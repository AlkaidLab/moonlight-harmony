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
 * @brief HarmonyOS AVCodec 实现的 Opus 编码器
 * 
 * 使用 HarmonyOS 原生 AVCodec API 进行 Opus 编码
 * 
 * 架构说明：
 * 按照 HarmonyOS 官方文档推荐的异步队列模式实现
 * - 回调中不进行耗时操作，只做队列入队
 * - 使用独立的编码线程处理实际编码工作
 * - NAPI 调用与编码器回调完全解耦
 */

#ifndef OPUS_ENCODER_H
#define OPUS_ENCODER_H

#include <cstdint>
#include <mutex>
#include <queue>
#include <condition_variable>
#include <atomic>
#include <thread>
#include <memory>
#include <vector>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/native_audio_channel_layout.h>

/**
 * 编码缓冲区信息（官方推荐的 CodecBufferInfo 模式）
 */
struct CodecBufferInfo {
    CodecBufferInfo() = default;
    CodecBufferInfo(uint32_t idx, OH_AVBuffer* buf) : index(idx), buffer(buf), isValid(true) {}
    
    OH_AVBuffer* buffer = nullptr;
    uint32_t index = 0;
    bool isValid = true;  // 标记缓冲区是否有效（Flush后失效）
};

/**
 * 线程安全的缓冲区队列（官方推荐的 CodecBufferQueue 模式）
 */
class CodecBufferQueue {
public:
    void Enqueue(const std::shared_ptr<CodecBufferInfo>& bufferInfo) {
        std::unique_lock<std::mutex> lock(mutex_);
        bufferQueue_.push(bufferInfo);
        cond_.notify_all();
    }
    
    std::shared_ptr<CodecBufferInfo> Dequeue(int32_t timeoutMs = 100) {
        std::unique_lock<std::mutex> lock(mutex_);
        (void)cond_.wait_for(lock, std::chrono::milliseconds(timeoutMs), 
                             [this]() { return !bufferQueue_.empty() || stopped_; });
        if (bufferQueue_.empty() || stopped_) {
            return nullptr;
        }
        auto bufferInfo = bufferQueue_.front();
        bufferQueue_.pop();
        return bufferInfo;
    }
    
    void Flush() {
        std::unique_lock<std::mutex> lock(mutex_);
        while (!bufferQueue_.empty()) {
            auto bufferInfo = bufferQueue_.front();
            bufferInfo->isValid = false;  // 标记为无效
            bufferQueue_.pop();
        }
    }
    
    void Stop() {
        std::unique_lock<std::mutex> lock(mutex_);
        stopped_ = true;
        cond_.notify_all();
    }
    
    void Reset() {
        std::unique_lock<std::mutex> lock(mutex_);
        stopped_ = false;
        while (!bufferQueue_.empty()) {
            bufferQueue_.pop();
        }
    }
    
    bool IsEmpty() {
        std::unique_lock<std::mutex> lock(mutex_);
        return bufferQueue_.empty();
    }
    
private:
    std::mutex mutex_;
    std::condition_variable cond_;
    std::queue<std::shared_ptr<CodecBufferInfo>> bufferQueue_;
    bool stopped_ = false;
};

/**
 * PCM 输入数据块
 */
struct PcmInputData {
    std::vector<uint8_t> data;
    int64_t pts = 0;
};

/**
 * 编码输出数据块
 */
struct OpusOutputData {
    std::vector<uint8_t> data;
    int64_t pts = 0;
};

/**
 * Opus 编码器类
 * 使用 HarmonyOS AVCodec API 进行 PCM 到 Opus 的编码
 * 
 * 线程模型：
 * - NAPI 线程：调用 Encode() 将 PCM 数据送入输入队列
 * - AVCodec 回调线程：将可用缓冲区送入回调队列
 * - 编码工作线程：从输入队列取数据，从回调队列取缓冲区，执行编码
 */
class OpusEncoder {
public:
    OpusEncoder();
    ~OpusEncoder();
    
    /**
     * 初始化编码器
     * @param sampleRate 采样率 (8000, 12000, 16000, 24000, 48000)
     * @param channels 通道数 (1 或 2)
     * @param bitrate 比特率 (6000-510000 bps)
     * @return 0 成功, 负数失败
     */
    int Init(int sampleRate, int channels, int bitrate);
    
    /**
     * 编码 PCM 数据（同步调用，内部异步处理）
     * @param pcmData PCM 数据 (16位有符号整数, S16LE)
     * @param pcmLength PCM 数据长度 (字节)
     * @param opusOutput 编码后的 Opus 数据输出缓冲区
     * @param maxOutputLen 输出缓冲区最大长度
     * @return 编码后的数据长度, 负数表示失败
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
    // AVCodec 编码器回调（官方推荐：只做入队，不做耗时操作）
    static void OnError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void OnOutputFormatChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void OnInputBufferAvailable(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void OnOutputBufferAvailable(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    
    // 编码工作线程
    void EncoderThreadFunc();
    
    // 编码器配置
    OH_AVCodec* encoder_ = nullptr;
    int sampleRate_ = 48000;
    int channels_ = 1;
    int bitrate_ = 64000;
    int frameSize_ = 960; // 20ms @ 48kHz
    
    // 编码器同步锁（仅用于保护 encoder_ 指针）
    std::mutex codecMutex_;
    
    // 输入/输出缓冲区队列（官方推荐模式）
    CodecBufferQueue inputBufferQueue_;   // AVCodec 回调送入的可用输入缓冲区
    CodecBufferQueue outputBufferQueue_;  // AVCodec 回调送入的编码完成缓冲区
    
    // PCM 输入数据队列（NAPI -> 编码线程）
    std::mutex pcmInputMutex_;
    std::condition_variable pcmInputCond_;
    std::queue<PcmInputData> pcmInputQueue_;
    static constexpr size_t MAX_PCM_QUEUE_SIZE = 10;
    
    // 编码输出数据队列（编码线程 -> NAPI）
    std::mutex opusOutputMutex_;
    std::condition_variable opusOutputCond_;
    std::queue<OpusOutputData> opusOutputQueue_;
    static constexpr size_t MAX_OUTPUT_QUEUE_SIZE = 10;
    
    // 编码工作线程
    std::thread encoderThread_;
    
    // 状态标志
    std::atomic<bool> initialized_{false};
    std::atomic<bool> hasError_{false};
    std::atomic<bool> stopping_{false};
    
    // 统计（用于调试）
    std::atomic<uint64_t> encodeCount_{0};
    std::atomic<uint64_t> inputCallbackCount_{0};
    std::atomic<uint64_t> outputCallbackCount_{0};
};

#endif // OPUS_ENCODER_H
