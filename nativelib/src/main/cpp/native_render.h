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
 * - 高帧率优化（NativeVSync SetExpectedFrameRateRange）
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
    
    // 应用帧率范围（通过 NativeVSync）
    void ApplyFrameRateRange();
    
    // 初始化 NativeVSync
    void InitNativeVSync();
    
    // 释放 NativeVSync
    void ReleaseNativeVSync();

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
    
    // 时间同步基准（用于 VSync 模式）
    mutable int64_t baseSystemTimeNs_ = 0;  // 系统时间基准（纳秒）
    mutable int64_t basePtsUs_ = 0;         // PTS 基准（微秒）
    mutable bool timeBaseInitialized_ = false;
    
    // NativeVSync（用于设置期望帧率范围）
    OH_NativeVSync* nativeVSync_ = nullptr;
    
    // 上一帧渲染时间（用于帧率控制）
    std::chrono::steady_clock::time_point lastFrameTime_;
};

#endif // NATIVE_RENDER_H
