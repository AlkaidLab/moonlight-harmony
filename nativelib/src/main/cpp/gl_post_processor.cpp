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
 * @file gl_post_processor.cpp
 * @brief GPU 后处理管线实现
 *
 * 使用 OH_NativeImage 作为解码器输出的代理 surface，
 * 通过 EGL + GLES 3.0 着色器对视频帧进行后处理，
 * 最终渲染到 XComponent 的 NativeWindow。
 *
 * 所有 EGL/GL/NativeImage API 通过 dlsym 动态加载，
 * 避免对不支持的设备产生硬依赖。
 */

#include "gl_post_processor.h"
#include <native_buffer/native_buffer.h>
#include <cstring>
#include <cmath>
#include <dlfcn.h>
#include <time.h>

#undef LOG_TAG
#define LOG_TAG "GLPostProcessor"

// =============================================================================
// EGL/GL 类型与常量（避免头文件依赖）
// =============================================================================

// EGL types
typedef void* EGLNativeWindowType;
typedef int EGLint;
typedef unsigned int EGLBoolean;

// EGL constants
#define MY_EGL_DEFAULT_DISPLAY     ((EGLNativeWindowType)0)
#define MY_EGL_NO_DISPLAY          ((EGLDisplay)0)
#define MY_EGL_NO_CONTEXT          ((EGLContext)0)
#define MY_EGL_NO_SURFACE          ((EGLSurface)0)
#define MY_EGL_NONE                0x3038
#define MY_EGL_RED_SIZE            0x3024
#define MY_EGL_GREEN_SIZE          0x3025
#define MY_EGL_BLUE_SIZE           0x3026
#define MY_EGL_ALPHA_SIZE          0x3027
#define MY_EGL_RENDERABLE_TYPE     0x3040
#define MY_EGL_OPENGL_ES3_BIT      0x0040
#define MY_EGL_CONTEXT_CLIENT_VERSION 0x3098
#define MY_EGL_TRUE                1
#define MY_EGL_SURFACE_TYPE        0x3033
#define MY_EGL_WINDOW_BIT          0x0004
#define MY_EGL_OPENGL_ES2_BIT      0x0004
#define MY_EGL_NATIVE_VISUAL_ID    0x302E
#define MY_EGL_WIDTH               0x3057
#define MY_EGL_HEIGHT              0x3056

// GL constants
#define MY_GL_TEXTURE_2D            0x0DE1
#define MY_GL_TEXTURE_EXTERNAL_OES  0x8D65
#define MY_GL_TEXTURE0              0x84C0
#define MY_GL_TEXTURE1              0x84C1
#define MY_GL_TEXTURE_MIN_FILTER    0x2801
#define MY_GL_TEXTURE_MAG_FILTER    0x2800
#define MY_GL_TEXTURE_WRAP_S        0x2802
#define MY_GL_TEXTURE_WRAP_T        0x2803
#define MY_GL_NEAREST               0x2600
#define MY_GL_LINEAR                0x2601
#define MY_GL_REPEAT                0x2901
#define MY_GL_CLAMP_TO_EDGE         0x812F
#define MY_GL_FLOAT                 0x1406
#define MY_GL_FALSE                 0
#define MY_GL_TRUE                  1
#define MY_GL_TRIANGLE_STRIP        0x0005
#define MY_GL_ARRAY_BUFFER          0x8892
#define MY_GL_STATIC_DRAW           0x88E4
#define MY_GL_VERTEX_SHADER         0x8B31
#define MY_GL_FRAGMENT_SHADER       0x8B30
#define MY_GL_COMPILE_STATUS        0x8B81
#define MY_GL_LINK_STATUS           0x8B82
#define MY_GL_INFO_LOG_LENGTH       0x8B84
#define MY_GL_COLOR_BUFFER_BIT      0x00004000
#define MY_GL_RED                   0x1903
#define MY_GL_UNSIGNED_BYTE         0x1401
#define MY_GL_R8                    0x8229
#define MY_GL_FRAMEBUFFER           0x8D40
#define MY_GL_COLOR_ATTACHMENT0     0x8CE0
#define MY_GL_FRAMEBUFFER_COMPLETE  0x8CD5
#define MY_GL_RGBA8                 0x8058
#define MY_GL_RGBA                  0x1908
#define MY_GL_RGBA16F               0x881A
#define MY_GL_HALF_FLOAT            0x140B

// =============================================================================
// 动态加载的函数指针
// =============================================================================

// EGL functions
typedef EGLDisplay (*PFN_eglGetDisplay)(EGLNativeWindowType);
typedef EGLBoolean (*PFN_eglInitialize)(EGLDisplay, EGLint*, EGLint*);
typedef EGLBoolean (*PFN_eglChooseConfig)(EGLDisplay, const EGLint*, EGLConfig*, EGLint, EGLint*);
typedef EGLBoolean (*PFN_eglGetConfigs)(EGLDisplay, EGLConfig*, EGLint, EGLint*);
typedef EGLBoolean (*PFN_eglGetConfigAttrib)(EGLDisplay, EGLConfig, EGLint, EGLint*);
typedef EGLContext (*PFN_eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint*);
typedef EGLSurface (*PFN_eglCreateWindowSurface)(EGLDisplay, EGLConfig, EGLNativeWindowType, const EGLint*);
typedef EGLBoolean (*PFN_eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
typedef EGLBoolean (*PFN_eglSwapBuffers)(EGLDisplay, EGLSurface);
typedef EGLBoolean (*PFN_eglSwapInterval)(EGLDisplay, EGLint);
typedef EGLBoolean (*PFN_eglQuerySurface)(EGLDisplay, EGLSurface, EGLint, EGLint*);
typedef EGLBoolean (*PFN_eglDestroySurface)(EGLDisplay, EGLSurface);
typedef EGLBoolean (*PFN_eglDestroyContext)(EGLDisplay, EGLContext);
typedef EGLBoolean (*PFN_eglTerminate)(EGLDisplay);

// GL functions
typedef void (*PFN_glGenTextures)(int, GLuint*);
typedef void (*PFN_glDeleteTextures)(int, const GLuint*);
typedef void (*PFN_glBindTexture)(unsigned int, GLuint);
typedef void (*PFN_glTexParameteri)(unsigned int, unsigned int, int);
typedef void (*PFN_glActiveTexture)(unsigned int);
typedef GLuint (*PFN_glCreateShader)(unsigned int);
typedef void (*PFN_glShaderSource)(GLuint, int, const char**, const int*);
typedef void (*PFN_glCompileShader)(GLuint);
typedef void (*PFN_glGetShaderiv)(GLuint, unsigned int, int*);
typedef void (*PFN_glGetShaderInfoLog)(GLuint, int, int*, char*);
typedef void (*PFN_glDeleteShader)(GLuint);
typedef GLuint (*PFN_glCreateProgram)(void);
typedef void (*PFN_glAttachShader)(GLuint, GLuint);
typedef void (*PFN_glLinkProgram)(GLuint);
typedef void (*PFN_glGetProgramiv)(GLuint, unsigned int, int*);
typedef void (*PFN_glGetProgramInfoLog)(GLuint, int, int*, char*);
typedef void (*PFN_glDeleteProgram)(GLuint);
typedef void (*PFN_glUseProgram)(GLuint);
typedef int (*PFN_glGetUniformLocation)(GLuint, const char*);
typedef void (*PFN_glUniform1i)(int, int);
typedef void (*PFN_glUniform1f)(int, float);
typedef void (*PFN_glUniform2f)(int, float, float);
typedef void (*PFN_glGenVertexArrays)(int, GLuint*);
typedef void (*PFN_glDeleteVertexArrays)(int, const GLuint*);
typedef void (*PFN_glBindVertexArray)(GLuint);
typedef void (*PFN_glGenBuffers)(int, GLuint*);
typedef void (*PFN_glDeleteBuffers)(int, const GLuint*);
typedef void (*PFN_glBindBuffer)(unsigned int, GLuint);
typedef void (*PFN_glBufferData)(unsigned int, long long, const void*, unsigned int);
typedef void (*PFN_glVertexAttribPointer)(GLuint, int, unsigned int, unsigned char, int, const void*);
typedef void (*PFN_glEnableVertexAttribArray)(GLuint);
typedef void (*PFN_glDrawArrays)(unsigned int, int, int);
typedef void (*PFN_glViewport)(int, int, int, int);
typedef void (*PFN_glClear)(unsigned int);
typedef void (*PFN_glClearColor)(float, float, float, float);
typedef void (*PFN_glTexImage2D)(unsigned int, int, int, int, int, int, unsigned int, unsigned int, const void*);
typedef unsigned int (*PFN_glGetError)(void);
typedef void (*PFN_glFinish)(void);

// GL FBO functions
typedef void (*PFN_glGenFramebuffers)(int, GLuint*);
typedef void (*PFN_glDeleteFramebuffers)(int, const GLuint*);
typedef void (*PFN_glBindFramebuffer)(unsigned int, GLuint);
typedef void (*PFN_glFramebufferTexture2D)(unsigned int, unsigned int, unsigned int, GLuint, int);
typedef unsigned int (*PFN_glCheckFramebufferStatus)(unsigned int);

// XEngine functions (dynamic)
typedef const unsigned char* (*PFN_HMS_XEG_GetString)(unsigned int);
typedef void (*PFN_HMS_XEG_SpatialUpscaleParameter)(unsigned int, void*);
typedef void (*PFN_HMS_XEG_RenderSpatialUpscale)(GLuint);

// OH_NativeImage functions
typedef OH_NativeImage* (*PFN_OH_NativeImage_Create)(GLuint, unsigned int);
typedef OHNativeWindow* (*PFN_OH_NativeImage_AcquireNativeWindow)(OH_NativeImage*);
typedef int32_t (*PFN_OH_NativeImage_UpdateSurfaceImage)(OH_NativeImage*);
typedef int32_t (*PFN_OH_NativeImage_GetTimestamp)(OH_NativeImage*, int64_t*);
typedef void (*PFN_OH_NativeImage_Destroy)(OH_NativeImage**);
typedef int32_t (*PFN_OH_NativeImage_AttachContext)(OH_NativeImage*, GLuint);
typedef int32_t (*PFN_OH_NativeImage_SetOnFrameAvailableListener)(OH_NativeImage*, void*);

// Function pointer storage
static struct {
    // EGL
    PFN_eglGetDisplay eglGetDisplay;
    PFN_eglInitialize eglInitialize;
    PFN_eglChooseConfig eglChooseConfig;
    PFN_eglGetConfigs eglGetConfigs;
    PFN_eglGetConfigAttrib eglGetConfigAttrib;
    PFN_eglCreateContext eglCreateContext;
    PFN_eglCreateWindowSurface eglCreateWindowSurface;
    PFN_eglMakeCurrent eglMakeCurrent;
    PFN_eglSwapBuffers eglSwapBuffers;
    PFN_eglSwapInterval eglSwapInterval;
    PFN_eglQuerySurface eglQuerySurface;
    PFN_eglDestroySurface eglDestroySurface;
    PFN_eglDestroyContext eglDestroyContext;
    PFN_eglTerminate eglTerminate;
    // GL
    PFN_glGenTextures glGenTextures;
    PFN_glDeleteTextures glDeleteTextures;
    PFN_glBindTexture glBindTexture;
    PFN_glTexParameteri glTexParameteri;
    PFN_glActiveTexture glActiveTexture;
    PFN_glCreateShader glCreateShader;
    PFN_glShaderSource glShaderSource;
    PFN_glCompileShader glCompileShader;
    PFN_glGetShaderiv glGetShaderiv;
    PFN_glGetShaderInfoLog glGetShaderInfoLog;
    PFN_glDeleteShader glDeleteShader;
    PFN_glCreateProgram glCreateProgram;
    PFN_glAttachShader glAttachShader;
    PFN_glLinkProgram glLinkProgram;
    PFN_glGetProgramiv glGetProgramiv;
    PFN_glGetProgramInfoLog glGetProgramInfoLog;
    PFN_glDeleteProgram glDeleteProgram;
    PFN_glUseProgram glUseProgram;
    PFN_glGetUniformLocation glGetUniformLocation;
    PFN_glUniform1i glUniform1i;
    PFN_glUniform1f glUniform1f;
    PFN_glUniform2f glUniform2f;
    PFN_glGenVertexArrays glGenVertexArrays;
    PFN_glDeleteVertexArrays glDeleteVertexArrays;
    PFN_glBindVertexArray glBindVertexArray;
    PFN_glGenBuffers glGenBuffers;
    PFN_glDeleteBuffers glDeleteBuffers;
    PFN_glBindBuffer glBindBuffer;
    PFN_glBufferData glBufferData;
    PFN_glVertexAttribPointer glVertexAttribPointer;
    PFN_glEnableVertexAttribArray glEnableVertexAttribArray;
    PFN_glDrawArrays glDrawArrays;
    PFN_glViewport glViewport;
    PFN_glClear glClear;
    PFN_glClearColor glClearColor;
    PFN_glTexImage2D glTexImage2D;
    PFN_glGetError glGetError;
    PFN_glFinish glFinish;
    // FBO
    PFN_glGenFramebuffers glGenFramebuffers;
    PFN_glDeleteFramebuffers glDeleteFramebuffers;
    PFN_glBindFramebuffer glBindFramebuffer;
    PFN_glFramebufferTexture2D glFramebufferTexture2D;
    PFN_glCheckFramebufferStatus glCheckFramebufferStatus;
    // NativeImage
    PFN_OH_NativeImage_Create nativeImageCreate;
    PFN_OH_NativeImage_AcquireNativeWindow nativeImageAcquireWindow;
    PFN_OH_NativeImage_UpdateSurfaceImage nativeImageUpdateSurface;
    PFN_OH_NativeImage_GetTimestamp nativeImageGetTimestamp;
    PFN_OH_NativeImage_Destroy nativeImageDestroy;
    PFN_OH_NativeImage_AttachContext nativeImageAttachContext;
    // XEngine (optional)
    PFN_HMS_XEG_GetString xegGetString;
    PFN_HMS_XEG_SpatialUpscaleParameter xegSpatialUpscaleParam;
    PFN_HMS_XEG_RenderSpatialUpscale xegRenderSpatialUpscale;
    // load status
    bool loaded;
} g_api = {};

static bool LoadAPIs() {
    if (g_api.loaded) return true;

    void* eglLib = dlopen("libEGL.so", RTLD_NOW);
    void* glesLib = dlopen("libGLESv3.so", RTLD_NOW);
    void* niLib = dlopen("libnative_image.so", RTLD_NOW);

    if (!eglLib || !glesLib || !niLib) {
        OH_LOG_ERROR(LOG_APP, "Failed to load GL libs: EGL=%{public}p, GLES=%{public}p, NI=%{public}p",
                     eglLib, glesLib, niLib);
        return false;
    }

    // EGL
    g_api.eglGetDisplay = (PFN_eglGetDisplay)dlsym(eglLib, "eglGetDisplay");
    g_api.eglInitialize = (PFN_eglInitialize)dlsym(eglLib, "eglInitialize");
    g_api.eglChooseConfig = (PFN_eglChooseConfig)dlsym(eglLib, "eglChooseConfig");
    g_api.eglGetConfigs = (PFN_eglGetConfigs)dlsym(eglLib, "eglGetConfigs");
    g_api.eglGetConfigAttrib = (PFN_eglGetConfigAttrib)dlsym(eglLib, "eglGetConfigAttrib");
    g_api.eglCreateContext = (PFN_eglCreateContext)dlsym(eglLib, "eglCreateContext");
    g_api.eglCreateWindowSurface = (PFN_eglCreateWindowSurface)dlsym(eglLib, "eglCreateWindowSurface");
    g_api.eglMakeCurrent = (PFN_eglMakeCurrent)dlsym(eglLib, "eglMakeCurrent");
    g_api.eglSwapBuffers = (PFN_eglSwapBuffers)dlsym(eglLib, "eglSwapBuffers");
    g_api.eglSwapInterval = (PFN_eglSwapInterval)dlsym(eglLib, "eglSwapInterval");
    g_api.eglQuerySurface = (PFN_eglQuerySurface)dlsym(eglLib, "eglQuerySurface");
    g_api.eglDestroySurface = (PFN_eglDestroySurface)dlsym(eglLib, "eglDestroySurface");
    g_api.eglDestroyContext = (PFN_eglDestroyContext)dlsym(eglLib, "eglDestroyContext");
    g_api.eglTerminate = (PFN_eglTerminate)dlsym(eglLib, "eglTerminate");

    // GL
    g_api.glGenTextures = (PFN_glGenTextures)dlsym(glesLib, "glGenTextures");
    g_api.glDeleteTextures = (PFN_glDeleteTextures)dlsym(glesLib, "glDeleteTextures");
    g_api.glBindTexture = (PFN_glBindTexture)dlsym(glesLib, "glBindTexture");
    g_api.glTexParameteri = (PFN_glTexParameteri)dlsym(glesLib, "glTexParameteri");
    g_api.glActiveTexture = (PFN_glActiveTexture)dlsym(glesLib, "glActiveTexture");
    g_api.glCreateShader = (PFN_glCreateShader)dlsym(glesLib, "glCreateShader");
    g_api.glShaderSource = (PFN_glShaderSource)dlsym(glesLib, "glShaderSource");
    g_api.glCompileShader = (PFN_glCompileShader)dlsym(glesLib, "glCompileShader");
    g_api.glGetShaderiv = (PFN_glGetShaderiv)dlsym(glesLib, "glGetShaderiv");
    g_api.glGetShaderInfoLog = (PFN_glGetShaderInfoLog)dlsym(glesLib, "glGetShaderInfoLog");
    g_api.glDeleteShader = (PFN_glDeleteShader)dlsym(glesLib, "glDeleteShader");
    g_api.glCreateProgram = (PFN_glCreateProgram)dlsym(glesLib, "glCreateProgram");
    g_api.glAttachShader = (PFN_glAttachShader)dlsym(glesLib, "glAttachShader");
    g_api.glLinkProgram = (PFN_glLinkProgram)dlsym(glesLib, "glLinkProgram");
    g_api.glGetProgramiv = (PFN_glGetProgramiv)dlsym(glesLib, "glGetProgramiv");
    g_api.glGetProgramInfoLog = (PFN_glGetProgramInfoLog)dlsym(glesLib, "glGetProgramInfoLog");
    g_api.glDeleteProgram = (PFN_glDeleteProgram)dlsym(glesLib, "glDeleteProgram");
    g_api.glUseProgram = (PFN_glUseProgram)dlsym(glesLib, "glUseProgram");
    g_api.glGetUniformLocation = (PFN_glGetUniformLocation)dlsym(glesLib, "glGetUniformLocation");
    g_api.glUniform1i = (PFN_glUniform1i)dlsym(glesLib, "glUniform1i");
    g_api.glUniform1f = (PFN_glUniform1f)dlsym(glesLib, "glUniform1f");
    g_api.glUniform2f = (PFN_glUniform2f)dlsym(glesLib, "glUniform2f");
    g_api.glGenVertexArrays = (PFN_glGenVertexArrays)dlsym(glesLib, "glGenVertexArrays");
    g_api.glDeleteVertexArrays = (PFN_glDeleteVertexArrays)dlsym(glesLib, "glDeleteVertexArrays");
    g_api.glBindVertexArray = (PFN_glBindVertexArray)dlsym(glesLib, "glBindVertexArray");
    g_api.glGenBuffers = (PFN_glGenBuffers)dlsym(glesLib, "glGenBuffers");
    g_api.glDeleteBuffers = (PFN_glDeleteBuffers)dlsym(glesLib, "glDeleteBuffers");
    g_api.glBindBuffer = (PFN_glBindBuffer)dlsym(glesLib, "glBindBuffer");
    g_api.glBufferData = (PFN_glBufferData)dlsym(glesLib, "glBufferData");
    g_api.glVertexAttribPointer = (PFN_glVertexAttribPointer)dlsym(glesLib, "glVertexAttribPointer");
    g_api.glEnableVertexAttribArray = (PFN_glEnableVertexAttribArray)dlsym(glesLib, "glEnableVertexAttribArray");
    g_api.glDrawArrays = (PFN_glDrawArrays)dlsym(glesLib, "glDrawArrays");
    g_api.glViewport = (PFN_glViewport)dlsym(glesLib, "glViewport");
    g_api.glClear = (PFN_glClear)dlsym(glesLib, "glClear");
    g_api.glClearColor = (PFN_glClearColor)dlsym(glesLib, "glClearColor");
    g_api.glTexImage2D = (PFN_glTexImage2D)dlsym(glesLib, "glTexImage2D");
    g_api.glGetError = (PFN_glGetError)dlsym(glesLib, "glGetError");
    g_api.glFinish = (PFN_glFinish)dlsym(glesLib, "glFinish");

    // FBO
    g_api.glGenFramebuffers = (PFN_glGenFramebuffers)dlsym(glesLib, "glGenFramebuffers");
    g_api.glDeleteFramebuffers = (PFN_glDeleteFramebuffers)dlsym(glesLib, "glDeleteFramebuffers");
    g_api.glBindFramebuffer = (PFN_glBindFramebuffer)dlsym(glesLib, "glBindFramebuffer");
    g_api.glFramebufferTexture2D = (PFN_glFramebufferTexture2D)dlsym(glesLib, "glFramebufferTexture2D");
    g_api.glCheckFramebufferStatus = (PFN_glCheckFramebufferStatus)dlsym(glesLib, "glCheckFramebufferStatus");

    // NativeImage
    g_api.nativeImageCreate = (PFN_OH_NativeImage_Create)dlsym(niLib, "OH_NativeImage_Create");
    g_api.nativeImageAcquireWindow = (PFN_OH_NativeImage_AcquireNativeWindow)dlsym(niLib, "OH_NativeImage_AcquireNativeWindow");
    g_api.nativeImageUpdateSurface = (PFN_OH_NativeImage_UpdateSurfaceImage)dlsym(niLib, "OH_NativeImage_UpdateSurfaceImage");
    g_api.nativeImageGetTimestamp = (PFN_OH_NativeImage_GetTimestamp)dlsym(niLib, "OH_NativeImage_GetTimestamp");
    g_api.nativeImageDestroy = (PFN_OH_NativeImage_Destroy)dlsym(niLib, "OH_NativeImage_Destroy");
    g_api.nativeImageAttachContext = (PFN_OH_NativeImage_AttachContext)dlsym(niLib, "OH_NativeImage_AttachContext");

    // Validate critical functions
    if (!g_api.eglGetDisplay || !g_api.eglInitialize || !g_api.eglChooseConfig ||
        !g_api.eglCreateContext || !g_api.eglCreateWindowSurface || !g_api.eglMakeCurrent ||
        !g_api.eglSwapBuffers || !g_api.glCreateShader || !g_api.glCreateProgram ||
        !g_api.nativeImageCreate || !g_api.nativeImageAcquireWindow ||
        !g_api.nativeImageUpdateSurface) {
        OH_LOG_ERROR(LOG_APP, "Missing critical GL/EGL/NativeImage APIs");
        return false;
    }

    // XEngine (可选，不影响核心功能)
    void* xeLib = dlopen("libxengine.so", RTLD_NOW);
    if (xeLib) {
        g_api.xegGetString = (PFN_HMS_XEG_GetString)dlsym(xeLib, "HMS_XEG_GetString");
        g_api.xegSpatialUpscaleParam = (PFN_HMS_XEG_SpatialUpscaleParameter)dlsym(xeLib, "HMS_XEG_SpatialUpscaleParameter");
        g_api.xegRenderSpatialUpscale = (PFN_HMS_XEG_RenderSpatialUpscale)dlsym(xeLib, "HMS_XEG_RenderSpatialUpscale");
        OH_LOG_INFO(LOG_APP, "XEngine library loaded: getString=%{public}p, spatialUpscale=%{public}p",
                     (void*)g_api.xegGetString, (void*)g_api.xegRenderSpatialUpscale);
    } else {
        OH_LOG_INFO(LOG_APP, "XEngine not available (libxengine.so not found)");
    }

    g_api.loaded = true;
    OH_LOG_INFO(LOG_APP, "GL/EGL/NativeImage APIs loaded successfully");
    return true;
}

// =============================================================================
// 着色器源码
// =============================================================================

static const char* VERTEX_SHADER_SRC = R"(#version 300 es
layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aTexCoord;
out vec2 vTexCoord;
void main() {
    gl_Position = vec4(aPosition, 0.0, 1.0);
    vTexCoord = vec2(aTexCoord.x, 1.0 - aTexCoord.y);
}
)";

// 暗区抖动后处理着色器
// 参考 hoangmaiwaxyz2772-max 的 HDR OLED 暗部补偿方案，重新设计实现
static const char* FRAGMENT_SHADER_SRC = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require

precision mediump float;

in vec2 vTexCoord;
uniform samplerExternalOES uTexture;
uniform sampler2D uBlueNoiseTexture;
uniform vec2 uTexelSize;
uniform float uTimePhase;
uniform int uEnableFilter;
uniform int uHdrMode;
uniform int uSdrToHdr;
uniform float uSdrPeakNits;
uniform float uSdrSaturation;
uniform float uSdrContrast;

out vec4 outColor;

// PQ (Perceptual Quantizer, SMPTE ST 2084) 常量
const float PQ_M1 = 0.1593017578125;
const float PQ_M2 = 78.84375;
const float PQ_C1 = 0.8359375;
const float PQ_C2 = 18.8515625;
const float PQ_C3 = 18.6875;
const float MAX_NITS = 10000.0;

// HLG (Hybrid Log-Gamma, ARIB STD-B67) 常量
const float HLG_A = 0.17883277;
const float HLG_B = 0.28466892;
const float HLG_C = 0.55991073;

// =========================================================================
// 传递函数：PQ ↔ 线性
// =========================================================================
vec3 pq_to_lin(vec3 pq) {
    vec3 p = pow(clamp(pq, 0.0, 1.0), vec3(1.0 / PQ_M2));
    return pow(max(p - PQ_C1, 0.0) / max(PQ_C2 - PQ_C3 * p, 1e-6), vec3(1.0 / PQ_M1));
}

vec3 lin_to_pq(vec3 lin) {
    vec3 lp = pow(max(lin, 0.0), vec3(PQ_M1));
    return pow((PQ_C1 + PQ_C2 * lp) / (1.0 + PQ_C3 * lp), vec3(PQ_M2));
}

// =========================================================================
// 传递函数：HLG ↔ 线性
// =========================================================================
vec3 hlg_to_lin(vec3 e) {
    vec3 s = clamp(e, 0.0, 1.0);
    vec3 mask = step(0.5, s);
    return mix(s * s / 3.0,
               (exp((s - HLG_C) / HLG_A) + HLG_B) / 12.0,
               mask);
}

vec3 lin_to_hlg(vec3 l) {
    l = max(l, 0.0);
    vec3 mask = step(0.08333333, l);
    return mix(sqrt(3.0 * l),
               HLG_A * log(12.0 * l - HLG_B) + HLG_C,
               mask);
}

// BT.2020 亮度系数
float luma_2020(vec3 c) { return dot(c, vec3(0.2627, 0.6780, 0.0593)); }

void main() {
    vec4 tex = texture(uTexture, vTexCoord);

    // SDR 内容 + HDR 显示面 → 扩展动态范围
    if (uSdrToHdr == 1 && uHdrMode == 0) {
        // sRGB gamma 解码 → 线性光
        vec3 linear = pow(max(tex.rgb, 0.0), vec3(2.2));
        float L = dot(linear, vec3(0.2126, 0.7152, 0.0722));

        if (L > 0.001) {
            // 逆 Reinhard 扩展亮度范围
            // SDR 参考白 80 nits，目标峰值由 uniform 控制
            float peakScale = uSdrPeakNits / 80.0;
            // 修正逆 Reinhard：F(L) = L * peakScale / (1 + L * (peakScale - 1))
            // 低亮度近似线性扩展，高亮度非线性压缩
            float Lhdr = L * peakScale / (1.0 + L * (peakScale - 1.0));

            // 保持色度不变，仅缩放亮度
            vec3 hdr = linear * (Lhdr / L);
            // 限幅防止超出 PQ 编码范围
            hdr = min(hdr, uSdrPeakNits / MAX_NITS);

            // 线性 → PQ 编码
            outColor = vec4(lin_to_pq(hdr), tex.a);
        } else {
            // 纯黑或极暗：直接映射为 PQ 零值
            outColor = vec4(lin_to_pq(vec3(0.0)), tex.a);
        }
        return;
    }

    // SDR 模式且无 SDR→HDR → 直通
    if (uHdrMode == 0) {
        outColor = tex;
        return;
    }

    // ===== HLG SDR-in-HDR: S-curve 逆色调映射 =====
    // S-curve：f(x) = x + maxBoost * x³/(1+x³)，暗部不动、高光扩展
    if (uSdrToHdr == 1 && uEnableFilter == 0 && uHdrMode == 2) {
        vec3 hlg = tex.rgb;
        vec3 lw = vec3(0.2627, 0.6780, 0.0593);
        float Yhlg = dot(hlg, lw);
        if (Yhlg > 0.001 && Yhlg < 0.99) {
            float maxBoost = (uSdrPeakNits - 203.0) / 1000.0;
            maxBoost = max(maxBoost, 0.0);

            // S-curve 全局增益
            vec3 x = hlg;
            vec3 x3 = x * x * x;
            vec3 boost = maxBoost * x3 / (1.0 + x3);
            hlg = hlg + boost;

            // 对比度调整：以中灰(0.5)为锚点缩放
            hlg = clamp(vec3(0.5) + (hlg - 0.5) * uSdrContrast, 0.0, 1.0);

            // 饱和度调整
            float Yout = dot(hlg, lw);
            hlg = Yout + (hlg - Yout) * uSdrSaturation;
            hlg = clamp(hlg, 0.0, 1.0);
        }
        outColor = vec4(hlg, tex.a);
        return;
    }

    // 亮区提前退出（> 0.4 编码值 ≈ > 40 nits），无需暗区处理
    // 但 SDR→HDR 增强需要处理全亮度范围，不能提前跳过
    if (uSdrToHdr == 0 && uEnableFilter == 1 && max(tex.r, max(tex.g, tex.b)) > 0.4) {
        outColor = tex;
        return;
    }

    // ----- 蓝噪声采样 -----
    vec2 pixelId = floor(vTexCoord / max(uTexelSize, 1e-5));
    vec2 noiseUV = pixelId / 64.0 + vec2(
        fract(sin(uTimePhase * 123.456) * 43758.545),
        fract(cos(uTimePhase * 789.012) * 32145.678));
    float noise = texture(uBlueNoiseTexture, noiseUV).r;
    float noise2 = texture(uBlueNoiseTexture, fract(noiseUV + vec2(0.314, 0.618))).r;

    // ----- 负值重分配（防止解码器溢出） -----
    vec3 rgb = min(tex.rgb, 1.0);
    float minCh = min(min(rgb.r, rgb.g), rgb.b);
    if (minCh < 0.0) {
        float Y = luma_2020(rgb);
        rgb = (Y <= 0.0) ? vec3(0.0) : mix(vec3(Y), rgb, Y / (Y - minCh));
    }

    // ----- 解码到线性空间 -----
    vec3 lin = (uHdrMode == 1) ? pq_to_lin(rgb) : hlg_to_lin(rgb);

    // ----- SDR-in-HDR 动态范围增强 -----
    // HDR 串流中 SDR 内容的动态范围有限，用逆 Reinhard 拉伸到更宽范围
    if (uSdrToHdr == 1) {
        float Ysrc = luma_2020(lin);

        if (uHdrMode == 1) {
            // PQ 模式：绝对亮度系统，SDR 参考白 = 203 nits (BT.2408)
            float nitsSrc = Ysrc * MAX_NITS;
            float refWhite = 203.0;
            if (nitsSrc > 0.01 && nitsSrc < refWhite * 1.1) {
                float normL = nitsSrc / refWhite;
                float peakScale = uSdrPeakNits / refWhite;
                float expanded = normL * peakScale / (1.0 + normL * (peakScale - 1.0));
                float targetNits = expanded * refWhite;
                lin = lin * (targetNits / nitsSrc);
                lin = min(lin, uSdrPeakNits / MAX_NITS);
            }
        } else {
            // HLG 模式：直接在 HLG 编码域增强（避免线性域精度问题）
            // HLG 编码已经是感知均匀的，直接操作更安全
            float Yhlg = dot(rgb, vec3(0.2627, 0.6780, 0.0593));
            if (Yhlg > 0.001) {
                // 温和提升：峰值500nits → 1.37x, 1000nits → 2.0x
                float peakScale = 1.0 + (uSdrPeakNits - 203.0) / 800.0;
                peakScale = max(peakScale, 1.0);
                // 逆 Reinhard 在 HLG 编码域
                float expanded = Yhlg * peakScale / (1.0 + Yhlg * (peakScale - 1.0));
                rgb = rgb * (expanded / Yhlg);
                rgb = min(rgb, 1.0);
            }
            // 重新解码增强后的 HLG 值到线性域（供后续暗区滤镜使用）
            lin = hlg_to_lin(rgb);
        }
    }

    float Y = luma_2020(lin);
    float nits = Y * MAX_NITS;

    // 仅 SDR→HDR 增强、不需要暗区滤镜 → 直接重编码输出
    if (uEnableFilter == 0) {
        outColor = vec4(
            (uHdrMode == 1) ? lin_to_pq(lin) : lin_to_hlg(lin),
            tex.a);
        return;
    }

    // ----- 暗区 PDM 抖动 (0–10 nits) -----
    // 用蓝噪声在安全亮度阶梯间做概率性插值
    // 补偿 OLED 面板最低亮度高于 PQ 曲线的缺陷
    //
    // edge 边界 = 面板标定的"PQ 标准亮度→实际输出亮度" 映射节点
    // 面板无法显示 edge 之间的连续灰阶，通过 0/1 抖动模拟中间亮度
    // 适配设备：MatePad Pro 12.2 (实测标定)
    vec3 result = lin;
    if (nits > 1e-7 && nits <= 10.0) {
        // 8% 亮度微扰消除阶梯边界
        float jNits = clamp(nits + (noise2 - 0.5) * nits * 0.08, 1e-7, 10.0);

        // 11 档安全亮度阶梯（基于 MatePad Pro 12.2 实测标定值）
        // 每档 low→high 由蓝噪声概率选择
        float mapped = jNits;
        #define STEP(lo, hi, edge_lo, edge_hi) \
            if (jNits <= edge_hi) { mapped = mix(lo, hi, step(noise, (jNits - edge_lo) / (edge_hi - edge_lo))); } else

        STEP(0.0,    0.0825, 0.0,    0.375)
        STEP(0.0825, 0.225,  0.375,  0.5625)
        STEP(0.225,  0.33,   0.5625, 0.75)
        STEP(0.33,   0.55,   0.75,   1.0)
        STEP(0.55,   0.775,  1.0,    1.25)
        STEP(0.775,  1.2,    1.25,   1.875)
        STEP(1.2,    1.7,    1.875,  2.5)
        STEP(1.7,    2.55,   2.5,    3.175)
        STEP(2.55,   3.6,    3.175,  5.0)
        STEP(3.6,    6.6,    5.0,    7.5)
        STEP(6.6,   10.0,    7.5,   10.0)
        { /* fallthrough */ }
        #undef STEP

        result = lin * (mapped / max(nits, 1e-7));
    } else if (nits <= 1e-7) {
        result = vec3(0.0);
    }

    // ----- Hunt 效应色度补偿 -----
    // 低亮度下人眼色彩感知衰减，适度增强色度
    float Yout = luma_2020(result);
    float nitsOut = Yout * MAX_NITS;
    float t = clamp((nitsOut - 0.1) * 0.101, 0.0, 1.0);
    float boost = 1.0 + 0.35 * (1.0 - t * t * (3.0 - 2.0 * t));

    vec3 chroma = result - Yout;
    // 安全限幅：防止色度增强导致负值
    float dR = Yout - result.r, dG = Yout - result.g, dB = Yout - result.b;
    float safeLimit = 0.99 * min(
        min((dR > 1e-6) ? Yout / dR : 10.0, (dG > 1e-6) ? Yout / dG : 10.0),
        (dB > 1e-6) ? Yout / dB : 10.0);
    result = Yout + chroma * min(boost, safeLimit);
    result = max(result, 0.0);

    // ----- 重编码 -----
    outColor = vec4(
        (uHdrMode == 1) ? lin_to_pq(result) : lin_to_hlg(result),
        tex.a);
}
)";

// OES → TEXTURE_2D blit 着色器（单独着色器，绑定到 FBO 输出）
static const char* BLIT_OES_FRAGMENT_SRC = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
in vec2 vTexCoord;
uniform samplerExternalOES uTexture;
out vec4 outColor;
void main() {
    outColor = texture(uTexture, vTexCoord);
}
)";

// FSR 1 EASU (Edge-Adaptive Spatial Upsampling) 着色器
// 完整的 GLES 3.0 移植版，基于 AMD FidelityFX FSR 1.0 (MIT License)
// 使用 12 个采样点、4-位置方向检测、各向异性自适应 Lanczos 核
static const char* FSR_EASU_FRAGMENT_SRC = R"(#version 300 es
precision highp float;
in vec2 vTexCoord;
uniform sampler2D uInputTexture;
uniform vec2 uInputSize;      // 输入纹理尺寸
uniform vec2 uOutputSize;     // 输出目标尺寸
uniform int uIsHdr;           // HDR 模式标志（BT.2020 亮度系数）
out vec4 outColor;

// 近似 Lanczos2 核（无 sin/rcp/sqrt）
// (25/16 * (2/5*d²-1)² - (25/16-1)) * (1/4*d²-1)²
float FsrEasuW(float d2, float lob, float clp) {
    d2 = min(d2, clp);
    float wB = (2.0/5.0) * d2 - 1.0;
    float wA = lob * d2 - 1.0;
    wB *= wB;
    wA *= wA;
    wB = (25.0/16.0) * wB - (25.0/16.0 - 1.0);
    return wB * wA;
}

void main() {
    // 近似亮度：luma*2 = 0.5*B + 0.5*R + G（与 AMD 原版一致，节省乘法）
    vec3 lumaCoeff = vec3(0.5, 1.0, 0.5);

    // 从输出空间映射到输入空间
    vec2 inputTexelSize = 1.0 / uInputSize;
    vec2 srcPixel = vTexCoord * uInputSize - 0.5;
    vec2 fp = floor(srcPixel);
    vec2 pp = srcPixel - fp;
    vec2 base = (fp + 0.5) * inputTexelSize;

    // 采样 12-tap 十字核
    //    b c
    //  e f g h
    //  i j k l
    //    n o
    vec3 b = texture(uInputTexture, base + vec2( 0, -1) * inputTexelSize).rgb;
    vec3 c = texture(uInputTexture, base + vec2( 1, -1) * inputTexelSize).rgb;
    vec3 e = texture(uInputTexture, base + vec2(-1,  0) * inputTexelSize).rgb;
    vec3 f = texture(uInputTexture, base).rgb;
    vec3 g = texture(uInputTexture, base + vec2( 1,  0) * inputTexelSize).rgb;
    vec3 h = texture(uInputTexture, base + vec2( 2,  0) * inputTexelSize).rgb;
    vec3 i = texture(uInputTexture, base + vec2(-1,  1) * inputTexelSize).rgb;
    vec3 j = texture(uInputTexture, base + vec2( 0,  1) * inputTexelSize).rgb;
    vec3 k = texture(uInputTexture, base + vec2( 1,  1) * inputTexelSize).rgb;
    vec3 l = texture(uInputTexture, base + vec2( 2,  1) * inputTexelSize).rgb;
    vec3 n = texture(uInputTexture, base + vec2( 0,  2) * inputTexelSize).rgb;
    vec3 o = texture(uInputTexture, base + vec2( 1,  2) * inputTexelSize).rgb;

    // 近似亮度（luma*2）
    float bL = dot(b, lumaCoeff);
    float cL = dot(c, lumaCoeff);
    float eL = dot(e, lumaCoeff);
    float fL = dot(f, lumaCoeff);
    float gL = dot(g, lumaCoeff);
    float hL = dot(h, lumaCoeff);
    float iL = dot(i, lumaCoeff);
    float jL = dot(j, lumaCoeff);
    float kL = dot(k, lumaCoeff);
    float lL = dot(l, lumaCoeff);
    float nL = dot(n, lumaCoeff);
    float oL = dot(o, lumaCoeff);

    // 方向检测：4 个双线性位置累加方向和长度
    //   (0): b,e,f,g,j    (1): c,f,g,h,k
    //   (2): f,i,j,k,n    (3): g,j,k,l,o
    vec2 dir = vec2(0.0);
    float len = 0.0;

    // --- Set 0: biS ---
    {
        float w = (1.0 - pp.x) * (1.0 - pp.y);
        float dc = gL - fL; float cb = fL - eL;
        float lenX = max(abs(dc), abs(cb));
        lenX = (lenX > 0.0) ? 1.0 / lenX : 0.0;
        float dX = gL - eL;
        dir.x += dX * w;
        float sX = clamp(abs(dX) * lenX, 0.0, 1.0); sX *= sX; len += sX * w;
        float ec = jL - fL; float ca = fL - bL;
        float lenY = max(abs(ec), abs(ca));
        lenY = (lenY > 0.0) ? 1.0 / lenY : 0.0;
        float dY = jL - bL;
        dir.y += dY * w;
        float sY = clamp(abs(dY) * lenY, 0.0, 1.0); sY *= sY; len += sY * w;
    }
    // --- Set 1: biT ---
    {
        float w = pp.x * (1.0 - pp.y);
        float dc = hL - gL; float cb = gL - fL;
        float lenX = max(abs(dc), abs(cb));
        lenX = (lenX > 0.0) ? 1.0 / lenX : 0.0;
        float dX = hL - fL;
        dir.x += dX * w;
        float sX = clamp(abs(dX) * lenX, 0.0, 1.0); sX *= sX; len += sX * w;
        float ec = kL - gL; float ca = gL - cL;
        float lenY = max(abs(ec), abs(ca));
        lenY = (lenY > 0.0) ? 1.0 / lenY : 0.0;
        float dY = kL - cL;
        dir.y += dY * w;
        float sY = clamp(abs(dY) * lenY, 0.0, 1.0); sY *= sY; len += sY * w;
    }
    // --- Set 2: biU ---
    {
        float w = (1.0 - pp.x) * pp.y;
        float dc = kL - jL; float cb = jL - iL;
        float lenX = max(abs(dc), abs(cb));
        lenX = (lenX > 0.0) ? 1.0 / lenX : 0.0;
        float dX = kL - iL;
        dir.x += dX * w;
        float sX = clamp(abs(dX) * lenX, 0.0, 1.0); sX *= sX; len += sX * w;
        float ec = nL - jL; float ca = jL - fL;
        float lenY = max(abs(ec), abs(ca));
        lenY = (lenY > 0.0) ? 1.0 / lenY : 0.0;
        float dY = nL - fL;
        dir.y += dY * w;
        float sY = clamp(abs(dY) * lenY, 0.0, 1.0); sY *= sY; len += sY * w;
    }
    // --- Set 3: biV ---
    {
        float w = pp.x * pp.y;
        float dc = lL - kL; float cb = kL - jL;
        float lenX = max(abs(dc), abs(cb));
        lenX = (lenX > 0.0) ? 1.0 / lenX : 0.0;
        float dX = lL - jL;
        dir.x += dX * w;
        float sX = clamp(abs(dX) * lenX, 0.0, 1.0); sX *= sX; len += sX * w;
        float ec = oL - kL; float ca = kL - gL;
        float lenY = max(abs(ec), abs(ca));
        lenY = (lenY > 0.0) ? 1.0 / lenY : 0.0;
        float dY = oL - gL;
        dir.y += dY * w;
        float sY = clamp(abs(dY) * lenY, 0.0, 1.0); sY *= sY; len += sY * w;
    }

    // 归一化方向
    float dirR = dir.x * dir.x + dir.y * dir.y;
    bool zro = dirR < (1.0 / 32768.0);
    dirR = inversesqrt(max(dirR, 1.0 / 32768.0));
    dirR = zro ? 1.0 : dirR;
    dir.x = zro ? 1.0 : dir.x;
    dir *= dirR;

    // 将 len 转换到 {0,1} 并平方
    len *= 0.5;
    len *= len;

    // 沿边缘拉伸核
    float stretch = (dir.x * dir.x + dir.y * dir.y) / max(abs(dir.x), abs(dir.y));
    vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);

    // 负瓣参数
    float lob = 0.5 + ((0.25 - 0.04) - 0.5) * len;
    float clp = 1.0 / lob;

    // 邻域极值（f,g,j,k 最近 4 像素）
    vec3 minC = min(min(f, g), min(j, k));
    vec3 maxC = max(max(f, g), max(j, k));

    // 12-tap 累加（旋转+各向异性）
    vec3 aC = vec3(0.0);
    float aW = 0.0;

    #define TAP(px,py,col) { \
        vec2 ofs = vec2(px, py) - pp; \
        float vx = ofs.x * dir.x + ofs.y * dir.y; \
        float vy = ofs.x * (-dir.y) + ofs.y * dir.x; \
        vx *= len2.x; vy *= len2.y; \
        float d2 = vx * vx + vy * vy; \
        float tw = FsrEasuW(d2, lob, clp); \
        aC += col * tw; aW += tw; \
    }

    TAP( 0.0, -1.0, b)  // b
    TAP( 1.0, -1.0, c)  // c
    TAP(-1.0,  0.0, e)  // e
    TAP( 0.0,  0.0, f)  // f
    TAP( 1.0,  0.0, g)  // g
    TAP( 2.0,  0.0, h)  // h
    TAP(-1.0,  1.0, i)  // i
    TAP( 0.0,  1.0, j)  // j
    TAP( 1.0,  1.0, k)  // k
    TAP( 2.0,  1.0, l)  // l
    TAP( 0.0,  2.0, n)  // n
    TAP( 1.0,  2.0, o)  // o

    #undef TAP

    // 归一化并夹钳（消除振铃）
    vec3 result = aC / max(aW, 1e-5);
    outColor = vec4(clamp(result, minC, maxC), 1.0);
}
)";

// FSR 1 RCAS (Robust Contrast Adaptive Sharpening) 着色器
// 在 EASU 上采样后应用自适应锐化
static const char* FSR_RCAS_FRAGMENT_SRC = R"(#version 300 es
precision highp float;
in vec2 vTexCoord;
uniform sampler2D uInputTexture;
uniform float uSharpness;  // 0.0 = 最大锐化, 值越大锐化越弱
uniform int uIsHdr;        // HDR 模式标志（BT.2020 亮度系数）
out vec4 outColor;

void main() {
    vec3 lumaCoeff = (uIsHdr == 1) ? vec3(0.2627, 0.6780, 0.0593) : vec3(0.299, 0.587, 0.114);
    vec2 texSize = vec2(textureSize(uInputTexture, 0));
    vec2 texelSize = 1.0 / texSize;

    // 十字采样 5 tap
    vec3 e = texture(uInputTexture, vTexCoord).rgb;
    vec3 b = texture(uInputTexture, vTexCoord + vec2( 0, -1) * texelSize).rgb;
    vec3 d = texture(uInputTexture, vTexCoord + vec2(-1,  0) * texelSize).rgb;
    vec3 f = texture(uInputTexture, vTexCoord + vec2( 1,  0) * texelSize).rgb;
    vec3 h = texture(uInputTexture, vTexCoord + vec2( 0,  1) * texelSize).rgb;

    // 亮度（近似 luma*2，与 AMD 原版一致：0.5*B + 0.5*R + G）
    float bL = dot(b, lumaCoeff);
    float dL = dot(d, lumaCoeff);
    float eL = dot(e, lumaCoeff);
    float fL = dot(f, lumaCoeff);
    float hL = dot(h, lumaCoeff);

    // 噪声检测
    float nz = 0.25 * (bL + dL + fL + hL) - eL;
    float range = max(max(bL, max(dL, eL)), max(fL, hL))
                - min(min(bL, min(dL, eL)), min(fL, hL));
    nz = clamp(abs(nz) / max(range, 1e-5), 0.0, 1.0);
    nz = 1.0 - 0.5 * nz;

    // 邻域极值
    float mn4R = min(min(b.r, d.r), min(f.r, h.r));
    float mn4G = min(min(b.g, d.g), min(f.g, h.g));
    float mn4B = min(min(b.b, d.b), min(f.b, h.b));
    float mx4R = max(max(b.r, d.r), max(f.r, h.r));
    float mx4G = max(max(b.g, d.g), max(f.g, h.g));
    float mx4B = max(max(b.b, d.b), max(f.b, h.b));

    // 求解最大不截断的锐化权重（AMD 原版 RCAS 算法）
    // hitMin = min(mn4, e) / (4*mx4)          → 正值
    // hitMax = (1 - max(mx4, e)) / (4*mn4-4)  → 负值
    // lobe = max(-hitMin, hitMax)              → 负值（锐化权重）
    vec2 peakC = vec2(1.0, -4.0);
    float hitMinR = min(mn4R, e.r) / max(4.0 * mx4R, 1e-5);
    float hitMinG = min(mn4G, e.g) / max(4.0 * mx4G, 1e-5);
    float hitMinB = min(mn4B, e.b) / max(4.0 * mx4B, 1e-5);
    float hitMaxR = (peakC.x - max(mx4R, e.r)) / min(4.0 * mn4R + peakC.y, -1e-5);
    float hitMaxG = (peakC.x - max(mx4G, e.g)) / min(4.0 * mn4G + peakC.y, -1e-5);
    float hitMaxB = (peakC.x - max(mx4B, e.b)) / min(4.0 * mn4B + peakC.y, -1e-5);
    float lobeR = max(-hitMinR, hitMaxR);
    float lobeG = max(-hitMinG, hitMaxG);
    float lobeB = max(-hitMinB, hitMaxB);

    // 限制锐化强度（lobe 为负值）
    float limit = 0.25 - 1.0 / 16.0;
    float lobe = max(-limit, min(max(max(lobeR, lobeG), lobeB), 0.0));

    // 应用锐度控制
    float sharp = exp2(-uSharpness);
    lobe *= sharp * nz;

    float rcpW = 1.0 / (4.0 * lobe + 1.0);
    outColor = vec4((lobe * b + lobe * d + lobe * h + lobe * f + e) * rcpW, 1.0);
}
)";

// 用于 TEXTURE_2D 输入的顶点着色器（与 OES 顶点着色器一样）
static const char* VERTEX_SHADER_2D_SRC = R"(#version 300 es
layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aTexCoord;
out vec2 vTexCoord;
void main() {
    gl_Position = vec4(aPosition, 0.0, 1.0);
    vTexCoord = aTexCoord;
}
)";

// 全屏四边形顶点数据 (position.xy, texcoord.xy)
static const float QUAD_VERTICES[] = {
    -1.0f, -1.0f,  0.0f, 0.0f,
     1.0f, -1.0f,  1.0f, 0.0f,
    -1.0f,  1.0f,  0.0f, 1.0f,
     1.0f,  1.0f,  1.0f, 1.0f,
};

// =============================================================================
// 蓝噪声生成（64x64 逐级抖动矩阵）
// =============================================================================
static void GenerateBlueNoise(uint8_t* data, int size) {
    // 使用 Bayer 有序抖动矩阵作为蓝噪声的近似
    // 对于暗区抖动来说效果足够好，且无需额外资源文件
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            // 8x8 Bayer matrix tiled to fill 64x64
            int bx = x & 7, by = y & 7;
            // 标准 8x8 Bayer 阈值矩阵（值域 0-63）
            static const uint8_t bayer8[8][8] = {
                { 0, 32,  8, 40,  2, 34, 10, 42},
                {48, 16, 56, 24, 50, 18, 58, 26},
                {12, 44,  4, 36, 14, 46,  6, 38},
                {60, 28, 52, 20, 62, 30, 54, 22},
                { 3, 35, 11, 43,  1, 33,  9, 41},
                {51, 19, 59, 27, 49, 17, 57, 25},
                {15, 47,  7, 39, 13, 45,  5, 37},
                {63, 31, 55, 23, 61, 29, 53, 21}
            };
            data[y * size + x] = static_cast<uint8_t>(bayer8[by][bx] * 4 + 2);
        }
    }
}

// =============================================================================
// 单例
// =============================================================================

GLPostProcessor* GLPostProcessor::instance_ = nullptr;
std::mutex GLPostProcessor::instanceMutex_;

GLPostProcessor* GLPostProcessor::GetInstance() {
    std::lock_guard<std::mutex> lock(instanceMutex_);
    if (!instance_) {
        instance_ = new GLPostProcessor();
    }
    return instance_;
}

void GLPostProcessor::ReleaseInstance() {
    std::lock_guard<std::mutex> lock(instanceMutex_);
    if (instance_) {
        delete instance_;
        instance_ = nullptr;
    }
}

GLPostProcessor::GLPostProcessor() = default;

GLPostProcessor::~GLPostProcessor() {
    ReleaseInternal();
}

// =============================================================================
// 初始化
// =============================================================================

int GLPostProcessor::Init(OHNativeWindow* displayWindow,
                          uint32_t inputWidth, uint32_t inputHeight,
                          uint32_t outputWidth, uint32_t outputHeight) {
    std::lock_guard<std::mutex> lock(processMutex_);

    if (initialized_) {
        OH_LOG_WARN(LOG_APP, "GLPostProcessor already initialized");
        return 0;
    }

    if (!displayWindow) {
        OH_LOG_ERROR(LOG_APP, "GLPostProcessor: null display window");
        return -1;
    }

    displayWindow_ = displayWindow;
    inputWidth_ = inputWidth;
    inputHeight_ = inputHeight;
    outputWidth_ = (outputWidth > 0) ? outputWidth : inputWidth;
    outputHeight_ = (outputHeight > 0) ? outputHeight : inputHeight;

    // 加载所有 API
    if (!LoadAPIs()) {
        OH_LOG_ERROR(LOG_APP, "GLPostProcessor: failed to load APIs");
        return -1;
    }

    // SDR -> HDR: configure display surface for HDR PQ color space
    if (sdrToHdr_ && hdrMode_ == PostProcessHdrMode::SDR) {
        OH_NativeWindow_SetColorSpace(displayWindow, OH_COLORSPACE_BT2020_PQ_FULL);
        OH_NativeWindow_NativeWindowHandleOpt(displayWindow, SET_COLOR_GAMUT,
                                               NATIVEBUFFER_COLOR_GAMUT_BT2100_PQ);
        OH_LOG_INFO(LOG_APP, "GLPostProcessor: SDR->HDR enabled, display set to BT.2020 PQ (peak=%.0f nits)",
                     sdrToHdrPeakNits_);
    } else if (hdrMode_ == PostProcessHdrMode::HLG) {
        // HLG HDR: 设置显示窗口为 BT.2020 HLG 色彩空间
        // 解码器直出时系统自动设置；但经过 GLPostProcessor 的 FBO 中转后，
        // 需要手动告知系统输出内容是 HLG 编码，否则色彩会偏淡
        OH_NativeWindow_SetColorSpace(displayWindow, OH_COLORSPACE_BT2020_HLG_FULL);
        OH_NativeWindow_NativeWindowHandleOpt(displayWindow, SET_COLOR_GAMUT,
                                               NATIVEBUFFER_COLOR_GAMUT_BT2100_HLG);
        OH_LOG_INFO(LOG_APP, "GLPostProcessor: HLG HDR, display set to BT.2020 HLG");
    } else if (hdrMode_ == PostProcessHdrMode::PQ) {
        // PQ HDR10: 设置显示窗口为 BT.2020 PQ 色彩空间
        OH_NativeWindow_SetColorSpace(displayWindow, OH_COLORSPACE_BT2020_PQ_FULL);
        OH_NativeWindow_NativeWindowHandleOpt(displayWindow, SET_COLOR_GAMUT,
                                               NATIVEBUFFER_COLOR_GAMUT_BT2100_PQ);
        OH_LOG_INFO(LOG_APP, "GLPostProcessor: HDR10 PQ, display set to BT.2020 PQ");
    } else {
        OH_LOG_INFO(LOG_APP, "GLPostProcessor::Init: sdrToHdr=%{public}d hdrMode=%{public}d dither=%{public}d",
                     sdrToHdr_ ? 1 : 0, static_cast<int>(hdrMode_), ditherEnabled_ ? 1 : 0);
    }

    // 初始化 EGL（在 display window 上创建 EGL surface）
    // InitEGL 内部会通过 eglQuerySurface 获取实际 surface 尺寸并更新 outputWidth_/outputHeight_
    if (!InitEGL(displayWindow)) {
        OH_LOG_ERROR(LOG_APP, "GLPostProcessor: EGL init failed");
        ReleaseInternal();
        return -1;
    }

    // EGL surface 实际尺寸由 XComponent 布局决定（已包含 letterbox 计算），
    // 直接使用 outputWidth_/outputHeight_ 作为渲染区域，无需再手动 letterbox
    renderWidth_ = outputWidth_;
    renderHeight_ = outputHeight_;
    renderX_ = 0;
    renderY_ = 0;

    // 创建 OES 纹理 + OH_NativeImage
    if (!InitNativeImage()) {
        OH_LOG_ERROR(LOG_APP, "GLPostProcessor: NativeImage init failed");
        ReleaseInternal();
        return -1;
    }

    // 编译着色器
    if (!InitShaders()) {
        OH_LOG_ERROR(LOG_APP, "GLPostProcessor: shader init failed");
        ReleaseInternal();
        return -1;
    }

    // 生成蓝噪声纹理
    if (!InitBlueNoiseTexture()) {
        OH_LOG_WARN(LOG_APP, "GLPostProcessor: blue noise init failed, dithering quality reduced");
    }

    // 初始化 FBO（用于 OES → TEXTURE_2D 转换，超分辨率需要）
    if (upscaleMode_ != UpscaleMode::OFF) {
        if (!InitFBO()) {
            OH_LOG_WARN(LOG_APP, "GLPostProcessor: FBO init failed, upscale disabled");
            upscaleMode_ = UpscaleMode::OFF;
        } else if (!InitUpscale()) {
            OH_LOG_WARN(LOG_APP, "GLPostProcessor: upscale init failed, upscale disabled");
            ReleaseFBO();
            upscaleMode_ = UpscaleMode::OFF;
        }

        // 如果超分实际不需要（输出<=输入），释放 FBO 管线
        if (activeUpscale_ == UpscaleMode::OFF && fbo_) {
            OH_LOG_INFO(LOG_APP, "GLPostProcessor: upscale not needed (native resolution), releasing FBO pipeline");
            ReleaseFBO();
            ReleaseUpscale();
            upscaleMode_ = UpscaleMode::OFF;
        }
    }

    // 如果没有任何后处理需要，释放整个管线避免不必要的中转开销
    if (!IsActive()) {
        OH_LOG_INFO(LOG_APP, "GLPostProcessor: no post-processing needed, releasing pipeline");
        ReleaseInternal();
        return 0;  // 成功，但不激活管线
    }

    initialized_ = true;

    // Release EGL context from init thread so decode thread can claim it
    g_api.eglMakeCurrent(eglDisplay_, MY_EGL_NO_SURFACE, MY_EGL_NO_SURFACE, MY_EGL_NO_CONTEXT);

    OH_LOG_INFO(LOG_APP, "GLPostProcessor initialized: input=%{public}ux%{public}u output=%{public}ux%{public}u upscale=%{public}d",
                inputWidth_, inputHeight_, outputWidth_, outputHeight_, static_cast<int>(activeUpscale_));
    return 0;
}

bool GLPostProcessor::InitEGL(OHNativeWindow* displayWindow) {
    eglDisplay_ = g_api.eglGetDisplay(MY_EGL_DEFAULT_DISPLAY);
    if (eglDisplay_ == MY_EGL_NO_DISPLAY) {
        OH_LOG_ERROR(LOG_APP, "eglGetDisplay failed");
        return false;
    }

    EGLint major, minor;
    if (!g_api.eglInitialize(eglDisplay_, &major, &minor)) {
        OH_LOG_ERROR(LOG_APP, "eglInitialize failed");
        return false;
    }
    OH_LOG_INFO(LOG_APP, "EGL %{public}d.%{public}d initialized", major, minor);

    // Query window's current pixel format
    int32_t windowFormat = 0;
    OH_NativeWindow_NativeWindowHandleOpt(displayWindow, GET_FORMAT, &windowFormat);
    OH_LOG_INFO(LOG_APP, "Window pixel format: %{public}d", windowFormat);

    // Get all available EGL configs
    EGLint totalConfigs = 0;
    if (!g_api.eglGetConfigs || !g_api.eglGetConfigAttrib) {
        OH_LOG_ERROR(LOG_APP, "eglGetConfigs/eglGetConfigAttrib not available");
        return false;
    }
    g_api.eglGetConfigs(eglDisplay_, nullptr, 0, &totalConfigs);
    OH_LOG_INFO(LOG_APP, "EGL total configs: %{public}d", totalConfigs);

    if (totalConfigs <= 0) {
        OH_LOG_ERROR(LOG_APP, "No EGL configs available");
        return false;
    }

    // Enumerate all configs and dump their attributes
    int maxDump = totalConfigs < 32 ? totalConfigs : 32;
    EGLConfig allConfigs[32];
    EGLint gotConfigs = 0;
    g_api.eglGetConfigs(eglDisplay_, allConfigs, maxDump, &gotConfigs);

    // Log all configs for diagnostics, and find best match
    EGLConfig bestConfig = nullptr;
    int bestScore = -1;
    for (int i = 0; i < gotConfigs; i++) {
        EGLint r = 0, g = 0, b = 0, a = 0, rt = 0, st = 0, nv = 0;
        g_api.eglGetConfigAttrib(eglDisplay_, allConfigs[i], MY_EGL_RED_SIZE, &r);
        g_api.eglGetConfigAttrib(eglDisplay_, allConfigs[i], MY_EGL_GREEN_SIZE, &g);
        g_api.eglGetConfigAttrib(eglDisplay_, allConfigs[i], MY_EGL_BLUE_SIZE, &b);
        g_api.eglGetConfigAttrib(eglDisplay_, allConfigs[i], MY_EGL_ALPHA_SIZE, &a);
        g_api.eglGetConfigAttrib(eglDisplay_, allConfigs[i], MY_EGL_RENDERABLE_TYPE, &rt);
        g_api.eglGetConfigAttrib(eglDisplay_, allConfigs[i], MY_EGL_SURFACE_TYPE, &st);
        g_api.eglGetConfigAttrib(eglDisplay_, allConfigs[i], MY_EGL_NATIVE_VISUAL_ID, &nv);

        // Score this config: prefer matching window format, then ES3, then higher color depth
        bool hasWindow = (st & MY_EGL_WINDOW_BIT) != 0;
        bool hasES3 = (rt & MY_EGL_OPENGL_ES3_BIT) != 0;
        bool fmtMatch = (nv == windowFormat);
        int colorBits = r + g + b + a;

        if (!hasWindow) continue; // Must support window surfaces

        int score = 0;
        if (fmtMatch) score += 10000;  // Matching format is critical
        if (hasES3) score += 1000;     // Prefer ES3
        score += colorBits * 10;       // Prefer higher color depth

        if (score > bestScore) {
            bestScore = score;
            bestConfig = allConfigs[i];
        }
    }

    if (bestConfig == nullptr) {
        OH_LOG_ERROR(LOG_APP, "No EGL config with WINDOW_BIT found");
        return false;
    }

    eglConfig_ = bestConfig;
    {
        EGLint r = 0, g = 0, b = 0, a = 0, nv = 0, rt = 0;
        g_api.eglGetConfigAttrib(eglDisplay_, eglConfig_, MY_EGL_RED_SIZE, &r);
        g_api.eglGetConfigAttrib(eglDisplay_, eglConfig_, MY_EGL_GREEN_SIZE, &g);
        g_api.eglGetConfigAttrib(eglDisplay_, eglConfig_, MY_EGL_BLUE_SIZE, &b);
        g_api.eglGetConfigAttrib(eglDisplay_, eglConfig_, MY_EGL_ALPHA_SIZE, &a);
        g_api.eglGetConfigAttrib(eglDisplay_, eglConfig_, MY_EGL_NATIVE_VISUAL_ID, &nv);
        g_api.eglGetConfigAttrib(eglDisplay_, eglConfig_, MY_EGL_RENDERABLE_TYPE, &rt);
        OH_LOG_INFO(LOG_APP, "Selected EGL config: R%{public}dG%{public}dB%{public}dA%{public}d nv=%{public}d rt=0x%{public}x score=%{public}d",
                    r, g, b, a, nv, rt, bestScore);
    }

    // If best config's native visual doesn't match window format, try setting window format
    {
        EGLint nv = 0;
        g_api.eglGetConfigAttrib(eglDisplay_, eglConfig_, MY_EGL_NATIVE_VISUAL_ID, &nv);
        if (nv != windowFormat && nv != 0) {
            OH_LOG_WARN(LOG_APP, "Config nativeVisual=%{public}d != windowFormat=%{public}d, setting window format",
                        nv, windowFormat);
            OH_NativeWindow_NativeWindowHandleOpt(displayWindow, SET_FORMAT, nv);
        }
    }

    // Create EGL context (GLES 3.0, fallback to 2.0)
    EGLint ctxAttribs3[] = { MY_EGL_CONTEXT_CLIENT_VERSION, 3, MY_EGL_NONE };
    eglContext_ = g_api.eglCreateContext(eglDisplay_, eglConfig_, MY_EGL_NO_CONTEXT, ctxAttribs3);
    if (eglContext_ == MY_EGL_NO_CONTEXT) {
        OH_LOG_WARN(LOG_APP, "eglCreateContext GLES3 failed, trying GLES2");
        EGLint ctxAttribs2[] = { MY_EGL_CONTEXT_CLIENT_VERSION, 2, MY_EGL_NONE };
        eglContext_ = g_api.eglCreateContext(eglDisplay_, eglConfig_, MY_EGL_NO_CONTEXT, ctxAttribs2);
    }
    if (eglContext_ == MY_EGL_NO_CONTEXT) {
        OH_LOG_ERROR(LOG_APP, "eglCreateContext failed");
        return false;
    }

    // Create EGL window surface
    eglSurface_ = g_api.eglCreateWindowSurface(eglDisplay_, eglConfig_,
                                                 (EGLNativeWindowType)displayWindow, nullptr);
    if (eglSurface_ == MY_EGL_NO_SURFACE) {
        OH_LOG_ERROR(LOG_APP, "eglCreateWindowSurface failed");
        return false;
    }

    if (!g_api.eglMakeCurrent(eglDisplay_, eglSurface_, eglSurface_, eglContext_)) {
        OH_LOG_ERROR(LOG_APP, "eglMakeCurrent failed");
        return false;
    }

    OH_LOG_INFO(LOG_APP, "EGL context created and bound");

    // 查询 EGL surface 的实际像素尺寸（由 XComponent 布局决定，已经包含 letterbox 计算）
    if (g_api.eglQuerySurface) {
        EGLint surfW = 0, surfH = 0;
        g_api.eglQuerySurface(eglDisplay_, eglSurface_, MY_EGL_WIDTH, &surfW);
        g_api.eglQuerySurface(eglDisplay_, eglSurface_, MY_EGL_HEIGHT, &surfH);
        if (surfW > 0 && surfH > 0) {
            OH_LOG_INFO(LOG_APP, "EGL surface actual size: %{public}dx%{public}d (passed output: %{public}ux%{public}u)",
                        surfW, surfH, outputWidth_, outputHeight_);
            outputWidth_ = static_cast<uint32_t>(surfW);
            outputHeight_ = static_cast<uint32_t>(surfH);
        }
    }

    // 禁用 VSync 同步，避免 eglSwapBuffers 阻塞解码器回调线程
    if (g_api.eglSwapInterval) {
        g_api.eglSwapInterval(eglDisplay_, 0);
    }

    return true;
}

bool GLPostProcessor::InitNativeImage() {
    // 创建 OES 纹理
    g_api.glGenTextures(1, &oesTexture_);
    g_api.glBindTexture(MY_GL_TEXTURE_EXTERNAL_OES, oesTexture_);
    g_api.glTexParameteri(MY_GL_TEXTURE_EXTERNAL_OES, MY_GL_TEXTURE_MIN_FILTER, MY_GL_LINEAR);
    g_api.glTexParameteri(MY_GL_TEXTURE_EXTERNAL_OES, MY_GL_TEXTURE_MAG_FILTER, MY_GL_LINEAR);
    g_api.glTexParameteri(MY_GL_TEXTURE_EXTERNAL_OES, MY_GL_TEXTURE_WRAP_S, MY_GL_CLAMP_TO_EDGE);
    g_api.glTexParameteri(MY_GL_TEXTURE_EXTERNAL_OES, MY_GL_TEXTURE_WRAP_T, MY_GL_CLAMP_TO_EDGE);

    // 创建 OH_NativeImage（绑定到 OES 纹理）
    nativeImage_ = g_api.nativeImageCreate(oesTexture_, MY_GL_TEXTURE_EXTERNAL_OES);
    if (!nativeImage_) {
        OH_LOG_ERROR(LOG_APP, "OH_NativeImage_Create failed");
        return false;
    }

    // 获取代理 NativeWindow（解码器将输出到这里）
    proxyWindow_ = g_api.nativeImageAcquireWindow(nativeImage_);
    if (!proxyWindow_) {
        OH_LOG_ERROR(LOG_APP, "OH_NativeImage_AcquireNativeWindow failed");
        return false;
    }

    OH_LOG_INFO(LOG_APP, "NativeImage created: texture=%{public}u, proxyWindow=%{public}p",
                oesTexture_, static_cast<void*>(proxyWindow_));
    return true;
}

static GLuint CompileShader(unsigned int type, const char* source) {
    GLuint shader = g_api.glCreateShader(type);
    g_api.glShaderSource(shader, 1, &source, nullptr);
    g_api.glCompileShader(shader);

    int status;
    g_api.glGetShaderiv(shader, MY_GL_COMPILE_STATUS, &status);
    if (!status) {
        char log[512];
        g_api.glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        OH_LOG_ERROR(LOG_APP, "Shader compile failed: %{public}s", log);
        g_api.glDeleteShader(shader);
        return 0;
    }
    return shader;
}

bool GLPostProcessor::InitShaders() {
    GLuint vert = CompileShader(MY_GL_VERTEX_SHADER, VERTEX_SHADER_SRC);
    if (!vert) return false;

    GLuint frag = CompileShader(MY_GL_FRAGMENT_SHADER, FRAGMENT_SHADER_SRC);
    if (!frag) {
        g_api.glDeleteShader(vert);
        return false;
    }

    shaderProgram_ = g_api.glCreateProgram();
    g_api.glAttachShader(shaderProgram_, vert);
    g_api.glAttachShader(shaderProgram_, frag);
    g_api.glLinkProgram(shaderProgram_);

    g_api.glDeleteShader(vert);
    g_api.glDeleteShader(frag);

    int status;
    g_api.glGetProgramiv(shaderProgram_, MY_GL_LINK_STATUS, &status);
    if (!status) {
        char log[512];
        g_api.glGetProgramInfoLog(shaderProgram_, sizeof(log), nullptr, log);
        OH_LOG_ERROR(LOG_APP, "Program link failed: %{public}s", log);
        g_api.glDeleteProgram(shaderProgram_);
        shaderProgram_ = 0;
        return false;
    }

    // 获取 uniform locations
    locTexture_ = g_api.glGetUniformLocation(shaderProgram_, "uTexture");
    locBlueNoise_ = g_api.glGetUniformLocation(shaderProgram_, "uBlueNoiseTexture");
    locTexelSize_ = g_api.glGetUniformLocation(shaderProgram_, "uTexelSize");
    locTimePhase_ = g_api.glGetUniformLocation(shaderProgram_, "uTimePhase");
    locEnableFilter_ = g_api.glGetUniformLocation(shaderProgram_, "uEnableFilter");
    locHdrMode_ = g_api.glGetUniformLocation(shaderProgram_, "uHdrMode");
    locSdrToHdr_ = g_api.glGetUniformLocation(shaderProgram_, "uSdrToHdr");
    locSdrPeakNits_ = g_api.glGetUniformLocation(shaderProgram_, "uSdrPeakNits");
    locSdrSaturation_ = g_api.glGetUniformLocation(shaderProgram_, "uSdrSaturation");
    locSdrContrast_ = g_api.glGetUniformLocation(shaderProgram_, "uSdrContrast");

    // 创建 VAO/VBO
    g_api.glGenVertexArrays(1, &vao_);
    g_api.glGenBuffers(1, &vbo_);

    g_api.glBindVertexArray(vao_);
    g_api.glBindBuffer(MY_GL_ARRAY_BUFFER, vbo_);
    g_api.glBufferData(MY_GL_ARRAY_BUFFER, sizeof(QUAD_VERTICES), QUAD_VERTICES, MY_GL_STATIC_DRAW);

    // position (location=0)
    g_api.glVertexAttribPointer(0, 2, MY_GL_FLOAT, MY_GL_FALSE, 4 * sizeof(float), (void*)0);
    g_api.glEnableVertexAttribArray(0);
    // texcoord (location=1)
    g_api.glVertexAttribPointer(1, 2, MY_GL_FLOAT, MY_GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
    g_api.glEnableVertexAttribArray(1);

    g_api.glBindVertexArray(0);

    OH_LOG_INFO(LOG_APP, "Shaders compiled and linked: program=%{public}u", shaderProgram_);
    return true;
}

bool GLPostProcessor::InitBlueNoiseTexture() {
    const int SIZE = 64;
    uint8_t data[SIZE * SIZE];
    GenerateBlueNoise(data, SIZE);

    g_api.glGenTextures(1, &blueNoiseTexture_);
    g_api.glBindTexture(MY_GL_TEXTURE_2D, blueNoiseTexture_);
    g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_MIN_FILTER, MY_GL_NEAREST);
    g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_MAG_FILTER, MY_GL_NEAREST);
    g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_WRAP_S, MY_GL_REPEAT);
    g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_WRAP_T, MY_GL_REPEAT);
    g_api.glTexImage2D(MY_GL_TEXTURE_2D, 0, MY_GL_R8, SIZE, SIZE, 0,
                        MY_GL_RED, MY_GL_UNSIGNED_BYTE, data);

    OH_LOG_INFO(LOG_APP, "Blue noise texture created: %{public}u", blueNoiseTexture_);
    return true;
}

// 链接着色器程序的通用辅助函数
static GLuint LinkProgram(GLuint vert, GLuint frag) {
    GLuint prog = g_api.glCreateProgram();
    g_api.glAttachShader(prog, vert);
    g_api.glAttachShader(prog, frag);
    g_api.glLinkProgram(prog);

    int status;
    g_api.glGetProgramiv(prog, MY_GL_LINK_STATUS, &status);
    if (!status) {
        char log[512];
        g_api.glGetProgramInfoLog(prog, sizeof(log), nullptr, log);
        OH_LOG_ERROR(LOG_APP, "Program link failed: %{public}s", log);
        g_api.glDeleteProgram(prog);
        return 0;
    }
    return prog;
}

bool GLPostProcessor::InitFBO() {
    // 创建 FBO 和 TEXTURE_2D 用于 OES → TEXTURE_2D 中转
    g_api.glGenFramebuffers(1, &fbo_);
    g_api.glGenTextures(1, &fboTexture_);

    // HDR 模式统一使用 RGBA16F 保留精度，SDR 使用 RGBA8
    bool isHdr = (hdrMode_ != PostProcessHdrMode::SDR);
    unsigned int internalFormat = isHdr ? MY_GL_RGBA16F : MY_GL_RGBA8;
    unsigned int pixelType = isHdr ? MY_GL_HALF_FLOAT : MY_GL_UNSIGNED_BYTE;

    g_api.glBindTexture(MY_GL_TEXTURE_2D, fboTexture_);
    g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_MIN_FILTER, MY_GL_LINEAR);
    g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_MAG_FILTER, MY_GL_LINEAR);
    g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_WRAP_S, MY_GL_CLAMP_TO_EDGE);
    g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_WRAP_T, MY_GL_CLAMP_TO_EDGE);
    g_api.glTexImage2D(MY_GL_TEXTURE_2D, 0, internalFormat, inputWidth_, inputHeight_, 0,
                    MY_GL_RGBA, pixelType, nullptr);

    OH_LOG_INFO(LOG_APP, "FBO texture: %{public}ux%{public}u fmt=0x%{public}x",
                inputWidth_, inputHeight_, internalFormat);

    // 无论哪种纹理创建方式，都绑定到 FBO
    g_api.glBindFramebuffer(MY_GL_FRAMEBUFFER, fbo_);
    g_api.glFramebufferTexture2D(MY_GL_FRAMEBUFFER, MY_GL_COLOR_ATTACHMENT0,
                                  MY_GL_TEXTURE_2D, fboTexture_, 0);

    unsigned int fbStatus = g_api.glCheckFramebufferStatus(MY_GL_FRAMEBUFFER);
    g_api.glBindFramebuffer(MY_GL_FRAMEBUFFER, 0);

    if (fbStatus != MY_GL_FRAMEBUFFER_COMPLETE) {
        OH_LOG_ERROR(LOG_APP, "FBO incomplete: 0x%{public}x", fbStatus);
        ReleaseFBO();
        return false;
    }

    // 编译 blit 着色器（OES → TEXTURE_2D）
    GLuint vert = CompileShader(MY_GL_VERTEX_SHADER, VERTEX_SHADER_SRC);
    if (!vert) { ReleaseFBO(); return false; }

    GLuint frag = CompileShader(MY_GL_FRAGMENT_SHADER, BLIT_OES_FRAGMENT_SRC);
    if (!frag) { g_api.glDeleteShader(vert); ReleaseFBO(); return false; }

    blitProgram_ = LinkProgram(vert, frag);
    g_api.glDeleteShader(vert);
    g_api.glDeleteShader(frag);

    if (!blitProgram_) { ReleaseFBO(); return false; }

    OH_LOG_INFO(LOG_APP, "FBO initialized: %{public}ux%{public}u, texture=%{public}u",
                inputWidth_, inputHeight_, fboTexture_);
    return true;
}

void GLPostProcessor::ReleaseFBO() {
    if (blitProgram_) { g_api.glDeleteProgram(blitProgram_); blitProgram_ = 0; }
    if (fbo_) { g_api.glDeleteFramebuffers(1, &fbo_); fbo_ = 0; }
    if (fboTexture_) { g_api.glDeleteTextures(1, &fboTexture_); fboTexture_ = 0; }
}

bool GLPostProcessor::InitUpscale() {
    // 根据设定的模式确定实际使用的超分方案
    activeUpscale_ = UpscaleMode::OFF;

    if (outputWidth_ <= inputWidth_ && outputHeight_ <= inputHeight_) {
        OH_LOG_INFO(LOG_APP, "Output <= input, upscale not needed");
        return true;  // 不需要超分，但不是错误
    }

    if (upscaleMode_ == UpscaleMode::XENGINE || upscaleMode_ == UpscaleMode::AUTO) {
        // 尝试 XEngine
        if (g_api.xegGetString && g_api.xegSpatialUpscaleParam && g_api.xegRenderSpatialUpscale) {
            const char* extensions = reinterpret_cast<const char*>(g_api.xegGetString(0x01)); // XEG_EXTENSIONS
            if (extensions && strstr(extensions, "XEG_spatial_upscale")) {
                // 不在初始化时设置参数，改为每帧设置（确保 EGL context 匹配）
                activeUpscale_ = UpscaleMode::XENGINE;
                xengineAvailable_ = true;

                OH_LOG_INFO(LOG_APP, "XEngine spatial upscale enabled, sharpness=%.2f", upscaleSharpness_);
                return true;
            }
            OH_LOG_WARN(LOG_APP, "XEngine loaded but spatial_upscale extension not available");
        }

        if (upscaleMode_ == UpscaleMode::XENGINE) {
            OH_LOG_ERROR(LOG_APP, "XEngine spatial upscale requested but not available");
            return false;
        }
        // AUTO 模式：回落到 FSR1
    }

    // FSR1 回退方案
    if (upscaleMode_ == UpscaleMode::FSR1 || upscaleMode_ == UpscaleMode::AUTO) {
        // 编译 FSR EASU 着色器
        GLuint vert = CompileShader(MY_GL_VERTEX_SHADER, VERTEX_SHADER_2D_SRC);
        if (!vert) return false;

        GLuint easuFrag = CompileShader(MY_GL_FRAGMENT_SHADER, FSR_EASU_FRAGMENT_SRC);
        if (!easuFrag) { g_api.glDeleteShader(vert); return false; }

        fsrEasuProgram_ = LinkProgram(vert, easuFrag);
        g_api.glDeleteShader(easuFrag);

        if (!fsrEasuProgram_) { g_api.glDeleteShader(vert); return false; }

        // 编译 FSR RCAS 着色器
        GLuint rcasFrag = CompileShader(MY_GL_FRAGMENT_SHADER, FSR_RCAS_FRAGMENT_SRC);
        if (!rcasFrag) {
            g_api.glDeleteShader(vert);
            g_api.glDeleteProgram(fsrEasuProgram_);
            fsrEasuProgram_ = 0;
            return false;
        }

        fsrRcasProgram_ = LinkProgram(vert, rcasFrag);
        g_api.glDeleteShader(vert);
        g_api.glDeleteShader(rcasFrag);

        if (!fsrRcasProgram_) {
            g_api.glDeleteProgram(fsrEasuProgram_);
            fsrEasuProgram_ = 0;
            return false;
        }

        // 创建 FSR 中间 FBO（EASU 输出、RCAS 输入，输出分辨率）
        bool isHdr = (hdrMode_ != PostProcessHdrMode::SDR);
        unsigned int fsrInternalFormat = isHdr ? MY_GL_RGBA16F : MY_GL_RGBA8;
        unsigned int fsrPixelType = isHdr ? MY_GL_HALF_FLOAT : MY_GL_UNSIGNED_BYTE;

        g_api.glGenFramebuffers(1, &fsrFbo_);
        g_api.glGenTextures(1, &fsrTexture_);

        g_api.glBindTexture(MY_GL_TEXTURE_2D, fsrTexture_);
        g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_MIN_FILTER, MY_GL_LINEAR);
        g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_MAG_FILTER, MY_GL_LINEAR);
        g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_WRAP_S, MY_GL_CLAMP_TO_EDGE);
        g_api.glTexParameteri(MY_GL_TEXTURE_2D, MY_GL_TEXTURE_WRAP_T, MY_GL_CLAMP_TO_EDGE);
        g_api.glTexImage2D(MY_GL_TEXTURE_2D, 0, fsrInternalFormat, renderWidth_, renderHeight_, 0,
                            MY_GL_RGBA, fsrPixelType, nullptr);

        g_api.glBindFramebuffer(MY_GL_FRAMEBUFFER, fsrFbo_);
        g_api.glFramebufferTexture2D(MY_GL_FRAMEBUFFER, MY_GL_COLOR_ATTACHMENT0,
                                      MY_GL_TEXTURE_2D, fsrTexture_, 0);

        unsigned int fbStatus = g_api.glCheckFramebufferStatus(MY_GL_FRAMEBUFFER);
        g_api.glBindFramebuffer(MY_GL_FRAMEBUFFER, 0);

        if (fbStatus != MY_GL_FRAMEBUFFER_COMPLETE) {
            OH_LOG_ERROR(LOG_APP, "FSR FBO incomplete: 0x%{public}x", fbStatus);
            ReleaseUpscale();
            return false;
        }

        activeUpscale_ = UpscaleMode::FSR1;
        OH_LOG_INFO(LOG_APP, "FSR1 upscale enabled: %{public}ux%{public}u → %{public}ux%{public}u (render %{public}ux%{public}u +%{public}u+%{public}u)",
                    inputWidth_, inputHeight_, outputWidth_, outputHeight_,
                    renderWidth_, renderHeight_, renderX_, renderY_);
        return true;
    }

    return false;
}

void GLPostProcessor::ReleaseUpscale() {
    if (fsrEasuProgram_) { g_api.glDeleteProgram(fsrEasuProgram_); fsrEasuProgram_ = 0; }
    if (fsrRcasProgram_) { g_api.glDeleteProgram(fsrRcasProgram_); fsrRcasProgram_ = 0; }
    if (fsrFbo_) { g_api.glDeleteFramebuffers(1, &fsrFbo_); fsrFbo_ = 0; }
    if (fsrTexture_) { g_api.glDeleteTextures(1, &fsrTexture_); fsrTexture_ = 0; }
    activeUpscale_ = UpscaleMode::OFF;
    xengineAvailable_ = false;
}

void GLPostProcessor::BlitOESToFBO() {
    // 将 OES 纹理渲染到 FBO 的 TEXTURE_2D（输入分辨率）
    // 如果启用了 SDR→HDR 或暗区增强，使用后处理 shader 而非直通 shader
    g_api.glBindFramebuffer(MY_GL_FRAMEBUFFER, fbo_);
    g_api.glViewport(0, 0, inputWidth_, inputHeight_);

    bool usePostProc = (sdrToHdr_ || ditherEnabled_) && shaderProgram_;
    if (usePostProc) {
        // 使用后处理 shader（包含 SDR→HDR 增强、暗区增强等）
        g_api.glUseProgram(shaderProgram_);

        g_api.glActiveTexture(MY_GL_TEXTURE0);
        g_api.glBindTexture(MY_GL_TEXTURE_EXTERNAL_OES, oesTexture_);
        g_api.glUniform1i(locTexture_, 0);

        g_api.glActiveTexture(MY_GL_TEXTURE1);
        g_api.glBindTexture(MY_GL_TEXTURE_2D, blueNoiseTexture_);
        g_api.glUniform1i(locBlueNoise_, 1);

        g_api.glUniform2f(locTexelSize_, 1.0f / inputWidth_, 1.0f / inputHeight_);

        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        float timePhase = static_cast<float>(fmod(ts.tv_sec + ts.tv_nsec * 1e-9, 100.0));
        g_api.glUniform1f(locTimePhase_, timePhase);

        g_api.glUniform1i(locSdrToHdr_, sdrToHdr_ ? 1 : 0);
        g_api.glUniform1f(locSdrSaturation_, sdrToHdrSaturation_);
        g_api.glUniform1f(locSdrContrast_, sdrToHdrContrast_);
        g_api.glUniform1f(locSdrPeakNits_, sdrToHdrPeakNits_);
        g_api.glUniform1i(locEnableFilter_, ditherEnabled_ ? 1 : 0);
        g_api.glUniform1i(locHdrMode_, static_cast<int>(hdrMode_));
    } else {
        // 直通 blit
        g_api.glUseProgram(blitProgram_);

        g_api.glActiveTexture(MY_GL_TEXTURE0);
        g_api.glBindTexture(MY_GL_TEXTURE_EXTERNAL_OES, oesTexture_);
        g_api.glUniform1i(g_api.glGetUniformLocation(blitProgram_, "uTexture"), 0);
    }

    g_api.glBindVertexArray(vao_);
    g_api.glDrawArrays(MY_GL_TRIANGLE_STRIP, 0, 4);
    g_api.glBindVertexArray(0);

    g_api.glBindFramebuffer(MY_GL_FRAMEBUFFER, 0);
}

void GLPostProcessor::ApplyUpscale() {
    int isHdr = (hdrMode_ != PostProcessHdrMode::SDR) ? 1 : 0;

    if (activeUpscale_ == UpscaleMode::XENGINE) {
        // XEngine 硬件加速超分：fboTexture_ → 默认 FBO（屏幕）
        // SCISSOR = 输入裁剪窗口（类似 neural upscale，定义输入采样区域）
        unsigned int scissor[4] = {0, 0, inputWidth_, inputHeight_};
        g_api.xegSpatialUpscaleParam(0x01, scissor);
        float sharp = upscaleSharpness_;
        g_api.xegSpatialUpscaleParam(0x02, &sharp);

        g_api.glActiveTexture(MY_GL_TEXTURE0);
        g_api.glBindTexture(MY_GL_TEXTURE_2D, fboTexture_);
        g_api.glViewport(renderX_, renderY_, renderWidth_, renderHeight_);
        g_api.xegRenderSpatialUpscale(fboTexture_);

        if (frameCount_ < 3) {
            unsigned int err = g_api.glGetError();
            OH_LOG_INFO(LOG_APP, "XEngine frame %{public}u: tex=%{public}u input=%{public}ux%{public}u "
                        "output=%{public}ux%{public}u render=%{public}ux%{public}u+%{public}u+%{public}u "
                        "glErr=0x%{public}x",
                        frameCount_, fboTexture_, inputWidth_, inputHeight_,
                        outputWidth_, outputHeight_, renderWidth_, renderHeight_,
                        renderX_, renderY_, err);
        }
    } else if (activeUpscale_ == UpscaleMode::FSR1) {
        // FSR1 Pass 1: EASU（边缘自适应上采样） — 渲染到 fsrFbo_（renderWidth_ × renderHeight_）
        g_api.glBindFramebuffer(MY_GL_FRAMEBUFFER, fsrFbo_);
        g_api.glViewport(0, 0, renderWidth_, renderHeight_);
        g_api.glUseProgram(fsrEasuProgram_);

        g_api.glActiveTexture(MY_GL_TEXTURE0);
        g_api.glBindTexture(MY_GL_TEXTURE_2D, fboTexture_);
        g_api.glUniform1i(g_api.glGetUniformLocation(fsrEasuProgram_, "uInputTexture"), 0);
        g_api.glUniform2f(g_api.glGetUniformLocation(fsrEasuProgram_, "uInputSize"),
                          static_cast<float>(inputWidth_), static_cast<float>(inputHeight_));
        g_api.glUniform2f(g_api.glGetUniformLocation(fsrEasuProgram_, "uOutputSize"),
                          static_cast<float>(renderWidth_), static_cast<float>(renderHeight_));
        g_api.glUniform1i(g_api.glGetUniformLocation(fsrEasuProgram_, "uIsHdr"), isHdr);

        g_api.glBindVertexArray(vao_);
        g_api.glDrawArrays(MY_GL_TRIANGLE_STRIP, 0, 4);
        g_api.glBindVertexArray(0);

        // FSR1 Pass 2: RCAS（对比度自适应锐化） — 渲染到默认 FBO（屏幕）
        g_api.glBindFramebuffer(MY_GL_FRAMEBUFFER, 0);
        g_api.glViewport(renderX_, renderY_, renderWidth_, renderHeight_);
        g_api.glUseProgram(fsrRcasProgram_);

        g_api.glActiveTexture(MY_GL_TEXTURE0);
        g_api.glBindTexture(MY_GL_TEXTURE_2D, fsrTexture_);
        g_api.glUniform1i(g_api.glGetUniformLocation(fsrRcasProgram_, "uInputTexture"), 0);
        // sharpness: 0.0 = 最大锐化, 2.0 = 非常柔和
        // 将 upscaleSharpness_ (0-1) 映射到 (1.0 - 0.0)
        // 流媒体内容有压缩损失，需要更强的锐化来补偿
        g_api.glUniform1f(g_api.glGetUniformLocation(fsrRcasProgram_, "uSharpness"),
                          1.0f * (1.0f - upscaleSharpness_));
        g_api.glUniform1i(g_api.glGetUniformLocation(fsrRcasProgram_, "uIsHdr"), isHdr);

        g_api.glBindVertexArray(vao_);
        g_api.glDrawArrays(MY_GL_TRIANGLE_STRIP, 0, 4);
        g_api.glBindVertexArray(0);
    }
}

// =============================================================================
// 帧处理
// =============================================================================

OHNativeWindow* GLPostProcessor::GetDecoderWindow() {
    if (initialized_ && IsActive() && proxyWindow_) {
        return proxyWindow_;
    }
    return displayWindow_;
}

void GLPostProcessor::SetHdrMode(PostProcessHdrMode mode) {
    hdrMode_ = mode;
}

void GLPostProcessor::ProcessFrame() {
    if (!initialized_ || !IsActive()) {
        return;
    }

    std::lock_guard<std::mutex> lock(processMutex_);

    // 确保 EGL context 是当前的
    g_api.eglMakeCurrent(eglDisplay_, eglSurface_, eglSurface_, eglContext_);

    // First frame: attach NativeImage to this EGL context (may differ from creation thread)
    if (frameCount_ == 0 && g_api.nativeImageAttachContext) {
        g_api.nativeImageAttachContext(nativeImage_, oesTexture_);
    }

    // 从 NativeImage 更新纹理（获取解码器最新输出帧）
    int32_t ret = g_api.nativeImageUpdateSurface(nativeImage_);
    if (ret != 0) {
        return;
    }

    if (activeUpscale_ != UpscaleMode::OFF && fbo_) {
        // === 超分辨率管线 ===
        // Pass 1: OES → TEXTURE_2D (FBO blit)
        BlitOESToFBO();

        // Pass 2+3: 超分辨率（XEngine 或 FSR1 EASU+RCAS）→ 默认 FBO（屏幕）
        ApplyUpscale();

        if (frameCount_ == 0) {
            unsigned int err = g_api.glGetError();
            OH_LOG_INFO(LOG_APP, "First upscale frame: mode=%{public}d glErr=0x%{public}x",
                        static_cast<int>(activeUpscale_), err);
        }
    } else {
        // === 原有管线：直接 OES → 屏幕（暗区增强后处理）===
        DrawFullscreenQuad();
    }

    // 提交到显示
    g_api.eglSwapBuffers(eglDisplay_, eglSurface_);

    frameCount_++;
}

void GLPostProcessor::DrawFullscreenQuad() {
    g_api.glViewport(0, 0, outputWidth_, outputHeight_);

    g_api.glUseProgram(shaderProgram_);

    // 绑定 OES 纹理到 unit 0
    g_api.glActiveTexture(MY_GL_TEXTURE0);
    g_api.glBindTexture(MY_GL_TEXTURE_EXTERNAL_OES, oesTexture_);
    g_api.glUniform1i(locTexture_, 0);

    // 绑定蓝噪声纹理到 unit 1
    g_api.glActiveTexture(MY_GL_TEXTURE1);
    g_api.glBindTexture(MY_GL_TEXTURE_2D, blueNoiseTexture_);
    g_api.glUniform1i(locBlueNoise_, 1);

    // 设置 uniforms
    g_api.glUniform2f(locTexelSize_, 1.0f / outputWidth_, 1.0f / outputHeight_);

    // 时间相位（用于蓝噪声偏移的时间抖动）
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    float timePhase = static_cast<float>(fmod(ts.tv_sec + ts.tv_nsec * 1e-9, 100.0));
    g_api.glUniform1f(locTimePhase_, timePhase);

    g_api.glUniform1i(locSdrToHdr_, sdrToHdr_ ? 1 : 0);
    g_api.glUniform1f(locSdrSaturation_, sdrToHdrSaturation_);
    g_api.glUniform1f(locSdrContrast_, sdrToHdrContrast_);
    g_api.glUniform1f(locSdrPeakNits_, sdrToHdrPeakNits_);
    g_api.glUniform1i(locEnableFilter_, ditherEnabled_ ? 1 : 0);
    g_api.glUniform1i(locHdrMode_, static_cast<int>(hdrMode_));

    // 绘制
    g_api.glBindVertexArray(vao_);
    g_api.glDrawArrays(MY_GL_TRIANGLE_STRIP, 0, 4);
    g_api.glBindVertexArray(0);
}

// =============================================================================
// 清理
// =============================================================================

void GLPostProcessor::Release() {
    std::lock_guard<std::mutex> lock(processMutex_);
    ReleaseInternal();
}

void GLPostProcessor::ReleaseInternal() {
    if (eglDisplay_ && eglSurface_ && eglContext_) {
        g_api.eglMakeCurrent(eglDisplay_, eglSurface_, eglSurface_, eglContext_);
    }

    ReleaseUpscale();
    ReleaseFBO();
    ReleaseShaders();
    ReleaseNativeImage();
    ReleaseEGL();

    initialized_ = false;
    frameCount_ = 0;
    OH_LOG_INFO(LOG_APP, "GLPostProcessor released");
}

void GLPostProcessor::ReleaseShaders() {
    if (vao_) { g_api.glDeleteVertexArrays(1, &vao_); vao_ = 0; }
    if (vbo_) { g_api.glDeleteBuffers(1, &vbo_); vbo_ = 0; }
    if (blueNoiseTexture_) { g_api.glDeleteTextures(1, &blueNoiseTexture_); blueNoiseTexture_ = 0; }
    if (shaderProgram_) { g_api.glDeleteProgram(shaderProgram_); shaderProgram_ = 0; }
}

void GLPostProcessor::ReleaseNativeImage() {
    if (nativeImage_) {
        g_api.nativeImageDestroy(&nativeImage_);
        nativeImage_ = nullptr;
        proxyWindow_ = nullptr;  // owned by NativeImage
    }
    if (oesTexture_) { g_api.glDeleteTextures(1, &oesTexture_); oesTexture_ = 0; }
}

void GLPostProcessor::ReleaseEGL() {
    if (eglDisplay_) {
        g_api.eglMakeCurrent(eglDisplay_, MY_EGL_NO_SURFACE, MY_EGL_NO_SURFACE, MY_EGL_NO_CONTEXT);
        if (eglSurface_) { g_api.eglDestroySurface(eglDisplay_, eglSurface_); eglSurface_ = nullptr; }
        if (eglContext_) { g_api.eglDestroyContext(eglDisplay_, eglContext_); eglContext_ = nullptr; }
        g_api.eglTerminate(eglDisplay_);
        eglDisplay_ = nullptr;
    }
}
