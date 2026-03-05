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

// =============================================================================
// NativeWindow 管理
// =============================================================================

void NativeRender::SetNativeWindow(OHNativeWindow* window, uint64_t width, uint64_t height) {
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
    
    // 重置时间基准
    timeBaseInitialized_ = false;
    
    // 应用帧率范围（NativeVSync 层）
    ApplyFrameRateRange();
    
    // 应用帧率范围（NativeWindow/Surface 层）
    ApplyNativeWindowFrameRate();
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
    if (nativeVSync_ != nullptr && CheckAndLoadApi20()) {
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
