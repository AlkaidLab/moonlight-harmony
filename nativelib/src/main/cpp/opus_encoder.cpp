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
 * @brief HarmonyOS AVCodec 实现的 Opus 编码器
 * 
 * 使用 HarmonyOS 原生 AVCodec API 进行 Opus 编码
 * 
 * 按照 HarmonyOS 官方文档推荐的异步队列模式实现：
 * https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/audio-encoding-V5
 * 
 * 核心设计原则：
 * 1. "回调中不建议进行耗时操作" - 回调只做入队
 * 2. 使用线程安全的队列解耦回调线程与工作线程
 * 3. 独立的编码工作线程处理实际数据
 */

#include "opus_encoder.h"
#include <hilog/log.h>
#include <cstring>
#include <chrono>

#define LOG_TAG "OpusEncoder"

// =============================================================================
// OpusEncoder 类实现
// =============================================================================

OpusEncoder::OpusEncoder() {
    OH_LOG_INFO(LOG_APP, "OpusEncoder constructor");
}

OpusEncoder::~OpusEncoder() {
    OH_LOG_INFO(LOG_APP, "OpusEncoder destructor");
    Cleanup();
}

int OpusEncoder::Init(int sampleRate, int channels, int bitrate) {
    OH_LOG_INFO(LOG_APP, "Init: sampleRate=%{public}d, channels=%{public}d, bitrate=%{public}d",
                sampleRate, channels, bitrate);
    
    if (initialized_.load(std::memory_order_acquire)) {
        OH_LOG_WARN(LOG_APP, "Opus encoder already initialized");
        return 0;
    }
    
    // 保存配置
    sampleRate_ = sampleRate;
    channels_ = channels;
    bitrate_ = bitrate;
    frameSize_ = sampleRate / 50; // 20ms 帧
    
    // 重置状态
    stopping_.store(false, std::memory_order_release);
    hasError_.store(false, std::memory_order_release);
    encodeCount_.store(0);
    inputCallbackCount_.store(0);
    outputCallbackCount_.store(0);
    
    // 重置队列
    inputBufferQueue_.Reset();
    outputBufferQueue_.Reset();
    
    {
        std::lock_guard<std::mutex> lock(pcmInputMutex_);
        while (!pcmInputQueue_.empty()) pcmInputQueue_.pop();
    }
    {
        std::lock_guard<std::mutex> lock(opusOutputMutex_);
        while (!opusOutputQueue_.empty()) opusOutputQueue_.pop();
    }
    
    // 创建 Opus 编码器
    {
        std::lock_guard<std::mutex> lock(codecMutex_);
        
        encoder_ = OH_AudioCodec_CreateByMime(OH_AVCODEC_MIMETYPE_AUDIO_OPUS, true);
        if (encoder_ == nullptr) {
            OH_LOG_ERROR(LOG_APP, "Failed to create Opus encoder");
            return -1;
        }
        
        // 注册回调
        OH_AVCodecCallback callback = {
            .onError = OnError,
            .onStreamChanged = OnOutputFormatChanged,
            .onNeedInputBuffer = OnInputBufferAvailable,
            .onNewOutputBuffer = OnOutputBufferAvailable
        };
        
        int32_t ret = OH_AudioCodec_RegisterCallback(encoder_, callback, this);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "Failed to register callback: %{public}d", ret);
            OH_AudioCodec_Destroy(encoder_);
            encoder_ = nullptr;
            return -1;
        }
        
        // 配置编码器
        OH_AVFormat* format = OH_AVFormat_Create();
        if (format == nullptr) {
            OH_LOG_ERROR(LOG_APP, "Failed to create AVFormat");
            OH_AudioCodec_Destroy(encoder_);
            encoder_ = nullptr;
            return -1;
        }
        
        // 设置必需参数（根据官方文档）
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, sampleRate_);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, channels_);
        OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE, bitrate_);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, 1); // SAMPLE_S16LE
        
        // 设置通道布局
        if (channels_ == 1) {
            OH_AVFormat_SetLongValue(format, OH_MD_KEY_CHANNEL_LAYOUT, CH_LAYOUT_MONO);
        } else {
            OH_AVFormat_SetLongValue(format, OH_MD_KEY_CHANNEL_LAYOUT, CH_LAYOUT_STEREO);
        }
        
        // 设置最大输入缓冲区大小 (20ms 帧 * 2 字节/样本 * 通道数)
        int maxInputSize = frameSize_ * 2 * channels_;
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE, maxInputSize);
        
        ret = OH_AudioCodec_Configure(encoder_, format);
        OH_AVFormat_Destroy(format);
        
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "Failed to configure encoder: %{public}d", ret);
            OH_AudioCodec_Destroy(encoder_);
            encoder_ = nullptr;
            return -1;
        }
        
        // 准备编码器
        ret = OH_AudioCodec_Prepare(encoder_);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "Failed to prepare encoder: %{public}d", ret);
            OH_AudioCodec_Destroy(encoder_);
            encoder_ = nullptr;
            return -1;
        }
        
        // 启动编码器
        ret = OH_AudioCodec_Start(encoder_);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "Failed to start encoder: %{public}d", ret);
            OH_AudioCodec_Destroy(encoder_);
            encoder_ = nullptr;
            return -1;
        }
    }
    
    // 启动编码工作线程
    encoderThread_ = std::thread(&OpusEncoder::EncoderThreadFunc, this);
    
    initialized_.store(true, std::memory_order_release);
    OH_LOG_INFO(LOG_APP, "Opus encoder initialized successfully");
    return 0;
}

void OpusEncoder::EncoderThreadFunc() {
    OH_LOG_INFO(LOG_APP, "Encoder thread started");
    
    while (!stopping_.load(std::memory_order_acquire)) {
        // 1. 等待 PCM 输入数据
        PcmInputData pcmInput;
        {
            std::unique_lock<std::mutex> lock(pcmInputMutex_);
            if (!pcmInputCond_.wait_for(lock, std::chrono::milliseconds(50), [this] {
                return !pcmInputQueue_.empty() || stopping_.load(std::memory_order_acquire);
            })) {
                continue;  // 超时，重新检查
            }
            
            if (stopping_.load(std::memory_order_acquire)) {
                break;
            }
            
            if (pcmInputQueue_.empty()) {
                continue;
            }
            
            pcmInput = std::move(pcmInputQueue_.front());
            pcmInputQueue_.pop();
        }
        
        // 2. 获取可用的输入缓冲区（从 AVCodec 回调队列）
        auto inputBufInfo = inputBufferQueue_.Dequeue(100);
        if (inputBufInfo == nullptr || !inputBufInfo->isValid) {
            // 没有可用缓冲区，将数据放回队列（或丢弃）
            OH_LOG_WARN(LOG_APP, "No input buffer available, dropping PCM data");
            continue;
        }
        
        // 3. 填充数据到输入缓冲区
        OH_AVBuffer* buffer = inputBufInfo->buffer;
        if (buffer == nullptr) {
            OH_LOG_ERROR(LOG_APP, "Input buffer is null");
            continue;
        }
        
        int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
        if (capacity < static_cast<int32_t>(pcmInput.data.size())) {
            OH_LOG_ERROR(LOG_APP, "Buffer capacity %{public}d < data size %{public}zu", 
                         capacity, pcmInput.data.size());
            continue;
        }
        
        uint8_t* bufferData = OH_AVBuffer_GetAddr(buffer);
        if (bufferData == nullptr) {
            OH_LOG_ERROR(LOG_APP, "Failed to get buffer address");
            continue;
        }
        
        memcpy(bufferData, pcmInput.data.data(), pcmInput.data.size());
        
        OH_AVCodecBufferAttr attr;
        memset(&attr, 0, sizeof(attr));
        attr.pts = pcmInput.pts;
        attr.size = static_cast<int32_t>(pcmInput.data.size());
        attr.offset = 0;
        attr.flags = 0;
        
        int32_t ret = OH_AVBuffer_SetBufferAttr(buffer, &attr);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "Failed to set buffer attr: %{public}d", ret);
            continue;
        }
        
        // 4. 提交输入缓冲区给编码器
        {
            std::lock_guard<std::mutex> lock(codecMutex_);
            if (encoder_ != nullptr && !stopping_.load(std::memory_order_acquire)) {
                ret = OH_AudioCodec_PushInputBuffer(encoder_, inputBufInfo->index);
                if (ret != AV_ERR_OK) {
                    OH_LOG_ERROR(LOG_APP, "Failed to push input buffer: %{public}d", ret);
                }
            }
        }
    }
    
    OH_LOG_INFO(LOG_APP, "Encoder thread exiting");
}

int OpusEncoder::Encode(const uint8_t* pcmData, int pcmLength, uint8_t* opusOutput, int maxOutputLen) {
    // 验证输入参数
    if (pcmData == nullptr || pcmLength <= 0 || opusOutput == nullptr || maxOutputLen <= 0) {
        return -1;
    }
    
    // 检查状态
    if (!initialized_.load(std::memory_order_acquire) || 
        hasError_.load(std::memory_order_acquire) ||
        stopping_.load(std::memory_order_acquire)) {
        return -1;
    }
    
    // 1. 将 PCM 数据送入输入队列
    {
        std::lock_guard<std::mutex> lock(pcmInputMutex_);
        
        // 如果队列满了，丢弃最旧的数据
        if (pcmInputQueue_.size() >= MAX_PCM_QUEUE_SIZE) {
            pcmInputQueue_.pop();
            OH_LOG_WARN(LOG_APP, "PCM input queue full, dropping oldest frame");
        }
        
        PcmInputData inputData;
        inputData.data.assign(pcmData, pcmData + pcmLength);
        inputData.pts = encodeCount_.fetch_add(1) * 20000; // 20ms per frame
        pcmInputQueue_.push(std::move(inputData));
    }
    pcmInputCond_.notify_one();
    
    // 2. 尝试从输出队列获取编码结果
    {
        std::unique_lock<std::mutex> lock(opusOutputMutex_);
        
        // 等待一小段时间获取输出
        if (!opusOutputCond_.wait_for(lock, std::chrono::milliseconds(50), [this] {
            return !opusOutputQueue_.empty() || hasError_.load(std::memory_order_acquire);
        })) {
            // 超时，返回 0 表示暂无数据
            return 0;
        }
        
        if (hasError_.load(std::memory_order_acquire) || opusOutputQueue_.empty()) {
            return opusOutputQueue_.empty() ? 0 : -1;
        }
        
        OpusOutputData outputData = std::move(opusOutputQueue_.front());
        opusOutputQueue_.pop();
        
        int outputLen = std::min(static_cast<int>(outputData.data.size()), maxOutputLen);
        memcpy(opusOutput, outputData.data.data(), outputLen);
        return outputLen;
    }
}

void OpusEncoder::Cleanup() {
    OH_LOG_INFO(LOG_APP, "Cleanup starting, encodeCount=%{public}llu, inputCb=%{public}llu, outputCb=%{public}llu",
                static_cast<unsigned long long>(encodeCount_.load()),
                static_cast<unsigned long long>(inputCallbackCount_.load()),
                static_cast<unsigned long long>(outputCallbackCount_.load()));
    
    // 1. 设置停止标志
    stopping_.store(true, std::memory_order_release);
    initialized_.store(false, std::memory_order_release);
    
    // 2. 停止队列
    inputBufferQueue_.Stop();
    outputBufferQueue_.Stop();
    
    // 3. 唤醒等待的线程
    pcmInputCond_.notify_all();
    opusOutputCond_.notify_all();
    
    // 4. 等待编码线程结束
    if (encoderThread_.joinable()) {
        OH_LOG_INFO(LOG_APP, "Waiting for encoder thread to exit");
        encoderThread_.join();
        OH_LOG_INFO(LOG_APP, "Encoder thread exited");
    }
    
    // 5. 停止和销毁编码器
    OH_AVCodec* encoderToDestroy = nullptr;
    {
        std::lock_guard<std::mutex> lock(codecMutex_);
        encoderToDestroy = encoder_;
        encoder_ = nullptr;
    }
    
    if (encoderToDestroy != nullptr) {
        OH_LOG_INFO(LOG_APP, "Stopping encoder");
        OH_AudioCodec_Stop(encoderToDestroy);
        
        // 等待一下让内部状态稳定
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        
        OH_LOG_INFO(LOG_APP, "Destroying encoder");
        OH_AudioCodec_Destroy(encoderToDestroy);
    }
    
    // 6. 清空队列
    inputBufferQueue_.Flush();
    outputBufferQueue_.Flush();
    
    {
        std::lock_guard<std::mutex> lock(pcmInputMutex_);
        while (!pcmInputQueue_.empty()) pcmInputQueue_.pop();
    }
    {
        std::lock_guard<std::mutex> lock(opusOutputMutex_);
        while (!opusOutputQueue_.empty()) opusOutputQueue_.pop();
    }
    
    OH_LOG_INFO(LOG_APP, "Cleanup completed");
}

// =============================================================================
// AVCodec 回调实现
// 官方文档强调："回调中不建议进行耗时操作"
// 因此这里只做简单的入队操作
// =============================================================================

void OpusEncoder::OnError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    auto* self = static_cast<OpusEncoder*>(userData);
    if (self == nullptr) {
        return;
    }
    
    OH_LOG_ERROR(LOG_APP, "Encoder error: %{public}d", errorCode);
    
    // 只设置错误标志，不做其他操作
    self->hasError_.store(true, std::memory_order_release);
    
    // 唤醒等待的线程
    self->pcmInputCond_.notify_all();
    self->opusOutputCond_.notify_all();
    self->inputBufferQueue_.Stop();
    self->outputBufferQueue_.Stop();
}

void OpusEncoder::OnOutputFormatChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    OH_LOG_INFO(LOG_APP, "Output format changed");
    // 格式变化通常不需要特殊处理
}

void OpusEncoder::OnInputBufferAvailable(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    auto* self = static_cast<OpusEncoder*>(userData);
    if (self == nullptr || buffer == nullptr) {
        return;
    }
    
    // 快速检查是否应该处理
    if (self->stopping_.load(std::memory_order_acquire) || 
        self->hasError_.load(std::memory_order_acquire)) {
        return;
    }
    
    // 只做入队操作（官方推荐）
    self->inputBufferQueue_.Enqueue(std::make_shared<CodecBufferInfo>(index, buffer));
    self->inputCallbackCount_.fetch_add(1, std::memory_order_relaxed);
}

void OpusEncoder::OnOutputBufferAvailable(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    auto* self = static_cast<OpusEncoder*>(userData);
    if (self == nullptr || buffer == nullptr) {
        return;
    }
    
    // 快速检查是否应该处理
    if (self->stopping_.load(std::memory_order_acquire) || 
        self->hasError_.load(std::memory_order_acquire)) {
        return;
    }
    
    self->outputCallbackCount_.fetch_add(1, std::memory_order_relaxed);
    
    // 获取编码后的数据
    OH_AVCodecBufferAttr attr;
    memset(&attr, 0, sizeof(attr));
    
    int32_t ret = OH_AVBuffer_GetBufferAttr(buffer, &attr);
    if (ret == AV_ERR_OK && attr.size > 0) {
        uint8_t* data = OH_AVBuffer_GetAddr(buffer);
        if (data != nullptr) {
            // 复制数据到输出队列
            OpusOutputData outputData;
            outputData.data.assign(data, data + attr.size);
            outputData.pts = attr.pts;
            
            {
                std::lock_guard<std::mutex> lock(self->opusOutputMutex_);
                
                // 如果队列满了，丢弃最旧的数据
                if (self->opusOutputQueue_.size() >= MAX_OUTPUT_QUEUE_SIZE) {
                    self->opusOutputQueue_.pop();
                }
                
                self->opusOutputQueue_.push(std::move(outputData));
            }
            self->opusOutputCond_.notify_one();
        }
    }
    
    // 释放输出缓冲区（必须在回调中调用）
    {
        std::lock_guard<std::mutex> lock(self->codecMutex_);
        if (self->encoder_ != nullptr && !self->stopping_.load(std::memory_order_acquire)) {
            OH_AudioCodec_FreeOutputBuffer(self->encoder_, index);
        }
    }
}
