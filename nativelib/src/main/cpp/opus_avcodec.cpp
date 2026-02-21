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
 * @file opus_avcodec.cpp
 * @brief HarmonyOS AVCodec 实现的 Opus 解码器
 * 
 * 使用 HarmonyOS 原生 AVCodec API 进行 Opus 解码
 */

#include "opus_avcodec.h"
#include <hilog/log.h>
#include <cstring>

#define LOG_TAG "OpusAVCodec"

// =============================================================================
// OpusAVCodecDecoder 类实现
// =============================================================================

OpusAVCodecDecoder::OpusAVCodecDecoder() {
}

OpusAVCodecDecoder::~OpusAVCodecDecoder() {
    Cleanup();
}

int OpusAVCodecDecoder::Init(POPUS_MULTISTREAM_CONFIGURATION opusConfig) {
    std::lock_guard<std::mutex> lock(decodeMutex_);
    
    if (decoder_ != nullptr) {
        OH_LOG_WARN(LOG_APP, "Opus decoder already initialized");
        return 0;
    }
    
    // 保存配置（用于错误恢复时重建）
    memcpy(&savedConfig_, opusConfig, sizeof(savedConfig_));
    
    // 保存配置
    sampleRate_ = opusConfig->sampleRate;
    channelCount_ = opusConfig->channelCount;
    samplesPerFrame_ = opusConfig->samplesPerFrame;
    
    OH_LOG_INFO(LOG_APP, "Initializing AVCodec Opus decoder: sampleRate=%{public}d, channels=%{public}d, samplesPerFrame=%{public}d",
                sampleRate_, channelCount_, samplesPerFrame_);
    
    // 创建 Opus 解码器
    // 注意：HarmonyOS 使用 OH_AVCODEC_MIMETYPE_AUDIO_OPUS
    decoder_ = OH_AudioCodec_CreateByMime(OH_AVCODEC_MIMETYPE_AUDIO_OPUS, false);
    if (decoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to create Opus decoder");
        return -1;
    }
    
    // 注册回调
    OH_AVCodecCallback callback = {
        .onError = OnError,
        .onStreamChanged = OnOutputFormatChanged,
        .onNeedInputBuffer = OnInputBufferAvailable,
        .onNewOutputBuffer = OnOutputBufferAvailable
    };
    
    int32_t ret = OH_AudioCodec_RegisterCallback(decoder_, callback, this);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to register callback: %{public}d", ret);
        OH_AudioCodec_Destroy(decoder_);
        decoder_ = nullptr;
        return -1;
    }
    
    // 配置解码器
    OH_AVFormat* format = OH_AVFormat_Create();
    if (format == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to create AVFormat");
        OH_AudioCodec_Destroy(decoder_);
        decoder_ = nullptr;
        return -1;
    }
    
    // 设置必需参数
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, sampleRate_);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, channelCount_);
    
    // 可选参数
    int maxInputSize = 1500; // Opus 最大包大小
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE, maxInputSize);
    
    ret = OH_AudioCodec_Configure(decoder_, format);
    OH_AVFormat_Destroy(format);
    
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to configure decoder: %{public}d", ret);
        OH_AudioCodec_Destroy(decoder_);
        decoder_ = nullptr;
        return -1;
    }
    
    // 准备解码器
    ret = OH_AudioCodec_Prepare(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to prepare decoder: %{public}d", ret);
        OH_AudioCodec_Destroy(decoder_);
        decoder_ = nullptr;
        return -1;
    }
    
    // 启动解码器
    ret = OH_AudioCodec_Start(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to start decoder: %{public}d", ret);
        OH_AudioCodec_Destroy(decoder_);
        decoder_ = nullptr;
        return -1;
    }
    
    running_ = true;
    needReset_ = false;
    consecutiveErrors_ = 0;
    OH_LOG_INFO(LOG_APP, "AVCodec Opus decoder initialized successfully");
    
    return 0;
}

int OpusAVCodecDecoder::Decode(const unsigned char* opusData, int opusLength,
                                short* pcmOut, int maxSamples) {
    if (!running_ || decoder_ == nullptr) {
        // 如果需要重建，尝试重建
        if (needReset_.load()) {
            int ret = TryRebuild();
            if (ret != 0) {
                return -1;
            }
        } else {
            return -1;
        }
    }
    
    // 处理 NULL 数据（PLC - 丢包补偿）
    // moonlight-common-c 在检测到丢包时传 NULL 表示需要 PLC
    // AVCodec 不支持原生 PLC，使用最后一帧衰减回放代替纯静音
    if (opusData == nullptr || opusLength <= 0) {
        int silenceSamples = std::min(samplesPerFrame_, maxSamples);
        int totalSamples = silenceSamples * channelCount_;
        
        if (!lastDecodedFrame_.empty() && plcConsecutiveCount_ < MAX_PLC_REPEATS) {
            // 用上一帧数据衰减回放
            int copyCount = std::min(totalSamples, (int)lastDecodedFrame_.size());
            float gain = 1.0f;
            for (int i = 0; i <= plcConsecutiveCount_; i++) {
                gain *= PLC_DECAY;
            }
            for (int i = 0; i < copyCount; i++) {
                pcmOut[i] = (short)(lastDecodedFrame_[i] * gain);
            }
            if (copyCount < totalSamples) {
                memset(pcmOut + copyCount, 0, (totalSamples - copyCount) * sizeof(short));
            }
            plcConsecutiveCount_++;
        } else {
            // 超过最大重复次数或无缓存帧，输出静音
            memset(pcmOut, 0, totalSamples * sizeof(short));
        }
        return silenceSamples;
    }
    
    // 获取输入缓冲区
    uint32_t inputIndex;
    OH_AVBuffer* inputBuffer = nullptr;
    
    {
        std::unique_lock<std::mutex> lock(inputMutex_);
        // 等待输入缓冲区可用（超时 100ms）
        if (inputIndexQueue_.empty()) {
            if (!inputCond_.wait_for(lock, std::chrono::milliseconds(100), 
                [this] { return !inputIndexQueue_.empty() || !running_; })) {
                OH_LOG_WARN(LOG_APP, "Timeout waiting for input buffer");
                return -1;
            }
        }
        
        if (!running_ || inputIndexQueue_.empty()) {
            return -1;
        }
        
        inputIndex = inputIndexQueue_.front();
        inputBuffer = inputBufferQueue_.front();
        inputIndexQueue_.pop();
        inputBufferQueue_.pop();
    }
    
    // 填充输入数据
    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(inputBuffer);
    if (bufferAddr == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to get input buffer address");
        return -1;
    }
    
    memcpy(bufferAddr, opusData, opusLength);
    
    // 设置缓冲区属性
    OH_AVCodecBufferAttr attr = {0};
    attr.size = opusLength;
    attr.offset = 0;
    attr.pts = 0;  // TODO: 使用正确的时间戳
    attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
    
    OH_AVBuffer_SetBufferAttr(inputBuffer, &attr);
    
    // 准备接收输出
    {
        std::lock_guard<std::mutex> lock(decodeMutex_);
        pendingPcmOutput_ = pcmOut;
        pendingMaxSamples_ = maxSamples;
        decodedSamples_ = 0;
        decodeComplete_ = false;
    }
    
    // 提交输入缓冲区
    int32_t ret = OH_AudioCodec_PushInputBuffer(decoder_, inputIndex);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to push input buffer: %{public}d", ret);
        return -1;
    }
    
    // 等待解码完成
    {
        std::unique_lock<std::mutex> lock(decodeMutex_);
        if (!decodeComplete_) {
            decodeCompleteCond_.wait_for(lock, std::chrono::milliseconds(100),
                [this] { return decodeComplete_ || !running_; });
        }
    }
    
    if (decodedSamples_ > 0) {
        consecutiveErrors_ = 0;  // 成功解码，重置错误计数
        
        int totalSamples = decodedSamples_ * channelCount_;
        
        // PLC 恢复后的首帧：与上一 PLC 帧做交叉渐变，消除波形跳变
        if (plcConsecutiveCount_ > 0 && !lastDecodedFrame_.empty()) {
            int crossLen = std::min(totalSamples, (int)lastDecodedFrame_.size());
            // 交叉渐变：从旧帧（衰减后）渐出，新帧渐入
            float plcGain = 1.0f;
            for (int j = 0; j <= plcConsecutiveCount_; j++) {
                plcGain *= PLC_DECAY;
            }
            for (int i = 0; i < crossLen; i++) {
                float t = (float)i / (float)crossLen; // 0→1
                float oldVal = lastDecodedFrame_[i] * plcGain;
                float newVal = pcmOut[i];
                pcmOut[i] = (short)(oldVal * (1.0f - t) + newVal * t);
            }
        }
        
        plcConsecutiveCount_ = 0; // 成功解码，重置 PLC 计数
        
        // 缓存最后一帧用于 PLC
        lastDecodedFrame_.resize(totalSamples);
        memcpy(lastDecodedFrame_.data(), pcmOut, totalSamples * sizeof(short));
    } else {
        int errors = ++consecutiveErrors_;
        if (errors >= MAX_DECODE_ERRORS) {
            OH_LOG_ERROR(LOG_APP, "Too many consecutive decode errors (%{public}d), scheduling rebuild", errors);
            needReset_ = true;
            running_ = false;
        }
    }
    
    return decodedSamples_;
}

void OpusAVCodecDecoder::Cleanup() {
    running_ = false;
    
    // 唤醒所有等待线程
    inputCond_.notify_all();
    outputCond_.notify_all();
    decodeCompleteCond_.notify_all();
    
    if (decoder_ != nullptr) {
        OH_AudioCodec_Stop(decoder_);
        OH_AudioCodec_Destroy(decoder_);
        decoder_ = nullptr;
    }
    
    // 清空队列
    {
        std::lock_guard<std::mutex> lock(inputMutex_);
        while (!inputIndexQueue_.empty()) inputIndexQueue_.pop();
        while (!inputBufferQueue_.empty()) inputBufferQueue_.pop();
    }
    
    {
        std::lock_guard<std::mutex> lock(outputMutex_);
        while (!outputIndexQueue_.empty()) outputIndexQueue_.pop();
        while (!outputBufferQueue_.empty()) outputBufferQueue_.pop();
    }
    
    // 清空 PLC 缓存
    lastDecodedFrame_.clear();
    plcConsecutiveCount_ = 0;
    
    OH_LOG_INFO(LOG_APP, "AVCodec Opus decoder cleaned up");
}

int OpusAVCodecDecoder::TryRebuild() {
    OH_LOG_INFO(LOG_APP, "Attempting Opus decoder rebuild...");
    
    // 先完全清理
    if (decoder_ != nullptr) {
        OH_AudioCodec_Stop(decoder_);
        OH_AudioCodec_Destroy(decoder_);
        decoder_ = nullptr;
    }
    
    // 清空队列
    {
        std::lock_guard<std::mutex> lock(inputMutex_);
        while (!inputIndexQueue_.empty()) inputIndexQueue_.pop();
        while (!inputBufferQueue_.empty()) inputBufferQueue_.pop();
    }
    {
        std::lock_guard<std::mutex> lock(outputMutex_);
        while (!outputIndexQueue_.empty()) outputIndexQueue_.pop();
        while (!outputBufferQueue_.empty()) outputBufferQueue_.pop();
    }
    
    // 重新初始化
    needReset_ = false;
    int ret = Init(&savedConfig_);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to rebuild Opus decoder");
        return -1;
    }
    
    OH_LOG_INFO(LOG_APP, "Opus decoder rebuilt successfully");
    return 0;
}

// =============================================================================
// AVCodec 回调实现
// =============================================================================

void OpusAVCodecDecoder::OnError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    OH_LOG_ERROR(LOG_APP, "AVCodec error: %{public}d", errorCode);
    
    OpusAVCodecDecoder* self = static_cast<OpusAVCodecDecoder*>(userData);
    if (self != nullptr) {
        OH_LOG_ERROR(LOG_APP, "AVCodec Opus decoder error, scheduling rebuild");
        self->needReset_ = true;
        self->running_ = false;
    }
}

void OpusAVCodecDecoder::OnOutputFormatChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    OH_LOG_INFO(LOG_APP, "AVCodec output format changed");
}

void OpusAVCodecDecoder::OnInputBufferAvailable(OH_AVCodec* codec, uint32_t index, 
                                                 OH_AVBuffer* buffer, void* userData) {
    OpusAVCodecDecoder* self = static_cast<OpusAVCodecDecoder*>(userData);
    if (self != nullptr) {
        std::lock_guard<std::mutex> lock(self->inputMutex_);
        self->inputIndexQueue_.push(index);
        self->inputBufferQueue_.push(buffer);
        self->inputCond_.notify_one();
    }
}

void OpusAVCodecDecoder::OnOutputBufferAvailable(OH_AVCodec* codec, uint32_t index,
                                                  OH_AVBuffer* buffer, void* userData) {
    OpusAVCodecDecoder* self = static_cast<OpusAVCodecDecoder*>(userData);
    if (self == nullptr) return;
    
    // 获取输出数据
    OH_AVCodecBufferAttr attr;
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to get buffer attr");
        OH_AudioCodec_FreeOutputBuffer(codec, index);
        return;
    }
    
    uint8_t* data = OH_AVBuffer_GetAddr(buffer);
    if (data == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to get output buffer address");
        OH_AudioCodec_FreeOutputBuffer(codec, index);
        return;
    }
    
    // 复制到输出缓冲区
    {
        std::lock_guard<std::mutex> lock(self->decodeMutex_);
        if (self->pendingPcmOutput_ != nullptr && attr.size > 0) {
            // 计算采样数（假设输出是 16-bit PCM）
            int samplesDecoded = attr.size / (sizeof(short) * self->channelCount_);
            int samplesToCopy = std::min(samplesDecoded, self->pendingMaxSamples_);
            
            memcpy(self->pendingPcmOutput_, data, samplesToCopy * self->channelCount_ * sizeof(short));
            self->decodedSamples_ = samplesToCopy;
        }
        self->decodeComplete_ = true;
        self->decodeCompleteCond_.notify_one();
    }
    
    // 释放输出缓冲区
    OH_AudioCodec_FreeOutputBuffer(codec, index);
}

// =============================================================================
// 全局简化接口
// =============================================================================

namespace {
    static OpusAVCodecDecoder* g_decoder = nullptr;
    static std::mutex g_decoderMutex;
    static OPUS_MULTISTREAM_CONFIGURATION g_opusConfig;
}

namespace OpusDecoder {

int Init(POPUS_MULTISTREAM_CONFIGURATION opusConfig) {
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    
    if (g_decoder != nullptr) {
        delete g_decoder;
    }
    
    // 保存配置
    memcpy(&g_opusConfig, opusConfig, sizeof(g_opusConfig));
    
    g_decoder = new OpusAVCodecDecoder();
    return g_decoder->Init(opusConfig);
}

int Decode(const unsigned char* opusData, int opusLength,
           short* pcmOut, int maxSamples) {
    if (g_decoder == nullptr) {
        return -1;
    }
    return g_decoder->Decode(opusData, opusLength, pcmOut, maxSamples);
}

void Cleanup() {
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    
    if (g_decoder != nullptr) {
        delete g_decoder;
        g_decoder = nullptr;
    }
}

int GetChannelCount() {
    if (g_decoder != nullptr) {
        return g_decoder->GetChannelCount();
    }
    return g_opusConfig.channelCount;
}

int GetSamplesPerFrame() {
    return g_opusConfig.samplesPerFrame;
}

} // namespace OpusDecoder
