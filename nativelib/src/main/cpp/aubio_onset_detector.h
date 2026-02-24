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
 * @file aubio_onset_detector.h
 * @brief aubio onset 检测器的 C++ 封装
 *
 * 用法:
 *   AubioOnsetDetector detector;
 *   detector.Init(48000, 512, 1024);  // samplerate, hop_size, buf_size
 *   detector.SetMethod("hfc");         // onset 方法 (可选)
 *
 *   // 在音频回调中:
 *   bool onset = detector.ProcessSamples(pcm_float_mono, hop_size);
 *   if (onset) {
 *       float when_ms = detector.GetLastOnsetMs();
 *   }
 *
 *   detector.Cleanup();
 *
 * 线程安全: 非线程安全，应在同一个音频处理线程中调用。
 */

#ifndef AUBIO_ONSET_DETECTOR_H
#define AUBIO_ONSET_DETECTOR_H

#include <cstdint>
#include <cstring>

// aubio C API
extern "C" {
#include "aubio/src/types.h"
#include "aubio/src/fvec.h"
#include "aubio/src/cvec.h"
#include "aubio/src/onset/onset.h"
}

class AubioOnsetDetector {
public:
    AubioOnsetDetector() = default;


    ~AubioOnsetDetector() {
        Cleanup();
    }

    // 禁止复制
    AubioOnsetDetector(const AubioOnsetDetector&) = delete;
    AubioOnsetDetector& operator=(const AubioOnsetDetector&) = delete;

    /**
     * 初始化 onset 检测器
     * @param sampleRate 采样率 (通常 48000)
     * @param hopSize 每次处理的采样数 (推荐 256 或 512)
     * @param bufSize FFT 窗口大小 (必须 >= hopSize, 推荐 512 或 1024)
     * @param method onset 检测方法: "default", "energy", "hfc", "complex",
     *               "phase", "wphase", "specdiff", "kl", "mkl", "specflux"
     * @return true 如果初始化成功
     */
    bool Init(uint32_t sampleRate, uint32_t hopSize = 256,
              uint32_t bufSize = 512, const char* method = "hfc") {
        Cleanup();

        sampleRate_ = sampleRate;
        hopSize_ = hopSize;
        bufSize_ = bufSize;

        // 创建 aubio onset 检测器
        onset_ = new_aubio_onset(method, bufSize, hopSize, sampleRate);
        if (!onset_) {
            return false;
        }

        // 创建输入/输出缓冲区
        inputBuf_ = new_fvec(hopSize);
        outputBuf_ = new_fvec(1);
        if (!inputBuf_ || !outputBuf_) {
            Cleanup();
            return false;
        }

        initialized_ = true;
        return true;
    }

    /**
     * 清理资源
     */
    void Cleanup() {
        if (onset_) {
            del_aubio_onset(onset_);
            onset_ = nullptr;
        }
        if (inputBuf_) {
            del_fvec(inputBuf_);
            inputBuf_ = nullptr;
        }
        if (outputBuf_) {
            del_fvec(outputBuf_);
            outputBuf_ = nullptr;
        }
        initialized_ = false;
    }

    /**
     * 处理一帧音频数据 (float, 单声道, [-1.0, 1.0])
     * @param samples 音频采样数组
     * @param count 采样数 (必须 == hopSize)
     * @return true 如果检测到 onset
     */
    bool ProcessSamples(const float* samples, uint32_t count) {
        if (!initialized_ || !samples || count != hopSize_) {
            return false;
        }

        // 复制数据到 aubio 缓冲区
        std::memcpy(inputBuf_->data, samples, count * sizeof(float));

        // 执行 onset 检测
        aubio_onset_do(onset_, inputBuf_, outputBuf_);

        return outputBuf_->data[0] > 0.0f;
    }

    /**
     * 处理交错多声道 int16 PCM 数据
     * 自动混缩到单声道 float 并累积到内部缓冲区
     * @param pcmData 交错 PCM 数据
     * @param perChannelSamples 每声道采样数
     * @param channelCount 声道数
     * @param onsetDetected [out] 如果检测到 onset 则设为 true
     * @return 处理的完整 hop 数
     */
    int ProcessInt16Interleaved(const int16_t* pcmData, int perChannelSamples,
                                int channelCount, bool& onsetDetected) {
        if (!initialized_ || !pcmData || perChannelSamples <= 0) {
            onsetDetected = false;
            return 0;
        }

        onsetDetected = false;
        int hopsProcessed = 0;

        for (int i = 0; i < perChannelSamples; i++) {
            // 混缩到单声道
            float sample = 0.0f;
            for (int ch = 0; ch < channelCount; ch++) {
                sample += static_cast<float>(pcmData[i * channelCount + ch]);
            }
            sample /= (channelCount * 32768.0f);

            // 写入内部收集缓冲区
            inputBuf_->data[accumPos_] = sample;
            accumPos_++;

            // 积满一个 hop 就处理
            if (accumPos_ >= static_cast<int>(hopSize_)) {
                aubio_onset_do(onset_, inputBuf_, outputBuf_);
                if (outputBuf_->data[0] > 0.0f) {
                    onsetDetected = true;
                }
                accumPos_ = 0;
                hopsProcessed++;
            }
        }

        return hopsProcessed;
    }

    // ---- 参数调节 ----

    void SetThreshold(float threshold) {
        if (onset_) aubio_onset_set_threshold(onset_, threshold);
    }

    float GetThreshold() const {
        return onset_ ? aubio_onset_get_threshold(onset_) : 0.0f;
    }

    void SetSilence(float silenceDb) {
        if (onset_) aubio_onset_set_silence(onset_, silenceDb);
    }

    float GetSilence() const {
        return onset_ ? aubio_onset_get_silence(onset_) : -70.0f;
    }

    void SetMinioiMs(float ms) {
        if (onset_) aubio_onset_set_minioi_ms(onset_, ms);
    }

    float GetMinioiMs() const {
        return onset_ ? aubio_onset_get_minioi_ms(onset_) : 0.0f;
    }

    void SetAdaptiveWhitening(bool enable) {
        if (onset_) aubio_onset_set_awhitening(onset_, enable ? 1 : 0);
    }

    void SetCompression(float lambda) {
        if (onset_) aubio_onset_set_compression(onset_, lambda);
    }

    // ---- 查询 ----

    /** 获取最近一次 onset 的时间 (采样数) */
    uint32_t GetLastOnset() const {
        return onset_ ? aubio_onset_get_last(onset_) : 0;
    }

    /** 获取最近一次 onset 的时间 (毫秒) */
    float GetLastOnsetMs() const {
        return onset_ ? aubio_onset_get_last_ms(onset_) : 0.0f;
    }

    /** 获取当前帧的 onset 描述子值 */
    float GetDescriptor() const {
        return onset_ ? aubio_onset_get_descriptor(onset_) : 0.0f;
    }

    /** 获取阈值处理后的描述子值 */
    float GetThresholdedDescriptor() const {
        return onset_ ? aubio_onset_get_thresholded_descriptor(onset_) : 0.0f;
    }

    /** 重置检测器状态 */
    void Reset() {
        if (onset_) aubio_onset_reset(onset_);
        accumPos_ = 0;
    }

    bool IsInitialized() const { return initialized_; }
    uint32_t GetHopSize() const { return hopSize_; }
    uint32_t GetBufSize() const { return bufSize_; }

private:
    aubio_onset_t* onset_ = nullptr;
    fvec_t* inputBuf_ = nullptr;
    fvec_t* outputBuf_ = nullptr;

    uint32_t sampleRate_ = 0;
    uint32_t hopSize_ = 0;
    uint32_t bufSize_ = 0;
    int accumPos_ = 0;  // int16 interleaved 模式下的累积位置

    bool initialized_ = false;
};

#endif // AUBIO_ONSET_DETECTOR_H
