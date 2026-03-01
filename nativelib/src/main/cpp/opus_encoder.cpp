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
 * @file opus_encoder.cpp
 * @brief libopus 直接调用的 Opus 编码器实现（麦克风用）
 *
 * 使用 libopus 原生 API 进行 Opus 编码，与 Android 版本参数一致。
 * 完全同步调用，在音频回调线程中直接完成 PCM → Opus 编码，
 * 无队列、无额外线程、无异步延迟。
 *
 * 关键优化（对比旧版 AVCodec 方案）：
 * 1. OPUS_APPLICATION_VOIP — 专门优化语音信号的编码模式
 * 2. OPUS_SIGNAL_VOICE — 明确告知编码器输入是语音
 * 3. OPUS_SET_INBAND_FEC(1) — 前向纠错，丢包时仍可恢复
 * 4. OPUS_SET_DTX(1) — 静音检测，节省带宽
 * 5. OPUS_SET_COMPLEXITY(6) — 足够质量且不会导致实时编码超时
 * 6. OPUS_SET_PACKET_LOSS_PERC(1) — 预估丢包率
 */

#include "opus_encoder.h"
#include <opus.h>
#include <hilog/log.h>
#include <cstring>

#define LOG_TAG "OpusEncoder"

// =============================================================================
// OhosOpusEncoder 实现
// =============================================================================

OhosOpusEncoder::OhosOpusEncoder() {
    OH_LOG_INFO(LOG_APP, "OhosOpusEncoder constructor (libopus)");
}

OhosOpusEncoder::~OhosOpusEncoder() {
    OH_LOG_INFO(LOG_APP, "OhosOpusEncoder destructor");
    Cleanup();
}

int OhosOpusEncoder::Init(int sampleRate, int channels, int bitrate) {
    OH_LOG_INFO(LOG_APP, "Init (libopus): sampleRate=%{public}d, channels=%{public}d, bitrate=%{public}d",
                sampleRate, channels, bitrate);

    if (initialized_.load(std::memory_order_acquire)) {
        OH_LOG_WARN(LOG_APP, "Opus encoder already initialized, cleaning up first");
        Cleanup();
    }

    sampleRate_ = sampleRate;
    channels_ = channels;
    bitrate_ = bitrate;
    frameSize_ = sampleRate / 50; // 20ms 帧 (48000/50 = 960)

    // 创建 libopus 编码器 — VOIP 模式专门优化语音
    int error = 0;
    encoder_ = opus_encoder_create(sampleRate_, channels_, OPUS_APPLICATION_VOIP, &error);
    if (error != OPUS_OK || encoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "opus_encoder_create failed: %{public}d (%{public}s)",
                     error, opus_strerror(error));
        encoder_ = nullptr;
        return -1;
    }

    // ---- 编码参数配置（与 Android OpusEncoder.c 一致）----

    // 比特率
    opus_encoder_ctl(encoder_, OPUS_SET_BITRATE(bitrate_));

    // 信号类型：语音
    opus_encoder_ctl(encoder_, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));

    // 编码复杂度：6（平衡质量与 CPU，与 Android 一致）
    opus_encoder_ctl(encoder_, OPUS_SET_COMPLEXITY(6));

    // DTX：静音时不发送帧，节省带宽
    opus_encoder_ctl(encoder_, OPUS_SET_DTX(1));

    // 帧大小：20ms
    opus_encoder_ctl(encoder_, OPUS_SET_EXPERT_FRAME_DURATION(OPUS_FRAMESIZE_20_MS));

    // FEC：前向纠错，丢包时可从后续包恢复
    opus_encoder_ctl(encoder_, OPUS_SET_INBAND_FEC(1));

    // 预估丢包率：1%
    opus_encoder_ctl(encoder_, OPUS_SET_PACKET_LOSS_PERC(1));

    // 输出日志确认参数
    opus_int32 actualBitrate = 0, actualComplexity = 0, actualDtx = 0, actualFec = 0;
    opus_encoder_ctl(encoder_, OPUS_GET_BITRATE(&actualBitrate));
    opus_encoder_ctl(encoder_, OPUS_GET_COMPLEXITY(&actualComplexity));
    opus_encoder_ctl(encoder_, OPUS_GET_DTX(&actualDtx));
    opus_encoder_ctl(encoder_, OPUS_GET_INBAND_FEC(&actualFec));

    OH_LOG_INFO(LOG_APP,
        "libopus encoder ready: bitrate=%{public}d complexity=%{public}d DTX=%{public}d FEC=%{public}d frameSize=%{public}d",
        actualBitrate, actualComplexity, actualDtx, actualFec, frameSize_);

    hasError_.store(false, std::memory_order_release);
    initialized_.store(true, std::memory_order_release);
    return 0;
}

int OhosOpusEncoder::Encode(const uint8_t* pcmData, int pcmLength, uint8_t* opusOutput, int maxOutputLen) {
    if (pcmData == nullptr || pcmLength <= 0 || opusOutput == nullptr || maxOutputLen <= 0) {
        return -1;
    }

    if (!initialized_.load(std::memory_order_acquire) || encoder_ == nullptr) {
        return -1;
    }

    // pcmLength 应该是 frameSize_ * channels_ * sizeof(int16_t)
    int expectedBytes = frameSize_ * channels_ * 2;
    if (pcmLength < expectedBytes) {
        OH_LOG_WARN(LOG_APP, "PCM data too short: %{public}d < %{public}d", pcmLength, expectedBytes);
        return -1;
    }

    // 同步编码 — 直接在调用线程中完成，零延迟
    int encodedLen = opus_encode(
        encoder_,
        reinterpret_cast<const opus_int16*>(pcmData),
        frameSize_,
        opusOutput,
        maxOutputLen
    );

    if (encodedLen < 0) {
        OH_LOG_ERROR(LOG_APP, "opus_encode failed: %{public}d (%{public}s)",
                     encodedLen, opus_strerror(encodedLen));
        hasError_.store(true, std::memory_order_release);
        return -1;
    }

    // encodedLen == 1 时是 DTX 静音帧（只有 1 字节的 TOC），也需要发送
    return encodedLen;
}

void OhosOpusEncoder::Cleanup() {
    OH_LOG_INFO(LOG_APP, "Cleanup (libopus)");

    initialized_.store(false, std::memory_order_release);

    if (encoder_ != nullptr) {
        opus_encoder_destroy(encoder_);
        encoder_ = nullptr;
    }

    hasError_.store(false, std::memory_order_release);
    OH_LOG_INFO(LOG_APP, "Cleanup completed");
}

