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
 * @file gl_post_processor.h
 * @brief GPU 后处理管线
 *
 * 在视频解码输出与显示之间插入可选的 GL 着色器处理阶段。
 * 
 * 架构：
 *   OH_NativeImage (proxy surface)
 *        ↑ decoder outputs here
 *        ↓ GL_TEXTURE_EXTERNAL_OES
 *   GL shader processing
 *        ↓
 *   XComponent NativeWindow (display)
 *
 * 当禁用时，解码器直接输出到 XComponent 的 NativeWindow，零开销。
 */

#ifndef GL_POST_PROCESSOR_H
#define GL_POST_PROCESSOR_H

#include <native_window/external_window.h>
#include <hilog/log.h>

#include <cstdint>
#include <mutex>
#include <atomic>
#include <thread>

// 前向声明 — 避免在头文件中引入 EGL/GL/NativeImage 依赖
// 实际类型在 cpp 中通过 dlsym 加载
typedef void* EGLDisplay;
typedef void* EGLContext;
typedef void* EGLSurface;
typedef void* EGLConfig;
typedef unsigned int GLuint;

struct OH_NativeImage;

/**
 * HDR 模式（决定着色器中的传递函数）
 */
enum class PostProcessHdrMode {
    SDR = 0,    // SDR — 不做 PQ/HLG 转换
    PQ  = 1,    // HDR10 PQ
    HLG = 2     // Hybrid Log-Gamma
};

/**
 * GL 后处理管线
 *
 * 使用方式：
 *   1. Init(displayWindow, width, height) — 传入 XComponent 的 NativeWindow
 *   2. GetDecoderWindow() — 返回代理 window，传给解码器的 SetSurface
 *   3. 解码器每帧输出后自动触发处理（通过 OH_NativeImage 的 FrameAvailable 回调）
 *   4. Release() — 清理资源
 */
class GLPostProcessor {
public:
    static GLPostProcessor* GetInstance();
    static void ReleaseInstance();

    /**
     * 初始化后处理管线
     * @param displayWindow XComponent 的 NativeWindow（最终显示目标）
     * @param width  视频宽度
     * @param height 视频高度
     * @return 0 成功, -1 失败
     */
    int Init(OHNativeWindow* displayWindow, uint32_t width, uint32_t height);

    /**
     * 获取解码器应使用的 NativeWindow
     * 如果后处理已启用，返回代理 window；否则返回原始 display window
     */
    OHNativeWindow* GetDecoderWindow();

    /**
     * 设置 HDR 模式
     */
    void SetHdrMode(PostProcessHdrMode mode);

    /**
     * 启用/禁用后处理（运行时切换）
     * 注意：切换需要重建解码器管线，因此只在串流开始前设置
     */
    void SetEnabled(bool enabled) { enabled_ = enabled; }
    bool IsEnabled() const { return enabled_; }

    /**
     * 手动触发处理当前帧（供解码器回调调用）
     */
    void ProcessFrame();

    /**
     * 释放所有资源
     */
    void Release();

private:
    GLPostProcessor();
    ~GLPostProcessor();
    GLPostProcessor(const GLPostProcessor&) = delete;
    GLPostProcessor& operator=(const GLPostProcessor&) = delete;

    // EGL 初始化
    bool InitEGL(OHNativeWindow* displayWindow);
    void ReleaseEGL();

    // 着色器编译
    bool InitShaders();
    void ReleaseShaders();

    // OH_NativeImage 代理 surface
    bool InitNativeImage();
    void ReleaseNativeImage();

    // 蓝噪声纹理
    bool InitBlueNoiseTexture();

    // 绘制全屏四边形
    void DrawFullscreenQuad();

private:
    static GLPostProcessor* instance_;
    static std::mutex instanceMutex_;

    std::atomic<bool> enabled_{false};
    std::mutex processMutex_;

    // 显示目标
    OHNativeWindow* displayWindow_ = nullptr;
    uint32_t width_ = 0;
    uint32_t height_ = 0;

    // EGL
    EGLDisplay eglDisplay_ = nullptr;
    EGLContext eglContext_ = nullptr;
    EGLSurface eglSurface_ = nullptr;
    EGLConfig eglConfig_ = nullptr;

    // OH_NativeImage（解码器输出的代理 surface）
    OH_NativeImage* nativeImage_ = nullptr;
    OHNativeWindow* proxyWindow_ = nullptr;
    GLuint oesTexture_ = 0;

    // 着色器
    GLuint shaderProgram_ = 0;
    GLuint vao_ = 0;
    GLuint vbo_ = 0;

    // Uniform locations
    int locTexture_ = -1;
    int locBlueNoise_ = -1;
    int locTexelSize_ = -1;
    int locTimePhase_ = -1;
    int locEnableFilter_ = -1;
    int locHdrMode_ = -1;

    // 蓝噪声纹理
    GLuint blueNoiseTexture_ = 0;

    // 状态
    PostProcessHdrMode hdrMode_ = PostProcessHdrMode::SDR;
    uint32_t frameCount_ = 0;

    bool initialized_ = false;
};

#endif // GL_POST_PROCESSOR_H
