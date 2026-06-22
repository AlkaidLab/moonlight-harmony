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
 *   3. DisplaySoloist SetExpectedFrameRateRange（显示层持续 vsync 请求，API 12+）
 *   4. XComponent SetExpectedFrameRateRange（ArkUI 框架层，由 MoonBridge 独立设置）
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
// DisplaySoloist 动态加载（API 12+，避免低版本硬依赖）
// =============================================================================

struct DisplaySoloistExpectedRateRange {
    int32_t min;
    int32_t max;
    int32_t expected;
};

typedef void (*PFN_DisplaySoloistFrameCallback)(long long timestamp, long long targetTimestamp, void* data);
typedef void* (*PFN_DisplaySoloistCreate)(bool useExclusiveThread);
typedef int32_t (*PFN_DisplaySoloistDestroy)(void* displaySoloist);
typedef int32_t (*PFN_DisplaySoloistStart)(void* displaySoloist, PFN_DisplaySoloistFrameCallback callback, void* data);
typedef int32_t (*PFN_DisplaySoloistStop)(void* displaySoloist);
typedef int32_t (*PFN_DisplaySoloistSetExpectedFrameRateRange)(
    void* displaySoloist, DisplaySoloistExpectedRateRange* range);

static PFN_DisplaySoloistCreate g_pfnDisplaySoloistCreate = nullptr;
static PFN_DisplaySoloistDestroy g_pfnDisplaySoloistDestroy = nullptr;
static PFN_DisplaySoloistStart g_pfnDisplaySoloistStart = nullptr;
static PFN_DisplaySoloistStop g_pfnDisplaySoloistStop = nullptr;
static PFN_DisplaySoloistSetExpectedFrameRateRange g_pfnDisplaySoloistSetRate = nullptr;
static bool g_displaySoloistChecked = false;

static void DisplaySoloistFrameCallback(long long, long long, void*) {
    // 空回调即可让 DisplaySoloist 按期望帧率持续请求 vsync。
}

static bool CheckAndLoadDisplaySoloistApi() {
    if (g_displaySoloistChecked) {
        return g_pfnDisplaySoloistCreate && g_pfnDisplaySoloistDestroy && g_pfnDisplaySoloistStart &&
               g_pfnDisplaySoloistStop && g_pfnDisplaySoloistSetRate;
    }
    g_displaySoloistChecked = true;

    g_pfnDisplaySoloistCreate = (PFN_DisplaySoloistCreate)dlsym(RTLD_DEFAULT, "OH_DisplaySoloist_Create");
    g_pfnDisplaySoloistDestroy = (PFN_DisplaySoloistDestroy)dlsym(RTLD_DEFAULT, "OH_DisplaySoloist_Destroy");
    g_pfnDisplaySoloistStart = (PFN_DisplaySoloistStart)dlsym(RTLD_DEFAULT, "OH_DisplaySoloist_Start");
    g_pfnDisplaySoloistStop = (PFN_DisplaySoloistStop)dlsym(RTLD_DEFAULT, "OH_DisplaySoloist_Stop");
    g_pfnDisplaySoloistSetRate = (PFN_DisplaySoloistSetExpectedFrameRateRange)
        dlsym(RTLD_DEFAULT, "OH_DisplaySoloist_SetExpectedFrameRateRange");

    if (!g_pfnDisplaySoloistCreate || !g_pfnDisplaySoloistDestroy || !g_pfnDisplaySoloistStart ||
        !g_pfnDisplaySoloistStop || !g_pfnDisplaySoloistSetRate) {
        void* handle = dlopen("libnative_display_soloist.so", RTLD_NOW);
        if (!handle) {
            handle = dlopen("libnative_display_soloist.z.so", RTLD_NOW);
        }
        if (handle) {
            if (!g_pfnDisplaySoloistCreate) {
                g_pfnDisplaySoloistCreate = (PFN_DisplaySoloistCreate)dlsym(handle, "OH_DisplaySoloist_Create");
            }
            if (!g_pfnDisplaySoloistDestroy) {
                g_pfnDisplaySoloistDestroy = (PFN_DisplaySoloistDestroy)dlsym(handle, "OH_DisplaySoloist_Destroy");
            }
            if (!g_pfnDisplaySoloistStart) {
                g_pfnDisplaySoloistStart = (PFN_DisplaySoloistStart)dlsym(handle, "OH_DisplaySoloist_Start");
            }
            if (!g_pfnDisplaySoloistStop) {
                g_pfnDisplaySoloistStop = (PFN_DisplaySoloistStop)dlsym(handle, "OH_DisplaySoloist_Stop");
            }
            if (!g_pfnDisplaySoloistSetRate) {
                g_pfnDisplaySoloistSetRate = (PFN_DisplaySoloistSetExpectedFrameRateRange)
                    dlsym(handle, "OH_DisplaySoloist_SetExpectedFrameRateRange");
            }
        }
    }

    bool available = g_pfnDisplaySoloistCreate && g_pfnDisplaySoloistDestroy && g_pfnDisplaySoloistStart &&
                     g_pfnDisplaySoloistStop && g_pfnDisplaySoloistSetRate;
    if (available) {
        OH_LOG_INFO(LOG_APP, "DisplaySoloist frame pacing API available");
    } else {
        OH_LOG_WARN(LOG_APP, "DisplaySoloist frame pacing API not available");
    }
    return available;
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
    ReleaseDisplaySoloist();
    ReleaseNativeVSync();
    window_ = nullptr;
    surfaceReady_ = false;
}

// =============================================================================
// NativeVSync 管理
// =============================================================================

void NativeRender::InitNativeVSync() {
    if (nativeVSync_ != nullptr) {
        return;  // 已初始化
    }
    
    // 创建 NativeVSync 实例
    const char* name = "moonlight_render";
    nativeVSync_ = OH_NativeVSync_Create(name, strlen(name));
    if (nativeVSync_ != nullptr) {
        OH_LOG_INFO(LOG_APP, "NativeVSync created successfully");
    } else {
        OH_LOG_WARN(LOG_APP, "Failed to create NativeVSync");
    }
}

void NativeRender::ReleaseNativeVSync() {
    if (nativeVSync_ != nullptr) {
        OH_NativeVSync_Destroy(nativeVSync_);
        nativeVSync_ = nullptr;
        OH_LOG_INFO(LOG_APP, "NativeVSync destroyed");
    }
}

void NativeRender::InitDisplaySoloist() {
    std::lock_guard<std::recursive_mutex> lock(frameRateMutex_);
    if (displaySoloist_ != nullptr || configuredFps_ <= 60 || !displayFramePacerEnabled_.load()) {
        return;
    }

    if (!CheckAndLoadDisplaySoloistApi()) {
        return;
    }

    displaySoloist_ = g_pfnDisplaySoloistCreate(true);
    if (!displaySoloist_) {
        OH_LOG_WARN(LOG_APP, "DisplaySoloist create failed");
        return;
    }

    ApplyDisplaySoloistFrameRate();
    int32_t ret = g_pfnDisplaySoloistStart(displaySoloist_, DisplaySoloistFrameCallback, this);
    if (ret == 0) {
        displaySoloistStarted_ = true;
        OH_LOG_INFO(LOG_APP, "DisplaySoloist started for %{public}d fps keepalive", configuredFps_);
    } else {
        OH_LOG_WARN(LOG_APP, "DisplaySoloist start failed: ret=%{public}d", ret);
        g_pfnDisplaySoloistDestroy(displaySoloist_);
        displaySoloist_ = nullptr;
        displaySoloistStarted_ = false;
    }
}

void NativeRender::ReleaseDisplaySoloist() {
    std::lock_guard<std::recursive_mutex> lock(frameRateMutex_);
    if (displaySoloist_ == nullptr) {
        return;
    }

    if (displaySoloistStarted_ && g_pfnDisplaySoloistStop) {
        g_pfnDisplaySoloistStop(displaySoloist_);
    }
    if (g_pfnDisplaySoloistDestroy) {
        g_pfnDisplaySoloistDestroy(displaySoloist_);
    }
    displaySoloist_ = nullptr;
    displaySoloistStarted_ = false;
    OH_LOG_INFO(LOG_APP, "DisplaySoloist stopped");
}

void NativeRender::SetDisplayFramePacerEnabled(bool enable) {
    std::lock_guard<std::recursive_mutex> lock(frameRateMutex_);
    displayFramePacerEnabled_.store(enable);
    OH_LOG_INFO(LOG_APP, "Display frame pacer %{public}s for configured fps=%{public}d",
                enable ? "enabled" : "disabled", configuredFps_);

    if (enable && configuredFps_ > 60) {
        InitDisplaySoloist();
        RefreshFrameRateHints(true);
    } else {
        ReleaseDisplaySoloist();
        ResetFrameRateHintsToDefault();
    }
}

// =============================================================================
// NativeWindow 管理
// =============================================================================

void NativeRender::SetNativeWindow(OHNativeWindow* window, uint64_t width, uint64_t height) {
    std::lock_guard<std::recursive_mutex> lock(frameRateMutex_);
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
        if (configuredFps_ > 0 && nativeVSync_ != nullptr) {
            RefreshFrameRateHints(true);
        }
        
        surfaceReady_ = true;
        OH_LOG_INFO(LOG_APP, "NativeWindow set: %{public}p, size: %{public}lux%{public}lu", 
                    static_cast<void*>(window), width, height);
    } else {
        surfaceReady_ = false;
        ReleaseDisplaySoloist();
        ReleaseNativeVSync();
        OH_LOG_INFO(LOG_APP, "NativeWindow cleared");
    }
}

void NativeRender::SetConfiguredFps(int fps) {
    std::lock_guard<std::recursive_mutex> lock(frameRateMutex_);
    int oldFps = configuredFps_;
    configuredFps_ = fps;
    OH_LOG_INFO(LOG_APP, "Configured FPS set to: %{public}d", fps);
    
    // 重置时间基准
    timeBaseInitialized_ = false;
    
    // 应用帧率范围（NativeVSync 层）
    ApplyFrameRateRange();
    
    // 应用帧率范围（NativeWindow/Surface 层）
    ApplyNativeWindowFrameRate();

    if (displayFramePacerEnabled_.load() && configuredFps_ > 60) {
        ReleaseDisplaySoloist();
        InitDisplaySoloist();
    } else if (configuredFps_ <= 60) {
        ReleaseDisplaySoloist();
        if (oldFps > 60) {
            ResetFrameRateHintsToDefault();
        }
    }
}

void NativeRender::SetVsyncEnabled(bool enable) {
    bool wasEnabled = vsyncEnabled_.exchange(enable);
    if (wasEnabled != enable) {
        // 重置时间基准
        timeBaseInitialized_ = false;
        OH_LOG_INFO(LOG_APP, "VSync mode %{public}s", enable ? "enabled" : "disabled");
    }
}

void NativeRender::ConfigureNativeWindow() {
    std::lock_guard<std::recursive_mutex> lock(frameRateMutex_);
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
        RefreshFrameRateHints(true);
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
    std::lock_guard<std::recursive_mutex> lock(frameRateMutex_);
    ApplyNativeWindowFrameRateValue(configuredFps_, true);
}

void NativeRender::ApplyNativeWindowFrameRateValue(int fps, bool exact) {
    if (window_ == nullptr || fps <= 0) {
        return;
    }
    
    if (!CheckAndLoadNWFrameRateApi()) {
        return;
    }
    
    // strategy = 1 (EXACT): 高帧率串流时明确请求固定刷新率，避免智能帧率回落到 60Hz。
    constexpr int32_t NATIVE_WINDOW_FRAME_RATE_STRATEGY_EXACT = 1;
    constexpr int32_t NATIVE_WINDOW_FRAME_RATE_STRATEGY_DEFAULT = 0;
    int32_t strategy = exact ? NATIVE_WINDOW_FRAME_RATE_STRATEGY_EXACT : NATIVE_WINDOW_FRAME_RATE_STRATEGY_DEFAULT;
    int32_t ret = g_pfnNWSetFrameRateRange(
        window_, fps, fps, fps, strategy);
    if (ret == 0) {
        OH_LOG_INFO(LOG_APP, "NativeWindow FrameRateRange set to %{public}d/%{public}d/%{public}d fps (%{public}s)",
                    fps, fps, fps, exact ? "EXACT" : "DEFAULT");
    } else {
        OH_LOG_WARN(LOG_APP, "NativeWindow SetFrameRateRange failed: ret=%{public}d, fps=%{public}d", 
                    ret, fps);
    }
}

void NativeRender::ApplyDisplaySoloistFrameRate() {
    std::lock_guard<std::recursive_mutex> lock(frameRateMutex_);
    ApplyDisplaySoloistFrameRateValue(configuredFps_);
}

void NativeRender::ApplyDisplaySoloistFrameRateValue(int fps) {
    if (displaySoloist_ == nullptr || fps <= 60 || !g_pfnDisplaySoloistSetRate) {
        return;
    }

    DisplaySoloistExpectedRateRange range = { fps, fps, fps };
    int32_t ret = g_pfnDisplaySoloistSetRate(displaySoloist_, &range);
    if (ret == 0) {
        OH_LOG_INFO(LOG_APP, "DisplaySoloist FrameRateRange set to %{public}d/%{public}d/%{public}d fps",
                    fps, fps, fps);
    } else {
        OH_LOG_WARN(LOG_APP, "DisplaySoloist SetExpectedFrameRateRange failed: ret=%{public}d, fps=%{public}d",
                    ret, fps);
    }
}

void NativeRender::ApplyFrameRateRange() {
    std::lock_guard<std::recursive_mutex> lock(frameRateMutex_);
    ApplyFrameRateRangeValue(configuredFps_);
}

void NativeRender::ApplyFrameRateRangeValue(int fps) {
    // NativeVSync SetExpectedFrameRateRange (API 20+)
    // 设置 VSync 回调的期望帧率，影响 VSync 信号频率
    // 注意：XComponent 帧率提示由 MoonBridge_SetXComponentFrameRate 通过 ArkUI_NodeHandle 独立设置
    if (nativeVSync_ != nullptr && CheckAndLoadApi20()) {
        OH_NativeVSync_ExpectedRateRange range;
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

void NativeRender::ResetFrameRateHintsToDefault() {
    OH_LOG_INFO(LOG_APP, "Resetting frame rate hints to default 60 fps");
    ApplyFrameRateRangeValue(60);
    ApplyNativeWindowFrameRateValue(60, false);
}

void NativeRender::RefreshFrameRateHints(bool force) {
    std::lock_guard<std::recursive_mutex> lock(frameRateMutex_);
    if (configuredFps_ <= 60) {
        return;
    }

    auto now = std::chrono::steady_clock::now();
    if (!force && (now - lastFrameRateHintTime_) < std::chrono::seconds(2)) {
        return;
    }
    lastFrameRateHintTime_ = now;

    OH_LOG_INFO(LOG_APP, "Refreshing frame rate hints: configured fps=%{public}d", configuredFps_);
    ApplyFrameRateRange();
    ApplyNativeWindowFrameRate();

    if (displayFramePacerEnabled_.load()) {
        if (displaySoloist_ == nullptr) {
            InitDisplaySoloist();
        } else {
            ApplyDisplaySoloistFrameRate();
        }
    }
}

// =============================================================================
// 帧呈现时间计算（VSync 模式）
// =============================================================================

int64_t NativeRender::CalculatePresentTime(int64_t pts) const {
    // 获取当前系统时间（纳秒）
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    int64_t nowNs = static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
    
    // 初始化时间基准
    if (!timeBaseInitialized_) {
        baseSystemTimeNs_ = nowNs;
        basePtsUs_ = pts;
        timeBaseInitialized_ = true;
        OH_LOG_INFO(LOG_APP, "VSync time base initialized: basePts=%{public}lld us", 
                    static_cast<long long>(basePtsUs_));
    }
    
    // 计算相对于基准的 PTS 偏移（转换为纳秒）
    int64_t ptsDeltaNs = (pts - basePtsUs_) * 1000LL;
    
    // 目标呈现时间 = 基准系统时间 + PTS 偏移
    int64_t targetPresentTimeNs = baseSystemTimeNs_ + ptsDeltaNs;
    
    // 如果目标时间已经过去，使用当前时间 + 小延迟
    // 避免使用过去的时间戳导致帧被丢弃
    if (targetPresentTimeNs < nowNs) {
        // 添加半个帧间隔的偏移，给 compositor 一些处理时间
        int64_t frameIntervalNs = 1000000000LL / configuredFps_;
        targetPresentTimeNs = nowNs + frameIntervalNs / 2;
        
        // 重新同步时间基准（避免持续漂移）
        baseSystemTimeNs_ = targetPresentTimeNs - ptsDeltaNs;
    }
    
    return targetPresentTimeNs;
}

// =============================================================================
// 帧渲染
// =============================================================================

void NativeRender::SubmitFrame(OH_AVCodec* codec, uint32_t bufferIndex, int64_t pts, int64_t enqueueTimeMs) {
    int32_t renderResult;
    RefreshFrameRateHints(false);
    
    if (vsyncEnabled_.load()) {
        // VSync 模式：使用 RenderOutputBufferAtTime 精确控制呈现时间
        PFN_RenderOutputBufferAtTime renderAtTime = GetRenderAtTimeFunc();
        if (renderAtTime != nullptr) {
            int64_t presentTimeNs = CalculatePresentTime(pts);
            renderResult = renderAtTime(codec, bufferIndex, presentTimeNs);
            
            if (renderResult != 0) {
                OH_LOG_WARN(LOG_APP, "RenderOutputBufferAtTime failed: %{public}d, pts=%{public}lld, presentNs=%{public}lld",
                            renderResult, static_cast<long long>(pts), static_cast<long long>(presentTimeNs));
            }
        } else {
            // RenderOutputBufferAtTime 不可用，回退到直接渲染
            renderResult = OH_VideoDecoder_RenderOutputBuffer(codec, bufferIndex);
            if (renderResult != 0) {
                OH_LOG_WARN(LOG_APP, "RenderOutputBuffer (vsync fallback) failed: %{public}d", renderResult);
            }
        }
    } else {
        // 低延迟模式：直接渲染
        renderResult = OH_VideoDecoder_RenderOutputBuffer(codec, bufferIndex);
        
        if (renderResult != 0) {
            OH_LOG_WARN(LOG_APP, "RenderOutputBuffer failed: %{public}d", renderResult);
        }
    }
    
    // 更新上一帧时间
    lastFrameTime_ = std::chrono::steady_clock::now();
}
