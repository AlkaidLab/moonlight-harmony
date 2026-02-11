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
 * @brief 低频能量分析器 — 从 PCM 音频流中提取低频能量用于驱动音频振动
 *
 * 算法:
 * 1. 1阶 IIR 低通滤波器（截止 ~150Hz）提取低频分量
 * 2. 滑动窗口 RMS 指数移动平均 (EMA) 计算低频能量包络
 * 3. 能量映射到 0-100 强度，经节流后通过 TSFN 发送到 ArkTS 层
 *
 * 设计原则:
 * - 零堆分配，所有状态内联
 * - 每帧 PCM 解码后在同一线程调用，无锁
 * - 节流控制：最多 ~20次/秒 回调，避免振动 API 过载
 */

#ifndef BASS_ENERGY_ANALYZER_H
#define BASS_ENERGY_ANALYZER_H

#include <cstdint>
#include <cmath>
#include <chrono>

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

        // 1阶 IIR 低通滤波器系数
        // 截止频率 ~150Hz
        // α = 2π·fc·dt / (1 + 2π·fc·dt), dt = 1/fs
        const double fc = 150.0;
        const double dt = 1.0 / sampleRate;
        const double rc = 1.0 / (2.0 * M_PI * fc);
        lpAlpha_ = static_cast<float>(dt / (rc + dt));  // ≈ 0.0192 @ 48kHz

        // RMS EMA 系数
        // 平滑窗口 ~50ms，每帧 ~5ms @ 48kHz/240采样
        // 如果每帧调一次 ProcessFrame，约 200次/秒，α_ema ≈ 0.15
        rmsAlpha_ = 0.15f;

        // 重置状态
        lpState_ = 0.0f;
        rmsEma_ = 0.0f;
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
            // 重置状态
            lpState_ = 0.0f;
            rmsEma_ = 0.0f;
            lastIntensity_ = 0;
        }
    }

    bool IsEnabled() const { return enabled_; }

    /**
     * 设置灵敏度 (0.1 - 3.0, 默认 1.0)
     * 灵敏度越高，越小的低音也能触发振动
     */
    void SetSensitivity(float sensitivity) {
        sensitivity_ = sensitivity;
    }

    /**
     * 处理一帧 PCM 数据，返回是否应该触发回调
     * @param pcmData PCM 数据 (int16, 交错多声道)
     * @param sampleCount 总采样数 (帧数 × 声道数)
     * @param outIntensity 输出振动强度 (0-100)
     * @return true 如果应该触发 TSFN 回调（经过节流控制）
     */
    bool ProcessFrame(const int16_t* pcmData, int sampleCount, int& outIntensity) {
        if (!enabled_ || pcmData == nullptr || sampleCount <= 0) {
            outIntensity = 0;
            return false;
        }

        const int frameCount = sampleCount / channelCount_;

        // 低通滤波 + 能量累加
        // 只取第一声道（或混合立体声）进行低频检测，减少计算量
        float sumSquared = 0.0f;
        for (int i = 0; i < frameCount; i++) {
            // 混合所有声道取平均
            float sample = 0.0f;
            for (int ch = 0; ch < channelCount_; ch++) {
                sample += static_cast<float>(pcmData[i * channelCount_ + ch]);
            }
            sample /= channelCount_;

            // 归一化到 [-1, 1]
            sample /= 32768.0f;

            // 1阶 IIR 低通滤波
            lpState_ += lpAlpha_ * (sample - lpState_);

            // 累加平方值
            sumSquared += lpState_ * lpState_;
        }

        // 帧内 RMS
        float frameRms = std::sqrt(sumSquared / frameCount);

        // EMA 平滑
        rmsEma_ = rmsAlpha_ * frameRms + (1.0f - rmsAlpha_) * rmsEma_;

        // 映射到 0-100 强度
        // 经验参数: RMS 0.05 大约对应中等力度的低音
        // 乘以灵敏度系数
        float normalizedEnergy = rmsEma_ * sensitivity_ * 20.0f;  // 缩放到 0-1 范围
        normalizedEnergy = std::min(normalizedEnergy, 1.0f);

        // 非线性映射（增强小信号区分度）
        float mappedIntensity = std::sqrt(normalizedEnergy) * 100.0f;
        int intensity = static_cast<int>(mappedIntensity);
        intensity = std::max(0, std::min(100, intensity));

        outIntensity = intensity;

        // 节流控制：最多 20次/秒，且强度变化 >= 5 才回调
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastCallbackTime_).count();

        if (elapsed < 50) {
            return false;  // 距离上次回调不到 50ms
        }

        int delta = std::abs(intensity - lastIntensity_);
        if (delta < 5 && !(lastIntensity_ > 0 && intensity == 0)) {
            return false;  // 变化太小（除非归零，归零要立即通知）
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

    // IIR 低通滤波器状态
    float lpAlpha_ = 0.0f;
    float lpState_ = 0.0f;

    // RMS EMA
    float rmsAlpha_ = 0.0f;
    float rmsEma_ = 0.0f;

    // 节流
    int lastIntensity_ = 0;
    std::chrono::steady_clock::time_point lastCallbackTime_;
};

#endif // BASS_ENERGY_ANALYZER_H
