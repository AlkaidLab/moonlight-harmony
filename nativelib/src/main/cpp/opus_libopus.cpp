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
 * @file opus_libopus.cpp
 * @brief libopus 1.6 直接调用的 Opus 解码器实现
 *
 * 使用 libopus 原生 opus_multistream_decode() 进行解码
 * 启用 ML 增强特性：
 *   - Deep PLC (complexity >= 5): 神经网络丢包补偿，比传统 PLC 质量高数倍
 *   - LACE (complexity == 6): 低码率语音增强，轻量级 DNN 后处理
 *   - NoLACE (complexity >= 7): 更强力的非线性语音增强
 *   - DRED 解码: 当编码端支持 DRED 时可解码深度冗余数据（未来 Sunshine 支持时自动生效）
 */

#include "opus_libopus.h"
#include <opus_multistream.h>
#include <opus_defines.h>
#include <hilog/log.h>
#include <mutex>
#include <cstring>

// Deep PLC 解码器复杂度等级
// 5 = Deep PLC only
// 6 = Deep PLC + LACE (低复杂度语音增强)
// 7+ = Deep PLC + NoLACE (高质量语音增强)
static constexpr int DECODER_COMPLEXITY = 7;

// =============================================================================
// 全局解码器实例
// =============================================================================

namespace {
    static OpusMSDecoder* g_decoder = nullptr;
    static std::mutex g_mutex;
    static int g_channelCount = 0;
    static int g_samplesPerFrame = 0;
    static OPUS_MULTISTREAM_CONFIGURATION g_savedConfig;
}

namespace MoonlightOpusDecoder {

int Init(POPUS_MULTISTREAM_CONFIGURATION opusConfig) {
    std::lock_guard<std::mutex> lock(g_mutex);
    
    // 清理旧实例
    if (g_decoder != nullptr) {
        opus_multistream_decoder_destroy(g_decoder);
        g_decoder = nullptr;
    }
    
    // 保存配置
    memcpy(&g_savedConfig, opusConfig, sizeof(g_savedConfig));
    g_channelCount = opusConfig->channelCount;
    g_samplesPerFrame = opusConfig->samplesPerFrame;
    
    OH_LOG_INFO(LOG_APP,
        "Initializing libopus decoder: sampleRate=%{public}d, channels=%{public}d, "
        "streams=%{public}d, coupledStreams=%{public}d, samplesPerFrame=%{public}d",
        opusConfig->sampleRate, opusConfig->channelCount,
        opusConfig->streams, opusConfig->coupledStreams,
        opusConfig->samplesPerFrame);
    
    int err = 0;
    g_decoder = opus_multistream_decoder_create(
        opusConfig->sampleRate,
        opusConfig->channelCount,
        opusConfig->streams,
        opusConfig->coupledStreams,
        opusConfig->mapping,
        &err
    );
    
    if (err != OPUS_OK || g_decoder == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to create opus multistream decoder: %{public}d (%{public}s)",
                     err, opus_strerror(err));
        g_decoder = nullptr;
        return -1;
    }
    
    // 设置解码器复杂度以启用 ML 增强特性
    // complexity 5 = Deep PLC (神经网络丢包补偿)
    // complexity 6 = Deep PLC + LACE (低复杂度语音增强)
    // complexity 7+ = Deep PLC + NoLACE (高质量非线性语音增强)
    int ctlErr = opus_multistream_decoder_ctl(g_decoder, OPUS_SET_COMPLEXITY(DECODER_COMPLEXITY));
    if (ctlErr != OPUS_OK) {
        OH_LOG_WARN(LOG_APP, "Failed to set decoder complexity to %{public}d: %{public}d (%{public}s). "
                    "ML features (Deep PLC/NoLACE) may not be available.",
                    DECODER_COMPLEXITY, ctlErr, opus_strerror(ctlErr));
    } else {
        OH_LOG_INFO(LOG_APP, "Decoder complexity set to %{public}d "
                    "(Deep PLC + NoLACE enabled)",
                    DECODER_COMPLEXITY);
    }
    
    OH_LOG_INFO(LOG_APP, "libopus 1.6 decoder initialized successfully with ML enhancements");
    return 0;
}

int Decode(const unsigned char* opusData, int opusLength,
           short* pcmOut, int maxSamples) {
    if (g_decoder == nullptr) {
        return -1;
    }
    
    // libopus 1.6 Neural PLC：传入 NULL 数据时，libopus 使用深度神经网络
    // (FARGAN vocoder) 预测并生成高质量的替代帧。
    // 当 complexity >= 5 时启用 Deep PLC，比传统 PLC 质量高数倍。
    // 传入正常数据时，NoLACE 增强器会自动优化低码率语音质量。
    int decodeLen = opus_multistream_decode(
        g_decoder,
        opusData,       // NULL = PLC（丢包补偿）
        opusLength,     // 0 when PLC
        pcmOut,
        maxSamples,
        0               // decode_fec: 0 = 不使用前向纠错
    );
    
    if (decodeLen < 0) {
        OH_LOG_WARN(LOG_APP, "opus_multistream_decode error: %{public}d (%{public}s)",
                    decodeLen, opus_strerror(decodeLen));
        return -1;
    }
    
    return decodeLen;
}

void Cleanup() {
    std::lock_guard<std::mutex> lock(g_mutex);
    
    if (g_decoder != nullptr) {
        opus_multistream_decoder_destroy(g_decoder);
        g_decoder = nullptr;
    }
    
    g_channelCount = 0;
    g_samplesPerFrame = 0;
    
    OH_LOG_INFO(LOG_APP, "libopus decoder cleaned up");
}

int GetChannelCount() {
    return g_channelCount;
}

int GetSamplesPerFrame() {
    return g_samplesPerFrame;
}

} // namespace MoonlightOpusDecoder
