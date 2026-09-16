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
 * - DisplaySoloist 持续请求期望帧率，系统仍可按设备策略限制刷新率。
 * - 每 2 秒检查请求状态、重试失败，并聚合回调频率诊断。
 */

#ifndef NATIVE_RENDER_H
#define NATIVE_RENDER_H

#include <native_window/external_window.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <hilog/log.h>

#include "two_step_presentation_scheduler.h"

#include <cstdint>
#include <mutex>
#include <atomic>

// DisplaySoloist 完整声明在 native_display_soloist.h；此处仅前向声明，
// 实现包含 SDK 头文件校验类型，并通过 dlsym 动态加载符号。
typedef struct OH_DisplaySoloist OH_DisplaySoloist;

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
    void SetConfiguredFps(double fps);

    /**
     * 启用/禁用 DisplaySoloist 请求；displayHz 与串流调度 FPS 分开。
     * 此通道仅支持 60 < displayHz <= 120，更高目标由 ArkUI 请求。
     * 禁用时停止并释放 Soloist，
     * 避免高刷请求在流结束后残留耗电。
     */
    void SetFrameRateKeepAlive(bool enabled, int32_t displayHz = 0);

    /**
     * 检查 DisplaySoloist 请求状态并聚合诊断；已有相同请求不重复设置。
     * @param force true 跳过节流立即重申；false 按 2 秒节流
     */
    void RefreshFrameRateHints(bool force);
    
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
     * Enable host-PTS paced presentation. The existing setting/API name is
     * retained for compatibility with persisted preferences.
    */
    void SetHostPacedPresentationEnabled(bool enable);
    bool IsHostPacedPresentationActive() const;
    TwoStepPresentationStats GetTwoStepPresentationStats() const;

    // Step 1: reserve the host-PTS target before the frame enters the decoder.
    PresentationTargetHandle PreparePresentationFrame(int64_t ptsUs);
    void DiscardPresentationFrame(PresentationTargetHandle handle);
    void DiscardPresentationFrame(int64_t ptsUs);
    
    /**
     * 强制下一帧重新锚定（Flush/重连/Surface 切换）。
     */
    void ResetPresentationClock();

    struct DecodedFrame {
        OH_AVCodec* codec = nullptr;
        uint32_t bufferIndex = 0;
        int64_t ptsUs = 0;
    };

    struct FrameSubmitResult {
        OH_AVErrCode status = AV_ERR_OK;
        bool presented = false;
    };

    // Takes ownership of the decoder output buffer for every return value.
    FrameSubmitResult SubmitFrame(const DecodedFrame& frame);
    
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

    static void SoloistFrameCallback(long long timestamp, long long targetTimestamp, void* data);

    // 按 keepAlive_ 与 configuredFps_ 状态启动/更新/停止 DisplaySoloist（须持有 frameRateMutex_）
    void EnsureDisplaySoloistLocked();

    // 流结束/禁用时停止 Soloist 并复位诊断窗口
    void ResetFrameRateHintsToDefault();

    // 已持有 presentationMutex_ 时使用
    int64_t CalculateLegacyPresentTargetLocked(int64_t pts, int64_t nowNs);
    void ResetPresentationClockLocked();
    void ResetPresentationStatsLocked();

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
    std::atomic<double> configuredFps_{60.0};
    
    // VSync 模式
    std::atomic<bool> vsyncEnabled_{false};
    std::atomic<bool> hostPacedPresentationEnabled_{false};
    
    // Timed presentation state. Legacy VSync and host-paced presentation use
    // separate clocks so switching decoder modes cannot perturb PTS cadence.
    mutable std::mutex presentationMutex_;
    TwoStepPresentationScheduler twoStepScheduler_;

    // Legacy VSync clock, kept isolated from the host-paced scheduler.
    int64_t estimatedOffsetNs_ = 0;  // 平滑后的 (本地 - host) 偏移均值(纳秒)
    int64_t skewNs_ = 0;             // 每帧频差估计(纳秒/帧)，消除时钟 skew 斜坡滞后
    double  jitterEstNs_ = 0.0;      // 在线抖动估计(平均绝对偏差, 纳秒)，驱动自适应 cushion
    int64_t lastPtsUs_ = 0;          // 上一帧 host PTS(微秒)，用于检测不连续(重连/跳变)
    bool timeBaseInitialized_ = false;

    int64_t vsyncFrameCount_ = 0;
    int64_t vsyncLateFrameCount_ = 0;
    int64_t vsyncResyncCount_ = 0;

    // DisplaySoloist 请求和诊断状态
    // 序列化 NativeWindow/Soloist 操作；SubmitFrame 热路径只读原子量
    std::mutex frameRateMutex_;
    std::atomic<bool> frameRateKeepAlive_{false};
    std::atomic<int32_t> displayRequestHz_{0};
    std::atomic<int64_t> lastHintRefreshNs_{0};
    OH_DisplaySoloist* displaySoloist_ = nullptr;
    int32_t soloistExpectedHz_ = 0;
    std::atomic<uint64_t> soloistCallbacks_{0};
    std::atomic<uint64_t> submittedFrames_{0};
    int64_t diagnosticStartNs_ = 0;
    uint64_t diagnosticCallbacks_ = 0;
    uint64_t diagnosticSubmissions_ = 0;
};

#endif // NATIVE_RENDER_H
