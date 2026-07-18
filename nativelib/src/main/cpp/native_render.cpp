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
 * @file native_render.cpp
 * @brief NativeWindow 渲染器实现
 * 
 * 提供基本的 NativeWindow 管理功能：
 * - 保存 NativeWindow 引用供解码器使用
 * - 直接渲染模式（低延迟）
 * - VSync 渲染模式（使用 RenderOutputBufferAtTime 精确呈现）
 * - 高帧率优化：
 *   1. NativeVSync SetExpectedFrameRateRange（VSync 回调频率，API 20+）
 *   2. NativeWindow SetFrameRateRange（Surface buffer queue 帧率偏好，API 12+）
 *   3. XComponent SetExpectedFrameRateRange（ArkUI 框架层，由 MoonBridge 独立设置）
 */

#include "native_render.h"
#include <cstring>
#include <dlfcn.h>
#include <time.h>

#undef LOG_TAG
#define LOG_TAG "NativeRender"

// RenderOutputBufferAtTime 是 API 12+ 的函数，旧设备或不完整运行时可能不存在
// 通过 dlsym 动态加载，避免硬依赖
typedef OH_AVErrCode (*PFN_RenderOutputBufferAtTime)(OH_AVCodec*, uint32_t, int64_t);
static PFN_RenderOutputBufferAtTime g_pfnRenderAtTime = nullptr;
static std::once_flag g_renderAtTimeOnce;

static int64_t GetMonotonicTimeNs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

static PFN_RenderOutputBufferAtTime GetRenderAtTimeFunc() {
    std::call_once(g_renderAtTimeOnce, [] {
        g_pfnRenderAtTime = (PFN_RenderOutputBufferAtTime)
            dlsym(RTLD_DEFAULT, "OH_VideoDecoder_RenderOutputBufferAtTime");
        // RTLD_DEFAULT 可能在某些设备上找不到（如 API 22），回退到显式 dlopen
        if (!g_pfnRenderAtTime) {
            void* handle = dlopen("libnative_media_vdec.so", RTLD_NOW);
            if (handle) {
                g_pfnRenderAtTime = (PFN_RenderOutputBufferAtTime)
                    dlsym(handle, "OH_VideoDecoder_RenderOutputBufferAtTime");
            }
        }
    });
    return g_pfnRenderAtTime;
}

// =============================================================================
// 动态加载 API 20 函数（用于向后兼容）
// =============================================================================

// OH_NativeVSync_SetExpectedFrameRateRange 函数指针类型
typedef int (*PFN_OH_NativeVSync_SetExpectedFrameRateRange)(
    OH_NativeVSync* nativeVsync, OH_NativeVSync_ExpectedRateRange* range);

// 全局函数指针（懒加载）
static PFN_OH_NativeVSync_SetExpectedFrameRateRange g_pfnSetExpectedFrameRateRange = nullptr;
static bool g_api20Checked = false;
static bool g_api20Available = false;

// 检查并加载 API 20 函数
static bool CheckAndLoadApi20() {
    if (g_api20Checked) {
        return g_api20Available;
    }
    g_api20Checked = true;
    
    // 尝试动态加载函数
    void* handle = dlopen("libnative_vsync.so", RTLD_NOW);
    if (handle != nullptr) {
        g_pfnSetExpectedFrameRateRange = (PFN_OH_NativeVSync_SetExpectedFrameRateRange)
            dlsym(handle, "OH_NativeVSync_SetExpectedFrameRateRange");
        if (g_pfnSetExpectedFrameRateRange != nullptr) {
            g_api20Available = true;
            OH_LOG_INFO(LOG_APP, "API 20 OH_NativeVSync_SetExpectedFrameRateRange available");
        } else {
            OH_LOG_WARN(LOG_APP, "API 20 OH_NativeVSync_SetExpectedFrameRateRange not found");
        }
        // 注意：不要 dlclose，保持库加载
    } else {
        OH_LOG_WARN(LOG_APP, "Failed to load libnative_vsync.so: %{public}s", dlerror());
    }
    
    return g_api20Available;
}

// =============================================================================
// 静态成员初始化
// =============================================================================

NativeRender* NativeRender::instance_ = nullptr;
std::mutex NativeRender::instanceMutex_;

// =============================================================================
// NativeRender 单例实现
// =============================================================================

NativeRender* NativeRender::GetInstance() {
    std::lock_guard<std::mutex> lock(instanceMutex_);
    if (instance_ == nullptr) {
        instance_ = new NativeRender();
    }
    return instance_;
}

void NativeRender::ReleaseInstance() {
    std::lock_guard<std::mutex> lock(instanceMutex_);
    if (instance_ != nullptr) {
        delete instance_;
        instance_ = nullptr;
    }
}

NativeRender::NativeRender() {
    OH_LOG_INFO(LOG_APP, "NativeRender created");
}

NativeRender::~NativeRender() {
    OH_LOG_INFO(LOG_APP, "NativeRender destroyed");
    ReleaseNativeVSync();
    window_ = nullptr;
    surfaceReady_ = false;
}

// =============================================================================
// NativeVSync 管理
// =============================================================================

void NativeRender::InitNativeVSync() {
    std::lock_guard<std::mutex> lock(nativeVsyncMutex_);
    if (nativeVSync_ != nullptr) {
        return;
    }

    const char* name = "moonlight_render";
    nativeVSync_ = OH_NativeVSync_Create(name, strlen(name));
    if (nativeVSync_ != nullptr) {
        OH_LOG_INFO(LOG_APP, "NativeVSync created successfully");
    } else {
        OH_LOG_WARN(LOG_APP, "Failed to create NativeVSync");
    }
}

void NativeRender::ReleaseNativeVSync() {
    std::lock_guard<std::mutex> lock(nativeVsyncMutex_);
    if (nativeVSync_ == nullptr) {
        return;
    }

    OH_NativeVSync_Destroy(nativeVSync_);
    nativeVSync_ = nullptr;
    OH_LOG_INFO(LOG_APP, "NativeVSync destroyed");
}

// =============================================================================
// NativeWindow 管理
// =============================================================================

void NativeRender::SetNativeWindow(OHNativeWindow* window, uint64_t width, uint64_t height) {
    ResetPresentationClock();
    window_ = window;
    surfaceWidth_ = width;
    surfaceHeight_ = height;
    
    if (window != nullptr) {
        // 配置 NativeWindow
        ConfigureNativeWindow();
        
        // 初始化 NativeVSync
        InitNativeVSync();
        
        // 如果帧率已配置，立即应用帧率范围
        // 这处理 SetConfiguredFps 在 SetNativeWindow 之前调用的情况
        if (configuredFps_.load() > 0) {
            ApplyFrameRateRange();
        }
        
        surfaceReady_ = true;
        OH_LOG_INFO(LOG_APP, "NativeWindow set: %{public}p, size: %{public}lux%{public}lu", 
                    static_cast<void*>(window), width, height);
    } else {
        surfaceReady_ = false;
        ReleaseNativeVSync();
        OH_LOG_INFO(LOG_APP, "NativeWindow cleared");
    }
}

void NativeRender::SetConfiguredFps(double fps) {
    {
        std::lock_guard<std::mutex> lock(presentationMutex_);
        configuredFps_.store(fps);
        ptsScheduler_.Configure(fps);
        ResetPresentationClockLocked();
    }
    OH_LOG_INFO(LOG_APP, "Configured FPS set to: %.3f", fps);
    
    // 应用帧率范围（NativeVSync 层）
    ApplyFrameRateRange();
    
    // 应用帧率范围（NativeWindow/Surface 层）
    ApplyNativeWindowFrameRate();
}

void NativeRender::SetVsyncEnabled(bool enable) {
    bool wasEnabled = vsyncEnabled_.exchange(enable);
    if (wasEnabled != enable) {
        {
            std::lock_guard<std::mutex> lock(presentationMutex_);
            ResetPresentationClockLocked();
            ResetPresentationStatsLocked();
        }
        OH_LOG_INFO(LOG_APP, "VSync mode %{public}s", enable ? "enabled" : "disabled");
    }
}

void NativeRender::SetHostPacedPresentationEnabled(bool enable) {
    bool wasEnabled = hostPacedPresentationEnabled_.exchange(enable);
    if (wasEnabled != enable) {
        {
            std::lock_guard<std::mutex> lock(presentationMutex_);
            ResetPresentationClockLocked();
            ResetPresentationStatsLocked();
        }
        OH_LOG_INFO(LOG_APP, "Host-paced presentation %{public}s", enable ? "enabled" : "disabled");
    }
    if (enable && GetRenderAtTimeFunc() == nullptr) {
        OH_LOG_WARN(LOG_APP,
            "Host-paced presentation unavailable; keeping decoder low-latency policies active");
    }
}

bool NativeRender::IsHostPacedPresentationActive() const {
    return hostPacedPresentationEnabled_.load() && GetRenderAtTimeFunc() != nullptr;
}

void NativeRender::ConfigureNativeWindow() {
    if (window_ == nullptr) {
        return;
    }
    
    // 设置 ScalingMode V2（高帧率优化）
    int32_t ret = OH_NativeWindow_NativeWindowSetScalingModeV2(window_, OH_SCALING_MODE_SCALE_TO_WINDOW_V2);
    if (ret == 0) {
        OH_LOG_INFO(LOG_APP, "ScalingModeV2 set to SCALE_TO_WINDOW_V2");
    }
    
    // 如果帧率已配置，立即在 NativeWindow 层设置帧率偏好
    if (configuredFps_.load() > 60) {
        ApplyNativeWindowFrameRate();
    }
}

// =============================================================================
// NativeWindow 帧率设置（Surface buffer queue 级别）
// =============================================================================

// 动态加载的 NativeWindow 帧率 API 函数指针
// OH_NativeWindow_SetFrameRateRange(window, min, max, expected, strategy)
// strategy: 0 = DEFAULT, 1 = EXACT
typedef int32_t (*PFN_OH_NativeWindow_SetFrameRateRange)(
    OHNativeWindow* window, int32_t min, int32_t max, int32_t expected, int32_t strategy);

static PFN_OH_NativeWindow_SetFrameRateRange g_pfnNWSetFrameRateRange = nullptr;
static bool g_nwFrameRateChecked = false;

static bool CheckAndLoadNWFrameRateApi() {
    if (g_nwFrameRateChecked) {
        return g_pfnNWSetFrameRateRange != nullptr;
    }
    g_nwFrameRateChecked = true;
    
    // 尝试加载 OH_NativeWindow_SetFrameRateRange（API 12+）
    g_pfnNWSetFrameRateRange = (PFN_OH_NativeWindow_SetFrameRateRange)
        dlsym(RTLD_DEFAULT, "OH_NativeWindow_SetFrameRateRange");
    
    if (!g_pfnNWSetFrameRateRange) {
        void* handle = dlopen("libnative_window.so", RTLD_NOW);
        if (handle) {
            g_pfnNWSetFrameRateRange = (PFN_OH_NativeWindow_SetFrameRateRange)
                dlsym(handle, "OH_NativeWindow_SetFrameRateRange");
        }
    }
    
    if (g_pfnNWSetFrameRateRange) {
        OH_LOG_INFO(LOG_APP, "NativeWindow: OH_NativeWindow_SetFrameRateRange available");
    } else {
        OH_LOG_WARN(LOG_APP, "NativeWindow: OH_NativeWindow_SetFrameRateRange not available");
    }
    
    return g_pfnNWSetFrameRateRange != nullptr;
}

void NativeRender::ApplyNativeWindowFrameRate() {
    const double configuredFps = configuredFps_.load();
    if (window_ == nullptr || configuredFps <= 60) {
        return;
    }
    
    if (!CheckAndLoadNWFrameRateApi()) {
        return;
    }
    
    // strategy = 0 (DEFAULT): 让系统根据能力选择最佳刷新率
    const int fps = static_cast<int>(configuredFps + 0.5);
    int32_t ret = g_pfnNWSetFrameRateRange(window_, fps, fps, fps, 0);
    if (ret == 0) {
        OH_LOG_INFO(LOG_APP, "NativeWindow FrameRateRange set to %{public}d fps (Surface level)", fps);
    } else {
        OH_LOG_WARN(LOG_APP, "NativeWindow SetFrameRateRange failed: ret=%{public}d, fps=%{public}d", 
                    ret, fps);
    }
}

void NativeRender::ApplyFrameRateRange() {
    // NativeVSync SetExpectedFrameRateRange (API 20+)
    // 设置 VSync 回调的期望帧率，影响 VSync 信号频率
    // 注意：XComponent 帧率提示由 MoonBridge_SetXComponentFrameRate 通过 ArkUI_NodeHandle 独立设置
    std::lock_guard<std::mutex> lock(nativeVsyncMutex_);
    if (nativeVSync_ == nullptr) {
        return;
    }

    if (CheckAndLoadApi20()) {
        OH_NativeVSync_ExpectedRateRange range;
        const int fps = static_cast<int>(configuredFps_.load() + 0.5);
        range.min = fps;
        range.max = fps;
        range.expected = fps;
        
        int32_t ret = g_pfnSetExpectedFrameRateRange(nativeVSync_, &range);
        if (ret == 0) {
            OH_LOG_INFO(LOG_APP, "NativeVSync FrameRateRange set to fixed %{public}d fps",
                        fps);
        } else {
            OH_LOG_WARN(LOG_APP, "Failed to set NativeVSync FrameRateRange to %{public}d: ret=%{public}d", 
                        fps, ret);
        }
    }
}

// =============================================================================
// PTS presentation clocks
// =============================================================================

void NativeRender::ResetPresentationClockLocked() {
    ptsScheduler_.Reset();
    timeBaseInitialized_ = false;
    estimatedOffsetNs_ = 0;
    skewNs_ = 0;
    jitterEstNs_ = 0.0;
    lastPtsUs_ = 0;
}

void NativeRender::ResetPresentationStatsLocked() {
    vsyncFrameCount_ = 0;
    vsyncLateFrameCount_ = 0;
    vsyncResyncCount_ = 0;
    preciseScheduledCount_ = 0;
    preciseDroppedCount_ = 0;
    preciseLateCount_ = 0;
    precisePhaseShiftCount_ = 0;
    preciseRebufferCount_ = 0;
    preciseResyncCount_ = 0;
    preciseApiFailureCount_ = 0;
}

void NativeRender::ResetPresentationClock() {
    std::lock_guard<std::mutex> lock(presentationMutex_);
    ResetPresentationClockLocked();
}

int64_t NativeRender::CalculateLegacyPresentTargetLocked(int64_t pts, int64_t nowNs) {
    const int64_t hostNs = pts * 1000LL;
    const int64_t instOffset = nowNs - hostNs;
    const double configuredFps = configuredFps_.load();
    const int64_t frameIntervalNs = configuredFps > 0.0 ?
        static_cast<int64_t>(1000000000.0 / configuredFps) : 16666667LL;
    const bool discontinuity = timeBaseInitialized_ &&
        (pts < lastPtsUs_ || (pts - lastPtsUs_) > 2000000LL);

    if (!timeBaseInitialized_ || discontinuity) {
        if (discontinuity) {
            vsyncResyncCount_++;
        }
        estimatedOffsetNs_ = instOffset;
        skewNs_ = 0;
        jitterEstNs_ = static_cast<double>(frameIntervalNs) / 16.0;
        timeBaseInitialized_ = true;
        OH_LOG_INFO(LOG_APP,
            "Legacy VSync clock (re)anchored: offset=%{public}lldus, pts=%{public}lldus%{public}s",
            static_cast<long long>(estimatedOffsetNs_ / 1000),
            static_cast<long long>(pts), discontinuity ? " [discontinuity]" : "");
    } else {
        const int64_t pred = estimatedOffsetNs_ + skewNs_;
        const int64_t e = instOffset - pred;
        int64_t ec = e;
        if (ec > 8000000LL) ec = 8000000LL;
        else if (ec < -8000000LL) ec = -8000000LL;
        estimatedOffsetNs_ = pred + (ec / 64);
        skewNs_ += (ec / 2048);
        const double ae = static_cast<double>(e < 0 ? -e : e);
        jitterEstNs_ += (ae - jitterEstNs_) / 32.0;
    }
    lastPtsUs_ = pts;

    int64_t cushionNs = static_cast<int64_t>(3.0 * jitterEstNs_);
    if (cushionNs < 1000000LL) cushionNs = 1000000LL;
    if (cushionNs > frameIntervalNs) cushionNs = frameIntervalNs;

    const int64_t targetNs = hostNs + estimatedOffsetNs_ + cushionNs;
    if (targetNs < nowNs) {
        vsyncLateFrameCount_++;
    }

    if (++vsyncFrameCount_ % 6000 == 0) {
        OH_LOG_INFO(LOG_APP,
            "Legacy VSync stats: frames=%{public}lld, late=%{public}lld, resync=%{public}lld, cushion=%{public}lldus",
            static_cast<long long>(vsyncFrameCount_),
            static_cast<long long>(vsyncLateFrameCount_),
            static_cast<long long>(vsyncResyncCount_),
            static_cast<long long>(cushionNs / 1000));
    }
    return targetNs;
}

// =============================================================================
// 帧渲染
// =============================================================================

NativeRender::FrameSubmitResult NativeRender::SubmitFrame(const DecodedFrame& frame) {
    bool bufferConsumed = false;
    bool framePresented = false;
    auto renderImmediately = [&frame, &bufferConsumed, &framePresented]() {
        const OH_AVErrCode result =
            OH_VideoDecoder_RenderOutputBuffer(frame.codec, frame.bufferIndex);
        if (result == AV_ERR_OK) {
            bufferConsumed = true;
            framePresented = true;
        }
        return result;
    };
    auto freeFrame = [&frame, &bufferConsumed]() {
        if (bufferConsumed) return AV_ERR_OK;
        const OH_AVErrCode result =
            OH_VideoDecoder_FreeOutputBuffer(frame.codec, frame.bufferIndex);
        // Do not retry a failed release with an index whose ownership is unclear.
        bufferConsumed = true;
        return result;
    };

    OH_AVErrCode renderResult = AV_ERR_OK;
    if (!vsyncEnabled_.load() && !hostPacedPresentationEnabled_.load()) {
        renderResult = renderImmediately();
    } else {
        PFN_RenderOutputBufferAtTime renderAtTime = GetRenderAtTimeFunc();
        if (renderAtTime == nullptr) {
            renderResult = renderImmediately();
        } else if (!hostPacedPresentationEnabled_.load()) {
            const int64_t nowNs = GetMonotonicTimeNs();
            int64_t presentTimeNs;
            {
                std::lock_guard<std::mutex> lock(presentationMutex_);
                presentTimeNs = CalculateLegacyPresentTargetLocked(frame.ptsUs, nowNs);
            }
            renderResult = renderAtTime(frame.codec, frame.bufferIndex, presentTimeNs);
            if (renderResult == AV_ERR_OK) {
                bufferConsumed = true;
                framePresented = true;
            } else {
                renderResult = renderImmediately();
            }
        } else {
            const int64_t decodedAtNs = GetMonotonicTimeNs();
            PresentationPlan plan;
            {
                std::lock_guard<std::mutex> lock(presentationMutex_);
                plan = ptsScheduler_.PlanFrame(frame.ptsUs, decodedAtNs);
                if (plan.action == PresentationAction::SCHEDULE) {
                    preciseScheduledCount_++;
                } else {
                    preciseDroppedCount_++;
                }
                if (plan.latenessNs > 0) preciseLateCount_++;
                if (plan.event == PresentationEvent::PHASE_SHIFT) precisePhaseShiftCount_++;
                if (plan.event == PresentationEvent::REBUFFER) preciseRebufferCount_++;
                if (plan.event == PresentationEvent::DISCONTINUITY ||
                    plan.event == PresentationEvent::DUPLICATE_PTS) {
                    preciseResyncCount_++;
                }

                const int64_t totalFrames = preciseScheduledCount_ + preciseDroppedCount_;
                if (totalFrames % 6000 == 0) {
                    OH_LOG_INFO(LOG_APP,
                        "Host-paced stats: frames=%{public}lld, scheduled=%{public}lld, dropped=%{public}lld, late=%{public}lld, phaseShift=%{public}lld, rebuffer=%{public}lld, resync=%{public}lld, apiFailure=%{public}lld, lead=%{public}lldus",
                        static_cast<long long>(totalFrames),
                        static_cast<long long>(preciseScheduledCount_),
                        static_cast<long long>(preciseDroppedCount_),
                        static_cast<long long>(preciseLateCount_),
                        static_cast<long long>(precisePhaseShiftCount_),
                        static_cast<long long>(preciseRebufferCount_),
                        static_cast<long long>(preciseResyncCount_),
                        static_cast<long long>(preciseApiFailureCount_),
                        static_cast<long long>(ptsScheduler_.GetInitialLeadNs() / 1000));
                }
            }

            if (plan.action == PresentationAction::DROP) {
                renderResult = freeFrame();
            } else {
                renderResult = renderAtTime(
                    frame.codec, frame.bufferIndex, plan.targetTimeNs);
                if (renderResult == AV_ERR_OK) {
                    bufferConsumed = true;
                    framePresented = true;
                } else {
                    {
                        std::lock_guard<std::mutex> lock(presentationMutex_);
                        preciseApiFailureCount_++;
                    }
                    OH_LOG_WARN(LOG_APP,
                        "Host-paced render failed: %{public}d, pts=%{public}lld, targetNs=%{public}lld; falling back",
                        renderResult, static_cast<long long>(frame.ptsUs),
                        static_cast<long long>(plan.targetTimeNs));
                    renderResult = renderImmediately();
                }
            }
        }
    }

    if (renderResult != AV_ERR_OK && !bufferConsumed) {
        OH_LOG_WARN(LOG_APP, "RenderOutputBuffer failed: %{public}d; freeing output", renderResult);
        freeFrame();
    }
    return {renderResult, framePresented};
}
