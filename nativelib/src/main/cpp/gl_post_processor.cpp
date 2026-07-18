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
#include <native_image/native_image.h>
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
typedef int64_t (*PFN_OH_NativeImage_GetTimestamp)(OH_NativeImage*);
typedef void (*PFN_OH_NativeImage_Destroy)(OH_NativeImage**);
typedef int32_t (*PFN_OH_NativeImage_AttachContext)(OH_NativeImage*, GLuint);
typedef int32_t (*PFN_OH_NativeImage_SetOnFrameAvailableListener)(
    OH_NativeImage*, OH_OnFrameAvailableListener);
typedef int32_t (*PFN_OH_NativeImage_UnsetOnFrameAvailableListener)(OH_NativeImage*);

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
    PFN_OH_NativeImage_SetOnFrameAvailableListener nativeImageSetFrameListener;
    PFN_OH_NativeImage_UnsetOnFrameAvailableListener nativeImageUnsetFrameListener;
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
    g_api.nativeImageSetFrameListener = (PFN_OH_NativeImage_SetOnFrameAvailableListener)
        dlsym(niLib, "OH_NativeImage_SetOnFrameAvailableListener");
    g_api.nativeImageUnsetFrameListener = (PFN_OH_NativeImage_UnsetOnFrameAvailableListener)
        dlsym(niLib, "OH_NativeImage_UnsetOnFrameAvailableListener");

    // Validate critical functions
    if (!g_api.eglGetDisplay || !g_api.eglInitialize || !g_api.eglChooseConfig ||
        !g_api.eglCreateContext || !g_api.eglCreateWindowSurface || !g_api.eglMakeCurrent ||
        !g_api.eglSwapBuffers || !g_api.glCreateShader || !g_api.glCreateProgram ||
        !g_api.nativeImageCreate || !g_api.nativeImageAcquireWindow ||
        !g_api.nativeImageUpdateSurface || !g_api.nativeImageSetFrameListener ||
        !g_api.nativeImageUnsetFrameListener) {
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
// 着色器源码（从 shaders/ 目录的 .vert/.frag 文件自动生成）
// =============================================================================
#include "shader_strings.h"

// 变量名映射（保持与后续代码的兼容性）
static const char* VERTEX_SHADER_SRC       = SHADER_POST_PROCESS_VERT;
static const char* FRAGMENT_SHADER_SRC     = SHADER_POST_PROCESS_FRAG;
static const char* BLIT_OES_FRAGMENT_SRC   = SHADER_BLIT_OES_FRAG;
static const char* FSR_EASU_FRAGMENT_SRC   = SHADER_FSR_EASU_FRAG;
static const char* FSR_RCAS_FRAGMENT_SRC   = SHADER_FSR_RCAS_FRAG;
static const char* VERTEX_SHADER_2D_SRC   = SHADER_FULLSCREEN_VERT;

// 全屏四边形顶点数据 (position.xy, texcoord.xy)
static const float QUAD_VERTICES[] = {
    -1.0f, -1.0f,  0.0f, 0.0f,
     1.0f, -1.0f,  1.0f, 0.0f,
    -1.0f,  1.0f,  0.0f, 1.0f,
     1.0f,  1.0f,  1.0f, 1.0f,
};


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

    // Release the context before the frame worker becomes eligible to claim it.
    g_api.eglMakeCurrent(eglDisplay_, MY_EGL_NO_SURFACE, MY_EGL_NO_SURFACE, MY_EGL_NO_CONTEXT);
    StartFrameWorker();

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

    OH_OnFrameAvailableListener listener = {};
    listener.context = this;
    listener.onFrameAvailable = &GLPostProcessor::OnFrameAvailable;
    {
        std::lock_guard<std::mutex> lock(frameCallbackMutex_);
        frameCallbacksEnabled_ = true;
    }
    if (g_api.nativeImageSetFrameListener(nativeImage_, listener) != 0) {
        std::lock_guard<std::mutex> lock(frameCallbackMutex_);
        frameCallbacksEnabled_ = false;
        OH_LOG_ERROR(LOG_APP, "OH_NativeImage_SetOnFrameAvailableListener failed");
        return false;
    }
    frameListenerRegistered_ = true;

    OH_LOG_INFO(LOG_APP, "NativeImage created: texture=%{public}u, proxyWindow=%{public}p",
                oesTexture_, static_cast<void*>(proxyWindow_));
    return true;
}

void GLPostProcessor::StartFrameWorker() {
    if (frameWorkerRunning_.exchange(true)) {
        return;
    }
    frameWorkerThread_ = std::thread(&GLPostProcessor::FrameWorkerLoop, this);
}

void GLPostProcessor::StopFrameWorker() {
    // Stop callbacks before joining the worker. Unregistering the listener
    // prevents new callbacks, while the in-flight counter is the lifetime
    // barrier for callbacks that were already executing.
    {
        std::lock_guard<std::mutex> lock(frameCallbackMutex_);
        frameCallbacksEnabled_ = false;
    }
    if (nativeImage_ && frameListenerRegistered_) {
        if (g_api.nativeImageUnsetFrameListener) {
            g_api.nativeImageUnsetFrameListener(nativeImage_);
        }
        frameListenerRegistered_ = false;
    }

    {
        std::unique_lock<std::mutex> lock(frameCallbackMutex_);
        frameCallbackCond_.wait(lock, [this] {
            return activeFrameCallbacks_ == 0;
        });
    }

    frameWorkerRunning_.store(false);
    frameWorkerCond_.notify_all();
    if (frameWorkerThread_.joinable()) {
        frameWorkerThread_.join();
    }
    std::lock_guard<std::mutex> lock(frameWorkerMutex_);
    framePending_ = false;
}

void GLPostProcessor::OnFrameAvailable(void* context) {
    auto* self = static_cast<GLPostProcessor*>(context);
    if (self == nullptr) {
        return;
    }

    bool shouldNotifyWorker = false;
    {
        std::lock_guard<std::mutex> lock(self->frameCallbackMutex_);
        self->activeFrameCallbacks_++;
        shouldNotifyWorker = self->frameCallbacksEnabled_;
    }

    if (shouldNotifyWorker && self->frameWorkerRunning_.load()) {
        {
            std::lock_guard<std::mutex> lock(self->frameWorkerMutex_);
            self->framePending_ = true;
        }
        self->frameWorkerCond_.notify_one();
    }

    {
        std::lock_guard<std::mutex> lock(self->frameCallbackMutex_);
        self->activeFrameCallbacks_--;
        if (self->activeFrameCallbacks_ == 0) {
            self->frameCallbackCond_.notify_all();
        }
    }
}

void GLPostProcessor::FrameWorkerLoop() {
    while (frameWorkerRunning_.load()) {
        {
            std::unique_lock<std::mutex> lock(frameWorkerMutex_);
            frameWorkerCond_.wait(lock, [this] {
                return framePending_ || !frameWorkerRunning_.load();
            });
            if (!frameWorkerRunning_.load()) {
                break;
            }
            framePending_ = false;
        }
        ProcessFrame();
    }

    if (eglDisplay_) {
        g_api.eglMakeCurrent(
            eglDisplay_, MY_EGL_NO_SURFACE, MY_EGL_NO_SURFACE, MY_EGL_NO_CONTEXT);
    }
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

void GLPostProcessor::FallbackFromXEngine() {
    // 运行时从 XEngine 降级：尝试初始化 FSR1，失败则关闭超分
    // 注意：只修改 activeUpscale_，不修改 upscaleMode_（保留用户意图，允许后续恢复）
    OH_LOG_WARN(LOG_APP, "FallbackFromXEngine: disabling XEngine, attempting FSR1 fallback");
    activeUpscale_ = UpscaleMode::OFF;
    xengineAvailable_ = false;
    xengineConsecutiveErrors_ = 0;

    // 清空 GL 错误队列（XEngine 残留错误可能污染 FSR1 初始化）
    while (g_api.glGetError() != 0) {}

    // 尝试初始化 FSR1（FBO 已存在，只需编译 FSR 着色器）
    // 临时修改 upscaleMode_ 以让 InitUpscale() 尝试 FSR1
    UpscaleMode savedMode = upscaleMode_;
    upscaleMode_ = UpscaleMode::FSR1;
    if (InitUpscale() && activeUpscale_ == UpscaleMode::FSR1) {
        OH_LOG_INFO(LOG_APP, "FallbackFromXEngine: FSR1 initialized successfully");
        // FSR1 成功，保持 upscaleMode_=FSR1 以示已降级
    } else {
        // FSR1 也失败，恢复原 upscaleMode_（保留用户意图）并关闭活动超分
        OH_LOG_WARN(LOG_APP, "FallbackFromXEngine: FSR1 init failed, upscale fully disabled");
        upscaleMode_ = savedMode;
        activeUpscale_ = UpscaleMode::OFF;
    }
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

        // 周期检查 GL 错误（避免每帧 GPU 同步开销），连续错误达到阈值时熔断降级
        // 每 30 帧采样一次
        if (frameCount_ % 30 == 0) {
            unsigned int err = g_api.glGetError();
            if (err != 0) {
                xengineConsecutiveErrors_++;
                OH_LOG_WARN(LOG_APP, "XEngine sampled glErr=0x%{public}x (consecutive=%{public}u/%{public}u) at frame %{public}u",
                            err, xengineConsecutiveErrors_, kXEngineErrorThreshold, frameCount_);
                if (xengineConsecutiveErrors_ >= kXEngineErrorThreshold) {
                    OH_LOG_ERROR(LOG_APP, "XEngine consecutive errors reached threshold, falling back");
                    FallbackFromXEngine();
                    // 本帧已损坏，若降级到 FSR1 则下一帧生效；
                    // 若完全关闭超分，用 OES 直通输出避免黑屏
                    if (activeUpscale_ == UpscaleMode::OFF) {
                        g_api.glBindFramebuffer(MY_GL_FRAMEBUFFER, 0);
                        DrawFullscreenQuad();
                    }
                    return;
                }
            } else {
                // 成功采样（无错误），重置计数
                xengineConsecutiveErrors_ = 0;
            }
        }

        if (frameCount_ < 3) {
            OH_LOG_INFO(LOG_APP, "XEngine frame %{public}u: tex=%{public}u input=%{public}ux%{public}u "
                        "output=%{public}ux%{public}u render=%{public}ux%{public}u+%{public}u+%{public}u",
                        frameCount_, fboTexture_, inputWidth_, inputHeight_,
                        outputWidth_, outputHeight_, renderWidth_, renderHeight_,
                        renderX_, renderY_);
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
    unsigned int swapOk = g_api.eglSwapBuffers(eglDisplay_, eglSurface_);
    if (!swapOk) {
        swapConsecutiveFailures_++;
        // 宽限期内降低日志级别，减少启动阶段噪音
        if (frameCount_ < kSwapGracePeriodFrames) {
            OH_LOG_DEBUG(LOG_APP, "eglSwapBuffers failed during grace period (consecutive=%{public}u, frame=%{public}u)",
                        swapConsecutiveFailures_, frameCount_);
        } else {
            OH_LOG_WARN(LOG_APP, "eglSwapBuffers failed (consecutive=%{public}u/%{public}u, frame=%{public}u)",
                        swapConsecutiveFailures_, kSwapFailureThreshold, frameCount_);
        }
        if (frameCount_ >= kSwapGracePeriodFrames &&
            swapConsecutiveFailures_ >= kSwapFailureThreshold) {
            if (activeUpscale_ != UpscaleMode::OFF) {
                // 关闭活动超分以降低管线复杂度，保留 FBO 管线（不释放，方便恢复）
                OH_LOG_ERROR(LOG_APP, "eglSwapBuffers consecutive failures after grace period, disabling active upscale");
                activeUpscale_ = UpscaleMode::OFF;
            }
            // 无论是否有超分，达到阈值后重置计数，避免无限累加产生日志噪音
            swapConsecutiveFailures_ = 0;
        }
    } else {
        swapConsecutiveFailures_ = 0;
    }

    frameCount_++;
}

void GLPostProcessor::DrawFullscreenQuad() {
    g_api.glViewport(0, 0, outputWidth_, outputHeight_);

    g_api.glUseProgram(shaderProgram_);

    // 绑定 OES 纹理到 unit 0
    g_api.glActiveTexture(MY_GL_TEXTURE0);
    g_api.glBindTexture(MY_GL_TEXTURE_EXTERNAL_OES, oesTexture_);
    g_api.glUniform1i(locTexture_, 0);

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
    StopFrameWorker();
    std::lock_guard<std::mutex> lock(processMutex_);
    ReleaseInternal();
}

void GLPostProcessor::ReleaseInternal() {
    StopFrameWorker();
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
    if (shaderProgram_) { g_api.glDeleteProgram(shaderProgram_); shaderProgram_ = 0; }
}

void GLPostProcessor::ReleaseNativeImage() {
    if (nativeImage_) {
        if (frameListenerRegistered_ && g_api.nativeImageUnsetFrameListener) {
            g_api.nativeImageUnsetFrameListener(nativeImage_);
        }
        frameListenerRegistered_ = false;
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
