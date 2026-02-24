/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * aubio onset detection wrapper for BassEnergyAnalyzer
 *
 * 封装 aubio 的 onset detection API，提供 C++ 友好的接口。
 * aubio 使用 spectral flux + adaptive whitening + peak-picking，
 * 比手写的简单 energy ratio 方案更精确。
 *
 * 线程模型: 与 BassEnergyAnalyzer 在同一解码线程调用，无需加锁。
 */

#ifndef AUBIO_ONSET_WRAPPER_H
#define AUBIO_ONSET_WRAPPER_H

extern "C" {
#include "types.h"
#include "fvec.h"
#include "onset/onset.h"
}

#include <cstdint>
#include <cstring>

class AubioOnsetWrapper {
public:
    AubioOnsetWrapper() = default;

    ~AubioOnsetWrapper() {
        Destroy();
    }

    // 禁止拷贝
    AubioOnsetWrapper(const AubioOnsetWrapper&) = delete;
    AubioOnsetWrapper& operator=(const AubioOnsetWrapper&) = delete;

    /**
     * 初始化 aubio onset detector
     *
     * @param sampleRate 采样率 (通常 48000)
     * @param hopSize 每次喂入的样本数 (对应 Opus 每帧解码出的 per-channel 样本数, 通常 240)
     * @param method  onset 检测方法: "specflux", "hfc", "complex", "energy" 等
     *                推荐 "specflux" - 在音乐 onset 检测上表现最好
     */
    bool Init(int sampleRate, int hopSize, const char* method = "specflux") {
        Destroy();

        sampleRate_ = sampleRate;
        hopSize_ = hopSize;

        // FFT 窗口 = 4× hop size (标准设置)
        // hop=240 → buf=1024 (取最近的 2 的幂)
        bufSize_ = 1;
        while (bufSize_ < static_cast<unsigned int>(hopSize * 4)) {
            bufSize_ *= 2;
        }

        // 创建 onset detector
        onset_ = new_aubio_onset(method, bufSize_, hopSize_, sampleRate_);
        if (!onset_) {
            return false;
        }

        // 配置参数 - 为游戏串流场景优化
        aubio_onset_set_threshold(onset_, 0.3f);      // peak-picking 阈值 (默认 0.3)
        aubio_onset_set_silence(onset_, -70.0f);       // 静音阈值 -70dB
        aubio_onset_set_minioi_ms(onset_, 80.0f);      // 最小 onset 间隔 80ms (~12.5 次/秒)
        aubio_onset_set_awhitening(onset_, 1);         // 启用自适应频谱白化
        aubio_onset_set_compression(onset_, 1.0f);     // 对数压缩
        aubio_onset_set_delay_ms(onset_, 0.0f);        // 零延迟 (实时)

        // 分配输入/输出缓冲区
        inputBuf_ = new_fvec(hopSize_);
        onsetOut_ = new_fvec(1);

        initialized_ = true;
        return true;
    }

    void Destroy() {
        if (onset_) {
            del_aubio_onset(onset_);
            onset_ = nullptr;
        }
        if (inputBuf_) {
            del_fvec(inputBuf_);
            inputBuf_ = nullptr;
        }
        if (onsetOut_) {
            del_fvec(onsetOut_);
            onsetOut_ = nullptr;
        }
        initialized_ = false;
        accumPos_ = 0;
    }

    void Reset() {
        if (onset_) {
            aubio_onset_reset(onset_);
        }
        accumPos_ = 0;
    }

    /**
     * 处理一帧 PCM 数据 (int16, 多声道交错)
     *
     * aubio 需要 float 单声道数据，长度 = hopSize。
     * 我们在此进行:
     *   1. int16 → float 归一化 (-1.0 ~ 1.0)
     *   2. 多声道取平均 → 单声道
     *   3. 如果帧长度 != hopSize，用内部缓冲区累积
     *
     * @param pcmData   PCM int16 数据 (交错多声道)
     * @param perChannelSamples  每声道样本数
     * @param channelCount 声道数
     * @param outOnsetDetected  输出: 是否检测到 onset
     * @return true 如果成功处理
     */
    bool ProcessFrame(const int16_t* pcmData, int perChannelSamples,
                      int channelCount, bool& outOnsetDetected) {
        if (!initialized_ || !pcmData) {
            outOnsetDetected = false;
            return false;
        }

        outOnsetDetected = false;

        // 逐样本：int16 多声道 → float 单声道
        for (int i = 0; i < perChannelSamples; i++) {
            float monoSample = 0.0f;
            for (int ch = 0; ch < channelCount; ch++) {
                monoSample += static_cast<float>(pcmData[i * channelCount + ch]);
            }
            monoSample /= (32768.0f * channelCount);

            // 累积到 aubio 输入缓冲区
            inputBuf_->data[accumPos_] = monoSample;
            accumPos_++;

            // 满一个 hop 就提交给 aubio
            if (accumPos_ >= static_cast<int>(hopSize_)) {
                aubio_onset_do(onset_, inputBuf_, onsetOut_);
                if (onsetOut_->data[0] > 0.0f) {
                    outOnsetDetected = true;
                }
                accumPos_ = 0;
            }
        }

        return true;
    }

    /**
     * 获取 onset 检测器的当前描述子值
     * 可用于判断 onset 的"强度"
     */
    float GetDescriptor() const {
        if (!onset_) return 0.0f;
        return aubio_onset_get_descriptor(onset_);
    }

    /**
     * 获取阈值化后的描述子 (超过阈值的部分)
     */
    float GetThresholdedDescriptor() const {
        if (!onset_) return 0.0f;
        return aubio_onset_get_thresholded_descriptor(onset_);
    }

    /**
     * 设置 onset 检测阈值 (默认 0.3)
     * 降低 → 更灵敏（更多 onset），升高 → 更保守
     */
    void SetThreshold(float threshold) {
        if (onset_) {
            aubio_onset_set_threshold(onset_, threshold);
        }
    }

    /**
     * 设置最小 onset 间隔 (毫秒)
     */
    void SetMinInterval(float ms) {
        if (onset_) {
            aubio_onset_set_minioi_ms(onset_, ms);
        }
    }

    bool IsInitialized() const { return initialized_; }

private:
    aubio_onset_t* onset_ = nullptr;
    fvec_t* inputBuf_ = nullptr;
    fvec_t* onsetOut_ = nullptr;

    int sampleRate_ = 48000;
    unsigned int hopSize_ = 240;
    unsigned int bufSize_ = 1024;
    int accumPos_ = 0;           // 内部累积位置（帧长 != hopSize 时用）
    bool initialized_ = false;
};

#endif // AUBIO_ONSET_WRAPPER_H
