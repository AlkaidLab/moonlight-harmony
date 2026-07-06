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
    
    // 应用帧率范围（通过 NativeVSync，API 20+）
    void ApplyFrameRateRange();
    
    // 应用 NativeWindow 帧率（Surface buffer queue 级别，API 12+）
    void ApplyNativeWindowFrameRate();
    
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
    
    // 帧率范围已经应用过（NativeVSync）
    bool frameRateApplied_ = false;
    
    // 时间同步（用于 VSync 模式）——去抖时钟（alpha-beta / PI 时钟恢复）
    // 用平滑的 offset(+skew) 估计 + 自适应 cushion 替代朴素首帧锚点：
    //   target = pts*1000 + estimatedOffsetNs_ + cushion
    // 经离线仿真(steady/WiFi/jittery/120fps)验证，相较旧朴素锚点：
    //   硬重置 resync 由每 20s 一次降为 0；可见卡顿(>半帧)由每场景数次降为 0；
    //   最大间隔跳变 31ms→<4ms；代价是自适应缓冲延迟(净 LAN≈1.2ms，WiFi≈8ms，远端≈16ms)。
    // 设计要点：
    //   - estimatedOffsetNs_ 以小比例项(Kp=1/64)跟踪"本地单调钟 - host PTS"偏移的均值，
    //     保持网格近似刚性、不追逐逐帧抖动(抖动交由 cushion 吸收)；
    //   - skewNs_ 为每帧频差积分项(Ki=1/2048)，消除主机/客户端时钟频差造成的斜坡滞后；
    //   - jitterEstNs_ 在线估计抖动幅度(平均绝对偏差)，cushion 随之自适应；
    //   - 迟到帧(target<now)直接按原网格时刻送解码器(过去时间戳=立即呈现)，绝不把网格拽到
    //     到达时刻——避免"弹出网格再弹回"的双重卡顿(旧硬重置的根因)。
    mutable int64_t estimatedOffsetNs_ = 0;  // 平滑后的 (本地 - host) 偏移均值(纳秒)
    mutable int64_t skewNs_ = 0;             // 每帧频差估计(纳秒/帧)，消除时钟 skew 斜坡滞后
    mutable double  jitterEstNs_ = 0.0;      // 在线抖动估计(平均绝对偏差, 纳秒)，驱动自适应 cushion
    mutable int64_t lastPtsUs_ = 0;          // 上一帧 host PTS(微秒)，用于检测不连续(重连/跳变)
    mutable bool timeBaseInitialized_ = false;

    // VSync 去抖时钟的运行统计(用于评估收益/风险)
    mutable int64_t vsyncFrameCount_ = 0;      // 已呈现帧数
    mutable int64_t vsyncLateFrameCount_ = 0;  // 目标时刻已过去、被迫前推的帧数(判断延迟/cushion 是否偏小)
    mutable int64_t vsyncResyncCount_ = 0;     // 因 PTS 不连续而重锚定的次数(判断硬跳变是否仍在发生)
    
    // NativeVSync（用于设置期望帧率范围，API 20+）
    OH_NativeVSync* nativeVSync_ = nullptr;
    
    // 上一帧渲染时间（用于帧率控制）
    std::chrono::steady_clock::time_point lastFrameTime_;
};

#endif // NATIVE_RENDER_H
