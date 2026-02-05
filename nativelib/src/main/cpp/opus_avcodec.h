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
 * @file opus_avcodec.h
 * @brief HarmonyOS AVCodec 实现的 Opus 解码器
 * 
 * 使用 HarmonyOS 原生 AVCodec API 进行 Opus 解码
 * 替代直接链接 libopus
 */

#ifndef OPUS_AVCODEC_H
#define OPUS_AVCODEC_H

#include <cstdint>
#include <mutex>
#include <queue>
#include <condition_variable>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>

extern "C" {
#include "moonlight-common-c/src/Limelight.h"
}

/**
 * AVCodec Opus 解码器封装类
 */
class OpusAVCodecDecoder {
public:
    OpusAVCodecDecoder();
    ~OpusAVCodecDecoder();
    
    /**
     * 初始化解码器
     * @param opusConfig Opus 配置
     * @return 0 成功，负数失败
     */
    int Init(POPUS_MULTISTREAM_CONFIGURATION opusConfig);
    
    /**
     * 解码 Opus 数据
     * @param opusData 输入 Opus 数据
     * @param opusLength 数据长度
     * @param pcmOut 输出 PCM 缓冲区（调用者分配）
     * @param maxSamples 最大采样数
     * @return 解码的采样数，负数表示失败
     */
    int Decode(const unsigned char* opusData, int opusLength, 
               short* pcmOut, int maxSamples);
    
    /**
     * 清理解码器
     */
    void Cleanup();
    
    /**
     * 检查是否已初始化
     */
    bool IsInitialized() const { return decoder_ != nullptr; }
    
    /**
     * 获取通道数
     */
    int GetChannelCount() const { return channelCount_; }
    
    /**
     * 获取采样率
     */
    int GetSampleRate() const { return sampleRate_; }
    
private:
    // AVCodec 回调
    static void OnError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void OnOutputFormatChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void OnInputBufferAvailable(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* data, void* userData);
    static void OnOutputBufferAvailable(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* data, void* userData);
    
    // 内部方法
    void ProcessInputBuffer(uint32_t index, OH_AVBuffer* buffer);
    void ProcessOutputBuffer(uint32_t index, OH_AVBuffer* buffer);
    
    // 解码器实例
    OH_AVCodec* decoder_ = nullptr;
    
    // 配置参数
    int sampleRate_ = 48000;
    int channelCount_ = 2;
    int samplesPerFrame_ = 240;
    
    // 输入/输出队列
    std::mutex inputMutex_;
    std::mutex outputMutex_;
    std::condition_variable inputCond_;
    std::condition_variable outputCond_;
    std::queue<uint32_t> inputIndexQueue_;
    std::queue<OH_AVBuffer*> inputBufferQueue_;
    std::queue<uint32_t> outputIndexQueue_;
    std::queue<OH_AVBuffer*> outputBufferQueue_;
    
    // 同步解码
    std::mutex decodeMutex_;
    short* pendingPcmOutput_ = nullptr;
    int pendingMaxSamples_ = 0;
    int decodedSamples_ = 0;
    bool decodeComplete_ = false;
    std::condition_variable decodeCompleteCond_;
    
    // 是否运行中
    bool running_ = false;
};

/**
 * 全局 Opus 解码器实例（简化接口）
 */
namespace OpusDecoder {
    /**
     * 初始化解码器
     */
    int Init(POPUS_MULTISTREAM_CONFIGURATION opusConfig);
    
    /**
     * 解码 Opus 数据
     */
    int Decode(const unsigned char* opusData, int opusLength,
               short* pcmOut, int maxSamples);
    
    /**
     * 清理解码器
     */
    void Cleanup();
    
    /**
     * 获取通道数
     */
    int GetChannelCount();
    
    /**
     * 获取每帧采样数
     */
    int GetSamplesPerFrame();
}

#endif // OPUS_AVCODEC_H
