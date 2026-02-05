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
 * @file callbacks.cpp
 * @brief moonlight-common-c 回调处理实现
 * 
 * 实现从 C 库回调到 ArkTS 的机制
 * 参照 Android 的 callbacks.c 实现
 */

#include "callbacks.h"
#include "opus_avcodec.h"
#include "video_decoder.h"
#include "audio_renderer.h"
#include <hilog/log.h>
#include <cstring>
#include <cstdarg>
#include <mutex>

extern "C" {
#include "moonlight-common-c/src/Limelight.h"
}

#define LOG_TAG "MoonlightCallbacks"

// =============================================================================
// 全局变量
// =============================================================================

static napi_env g_env = nullptr;
static std::mutex g_mutex;

// 回调实例
VideoDecoderCallbacks g_videoCallbacks = {0};
AudioRendererCallbacks g_audioCallbacks = {0};
ConnectionListenerCallbacks g_connCallbacks = {0};

// Opus 配置
static OPUS_MULTISTREAM_CONFIGURATION g_opusConfig;
static short* g_decodedAudioBuffer = nullptr;

// =============================================================================
// 辅助函数
// =============================================================================

/**
 * 创建线程安全函数
 */
static napi_status CreateThreadsafeFunction(
    napi_env env,
    napi_value callback,
    const char* name,
    napi_threadsafe_function_call_js call_js,
    napi_threadsafe_function* result
) {
    napi_value resourceName;
    napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resourceName);
    
    return napi_create_threadsafe_function(
        env,
        callback,
        nullptr,
        resourceName,
        0,  // max_queue_size (0 = unlimited)
        1,  // initial_thread_count
        nullptr,
        nullptr,
        nullptr,
        call_js,
        result
    );
}

// =============================================================================
// 回调 JS 调用函数
// =============================================================================

// 通用参数传递结构
typedef struct {
    int intParams[4];
    double doubleParams[2];
    void* ptrParam;
    int ptrSize;
} CallbackData;

static void CallJs_StageStarting(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[1];
        napi_create_int32(env, cbData->intParams[0], &argv[0]);
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 1, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_StageComplete(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[1];
        napi_create_int32(env, cbData->intParams[0], &argv[0]);
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 1, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_StageFailed(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[2];
        napi_create_int32(env, cbData->intParams[0], &argv[0]);
        napi_create_int32(env, cbData->intParams[1], &argv[1]);
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 2, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_ConnectionStarted(napi_env env, napi_value js_callback, void* context, void* data) {
    if (env != nullptr && js_callback != nullptr) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 0, nullptr, nullptr);
    }
}

static void CallJs_ConnectionTerminated(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[1];
        napi_create_int32(env, cbData->intParams[0], &argv[0]);
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 1, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_Rumble(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[3];
        napi_create_int32(env, cbData->intParams[0], &argv[0]);
        napi_create_int32(env, cbData->intParams[1], &argv[1]);
        napi_create_int32(env, cbData->intParams[2], &argv[2]);
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 3, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_ConnectionStatusUpdate(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[1];
        napi_create_int32(env, cbData->intParams[0], &argv[0]);
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 1, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_SetHdrMode(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[1];
        napi_get_boolean(env, cbData->intParams[0] != 0, &argv[0]);
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 1, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_ResolutionChanged(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[2];
        napi_create_uint32(env, cbData->intParams[0], &argv[0]);
        napi_create_uint32(env, cbData->intParams[1], &argv[1]);
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 2, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_DrSetup(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[4];
        napi_create_int32(env, cbData->intParams[0], &argv[0]); // videoFormat
        napi_create_int32(env, cbData->intParams[1], &argv[1]); // width
        napi_create_int32(env, cbData->intParams[2], &argv[2]); // height
        napi_create_int32(env, cbData->intParams[3], &argv[3]); // redrawRate
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 4, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_DrSubmitDecodeUnit(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr && cbData->ptrParam != nullptr) {
        napi_value argv[3];
        
        // 创建 ArrayBuffer
        void* bufferData;
        napi_create_arraybuffer(env, cbData->ptrSize, &bufferData, &argv[0]);
        memcpy(bufferData, cbData->ptrParam, cbData->ptrSize);
        
        napi_create_int32(env, cbData->intParams[0], &argv[1]); // frameNumber
        napi_create_int32(env, cbData->intParams[1], &argv[2]); // frameType
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 3, argv, nullptr);
        
        free(cbData->ptrParam);
    }
    delete cbData;
}

static void CallJs_ArInit(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[3];
        napi_create_int32(env, cbData->intParams[0], &argv[0]); // audioConfiguration
        napi_create_int32(env, cbData->intParams[1], &argv[1]); // sampleRate
        napi_create_int32(env, cbData->intParams[2], &argv[2]); // samplesPerFrame
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 3, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_ArPlaySample(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr && cbData->ptrParam != nullptr) {
        napi_value argv[1];
        
        // 创建 Int16Array
        void* bufferData;
        napi_value arrayBuffer;
        napi_create_arraybuffer(env, cbData->ptrSize, &bufferData, &arrayBuffer);
        memcpy(bufferData, cbData->ptrParam, cbData->ptrSize);
        
        napi_create_typedarray(env, napi_int16_array, cbData->ptrSize / 2, arrayBuffer, 0, &argv[0]);
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 1, argv, nullptr);
        
        free(cbData->ptrParam);
    }
    delete cbData;
}

static void CallJs_Void(napi_env env, napi_value js_callback, void* context, void* data) {
    if (env != nullptr && js_callback != nullptr) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 0, nullptr, nullptr);
    }
}

// =============================================================================
// 回调初始化
// =============================================================================

void Callbacks_Init(napi_env env, napi_value callbacks) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_env = env;
    
    napi_value callback;
    
    // 视频解码器回调
    if (napi_get_named_property(env, callbacks, "drSetup", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "drSetup", CallJs_DrSetup, &g_videoCallbacks.tsfn_setup);
    }
    if (napi_get_named_property(env, callbacks, "drStart", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "drStart", CallJs_Void, &g_videoCallbacks.tsfn_start);
    }
    if (napi_get_named_property(env, callbacks, "drStop", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "drStop", CallJs_Void, &g_videoCallbacks.tsfn_stop);
    }
    if (napi_get_named_property(env, callbacks, "drCleanup", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "drCleanup", CallJs_Void, &g_videoCallbacks.tsfn_cleanup);
    }
    if (napi_get_named_property(env, callbacks, "drSubmitDecodeUnit", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "drSubmitDecodeUnit", CallJs_DrSubmitDecodeUnit, &g_videoCallbacks.tsfn_submitDecodeUnit);
    }
    
    // 音频渲染器回调
    if (napi_get_named_property(env, callbacks, "arInit", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "arInit", CallJs_ArInit, &g_audioCallbacks.tsfn_init);
    }
    if (napi_get_named_property(env, callbacks, "arStart", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "arStart", CallJs_Void, &g_audioCallbacks.tsfn_start);
    }
    if (napi_get_named_property(env, callbacks, "arStop", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "arStop", CallJs_Void, &g_audioCallbacks.tsfn_stop);
    }
    if (napi_get_named_property(env, callbacks, "arCleanup", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "arCleanup", CallJs_Void, &g_audioCallbacks.tsfn_cleanup);
    }
    if (napi_get_named_property(env, callbacks, "arPlaySample", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "arPlaySample", CallJs_ArPlaySample, &g_audioCallbacks.tsfn_playSample);
    }
    
    // 连接监听器回调
    if (napi_get_named_property(env, callbacks, "stageStarting", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "stageStarting", CallJs_StageStarting, &g_connCallbacks.tsfn_stageStarting);
    }
    if (napi_get_named_property(env, callbacks, "stageComplete", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "stageComplete", CallJs_StageComplete, &g_connCallbacks.tsfn_stageComplete);
    }
    if (napi_get_named_property(env, callbacks, "stageFailed", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "stageFailed", CallJs_StageFailed, &g_connCallbacks.tsfn_stageFailed);
    }
    if (napi_get_named_property(env, callbacks, "connectionStarted", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "connectionStarted", CallJs_ConnectionStarted, &g_connCallbacks.tsfn_connectionStarted);
    }
    if (napi_get_named_property(env, callbacks, "connectionTerminated", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "connectionTerminated", CallJs_ConnectionTerminated, &g_connCallbacks.tsfn_connectionTerminated);
    }
    if (napi_get_named_property(env, callbacks, "rumble", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "rumble", CallJs_Rumble, &g_connCallbacks.tsfn_rumble);
    }
    if (napi_get_named_property(env, callbacks, "connectionStatusUpdate", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "connectionStatusUpdate", CallJs_ConnectionStatusUpdate, &g_connCallbacks.tsfn_connectionStatusUpdate);
    }
    if (napi_get_named_property(env, callbacks, "setHdrMode", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "setHdrMode", CallJs_SetHdrMode, &g_connCallbacks.tsfn_setHdrMode);
    }
    if (napi_get_named_property(env, callbacks, "resolutionChanged", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "resolutionChanged", CallJs_ResolutionChanged, &g_connCallbacks.tsfn_resolutionChanged);
    }
    
    OH_LOG_INFO(LOG_APP, "Callbacks initialized");
}

void Callbacks_Cleanup(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    
    // 释放线程安全函数
    if (g_videoCallbacks.tsfn_setup) napi_release_threadsafe_function(g_videoCallbacks.tsfn_setup, napi_tsfn_release);
    if (g_videoCallbacks.tsfn_start) napi_release_threadsafe_function(g_videoCallbacks.tsfn_start, napi_tsfn_release);
    if (g_videoCallbacks.tsfn_stop) napi_release_threadsafe_function(g_videoCallbacks.tsfn_stop, napi_tsfn_release);
    if (g_videoCallbacks.tsfn_cleanup) napi_release_threadsafe_function(g_videoCallbacks.tsfn_cleanup, napi_tsfn_release);
    if (g_videoCallbacks.tsfn_submitDecodeUnit) napi_release_threadsafe_function(g_videoCallbacks.tsfn_submitDecodeUnit, napi_tsfn_release);
    
    if (g_audioCallbacks.tsfn_init) napi_release_threadsafe_function(g_audioCallbacks.tsfn_init, napi_tsfn_release);
    if (g_audioCallbacks.tsfn_start) napi_release_threadsafe_function(g_audioCallbacks.tsfn_start, napi_tsfn_release);
    if (g_audioCallbacks.tsfn_stop) napi_release_threadsafe_function(g_audioCallbacks.tsfn_stop, napi_tsfn_release);
    if (g_audioCallbacks.tsfn_cleanup) napi_release_threadsafe_function(g_audioCallbacks.tsfn_cleanup, napi_tsfn_release);
    if (g_audioCallbacks.tsfn_playSample) napi_release_threadsafe_function(g_audioCallbacks.tsfn_playSample, napi_tsfn_release);
    
    if (g_connCallbacks.tsfn_stageStarting) napi_release_threadsafe_function(g_connCallbacks.tsfn_stageStarting, napi_tsfn_release);
    if (g_connCallbacks.tsfn_stageComplete) napi_release_threadsafe_function(g_connCallbacks.tsfn_stageComplete, napi_tsfn_release);
    if (g_connCallbacks.tsfn_stageFailed) napi_release_threadsafe_function(g_connCallbacks.tsfn_stageFailed, napi_tsfn_release);
    if (g_connCallbacks.tsfn_connectionStarted) napi_release_threadsafe_function(g_connCallbacks.tsfn_connectionStarted, napi_tsfn_release);
    if (g_connCallbacks.tsfn_connectionTerminated) napi_release_threadsafe_function(g_connCallbacks.tsfn_connectionTerminated, napi_tsfn_release);
    if (g_connCallbacks.tsfn_rumble) napi_release_threadsafe_function(g_connCallbacks.tsfn_rumble, napi_tsfn_release);
    if (g_connCallbacks.tsfn_connectionStatusUpdate) napi_release_threadsafe_function(g_connCallbacks.tsfn_connectionStatusUpdate, napi_tsfn_release);
    if (g_connCallbacks.tsfn_setHdrMode) napi_release_threadsafe_function(g_connCallbacks.tsfn_setHdrMode, napi_tsfn_release);
    if (g_connCallbacks.tsfn_resolutionChanged) napi_release_threadsafe_function(g_connCallbacks.tsfn_resolutionChanged, napi_tsfn_release);
    
    memset(&g_videoCallbacks, 0, sizeof(g_videoCallbacks));
    memset(&g_audioCallbacks, 0, sizeof(g_audioCallbacks));
    memset(&g_connCallbacks, 0, sizeof(g_connCallbacks));
    
    // 清理 AVCodec Opus 解码器
    OpusDecoder::Cleanup();
    
    if (g_decodedAudioBuffer) {
        free(g_decodedAudioBuffer);
        g_decodedAudioBuffer = nullptr;
    }
    
    g_env = nullptr;
    
    OH_LOG_INFO(LOG_APP, "Callbacks cleaned up");
}

// =============================================================================
// moonlight-common-c 回调桥接实现
// =============================================================================

// 视频解码器配置参数（保存用于创建解码器）
static int g_videoFormat = 0;
static int g_videoWidth = 0;
static int g_videoHeight = 0;
static int g_videoFps = 0;

// 视频解码器回调
int BridgeDrSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags) {
    OH_LOG_INFO(LOG_APP, "BridgeDrSetup: format=0x%{public}x, %{public}dx%{public}d@%{public}d, drFlags=0x%{public}x", 
                videoFormat, width, height, redrawRate, drFlags);
    
    // 先清理之前的解码器资源（如果有的话）
    VideoDecoderInstance::Cleanup();
    
    // 保存视频参数
    g_videoFormat = videoFormat;
    g_videoWidth = width;
    g_videoHeight = height;
    g_videoFps = redrawRate;
    
    // 初始化视频解码器（如果 Surface 已设置，会立即创建解码器）
    int ret = VideoDecoderInstance::Setup(videoFormat, width, height, redrawRate);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "VideoDecoderInstance::Setup failed: %{public}d", ret);
    }
    
    // 通知 ArkTS 层设置视频参数
    if (g_videoCallbacks.tsfn_setup) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = videoFormat;
        data->intParams[1] = width;
        data->intParams[2] = height;
        data->intParams[3] = redrawRate;
        napi_call_threadsafe_function(g_videoCallbacks.tsfn_setup, data, napi_tsfn_blocking);
    }
    
    OH_LOG_INFO(LOG_APP, "BridgeDrSetup completed with ret=%{public}d", ret);
    return ret;
}

void BridgeDrStart(void) {
    OH_LOG_INFO(LOG_APP, "BridgeDrStart: starting video decoder...");
    
    // 启动视频解码器（此时才真正创建解码器）
    int ret = VideoDecoderInstance::Start();
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "VideoDecoderInstance::Start failed: %{public}d", ret);
        // BridgeDrStart 返回类型是 void，无法返回错误
        // 但解码器会在 SubmitDecodeUnit 时失败
    } else {
        OH_LOG_INFO(LOG_APP, "BridgeDrStart: video decoder started successfully");
    }
    
    if (g_videoCallbacks.tsfn_start) {
        napi_call_threadsafe_function(g_videoCallbacks.tsfn_start, nullptr, napi_tsfn_blocking);
    }
    
    OH_LOG_INFO(LOG_APP, "BridgeDrStart: completed");
}

void BridgeDrStop(void) {
    OH_LOG_INFO(LOG_APP, "BridgeDrStop");
    
    // 停止视频解码器
    VideoDecoderInstance::Stop();
    
    if (g_videoCallbacks.tsfn_stop) {
        napi_call_threadsafe_function(g_videoCallbacks.tsfn_stop, nullptr, napi_tsfn_blocking);
    }
}

void BridgeDrCleanup(void) {
    OH_LOG_INFO(LOG_APP, "BridgeDrCleanup");
    
    // 清理视频解码器
    VideoDecoderInstance::Cleanup();
    
    if (g_videoCallbacks.tsfn_cleanup) {
        napi_call_threadsafe_function(g_videoCallbacks.tsfn_cleanup, nullptr, napi_tsfn_blocking);
    }
}

int BridgeDrSubmitDecodeUnit(void* decodeUnitPtr) {
    PDECODE_UNIT decodeUnit = (PDECODE_UNIT)decodeUnitPtr;
    
    // 计算总大小
    int totalSize = 0;
    PLENTRY entry = decodeUnit->bufferList;
    while (entry != nullptr) {
        totalSize += entry->length;
        entry = entry->next;
    }
    
    // 复制数据
    uint8_t* buffer = (uint8_t*)malloc(totalSize);
    int offset = 0;
    entry = decodeUnit->bufferList;
    while (entry != nullptr) {
        memcpy(buffer + offset, entry->data, entry->length);
        offset += entry->length;
        entry = entry->next;
    }
    
    // 提交到硬件解码器（传递主机处理延迟）
    int result = VideoDecoderInstance::SubmitDecodeUnit(
        buffer, 
        totalSize, 
        decodeUnit->frameNumber, 
        decodeUnit->frameType,
        decodeUnit->frameHostProcessingLatency
    );
    
    free(buffer);
    
    // 同时通知 ArkTS 层（可选，用于统计等）
    if (g_videoCallbacks.tsfn_submitDecodeUnit) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = decodeUnit->frameNumber;
        data->intParams[1] = decodeUnit->frameType;
        data->intParams[2] = totalSize;
        data->ptrParam = nullptr;  // 不传递数据，已经在本地解码
        data->ptrSize = 0;
        napi_call_threadsafe_function(g_videoCallbacks.tsfn_submitDecodeUnit, data, napi_tsfn_nonblocking);
    }
    
    return result == 0 ? DR_OK : DR_NEED_IDR;
}

// 音频渲染器回调
int BridgeArInit(int audioConfiguration, void* opusConfigPtr, void* context, int flags) {
    POPUS_MULTISTREAM_CONFIGURATION opusConfig = (POPUS_MULTISTREAM_CONFIGURATION)opusConfigPtr;
    OH_LOG_INFO(LOG_APP, "BridgeArInit: config=%{public}d, sampleRate=%{public}d, channels=%{public}d", 
                audioConfiguration, opusConfig->sampleRate, opusConfig->channelCount);
    
    // 保存配置
    memcpy(&g_opusConfig, opusConfig, sizeof(g_opusConfig));
    
    // 使用 HarmonyOS AVCodec Opus 解码器
    int err = OpusDecoder::Init(opusConfig);
    if (err != 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to create AVCodec Opus decoder: %{public}d", err);
        return -1;
    }
    
    // 分配解码缓冲区
    g_decodedAudioBuffer = (short*)malloc(opusConfig->channelCount * opusConfig->samplesPerFrame * sizeof(short));
    
    // 初始化音频播放器
    err = AudioRendererInstance::Init(opusConfig->sampleRate, opusConfig->channelCount, opusConfig->samplesPerFrame);
    if (err != 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to init audio renderer: %{public}d", err);
        // 继续执行，让 ArkTS 层处理音频
    }
    
    if (g_audioCallbacks.tsfn_init) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = audioConfiguration;
        data->intParams[1] = opusConfig->sampleRate;
        data->intParams[2] = opusConfig->samplesPerFrame;
        napi_call_threadsafe_function(g_audioCallbacks.tsfn_init, data, napi_tsfn_blocking);
    }
    
    return 0;
}

void BridgeArStart(void) {
    OH_LOG_INFO(LOG_APP, "BridgeArStart");
    
    // 启动音频播放器
    AudioRendererInstance::Start();
    
    if (g_audioCallbacks.tsfn_start) {
        napi_call_threadsafe_function(g_audioCallbacks.tsfn_start, nullptr, napi_tsfn_blocking);
    }
}

void BridgeArStop(void) {
    OH_LOG_INFO(LOG_APP, "BridgeArStop");
    
    // 停止音频播放器
    AudioRendererInstance::Stop();
    
    if (g_audioCallbacks.tsfn_stop) {
        napi_call_threadsafe_function(g_audioCallbacks.tsfn_stop, nullptr, napi_tsfn_blocking);
    }
}

void BridgeArCleanup(void) {
    OH_LOG_INFO(LOG_APP, "BridgeArCleanup");
    
    // 清理音频播放器
    AudioRendererInstance::Cleanup();
    
    // 清理 AVCodec Opus 解码器
    OpusDecoder::Cleanup();
    
    if (g_decodedAudioBuffer) {
        free(g_decodedAudioBuffer);
        g_decodedAudioBuffer = nullptr;
    }
    
    if (g_audioCallbacks.tsfn_cleanup) {
        napi_call_threadsafe_function(g_audioCallbacks.tsfn_cleanup, nullptr, napi_tsfn_blocking);
    }
}

void BridgeArDecodeAndPlaySample(char* sampleData, int sampleLength) {
    if (g_decodedAudioBuffer == nullptr) {
        return;
    }
    
    // 使用 HarmonyOS AVCodec Opus 解码器
    int decodeLen = OpusDecoder::Decode(
        (const unsigned char*)sampleData,
        sampleLength,
        g_decodedAudioBuffer,
        g_opusConfig.samplesPerFrame
    );
    
    if (decodeLen > 0) {
        // 直接播放到音频播放器
        AudioRendererInstance::PlaySamples(g_decodedAudioBuffer, decodeLen);
    }
}

// 连接监听器回调
void BridgeClStageStarting(int stage) {
    OH_LOG_INFO(LOG_APP, "Stage starting: %{public}d", stage);
    if (g_connCallbacks.tsfn_stageStarting) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = stage;
        napi_call_threadsafe_function(g_connCallbacks.tsfn_stageStarting, data, napi_tsfn_blocking);
    }
}

void BridgeClStageComplete(int stage) {
    OH_LOG_INFO(LOG_APP, "Stage complete: %{public}d", stage);
    if (g_connCallbacks.tsfn_stageComplete) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = stage;
        napi_call_threadsafe_function(g_connCallbacks.tsfn_stageComplete, data, napi_tsfn_blocking);
    }
}

void BridgeClStageFailed(int stage, int errorCode) {
    OH_LOG_ERROR(LOG_APP, "Stage failed: %{public}d, error: %{public}d", stage, errorCode);
    if (g_connCallbacks.tsfn_stageFailed) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = stage;
        data->intParams[1] = errorCode;
        napi_call_threadsafe_function(g_connCallbacks.tsfn_stageFailed, data, napi_tsfn_blocking);
    }
}

void BridgeClConnectionStarted(void) {
    OH_LOG_INFO(LOG_APP, "Connection started");
    if (g_connCallbacks.tsfn_connectionStarted) {
        napi_call_threadsafe_function(g_connCallbacks.tsfn_connectionStarted, nullptr, napi_tsfn_blocking);
    }
}

void BridgeClConnectionTerminated(int errorCode) {
    OH_LOG_INFO(LOG_APP, "Connection terminated: %{public}d", errorCode);
    if (g_connCallbacks.tsfn_connectionTerminated) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = errorCode;
        napi_call_threadsafe_function(g_connCallbacks.tsfn_connectionTerminated, data, napi_tsfn_blocking);
    }
}

void BridgeClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor) {
    if (g_connCallbacks.tsfn_rumble) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = controllerNumber;
        data->intParams[1] = lowFreqMotor;
        data->intParams[2] = highFreqMotor;
        napi_call_threadsafe_function(g_connCallbacks.tsfn_rumble, data, napi_tsfn_nonblocking);
    }
}

void BridgeClConnectionStatusUpdate(int connectionStatus) {
    OH_LOG_INFO(LOG_APP, "Connection status: %{public}d", connectionStatus);
    if (g_connCallbacks.tsfn_connectionStatusUpdate) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = connectionStatus;
        napi_call_threadsafe_function(g_connCallbacks.tsfn_connectionStatusUpdate, data, napi_tsfn_nonblocking);
    }
}

void BridgeClSetHdrMode(int enabled, void* hdrMetadata) {
    OH_LOG_INFO(LOG_APP, "Set HDR mode: %{public}d, metadata=%{public}p", enabled, hdrMetadata);
    
    // 如果有 HDR 元数据，可以在这里处理
    // hdrMetadata 包含 HDR10 静态元数据（如果有的话）
    if (enabled && hdrMetadata != nullptr) {
        // HDR 元数据格式（来自 moonlight-common-c）:
        // 24 字节的 SS_HDR_METADATA 结构体
        // 包含显示主颜色坐标、白点、亮度等信息
        uint8_t* metadata = static_cast<uint8_t*>(hdrMetadata);
        OH_LOG_INFO(LOG_APP, "HDR metadata received: first 4 bytes = %02x %02x %02x %02x",
                    metadata[0], metadata[1], metadata[2], metadata[3]);
    }
    
    // 通知 ArkTS 层 HDR 状态变化
    if (g_connCallbacks.tsfn_setHdrMode) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = enabled;
        napi_call_threadsafe_function(g_connCallbacks.tsfn_setHdrMode, data, napi_tsfn_nonblocking);
    }
}

void BridgeClRumbleTriggers(unsigned short controllerNumber, unsigned short leftTrigger, unsigned short rightTrigger) {
    // TODO: 实现触发器震动
}

void BridgeClSetMotionEventState(unsigned short controllerNumber, unsigned char motionType, unsigned short reportRateHz) {
    // TODO: 实现动作感应状态
}

void BridgeClSetControllerLED(unsigned short controllerNumber, unsigned char r, unsigned char g, unsigned char b) {
    // TODO: 实现手柄 LED 控制
}

void BridgeClResolutionChanged(unsigned int width, unsigned int height) {
    OH_LOG_INFO(LOG_APP, "Resolution changed: %ux%u", width, height);
    if (g_connCallbacks.tsfn_resolutionChanged) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = width;
        data->intParams[1] = height;
        napi_call_threadsafe_function(g_connCallbacks.tsfn_resolutionChanged, data, napi_tsfn_blocking);
    }
}

void BridgeClLogMessage(const char* format, ...) {
    va_list args;
    va_start(args, format);
    char buffer[1024];
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    
    OH_LOG_INFO(LOG_APP, "[Moonlight] %{public}s", buffer);
}
