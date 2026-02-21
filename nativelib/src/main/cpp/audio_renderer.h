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
 * 
 * 性能优化：
 * - 无锁环形缓冲区替代 std::queue + new/delete，消除每帧堆分配
 * - 音频工作组 (AudioWorkgroup) 集成，保障音频线程调度优先级
 * - 始终设置 QoS_USER_INTERACTIVE，降低回调延迟
 */

#ifndef AUDIO_RENDERER_H
#define AUDIO_RENDERER_H

#include <cstdint>
#include <mutex>
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
    double latencyMs;         // 当前环形缓冲区中的音频延迟（毫秒）
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
    
    // =========================================================================
    // 无锁环形缓冲区（SPSC: 单生产者单消费者）
    // 生产者: PlaySamples() (解码线程)
    // 消费者: OnWriteData() (OHAudio 音频回调线程)
    // =========================================================================
    // 缓冲区容量：16帧 × 最大8声道 × 240采样/帧 = 30720 采样
    // 对于 stereo: 30720/2 = 15360 samples = 320ms @48kHz
    // 对于 5.1:   30720/6 = 5120 samples = 106ms
    // 对于 7.1:   30720/8 = 3840 samples = 80ms
    // 较大的缓冲可吸收视频帧率波动导致的音频解码延迟抖动
    static constexpr int MAX_BUFFER_FRAMES = 16;
    static constexpr int MAX_CHANNELS = 8;
    static constexpr int MAX_SAMPLES_PER_FRAME = 240;
    static constexpr int RING_BUFFER_CAPACITY = MAX_BUFFER_FRAMES * MAX_CHANNELS * MAX_SAMPLES_PER_FRAME;
    
    int16_t ringBuffer_[RING_BUFFER_CAPACITY];
    std::atomic<int> ringHead_{0};  // 消费者读位置（OnWriteData 更新）
    std::atomic<int> ringTail_{0};  // 生产者写位置（PlaySamples 更新）
    
    // 统计信息（原子操作避免锁）
    std::atomic<uint64_t> totalSamples_{0};
    std::atomic<uint64_t> playedSamples_{0};
    std::atomic<uint64_t> droppedSamples_{0};
    std::atomic<uint32_t> underruns_{0};
    
    // Underrun 拗音消除：记录上次回调是否 underrun，用于恢复时渐入
    bool wasUnderrun_{false};
    
    // 运行状态
    std::atomic<bool> running_{false};
    std::atomic<bool> configured_{false};
    
    // 错误恢复
    std::atomic<bool> needRestart_{false};
    std::atomic<int> consecutiveErrors_{0};
    static constexpr int MAX_ERRORS_BEFORE_RESTART = 3;
    
    /**
     * 尝试重启音频渲染器（内部使用）
     * @return 0 成功，负数失败
     */
    int TryRestart();
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
