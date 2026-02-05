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
 * @file audio_renderer.h
 * @brief HarmonyOS OHAudio 音频渲染器
 * 
 * 使用 HarmonyOS OHAudio API 播放解码后的 PCM 音频数据
 */

#ifndef AUDIO_RENDERER_H
#define AUDIO_RENDERER_H

#include <cstdint>
#include <mutex>
#include <queue>
#include <atomic>
#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>

/**
 * 音频配置
 */
struct AudioRendererConfig {
    int sampleRate;           // 采样率（如 48000）
    int channelCount;         // 声道数（如 2）
    int samplesPerFrame;      // 每帧采样数
    int bitsPerSample;        // 每采样位数（通常 16）
    float volume;             // 音量 (0.0 - 1.0, 默认 1.0)
    bool enableSpatialAudio;  // 是否启用空间音频（HarmonyOS 5.0+）
};

/**
 * 音频统计信息
 */
struct AudioRendererStats {
    uint64_t totalSamples;
    uint64_t playedSamples;
    uint64_t droppedSamples;
    uint32_t underruns;
    double latencyMs;
};

/**
 * OHAudio 音频渲染器封装类
 */
class AudioRenderer {
public:
    AudioRenderer();
    ~AudioRenderer();
    
    /**
     * 初始化音频渲染器
     * @param config 音频配置
     * @return 0 成功，负数失败
     */
    int Init(const AudioRendererConfig& config);
    
    /**
     * 启动音频播放
     */
    int Start();
    
    /**
     * 设置音量
     * @param volume 音量 (0.0 - 1.0)
     * @return 0 成功，负数失败
     */
    int SetVolume(float volume);
    
    /**
     * 停止音频播放
     */
    int Stop();
    
    /**
     * 清理音频渲染器
     */
    void Cleanup();
    
    /**
     * 播放 PCM 数据
     * @param pcmData PCM 数据（16-bit signed）
     * @param sampleCount 采样数
     * @return 0 成功，负数失败
     */
    int PlaySamples(const int16_t* pcmData, int sampleCount);
    
    /**
     * 获取统计信息
     */
    AudioRendererStats GetStats() const;
    
    /**
     * 检查是否已初始化
     */
    bool IsInitialized() const { return renderer_ != nullptr; }
    
    /**
     * 检查是否正在运行
     */
    bool IsRunning() const { return running_; }

private:
    // OHAudio 回调
    static int32_t OnWriteData(OH_AudioRenderer* renderer, void* userData,
                               void* buffer, int32_t bufferLen);
    static int32_t OnStreamEvent(OH_AudioRenderer* renderer, void* userData,
                                  OH_AudioStream_Event event);
    static int32_t OnInterruptEvent(OH_AudioRenderer* renderer, void* userData,
                                     OH_AudioInterrupt_ForceType type,
                                     OH_AudioInterrupt_Hint hint);
    static int32_t OnError(OH_AudioRenderer* renderer, void* userData,
                            OH_AudioStream_Result error);
    
    // 音频渲染器实例
    OH_AudioRenderer* renderer_ = nullptr;
    OH_AudioStreamBuilder* builder_ = nullptr;
    
    // 配置
    AudioRendererConfig config_;
    
    // PCM 数据队列
    mutable std::mutex queueMutex_;
    std::queue<std::pair<int16_t*, int>> pcmQueue_;  // 数据和采样数
    static constexpr int MAX_QUEUE_SIZE = 16;
    
    // 统计信息
    mutable std::mutex statsMutex_;
    AudioRendererStats stats_;
    
    // 运行状态
    std::atomic<bool> running_{false};
    std::atomic<bool> configured_{false};
};

/**
 * 全局音频渲染器实例（简化接口）
 */
namespace AudioRendererInstance {
    /**
     * 设置是否启用空间音频（在 Init 之前调用）
     * @param enabled 是否启用
     */
    void SetSpatialAudioEnabled(bool enabled);
    
    /**
     * 获取空间音频是否启用
     */
    bool IsSpatialAudioEnabled();
    
    /**
     * 初始化音频渲染器
     */
    int Init(int sampleRate, int channelCount, int samplesPerFrame);
    
    /**
     * 设置音量
     * @param volume 音量 (0.0 - 1.0)
     */
    int SetVolume(float volume);
    
    /**
     * 播放 PCM 数据
     */
    int PlaySamples(const int16_t* pcmData, int sampleCount);
    
    /**
     * 启动音频播放
     */
    int Start();
    
    /**
     * 停止音频播放
     */
    int Stop();
    
    /**
     * 清理音频渲染器
     */
    void Cleanup();
    
    /**
     * 获取统计信息
     */
    AudioRendererStats GetStats();
}

#endif // AUDIO_RENDERER_H
