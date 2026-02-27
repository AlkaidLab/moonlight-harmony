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
 * @file mic_capturer.cpp
 * @brief HarmonyOS OHAudio 低时延麦克风采集器实现
 *
 * 使用 OHAudio native API + AUDIOSTREAM_LATENCY_MODE_FAST，在音频回调线程中
 * 直接完成 PCM → Opus 编码 → 网络发送，消除 ArkTS 层跨线程和 GC 开销。
 */

#include "mic_capturer.h"
#include <hilog/log.h>
#include <cstring>
#include <dlfcn.h>

#define LOG_TAG "MicCapturer"

// =============================================================================
// OHAudio Capturer 新式回调 API 动态加载（兼容旧设备缺失符号）
// 与 audio_renderer.cpp 同理：部分 API 12 设备的 libohaudio.so 缺少
// SetCapturerReadDataCallback / SetCapturerErrorCallback / SetCapturerInterruptCallback，
// 直接链接会导致整个 .so 加载失败。
// =============================================================================

typedef OH_AudioStream_Result (*PFN_SetCapturerReadDataCb)(
    OH_AudioStreamBuilder*, OH_AudioCapturer_OnReadDataCallback, void*);
typedef OH_AudioStream_Result (*PFN_SetCapturerErrorCb)(
    OH_AudioStreamBuilder*, OH_AudioCapturer_OnErrorCallback, void*);
typedef OH_AudioStream_Result (*PFN_SetCapturerInterruptCb)(
    OH_AudioStreamBuilder*, OH_AudioCapturer_OnInterruptCallback, void*);

static PFN_SetCapturerReadDataCb   g_pfnSetCapturerReadDataCb = nullptr;
static PFN_SetCapturerErrorCb      g_pfnSetCapturerErrorCb = nullptr;
static PFN_SetCapturerInterruptCb  g_pfnSetCapturerInterruptCb = nullptr;
static bool g_capturerApisChecked = false;

static void LoadCapturerApis() {
    if (g_capturerApisChecked) return;
    g_capturerApisChecked = true;

    void* handle = dlopen("libohaudio.so", RTLD_NOW);
    if (!handle) {
        OH_LOG_ERROR(LOG_APP, "Failed to dlopen libohaudio.so for capturer APIs");
        return;
    }

    g_pfnSetCapturerReadDataCb = (PFN_SetCapturerReadDataCb)
        dlsym(handle, "OH_AudioStreamBuilder_SetCapturerReadDataCallback");
    g_pfnSetCapturerErrorCb = (PFN_SetCapturerErrorCb)
        dlsym(handle, "OH_AudioStreamBuilder_SetCapturerErrorCallback");
    g_pfnSetCapturerInterruptCb = (PFN_SetCapturerInterruptCb)
        dlsym(handle, "OH_AudioStreamBuilder_SetCapturerInterruptCallback");

    OH_LOG_INFO(LOG_APP, "Capturer API probe: ReadDataCb=%{public}s ErrorCb=%{public}s InterruptCb=%{public}s",
                g_pfnSetCapturerReadDataCb ? "Y" : "N",
                g_pfnSetCapturerErrorCb ? "Y" : "N",
                g_pfnSetCapturerInterruptCb ? "Y" : "N");
    // 不 dlclose
}

// moonlight-common-c 的麦克风发送函数
extern "C" {
    int sendMicrophoneOpusData(const unsigned char* data, int length);
}

// =============================================================================
// 构造 / 析构
// =============================================================================

MicCapturer::MicCapturer() = default;

MicCapturer::~MicCapturer() {
    Cleanup();
}

// =============================================================================
// Init
// =============================================================================

int MicCapturer::Init(const MicCapturerConfig& config) {
    if (capturer_ != nullptr) {
        OH_LOG_WARN(LOG_APP, "MicCapturer already initialized, reinitializing");
        Cleanup();
    }

    config_ = config;

    // 计算目标帧字节数：samplesPerFrame * channels * sizeof(int16_t)
    int samplesPerFrame = config_.sampleRate * config_.frameSizeMs / 1000;
    frameSizeBytes_ = samplesPerFrame * config_.channels * 2; // 16-bit
    frameBufferPos_ = 0;

    OH_LOG_INFO(LOG_APP, "MicCapturer Init: rate=%{public}d ch=%{public}d bitrate=%{public}d frameMs=%{public}d frameBytes=%{public}d",
                config_.sampleRate, config_.channels, config_.opusBitrate,
                config_.frameSizeMs, frameSizeBytes_);

    // --- 初始化 Opus 编码器 ---
    int ret = encoder_.Init(config_.sampleRate, config_.channels, config_.opusBitrate);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to init Opus encoder: %{public}d", ret);
        return -1;
    }

    // --- 创建 OHAudio Capturer ---
    OH_AudioStream_Result result = OH_AudioStreamBuilder_Create(&builder_, AUDIOSTREAM_TYPE_CAPTURER);
    if (result != AUDIOSTREAM_SUCCESS || builder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to create AudioStreamBuilder: %{public}d", result);
        encoder_.Cleanup();
        return -2;
    }

    // 采样率
    OH_AudioStreamBuilder_SetSamplingRate(builder_, config_.sampleRate);
    // 声道
    OH_AudioStreamBuilder_SetChannelCount(builder_, config_.channels);
    // 格式 16-bit PCM
    OH_AudioStreamBuilder_SetSampleFormat(builder_, AUDIOSTREAM_SAMPLE_S16LE);
    // 编码类型 RAW
    OH_AudioStreamBuilder_SetEncodingType(builder_, AUDIOSTREAM_ENCODING_TYPE_RAW);

    // 录制场景：语音通信（自动带 AEC / AGC）
    OH_AudioStreamBuilder_SetCapturerInfo(builder_, AUDIOSTREAM_SOURCE_TYPE_VOICE_COMMUNICATION);

    // ★ 低时延模式 ★
    result = OH_AudioStreamBuilder_SetLatencyMode(builder_, AUDIOSTREAM_LATENCY_MODE_FAST);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "SetLatencyMode FAST failed: %{public}d (will fallback to NORMAL)", result);
    } else {
        OH_LOG_INFO(LOG_APP, "Mic latency mode set to FAST");
    }

    // 回调帧大小（尽量匹配 Opus 帧）
    result = OH_AudioStreamBuilder_SetFrameSizeInCallback(builder_, samplesPerFrame);
    if (result == AUDIOSTREAM_SUCCESS) {
        OH_LOG_INFO(LOG_APP, "Mic callback frame size: %{public}d samples", samplesPerFrame);
    } else {
        OH_LOG_WARN(LOG_APP, "SetFrameSizeInCallback failed: %{public}d (using system default)", result);
    }

    // 数据读入回调（通过 dlsym 动态加载，兼容旧设备）
    LoadCapturerApis();
    if (g_pfnSetCapturerReadDataCb) {
        result = g_pfnSetCapturerReadDataCb(builder_,
            reinterpret_cast<OH_AudioCapturer_OnReadDataCallback>(OnReadData), this);
        if (result != AUDIOSTREAM_SUCCESS) {
            OH_LOG_ERROR(LOG_APP, "Failed to set read data callback: %{public}d", result);
            OH_AudioStreamBuilder_Destroy(builder_);
            builder_ = nullptr;
            encoder_.Cleanup();
            return -3;
        }
    } else {
        OH_LOG_ERROR(LOG_APP, "SetCapturerReadDataCallback not available on this device!");
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        encoder_.Cleanup();
        return -3;
    }

    // 错误回调（可选 — 部分 API 12 设备不存在此符号）
    if (g_pfnSetCapturerErrorCb) {
        g_pfnSetCapturerErrorCb(builder_,
            reinterpret_cast<OH_AudioCapturer_OnErrorCallback>(OnError), this);
    } else {
        OH_LOG_INFO(LOG_APP, "SetCapturerErrorCallback not available, skipping");
    }

    // 中断回调（可选）
    if (g_pfnSetCapturerInterruptCb) {
        g_pfnSetCapturerInterruptCb(builder_,
            reinterpret_cast<OH_AudioCapturer_OnInterruptCallback>(OnInterruptEvent), this);
    } else {
        OH_LOG_INFO(LOG_APP, "SetCapturerInterruptCallback not available, skipping");
    }

    // 生成 capturer
    result = OH_AudioStreamBuilder_GenerateCapturer(builder_, &capturer_);
    if (result != AUDIOSTREAM_SUCCESS || capturer_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Failed to generate capturer: %{public}d", result);
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
        encoder_.Cleanup();
        return -4;
    }

    OH_LOG_INFO(LOG_APP, "MicCapturer initialized successfully");
    return 0;
}

// =============================================================================
// Start / Stop / Pause / Resume
// =============================================================================

int MicCapturer::Start() {
    if (capturer_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "MicCapturer not initialized");
        return -1;
    }

    // 重置统计
    framesCaptured_.store(0);
    framesEncoded_.store(0);
    framesSent_.store(0);
    framesDropped_.store(0);
    frameBufferPos_ = 0;

    OH_AudioStream_Result result = OH_AudioCapturer_Start(capturer_);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "Failed to start capturer: %{public}d", result);
        return -1;
    }

    running_.store(true, std::memory_order_release);
    paused_.store(false, std::memory_order_release);
    OH_LOG_INFO(LOG_APP, "MicCapturer started");
    return 0;
}

int MicCapturer::Stop() {
    running_.store(false, std::memory_order_release);

    if (capturer_ == nullptr) return 0;

    OH_AudioStream_Result result = OH_AudioCapturer_Stop(capturer_);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "Failed to stop capturer: %{public}d", result);
    }

    OH_LOG_INFO(LOG_APP, "MicCapturer stopped: captured=%{public}llu encoded=%{public}llu sent=%{public}llu dropped=%{public}llu",
                (unsigned long long)framesCaptured_.load(),
                (unsigned long long)framesEncoded_.load(),
                (unsigned long long)framesSent_.load(),
                (unsigned long long)framesDropped_.load());
    return 0;
}

void MicCapturer::Pause() {
    paused_.store(true, std::memory_order_release);
    OH_LOG_INFO(LOG_APP, "MicCapturer paused");
}

void MicCapturer::Resume() {
    paused_.store(false, std::memory_order_release);
    OH_LOG_INFO(LOG_APP, "MicCapturer resumed");
}

void MicCapturer::Cleanup() {
    Stop();

    if (capturer_ != nullptr) {
        OH_AudioCapturer_Release(capturer_);
        capturer_ = nullptr;
    }
    if (builder_ != nullptr) {
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
    }

    encoder_.Cleanup();
    frameBufferPos_ = 0;

    OH_LOG_INFO(LOG_APP, "MicCapturer cleaned up");
}

MicCapturerStats MicCapturer::GetStats() const {
    return {
        framesCaptured_.load(std::memory_order_relaxed),
        framesEncoded_.load(std::memory_order_relaxed),
        framesSent_.load(std::memory_order_relaxed),
        framesDropped_.load(std::memory_order_relaxed),
        false // TODO: query OH_AudioCapturer_GetFastStatus when API 20+ available
    };
}

// =============================================================================
// OHAudio 回调
// =============================================================================

OH_AudioData_Callback_Result MicCapturer::OnReadData(
    OH_AudioCapturer* capturer, void* userData,
    void* buffer, int32_t length)
{
    auto* self = static_cast<MicCapturer*>(userData);
    if (self == nullptr || !self->running_.load(std::memory_order_acquire)) {
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    if (self->paused_.load(std::memory_order_acquire)) {
        // 暂停时丢弃数据但返回 VALID 以保持流活跃
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    self->ProcessPcmFrame(static_cast<const uint8_t*>(buffer), length);
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

void MicCapturer::OnError(
    OH_AudioCapturer* capturer, void* userData,
    OH_AudioStream_Result error)
{
    OH_LOG_ERROR(LOG_APP, "MicCapturer error: %{public}d", error);
}

void MicCapturer::OnInterruptEvent(
    OH_AudioCapturer* capturer, void* userData,
    OH_AudioInterrupt_ForceType type, OH_AudioInterrupt_Hint hint)
{
    auto* self = static_cast<MicCapturer*>(userData);
    OH_LOG_INFO(LOG_APP, "MicCapturer interrupt: type=%{public}d hint=%{public}d", type, hint);

    if (type == AUDIOSTREAM_INTERRUPT_FORCE) {
        if (hint == AUDIOSTREAM_INTERRUPT_HINT_PAUSE || 
            hint == AUDIOSTREAM_INTERRUPT_HINT_STOP) {
            if (self) self->Pause();
        } else if (hint == AUDIOSTREAM_INTERRUPT_HINT_RESUME) {
            if (self) self->Resume();
        }
    }
}

// =============================================================================
// PCM 帧处理（在音频回调线程中执行）
// =============================================================================

void MicCapturer::ProcessPcmFrame(const uint8_t* data, int32_t length) {
    framesCaptured_.fetch_add(1, std::memory_order_relaxed);

    int offset = 0;
    while (offset < length) {
        // 填充帧累积缓冲区
        int needed = frameSizeBytes_ - frameBufferPos_;
        int available = length - offset;
        int toCopy = (available < needed) ? available : needed;

        memcpy(frameBuffer_ + frameBufferPos_, data + offset, toCopy);
        frameBufferPos_ += toCopy;
        offset += toCopy;

        // 帧累积满了，编码 + 发送
        if (frameBufferPos_ >= frameSizeBytes_) {
            int opusLen = encoder_.Encode(
                frameBuffer_, frameSizeBytes_,
                opusOutput_, kOpusMaxOutputBytes);

            if (opusLen > 0) {
                framesEncoded_.fetch_add(1, std::memory_order_relaxed);

                int ret = sendMicrophoneOpusData(opusOutput_, opusLen);
                if (ret >= 0) {
                    framesSent_.fetch_add(1, std::memory_order_relaxed);
                } else {
                    framesDropped_.fetch_add(1, std::memory_order_relaxed);
                }
            } else if (opusLen < 0) {
                framesDropped_.fetch_add(1, std::memory_order_relaxed);
            }
            // opusLen == 0: 编码器暂无输出（异步模式下正常）

            frameBufferPos_ = 0;
        }
    }
}
