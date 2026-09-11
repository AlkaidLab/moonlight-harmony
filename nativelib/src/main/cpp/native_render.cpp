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
// DisplaySoloist 帧率保活（API 12+，dlsym 动态加载）
// =============================================================================
// 官方为"游戏、自绘制 UI 框架"指定的独立线程帧率控制通道。
// 空回调即可让 DisplaySoloist 按期望帧率持续请求 vsync——该持续请求
// 替代触摸成为控帧系统（HGM）维持高刷新率的信号，对抗无触摸降频。

typedef struct DisplaySoloist_ExpectedRateRange {
    int32_t min;
    int32_t max;
    int32_t expected;
} DisplaySoloist_ExpectedRateRange;

typedef void* (*PFN_OH_DisplaySoloist_Create)(bool useExclusiveThread);
typedef int32_t (*PFN_OH_DisplaySoloist_Destroy)(void* displaySoloist);
typedef int32_t (*PFN_OH_DisplaySoloist_Start)(
    void* displaySoloist, void (*callback)(long long, long long, void*), void* data);
typedef int32_t (*PFN_OH_DisplaySoloist_Stop)(void* displaySoloist);
typedef int32_t (*PFN_OH_DisplaySoloist_SetExpectedFrameRateRange)(
    void* displaySoloist, DisplaySoloist_ExpectedRateRange* range);

static PFN_OH_DisplaySoloist_Create g_pfnSoloistCreate = nullptr;
static PFN_OH_DisplaySoloist_Destroy g_pfnSoloistDestroy = nullptr;
static PFN_OH_DisplaySoloist_Start g_pfnSoloistStart = nullptr;
static PFN_OH_DisplaySoloist_Stop g_pfnSoloistStop = nullptr;
static PFN_OH_DisplaySoloist_SetExpectedFrameRateRange g_pfnSoloistSetRange = nullptr;
static bool g_soloistChecked = false;

static bool CheckAndLoadSoloistApis() {
    if (g_soloistChecked) {
        return g_pfnSoloistCreate != nullptr;
    }
    g_soloistChecked = true;

    g_pfnSoloistCreate = (PFN_OH_DisplaySoloist_Create)dlsym(RTLD_DEFAULT, "OH_DisplaySoloist_Create");
    g_pfnSoloistDestroy = (PFN_OH_DisplaySoloist_Destroy)dlsym(RTLD_DEFAULT, "OH_DisplaySoloist_Destroy");
    g_pfnSoloistStart = (PFN_OH_DisplaySoloist_Start)dlsym(RTLD_DEFAULT, "OH_DisplaySoloist_Start");
    g_pfnSoloistStop = (PFN_OH_DisplaySoloist_Stop)dlsym(RTLD_DEFAULT, "OH_DisplaySoloist_Stop");
    g_pfnSoloistSetRange = (PFN_OH_DisplaySoloist_SetExpectedFrameRateRange)
        dlsym(RTLD_DEFAULT, "OH_DisplaySoloist_SetExpectedFrameRateRange");

    if (!g_pfnSoloistCreate || !g_pfnSoloistDestroy || !g_pfnSoloistStart ||
        !g_pfnSoloistStop || !g_pfnSoloistSetRange) {
        // 回退到显式 dlopen（部分运行时 RTLD_DEFAULT 找不到）
        const char* candidates[] = {"libnative_display_soloist.so", "libnative_display_soloist.z.so"};
        for (const char* lib : candidates) {
            void* handle = dlopen(lib, RTLD_NOW);
            if (handle == nullptr) continue;
            if (!g_pfnSoloistCreate)
                g_pfnSoloistCreate = (PFN_OH_DisplaySoloist_Create)dlsym(handle, "OH_DisplaySoloist_Create");
            if (!g_pfnSoloistDestroy)
                g_pfnSoloistDestroy = (PFN_OH_DisplaySoloist_Destroy)dlsym(handle, "OH_DisplaySoloist_Destroy");
            if (!g_pfnSoloistStart)
                g_pfnSoloistStart = (PFN_OH_DisplaySoloist_Start)dlsym(handle, "OH_DisplaySoloist_Start");
            if (!g_pfnSoloistStop)
                g_pfnSoloistStop = (PFN_OH_DisplaySoloist_Stop)dlsym(handle, "OH_DisplaySoloist_Stop");
            if (!g_pfnSoloistSetRange)
                g_pfnSoloistSetRange = (PFN_OH_DisplaySoloist_SetExpectedFrameRateRange)
                    dlsym(handle, "OH_DisplaySoloist_SetExpectedFrameRateRange");
            if (g_pfnSoloistCreate && g_pfnSoloistDestroy && g_pfnSoloistStart &&
                g_pfnSoloistStop && g_pfnSoloistSetRange) {
                break;
            }
        }
    }

    if (g_pfnSoloistCreate && g_pfnSoloistDestroy && g_pfnSoloistStart &&
        g_pfnSoloistStop && g_pfnSoloistSetRange) {
        OH_LOG_INFO(LOG_APP, "DisplaySoloist APIs available (frame-rate keepalive enabled)");
    } else {
        OH_LOG_WARN(LOG_APP, "DisplaySoloist APIs not available; keepalive limited to hint layers");
    }
    return g_pfnSoloistCreate != nullptr && g_pfnSoloistDestroy != nullptr &&
           g_pfnSoloistStart != nullptr && g_pfnSoloistStop != nullptr &&
           g_pfnSoloistSetRange != nullptr;
}

// DisplaySoloist 空回调：仅维持按期望帧率的持续 vsync 请求，不做任何绘制
static void EmptySoloistFrameCallback(long long /*timestamp*/, long long /*targetTimestamp*/, void* /*data*/) {}

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
    {
        std::lock_guard<std::mutex> lock(frameRateMutex_);
        if (displaySoloist_ != nullptr && g_pfnSoloistStop && g_pfnSoloistDestroy) {
            g_pfnSoloistStop(displaySoloist_);
            g_pfnSoloistDestroy(displaySoloist_);
            displaySoloist_ = nullptr;
        }
    }
    window_ = nullptr;
    surfaceReady_ = false;
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

        // Surface 绑定/重建会冲掉系统侧已采信的帧率决策，立即重申全部 hint
        RefreshFrameRateHints(true);

        surfaceReady_ = true;
        OH_LOG_INFO(LOG_APP, "NativeWindow set: %{public}p, size: %{public}lux%{public}lu",
                    static_cast<void*>(window), width, height);
    } else {
        surfaceReady_ = false;
        ResetFrameRateHintsToDefault();
        OH_LOG_INFO(LOG_APP, "NativeWindow cleared");
    }
}

void NativeRender::SetConfiguredFps(double fps) {
    {
        std::lock_guard<std::mutex> lock(presentationMutex_);
        configuredFps_.store(fps);
        twoStepScheduler_.Configure(fps);
        ResetPresentationClockLocked();
    }
    OH_LOG_INFO(LOG_APP, "Configured FPS set to: %.3f", fps);

    // 帧率变化：立即重申 NativeWindow hint 并同步 DisplaySoloist 节奏
    RefreshFrameRateHints(true);
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

TwoStepPresentationStats NativeRender::GetTwoStepPresentationStats() const {
    std::lock_guard<std::mutex> lock(presentationMutex_);
    return twoStepScheduler_.GetStats();
}

PresentationTargetHandle NativeRender::PreparePresentationFrame(int64_t ptsUs) {
    if (!IsHostPacedPresentationActive()) {
        return {};
    }

    const int64_t preparedAtNs = GetMonotonicTimeNs();
    std::lock_guard<std::mutex> lock(presentationMutex_);
    return twoStepScheduler_.PrepareFrame(ptsUs, preparedAtNs);
}

void NativeRender::DiscardPresentationFrame(
        PresentationTargetHandle handle) {
    if (!handle) {
        return;
    }

    std::lock_guard<std::mutex> lock(presentationMutex_);
    twoStepScheduler_.DiscardFrame(handle);
}

void NativeRender::DiscardPresentationFrame(int64_t ptsUs) {
    if (!hostPacedPresentationEnabled_.load()) {
        return;
    }

    std::lock_guard<std::mutex> lock(presentationMutex_);
    twoStepScheduler_.DiscardFrame(ptsUs);
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

    // 注意：该符号不在公开 NDK 头文件中（仅 dlsym），strategy 语义无官方文档，
    // 社区用法 0=DEFAULT / 1=EXACT。DEFAULT 已证实在鸿蒙7 智能帧率下被降档，
    // 高帧率串流时改用 EXACT 明确请求固定刷新率；range 按 LTPO 官方建议留出
    // 协商区间（min<max），避免 min=max=expected 的官方反模式。
    const int fps = static_cast<int>(configuredFps + 0.5);
    int32_t ret = g_pfnNWSetFrameRateRange(window_, 0, 120, fps, 1);
    if (ret == 0) {
        OH_LOG_INFO(LOG_APP, "NativeWindow FrameRateRange set to expected %{public}d fps EXACT (Surface level)", fps);
    } else {
        OH_LOG_WARN(LOG_APP, "NativeWindow SetFrameRateRange failed: ret=%{public}d, fps=%{public}d",
                    ret, fps);
    }
}

void NativeRender::EnsureDisplaySoloistLocked() {
    const double configuredFps = configuredFps_.load();
    const bool shouldRun = frameRateKeepAlive_.load() && configuredFps > 60;

    if (!shouldRun) {
        if (displaySoloist_ != nullptr && g_pfnSoloistStop && g_pfnSoloistDestroy) {
            g_pfnSoloistStop(displaySoloist_);
            g_pfnSoloistDestroy(displaySoloist_);
            displaySoloist_ = nullptr;
            OH_LOG_INFO(LOG_APP, "DisplaySoloist keepalive stopped");
        }
        return;
    }

    if (!CheckAndLoadSoloistApis()) {
        return;
    }

    bool freshlyCreated = false;
    if (displaySoloist_ == nullptr) {
        displaySoloist_ = static_cast<OH_DisplaySoloist*>(g_pfnSoloistCreate(true));
        if (displaySoloist_ == nullptr) {
            OH_LOG_WARN(LOG_APP, "OH_DisplaySoloist_Create failed");
            return;
        }
        freshlyCreated = true;
    }

    // range 留出协商区间（min<max），expected 锁定串流帧率；
    // 按官方示例顺序 Create → SetExpectedFrameRateRange → Start
    DisplaySoloist_ExpectedRateRange range;
    range.min = 0;
    range.max = 120;
    range.expected = static_cast<int32_t>(configuredFps + 0.5);
    int32_t ret = g_pfnSoloistSetRange(displaySoloist_, &range);
    if (ret != 0) {
        OH_LOG_WARN(LOG_APP, "DisplaySoloist SetExpectedFrameRateRange failed: ret=%{public}d", ret);
        return;
    }

    if (freshlyCreated) {
        // 空回调即可让 Soloist 按期望帧率持续请求 vsync；已运行的实例只更新 range
        if (g_pfnSoloistStart(displaySoloist_, EmptySoloistFrameCallback, nullptr) == 0) {
            OH_LOG_INFO(LOG_APP, "DisplaySoloist keepalive running (exclusive thread, expected %{public}d fps)",
                        range.expected);
        } else {
            OH_LOG_WARN(LOG_APP, "DisplaySoloist Start failed");
        }
    }
}

void NativeRender::RefreshFrameRateHints(bool force) {
    // SubmitFrame 每帧调用：节流检查只碰原子量，2 秒内直接返回
    const int64_t nowNs = GetMonotonicTimeNs();
    int64_t lastNs = lastHintRefreshNs_.load();
    if (!force && nowNs - lastNs < 2000000000LL) {
        return;
    }
    if (!lastHintRefreshNs_.compare_exchange_strong(lastNs, nowNs)) {
        return;
    }

    std::lock_guard<std::mutex> lock(frameRateMutex_);
    ApplyNativeWindowFrameRate();
    EnsureDisplaySoloistLocked();
}

void NativeRender::SetFrameRateKeepAlive(bool enabled) {
    frameRateKeepAlive_.store(enabled);
    OH_LOG_INFO(LOG_APP, "Frame-rate keepalive %{public}s", enabled ? "enabled" : "disabled");
    if (enabled) {
        RefreshFrameRateHints(true);
    } else {
        ResetFrameRateHintsToDefault();
    }
}

void NativeRender::ResetFrameRateHintsToDefault() {
    std::lock_guard<std::mutex> lock(frameRateMutex_);

    if (displaySoloist_ != nullptr && g_pfnSoloistStop && g_pfnSoloistDestroy) {
        g_pfnSoloistStop(displaySoloist_);
        g_pfnSoloistDestroy(displaySoloist_);
        displaySoloist_ = nullptr;
        OH_LOG_INFO(LOG_APP, "DisplaySoloist destroyed");
    }

    // 复位为 60fps 默认请求，避免高刷 hint 在流结束后残留耗电
    if (window_ != nullptr && CheckAndLoadNWFrameRateApi()) {
        int32_t ret = g_pfnNWSetFrameRateRange(window_, 0, 120, 60, 0);
        OH_LOG_INFO(LOG_APP, "NativeWindow FrameRateRange reset to default 60: ret=%{public}d", ret);
    }
}

// =============================================================================
// PTS presentation clocks
// =============================================================================

void NativeRender::ResetPresentationClockLocked() {
    twoStepScheduler_.Reset();
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
    twoStepScheduler_.ResetStats();
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
    // 渲染期间持续重申帧率 hint（2 秒节流）：帧率请求是"一次设置会被
    // Surface/布局变化或系统策略冲掉"的易失状态，必须持续重申才能在
    // 无触摸时维持高刷新率。空帧间隔时无解码帧到达，不会有更频繁的调用。
    RefreshFrameRateHints(false);

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
            PreparedPresentationPlan plan;
            {
                std::lock_guard<std::mutex> lock(presentationMutex_);
                plan = twoStepScheduler_.PlanDecodedFrame(
                    frame.ptsUs, decodedAtNs);
            }

            if (plan.action == PreparedPresentationAction::DROP) {
                renderResult = freeFrame();
            } else if (plan.action == PreparedPresentationAction::IMMEDIATE) {
                renderResult = renderImmediately();
            } else {
                renderResult = renderAtTime(
                    frame.codec, frame.bufferIndex, plan.targetTimeNs);
                if (renderResult == AV_ERR_OK) {
                    bufferConsumed = true;
                    framePresented = true;
                } else {
                    {
                        std::lock_guard<std::mutex> lock(presentationMutex_);
                        twoStepScheduler_.NoteRenderAtTimeFallback();
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
