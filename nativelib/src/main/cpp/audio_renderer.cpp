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
 * @file audio_renderer.cpp
 * @brief HarmonyOS OHAudio 音频渲染器实现
 * 
 * 性能优化：
 * - 无锁环形缓冲区（SPSC）替代 std::queue + new/delete
 * - 音频工作组集成，保障回调线程调度
 * - 始终设置 QoS USER_INTERACTIVE
 */

#include "audio_renderer.h"
#include <hilog/log.h>
#include <cstring>
#include <dlfcn.h>
#include <qos/qos.h>
#include <algorithm>

#define LOG_TAG "AudioRenderer"

// =============================================================================
// API 20+ 空间音频支持（动态加载）
// =============================================================================

// 函数指针类型定义
typedef OH_AudioStream_Result (*PFN_OH_AudioStreamBuilder_SetSpatializationEnabled)(
    OH_AudioStreamBuilder* builder, bool spatializationEnabled);

// 全局函数指针
static PFN_OH_AudioStreamBuilder_SetSpatializationEnabled g_pfnSetSpatializationEnabled = nullptr;
static bool g_spatialAudioChecked = false;
static bool g_spatialAudioAvailable = false;

// 检查并加载空间音频 API
static bool CheckAndLoadSpatialAudioApi() {
    if (g_spatialAudioChecked) {
        return g_spatialAudioAvailable;
    }
    g_spatialAudioChecked = true;
    
    void* handle = dlopen("libohaudio.so", RTLD_NOW);
    if (handle != nullptr) {
        g_pfnSetSpatializationEnabled = (PFN_OH_AudioStreamBuilder_SetSpatializationEnabled)
            dlsym(handle, "OH_AudioStreamBuilder_SetSpatializationEnabled");
        if (g_pfnSetSpatializationEnabled != nullptr) {
            g_spatialAudioAvailable = true;
            OH_LOG_INFO(LOG_APP, "API 20+ Spatial Audio API available");
        } else {
            OH_LOG_WARN(LOG_APP, "Spatial Audio API not found (API < 20)");
        }
        // 不要 dlclose，保持库加载
    } else {
        OH_LOG_WARN(LOG_APP, "Failed to load libohaudio.so for spatial audio check");
    }
    
    return g_spatialAudioAvailable;
}

// =============================================================================
// AudioRenderer 类实现
// =============================================================================

AudioRenderer::AudioRenderer() {
    memset(ringBuffer_, 0, sizeof(ringBuffer_));
}

AudioRenderer::~AudioRenderer() {
    Cleanup();
}

int AudioRenderer::Init(const AudioRendererConfig& config) {
    if (renderer_ != nullptr) {
        OH_LOG_WARN(LOG_APP, "AudioRenderer already initialized, cleaning up first to reinitialize");
        Cleanup();  // 清理旧实例后重新初始化，防止重复进入串流时音频问题
    }
    
    config_ = config;
    
    OH_LOG_INFO(LOG_APP, "Initializing audio renderer: sampleRate=%{public}d, channels=%{public}d, samplesPerFrame=%{public}d",
                config_.sampleRate, config_.channelCount, config_.samplesPerFrame);
    
    // 创建 AudioStreamBuilder
    OH_AudioStream_Result result = OH_AudioStreamBuilder_Create(&builder_, AUDIOSTREAM_TYPE_RENDERER);
    if (result != AUDIOSTREAM_SUCCESS || builder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to create AudioStreamBuilder: %{public}d", result);
        return -1;
    }
    
    // 设置采样率
    result = OH_AudioStreamBuilder_SetSamplingRate(builder_, config_.sampleRate);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to set sampling rate: %{public}d", result);
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        return -1;
    }
    
    // 设置声道数
    result = OH_AudioStreamBuilder_SetChannelCount(builder_, config_.channelCount);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to set channel count: %{public}d", result);
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        return -1;
    }
    
    // 设置声道布局
    // 根据声道数选择对应的声道布局
    // HarmonyOS 支持的布局: CH_LAYOUT_MONO(1), CH_LAYOUT_STEREO(2), 
    // CH_LAYOUT_5POINT1(6), CH_LAYOUT_7POINT1(8) 等
    OH_AudioChannelLayout channelLayout;
    switch (config_.channelCount) {
        case 1:
            channelLayout = CH_LAYOUT_MONO;
            break;
        case 2:
            channelLayout = CH_LAYOUT_STEREO;
            break;
        case 6:
            // 5.1 环绕声: FL, FR, FC, LFE, BL, BR
            channelLayout = CH_LAYOUT_5POINT1;
            break;
        case 8:
            // 7.1 环绕声: FL, FR, FC, LFE, BL, BR, SL, SR
            channelLayout = CH_LAYOUT_7POINT1;
            break;
        default:
            // 对于不支持的声道数，使用 UNKNOWN 让系统自动选择
            OH_LOG_WARN(LOG_APP, "Unsupported channel count %{public}d, using CH_LAYOUT_UNKNOWN", 
                        config_.channelCount);
            channelLayout = CH_LAYOUT_UNKNOWN;
            break;
    }
    
    OH_LOG_INFO(LOG_APP, "Setting channel layout for %{public}d channels: 0x%{public}llx",
                config_.channelCount, static_cast<long long>(channelLayout));
    
    result = OH_AudioStreamBuilder_SetChannelLayout(builder_, channelLayout);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to set channel layout: %{public}d", result);
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        return -1;
    }
    
    // 设置采样格式（16-bit PCM）
    result = OH_AudioStreamBuilder_SetSampleFormat(builder_, AUDIOSTREAM_SAMPLE_S16LE);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to set sample format: %{public}d", result);
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        return -1;
    }
    
    // 设置编码类型（PCM）
    result = OH_AudioStreamBuilder_SetEncodingType(builder_, AUDIOSTREAM_ENCODING_TYPE_RAW);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to set encoding type: %{public}d", result);
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        return -1;
    }
    
    // 设置用途（游戏）
    result = OH_AudioStreamBuilder_SetRendererInfo(builder_, AUDIOSTREAM_USAGE_GAME);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "Failed to set renderer usage: %{public}d", result);
        // 非致命错误，继续
    }
    
    // 设置低延迟模式
    // 注意：当启用空间音频时使用 NORMAL 模式，因为 FAST 模式会绕过 DSP 空间化处理管线
    OH_AudioStream_LatencyMode latencyMode = config_.enableSpatialAudio 
        ? AUDIOSTREAM_LATENCY_MODE_NORMAL 
        : AUDIOSTREAM_LATENCY_MODE_FAST;
    result = OH_AudioStreamBuilder_SetLatencyMode(builder_, latencyMode);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "Failed to set latency mode: %{public}d", result);
        // 非致命错误，继续
    } else {
        OH_LOG_INFO(LOG_APP, "Audio latency mode: %{public}s",
                    latencyMode == AUDIOSTREAM_LATENCY_MODE_FAST ? "FAST" : "NORMAL (spatial audio)");
    }
    
    // 设置回调帧大小（API 12+）
    // 匹配 Opus 解码帧大小（通常 240 samples = 5ms @48kHz），
    // 减少 OHAudio 内部缓冲，降低音频管线延迟
    result = OH_AudioStreamBuilder_SetFrameSizeInCallback(builder_, config_.samplesPerFrame);
    if (result == AUDIOSTREAM_SUCCESS) {
        OH_LOG_INFO(LOG_APP, "Audio callback frame size set to %{public}d samples", config_.samplesPerFrame);
    } else {
        OH_LOG_WARN(LOG_APP, "Failed to set callback frame size: %{public}d (using system default)", result);
    }
    
    // 尝试启用空间音频（HarmonyOS 5.0+ API 20）
    if (config_.enableSpatialAudio && CheckAndLoadSpatialAudioApi() && g_pfnSetSpatializationEnabled != nullptr) {
        result = g_pfnSetSpatializationEnabled(builder_, true);
        if (result == AUDIOSTREAM_SUCCESS) {
            OH_LOG_INFO(LOG_APP, "Spatial audio enabled successfully");
        } else {
            OH_LOG_WARN(LOG_APP, "Failed to enable spatial audio: %{public}d", result);
        }
    } else if (config_.enableSpatialAudio) {
        OH_LOG_INFO(LOG_APP, "Spatial audio not available on this device/API level");
    }
    
    // 设置回调 (API 12+ 新版独立回调设置)
    // 数据写入回调
    result = OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder_,
        (OH_AudioRenderer_OnWriteDataCallback)OnWriteData, this);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to set write data callback: %{public}d", result);
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        return -1;
    }
    
    // 中断事件回调
    result = OH_AudioStreamBuilder_SetRendererInterruptCallback(builder_,
        (OH_AudioRenderer_OnInterruptCallback)OnInterruptEvent, this);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "Failed to set interrupt callback: %{public}d", result);
    }
    
    // 错误回调
    result = OH_AudioStreamBuilder_SetRendererErrorCallback(builder_,
        (OH_AudioRenderer_OnErrorCallback)OnError, this);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "Failed to set error callback: %{public}d", result);
    }
    
    // 设备变更回调（替代旧版 OnStreamEvent）
    result = OH_AudioStreamBuilder_SetRendererOutputDeviceChangeCallback(builder_,
        (OH_AudioRenderer_OutputDeviceChangeCallback)OnDeviceChange, this);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "Failed to set device change callback: %{public}d", result);
    }
    
    // 创建渲染器
    result = OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_);
    if (result != AUDIOSTREAM_SUCCESS || renderer_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to generate renderer: %{public}d", result);
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        return -1;
    }
    
    // 设置初始音量（如果配置了）
    if (config_.volume > 0.0f && config_.volume <= 1.0f) {
        SetVolume(config_.volume);
    }
    
    configured_ = true;
    OH_LOG_INFO(LOG_APP, "Audio renderer initialized successfully");
    
    return 0;
}

int AudioRenderer::SetVolume(float volume) {
    if (renderer_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Renderer not initialized");
        return -1;
    }
    
    // 限制音量范围
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    
    OH_AudioStream_Result result = OH_AudioRenderer_SetVolume(renderer_, volume);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to set volume to %{public}f: %{public}d", volume, result);
        return -1;
    }
    
    OH_LOG_INFO(LOG_APP, "Audio volume set to: %{public}f", volume);
    return 0;
}

int AudioRenderer::Start() {
    if (!configured_ || renderer_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Renderer not configured");
        return -1;
    }
    
    // 清空 OHAudio 内部缓冲，避免播放旧数据导致初始延迟
    OH_AudioRenderer_Flush(renderer_);
    
    // 清空环形缓冲区
    ringHead_.store(0, std::memory_order_relaxed);
    ringTail_.store(0, std::memory_order_relaxed);
    wasUnderrun_.store(false, std::memory_order_relaxed);
    
    OH_AudioStream_Result result = OH_AudioRenderer_Start(renderer_);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to start renderer: %{public}d", result);
        return -1;
    }
    
    running_ = true;
    needRestart_ = false;
    consecutiveErrors_ = 0;
    OH_LOG_INFO(LOG_APP, "Audio renderer started");
    
    return 0;
}

int AudioRenderer::Stop() {
    running_ = false;
    
    if (renderer_ != nullptr) {
        OH_AudioRenderer_Stop(renderer_);
    }
    
    // 清空环形缓冲区
    ringHead_.store(0, std::memory_order_relaxed);
    ringTail_.store(0, std::memory_order_relaxed);
    wasUnderrun_.store(false, std::memory_order_relaxed);
    
    OH_LOG_INFO(LOG_APP, "Audio renderer stopped");
    return 0;
}

void AudioRenderer::Cleanup() {
    Stop();
    
    if (renderer_ != nullptr) {
        OH_AudioRenderer_Release(renderer_);
        renderer_ = nullptr;
    }
    
    if (builder_ != nullptr) {
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
    }
    
    configured_ = false;
    
    OH_LOG_INFO(LOG_APP, "Audio renderer cleaned up");
}

int AudioRenderer::PlaySamples(const int16_t* pcmData, int sampleCount) {
    if (renderer_ == nullptr) {
        return -1;
    }
    
    // 如果需要重启，尝试恢复
    if (needRestart_.load(std::memory_order_relaxed)) {
        TryRestart();
    }
    
    if (!running_) {
        return -1;
    }
    
    // 写入环形缓冲区（无锁 SPSC）
    int dataSize = sampleCount * config_.channelCount;
    int tail = ringTail_.load(std::memory_order_relaxed);
    int head = ringHead_.load(std::memory_order_acquire);
    
    // 计算可用空间（保留1个元素的间隔以区分满/空）
    int available;
    if (tail >= head) {
        available = RING_BUFFER_CAPACITY - (tail - head) - 1;
    } else {
        available = head - tail - 1;
    }
    
    if (available < dataSize) {
        // 缓冲区空间不足 → 丢弃新数据（不移动消费者 head，维持 SPSC 约束）
        // 这与 Android 的策略一致：当音频延迟超限时丢弃新包，避免用延迟换取全无爬音
        droppedSamples_.fetch_add(sampleCount, std::memory_order_relaxed);
        return 0;
    }
    
    // 写入数据到环形缓冲区
    int firstPart = std::min(dataSize, RING_BUFFER_CAPACITY - tail);
    memcpy(ringBuffer_ + tail, pcmData, firstPart * sizeof(int16_t));
    if (firstPart < dataSize) {
        memcpy(ringBuffer_, pcmData + firstPart, (dataSize - firstPart) * sizeof(int16_t));
    }
    ringTail_.store((tail + dataSize) % RING_BUFFER_CAPACITY, std::memory_order_release);
    
    totalSamples_.fetch_add(sampleCount, std::memory_order_relaxed);
    
    return 0;
}

int AudioRenderer::TryRestart() {
    OH_LOG_INFO(LOG_APP, "Attempting audio renderer restart...");
    
    if (renderer_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Cannot restart: renderer is null");
        return -1;
    }
    
    // 先停止当前渲染器
    OH_AudioRenderer_Stop(renderer_);
    
    // 清空环形缓冲区 + OHAudio 内部缓冲，避免播放过时数据
    ringHead_.store(0, std::memory_order_relaxed);
    ringTail_.store(0, std::memory_order_relaxed);
    wasUnderrun_.store(false, std::memory_order_relaxed);
    OH_AudioRenderer_Flush(renderer_);
    
    // 尝试重新启动
    OH_AudioStream_Result result = OH_AudioRenderer_Start(renderer_);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to restart renderer: %{public}d", result);
        
        // 完全重建渲染器
        OH_LOG_INFO(LOG_APP, "Attempting full renderer rebuild...");
        OH_AudioRenderer_Release(renderer_);
        renderer_ = nullptr;
        
        if (builder_ != nullptr) {
            result = OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_);
            if (result != AUDIOSTREAM_SUCCESS || renderer_ == nullptr) {
                OH_LOG_ERROR(LOG_APP, "Failed to rebuild renderer: %{public}d", result);
                return -1;
            }
            
            if (config_.volume > 0.0f && config_.volume <= 1.0f) {
                OH_AudioRenderer_SetVolume(renderer_, config_.volume);
            }
            
            result = OH_AudioRenderer_Start(renderer_);
            if (result != AUDIOSTREAM_SUCCESS) {
                OH_LOG_ERROR(LOG_APP, "Failed to start rebuilt renderer: %{public}d", result);
                return -1;
            }
        } else {
            OH_LOG_ERROR(LOG_APP, "Cannot rebuild: builder is null");
            return -1;
        }
    }
    
    running_ = true;
    needRestart_ = false;
    consecutiveErrors_ = 0;
    OH_LOG_INFO(LOG_APP, "Audio renderer restarted successfully");
    return 0;
}

AudioRendererStats AudioRenderer::GetStats() const {
    AudioRendererStats stats;
    stats.totalSamples = totalSamples_.load(std::memory_order_relaxed);
    stats.playedSamples = playedSamples_.load(std::memory_order_relaxed);
    stats.droppedSamples = droppedSamples_.load(std::memory_order_relaxed);
    stats.underruns = underruns_.load(std::memory_order_relaxed);
    
    // 计算当前缓冲区延迟
    int head = ringHead_.load(std::memory_order_relaxed);
    int tail = ringTail_.load(std::memory_order_relaxed);
    int buffered;
    if (tail >= head) {
        buffered = tail - head;
    } else {
        buffered = RING_BUFFER_CAPACITY - head + tail;
    }
    int bufferedSamples = buffered / std::max(config_.channelCount, 1);
    stats.latencyMs = (config_.sampleRate > 0) 
        ? (bufferedSamples * 1000.0 / config_.sampleRate) 
        : 0.0;
    
    return stats;
}

double AudioRenderer::GetBufferLatencyMs() const {
    int head = ringHead_.load(std::memory_order_relaxed);
    int tail = ringTail_.load(std::memory_order_relaxed);
    int buffered = (tail >= head) ? (tail - head) : (RING_BUFFER_CAPACITY - head + tail);
    int channelCount = std::max(config_.channelCount, 1);
    return (config_.sampleRate > 0)
        ? ((double)(buffered / channelCount) * 1000.0 / config_.sampleRate)
        : 0.0;
}

// =============================================================================
// OHAudio 回调实现
// =============================================================================

OH_AudioData_Callback_Result AudioRenderer::OnWriteData(OH_AudioRenderer* renderer, void* userData,
                                    void* buffer, int32_t bufferLen) {
    AudioRenderer* self = static_cast<AudioRenderer*>(userData);
    if (self == nullptr || !self->running_) {
        // 填充静音
        memset(buffer, 0, bufferLen);
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }
    
    // 始终设置音频回调线程 QoS 为最高优先级
    static thread_local bool qosSet = false;
    if (!qosSet) {
        int ret = OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);
        if (ret == 0) {
            OH_LOG_INFO(LOG_APP, "Audio callback thread QoS set to USER_INTERACTIVE");
        }
        qosSet = true;
    }
    
    // 从环形缓冲区读取数据（无锁 SPSC 消费者端）
    int16_t* outBuffer = static_cast<int16_t*>(buffer);
    int samplesNeeded = bufferLen / sizeof(int16_t);
    
    int head = self->ringHead_.load(std::memory_order_relaxed);
    int tail = self->ringTail_.load(std::memory_order_acquire);
    
    // 计算可读数据量
    int available;
    if (tail >= head) {
        available = tail - head;
    } else {
        available = RING_BUFFER_CAPACITY - head + tail;
    }
    
    int toCopy = std::min(available, samplesNeeded);
    int channelCount = std::max(self->config_.channelCount, 1);
    // 渐变长度（按采样帧计，非采样点）：约 2ms @48kHz = 96 采样帧
    // 使用较短的渐变避免过度修改有效音频数据
    static constexpr int FADE_FRAMES = 96;
    
    if (toCopy > 0) {
        // 从环形缓冲区读取
        int firstPart = std::min(toCopy, RING_BUFFER_CAPACITY - head);
        memcpy(outBuffer, self->ringBuffer_ + head, firstPart * sizeof(int16_t));
        if (firstPart < toCopy) {
            memcpy(outBuffer + firstPart, self->ringBuffer_, (toCopy - firstPart) * sizeof(int16_t));
        }
        self->ringHead_.store((head + toCopy) % RING_BUFFER_CAPACITY, std::memory_order_release);
        
        // Underrun 后恢复：对开头数据施加渐入（fade-in），避免静音→有信号的波形跳变
        if (self->wasUnderrun_.load(std::memory_order_relaxed)) {
            // 按帧步进（每帧 channelCount 个采样点），确保同一时间步的所有声道获得相同增益
            int fadeFrames = std::min(toCopy / channelCount, FADE_FRAMES);
            for (int f = 0; f < fadeFrames; f++) {
                float gain = (float)f / (float)fadeFrames;
                for (int c = 0; c < channelCount; c++) {
                    outBuffer[f * channelCount + c] = (int16_t)(outBuffer[f * channelCount + c] * gain);
                }
            }
        }
    }
    
    // 如果数据不足，填充静音（underrun）
    if (toCopy < samplesNeeded) {
        // 计算欠缺比例：仅当大比例欠缺时才做渐出（小缺口直接填静音即可）
        int gap = samplesNeeded - toCopy;
        bool significantUnderrun = (gap > samplesNeeded / 4);  // 超过25%欠缺才渐出
        
        if (toCopy > 0 && significantUnderrun) {
            // 对末尾有效数据施加渐出，避免有信号→静音的波形跳变
            // 按帧步进确保多声道同步
            int fadeFrames = std::min(toCopy / channelCount, FADE_FRAMES);
            int fadeStartSample = toCopy - fadeFrames * channelCount;
            for (int f = 0; f < fadeFrames; f++) {
                float gain = 1.0f - (float)f / (float)fadeFrames;
                for (int c = 0; c < channelCount; c++) {
                    int idx = fadeStartSample + f * channelCount + c;
                    outBuffer[idx] = (int16_t)(outBuffer[idx] * gain);
                }
            }
        }
        memset(outBuffer + toCopy, 0, (samplesNeeded - toCopy) * sizeof(int16_t));
        self->underruns_.fetch_add(1, std::memory_order_relaxed);
        self->wasUnderrun_.store(true, std::memory_order_relaxed);
    } else {
        self->wasUnderrun_.store(false, std::memory_order_relaxed);
    }
    
    // 更新已播放样本数（按通道换算）
    self->playedSamples_.fetch_add(toCopy / channelCount, std::memory_order_relaxed);
    
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

void AudioRenderer::OnDeviceChange(OH_AudioRenderer* renderer, void* userData,
                                    OH_AudioStream_DeviceChangeReason reason) {
    OH_LOG_INFO(LOG_APP, "Audio output device changed: reason=%{public}d", reason);
    
    AudioRenderer* self = static_cast<AudioRenderer*>(userData);
    if (self == nullptr) return;
    
    if (reason == REASON_OLD_DEVICE_UNAVAILABLE) {
        // 旧设备不可用（如拔出耳机），标记重启
        OH_LOG_WARN(LOG_APP, "Audio device unavailable, scheduling restart");
        self->needRestart_ = true;
    }
}

void AudioRenderer::OnInterruptEvent(OH_AudioRenderer* renderer, void* userData,
                                         OH_AudioInterrupt_ForceType type,
                                         OH_AudioInterrupt_Hint hint) {
    OH_LOG_INFO(LOG_APP, "Audio interrupt: type=%{public}d, hint=%{public}d", type, hint);
    
    AudioRenderer* self = static_cast<AudioRenderer*>(userData);
    if (self == nullptr) return;
    
    if (hint == AUDIOSTREAM_INTERRUPT_HINT_PAUSE) {
        OH_LOG_WARN(LOG_APP, "Audio paused by system interrupt");
        self->running_ = false;
    } else if (hint == AUDIOSTREAM_INTERRUPT_HINT_RESUME) {
        OH_LOG_INFO(LOG_APP, "Audio resume hint received, scheduling restart");
        self->needRestart_ = true;
    } else if (hint == AUDIOSTREAM_INTERRUPT_HINT_STOP) {
        OH_LOG_WARN(LOG_APP, "Audio stopped by system, scheduling restart");
        self->running_ = false;
        self->needRestart_ = true;
    }
}

void AudioRenderer::OnError(OH_AudioRenderer* renderer, void* userData,
                                OH_AudioStream_Result error) {
    OH_LOG_ERROR(LOG_APP, "Audio renderer error: %{public}d", error);
    
    AudioRenderer* self = static_cast<AudioRenderer*>(userData);
    if (self == nullptr) return;
    
    int errors = ++self->consecutiveErrors_;
    OH_LOG_ERROR(LOG_APP, "Audio consecutive errors: %{public}d", errors);
    
    if (errors >= MAX_ERRORS_BEFORE_RESTART) {
        OH_LOG_WARN(LOG_APP, "Too many audio errors, scheduling restart");
        self->running_ = false;
        self->needRestart_ = true;
    }
}

// =============================================================================
// 全局简化接口
// =============================================================================

namespace {
    // 使用原子指针保证 PlaySamples 等高频调用的线程安全
    // Cleanup 通过 mutex 保证与 Init 的互斥
    static std::atomic<AudioRenderer*> g_audioRenderer{nullptr};
    static std::mutex g_audioRendererMutex;
}

namespace AudioRendererInstance {

// 空间音频配置（可通过 NAPI 设置）
static bool g_enableSpatialAudio = true;

void SetSpatialAudioEnabled(bool enabled) {
    g_enableSpatialAudio = enabled;
    OH_LOG_INFO(LOG_APP, "Spatial audio setting: %{public}s", enabled ? "enabled" : "disabled");
}

bool IsSpatialAudioEnabled() {
    return g_enableSpatialAudio;
}

int Init(int sampleRate, int channelCount, int samplesPerFrame) {
    std::lock_guard<std::mutex> lock(g_audioRendererMutex);
    
    AudioRenderer* old = g_audioRenderer.exchange(nullptr, std::memory_order_acq_rel);
    if (old != nullptr) {
        delete old;
    }
    
    AudioRenderer* renderer = new AudioRenderer();
    
    AudioRendererConfig config;
    config.sampleRate = sampleRate;
    config.channelCount = channelCount;
    config.samplesPerFrame = samplesPerFrame;
    config.bitsPerSample = 16;
    config.volume = 1.0f;
    config.enableSpatialAudio = g_enableSpatialAudio;
    
    int ret = renderer->Init(config);
    if (ret == 0) {
        g_audioRenderer.store(renderer, std::memory_order_release);
    } else {
        delete renderer;
    }
    return ret;
}

int SetVolume(float volume) {
    AudioRenderer* renderer = g_audioRenderer.load(std::memory_order_acquire);
    if (renderer == nullptr) {
        return -1;
    }
    return renderer->SetVolume(volume);
}

int PlaySamples(const int16_t* pcmData, int sampleCount) {
    AudioRenderer* renderer = g_audioRenderer.load(std::memory_order_acquire);
    if (renderer == nullptr) {
        return -1;
    }
    return renderer->PlaySamples(pcmData, sampleCount);
}

int Start() {
    AudioRenderer* renderer = g_audioRenderer.load(std::memory_order_acquire);
    if (renderer == nullptr) {
        return -1;
    }
    return renderer->Start();
}

int Stop() {
    AudioRenderer* renderer = g_audioRenderer.load(std::memory_order_acquire);
    if (renderer == nullptr) {
        return -1;
    }
    return renderer->Stop();
}

void Cleanup() {
    std::lock_guard<std::mutex> lock(g_audioRendererMutex);
    
    AudioRenderer* old = g_audioRenderer.exchange(nullptr, std::memory_order_acq_rel);
    if (old != nullptr) {
        delete old;
    }
}

AudioRendererStats GetStats() {
    AudioRenderer* renderer = g_audioRenderer.load(std::memory_order_acquire);
    if (renderer != nullptr) {
        return renderer->GetStats();
    }
    return AudioRendererStats{};
}

double GetBufferLatencyMs() {
    AudioRenderer* renderer = g_audioRenderer.load(std::memory_order_acquire);
    if (renderer != nullptr) {
        return renderer->GetBufferLatencyMs();
    }
    return 0.0;
}

} // namespace AudioRendererInstance
