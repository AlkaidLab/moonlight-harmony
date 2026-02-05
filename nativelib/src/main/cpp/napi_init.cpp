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
 * NAPI 模块初始化
 * 
 * 这是 HarmonyOS Native 模块的入口点
 * 参照 Android JNI 层导出所有 moonlight-common-c 接口
 */

#include <napi/native_api.h>
#include <hilog/log.h>

#include "moonlight_bridge.h"
#include "callbacks.h"
#include "gamepad_napi.h"
#include "game_controller_native.h"
// SDL3 库尚未移植到 HarmonyOS，暂时禁用
// #include "sdl3/sdl3_gamepad_napi.h"

#define LOG_TAG "MoonlightNative"
#define LOG_DOMAIN 0x0000

// 日志宏
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

// 定义模块
static napi_value Init(napi_env env, napi_value exports);
NAPI_MODULE(moonlight_nativelib, Init)

/**
 * 初始化模块，导出所有 NAPI 方法
 */
static napi_value Init(napi_env env, napi_value exports) {
    LOGI("Moonlight Native 模块初始化");
    
    // 导出方法 - 参照 Android MoonBridge.java
    napi_property_descriptor desc[] = {
        // 初始化
        { "init", nullptr, MoonBridge_Init, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 连接管理
        { "startConnection", nullptr, MoonBridge_StartConnection, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopConnection", nullptr, MoonBridge_StopConnection, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "interruptConnection", nullptr, MoonBridge_InterruptConnection, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resumeDecoder", nullptr, MoonBridge_ResumeDecoder, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 鼠标输入
        { "sendMouseMove", nullptr, MoonBridge_SendMouseMove, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendMousePosition", nullptr, MoonBridge_SendMousePosition, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendMouseMoveAsMousePosition", nullptr, MoonBridge_SendMouseMoveAsMousePosition, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendMouseButton", nullptr, MoonBridge_SendMouseButton, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendMouseHighResScroll", nullptr, MoonBridge_SendMouseHighResScroll, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendMouseHighResHScroll", nullptr, MoonBridge_SendMouseHighResHScroll, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 键盘输入
        { "sendKeyboardInput", nullptr, MoonBridge_SendKeyboardInput, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendUtf8Text", nullptr, MoonBridge_SendUtf8Text, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 手柄输入
        { "sendMultiControllerInput", nullptr, MoonBridge_SendMultiControllerInput, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendControllerArrivalEvent", nullptr, MoonBridge_SendControllerArrivalEvent, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendControllerTouchEvent", nullptr, MoonBridge_SendControllerTouchEvent, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendControllerMotionEvent", nullptr, MoonBridge_SendControllerMotionEvent, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendControllerBatteryEvent", nullptr, MoonBridge_SendControllerBatteryEvent, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 触摸输入
        { "sendTouchEvent", nullptr, MoonBridge_SendTouchEvent, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendPenEvent", nullptr, MoonBridge_SendPenEvent, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 麦克风
        { "getMicPortNumber", nullptr, MoonBridge_GetMicPortNumber, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isMicrophoneRequested", nullptr, MoonBridge_IsMicrophoneRequested, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendMicrophoneOpusData", nullptr, MoonBridge_SendMicrophoneOpusData, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isMicrophoneEncryptionEnabled", nullptr, MoonBridge_IsMicrophoneEncryptionEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // Opus 编码器
        { "opusEncoderCreate", nullptr, MoonBridge_OpusEncoderCreate, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "opusEncoderEncode", nullptr, MoonBridge_OpusEncoderEncode, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "opusEncoderDestroy", nullptr, MoonBridge_OpusEncoderDestroy, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 状态和统计
        { "getStageName", nullptr, MoonBridge_GetStageName, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getPendingAudioDuration", nullptr, MoonBridge_GetPendingAudioDuration, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getPendingVideoFrames", nullptr, MoonBridge_GetPendingVideoFrames, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getEstimatedRttInfo", nullptr, MoonBridge_GetEstimatedRttInfo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getHostFeatureFlags", nullptr, MoonBridge_GetHostFeatureFlags, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getLaunchUrlQueryParameters", nullptr, MoonBridge_GetLaunchUrlQueryParameters, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 工具函数
        { "testClientConnectivity", nullptr, MoonBridge_TestClientConnectivity, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getPortFlagsFromStage", nullptr, MoonBridge_GetPortFlagsFromStage, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getPortFlagsFromTerminationErrorCode", nullptr, MoonBridge_GetPortFlagsFromTerminationErrorCode, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stringifyPortFlags", nullptr, MoonBridge_StringifyPortFlags, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "findExternalAddressIP4", nullptr, MoonBridge_FindExternalAddressIP4, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "guessControllerType", nullptr, MoonBridge_GuessControllerType, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "guessControllerHasPaddles", nullptr, MoonBridge_GuessControllerHasPaddles, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "guessControllerHasShareButton", nullptr, MoonBridge_GuessControllerHasShareButton, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 视频 Surface 管理
        { "setVideoSurface", nullptr, MoonBridge_SetVideoSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "releaseVideoSurface", nullptr, MoonBridge_ReleaseVideoSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getVideoStats", nullptr, MoonBridge_GetVideoStats, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getDecoderCapabilities", nullptr, MoonBridge_GetDecoderCapabilities, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setDecoderBufferCount", nullptr, MoonBridge_SetDecoderBufferCount, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setDecoderSyncMode", nullptr, MoonBridge_SetDecoderSyncMode, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isDecoderSyncMode", nullptr, MoonBridge_IsDecoderSyncMode, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setVsyncEnabled", nullptr, MoonBridge_SetVsyncEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isVsyncEnabled", nullptr, MoonBridge_IsVsyncEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setVrrEnabled", nullptr, MoonBridge_SetVrrEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 音频设置
        { "setSpatialAudioEnabled", nullptr, MoonBridge_SetSpatialAudioEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isSpatialAudioEnabled", nullptr, MoonBridge_IsSpatialAudioEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setAudioVolume", nullptr, MoonBridge_SetAudioVolume, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 性能模式
        { "setPerformanceModeEnabled", nullptr, MoonBridge_SetPerformanceModeEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getPerformanceModeEnabled", nullptr, MoonBridge_GetPerformanceModeEnabled, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    
    // 初始化 Gamepad NAPI (添加 Gamepad 对象, 包含 SDL GameControllerDB 映射支持)
    GamepadNapi_Init(env, exports);
    
    // 初始化 Game Controller Kit NAPI (添加 GameController 对象, 统一 USB/蓝牙手柄支持)
    GameControllerNapi_Init(env, exports);
    
    // SDL3 库尚未移植到 HarmonyOS，SDL3 NAPI 暂时禁用
    // 当前使用内置的 SDL GameControllerDB 映射数据替代
    // Sdl3GamepadNapi_Init(env, exports);
    
    LOGI("导出 %zu 个 NAPI 方法", sizeof(desc) / sizeof(desc[0]));
    
    return exports;
}
