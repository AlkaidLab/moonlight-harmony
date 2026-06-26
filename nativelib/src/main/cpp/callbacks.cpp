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
#include "opus_libopus.h"
#include "video_decoder.h"
#include "audio_renderer.h"
#include "bass_energy_analyzer.h"
#include "moonlight_bridge.h"
#include <hilog/log.h>
#include <cstring>

// 外部函数：更新 mic 编码器丢包率（定义在 moonlight_bridge.cpp）
extern void MicCapturerUpdatePacketLossPercent(int percent);
#include <cstdarg>
#include <cstdint>
#include <mutex>
#include <qos/qos.h>
#include <sched.h>
#include <unistd.h>
#include <fstream>
#include <vector>

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

// 低频能量分析器（extern 供 moonlight_bridge.cpp 访问）
BassEnergyAnalyzer g_bassAnalyzer;

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

static bool ConvertSunshineHdrMetadata(const SS_HDR_METADATA* source, Smpte2086Metadata* target) {
    if (source == nullptr || target == nullptr) {
        return false;
    }

    constexpr float kChromaticityScale = 50000.0f;
    constexpr float kMinLuminanceScale = 10000.0f;

    if (source->maxDisplayLuminance == 0 ||
        source->displayPrimaries[0].x == 0 || source->displayPrimaries[0].y == 0 ||
        source->displayPrimaries[1].x == 0 || source->displayPrimaries[1].y == 0 ||
        source->displayPrimaries[2].x == 0 || source->displayPrimaries[2].y == 0 ||
        source->whitePoint.x == 0 || source->whitePoint.y == 0) {
        return false;
    }

    target->redX = static_cast<float>(source->displayPrimaries[0].x) / kChromaticityScale;
    target->redY = static_cast<float>(source->displayPrimaries[0].y) / kChromaticityScale;
    target->greenX = static_cast<float>(source->displayPrimaries[1].x) / kChromaticityScale;
    target->greenY = static_cast<float>(source->displayPrimaries[1].y) / kChromaticityScale;
    target->blueX = static_cast<float>(source->displayPrimaries[2].x) / kChromaticityScale;
    target->blueY = static_cast<float>(source->displayPrimaries[2].y) / kChromaticityScale;
    target->whiteX = static_cast<float>(source->whitePoint.x) / kChromaticityScale;
    target->whiteY = static_cast<float>(source->whitePoint.y) / kChromaticityScale;
    target->maxLuminance = static_cast<float>(source->maxDisplayLuminance);
    target->minLuminance = static_cast<float>(source->minDisplayLuminance) / kMinLuminanceScale;
    target->maxContentLightLevel = static_cast<float>(source->maxContentLightLevel);
    target->maxFrameAverageLightLevel = static_cast<float>(source->maxFrameAverageLightLevel);
    return true;
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

static void CallJs_SetMotionEventState(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[3];
        napi_create_int32(env, cbData->intParams[0], &argv[0]); // controllerNumber
        napi_create_int32(env, cbData->intParams[1], &argv[1]); // motionType
        napi_create_int32(env, cbData->intParams[2], &argv[2]); // reportRateHz
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 3, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_SetControllerLED(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[4];
        napi_create_int32(env, cbData->intParams[0], &argv[0]); // controllerNumber
        napi_create_int32(env, cbData->intParams[1], &argv[1]); // r
        napi_create_int32(env, cbData->intParams[2], &argv[2]); // g
        napi_create_int32(env, cbData->intParams[3], &argv[3]); // b
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 4, argv, nullptr);
    }
    delete cbData;
}

static void CallJs_RumbleTriggers(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[3];
        napi_create_int32(env, cbData->intParams[0], &argv[0]); // controllerNumber
        napi_create_int32(env, cbData->intParams[1], &argv[1]); // leftTrigger
        napi_create_int32(env, cbData->intParams[2], &argv[2]); // rightTrigger
        
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 3, argv, nullptr);
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

static void CallJs_ClipboardData(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[3];
        napi_create_int32(env, cbData->intParams[0], &argv[0]);
        napi_create_double(env, cbData->doubleParams[0], &argv[1]);

        void* bufferData = nullptr;
        napi_value arrayBuffer;
        napi_create_arraybuffer(env, cbData->ptrSize, &bufferData, &arrayBuffer);
        if (cbData->ptrSize > 0 && cbData->ptrParam != nullptr) {
            memcpy(bufferData, cbData->ptrParam, cbData->ptrSize);
        }
        napi_create_typedarray(env, napi_uint8_array, cbData->ptrSize, arrayBuffer, 0, &argv[2]);

        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 3, argv, nullptr);
    }

    if (cbData != nullptr && cbData->ptrParam != nullptr) {
        free(cbData->ptrParam);
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

static void CallJs_BassEnergy(napi_env env, napi_value js_callback, void* context, void* data) {
    CallbackData* cbData = (CallbackData*)data;
    if (env != nullptr && js_callback != nullptr) {
        napi_value argv[3];
        napi_create_int32(env, cbData->intParams[0], &argv[0]); // intensity (0-100)
        napi_create_int32(env, cbData->intParams[1], &argv[1]); // lowFreqRatio (0-100)
        napi_create_int32(env, cbData->intParams[2], &argv[2]); // stereoBalance (0-100)

        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, js_callback, 3, argv, nullptr);
    }
    delete cbData;
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
    if (napi_get_named_property(env, callbacks, "bassEnergy", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "bassEnergy", CallJs_BassEnergy, &g_audioCallbacks.tsfn_bassEnergy);
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
    if (napi_get_named_property(env, callbacks, "setMotionEventState", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "setMotionEventState", CallJs_SetMotionEventState, &g_connCallbacks.tsfn_setMotionEventState);
    }
    if (napi_get_named_property(env, callbacks, "setControllerLED", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "setControllerLED", CallJs_SetControllerLED, &g_connCallbacks.tsfn_setControllerLED);
    }
    if (napi_get_named_property(env, callbacks, "rumbleTriggers", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "rumbleTriggers", CallJs_RumbleTriggers, &g_connCallbacks.tsfn_rumbleTriggers);
    }
    if (napi_get_named_property(env, callbacks, "resolutionChanged", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "resolutionChanged", CallJs_ResolutionChanged, &g_connCallbacks.tsfn_resolutionChanged);
    }
    if (napi_get_named_property(env, callbacks, "clipboardData", &callback) == napi_ok) {
        CreateThreadsafeFunction(env, callback, "clipboardData", CallJs_ClipboardData, &g_connCallbacks.tsfn_clipboardData);
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
    if (g_audioCallbacks.tsfn_bassEnergy) napi_release_threadsafe_function(g_audioCallbacks.tsfn_bassEnergy, napi_tsfn_release);
    
    if (g_connCallbacks.tsfn_stageStarting) napi_release_threadsafe_function(g_connCallbacks.tsfn_stageStarting, napi_tsfn_release);
    if (g_connCallbacks.tsfn_stageComplete) napi_release_threadsafe_function(g_connCallbacks.tsfn_stageComplete, napi_tsfn_release);
    if (g_connCallbacks.tsfn_stageFailed) napi_release_threadsafe_function(g_connCallbacks.tsfn_stageFailed, napi_tsfn_release);
    if (g_connCallbacks.tsfn_connectionStarted) napi_release_threadsafe_function(g_connCallbacks.tsfn_connectionStarted, napi_tsfn_release);
    if (g_connCallbacks.tsfn_connectionTerminated) napi_release_threadsafe_function(g_connCallbacks.tsfn_connectionTerminated, napi_tsfn_release);
    if (g_connCallbacks.tsfn_rumble) napi_release_threadsafe_function(g_connCallbacks.tsfn_rumble, napi_tsfn_release);
    if (g_connCallbacks.tsfn_connectionStatusUpdate) napi_release_threadsafe_function(g_connCallbacks.tsfn_connectionStatusUpdate, napi_tsfn_release);
    if (g_connCallbacks.tsfn_setHdrMode) napi_release_threadsafe_function(g_connCallbacks.tsfn_setHdrMode, napi_tsfn_release);
    if (g_connCallbacks.tsfn_setMotionEventState) napi_release_threadsafe_function(g_connCallbacks.tsfn_setMotionEventState, napi_tsfn_release);
    if (g_connCallbacks.tsfn_setControllerLED) napi_release_threadsafe_function(g_connCallbacks.tsfn_setControllerLED, napi_tsfn_release);
    if (g_connCallbacks.tsfn_rumbleTriggers) napi_release_threadsafe_function(g_connCallbacks.tsfn_rumbleTriggers, napi_tsfn_release);
    if (g_connCallbacks.tsfn_resolutionChanged) napi_release_threadsafe_function(g_connCallbacks.tsfn_resolutionChanged, napi_tsfn_release);
    if (g_connCallbacks.tsfn_clipboardData) napi_release_threadsafe_function(g_connCallbacks.tsfn_clipboardData, napi_tsfn_release);
    
    memset(&g_videoCallbacks, 0, sizeof(g_videoCallbacks));
    memset(&g_audioCallbacks, 0, sizeof(g_audioCallbacks));
    memset(&g_connCallbacks, 0, sizeof(g_connCallbacks));
    
    // 清理 AVCodec Opus 解码器
    MoonlightOpusDecoder::Cleanup();
    
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
    
    // 计算总大小和分段数量
    int totalSize = 0;
    int segmentCount = 0;
    PLENTRY entry = decodeUnit->bufferList;
    while (entry != nullptr) {
        totalSize += entry->length;
        segmentCount++;
        entry = entry->next;
    }
    
    // 构建 scatter-gather 分段数组（栈上分配，避免动态内存）
    // 典型帧由 SPS/PPS/VPS + NAL 组成，分段数很少（通常 < 16）
    constexpr int kMaxStackSegments = 32;
    BufferSegment stackSegments[kMaxStackSegments];
    BufferSegment* segments = stackSegments;
    
    // 极端情况下分段数超限，回退到堆分配
    bool heapAllocated = false;
    if (segmentCount > kMaxStackSegments) {
        segments = new BufferSegment[segmentCount];
        heapAllocated = true;
    }
    
    int i = 0;
    entry = decodeUnit->bufferList;
    while (entry != nullptr) {
        segments[i].data = reinterpret_cast<const uint8_t*>(entry->data);
        segments[i].length = entry->length;
        i++;
        entry = entry->next;
    }
    
    // 直接提交到硬件解码器（scatter-gather 零拷贝：链表数据直写 AVBuffer）
    int result = VideoDecoderInstance::SubmitDecodeUnitScatter(
        segments,
        segmentCount,
        totalSize,
        decodeUnit->frameNumber, 
        decodeUnit->frameType,
        decodeUnit->frameHostProcessingLatency
    );
    
    if (heapAllocated) {
        delete[] segments;
    }
    
    // 注意: 不再通过 tsfn_submitDecodeUnit 通知 ArkTS 层
    // 之前每帧都分配 CallbackData (ptrParam=nullptr) 并 dispatch 到 JS 线程，
    // 但 CallJs_DrSubmitDecodeUnit 检测到 ptrParam==null 后直接 delete，
    // 导致 ~60Hz 的无用 new/delete + 事件循环唤醒，累积 GC 压力引起顿卡。
    // 视频帧已在本地直接提交硬件解码器，无需再通知 JS。
    
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
    int err = MoonlightOpusDecoder::Init(opusConfig);
    if (err != 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to create AVCodec Opus decoder: %{public}d", err);
        return -1;
    }
    
    // 分配解码缓冲区（先释放旧的，避免由上轮 Cleanup 未完整走完导致的泄漏 / size 不一致越界）
    if (g_decodedAudioBuffer) {
        free(g_decodedAudioBuffer);
        g_decodedAudioBuffer = nullptr;
    }
    g_decodedAudioBuffer = (short*)malloc(opusConfig->channelCount * opusConfig->samplesPerFrame * sizeof(short));
    
    // 初始化音频播放器
    err = AudioRendererInstance::Init(opusConfig->sampleRate, opusConfig->channelCount, opusConfig->samplesPerFrame);
    if (err != 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to init audio renderer: %{public}d", err);
        // 继续执行，让 ArkTS 层处理音频
    }
    
    // 初始化低频能量分析器
    g_bassAnalyzer.Init(opusConfig->sampleRate, opusConfig->channelCount);
    OH_LOG_INFO(LOG_APP, "Bass energy analyzer initialized: rate=%{public}d, ch=%{public}d",
                opusConfig->sampleRate, opusConfig->channelCount);
    
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
    MoonlightOpusDecoder::Cleanup();
    
    if (g_decodedAudioBuffer) {
        free(g_decodedAudioBuffer);
        g_decodedAudioBuffer = nullptr;
    }
    
    if (g_audioCallbacks.tsfn_cleanup) {
        napi_call_threadsafe_function(g_audioCallbacks.tsfn_cleanup, nullptr, napi_tsfn_blocking);
    }
}

void BridgeArDecodeAndPlaySample(char* sampleData, int sampleLength) {
    // DIRECT_SUBMIT 模式下，此函数运行在 AudioRecv 线程
    // 设置 QoS 和大核绑定以降低调度延迟（thread_local 确保每线程只执行一次）
    static thread_local bool audioThreadSetup = false;
    if (!audioThreadSetup) {
        audioThreadSetup = true;
        
        // 设置 QoS：优先 USER_INTERACTIVE（最高等级）
        int qosRet = OH_QoS_SetThreadQoS(QOS_USER_INTERACTIVE);
        if (qosRet == 0) {
            OH_LOG_INFO(LOG_APP, "AudioRecv thread QoS: USER_INTERACTIVE (highest)");
        } else {
            qosRet = OH_QoS_SetThreadQoS(QOS_USER_INITIATED);
            if (qosRet == 0) {
                OH_LOG_INFO(LOG_APP, "AudioRecv thread QoS: USER_INITIATED (fallback)");
            } else {
                OH_LOG_WARN(LOG_APP, "AudioRecv thread: failed to set QoS (ret=%{public}d)", qosRet);
            }
        }
        
        // 尝试绑定大核 — 读取 cpufreq 检测高频核心
        int numCpus = sysconf(_SC_NPROCESSORS_CONF);
        if (numCpus > 1) {
            long maxFreq = 0;
            std::vector<std::pair<int, long>> cpuFreqs;
            for (int i = 0; i < numCpus; i++) {
                char path[128];
                snprintf(path, sizeof(path),
                    "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
                std::ifstream ifs(path);
                long freq = 0;
                if (ifs >> freq) {
                    cpuFreqs.push_back({i, freq});
                    if (freq > maxFreq) maxFreq = freq;
                }
            }
            
            // 将最高频率 80% 以上的核心视为大核
            if (maxFreq > 0) {
                long threshold = maxFreq * 80 / 100;
                cpu_set_t cpuset;
                CPU_ZERO(&cpuset);
                int bigCount = 0;
                for (auto& [cpu, freq] : cpuFreqs) {
                    if (freq >= threshold) {
                        CPU_SET(cpu, &cpuset);
                        bigCount++;
                    }
                }
                if (bigCount > 0 && bigCount < numCpus) {
                    int ret = sched_setaffinity(0, sizeof(cpuset), &cpuset);
                    if (ret == 0) {
                        OH_LOG_INFO(LOG_APP, "AudioRecv thread bound to %{public}d big cores", bigCount);
                    }
                    // 失败也不要紧，QoS 已暗示调度器优先使用大核
                }
            }
        }
    }
    
    if (g_decodedAudioBuffer == nullptr) {
        return;
    }
    
    // 使用 HarmonyOS AVCodec Opus 解码器
    // 注意：sampleData 可能为 NULL（丢包补偿 PLC），MoonlightOpusDecoder::Decode 内部会处理
    int decodeLen = MoonlightOpusDecoder::Decode(
        (const unsigned char*)sampleData,
        sampleLength,
        g_decodedAudioBuffer,
        g_opusConfig.samplesPerFrame
    );

    // ---- 诊断采样：每 ~1s 输出一行 PCM 统计，异常帧立即 WARN ----
    // 用于排查"断连后重连卡爆音 + 手柄乱震"类问题
    // sequence 关联：BridgeArInit/Cleanup 已有 INFO 日志，便于按时间轴对位
    static thread_local uint64_t s_arvFrameSeq = 0;
    static thread_local uint64_t s_arvDecodeFailCount = 0;
    static thread_local int64_t  s_arvSatSum = 0;        // saturated sample 累计
    static thread_local int64_t  s_arvAbsSum = 0;
    static thread_local int      s_arvMaxAbs = 0;
    static thread_local int      s_arvSampleCount = 0;
    static thread_local int      s_arvBassFires = 0;
    static thread_local int      s_arvLastIntensityMax = 0;
    constexpr int kSatThreshold = 30000;
    constexpr int kFramesPerLog = 200;  // ~1s @5ms/frame

    s_arvFrameSeq++;
    if (decodeLen <= 0) {
        s_arvDecodeFailCount++;
        if (s_arvDecodeFailCount <= 3 || (s_arvDecodeFailCount % 50) == 0) {
            OH_LOG_WARN(LOG_APP, "[AUDIO_DIAG] decode failed/empty: seq=%{public}llu len=%{public}d failCount=%{public}llu",
                        (unsigned long long)s_arvFrameSeq, decodeLen, (unsigned long long)s_arvDecodeFailCount);
        }
    }

    if (decodeLen > 0) {
        // 始终写入解码后的音频，不在解码层丢帧
        // 延迟控制由环形缓冲区内部处理：满时丢弃旧数据、写入新数据
        // 这样波形始终连续，避免丢帧导致的电流滋啦声
        AudioRendererInstance::PlaySamples(g_decodedAudioBuffer, decodeLen);

        // 累计本帧 PCM 统计
        const int totalSamples = decodeLen * g_opusConfig.channelCount;
        int frameMaxAbs = 0;
        int64_t frameAbsSum = 0;
        int frameSat = 0;
        for (int i = 0; i < totalSamples; i++) {
            int v = g_decodedAudioBuffer[i];
            int a = v < 0 ? -v : v;
            if (a > frameMaxAbs) frameMaxAbs = a;
            frameAbsSum += a;
            if (a >= kSatThreshold) frameSat++;
        }
        s_arvSatSum += frameSat;
        s_arvAbsSum += frameAbsSum;
        s_arvSampleCount += totalSamples;
        if (frameMaxAbs > s_arvMaxAbs) s_arvMaxAbs = frameMaxAbs;

        // 单帧异常告警：饱和率 > 50%
        if (totalSamples > 0 && frameSat * 2 > totalSamples) {
            OH_LOG_WARN(LOG_APP, "[AUDIO_DIAG] frame saturation: seq=%{public}llu satRatio=%{public}d%% maxAbs=%{public}d totalSamples=%{public}d",
                        (unsigned long long)s_arvFrameSeq,
                        (int)(frameSat * 100 / totalSamples),
                        frameMaxAbs, totalSamples);
        }

        // 低频能量分析（音频振动）
        int bassIntensity = 0;
        int bassLowFreqRatio = 50;
        int bassStereoBalance = 50;
        if (g_bassAnalyzer.ProcessFrame(g_decodedAudioBuffer, decodeLen, bassIntensity, bassLowFreqRatio, bassStereoBalance)) {
            s_arvBassFires++;
            if (bassIntensity > s_arvLastIntensityMax) s_arvLastIntensityMax = bassIntensity;
            if (g_audioCallbacks.tsfn_bassEnergy) {
                CallbackData* data = new CallbackData();
                data->intParams[0] = bassIntensity;
                data->intParams[1] = bassLowFreqRatio;
                data->intParams[2] = bassStereoBalance;
                napi_status st = napi_call_threadsafe_function(g_audioCallbacks.tsfn_bassEnergy, data, napi_tsfn_nonblocking);
                if (st != napi_ok) delete data;
            }
        }
    }

    if ((s_arvFrameSeq % kFramesPerLog) == 0 && s_arvSampleCount > 0) {
        const int satPct = (int)(s_arvSatSum * 100 / s_arvSampleCount);
        const int meanAbs = (int)(s_arvAbsSum / s_arvSampleCount);
        OH_LOG_INFO(LOG_APP,
            "[AUDIO_DIAG] window seq=%{public}llu frames=%{public}d samples=%{public}d "
            "maxAbs=%{public}d meanAbs=%{public}d satPct=%{public}d%% bassFires=%{public}d intensityMax=%{public}d decodeFails=%{public}llu",
            (unsigned long long)s_arvFrameSeq, kFramesPerLog,
            s_arvSampleCount, s_arvMaxAbs, meanAbs, satPct,
            s_arvBassFires, s_arvLastIntensityMax,
            (unsigned long long)s_arvDecodeFailCount);
        s_arvSatSum = 0;
        s_arvAbsSum = 0;
        s_arvSampleCount = 0;
        s_arvMaxAbs = 0;
        s_arvBassFires = 0;
        s_arvLastIntensityMax = 0;
        // decodeFails 不清零，便于看累计
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
    MoonBridge_OnConnectionTerminated();
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
        napi_status st = napi_call_threadsafe_function(g_connCallbacks.tsfn_rumble, data, napi_tsfn_nonblocking);
        if (st != napi_ok) delete data;
    }
}

void BridgeClConnectionStatusUpdate(int connectionStatus) {
    OH_LOG_INFO(LOG_APP, "Connection status: %{public}d", connectionStatus);
    
    // 网络质量差时主动请求 IDR 帧，加速画面恢复
    // CONN_STATUS_POOR = 1，此时很可能有帧丢失导致解码器参考帧损坏
    // 提前请求 IDR 可避免等待超时才触发恢复
    if (connectionStatus == 1) { // CONN_STATUS_POOR
        LiRequestIdrFrame();
        OH_LOG_WARN(LOG_APP, "Poor connection detected, proactively requesting IDR frame");
    }
    
    // 动态更新所有 mic 编码器的丢包率预估
    // POOR → 15%（增加 FEC 冗余），OKAY → 1%（恢复正常）
    {
        int lossPercent = (connectionStatus == 1) ? 15 : 1;
        MicCapturerUpdatePacketLossPercent(lossPercent);
    }
    
    if (g_connCallbacks.tsfn_connectionStatusUpdate) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = connectionStatus;
        napi_status st = napi_call_threadsafe_function(g_connCallbacks.tsfn_connectionStatusUpdate, data, napi_tsfn_nonblocking);
        if (st != napi_ok) delete data;
    }
}

void BridgeClSetHdrMode(int enabled, void* hdrMetadata) {
    OH_LOG_INFO(LOG_APP, "Set HDR mode: %{public}d, metadata=%{public}p", enabled, hdrMetadata);

    if (enabled && hdrMetadata != nullptr) {
        Smpte2086Metadata convertedMetadata = {};
        if (ConvertSunshineHdrMetadata(static_cast<const SS_HDR_METADATA*>(hdrMetadata), &convertedMetadata)) {
            VideoDecoderInstance::SetHdrStaticMetadata(&convertedMetadata);
            OH_LOG_INFO(LOG_APP, "HDR metadata applied: R=(%.4f,%.4f), G=(%.4f,%.4f), B=(%.4f,%.4f), "
                        "WP=(%.4f,%.4f), maxLum=%.3f, minLum=%.4f, maxCLL=%.3f, maxFALL=%.3f",
                        convertedMetadata.redX, convertedMetadata.redY,
                        convertedMetadata.greenX, convertedMetadata.greenY,
                        convertedMetadata.blueX, convertedMetadata.blueY,
                        convertedMetadata.whiteX, convertedMetadata.whiteY,
                        convertedMetadata.maxLuminance, convertedMetadata.minLuminance,
                        convertedMetadata.maxContentLightLevel,
                        convertedMetadata.maxFrameAverageLightLevel);
        } else {
            VideoDecoderInstance::SetHdrStaticMetadata(nullptr);
            OH_LOG_WARN(LOG_APP, "HDR metadata missing or invalid, decoder will use fallback static metadata");
        }
    } else {
        VideoDecoderInstance::SetHdrStaticMetadata(nullptr);
    }
    
    // 通知 ArkTS 层 HDR 状态变化
    if (g_connCallbacks.tsfn_setHdrMode) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = enabled;
        napi_status st = napi_call_threadsafe_function(g_connCallbacks.tsfn_setHdrMode, data, napi_tsfn_nonblocking);
        if (st != napi_ok) delete data;
    }
}

void BridgeClRumbleTriggers(unsigned short controllerNumber, unsigned short leftTrigger, unsigned short rightTrigger) {
    if (g_connCallbacks.tsfn_rumbleTriggers) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = controllerNumber;
        data->intParams[1] = leftTrigger;
        data->intParams[2] = rightTrigger;
        napi_status st = napi_call_threadsafe_function(g_connCallbacks.tsfn_rumbleTriggers, data, napi_tsfn_nonblocking);
        if (st != napi_ok) delete data;
    }
}

void BridgeClSetMotionEventState(unsigned short controllerNumber, unsigned char motionType, unsigned short reportRateHz) {
    OH_LOG_INFO(LOG_APP, "SetMotionEventState: controller=%u, type=%u, rate=%u", controllerNumber, motionType, reportRateHz);
    if (g_connCallbacks.tsfn_setMotionEventState) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = controllerNumber;
        data->intParams[1] = motionType;
        data->intParams[2] = reportRateHz;
        napi_status st = napi_call_threadsafe_function(g_connCallbacks.tsfn_setMotionEventState, data, napi_tsfn_nonblocking);
        if (st != napi_ok) delete data;
    }
}

void BridgeClSetControllerLED(unsigned short controllerNumber, unsigned char r, unsigned char g, unsigned char b) {
    if (g_connCallbacks.tsfn_setControllerLED) {
        CallbackData* data = new CallbackData();
        data->intParams[0] = controllerNumber;
        data->intParams[1] = r;
        data->intParams[2] = g;
        data->intParams[3] = b;
        napi_status st = napi_call_threadsafe_function(g_connCallbacks.tsfn_setControllerLED, data, napi_tsfn_nonblocking);
        if (st != napi_ok) delete data;
    }
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

void BridgeClClipboardData(const char* data, int length) {
    static constexpr int kClipboardWireHeaderSize = 10;
    static constexpr uint32_t kMaxClipboardPayloadBytes = 65500 - kClipboardWireHeaderSize;

    if (g_connCallbacks.tsfn_clipboardData == nullptr || data == nullptr || length < 10) {
        return;
    }

    const uint8_t* frame = reinterpret_cast<const uint8_t*>(data);
    const uint8_t version = frame[0];
    const uint8_t kind = frame[1];
    const uint32_t token =
        static_cast<uint32_t>(frame[2]) |
        (static_cast<uint32_t>(frame[3]) << 8) |
        (static_cast<uint32_t>(frame[4]) << 16) |
        (static_cast<uint32_t>(frame[5]) << 24);
    const uint32_t payloadLength =
        static_cast<uint32_t>(frame[6]) |
        (static_cast<uint32_t>(frame[7]) << 8) |
        (static_cast<uint32_t>(frame[8]) << 16) |
        (static_cast<uint32_t>(frame[9]) << 24);
    const int availablePayloadLength = length - kClipboardWireHeaderSize;

    if (version != 1) {
        OH_LOG_WARN(LOG_APP, "BridgeClClipboardData: unsupported version=%{public}u", version);
        return;
    }

    if (payloadLength != static_cast<uint32_t>(availablePayloadLength)) {
        OH_LOG_WARN(LOG_APP, "BridgeClClipboardData: malformed payload len=%{public}u available=%{public}d",
                    payloadLength, availablePayloadLength);
        return;
    }

    if (payloadLength > kMaxClipboardPayloadBytes ||
        static_cast<uint32_t>(availablePayloadLength) > kMaxClipboardPayloadBytes) {
        OH_LOG_WARN(LOG_APP,
                    "BridgeClClipboardData: payload too large len=%{public}u available=%{public}d max=%{public}u",
                    payloadLength, availablePayloadLength, kMaxClipboardPayloadBytes);
        return;
    }

    CallbackData* cbData = new CallbackData();
    memset(cbData, 0, sizeof(*cbData));
    cbData->intParams[0] = static_cast<int>(kind);
    cbData->doubleParams[0] = static_cast<double>(token);
    cbData->ptrSize = availablePayloadLength;

    if (availablePayloadLength > 0) {
        cbData->ptrParam = malloc(availablePayloadLength);
        if (cbData->ptrParam == nullptr) {
            delete cbData;
            OH_LOG_ERROR(LOG_APP, "BridgeClClipboardData: malloc failed for %{public}d bytes", availablePayloadLength);
            return;
        }
        memcpy(cbData->ptrParam, frame + kClipboardWireHeaderSize, availablePayloadLength);
    }

    napi_status st = napi_call_threadsafe_function(g_connCallbacks.tsfn_clipboardData, cbData, napi_tsfn_blocking);
    if (st != napi_ok) {
        if (cbData->ptrParam != nullptr) {
            free(cbData->ptrParam);
        }
        delete cbData;
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
