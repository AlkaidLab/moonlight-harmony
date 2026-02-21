/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * @file bass_energy_analyzer.h
 * @brief 低频能量分析器 v2 — 精准低音检测驱动音频振动
 *
 * 相比 v1 的改进:
 * 1. 2 阶 Butterworth 低通滤波器（截止 80Hz，-12dB/oct）
 *    → 衰减更陡峭，300Hz 信号衰减 ~22dB（v1 仅 6dB），几乎消除中频泄漏
 * 2. 攻击/释放包络跟踪器
 *    → 攻击 ~5ms（爆炸起音锐利），释放 ~80ms（衰减自然不突兀）
 * 3. 自适应噪声门限
 *    → 排除环境底噪和安静配乐，只在有显著低音冲击时触发
 * 4. 修复 sampleCount 语义（per-channel frames，非 total int16 count）
 *
 * 设计原则:
 * - 零堆分配，所有状态内联
 * - 每帧 PCM 解码后在同一线程调用，无锁
 * - 节流控制：最多 ~25次/秒 回调，避免振动 API 过载
 */

#ifndef BASS_ENERGY_ANALYZER_H
#define BASS_ENERGY_ANALYZER_H

#include <cstdint>
#include <cmath>
#include <chrono>
#include <algorithm>

class BassEnergyAnalyzer {
public:
    /**
     * 初始化分析器
     * @param sampleRate 采样率 (通常 48000)
     * @param channelCount 声道数 (1, 2, 6, 8 等)
     */
    void Init(int sampleRate, int channelCount) {
        sampleRate_ = sampleRate;
        channelCount_ = channelCount;

        // ---- 2 阶 Butterworth LPF 系数计算 ----
        // 截止频率 80Hz，Q = 1/√2 (Butterworth 最大平坦)
        // 参考: Audio EQ Cookbook (Robert Bristow-Johnson)
        const double fc = 80.0;
        const double Q = 0.7071;  // 1/√2
        const double w0 = 2.0 * M_PI * fc / sampleRate;
        const double sinW0 = std::sin(w0);
        const double cosW0 = std::cos(w0);
        const double alpha = sinW0 / (2.0 * Q);

        // LPF 传递函数: H(z) = (b0 + b1*z^-1 + b2*z^-2) / (a0 + a1*z^-1 + a2*z^-2)
        const double a0 = 1.0 + alpha;
        bq_b0_ = static_cast<float>((1.0 - cosW0) / 2.0 / a0);
        bq_b1_ = static_cast<float>((1.0 - cosW0) / a0);
        bq_b2_ = bq_b0_;
        bq_a1_ = static_cast<float>(-2.0 * cosW0 / a0);
        bq_a2_ = static_cast<float>((1.0 - alpha) / a0);

        // ---- 攻击/释放包络系数 ----
        // attack ~5ms → 爆炸枪声起音锐利
        // release ~80ms → 衰减平滑自然
        const double attackMs = 5.0;
        const double releaseMs = 80.0;
        // 每调用一次 ProcessFrame 大约对应 samplesPerFrame/sampleRate 秒
        // 但这里按采样点计算，在循环内逐采样应用
        attackCoeff_ = static_cast<float>(1.0 - std::exp(-1.0 / (sampleRate * attackMs / 1000.0)));
        releaseCoeff_ = static_cast<float>(1.0 - std::exp(-1.0 / (sampleRate * releaseMs / 1000.0)));

        // ---- 噪声门限 ----
        // 自适应底噪追踪：追踪近期最低能量水平，门限 = 底噪 + 固定偏移
        noiseFloor_ = 0.0f;
        noiseFloorAlpha_ = static_cast<float>(1.0 - std::exp(-1.0 / (sampleRate * 2.0)));  // ~2秒追踪

        // 重置滤波器状态
        bq_x1_ = bq_x2_ = 0.0f;
        bq_y1_ = bq_y2_ = 0.0f;
        envelope_ = 0.0f;
        rmsEnvelope_ = 0.0f;
        lastIntensity_ = 0;
        lastCallbackTime_ = std::chrono::steady_clock::now();
        enabled_ = false;
        sensitivity_ = 1.0f;
    }

    /**
     * 启用/禁用分析器
     */
    void SetEnabled(bool enabled) {
        enabled_ = enabled;
        if (!enabled) {
            // 重置滤波器状态
            bq_x1_ = bq_x2_ = 0.0f;
            bq_y1_ = bq_y2_ = 0.0f;
            envelope_ = 0.0f;
            rmsEnvelope_ = 0.0f;
            noiseFloor_ = 0.0f;
            lastIntensity_ = 0;
        }
    }

    bool IsEnabled() const { return enabled_; }

    /**
     * 设置灵敏度 (0.1 - 3.0, 默认 1.0)
     * 灵敏度越高，越小的低音也能触发振动
     */
    void SetSensitivity(float sensitivity) {
        sensitivity_ = std::max(0.1f, std::min(3.0f, sensitivity));
    }

    /**
     * 处理一帧 PCM 数据，返回是否应该触发回调
     * @param pcmData PCM 数据 (int16, 交错多声道)
     * @param sampleCount 每声道采样数 (per-channel frame count)
     * @param outIntensity 输出振动强度 (0-100)
     * @return true 如果应该触发 TSFN 回调（经过节流控制）
     */
    bool ProcessFrame(const int16_t* pcmData, int sampleCount, int& outIntensity) {
        if (!enabled_ || pcmData == nullptr || sampleCount <= 0) {
            outIntensity = 0;
            return false;
        }

        // sampleCount 是 per-channel frame count (来自 MoonlightOpusDecoder::Decode 返回值)
        const int frameCount = sampleCount;

        // 同时计算原始信号 RMS（绝对音量指标）
        float sumSquares = 0.0f;

        for (int i = 0; i < frameCount; i++) {
            // 混合所有声道取平均，归一化到 [-1, 1]
            float sample = 0.0f;
            for (int ch = 0; ch < channelCount_; ch++) {
                sample += static_cast<float>(pcmData[i * channelCount_ + ch]);
            }
            sample /= (channelCount_ * 32768.0f);

            // 累积原始信号平方和（用于 RMS 计算）
            sumSquares += sample * sample;

            // ---- 2 阶 Biquad LPF (Direct Form I) ----
            float filtered = bq_b0_ * sample + bq_b1_ * bq_x1_ + bq_b2_ * bq_x2_
                           - bq_a1_ * bq_y1_ - bq_a2_ * bq_y2_;
            bq_x2_ = bq_x1_;
            bq_x1_ = sample;
            bq_y2_ = bq_y1_;
            bq_y1_ = filtered;

            // ---- 攻击/释放包络跟踪 ----
            float rectified = std::fabs(filtered);
            if (rectified > envelope_) {
                envelope_ += attackCoeff_ * (rectified - envelope_);   // 快速攻击
            } else {
                envelope_ += releaseCoeff_ * (rectified - envelope_);  // 慢速释放
            }
        }

        // ---- 绝对音量 RMS 计算 ----
        // RMS ∈ [0, 1]，典型游戏音频: 安静 ~0.001-0.01, 普通 ~0.02-0.1, 爆炸 ~0.1-0.5
        float rms = (frameCount > 0) ? std::sqrt(sumSquares / frameCount) : 0.0f;

        // 用攻击/释放平滑 RMS，避免瞬间静音导致振动突然中断
        if (rms > rmsEnvelope_) {
            rmsEnvelope_ += 0.3f * (rms - rmsEnvelope_);   // 快速攻击跟踪音量上升
        } else {
            rmsEnvelope_ += 0.02f * (rms - rmsEnvelope_);  // 慢速释放避免突变
        }

        // 绝对音量权重: RMS < 0.005 时开始衰减，0.001 以下几乎静音
        // 使用平滑的 S 曲线映射，避免硬切
        // volumeWeight: 0.0 (极安静) → 1.0 (正常音量以上)
        const float rmsLow = 0.002f;   // 低于此视为极安静（几乎无声）
        const float rmsHigh = 0.015f;  // 高于此为正常音量，权重 = 1.0
        float volumeWeight;
        if (rmsEnvelope_ <= rmsLow) {
            volumeWeight = 0.0f;
        } else if (rmsEnvelope_ >= rmsHigh) {
            volumeWeight = 1.0f;
        } else {
            // 线性插值 [rmsLow, rmsHigh] → [0, 1]
            float t = (rmsEnvelope_ - rmsLow) / (rmsHigh - rmsLow);
            // smoothstep: 3t² - 2t³ — 平滑过渡
            volumeWeight = t * t * (3.0f - 2.0f * t);
        }

        // ---- 自适应噪声门限 ----
        // 底噪慢速追踪（上升快、下降慢，跟踪最低能量水平）
        if (envelope_ < noiseFloor_ || noiseFloor_ < 1e-8f) {
            noiseFloor_ = envelope_;  // 立即下降
        } else {
            noiseFloor_ += noiseFloorAlpha_ * (envelope_ - noiseFloor_);  // 缓慢上升
        }

        // 有效能量 = 包络 - 底噪偏移（底噪 ×8 作为门限，低于此视为 BGM/环境音）
        float threshold = noiseFloor_ * 8.0f + 0.005f;  // 高绝对门槛，滤除 BGM 和常规配乐
        float effectiveEnergy = std::max(0.0f, envelope_ - threshold);

        // ---- 映射到 0-100 强度 ----
        // 经验参数: 有效能量 0.06 ≈ 中等爆炸 → 约 47% 强度
        // 灵敏度缩放 → pow1.5 拑拐压缩 → 绝对音量权重 → 百分比
        float normalized = effectiveEnergy * sensitivity_ * 10.0f;
        normalized = std::min(normalized, 1.0f);

        // 非线性映射: pow(x, 2.5) — 陡峭指数压缩曲线
        // 效果: 中低能量几乎完全消除，只有强烈冲击才能突破
        // 对比: 0.1→0.003, 0.3→0.05, 0.5→0.18, 0.8→0.57, 1.0→1.0
        // 再乘以绝对音量权重：整体安静时抑制振动，防止低音量下过度反应
        float mappedIntensity = std::pow(normalized, 2.5f) * volumeWeight * 100.0f;
        int intensity = static_cast<int>(mappedIntensity);
        intensity = std::max(0, std::min(100, intensity));

        outIntensity = intensity;

        // ---- 节流控制 ----
        // 最多 25次/秒（40ms 间隔），且强度变化 >= 5 才触发回调
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastCallbackTime_).count();

        if (elapsed < 40) {
            return false;
        }

        int delta = std::abs(intensity - lastIntensity_);
        // 归零事件强制回调（停止振动），否则要求足够变化量
        bool shouldCallback = (lastIntensity_ > 0 && intensity == 0)  // 归零
                           || (intensity > 0 && lastIntensity_ == 0)  // 从零起步
                           || (delta >= 5);                            // 足够变化

        if (!shouldCallback) {
            return false;
        }

        lastIntensity_ = intensity;
        lastCallbackTime_ = now;
        return true;
    }

    /**
     * 获取当前低频能量 (0-100)，不走节流
     */
    int GetCurrentIntensity() const {
        return lastIntensity_;
    }

private:
    // 配置
    int sampleRate_ = 48000;
    int channelCount_ = 2;
    bool enabled_ = false;
    float sensitivity_ = 1.0f;

    // 2 阶 Biquad LPF 系数
    float bq_b0_ = 0.0f, bq_b1_ = 0.0f, bq_b2_ = 0.0f;
    float bq_a1_ = 0.0f, bq_a2_ = 0.0f;

    // Biquad 状态 (Direct Form I)
    float bq_x1_ = 0.0f, bq_x2_ = 0.0f;  // 输入延迟
    float bq_y1_ = 0.0f, bq_y2_ = 0.0f;  // 输出延迟

    // 攻击/释放包络
    float attackCoeff_ = 0.0f;
    float releaseCoeff_ = 0.0f;
    float envelope_ = 0.0f;

    // 绝对音量 RMS 包络（平滑跟踪整体音量水平）
    float rmsEnvelope_ = 0.0f;

    // 自适应噪声门限
    float noiseFloor_ = 0.0f;
    float noiseFloorAlpha_ = 0.0f;

    // 节流
    int lastIntensity_ = 0;
    std::chrono::steady_clock::time_point lastCallbackTime_;
};

#endif // BASS_ENERGY_ANALYZER_H
