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
 *   3. DisplaySoloist SetExpectedFrameRateRange（显示层持续 vsync 请求，API 12+）
 *   4. XComponent SetExpectedFrameRateRange（ArkUI 框架层，由 MoonBridge 独立设置）
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
     * 启动/停止显示高刷保持（DisplaySoloist）
     */
    void SetDisplayFramePacerEnabled(bool enable);

    /**
     * 重新应用各 native 层帧率提示（用于前后台/Surface 恢复/智能帧率保活）
     */
    void RefreshFrameRateHints(bool force = false);
    
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
     * 提交渲染帧
     * @param codec 解码器实例
     * @param bufferIndex 缓冲区索引
     * @param pts 呈现时间戳（微秒）
     * @param enqueueTimeMs 入队时间（毫秒）
     */
    void SubmitFrame(OH_AVCodec* codec, uint32_t bufferIndex, int64_t pts, int64_t enqueueTimeMs);
    
    // Surface 尺寸
    uint64_t GetSurfaceWidth() const { return surfaceWidth_; }
    uint64_t GetSurfaceHeight() const { return surfaceHeight_; }
    
    // 检查 Surface 是否就绪
    bool IsSurfaceReady() const { return surfaceReady_; }
    
    // 计算 VSync 呈现时间（供 VideoDecoder 同步模式使用）
    int64_t CalculatePresentTime(int64_t pts) const;

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
    void ApplyFrameRateRangeValue(int fps);
    
    // 应用 NativeWindow 帧率（Surface buffer queue 级别，API 12+）
    void ApplyNativeWindowFrameRate();
    void ApplyNativeWindowFrameRateValue(int fps, bool exact);
    
    // 初始化 NativeVSync
    void InitNativeVSync();
    
    // 释放 NativeVSync
    void ReleaseNativeVSync();

    // 初始化/释放 DisplaySoloist
    void InitDisplaySoloist();
    void ReleaseDisplaySoloist();

    // 应用 DisplaySoloist 帧率（显示层持续 vsync 请求，API 12+）
    void ApplyDisplaySoloistFrameRate();
    void ApplyDisplaySoloistFrameRateValue(int fps);

    // 将 NativeVSync / NativeWindow 帧率提示恢复到 60Hz 默认值
    void ResetFrameRateHintsToDefault();

private:
    // 单例
    static NativeRender* instance_;
    static std::mutex instanceMutex_;
    
    // Surface 相关
    std::recursive_mutex frameRateMutex_;
    OHNativeWindow* window_ = nullptr;
    uint64_t surfaceWidth_ = 0;
    uint64_t surfaceHeight_ = 0;
    std::atomic<bool> surfaceReady_{false};
    
    // 帧率配置
    int configuredFps_ = 60;
    std::atomic<bool> displayFramePacerEnabled_{false};
    
    // VSync 模式
    std::atomic<bool> vsyncEnabled_{false};
    
    // 帧率范围已经应用过（NativeVSync）
    bool frameRateApplied_ = false;
    
    // 时间同步基准（用于 VSync 模式）
    mutable int64_t baseSystemTimeNs_ = 0;  // 系统时间基准（纳秒）
    mutable int64_t basePtsUs_ = 0;         // PTS 基准（微秒）
    mutable bool timeBaseInitialized_ = false;
    
    // NativeVSync（用于设置期望帧率范围，API 20+）
    OH_NativeVSync* nativeVSync_ = nullptr;

    // DisplaySoloist（用于智能帧率下持续请求高刷新率，API 12+，动态加载）
    void* displaySoloist_ = nullptr;
    bool displaySoloistStarted_ = false;
    
    // 上一帧渲染时间（用于帧率控制）
    std::chrono::steady_clock::time_point lastFrameTime_;
    std::chrono::steady_clock::time_point lastFrameRateHintTime_;
};

#endif // NATIVE_RENDER_H
