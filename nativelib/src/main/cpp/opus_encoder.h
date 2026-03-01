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
 * @file opus_encoder.h
 * @brief libopus 直接调用的 Opus 编码器（麦克风用）
 *
 * 使用 libopus 原生 API 进行 Opus 编码，替代 AVCodec 包装。
 * 优势：
 *   - OPUS_APPLICATION_VOIP 优化语音质量
 *   - OPUS_SIGNAL_VOICE 信号类型提示
 *   - FEC 前向纠错 + DTX 静音检测
 *   - 同步调用，零额外延迟
 *   - 与 Android 版本 (OpusEncoder.c) 参数一致
 */

#ifndef OPUS_ENCODER_H
#define OPUS_ENCODER_H

#include <cstdint>
#include <atomic>

// Forward declaration — libopus
struct OpusEncoder;

/**
 * Opus 编码器类
 * 使用 libopus 原生 API 进行 PCM 到 Opus 的编码
 *
 * 完全同步调用，在音频回调线程中直接编码，无队列、无额外线程。
 */
class OhosOpusEncoder {
public:
    OhosOpusEncoder();
    ~OhosOpusEncoder();

    /**
     * 初始化编码器
     * @param sampleRate 采样率 (8000, 12000, 16000, 24000, 48000)
     * @param channels 通道数 (1 或 2)
     * @param bitrate 比特率 (6000-510000 bps)
     * @return 0 成功, 负数失败
     */
    int Init(int sampleRate, int channels, int bitrate);

    /**
     * 编码 PCM 数据（同步调用）
     * @param pcmData PCM 数据 (16位有符号整数, S16LE)
     * @param pcmLength PCM 数据长度 (字节)
     * @param opusOutput 编码后的 Opus 数据输出缓冲区
     * @param maxOutputLen 输出缓冲区最大长度
     * @return 编码后的数据长度 (>0), 0 表示 DTX 静音, 负数表示失败
     */
    int Encode(const uint8_t* pcmData, int pcmLength, uint8_t* opusOutput, int maxOutputLen);

    /**
     * 清理资源
     */
    void Cleanup();

    /**
     * 检查是否已初始化
     */
    bool IsInitialized() const { return initialized_.load(std::memory_order_acquire); }

    /**
     * 检查是否有错误
     */
    bool HasError() const { return hasError_.load(std::memory_order_acquire); }

private:
    ::OpusEncoder* encoder_ = nullptr;
    int sampleRate_ = 48000;
    int channels_ = 1;
    int bitrate_ = 64000;
    int frameSize_ = 960; // samples per channel per frame (20ms @ 48kHz)

    std::atomic<bool> initialized_{false};
    std::atomic<bool> hasError_{false};
};

#endif // OPUS_ENCODER_H
