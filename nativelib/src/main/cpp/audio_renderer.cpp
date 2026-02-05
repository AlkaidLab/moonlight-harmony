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
 */

#include "audio_renderer.h"
#include "moonlight_bridge.h"
#include <hilog/log.h>
#include <cstring>
#include <dlfcn.h>
#include <qos/qos.h>

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
    memset(&stats_, 0, sizeof(stats_));
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
    result = OH_AudioStreamBuilder_SetLatencyMode(builder_, AUDIOSTREAM_LATENCY_MODE_FAST);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "Failed to set latency mode: %{public}d", result);
        // 非致命错误，继续
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
    
    // 设置回调
    OH_AudioRenderer_Callbacks callbacks = {
        .OH_AudioRenderer_OnWriteData = OnWriteData,
        .OH_AudioRenderer_OnStreamEvent = OnStreamEvent,
        .OH_AudioRenderer_OnInterruptEvent = OnInterruptEvent,
        .OH_AudioRenderer_OnError = OnError
    };
    
    result = OH_AudioStreamBuilder_SetRendererCallback(builder_, callbacks, this);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to set renderer callback: %{public}d", result);
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        return -1;
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
    
    OH_AudioStream_Result result = OH_AudioRenderer_Start(renderer_);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to start renderer: %{public}d", result);
        return -1;
    }
    
    running_ = true;
    OH_LOG_INFO(LOG_APP, "Audio renderer started");
    
    return 0;
}

int AudioRenderer::Stop() {
    running_ = false;
    
    if (renderer_ != nullptr) {
        OH_AudioRenderer_Stop(renderer_);
    }
    
    // 清空队列
    {
        std::lock_guard<std::mutex> lock(queueMutex_);
        while (!pcmQueue_.empty()) {
            auto& item = pcmQueue_.front();
            delete[] item.first;
            pcmQueue_.pop();
        }
    }
    
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
    if (!running_ || renderer_ == nullptr) {
        return -1;
    }
    
    // 复制数据到队列
    int dataSize = sampleCount * config_.channelCount;
    int16_t* buffer = new int16_t[dataSize];
    memcpy(buffer, pcmData, dataSize * sizeof(int16_t));
    
    {
        std::lock_guard<std::mutex> lock(queueMutex_);
        
        // 如果队列满了，丢弃最旧的数据
        while (pcmQueue_.size() >= MAX_QUEUE_SIZE) {
            auto& item = pcmQueue_.front();
            delete[] item.first;
            pcmQueue_.pop();
            
            std::lock_guard<std::mutex> statsLock(statsMutex_);
            stats_.droppedSamples += item.second;
        }
        
        pcmQueue_.push({buffer, sampleCount});
    }
    
    {
        std::lock_guard<std::mutex> lock(statsMutex_);
        stats_.totalSamples += sampleCount;
    }
    
    return 0;
}

AudioRendererStats AudioRenderer::GetStats() const {
    std::lock_guard<std::mutex> lock(statsMutex_);
    return stats_;
}

// =============================================================================
// OHAudio 回调实现
// =============================================================================

int32_t AudioRenderer::OnWriteData(OH_AudioRenderer* renderer, void* userData,
                                    void* buffer, int32_t bufferLen) {
    AudioRenderer* self = static_cast<AudioRenderer*>(userData);
    if (self == nullptr || !self->running_) {
        // 填充静音
        memset(buffer, 0, bufferLen);
        return bufferLen;
    }
    
    // 性能模式下设置音频线程 QoS
    static thread_local bool qosSet = false;
    if (!qosSet && MoonBridge_IsPerformanceModeEnabled()) {
        int ret = OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);
        if (ret == 0) {
            OH_LOG_INFO(LOG_APP, "Audio thread QoS set to USER_INTERACTIVE (performance mode)");
        }
        qosSet = true;
    }
    
    int16_t* outBuffer = static_cast<int16_t*>(buffer);
    int bytesWritten = 0;
    int bytesRemaining = bufferLen;
    
    std::lock_guard<std::mutex> lock(self->queueMutex_);
    
    while (bytesRemaining > 0 && !self->pcmQueue_.empty()) {
        auto& item = self->pcmQueue_.front();
        int16_t* pcmData = item.first;
        int sampleCount = item.second;
        int dataBytes = sampleCount * self->config_.channelCount * sizeof(int16_t);
        
        int bytesToCopy = std::min(dataBytes, bytesRemaining);
        memcpy(outBuffer + bytesWritten / sizeof(int16_t), pcmData, bytesToCopy);
        bytesWritten += bytesToCopy;
        bytesRemaining -= bytesToCopy;
        
        if (bytesToCopy >= dataBytes) {
            // 整个缓冲区已复制完成
            delete[] pcmData;
            self->pcmQueue_.pop();
        } else {
            // 部分复制，保留剩余数据
            int remainingBytes = dataBytes - bytesToCopy;
            int remainingSamples = remainingBytes / (self->config_.channelCount * sizeof(int16_t));
            
            // 移动数据到缓冲区开头
            memmove(pcmData, reinterpret_cast<uint8_t*>(pcmData) + bytesToCopy, remainingBytes);
            
            // 更新样本数
            item.second = remainingSamples;
            
            // 跳出循环，因为输出缓冲区已满
            break;
        }
    }
    
    // 如果还有剩余空间，填充静音
    if (bytesRemaining > 0) {
        memset(reinterpret_cast<uint8_t*>(buffer) + bytesWritten, 0, bytesRemaining);
        
        std::lock_guard<std::mutex> statsLock(self->statsMutex_);
        self->stats_.underruns++;
    }
    
    {
        std::lock_guard<std::mutex> statsLock(self->statsMutex_);
        self->stats_.playedSamples += bytesWritten / (self->config_.channelCount * sizeof(int16_t));
    }
    
    return bufferLen;
}

int32_t AudioRenderer::OnStreamEvent(OH_AudioRenderer* renderer, void* userData,
                                      OH_AudioStream_Event event) {
    OH_LOG_INFO(LOG_APP, "Audio stream event: %{public}d", event);
    return 0;
}

int32_t AudioRenderer::OnInterruptEvent(OH_AudioRenderer* renderer, void* userData,
                                         OH_AudioInterrupt_ForceType type,
                                         OH_AudioInterrupt_Hint hint) {
    OH_LOG_INFO(LOG_APP, "Audio interrupt: type=%{public}d, hint=%{public}d", type, hint);
    
    AudioRenderer* self = static_cast<AudioRenderer*>(userData);
    if (self == nullptr) return 0;
    
    if (hint == AUDIOSTREAM_INTERRUPT_HINT_PAUSE) {
        // 被系统暂停
        self->running_ = false;
    } else if (hint == AUDIOSTREAM_INTERRUPT_HINT_RESUME) {
        // 可以恢复
        self->running_ = true;
    }
    
    return 0;
}

int32_t AudioRenderer::OnError(OH_AudioRenderer* renderer, void* userData,
                                OH_AudioStream_Result error) {
    OH_LOG_ERROR(LOG_APP, "Audio renderer error: %{public}d", error);
    return 0;
}

// =============================================================================
// 全局简化接口
// =============================================================================

namespace {
    static AudioRenderer* g_audioRenderer = nullptr;
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
    
    if (g_audioRenderer != nullptr) {
        delete g_audioRenderer;
    }
    
    g_audioRenderer = new AudioRenderer();
    
    AudioRendererConfig config;
    config.sampleRate = sampleRate;
    config.channelCount = channelCount;
    config.samplesPerFrame = samplesPerFrame;
    config.bitsPerSample = 16;
    config.volume = 1.0f;  // 最大音量
    config.enableSpatialAudio = g_enableSpatialAudio;  // 使用配置的空间音频设置
    
    return g_audioRenderer->Init(config);
}

int SetVolume(float volume) {
    if (g_audioRenderer == nullptr) {
        return -1;
    }
    return g_audioRenderer->SetVolume(volume);
}

int PlaySamples(const int16_t* pcmData, int sampleCount) {
    if (g_audioRenderer == nullptr) {
        return -1;
    }
    return g_audioRenderer->PlaySamples(pcmData, sampleCount);
}

int Start() {
    if (g_audioRenderer == nullptr) {
        return -1;
    }
    return g_audioRenderer->Start();
}

int Stop() {
    if (g_audioRenderer == nullptr) {
        return -1;
    }
    return g_audioRenderer->Stop();
}

void Cleanup() {
    std::lock_guard<std::mutex> lock(g_audioRendererMutex);
    
    if (g_audioRenderer != nullptr) {
        delete g_audioRenderer;
        g_audioRenderer = nullptr;
    }
}

AudioRendererStats GetStats() {
    if (g_audioRenderer != nullptr) {
        return g_audioRenderer->GetStats();
    }
    return AudioRendererStats{};
}

} // namespace AudioRendererInstance
