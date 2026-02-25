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
 * @file mic_capturer.h
 * @brief HarmonyOS OHAudio 低时延麦克风采集器
 *
 * 使用 OHAudio C API + AUDIOSTREAM_LATENCY_MODE_FAST 实现低时延麦克风采集。
 * 在 native 回调线程中直接完成 Opus 编码 + 网络发送，消除 ArkTS 跨线程开销。
 *
 * 数据流：
 *   OH_AudioCapturer (FAST) → native callback → Opus encode → sendMicrophoneOpusData()
 */

#ifndef MIC_CAPTURER_H
#define MIC_CAPTURER_H

#include <cstdint>
#include <atomic>
#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiocapturer.h>
#include "opus_encoder.h"

/**
 * 麦克风采集器配置
 */
struct MicCapturerConfig {
    int sampleRate = 48000;      // 采样率
    int channels = 1;            // 声道数（单声道）
    int opusBitrate = 64000;     // Opus 编码比特率 (bps)
    int frameSizeMs = 20;        // 帧大小 (ms)
};

/**
 * 麦克风采集器统计
 */
struct MicCapturerStats {
    uint64_t framesCapture;     // 采集帧数
    uint64_t framesEncoded;     // 编码帧数
    uint64_t framesSent;        // 发送帧数
    uint64_t framesDropped;     // 丢弃帧数
    bool isFastMode;            // 是否工作在低时延模式
};

/**
 * OHAudio 低时延麦克风采集器
 *
 * 使用方式：
 *   MicCapturer capturer;
 *   capturer.Init(config);
 *   capturer.Start();
 *   // ... 流式传输期间自动在 native 回调中编码发送 ...
 *   capturer.Stop();
 *   capturer.Cleanup();
 */
class MicCapturer {
public:
    MicCapturer();
    ~MicCapturer();

    /**
     * 初始化麦克风采集器、Opus 编码器
     * @return 0 成功，负数失败
     */
    int Init(const MicCapturerConfig& config);

    /**
     * 启动采集
     * @return 0 成功，负数失败
     */
    int Start();

    /**
     * 停止采集
     * @return 0 成功，负数失败
     */
    int Stop();

    /**
     * 释放所有资源
     */
    void Cleanup();

    /**
     * 暂停（不释放设备，仅丢弃数据）
     */
    void Pause();

    /**
     * 恢复
     */
    void Resume();

    bool IsRunning() const { return running_.load(std::memory_order_acquire); }
    bool IsPaused()  const { return paused_.load(std::memory_order_acquire); }

    MicCapturerStats GetStats() const;

private:
    // OHAudio 回调
    static OH_AudioData_Callback_Result OnReadData(
        OH_AudioCapturer* capturer, void* userData,
        void* buffer, int32_t length);
    static void OnError(
        OH_AudioCapturer* capturer, void* userData,
        OH_AudioStream_Result error);
    static void OnInterruptEvent(
        OH_AudioCapturer* capturer, void* userData,
        OH_AudioInterrupt_ForceType type, OH_AudioInterrupt_Hint hint);

    // 处理一帧 PCM 数据 (在回调线程中调用)
    void ProcessPcmFrame(const uint8_t* data, int32_t length);

    // OHAudio 对象
    OH_AudioCapturer*      capturer_ = nullptr;
    OH_AudioStreamBuilder* builder_  = nullptr;

    // Opus 编码器
    OhosOpusEncoder encoder_;

    // 帧累积缓冲区（回调帧大小可能 != Opus 帧大小）
    static constexpr int kMaxFrameBytes = 48000 / 50 * 2 * 2; // 20ms, stereo, 16bit = 3840
    uint8_t frameBuffer_[kMaxFrameBytes] = {};
    int frameBufferPos_ = 0;
    int frameSizeBytes_ = 0; // 目标帧字节数

    // Opus 编码输出缓冲
    static constexpr int kOpusMaxOutputBytes = 4096;
    uint8_t opusOutput_[kOpusMaxOutputBytes] = {};

    // 配置
    MicCapturerConfig config_;

    // 状态
    std::atomic<bool> running_{false};
    std::atomic<bool> paused_{false};

    // 统计
    std::atomic<uint64_t> framesCaptured_{0};
    std::atomic<uint64_t> framesEncoded_{0};
    std::atomic<uint64_t> framesSent_{0};
    std::atomic<uint64_t> framesDropped_{0};
};

#endif // MIC_CAPTURER_H
