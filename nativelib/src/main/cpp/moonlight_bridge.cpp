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
 * @file moonlight_bridge.cpp
 * @brief HarmonyOS NAPI 桥接层实现
 * 
 * 实现所有从 ArkTS 调用到 moonlight-common-c 的函数
 * 参照 Android 的 simplejni.c 实现
 */

// 首先包含 moonlight-common-c 的头文件以避免宏重定义警告
extern "C" {
#include "moonlight-common-c/src/Limelight.h"

// 从 MicrophoneStream.c 导出的函数
int sendMicrophoneOpusData(const unsigned char* data, int length);
bool isMicrophoneEncryptionEnabled(void);
}

#include "moonlight_bridge.h"
#include "callbacks.h"
#include "video_decoder.h"
#include "audio_renderer.h"
#include "native_render.h"
#include "opus_encoder.h"
#include <hilog/log.h>
#include <cstring>
#include <arpa/inet.h>
#include <native_window/external_window.h>
#include <unordered_map>
#include <memory>

#define LOG_TAG "MoonlightBridge"

// =============================================================================
// 全局状态
// =============================================================================

static bool g_initialized = false;
static STREAM_CONFIGURATION g_streamConfig;
static SERVER_INFORMATION g_serverInfo;
static int g_videoCapabilities = 0;
static bool g_performanceMode = false;  // 性能模式

// Opus 编码器管理
static std::mutex g_opusEncoderMutex;
static std::unordered_map<int64_t, std::unique_ptr<OpusEncoder>> g_opusEncoders;
static int64_t g_opusEncoderNextHandle = 1;

// 回调结构体
static DECODER_RENDERER_CALLBACKS g_videoCallbacksStruct = {
    .setup = BridgeDrSetup,
    .start = BridgeDrStart,
    .stop = BridgeDrStop,
    .cleanup = BridgeDrCleanup,
    .submitDecodeUnit = (int (*)(PDECODE_UNIT))BridgeDrSubmitDecodeUnit,
    .capabilities = CAPABILITY_DIRECT_SUBMIT,  // 直接从网络线程提交，减少延迟
};

static AUDIO_RENDERER_CALLBACKS g_audioCallbacksStruct = {
    .init = (int (*)(int, POPUS_MULTISTREAM_CONFIGURATION, void*, int))BridgeArInit,
    .start = BridgeArStart,
    .stop = BridgeArStop,
    .cleanup = BridgeArCleanup,
    .decodeAndPlaySample = BridgeArDecodeAndPlaySample,
    .capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION | CAPABILITY_DIRECT_SUBMIT  // 添加直接提交能力
};

static CONNECTION_LISTENER_CALLBACKS g_connCallbacksStruct = {
    .stageStarting = BridgeClStageStarting,
    .stageComplete = BridgeClStageComplete,
    .stageFailed = BridgeClStageFailed,
    .connectionStarted = BridgeClConnectionStarted,
    .connectionTerminated = BridgeClConnectionTerminated,
    .logMessage = BridgeClLogMessage,
    .rumble = BridgeClRumble,
    .connectionStatusUpdate = BridgeClConnectionStatusUpdate,
    .setHdrMode = (void (*)(bool))BridgeClSetHdrMode,
    .rumbleTriggers = BridgeClRumbleTriggers,
    .setMotionEventState = BridgeClSetMotionEventState,
    .setControllerLED = BridgeClSetControllerLED,
    .resolutionChanged = (void (*)(uint32_t, uint32_t))BridgeClResolutionChanged,
};

// =============================================================================
// 辅助函数
// =============================================================================

static napi_value GetUndefined(napi_env env) {
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value GetNull(napi_env env) {
    napi_value null;
    napi_get_null(env, &null);
    return null;
}

static bool GetInt32(napi_env env, napi_value value, int32_t* result) {
    napi_valuetype type;
    napi_typeof(env, value, &type);
    if (type != napi_number) return false;
    napi_get_value_int32(env, value, result);
    return true;
}

static bool GetUint32(napi_env env, napi_value value, uint32_t* result) {
    napi_valuetype type;
    napi_typeof(env, value, &type);
    if (type != napi_number) return false;
    napi_get_value_uint32(env, value, result);
    return true;
}

static bool GetDouble(napi_env env, napi_value value, double* result) {
    napi_valuetype type;
    napi_typeof(env, value, &type);
    if (type != napi_number) return false;
    napi_get_value_double(env, value, result);
    return true;
}

static bool GetString(napi_env env, napi_value value, char* buffer, size_t bufferSize) {
    napi_valuetype type;
    napi_typeof(env, value, &type);
    if (type != napi_string) return false;
    size_t result;
    napi_get_value_string_utf8(env, value, buffer, bufferSize, &result);
    return true;
}

static bool GetBool(napi_env env, napi_value value, bool* result) {
    napi_valuetype type;
    napi_typeof(env, value, &type);
    if (type != napi_boolean) return false;
    napi_get_value_bool(env, value, result);
    return true;
}

// =============================================================================
// 模块初始化
// =============================================================================

napi_value MoonBridge_Init(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "MoonBridge_Init");
    
    // 清理之前的资源（如果有的话）
    // 修复：增加音频渲染器清理，防止重复进入串流时音频泄漏
    VideoDecoderInstance::Cleanup();
    AudioRendererInstance::Cleanup();
    Callbacks_Cleanup();
    
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc >= 1) {
        // 初始化回调
        Callbacks_Init(env, args[0]);
    }
    
    g_initialized = true;
    
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

// =============================================================================
// 连接管理
// =============================================================================

napi_value MoonBridge_StartConnection(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "MoonBridge_StartConnection");
    
    size_t argc = 22;
    napi_value args[22];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 19) {
        napi_throw_error(env, nullptr, "参数不足");
        napi_value result;
        napi_create_int32(env, -1, &result);
        return result;
    }
    
    // 解析参数
    char address[256] = {0};
    char appVersion[64] = {0};
    char gfeVersion[64] = {0};
    char rtspSessionUrl[512] = {0};
    
    GetString(env, args[0], address, sizeof(address));
    GetString(env, args[1], appVersion, sizeof(appVersion));
    GetString(env, args[2], gfeVersion, sizeof(gfeVersion));
    GetString(env, args[3], rtspSessionUrl, sizeof(rtspSessionUrl));
    
    int32_t serverCodecModeSupport, width, height, fps;
    int32_t bitrate, packetSize, streamingRemotely, audioConfiguration;
    int32_t supportedVideoFormats, clientRefreshRateX100;
    int32_t videoCapabilities, colorSpace, colorRange, hdrMode;
    bool enableMic, controlOnly;
    
    GetInt32(env, args[4], &serverCodecModeSupport);
    GetInt32(env, args[5], &width);
    GetInt32(env, args[6], &height);
    GetInt32(env, args[7], &fps);
    GetInt32(env, args[8], &bitrate);
    GetInt32(env, args[9], &packetSize);
    GetInt32(env, args[10], &streamingRemotely);
    GetInt32(env, args[11], &audioConfiguration);
    GetInt32(env, args[12], &supportedVideoFormats);
    GetInt32(env, args[13], &clientRefreshRateX100);
    
    // AES Key 和 IV - 支持 ArrayBuffer 和 TypedArray（如 Uint8Array）
    void* aesKeyData = nullptr;
    size_t aesKeyLength = 0;
    void* aesIvData = nullptr;
    size_t aesIvLength = 0;
    
    // 获取 AES Key - 先尝试 ArrayBuffer，失败则尝试 TypedArray
    napi_valuetype keyType;
    napi_typeof(env, args[14], &keyType);
    bool isKeyTypedArray = false;
    napi_is_typedarray(env, args[14], &isKeyTypedArray);
    
    if (isKeyTypedArray) {
        napi_typedarray_type type;
        size_t byteOffset;
        napi_value arrayBuffer;
        napi_get_typedarray_info(env, args[14], &type, &aesKeyLength, &aesKeyData, &arrayBuffer, &byteOffset);
    } else {
        napi_get_arraybuffer_info(env, args[14], &aesKeyData, &aesKeyLength);
    }
    
    // 获取 AES IV - 先尝试 ArrayBuffer，失败则尝试 TypedArray
    napi_valuetype ivType;
    napi_typeof(env, args[15], &ivType);
    bool isIvTypedArray = false;
    napi_is_typedarray(env, args[15], &isIvTypedArray);
    
    if (isIvTypedArray) {
        napi_typedarray_type type;
        size_t byteOffset;
        napi_value arrayBuffer;
        napi_get_typedarray_info(env, args[15], &type, &aesIvLength, &aesIvData, &arrayBuffer, &byteOffset);
    } else {
        napi_get_arraybuffer_info(env, args[15], &aesIvData, &aesIvLength);
    }
    
    GetInt32(env, args[16], &videoCapabilities);
    GetInt32(env, args[17], &colorSpace);
    GetInt32(env, args[18], &colorRange);
    
    // hdrMode: 0=SDR, 1=HDR10/PQ, 2=HLG
    if (argc > 19) GetInt32(env, args[19], &hdrMode);
    else hdrMode = 0;  // 默认 SDR
    
    if (argc > 20) GetBool(env, args[20], &enableMic);
    else enableMic = false;
    
    if (argc > 21) GetBool(env, args[21], &controlOnly);
    else controlOnly = false;
    
    // 设置服务器信息
    g_serverInfo.address = strdup(address);
    g_serverInfo.serverInfoAppVersion = strdup(appVersion);
    g_serverInfo.serverInfoGfeVersion = strlen(gfeVersion) > 0 ? strdup(gfeVersion) : nullptr;
    g_serverInfo.rtspSessionUrl = strlen(rtspSessionUrl) > 0 ? strdup(rtspSessionUrl) : nullptr;
    g_serverInfo.serverCodecModeSupport = serverCodecModeSupport;
    
    // 设置串流配置
    memset(&g_streamConfig, 0, sizeof(g_streamConfig));
    g_streamConfig.width = width;
    g_streamConfig.height = height;
    g_streamConfig.fps = fps;
    g_streamConfig.bitrate = bitrate;
    g_streamConfig.packetSize = packetSize;
    g_streamConfig.streamingRemotely = streamingRemotely;
    g_streamConfig.audioConfiguration = audioConfiguration;
    g_streamConfig.supportedVideoFormats = supportedVideoFormats;
    g_streamConfig.clientRefreshRateX100 = clientRefreshRateX100;
    g_streamConfig.encryptionFlags = ENCFLG_AUDIO;
    g_streamConfig.colorSpace = colorSpace;
    g_streamConfig.colorRange = colorRange;
    g_streamConfig.enableMic = enableMic;
    g_streamConfig.controlOnly = controlOnly;
    
    // 复制 AES 密钥和 IV
    if (aesKeyData && aesKeyLength >= 16) {
        memcpy(g_streamConfig.remoteInputAesKey, aesKeyData, 16);
    } else {
        OH_LOG_ERROR(LOG_APP, "  riKey: INVALID (data=%{public}p, len=%{public}zu)", aesKeyData, aesKeyLength);
    }
    if (aesIvData && aesIvLength >= 16) {
        memcpy(g_streamConfig.remoteInputAesIv, aesIvData, 16);
    } else {
        OH_LOG_ERROR(LOG_APP, "  riIv: INVALID (data=%{public}p, len=%{public}zu)", aesIvData, aesIvLength);
    }
    
    g_videoCapabilities = videoCapabilities;
    g_videoCallbacksStruct.capabilities = videoCapabilities;
    
    // 判断是否启用 HDR（10位色深视频格式表示 HDR）
    // VIDEO_FORMAT_MASK_10BIT = 0xAA00
    // 0x0200 = HEVC MAIN10 (HDR), 0x2000 = AV1 MAIN10 (HDR)
    bool enableHdr = (supportedVideoFormats & 0xAA00) != 0;
    
    // 确定 HDR 类型
    // hdrMode 来自客户端设置: 0=SDR, 1=HDR10 (PQ), 2=HLG
    // 如果启用 HDR 但没有指定 hdrMode，默认使用 HDR10 (PQ)
    // 如果 hdrMode 是 HLG (2) 但 HDR 未启用，回退到 SDR
    int hdrType = 0;  // SDR
    if (enableHdr) {
        if (hdrMode == 2) {
            // HLG 模式 - 需要 Sunshine 支持
            hdrType = 2;
        } else {
            // HDR10/PQ 模式 (默认)
            hdrType = 1;
        }
    }
    
    // 设置 StreamConfig 的 hdrMode，这会在 RTSP ANNOUNCE 中发送给 Sunshine
    g_streamConfig.hdrMode = hdrType;
    
    OH_LOG_INFO(LOG_APP, "HDR config: enabled=%{public}d, hdrMode=%{public}d (client request=%{public}d), hdrType=%{public}d (0=SDR,1=HDR10,2=HLG), colorSpace=%{public}d, colorRange=%{public}d, videoFormats=0x%{public}x",
                enableHdr ? 1 : 0, g_streamConfig.hdrMode, hdrMode, hdrType, colorSpace, colorRange, supportedVideoFormats);
    
    // 配置视频解码器的 HDR 设置
    VideoDecoderInstance::SetHdrConfig(enableHdr, hdrType, colorSpace, colorRange);
    
    OH_LOG_INFO(LOG_APP, "Starting connection to %{public}s (%{public}dx%{public}d@%{public}d, bitrate=%{public}d)", 
                address, width, height, fps, bitrate);
    
    // 开始连接
    int ret = LiStartConnection(
        &g_serverInfo,
        &g_streamConfig,
        &g_connCallbacksStruct,
        &g_videoCallbacksStruct,
        &g_audioCallbacksStruct,
        nullptr, 0,  // 平台信息
        nullptr, 0   // HDR 信息
    );
    
    OH_LOG_INFO(LOG_APP, "LiStartConnection returned: %{public}d", ret);
    
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

napi_value MoonBridge_StopConnection(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "MoonBridge_StopConnection");
    
    LiStopConnection();
    
    // 重置 HDR 配置 - 在会话完全结束时重置
    VideoDecoderInstance::ResetHdrConfig();
    
    // 清理服务器信息
    if (g_serverInfo.address) {
        free((void*)g_serverInfo.address);
        g_serverInfo.address = nullptr;
    }
    if (g_serverInfo.serverInfoAppVersion) {
        free((void*)g_serverInfo.serverInfoAppVersion);
        g_serverInfo.serverInfoAppVersion = nullptr;
    }
    if (g_serverInfo.serverInfoGfeVersion) {
        free((void*)g_serverInfo.serverInfoGfeVersion);
        g_serverInfo.serverInfoGfeVersion = nullptr;
    }
    if (g_serverInfo.rtspSessionUrl) {
        free((void*)g_serverInfo.rtspSessionUrl);
        g_serverInfo.rtspSessionUrl = nullptr;
    }
    
    return GetUndefined(env);
}

napi_value MoonBridge_InterruptConnection(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "MoonBridge_InterruptConnection");
    LiInterruptConnection();
    return GetUndefined(env);
}

napi_value MoonBridge_ResumeDecoder(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "MoonBridge_ResumeDecoder - 从后台恢复解码器");
    
    // 调用视频解码器的恢复函数
    VideoDecoderInstance::Resume();
    
    return GetUndefined(env);
}

// =============================================================================
// 输入处理 - 鼠标
// =============================================================================

napi_value MoonBridge_SendMouseMove(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t deltaX, deltaY;
    GetInt32(env, args[0], &deltaX);
    GetInt32(env, args[1], &deltaY);
    
    LiSendMouseMoveEvent((short)deltaX, (short)deltaY);
    
    return GetUndefined(env);
}

napi_value MoonBridge_SendMousePosition(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t x, y, refWidth, refHeight;
    GetInt32(env, args[0], &x);
    GetInt32(env, args[1], &y);
    GetInt32(env, args[2], &refWidth);
    GetInt32(env, args[3], &refHeight);
    
    LiSendMousePositionEvent((short)x, (short)y, (short)refWidth, (short)refHeight);
    
    return GetUndefined(env);
}

napi_value MoonBridge_SendMouseMoveAsMousePosition(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t deltaX, deltaY, refWidth, refHeight;
    GetInt32(env, args[0], &deltaX);
    GetInt32(env, args[1], &deltaY);
    GetInt32(env, args[2], &refWidth);
    GetInt32(env, args[3], &refHeight);
    
    LiSendMouseMoveAsMousePositionEvent((short)deltaX, (short)deltaY, (short)refWidth, (short)refHeight);
    
    return GetUndefined(env);
}

napi_value MoonBridge_SendMouseButton(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t buttonEvent, mouseButton;
    GetInt32(env, args[0], &buttonEvent);
    GetInt32(env, args[1], &mouseButton);
    
    LiSendMouseButtonEvent((char)buttonEvent, (char)mouseButton);
    
    return GetUndefined(env);
}

napi_value MoonBridge_SendMouseHighResScroll(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t scrollAmount;
    GetInt32(env, args[0], &scrollAmount);
    
    LiSendHighResScrollEvent((short)scrollAmount);
    
    return GetUndefined(env);
}

napi_value MoonBridge_SendMouseHighResHScroll(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t scrollAmount;
    GetInt32(env, args[0], &scrollAmount);
    
    LiSendHighResHScrollEvent((short)scrollAmount);
    
    return GetUndefined(env);
}

// =============================================================================
// 输入处理 - 键盘
// =============================================================================

napi_value MoonBridge_SendKeyboardInput(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t keyCode, keyAction, modifiers, flags;
    GetInt32(env, args[0], &keyCode);
    GetInt32(env, args[1], &keyAction);
    GetInt32(env, args[2], &modifiers);
    GetInt32(env, args[3], &flags);
    
    LiSendKeyboardEvent2((short)keyCode, (char)keyAction, (char)modifiers, (char)flags);
    
    return GetUndefined(env);
}

napi_value MoonBridge_SendUtf8Text(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    char text[1024] = {0};
    size_t textLen = 0;
    napi_get_value_string_utf8(env, args[0], text, sizeof(text), &textLen);
    
    LiSendUtf8TextEvent(text, textLen);
    
    return GetUndefined(env);
}

// =============================================================================
// 输入处理 - 手柄
// =============================================================================

napi_value MoonBridge_SendMultiControllerInput(napi_env env, napi_callback_info info) {
    size_t argc = 9;
    napi_value args[9];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t controllerNumber, activeGamepadMask, buttonFlags;
    int32_t leftTrigger, rightTrigger;
    int32_t leftStickX, leftStickY, rightStickX, rightStickY;
    
    GetInt32(env, args[0], &controllerNumber);
    GetInt32(env, args[1], &activeGamepadMask);
    GetInt32(env, args[2], &buttonFlags);
    GetInt32(env, args[3], &leftTrigger);
    GetInt32(env, args[4], &rightTrigger);
    GetInt32(env, args[5], &leftStickX);
    GetInt32(env, args[6], &leftStickY);
    GetInt32(env, args[7], &rightStickX);
    GetInt32(env, args[8], &rightStickY);
    
    LiSendMultiControllerEvent(
        (short)controllerNumber,
        (short)activeGamepadMask,
        buttonFlags,
        (unsigned char)leftTrigger,
        (unsigned char)rightTrigger,
        (short)leftStickX,
        (short)leftStickY,
        (short)rightStickX,
        (short)rightStickY
    );
    
    return GetUndefined(env);
}

napi_value MoonBridge_SendControllerArrivalEvent(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t controllerNumber, activeGamepadMask, type;
    int32_t supportedButtonFlags, capabilities;
    
    GetInt32(env, args[0], &controllerNumber);
    GetInt32(env, args[1], &activeGamepadMask);
    GetInt32(env, args[2], &type);
    GetInt32(env, args[3], &supportedButtonFlags);
    GetInt32(env, args[4], &capabilities);
    
    int ret = LiSendControllerArrivalEvent(
        (char)controllerNumber,
        (short)activeGamepadMask,
        (char)type,
        supportedButtonFlags,
        (short)capabilities
    );
    
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

napi_value MoonBridge_SendControllerTouchEvent(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t controllerNumber, eventType, pointerId;
    double x, y, pressure;
    
    GetInt32(env, args[0], &controllerNumber);
    GetInt32(env, args[1], &eventType);
    GetInt32(env, args[2], &pointerId);
    GetDouble(env, args[3], &x);
    GetDouble(env, args[4], &y);
    GetDouble(env, args[5], &pressure);
    
    int ret = LiSendControllerTouchEvent(
        (char)controllerNumber,
        (char)eventType,
        pointerId,
        (float)x,
        (float)y,
        (float)pressure
    );
    
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

napi_value MoonBridge_SendControllerMotionEvent(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t controllerNumber, motionType;
    double x, y, z;
    
    GetInt32(env, args[0], &controllerNumber);
    GetInt32(env, args[1], &motionType);
    GetDouble(env, args[2], &x);
    GetDouble(env, args[3], &y);
    GetDouble(env, args[4], &z);
    
    int ret = LiSendControllerMotionEvent(
        (char)controllerNumber,
        (char)motionType,
        (float)x,
        (float)y,
        (float)z
    );
    
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

napi_value MoonBridge_SendControllerBatteryEvent(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t controllerNumber, batteryState, batteryPercentage;
    
    GetInt32(env, args[0], &controllerNumber);
    GetInt32(env, args[1], &batteryState);
    GetInt32(env, args[2], &batteryPercentage);
    
    int ret = LiSendControllerBatteryEvent(
        (char)controllerNumber,
        (char)batteryState,
        (char)batteryPercentage
    );
    
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

// =============================================================================
// 输入处理 - 触摸/触控笔
// =============================================================================

napi_value MoonBridge_SendTouchEvent(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t eventType, pointerId, rotation;
    double x, y, pressureOrDistance, contactAreaMajor, contactAreaMinor;
    
    GetInt32(env, args[0], &eventType);
    GetInt32(env, args[1], &pointerId);
    GetDouble(env, args[2], &x);
    GetDouble(env, args[3], &y);
    GetDouble(env, args[4], &pressureOrDistance);
    GetDouble(env, args[5], &contactAreaMajor);
    GetDouble(env, args[6], &contactAreaMinor);
    GetInt32(env, args[7], &rotation);
    
    int ret = LiSendTouchEvent(
        (char)eventType,
        pointerId,
        (float)x,
        (float)y,
        (float)pressureOrDistance,
        (float)contactAreaMajor,
        (float)contactAreaMinor,
        (short)rotation
    );
    
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

napi_value MoonBridge_SendPenEvent(napi_env env, napi_callback_info info) {
    size_t argc = 11;
    napi_value args[11];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t eventType, toolType, penButtons, rotation, tilt;
    double x, y, pressureOrDistance, contactAreaMajor, contactAreaMinor;
    
    GetInt32(env, args[0], &eventType);
    GetInt32(env, args[1], &toolType);
    GetInt32(env, args[2], &penButtons);
    GetDouble(env, args[3], &x);
    GetDouble(env, args[4], &y);
    GetDouble(env, args[5], &pressureOrDistance);
    GetDouble(env, args[6], &contactAreaMajor);
    GetDouble(env, args[7], &contactAreaMinor);
    GetInt32(env, args[8], &rotation);
    GetInt32(env, args[9], &tilt);
    
    int ret = LiSendPenEvent(
        (char)eventType,
        (char)toolType,
        (char)penButtons,
        (float)x,
        (float)y,
        (float)pressureOrDistance,
        (float)contactAreaMajor,
        (float)contactAreaMinor,
        (short)rotation,
        (char)tilt
    );
    
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

// =============================================================================
// 麦克风支持
// =============================================================================

napi_value MoonBridge_GetMicPortNumber(napi_env env, napi_callback_info info) {
    extern uint16_t MicPortNumber;
    
    napi_value result;
    napi_create_int32(env, MicPortNumber, &result);
    return result;
}

napi_value MoonBridge_IsMicrophoneRequested(napi_env env, napi_callback_info info) {
    extern uint16_t MicPortNumber;
    
    bool requested = (MicPortNumber != 0 && g_streamConfig.enableMic);
    
    napi_value result;
    napi_get_boolean(env, requested, &result);
    return result;
}

napi_value MoonBridge_SendMicrophoneOpusData(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    void* data = nullptr;
    size_t length = 0;
    napi_get_arraybuffer_info(env, args[0], &data, &length);
    
    int ret = -1;
    if (data && length > 0) {
        ret = sendMicrophoneOpusData((const unsigned char*)data, (int)length);
    }
    
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

napi_value MoonBridge_IsMicrophoneEncryptionEnabled(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, isMicrophoneEncryptionEnabled(), &result);
    return result;
}

// =============================================================================
// Opus 编码器
// =============================================================================

/**
 * 创建 Opus 编码器实例
 * @param sampleRate 采样率 (48000)
 * @param channels 通道数 (1)
 * @param bitrate 比特率 (64000)
 * @return 编码器句柄 (>0 成功, <=0 失败)
 */
napi_value MoonBridge_OpusEncoderCreate(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t sampleRate = 48000;
    int32_t channels = 1;
    int32_t bitrate = 64000;
    
    if (argc >= 1) napi_get_value_int32(env, args[0], &sampleRate);
    if (argc >= 2) napi_get_value_int32(env, args[1], &channels);
    if (argc >= 3) napi_get_value_int32(env, args[2], &bitrate);
    
    OH_LOG_INFO(LOG_APP, "OpusEncoderCreate: sampleRate=%{public}d, channels=%{public}d, bitrate=%{public}d",
                sampleRate, channels, bitrate);
    
    auto encoder = std::make_unique<OpusEncoder>();
    int ret = encoder->Init(sampleRate, channels, bitrate);
    
    napi_value result;
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to initialize Opus encoder: %{public}d", ret);
        napi_create_int64(env, 0, &result);
        return result;
    }
    
    std::lock_guard<std::mutex> lock(g_opusEncoderMutex);
    int64_t handle = g_opusEncoderNextHandle++;
    g_opusEncoders[handle] = std::move(encoder);
    
    OH_LOG_INFO(LOG_APP, "Opus encoder created with handle: %{public}lld", (long long)handle);
    napi_create_int64(env, handle, &result);
    return result;
}

/**
 * 编码 PCM 数据为 Opus
 * @param handle 编码器句柄
 * @param pcmData PCM 数据 (ArrayBuffer)
 * @return 编码后的 Opus 数据 (ArrayBuffer), 或 null 如果失败/无数据
 */
napi_value MoonBridge_OpusEncoderEncode(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int64_t handle = 0;
    napi_get_value_int64(env, args[0], &handle);
    
    void* pcmData = nullptr;
    size_t pcmLength = 0;
    napi_get_arraybuffer_info(env, args[1], &pcmData, &pcmLength);
    
    if (handle == 0 || pcmData == nullptr || pcmLength == 0) {
        return GetUndefined(env);
    }
    
    OpusEncoder* encoder = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_opusEncoderMutex);
        auto it = g_opusEncoders.find(handle);
        if (it == g_opusEncoders.end()) {
            OH_LOG_WARN(LOG_APP, "Invalid opus encoder handle: %{public}lld", (long long)handle);
            return GetUndefined(env);
        }
        encoder = it->second.get();
    }
    
    // 输出缓冲区 (Opus 帧最大约 4000 字节)
    static thread_local uint8_t opusOutput[4096];
    
    int outputLen = encoder->Encode(
        static_cast<const uint8_t*>(pcmData),
        static_cast<int>(pcmLength),
        opusOutput,
        sizeof(opusOutput)
    );
    
    if (outputLen <= 0) {
        // 0 表示暂无数据，负数表示错误
        return GetUndefined(env);
    }
    
    // 创建包含编码数据的 ArrayBuffer
    void* resultData = nullptr;
    napi_value result;
    napi_create_arraybuffer(env, outputLen, &resultData, &result);
    memcpy(resultData, opusOutput, outputLen);
    
    return result;
}

/**
 * 销毁 Opus 编码器实例
 * @param handle 编码器句柄
 */
napi_value MoonBridge_OpusEncoderDestroy(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int64_t handle = 0;
    napi_get_value_int64(env, args[0], &handle);
    
    if (handle == 0) {
        return GetUndefined(env);
    }
    
    OH_LOG_INFO(LOG_APP, "OpusEncoderDestroy: handle=%{public}lld", (long long)handle);
    
    std::lock_guard<std::mutex> lock(g_opusEncoderMutex);
    auto it = g_opusEncoders.find(handle);
    if (it != g_opusEncoders.end()) {
        it->second->Cleanup();
        g_opusEncoders.erase(it);
    }
    
    return GetUndefined(env);
}

// =============================================================================
// 状态和统计
// =============================================================================

napi_value MoonBridge_GetStageName(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t stage;
    GetInt32(env, args[0], &stage);
    
    const char* name = LiGetStageName(stage);
    
    napi_value result;
    napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value MoonBridge_GetPendingAudioDuration(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_int32(env, LiGetPendingAudioDuration(), &result);
    return result;
}

napi_value MoonBridge_GetPendingVideoFrames(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_int32(env, LiGetPendingVideoFrames(), &result);
    return result;
}

napi_value MoonBridge_GetEstimatedRttInfo(napi_env env, napi_callback_info info) {
    uint32_t rtt, variance;
    
    if (!LiGetEstimatedRttInfo(&rtt, &variance)) {
        napi_value result;
        napi_create_int64(env, -1, &result);
        return result;
    }
    
    int64_t combined = ((int64_t)rtt << 32) | variance;
    
    napi_value result;
    napi_create_int64(env, combined, &result);
    return result;
}

napi_value MoonBridge_GetHostFeatureFlags(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_int32(env, LiGetHostFeatureFlags(), &result);
    return result;
}

napi_value MoonBridge_GetLaunchUrlQueryParameters(napi_env env, napi_callback_info info) {
    const char* params = LiGetLaunchUrlQueryParameters();
    
    napi_value result;
    if (params) {
        napi_create_string_utf8(env, params, NAPI_AUTO_LENGTH, &result);
    } else {
        napi_get_null(env, &result);
    }
    return result;
}

// =============================================================================
// 工具函数
// =============================================================================

napi_value MoonBridge_TestClientConnectivity(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    char hostName[256] = {0};
    int32_t referencePort, testFlags;
    
    GetString(env, args[0], hostName, sizeof(hostName));
    GetInt32(env, args[1], &referencePort);
    GetInt32(env, args[2], &testFlags);
    
    int ret = LiTestClientConnectivity(hostName, (unsigned short)referencePort, testFlags);
    
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

napi_value MoonBridge_GetPortFlagsFromStage(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t stage;
    GetInt32(env, args[0], &stage);
    
    napi_value result;
    napi_create_int32(env, LiGetPortFlagsFromStage(stage), &result);
    return result;
}

napi_value MoonBridge_GetPortFlagsFromTerminationErrorCode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t errorCode;
    GetInt32(env, args[0], &errorCode);
    
    napi_value result;
    napi_create_int32(env, LiGetPortFlagsFromTerminationErrorCode(errorCode), &result);
    return result;
}

napi_value MoonBridge_StringifyPortFlags(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t portFlags;
    char separator[16] = {0};
    
    GetInt32(env, args[0], &portFlags);
    GetString(env, args[1], separator, sizeof(separator));
    
    char outputBuffer[512] = {0};
    LiStringifyPortFlags(portFlags, separator, outputBuffer, sizeof(outputBuffer));
    
    napi_value result;
    napi_create_string_utf8(env, outputBuffer, NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value MoonBridge_FindExternalAddressIP4(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    char stunHostName[256] = {0};
    int32_t stunPort;
    
    GetString(env, args[0], stunHostName, sizeof(stunHostName));
    GetInt32(env, args[1], &stunPort);
    
    struct in_addr wanAddr;
    int err = LiFindExternalAddressIP4(stunHostName, stunPort, &wanAddr.s_addr);
    
    if (err == 0) {
        char addrStr[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &wanAddr, addrStr, sizeof(addrStr));
        
        napi_value result;
        napi_create_string_utf8(env, addrStr, NAPI_AUTO_LENGTH, &result);
        return result;
    }
    
    return GetNull(env);
}

napi_value MoonBridge_GuessControllerType(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t vendorId, productId;
    GetInt32(env, args[0], &vendorId);
    GetInt32(env, args[1], &productId);
    
    // TODO: 实现手柄类型猜测
    napi_value result;
    napi_create_int32(env, LI_CTYPE_UNKNOWN, &result);
    return result;
}

napi_value MoonBridge_GuessControllerHasPaddles(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    // TODO: 实现拨片检测
    napi_value result;
    napi_get_boolean(env, false, &result);
    return result;
}

napi_value MoonBridge_GuessControllerHasShareButton(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    // TODO: 实现分享按钮检测
    napi_value result;
    napi_get_boolean(env, false, &result);
    return result;
}

// =============================================================================
// 视频 Surface 管理
// =============================================================================

napi_value MoonBridge_SetVideoSurface(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    OHNativeWindow* window = nullptr;
    
    // 优先使用 NativeRender 的 window（OH_NativeXComponent 架构）
    NativeRender* render = NativeRender::GetInstance();
    if (render != nullptr && render->IsSurfaceReady()) {
        window = render->GetNativeWindow();
        if (window != nullptr) {
            OH_LOG_INFO(LOG_APP, "[MoonBridge] SetVideoSurface: using NativeRender window (XComponent architecture)");
        }
    }
    
    // 如果 NativeRender 没有可用的 window，fallback 到 surfaceId 方式
    if (window == nullptr) {
        if (argc < 1) {
            OH_LOG_ERROR(LOG_APP, "[MoonBridge] SetVideoSurface: missing surfaceId argument and NativeRender not available");
            return GetNull(env);
        }
        
        // 获取 XComponent 的 surface ID
        char surfaceId[64] = {0};
        size_t strLen = 0;
        napi_get_value_string_utf8(env, args[0], surfaceId, sizeof(surfaceId), &strLen);
        
        if (strLen == 0) {
            OH_LOG_ERROR(LOG_APP, "[MoonBridge] SetVideoSurface: empty surfaceId");
            return GetNull(env);
        }
        
        // 通过 surfaceId 获取 OHNativeWindow
        uint64_t surfaceIdNum = strtoull(surfaceId, nullptr, 10);
        
        // 使用 OH_NativeWindow_CreateNativeWindowFromSurfaceId 获取 window
        int ret = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceIdNum, &window);
        if (ret != 0 || window == nullptr) {
            OH_LOG_ERROR(LOG_APP, "[MoonBridge] SetVideoSurface: failed to create window from surfaceId %{public}s, ret=%{public}d", surfaceId, ret);
            return GetNull(env);
        }
        
        OH_LOG_INFO(LOG_APP, "[MoonBridge] SetVideoSurface: created window from surfaceId %{public}s (legacy mode)", surfaceId);
        
        // 将 window 设置到 NativeRender，初始化 NativeVSync 用于高帧率优化
        if (render != nullptr) {
            // 获取 window 的尺寸（暂时使用默认值，后续可从 XComponent 获取）
            render->SetNativeWindow(window, 0, 0);
            OH_LOG_INFO(LOG_APP, "[MoonBridge] SetVideoSurface: NativeRender initialized with surfaceId window");
        }
    }
    
    // 初始化视频解码器
    bool success = VideoDecoderInstance::Init(window);
    
    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}

napi_value MoonBridge_ReleaseVideoSurface(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "[MoonBridge] ReleaseVideoSurface");
    
    // 清理视频解码器
    VideoDecoderInstance::Cleanup();
    
    // 清理 NativeRender 的 window 引用
    NativeRender* render = NativeRender::GetInstance();
    if (render != nullptr) {
        render->SetNativeWindow(nullptr, 0, 0);
    }
    
    return GetUndefined(env);
}

napi_value MoonBridge_GetVideoStats(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);
    
    auto stats = VideoDecoderInstance::GetStats();
    
    OH_LOG_INFO(LOG_APP, "[MoonBridge] GetVideoStats - frames: %{public}llu, rxFps: %.2f, rdFps: %.2f, bitrate: %.2f, hostLatency: %.2f",
                stats.decodedFrames, stats.currentFps, stats.renderedFps, stats.currentBitrate, stats.avgHostProcessingLatency);
    
    napi_value framesDecoded, framesDropped, avgDecodeTime;
    napi_value fps, renderedFps, bitrate, hostLatency;
    
    napi_create_uint32(env, static_cast<uint32_t>(stats.decodedFrames), &framesDecoded);
    napi_create_uint32(env, static_cast<uint32_t>(stats.droppedFrames), &framesDropped);
    napi_create_double(env, stats.averageDecodeTimeMs, &avgDecodeTime);
    napi_create_double(env, stats.currentFps, &fps);          // 接收帧率 (Rx)
    napi_create_double(env, stats.renderedFps, &renderedFps); // 渲染帧率 (Rd)
    napi_create_double(env, stats.currentBitrate, &bitrate);
    napi_create_double(env, stats.avgHostProcessingLatency, &hostLatency);  // 主机处理延迟
    
    napi_set_named_property(env, result, "framesDecoded", framesDecoded);
    napi_set_named_property(env, result, "framesDropped", framesDropped);
    napi_set_named_property(env, result, "avgDecodeTimeMs", avgDecodeTime);
    napi_set_named_property(env, result, "fps", fps);             // 接收帧率 (Rx)
    napi_set_named_property(env, result, "renderedFps", renderedFps); // 渲染帧率 (Rd)
    napi_set_named_property(env, result, "bitrate", bitrate);
    napi_set_named_property(env, result, "hostLatency", hostLatency);  // 主机处理延迟（编码时间）
    
    return result;
}

napi_value MoonBridge_GetDecoderCapabilities(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);
    
    auto caps = VideoDecoderInstance::GetCapabilities();
    
    napi_value supportsH264, supportsHEVC, supportsAV1;
    napi_value maxWidth, maxHeight, maxFps;
    
    napi_get_boolean(env, caps.supportsH264, &supportsH264);
    napi_get_boolean(env, caps.supportsHEVC, &supportsHEVC);
    napi_get_boolean(env, caps.supportsAV1, &supportsAV1);
    napi_create_uint32(env, caps.maxWidth, &maxWidth);
    napi_create_uint32(env, caps.maxHeight, &maxHeight);
    napi_create_uint32(env, caps.maxFps, &maxFps);
    
    napi_set_named_property(env, result, "supportsH264", supportsH264);
    napi_set_named_property(env, result, "supportsHEVC", supportsHEVC);
    napi_set_named_property(env, result, "supportsAV1", supportsAV1);
    napi_set_named_property(env, result, "maxWidth", maxWidth);
    napi_set_named_property(env, result, "maxHeight", maxHeight);
    napi_set_named_property(env, result, "maxFps", maxFps);
    
    return result;
}

napi_value MoonBridge_SetDecoderBufferCount(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t count = 4;  // 默认值
    if (argc >= 1) {
        GetInt32(env, args[0], &count);
    }
    
    OH_LOG_INFO(LOG_APP, "MoonBridge_SetDecoderBufferCount: %{public}d", count);
    VideoDecoderInstance::SetBufferCount(count);
    
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value MoonBridge_SetDecoderSyncMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    bool syncMode = false;  // 默认异步模式
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &syncMode);
    }
    
    OH_LOG_INFO(LOG_APP, "MoonBridge_SetDecoderSyncMode: %{public}s", 
                syncMode ? "SYNC (low latency)" : "ASYNC (default)");
    VideoDecoderInstance::SetSyncMode(syncMode);
    
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value MoonBridge_IsDecoderSyncMode(napi_env env, napi_callback_info info) {
    bool syncMode = VideoDecoderInstance::IsSyncMode();
    
    napi_value result;
    napi_get_boolean(env, syncMode, &result);
    return result;
}

napi_value MoonBridge_SetVrrEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    bool enabled = false;  // 默认禁用
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &enabled);
    }
    
    OH_LOG_INFO(LOG_APP, "MoonBridge_SetVrrEnabled: %{public}s", enabled ? "ON" : "OFF");
    VideoDecoderInstance::SetVrrEnabled(enabled);
    
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value MoonBridge_SetVsyncEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    bool enabled = false;  // 默认关闭（低延迟优先）
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &enabled);
    }
    
    OH_LOG_INFO(LOG_APP, "MoonBridge_SetVsyncEnabled: %{public}s", enabled ? "true" : "false");
    
    // 设置 NativeRender 的 VSync 模式
    NativeRender* render = NativeRender::GetInstance();
    if (render != nullptr) {
        render->SetVsyncEnabled(enabled);
    }
    
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value MoonBridge_IsVsyncEnabled(napi_env env, napi_callback_info info) {
    bool enabled = false;
    NativeRender* render = NativeRender::GetInstance();
    if (render != nullptr) {
        enabled = render->IsVsyncEnabled();
    }
    
    napi_value result;
    napi_get_boolean(env, enabled, &result);
    return result;
}

// =============================================================================
// 音频设置
// =============================================================================

napi_value MoonBridge_SetSpatialAudioEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    bool enabled = true;
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &enabled);
    }
    
    OH_LOG_INFO(LOG_APP, "MoonBridge_SetSpatialAudioEnabled: %{public}s", enabled ? "true" : "false");
    AudioRendererInstance::SetSpatialAudioEnabled(enabled);
    
    return GetUndefined(env);
}

napi_value MoonBridge_IsSpatialAudioEnabled(napi_env env, napi_callback_info info) {
    bool enabled = AudioRendererInstance::IsSpatialAudioEnabled();
    
    napi_value result;
    napi_get_boolean(env, enabled, &result);
    return result;
}

napi_value MoonBridge_SetAudioVolume(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    double volume = 1.0;
    if (argc >= 1) {
        napi_get_value_double(env, args[0], &volume);
    }
    
    OH_LOG_INFO(LOG_APP, "MoonBridge_SetAudioVolume: %{public}f", volume);
    int ret = AudioRendererInstance::SetVolume(static_cast<float>(volume));
    
    napi_value result;
    napi_get_boolean(env, ret == 0, &result);
    return result;
}

// =============================================================================
// 性能模式
// =============================================================================

bool MoonBridge_IsPerformanceModeEnabled() {
    return g_performanceMode;
}

napi_value MoonBridge_SetPerformanceModeEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    bool enabled = false;
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &enabled);
    }
    
    g_performanceMode = enabled;
    OH_LOG_INFO(LOG_APP, "MoonBridge_SetPerformanceModeEnabled: %{public}s", enabled ? "true" : "false");
    
    // 性能模式会影响后续创建的线程的 QoS 级别
    // 视频解码线程已经使用 QOS_DEADLINE_REQUEST
    // 音频渲染器使用低延迟模式
    // 性能模式主要用于：
    // 1. 确保网络/音频线程也获得高优先级
    // 2. 未来可以扩展到控制其他系统资源
    
    return GetUndefined(env);
}

napi_value MoonBridge_GetPerformanceModeEnabled(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, g_performanceMode, &result);
    return result;
}