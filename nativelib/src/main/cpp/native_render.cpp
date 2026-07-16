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

// RenderOutputBufferAtTime 是 API 14+ 的函数，低版本设备不存在
// 通过 dlsym 动态加载，避免硬依赖
typedef OH_AVErrCode (*PFN_RenderOutputBufferAtTime)(OH_AVCodec*, uint32_t, int64_t);
static PFN_RenderOutputBufferAtTime g_pfnRenderAtTime = nullptr;
static bool g_renderAtTimeChecked = false;

// VSync 回调只写入进程级原子状态，避免 Surface 销毁时回调持有悬空对象。
static std::atomic<int64_t> g_lastVsyncTimestampNs{0};
static std::atomic<int64_t> g_vsyncPeriodNs{0};

static void OnNativeVsync(long long timestamp, void* data) {
    (void)data;
    if (timestamp > 0) {
        g_lastVsyncTimestampNs.store(static_cast<int64_t>(timestamp), std::memory_order_release);
    }
}

static int64_t GetMonotonicTimeNs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

static PFN_RenderOutputBufferAtTime GetRenderAtTimeFunc() {
    if (!g_renderAtTimeChecked) {
        g_renderAtTimeChecked = true;
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
    }
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
    lastFrameTime_ = std::chrono::steady_clock::now();
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
    bool created = false;
    {
        std::lock_guard<std::mutex> lock(nativeVsyncMutex_);
        if (nativeVSync_ != nullptr) {
            return;
        }

        const char* name = "moonlight_render";
        nativeVSync_ = OH_NativeVSync_Create(name, strlen(name));
        if (nativeVSync_ != nullptr) {
            long long periodNs = 0;
            if (OH_NativeVSync_GetPeriod(nativeVSync_, &periodNs) != 0 || periodNs <= 0) {
                const int fps = configuredFps_ > 0 ? configuredFps_ : 60;
                periodNs = 1000000000LL / fps;
                OH_LOG_WARN(LOG_APP,
                    "NativeVSync period unavailable; using %{public}d FPS fallback", fps);
            }
            g_vsyncPeriodNs.store(static_cast<int64_t>(periodNs), std::memory_order_release);
            created = true;
            OH_LOG_INFO(LOG_APP, "NativeVSync created successfully, period=%{public}lldns", periodNs);
        } else {
            OH_LOG_WARN(LOG_APP, "Failed to create NativeVSync");
        }
    }

    if (created && twoStepPreciseSyncEnabled_.load()) {
        RequestVsyncSample();
    }
}

void NativeRender::ReleaseNativeVSync() {
    std::lock_guard<std::mutex> lock(nativeVsyncMutex_);
    if (nativeVSync_ == nullptr) {
        return;
    }

    OH_NativeVSync_Destroy(nativeVSync_);
    nativeVSync_ = nullptr;
    lastVsyncRequestFailureLogNs_ = 0;
    g_lastVsyncTimestampNs.store(0, std::memory_order_release);
    g_vsyncPeriodNs.store(0, std::memory_order_release);
    OH_LOG_INFO(LOG_APP, "NativeVSync destroyed");
}

void NativeRender::RequestVsyncSample() {
    std::lock_guard<std::mutex> lock(nativeVsyncMutex_);
    if (nativeVSync_ == nullptr) {
        return;
    }

    // GetPeriod only becomes valid after the first VSync callback. Query it on
    // the following frame while the instance is protected from destruction.
    if (g_lastVsyncTimestampNs.load(std::memory_order_acquire) > 0) {
        long long periodNs = 0;
        if (OH_NativeVSync_GetPeriod(nativeVSync_, &periodNs) == 0 && periodNs > 0) {
            g_vsyncPeriodNs.store(static_cast<int64_t>(periodNs), std::memory_order_release);
        }
    }

    int32_t ret = OH_NativeVSync_RequestFrame(nativeVSync_, OnNativeVsync, nullptr);
    if (ret != 0) {
        constexpr int64_t kFailureLogIntervalNs = 10000000000LL;
        const int64_t nowNs = GetMonotonicTimeNs();
        if (lastVsyncRequestFailureLogNs_ == 0 ||
            nowNs - lastVsyncRequestFailureLogNs_ >= kFailureLogIntervalNs) {
            lastVsyncRequestFailureLogNs_ = nowNs;
            OH_LOG_DEBUG(LOG_APP, "NativeVSync sample request failed: %{public}d", ret);
        }
    }
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
        if (configuredFps_ > 0) {
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

void NativeRender::SetConfiguredFps(int fps) {
    configuredFps_ = fps;
    OH_LOG_INFO(LOG_APP, "Configured FPS set to: %{public}d", fps);

    ResetPresentationClock();
    
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
        if (enable && twoStepPreciseSyncEnabled_.load()) {
            RequestVsyncSample();
        }
        OH_LOG_INFO(LOG_APP, "VSync mode %{public}s", enable ? "enabled" : "disabled");
    }
}

void NativeRender::SetTwoStepPreciseSyncEnabled(bool enable) {
    bool wasEnabled = twoStepPreciseSyncEnabled_.exchange(enable);
    if (wasEnabled != enable) {
        {
            std::lock_guard<std::mutex> lock(presentationMutex_);
            ResetPresentationClockLocked();
            ResetPresentationStatsLocked();
        }
        if (enable) {
            RequestVsyncSample();
        }
        OH_LOG_INFO(LOG_APP, "Two-step precise sync %{public}s", enable ? "enabled" : "disabled");
    }
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
    if (configuredFps_ > 60) {
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
    if (window_ == nullptr || configuredFps_ <= 60) {
        return;
    }
    
    if (!CheckAndLoadNWFrameRateApi()) {
        return;
    }
    
    // strategy = 0 (DEFAULT): 让系统根据能力选择最佳刷新率
    int32_t ret = g_pfnNWSetFrameRateRange(window_, configuredFps_, configuredFps_, configuredFps_, 0);
    if (ret == 0) {
        OH_LOG_INFO(LOG_APP, "NativeWindow FrameRateRange set to %{public}d fps (Surface level)", configuredFps_);
    } else {
        OH_LOG_WARN(LOG_APP, "NativeWindow SetFrameRateRange failed: ret=%{public}d, fps=%{public}d", 
                    ret, configuredFps_);
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
        range.min = configuredFps_;
        range.max = configuredFps_;
        range.expected = configuredFps_;
        
        int32_t ret = g_pfnSetExpectedFrameRateRange(nativeVSync_, &range);
        if (ret == 0) {
            OH_LOG_INFO(LOG_APP, "NativeVSync FrameRateRange set to fixed %{public}d fps",
                        configuredFps_);
        } else {
            OH_LOG_WARN(LOG_APP, "Failed to set NativeVSync FrameRateRange to %{public}d: ret=%{public}d", 
                        configuredFps_, ret);
        }
    }

    long long periodNs = 0;
    if (OH_NativeVSync_GetPeriod(nativeVSync_, &periodNs) != 0 || periodNs <= 0) {
        const int fps = configuredFps_ > 0 ? configuredFps_ : 60;
        periodNs = 1000000000LL / fps;
    }
    g_vsyncPeriodNs.store(static_cast<int64_t>(periodNs), std::memory_order_release);
}

// =============================================================================
// 两步呈现时钟
// =============================================================================

void NativeRender::ResetPresentationClockLocked() {
    timeBaseInitialized_ = false;
    estimatedOffsetNs_ = 0;
    skewNs_ = 0;
    jitterEstNs_ = 0.0;
    lastPtsUs_ = 0;
    lastScheduledPresentNs_ = 0;
}

void NativeRender::ResetPresentationStatsLocked() {
    vsyncFrameCount_ = 0;
    vsyncLateFrameCount_ = 0;
    vsyncResyncCount_ = 0;
    twoStepHitCount_ = 0;
    twoStepFallbackCount_ = 0;
    twoStepSameSlotCount_ = 0;
    twoStepDrainReanchorCount_ = 0;
}

void NativeRender::ResetPresentationClock() {
    std::lock_guard<std::mutex> lock(presentationMutex_);
    ResetPresentationClockLocked();
}

int64_t NativeRender::CalculatePresentTargetLocked(int64_t pts, int64_t nowNs, bool twoStep,
                                                   bool forceReanchor) {
    const int64_t hostNs = pts * 1000LL;
    const int64_t instOffset = nowNs - hostNs;
    const int64_t frameIntervalNs = configuredFps_ > 0 ? 1000000000LL / configuredFps_ : 16666667LL;
    const bool discontinuity = timeBaseInitialized_ &&
        (pts < lastPtsUs_ || (pts - lastPtsUs_) > 2000000LL);

    if (forceReanchor || !timeBaseInitialized_ || discontinuity) {
        if (forceReanchor) {
            twoStepDrainReanchorCount_++;
        } else if (discontinuity) {
            vsyncResyncCount_++;
        }
        estimatedOffsetNs_ = instOffset;
        skewNs_ = 0;
        jitterEstNs_ = static_cast<double>(frameIntervalNs) / 16.0;
        timeBaseInitialized_ = true;
        if (!forceReanchor) {
            OH_LOG_INFO(LOG_APP, "VSync clock (re)anchored: offset=%{public}lldus, pts=%{public}lldus%{public}s",
                        static_cast<long long>(estimatedOffsetNs_ / 1000),
                        static_cast<long long>(pts), discontinuity ? " [discontinuity]" : "");
        }
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

    // 二步模式的 VSync 向上取整自带约半帧余量；基线模式保留原 3×MAD + 1ms cushion。
    int64_t cushionNs = static_cast<int64_t>((twoStep ? 0.5 : 3.0) * jitterEstNs_);
    if (!twoStep && cushionNs < 1000000LL) cushionNs = 1000000LL;
    if (cushionNs > frameIntervalNs) cushionNs = frameIntervalNs;

    const int64_t targetNs = hostNs + estimatedOffsetNs_ + cushionNs;
    if (targetNs < nowNs) {
        vsyncLateFrameCount_++;
    }

    if (++vsyncFrameCount_ % 6000 == 0) {
        const int64_t vsyncPeriodUs =
            g_vsyncPeriodNs.load(std::memory_order_acquire) / 1000;
        OH_LOG_INFO(LOG_APP,
            "VSync clock stats: mode=%{public}s, frames=%{public}lld, late=%{public}lld, resync=%{public}lld, hit=%{public}lld, fallback=%{public}lld, sameSlot=%{public}lld, drainReanchor=%{public}lld, period=%{public}lldus, cushion=%{public}lldus",
            twoStep ? "two-step" : "baseline",
            static_cast<long long>(vsyncFrameCount_), static_cast<long long>(vsyncLateFrameCount_),
            static_cast<long long>(vsyncResyncCount_), static_cast<long long>(twoStepHitCount_),
            static_cast<long long>(twoStepFallbackCount_), static_cast<long long>(twoStepSameSlotCount_),
            static_cast<long long>(twoStepDrainReanchorCount_),
            static_cast<long long>(vsyncPeriodUs),
            static_cast<long long>(cushionNs / 1000));
    }
    return targetNs;
}

int64_t NativeRender::SnapTargetToVsync(int64_t targetNs, int64_t nowNs) const {
    const int64_t phaseNs = g_lastVsyncTimestampNs.load(std::memory_order_acquire);
    const int64_t periodNs = g_vsyncPeriodNs.load(std::memory_order_acquire);
    if (phaseNs <= 0 || periodNs <= 0) {
        return targetNs;
    }

    const int64_t phaseAgeNs = nowNs - phaseNs;
    if (phaseAgeNs < -periodNs || phaseAgeNs > periodNs * 4) {
        return targetNs;
    }

    const int64_t rawNs = targetNs < nowNs ? nowNs : targetNs;
    if (rawNs <= phaseNs) {
        return phaseNs;
    }
    const int64_t deltaNs = rawNs - phaseNs;
    return phaseNs + ((deltaNs + periodNs - 1) / periodNs) * periodNs;
}

// =============================================================================
// 帧渲染
// =============================================================================

OH_AVErrCode NativeRender::SubmitFrame(OH_AVCodec* codec, uint32_t bufferIndex, int64_t pts,
                                       bool drainToLatest) {
    auto renderImmediately = [codec, bufferIndex]() {
        return OH_VideoDecoder_RenderOutputBuffer(codec, bufferIndex);
    };
    auto noteFallback = [this]() {
        std::lock_guard<std::mutex> lock(presentationMutex_);
        twoStepFallbackCount_++;
    };

    OH_AVErrCode renderResult = AV_ERR_OK;
    if (!vsyncEnabled_.load() && !twoStepPreciseSyncEnabled_.load()) {
        renderResult = renderImmediately();
    } else {
        PFN_RenderOutputBufferAtTime renderAtTime = GetRenderAtTimeFunc();
        if (renderAtTime == nullptr) {
            if (twoStepPreciseSyncEnabled_.load()) {
                noteFallback();
            }
            renderResult = renderImmediately();
        } else if (!twoStepPreciseSyncEnabled_.load()) {
            // A/B 基线：保留原有的解码输出时采样 + 较大 cushion，不做 VSync 相位 snap。
            const int64_t nowNs = GetMonotonicTimeNs();
            int64_t presentTimeNs;
            {
                std::lock_guard<std::mutex> lock(presentationMutex_);
                presentTimeNs = CalculatePresentTargetLocked(pts, nowNs, false);
            }
            renderResult = renderAtTime(codec, bufferIndex, presentTimeNs);
            if (renderResult != AV_ERR_OK) {
                renderResult = renderImmediately();
            }
        } else {
            const int64_t nowNs = GetMonotonicTimeNs();
            RequestVsyncSample();
            int64_t targetNs;
            {
                std::lock_guard<std::mutex> lock(presentationMutex_);
                // step1 必须在解码输出到达时采样，目标才包含解码和排队耗时。
                targetNs = CalculatePresentTargetLocked(pts, nowNs, true, drainToLatest);
            }

            // step2 只负责把已恢复的 host 节奏落到本地显示槽。
            int64_t presentTimeNs = SnapTargetToVsync(targetNs, nowNs);
            if (drainToLatest) {
                std::lock_guard<std::mutex> lock(presentationMutex_);
                // Surface 按提交顺序处理；已有未来帧时让最新帧进入同槽覆盖，避免倒序时间戳。
                if (lastScheduledPresentNs_ >= nowNs && presentTimeNs < lastScheduledPresentNs_) {
                    presentTimeNs = lastScheduledPresentNs_;
                }
            }
            const int64_t frameIntervalNs = configuredFps_ > 0 ?
                1000000000LL / configuredFps_ : 16666667LL;
            const int64_t timeUntilPresentNs = presentTimeNs - nowNs;

            if (timeUntilPresentNs < 0 || timeUntilPresentNs > frameIntervalNs * 3) {
                noteFallback();
                ResetPresentationClock();
                renderResult = renderImmediately();
            } else {
                renderResult = renderAtTime(codec, bufferIndex, presentTimeNs);
                if (renderResult == AV_ERR_OK) {
                    std::lock_guard<std::mutex> lock(presentationMutex_);
                    if (lastScheduledPresentNs_ >= nowNs && presentTimeNs <= lastScheduledPresentNs_) {
                        twoStepSameSlotCount_++;
                    }
                    if (presentTimeNs > lastScheduledPresentNs_) {
                        lastScheduledPresentNs_ = presentTimeNs;
                    }
                    twoStepHitCount_++;
                } else {
                    OH_LOG_WARN(LOG_APP,
                        "RenderOutputBufferAtTime failed: %{public}d, pts=%{public}lld, presentNs=%{public}lld; falling back",
                        renderResult, static_cast<long long>(pts), static_cast<long long>(presentTimeNs));
                    noteFallback();
                    renderResult = renderImmediately();
                }
            }
        }
    }

    if (renderResult != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "RenderOutputBuffer failed: %{public}d", renderResult);
    }
    lastFrameTime_ = std::chrono::steady_clock::now();
    return renderResult;
}
