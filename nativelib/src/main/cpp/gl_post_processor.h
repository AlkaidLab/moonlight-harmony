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
 * 三个功能正交：暗区增强(dither)、SDR→HDR、超分辨率(upscale)，任意组合均可。
 *
 * 管线拓扑（按 IsActive() 判断是否启用整个管线）：
 *
 *   无超分：OES → [后处理shader] → 屏幕           (1 pass)
 *   有超分：OES → [后处理shader] → FBO → EASU → RCAS → 屏幕  (3 pass)
 *
 * 其中后处理 shader 内部通过 uniform 开关控制暗区增强 / SDR→HDR，
 * 均关闭时自动退化为直通 blit，无额外开销。
 *
 * 当所有功能均关闭时，解码器直接输出到 XComponent 的 NativeWindow，零开销。
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
 * 超分辨率模式
 */
enum class UpscaleMode {
    OFF      = 0,   // 不超分
    XENGINE  = 1,   // 华为 XEngine GPU 空间超分（硬件加速）
    FSR1     = 2,   // AMD FSR 1 EASU+RCAS（软件 shader 回退）
    AUTO     = 3    // 自动选择：优先 XEngine，不支持则 FSR1
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
     * @param inputWidth   视频输入宽度（串流分辨率）
     * @param inputHeight  视频输入高度
     * @param outputWidth  显示输出宽度（屏幕分辨率），0 = 与输入相同
     * @param outputHeight 显示输出高度，0 = 与输入相同
     * @return 0 成功, -1 失败
     */
    int Init(OHNativeWindow* displayWindow, uint32_t inputWidth, uint32_t inputHeight,
             uint32_t outputWidth = 0, uint32_t outputHeight = 0);

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
     * 设置超分辨率模式
     */
    void SetUpscaleMode(UpscaleMode mode) { upscaleMode_ = mode; }
    UpscaleMode GetUpscaleMode() const { return upscaleMode_; }
    UpscaleMode GetActiveUpscaleMode() const { return activeUpscale_; }

    /**
     * 设置超分锐度 (0.0 - 1.0)
     */
    void SetUpscaleSharpness(float sharpness) { upscaleSharpness_ = sharpness; }

    /**
     * 设置 SDR→HDR 逆色调映射
     * @param enabled 是否启用
     * @param peakNits 目标峰值亮度 (200-1000 nits)
     */
    void SetSdrToHdr(bool enabled, float peakNits = 500.0f, float saturation = 1.3f, float contrast = 1.0f) {
        sdrToHdr_ = enabled;
        sdrToHdrPeakNits_ = peakNits;
        sdrToHdrSaturation_ = saturation;
        sdrToHdrContrast_ = contrast;
    }
    bool IsSdrToHdr() const { return sdrToHdr_; }

    /**
     * 暗区增强（HDR 暗部抖动补偿）
     * 仅在串流开始前设置生效
     */
    void SetDitherEnabled(bool enabled) { ditherEnabled_ = enabled; }
    bool IsDitherEnabled() const { return ditherEnabled_; }

    /**
     * 管线是否需要激活（任一功能启用即需要）
     * 控制 Init 路径和 ProcessFrame 入口
     */
    bool IsActive() const { return ditherEnabled_ || sdrToHdr_ || upscaleMode_ != UpscaleMode::OFF; }

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

    // 内部无锁释放（供 Init 错误路径和析构函数调用）
    void ReleaseInternal();

    // EGL 初始化
    bool InitEGL(OHNativeWindow* displayWindow);
    void ReleaseEGL();

    // 着色器编译
    bool InitShaders();
    void ReleaseShaders();

    // OH_NativeImage 代理 surface
    bool InitNativeImage();
    void ReleaseNativeImage();

    // FBO (用于 OES → TEXTURE_2D 转换)
    bool InitFBO();
    void ReleaseFBO();

    // 超分辨率初始化
    bool InitUpscale();
    void ReleaseUpscale();

    // 渲染操作
    void DrawFullscreenQuad();
    void BlitOESToFBO();
    void ApplyUpscale();

    // 运行时降级：XEngine 连续错误时回退到 FSR1 或 OFF
    void FallbackFromXEngine();

private:
    static GLPostProcessor* instance_;
    static std::mutex instanceMutex_;

    std::atomic<bool> ditherEnabled_{false};  // 暗区增强（HDR 暗部抖动补偿）
    std::mutex processMutex_;

    // 显示目标
    OHNativeWindow* displayWindow_ = nullptr;
    uint32_t inputWidth_ = 0;
    uint32_t inputHeight_ = 0;
    uint32_t outputWidth_ = 0;
    uint32_t outputHeight_ = 0;

    // 实际渲染区域（由 eglQuerySurface 获取的 EGL surface 尺寸决定）
    uint32_t renderWidth_ = 0;
    uint32_t renderHeight_ = 0;
    uint32_t renderX_ = 0;
    uint32_t renderY_ = 0;

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
    int locTexelSize_ = -1;
    int locTimePhase_ = -1;
    int locEnableFilter_ = -1;
    int locHdrMode_ = -1;

    // SDR → HDR 逆色调映射
    int locSdrToHdr_ = -1;
    int locSdrPeakNits_ = -1;
    int locSdrSaturation_ = -1;
    int locSdrContrast_ = -1;

    // FBO (OES → TEXTURE_2D 转换)
    GLuint fbo_ = 0;
    GLuint fboTexture_ = 0;         // 输入分辨率的 TEXTURE_2D
    GLuint blitProgram_ = 0;        // OES → TEXTURE_2D 的简单 blit 着色器

    // 超分辨率
    UpscaleMode upscaleMode_ = UpscaleMode::OFF;
    UpscaleMode activeUpscale_ = UpscaleMode::OFF;  // 实际使用的超分模式
    float upscaleSharpness_ = 0.5f;
    bool xengineAvailable_ = false;

    // 运行时熔断：连续 GL 错误计数
    static constexpr uint32_t kXEngineErrorThreshold = 5;   // 连续错误帧数阈值
    static constexpr uint32_t kSwapFailureThreshold = 3;    // eglSwapBuffers 连续失败阈值
    uint32_t xengineConsecutiveErrors_ = 0;
    uint32_t swapConsecutiveFailures_ = 0;

    // FSR 1 着色器（回退方案）
    GLuint fsrEasuProgram_ = 0;
    GLuint fsrRcasProgram_ = 0;
    GLuint fsrFbo_ = 0;            // FSR EASU 输出 FBO
    GLuint fsrTexture_ = 0;        // FSR EASU 输出纹理（输出分辨率）

    // 状态
    PostProcessHdrMode hdrMode_ = PostProcessHdrMode::SDR;
    bool sdrToHdr_ = false;
    float sdrToHdrPeakNits_ = 500.0f;
    float sdrToHdrSaturation_ = 1.3f;
    float sdrToHdrContrast_ = 1.0f;
    uint32_t frameCount_ = 0;

    bool initialized_ = false;
};

#endif // GL_POST_PROCESSOR_H
