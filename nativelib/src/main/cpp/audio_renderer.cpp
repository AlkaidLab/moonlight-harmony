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
#include <ctime>
#include <memory>

#define LOG_TAG "AudioRenderer"

// =============================================================================
// OHAudio 新式回调 API 动态加载（兼容旧设备缺失符号）
// =============================================================================
// 某些 OHAudio 回调设置函数在部分 HarmonyOS 5.0.x (API 12) 设备的
// libohaudio.so 中不存在（如 SetRendererInterruptCallback）。
// 若直接链接，.so 加载时 linker 会因 "symbol not found" 而拒绝加载整个模块，
// 导致所有页面（包括 SettingsPageV2）因 native 模块不可用而崩溃。
// 使用 dlsym 运行时加载这些可选 API，缺失时静默跳过。
// =============================================================================

// 函数指针类型定义 — Renderer
typedef OH_AudioStream_Result (*PFN_SetRendererWriteDataCb)(
    OH_AudioStreamBuilder*, OH_AudioRenderer_OnWriteDataCallback, void*);
typedef OH_AudioStream_Result (*PFN_SetRendererInterruptCb)(
    OH_AudioStreamBuilder*, OH_AudioRenderer_OnInterruptCallback, void*);
typedef OH_AudioStream_Result (*PFN_SetRendererErrorCb)(
    OH_AudioStreamBuilder*, OH_AudioRenderer_OnErrorCallback, void*);
typedef OH_AudioStream_Result (*PFN_SetRendererOutputDeviceChangeCb)(
    OH_AudioStreamBuilder*, OH_AudioRenderer_OutputDeviceChangeCallback, void*);
typedef OH_AudioStream_Result (*PFN_SetRendererFastStatusChangeCb)(
    OH_AudioStreamBuilder*, OH_AudioRenderer_OnFastStatusChange, void*);
typedef OH_AudioStream_Result (*PFN_GetAudioTimestampInfo)(
    OH_AudioRenderer*, int64_t*, int64_t*);
typedef OH_AudioStream_Result (*PFN_GetRendererLatency)(
    OH_AudioRenderer*, OH_AudioStream_LatencyType, int32_t*);

// 函数指针类型定义 — 空间音频 (API 20+)
typedef OH_AudioStream_Result (*PFN_SetSpatializationEnabled)(
    OH_AudioStreamBuilder* builder, bool spatializationEnabled);

// 全局函数指针
static PFN_SetRendererWriteDataCb       g_pfnSetRendererWriteDataCb = nullptr;
static PFN_SetRendererInterruptCb       g_pfnSetRendererInterruptCb = nullptr;
static PFN_SetRendererErrorCb           g_pfnSetRendererErrorCb = nullptr;
static PFN_SetRendererOutputDeviceChangeCb g_pfnSetRendererDeviceChangeCb = nullptr;
static PFN_SetRendererFastStatusChangeCb g_pfnSetRendererFastStatusChangeCb = nullptr;
static PFN_SetSpatializationEnabled     g_pfnSetSpatializationEnabled = nullptr;
static PFN_GetAudioTimestampInfo        g_pfnGetAudioTimestampInfo = nullptr;
static PFN_GetRendererLatency           g_pfnGetRendererLatency = nullptr;

static bool g_audioApisChecked = false;
static bool g_writeDataCbAvailable = false;
static bool g_spatialAudioAvailable = false;

// 一次性加载所有 OHAudio 可选 API
static void LoadAudioApis() {
    if (g_audioApisChecked) return;
    g_audioApisChecked = true;
    
    void* handle = dlopen("libohaudio.so", RTLD_NOW);
    if (!handle) {
        OH_LOG_ERROR(LOG_APP, "Failed to dlopen libohaudio.so");
        return;
    }

    // Renderer 新式回调
    g_pfnSetRendererWriteDataCb = (PFN_SetRendererWriteDataCb)
        dlsym(handle, "OH_AudioStreamBuilder_SetRendererWriteDataCallback");
    g_pfnSetRendererInterruptCb = (PFN_SetRendererInterruptCb)
        dlsym(handle, "OH_AudioStreamBuilder_SetRendererInterruptCallback");
    g_pfnSetRendererErrorCb = (PFN_SetRendererErrorCb)
        dlsym(handle, "OH_AudioStreamBuilder_SetRendererErrorCallback");
    g_pfnSetRendererDeviceChangeCb = (PFN_SetRendererOutputDeviceChangeCb)
        dlsym(handle, "OH_AudioStreamBuilder_SetRendererOutputDeviceChangeCallback");
    g_pfnSetRendererFastStatusChangeCb = (PFN_SetRendererFastStatusChangeCb)
        dlsym(handle, "OH_AudioStreamBuilder_SetRendererFastStatusChangeCallback");
    g_pfnGetAudioTimestampInfo = (PFN_GetAudioTimestampInfo)
        dlsym(handle, "OH_AudioRenderer_GetAudioTimestampInfo");
    g_pfnGetRendererLatency = (PFN_GetRendererLatency)
        dlsym(handle, "OH_AudioRenderer_GetLatency");

    // 空间音频 (API 20+)
    g_pfnSetSpatializationEnabled = (PFN_SetSpatializationEnabled)
        dlsym(handle, "OH_AudioStreamBuilder_SetSpatializationEnabled");

    g_writeDataCbAvailable = (g_pfnSetRendererWriteDataCb != nullptr);
    g_spatialAudioAvailable = (g_pfnSetSpatializationEnabled != nullptr);

    OH_LOG_INFO(LOG_APP, "OHAudio API probe: WriteDataCb=%{public}s InterruptCb=%{public}s "
                "ErrorCb=%{public}s DeviceChangeCb=%{public}s FastStatusCb=%{public}s "
                "AudioTimestamp=%{public}s RouteLatency=%{public}s SpatialAudio=%{public}s",
                g_pfnSetRendererWriteDataCb ? "Y" : "N",
                g_pfnSetRendererInterruptCb ? "Y" : "N",
                g_pfnSetRendererErrorCb ? "Y" : "N",
                g_pfnSetRendererDeviceChangeCb ? "Y" : "N",
                g_pfnSetRendererFastStatusChangeCb ? "Y" : "N",
                g_pfnGetAudioTimestampInfo ? "Y" : "N",
                g_pfnGetRendererLatency ? "Y" : "N",
                g_pfnSetSpatializationEnabled ? "Y" : "N");
    // 不 dlclose，保持库加载
}

// =============================================================================
// AudioRenderer 类实现
// =============================================================================

AudioRenderer::AudioRenderer() {
    // ringBuffer_ 在 Init 中动态分配
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
    audioCompatMode_ = config.audioCompatMode;
    
    // 动态分配环形缓冲区：根据实际声道数和采样率计算容量
    // 兼容模式使用更大的缓冲区（120ms，与 v724 行为一致）
    int bufferMs = audioCompatMode_ ? TARGET_BUFFER_COMPAT_MS : TARGET_BUFFER_MS;
    int usableSamples = config_.sampleRate * config_.channelCount * bufferMs / 1000;
    // 对齐到帧边界（channelCount × samplesPerFrame）
    int frameSize = config_.channelCount * config_.samplesPerFrame;
    if (frameSize > 0) {
        usableSamples = ((usableSamples + frameSize - 1) / frameSize) * frameSize;
    }
    // SPSC 环形缓冲区需要多留 1 个位置以区分满/空
    ringCapacity_ = usableSamples + 1;
    
    // 释放旧缓冲区（如果有）
    delete[] ringBuffer_;
    ringBuffer_ = new int16_t[ringCapacity_];
    memset(ringBuffer_, 0, ringCapacity_ * sizeof(int16_t));
    
    OH_LOG_INFO(LOG_APP, "Ring buffer: capacity=%{public}d samples (%{public}dms for %{public}dch @%{public}dHz), "
                "latency cap=%{public}s, compat=%{public}s",
                ringCapacity_ - 1,
                bufferMs,
                config_.channelCount,
                config_.sampleRate,
                audioCompatMode_ ? "disabled" : "40ms",
                audioCompatMode_ ? "true" : "false");
    
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
    LoadAudioApis();
    if (config_.enableSpatialAudio && g_spatialAudioAvailable && g_pfnSetSpatializationEnabled != nullptr) {
        result = g_pfnSetSpatializationEnabled(builder_, true);
        if (result == AUDIOSTREAM_SUCCESS) {
            OH_LOG_INFO(LOG_APP, "Spatial audio enabled successfully");
        } else {
            OH_LOG_WARN(LOG_APP, "Failed to enable spatial audio: %{public}d", result);
        }
    } else if (config_.enableSpatialAudio) {
        OH_LOG_INFO(LOG_APP, "Spatial audio not available on this device/API level");
    }
    
    // 设置回调 — 通过 dlsym 动态加载的函数指针设置（兼容旧设备）
    LoadAudioApis();

    // 数据写入回调（必需）
    if (g_pfnSetRendererWriteDataCb) {
        result = g_pfnSetRendererWriteDataCb(builder_,
            (OH_AudioRenderer_OnWriteDataCallback)OnWriteData, this);
        if (result != AUDIOSTREAM_SUCCESS) {
            OH_LOG_ERROR(LOG_APP, "Failed to set write data callback: %{public}d", result);
            OH_AudioStreamBuilder_Destroy(builder_);
            builder_ = nullptr;
            return -1;
        }
    } else {
        OH_LOG_ERROR(LOG_APP, "SetRendererWriteDataCallback not available on this device!");
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        return -1;
    }
    
    // 中断事件回调（可选 — 部分 API 12 设备不存在此符号）
    if (g_pfnSetRendererInterruptCb) {
        result = g_pfnSetRendererInterruptCb(builder_,
            (OH_AudioRenderer_OnInterruptCallback)OnInterruptEvent, this);
        if (result != AUDIOSTREAM_SUCCESS) {
            OH_LOG_WARN(LOG_APP, "Failed to set interrupt callback: %{public}d", result);
        }
    } else {
        OH_LOG_INFO(LOG_APP, "SetRendererInterruptCallback not available, skipping");
    }
    
    // 错误回调（可选）
    if (g_pfnSetRendererErrorCb) {
        result = g_pfnSetRendererErrorCb(builder_,
            (OH_AudioRenderer_OnErrorCallback)OnError, this);
        if (result != AUDIOSTREAM_SUCCESS) {
            OH_LOG_WARN(LOG_APP, "Failed to set error callback: %{public}d", result);
        }
    } else {
        OH_LOG_INFO(LOG_APP, "SetRendererErrorCallback not available, skipping");
    }
    
    // 设备变更回调（可选）
    if (g_pfnSetRendererDeviceChangeCb) {
        result = g_pfnSetRendererDeviceChangeCb(builder_,
            (OH_AudioRenderer_OutputDeviceChangeCallback)OnDeviceChange, this);
        if (result != AUDIOSTREAM_SUCCESS) {
            OH_LOG_WARN(LOG_APP, "Failed to set device change callback: %{public}d", result);
        }
    } else {
        OH_LOG_INFO(LOG_APP, "SetRendererOutputDeviceChangeCallback not available, skipping");
    }

    if (g_pfnSetRendererFastStatusChangeCb) {
        result = g_pfnSetRendererFastStatusChangeCb(
            builder_, OnFastStatusChange, this);
        if (result != AUDIOSTREAM_SUCCESS) {
            OH_LOG_WARN(LOG_APP, "Failed to set fast status callback: %{public}d", result);
        }
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
    
    InvalidatePresentationEstimate();
    OH_AudioStream_Result result = OH_AudioRenderer_Start(renderer_);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to start renderer: %{public}d", result);
        return -1;
    }
    
    running_ = true;
    needRestart_ = false;
    consecutiveErrors_ = 0;
    RefreshRouteLatency();
    OH_LOG_INFO(LOG_APP, "Audio renderer started");
    
    return 0;
}

int AudioRenderer::Stop() {
    running_ = false;
    InvalidatePresentationEstimate();
    
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
    
    // 释放动态环形缓冲区
    delete[] ringBuffer_;
    ringBuffer_ = nullptr;
    ringCapacity_ = 0;
    
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
    // 生产者只写 ringTail_，不触碰 ringHead_（消费者的变量），保证无锁正确性
    // 延迟控制由消费者 OnWriteData 负责（在读取前跳过旧数据）
    int dataSize = sampleCount * config_.channelCount;
    int tail = ringTail_.load(std::memory_order_relaxed);
    int head = ringHead_.load(std::memory_order_acquire);
    
    // 计算可用空间（保留1个元素的间隔以区分满/空）
    int available;
    if (tail >= head) {
        available = ringCapacity_ - (tail - head) - 1;
    } else {
        available = head - tail - 1;
    }
    
    if (available < dataSize) {
        // 缓冲区空间不足 → 丢弃新数据
        // 不推进 head（消费者的写变量），保持 SPSC 无锁约定
        // 消费者端的延迟裁剪会确保缓冲区不会持续积累
        droppedSamples_.fetch_add(sampleCount, std::memory_order_relaxed);
        return 0;
    }
    
    // 写入数据到环形缓冲区
    int firstPart = std::min(dataSize, ringCapacity_ - tail);
    memcpy(ringBuffer_ + tail, pcmData, firstPart * sizeof(int16_t));
    if (firstPart < dataSize) {
        memcpy(ringBuffer_, pcmData + firstPart, (dataSize - firstPart) * sizeof(int16_t));
    }
    ringTail_.store((tail + dataSize) % ringCapacity_, std::memory_order_release);
    
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
    InvalidatePresentationEstimate();
    
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
    RefreshRouteLatency();
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
        buffered = ringCapacity_ - head + tail;
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
    int buffered = (tail >= head) ? (tail - head) : (ringCapacity_ - head + tail);
    int channelCount = std::max(config_.channelCount, 1);
    return (config_.sampleRate > 0)
        ? ((double)(buffered / channelCount) * 1000.0 / config_.sampleRate)
        : 0.0;
}

void AudioRenderer::InvalidatePresentationEstimate() {
    presentationClockRefreshNs_.store(0, std::memory_order_relaxed);
    previousPresentedFrames_.store(-1, std::memory_order_relaxed);
    previousPresentationTimestampNs_.store(0, std::memory_order_relaxed);
    presentationClockStableSamples_.store(0, std::memory_order_relaxed);
    cachedRendererLatencyUs_.store(-1, std::memory_order_relaxed);
    routeLatencyMs_.store(-1, std::memory_order_relaxed);
}

void AudioRenderer::RefreshRouteLatency() {
    if (renderer_ == nullptr || g_pfnGetRendererLatency == nullptr) {
        routeLatencyMs_.store(-1, std::memory_order_relaxed);
        return;
    }

    int32_t latencyMs = 0;
    if (g_pfnGetRendererLatency(
            renderer_, AUDIOSTREAM_LATENCY_TYPE_ALL, &latencyMs) ==
            AUDIOSTREAM_SUCCESS &&
        latencyMs >= 0 && latencyMs <= 1000) {
        routeLatencyMs_.store(latencyMs, std::memory_order_relaxed);
        OH_LOG_INFO(LOG_APP, "Audio route latency estimate: %{public}dms", latencyMs);
    } else {
        routeLatencyMs_.store(-1, std::memory_order_relaxed);
    }
}

void AudioRenderer::RefreshPresentationClock(int64_t nowNs) {
    int64_t lastRefreshNs =
        presentationClockRefreshNs_.load(std::memory_order_relaxed);
    if (lastRefreshNs > 0 &&
        nowNs - lastRefreshNs < PRESENTATION_CLOCK_REFRESH_NS) {
        return;
    }
    if (!presentationClockRefreshNs_.compare_exchange_strong(
            lastRefreshNs, nowNs, std::memory_order_acq_rel,
            std::memory_order_relaxed)) {
        return;
    }

    int64_t presentedFrames = 0;
    int64_t presentationTimestampNs = 0;
    OH_AudioStream_Result timestampResult;
    if (g_pfnGetAudioTimestampInfo != nullptr) {
        timestampResult = g_pfnGetAudioTimestampInfo(
            renderer_, &presentedFrames, &presentationTimestampNs);
    } else {
        timestampResult = OH_AudioRenderer_GetTimestamp(
            renderer_, CLOCK_MONOTONIC, &presentedFrames,
            &presentationTimestampNs);
    }

    int64_t framesWritten = 0;
    if (timestampResult != AUDIOSTREAM_SUCCESS ||
        OH_AudioRenderer_GetFramesWritten(renderer_, &framesWritten) !=
            AUDIOSTREAM_SUCCESS ||
        presentedFrames < 0 || framesWritten < presentedFrames ||
        presentationTimestampNs <= 0) {
        return;
    }

    const int64_t timestampAgeNs = nowNs - presentationTimestampNs;
    if (timestampAgeNs < -5000000 || timestampAgeNs > 1000000000) {
        return;
    }
    const int64_t elapsedFrames = timestampAgeNs > 0
        ? timestampAgeNs * static_cast<int64_t>(config_.sampleRate) /
            1000000000
        : 0;
    const int64_t presentedNow =
        std::min(framesWritten, presentedFrames + elapsedFrames);
    const int64_t pendingFrames = framesWritten - presentedNow;

    const int64_t previousFrames =
        previousPresentedFrames_.exchange(presentedFrames,
            std::memory_order_relaxed);
    const int64_t previousTimestamp =
        previousPresentationTimestampNs_.exchange(presentationTimestampNs,
            std::memory_order_relaxed);
    int stableSamples = presentationClockStableSamples_.load(
        std::memory_order_relaxed);
    if (previousFrames >= 0 && presentedFrames >= previousFrames &&
        presentationTimestampNs > previousTimestamp) {
        stableSamples = std::min(stableSamples + 1, 2);
    } else {
        stableSamples = 1;
    }
    presentationClockStableSamples_.store(
        stableSamples, std::memory_order_relaxed);

    if (stableSamples >= 2) {
        const int64_t latencyUs =
            pendingFrames * 1000000 / config_.sampleRate;
        // Frame position can reset after a route change while frames-written
        // remains stream-relative. Reject that mismatched origin and keep the
        // route-latency fallback instead of manufacturing a long haptic delay.
        if (latencyUs >= 0 && latencyUs <= 500000) {
            cachedRendererLatencyUs_.store(
                latencyUs, std::memory_order_release);
        }
    }
}

double AudioRenderer::GetPresentationLatencyMs() {
    const double ringBufferLatencyMs = GetBufferLatencyMs();
    if (renderer_ == nullptr || config_.sampleRate <= 0) {
        return ringBufferLatencyMs;
    }

    timespec now{};
    clock_gettime(CLOCK_MONOTONIC, &now);
    const int64_t nowNs =
        static_cast<int64_t>(now.tv_sec) * 1000000000 + now.tv_nsec;
    RefreshPresentationClock(nowNs);

    const int64_t cachedRendererLatencyUs =
        cachedRendererLatencyUs_.load(std::memory_order_acquire);
    if (cachedRendererLatencyUs >= 0) {
        return ringBufferLatencyMs +
            static_cast<double>(cachedRendererLatencyUs) / 1000.0;
    }

    const int32_t routeLatencyMs =
        routeLatencyMs_.load(std::memory_order_relaxed);
    return ringBufferLatencyMs +
        static_cast<double>(std::max(routeLatencyMs, 0));
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
    int channelCount = std::max(self->config_.channelCount, 1);

    // 计算可读数据量
    int available;
    if (tail >= head) {
        available = tail - head;
    } else {
        available = self->ringCapacity_ - head + tail;
    }
    
    // 延迟裁剪（消费者端）：如果缓冲区积累过多，跳过旧数据到合理位置
    // 兼容模式下跳过此逻辑，依赖缓冲区自然满溢丢弃（与 v724 行为一致）
    // 在消费者线程推进 head 是 SPSC 安全的（head 本就是消费者的写变量）
    if (!self->audioCompatMode_ && available > 0 && self->config_.sampleRate > 0) {
        int bufferedFrames = available / channelCount;
        double latencyMs = (double)bufferedFrames * 1000.0 / self->config_.sampleRate;
        if (latencyMs > MAX_AUDIO_LATENCY_MS) {
            // 跳到只保留 MAX_AUDIO_LATENCY_MS/2 的数据，给后续帧留余量
            int targetSamples = self->config_.sampleRate * channelCount * MAX_AUDIO_LATENCY_MS / 2 / 1000;
            // 对齐到帧边界
            targetSamples = (targetSamples / channelCount) * channelCount;
            int toDrop = available - targetSamples;
            if (toDrop > 0) {
                toDrop = (toDrop / channelCount) * channelCount;
                head = (head + toDrop) % self->ringCapacity_;
                self->ringHead_.store(head, std::memory_order_release);
                available -= toDrop;
                self->droppedSamples_.fetch_add(toDrop / channelCount, std::memory_order_relaxed);
                // 标记需要 fade-in（跳过数据后波形不连续）
                self->wasUnderrun_.store(true, std::memory_order_relaxed);
            }
        }
    }
    
    int toCopy = std::min(available, samplesNeeded);
    // 自适应渐变长度：根据 gap 大小调整，大 gap 需要更长渐变以减少爆音
    // 基础: 96 帧 (~2ms @48kHz)，最大: 480 帧 (~10ms @48kHz)
    static constexpr int FADE_FRAMES_MIN = 96;
    static constexpr int FADE_FRAMES_MAX = 480;
    int gap = samplesNeeded - toCopy;
    // gap 越大（数据越少），渐变越长
    int FADE_FRAMES;
    if (gap <= 0 || samplesNeeded <= 0) {
        FADE_FRAMES = FADE_FRAMES_MIN;
    } else {
        // 线性插值：gap 从 0 到 samplesNeeded 时，fade 从 MIN 到 MAX
        float gapRatio = (float)gap / (float)samplesNeeded;
        FADE_FRAMES = FADE_FRAMES_MIN + (int)((FADE_FRAMES_MAX - FADE_FRAMES_MIN) * gapRatio);
    }
    
    if (toCopy > 0) {
        // 从环形缓冲区读取
        int firstPart = std::min(toCopy, self->ringCapacity_ - head);
        memcpy(outBuffer, self->ringBuffer_ + head, firstPart * sizeof(int16_t));
        if (firstPart < toCopy) {
            memcpy(outBuffer + firstPart, self->ringBuffer_, (toCopy - firstPart) * sizeof(int16_t));
        }
        self->ringHead_.store((head + toCopy) % self->ringCapacity_, std::memory_order_release);
        
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
    self->InvalidatePresentationEstimate();
    
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
    self->InvalidatePresentationEstimate();
    
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

void AudioRenderer::OnFastStatusChange(OH_AudioRenderer* renderer,
                                       void* userData,
                                       OH_AudioStream_FastStatus status) {
    AudioRenderer* self = static_cast<AudioRenderer*>(userData);
    if (self == nullptr) return;

    self->InvalidatePresentationEstimate();
    OH_LOG_INFO(LOG_APP, "Audio renderer fast status changed: %{public}s",
                status == AUDIOSTREAM_FASTSTATUS_FAST ? "FAST" : "NORMAL");
}

// =============================================================================
// 全局简化接口
// =============================================================================

namespace {
    // Atomic shared ownership keeps the renderer alive for the full duration
    // of each wrapper call while Init and Cleanup replace the global instance.
    static std::shared_ptr<AudioRenderer> g_audioRenderer;
    static std::mutex g_audioRendererMutex;

    std::shared_ptr<AudioRenderer> AcquireAudioRenderer() {
        return std::atomic_load_explicit(
            &g_audioRenderer, std::memory_order_acquire);
    }
}

namespace AudioRendererInstance {

// 空间音频配置（可通过 NAPI 设置）
static bool g_enableSpatialAudio = false;
// 音频兼容模式（增大缓冲区 + 禁用延迟裁剪）
static bool g_audioCompatMode = false;

void SetSpatialAudioEnabled(bool enabled) {
    g_enableSpatialAudio = enabled;
    OH_LOG_INFO(LOG_APP, "Spatial audio setting: %{public}s", enabled ? "enabled" : "disabled");
}

bool IsSpatialAudioEnabled() {
    return g_enableSpatialAudio;
}

void SetAudioCompatMode(bool enabled) {
    g_audioCompatMode = enabled;
    OH_LOG_INFO(LOG_APP, "Audio compat mode: %{public}s", enabled ? "enabled" : "disabled");
}

bool IsAudioCompatMode() {
    return g_audioCompatMode;
}

int Init(int sampleRate, int channelCount, int samplesPerFrame) {
    std::lock_guard<std::mutex> lock(g_audioRendererMutex);

    std::shared_ptr<AudioRenderer> old = std::atomic_exchange_explicit(
        &g_audioRenderer, std::shared_ptr<AudioRenderer>{},
        std::memory_order_acq_rel);
    old.reset();

    auto renderer = std::make_shared<AudioRenderer>();
    
    AudioRendererConfig config;
    config.sampleRate = sampleRate;
    config.channelCount = channelCount;
    config.samplesPerFrame = samplesPerFrame;
    config.bitsPerSample = 16;
    config.volume = 1.0f;
    config.enableSpatialAudio = g_enableSpatialAudio;
    config.audioCompatMode = g_audioCompatMode;
    
    int ret = renderer->Init(config);
    if (ret == 0) {
        std::atomic_store_explicit(
            &g_audioRenderer, renderer, std::memory_order_release);
    }
    return ret;
}

int SetVolume(float volume) {
    std::shared_ptr<AudioRenderer> renderer = AcquireAudioRenderer();
    if (renderer == nullptr) {
        return -1;
    }
    return renderer->SetVolume(volume);
}

int PlaySamples(const int16_t* pcmData, int sampleCount) {
    std::shared_ptr<AudioRenderer> renderer = AcquireAudioRenderer();
    if (renderer == nullptr) {
        return -1;
    }
    return renderer->PlaySamples(pcmData, sampleCount);
}

int Start() {
    std::shared_ptr<AudioRenderer> renderer = AcquireAudioRenderer();
    if (renderer == nullptr) {
        return -1;
    }
    return renderer->Start();
}

int Stop() {
    std::shared_ptr<AudioRenderer> renderer = AcquireAudioRenderer();
    if (renderer == nullptr) {
        return -1;
    }
    return renderer->Stop();
}

void Cleanup() {
    std::lock_guard<std::mutex> lock(g_audioRendererMutex);

    std::shared_ptr<AudioRenderer> old = std::atomic_exchange_explicit(
        &g_audioRenderer, std::shared_ptr<AudioRenderer>{},
        std::memory_order_acq_rel);
}

AudioRendererStats GetStats() {
    std::shared_ptr<AudioRenderer> renderer = AcquireAudioRenderer();
    if (renderer != nullptr) {
        return renderer->GetStats();
    }
    return AudioRendererStats{};
}

double GetBufferLatencyMs() {
    std::shared_ptr<AudioRenderer> renderer = AcquireAudioRenderer();
    if (renderer != nullptr) {
        return renderer->GetBufferLatencyMs();
    }
    return 0.0;
}

double GetPresentationLatencyMs() {
    std::shared_ptr<AudioRenderer> renderer = AcquireAudioRenderer();
    if (renderer != nullptr) {
        return renderer->GetPresentationLatencyMs();
    }
    return 0.0;
}

} // namespace AudioRendererInstance
