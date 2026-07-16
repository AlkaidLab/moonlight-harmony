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
 * @file native_render.h
 * @brief NativeWindow 渲染器头文件
 * 
 * 提供基本的 NativeWindow 管理功能：
 * - 保存 NativeWindow 引用供解码器使用
 * - 直接渲染模式（低延迟）
 * - VSync 渲染模式（使用 RenderOutputBufferAtTime）
 * - 高帧率优化：
 *   1. NativeVSync SetExpectedFrameRateRange（VSync 回调频率，API 20+）
 *   2. NativeWindow SetFrameRateRange（Surface buffer queue 帧率偏好，API 12+）
 *   3. XComponent SetExpectedFrameRateRange（ArkUI 框架层，由 MoonBridge 独立设置）
 */

#ifndef NATIVE_RENDER_H
#define NATIVE_RENDER_H

#include <native_window/external_window.h>
#include <native_vsync/native_vsync.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <hilog/log.h>

#include <cstdint>
#include <mutex>
#include <atomic>
#include <chrono>
#include <map>

/**
 * NativeRender 类
 * 管理 NativeWindow 并提供直接渲染
 */
class NativeRender {
public:
    /**
     * 获取单例实例
     */
    static NativeRender* GetInstance();
    
    /**
     * 释放单例实例
     */
    static void ReleaseInstance();
    
    /**
     * 获取 NativeWindow
     */
    OHNativeWindow* GetNativeWindow() const { return window_; }
    
    /**
     * 设置 NativeWindow（由 ArkTS 层调用）
     */
    void SetNativeWindow(OHNativeWindow* window, uint64_t width, uint64_t height);
    
    /**
     * 配置帧率（用于高帧率优化）
     * @param fps 期望帧率
     */
    void SetConfiguredFps(int fps);
    
    /**
     * 获取配置的帧率
     */
    int GetConfiguredFps() const { return configuredFps_; }
    
    /**
     * 启用/禁用 VSync 渲染模式
     * @param enable true 使用 RenderOutputBufferAtTime，false 使用 RenderOutputBuffer
     */
    void SetVsyncEnabled(bool enable);
    
    /**
     * 获取 VSync 是否启用
     */
    bool IsVsyncEnabled() const { return vsyncEnabled_; }

    /**
     * 启用/禁用二步精确同步；开启时内部自行使用 VSync，不依赖 VSync 设置开关。
     */
    void SetTwoStepPreciseSyncEnabled(bool enable);
    bool IsTwoStepPreciseSyncEnabled() const { return twoStepPreciseSyncEnabled_; }
    
    /**
     * step1：帧到达解码管线时，用 host PTS 生成去抖的本地呈现目标。
     */
    void PrepareFrame(int64_t pts);

    /**
     * 丢弃尚未呈现的帧目标。
     */
    void DiscardFrame(int64_t pts);

    /**
     * 清空帧目标并强制下一帧重新锚定（Flush/重连/Surface 切换）。
     */
    void ResetPresentationClock();

    /**
     * step2：解码输出时将 step1 目标对齐到最近 VSync 并呈现。
     * 无效目标、不支持定时呈现或 API 失败时立即回退直接呈现。
     */
    OH_AVErrCode SubmitFrame(OH_AVCodec* codec, uint32_t bufferIndex, int64_t pts, int64_t enqueueTimeMs);
    
    // Surface 尺寸
    uint64_t GetSurfaceWidth() const { return surfaceWidth_; }
    uint64_t GetSurfaceHeight() const { return surfaceHeight_; }
    
    // 检查 Surface 是否就绪
    bool IsSurfaceReady() const { return surfaceReady_; }
    
private:
    NativeRender();
    ~NativeRender();
    
    // 禁止拷贝
    NativeRender(const NativeRender&) = delete;
    NativeRender& operator=(const NativeRender&) = delete;
    
    // 配置 NativeWindow
    void ConfigureNativeWindow();
    
    // 应用帧率范围（通过 NativeVSync，API 20+）
    void ApplyFrameRateRange();
    
    // 应用 NativeWindow 帧率（Surface buffer queue 级别，API 12+）
    void ApplyNativeWindowFrameRate();
    
    // 初始化 NativeVSync
    void InitNativeVSync();
    
    // 释放 NativeVSync
    void ReleaseNativeVSync();

    // 请求一次 VSync 样本，供 step2 做相位对齐
    void RequestVsyncSample();

    // 已持有 presentationMutex_ 时使用
    int64_t CalculatePresentTargetLocked(int64_t pts, int64_t nowNs, bool twoStep);
    void ResetPresentationClockLocked();

    // 将目标向上对齐到最近的真实 VSync；无有效相位时返回原目标
    int64_t SnapTargetToVsync(int64_t targetNs, int64_t nowNs) const;

private:
    // 单例
    static NativeRender* instance_;
    static std::mutex instanceMutex_;
    
    // Surface 相关
    OHNativeWindow* window_ = nullptr;
    uint64_t surfaceWidth_ = 0;
    uint64_t surfaceHeight_ = 0;
    std::atomic<bool> surfaceReady_{false};
    
    // 帧率配置
    int configuredFps_ = 60;
    
    // VSync 模式
    std::atomic<bool> vsyncEnabled_{false};
    std::atomic<bool> twoStepPreciseSyncEnabled_{false};
    
    // 帧率范围已经应用过（NativeVSync）
    bool frameRateApplied_ = false;
    
    // 两步呈现状态：step1 host-PI 去抖，step2 对齐本地 VSync
    mutable std::mutex presentationMutex_;
    std::map<int64_t, int64_t> pendingPresentTargets_;
    static constexpr size_t kMaxPendingPresentTargets = 64;

    // Host PTS 去抖时钟。旧 VSync 模式在解码输出时计算目标；二步模式在输入时预计算，
    // 再于输出时向上对齐真实 VSync。两者共享 offset/skew 与在线抖动估计。
    int64_t estimatedOffsetNs_ = 0;  // 平滑后的 (本地 - host) 偏移均值(纳秒)
    int64_t skewNs_ = 0;             // 每帧频差估计(纳秒/帧)，消除时钟 skew 斜坡滞后
    double  jitterEstNs_ = 0.0;      // 在线抖动估计(平均绝对偏差, 纳秒)，驱动自适应 cushion
    int64_t lastPtsUs_ = 0;          // 上一帧 host PTS(微秒)，用于检测不连续(重连/跳变)
    bool timeBaseInitialized_ = false;

    // VSync 去抖时钟的运行统计(用于评估收益/风险)
    int64_t vsyncFrameCount_ = 0;      // step1 生成目标的帧数
    int64_t vsyncLateFrameCount_ = 0;  // step1 目标在生成时已过期的帧数
    int64_t vsyncResyncCount_ = 0;     // 因 PTS 不连续而重锚定的次数
    int64_t twoStepHitCount_ = 0;      // step2 命中预计算目标的帧数
    int64_t twoStepFallbackCount_ = 0; // 缺失/无效目标或定时 API 失败的回退次数
    
    // NativeVSync（用于设置期望帧率范围，API 20+）
    std::mutex nativeVsyncMutex_;
    OH_NativeVSync* nativeVSync_ = nullptr;
    
    // 上一帧渲染时间（用于帧率控制）
    std::chrono::steady_clock::time_point lastFrameTime_;
};

#endif // NATIVE_RENDER_H
