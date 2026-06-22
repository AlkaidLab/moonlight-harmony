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

// 从 ControlStream.c 导出的函数（剪贴板同步）
int LiSendClipboardData(const void* payload, int length);
}

#include "moonlight_bridge.h"
#include "callbacks.h"
#include "video_decoder.h"
#include "audio_renderer.h"
#include "bass_energy_analyzer.h"
#include "native_render.h"
#include "gl_post_processor.h"
#include "opus_encoder.h"
#include "mic_capturer.h"
#include <hilog/log.h>
#include <cstring>
#include <arpa/inet.h>
#include <native_window/external_window.h>
#include <unordered_map>
#include <memory>
#include <dlfcn.h>
#include <cstdlib>
#include <cerrno>
#include <mutex>

#define LOG_TAG "MoonlightBridge"

// =============================================================================
// 全局状态
// =============================================================================

static bool g_initialized = false;
static STREAM_CONFIGURATION g_streamConfig;
static SERVER_INFORMATION g_serverInfo;
static int g_videoCapabilities = 0;
static bool g_performanceMode = false;  // 性能模式
static constexpr int MOONBRIDGE_ERROR_BUSY = EBUSY;

enum class ConnectionState {
    Idle,
    Starting,
    Started,
    Terminated,
    Stopping
};

static std::mutex g_connectionStateMutex;
static ConnectionState g_connectionState = ConnectionState::Idle;
static bool g_connectionTerminatedDuringStart = false;

struct StartSlot {
    bool acquired = false;
    bool needsCleanup = false;
};

enum class StopAction {
    None,
    InterruptStart,
    Cleanup
};

struct StartConnectionContext {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    int result = -1;
    int32_t videoCapabilities = 0;
    bool ownsServerInfo = false;
    bool ownsStartSlot = false;
    SERVER_INFORMATION serverInfo = {};
    STREAM_CONFIGURATION streamConfig = {};
};

// Opus 编码器管理
static std::mutex g_opusEncoderMutex;
static std::unordered_map<int64_t, std::unique_ptr<OhosOpusEncoder>> g_opusEncoders;
static int64_t g_opusEncoderNextHandle = 1;

// Native 麦克风采集器 (低时延)
static std::unique_ptr<MicCapturer> g_micCapturer;
static std::mutex g_micCapturerMutex;

// 全局接口：更新 mic 编码器丢包率（供 callbacks.cpp 调用）
void MicCapturerUpdatePacketLossPercent(int percent) {
    std::lock_guard<std::mutex> lock(g_micCapturerMutex);
    if (g_micCapturer) {
        g_micCapturer->UpdatePacketLossPercent(percent);
    }
}

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
    .setAdaptiveTriggers = nullptr,
    .resolutionChanged = (void (*)(uint32_t, uint32_t))BridgeClResolutionChanged,
    .clipboardData = BridgeClClipboardData,
};

// =============================================================================
// 辅助函数
// =============================================================================

static napi_value GetUndefined(napi_env env) {
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value CreateResolvedInt32Promise(napi_env env, int32_t value) {
    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);

    napi_value result;
    napi_create_int32(env, value, &result);
    napi_resolve_deferred(env, deferred, result);
    return promise;
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

static size_t GetTypedArrayElementSize(napi_typedarray_type type) {
    switch (type) {
        case napi_int8_array:
        case napi_uint8_array:
        case napi_uint8_clamped_array:
            return 1;
        case napi_int16_array:
        case napi_uint16_array:
            return 2;
        case napi_int32_array:
        case napi_uint32_array:
        case napi_float32_array:
            return 4;
        case napi_float64_array:
        case napi_bigint64_array:
        case napi_biguint64_array:
            return 8;
        default:
            return 0;
    }
}

static bool GetByteArrayData(napi_env env, napi_value value, void** data, size_t* length) {
    bool isTypedArray = false;
    napi_status status = napi_is_typedarray(env, value, &isTypedArray);
    if (status == napi_ok && isTypedArray) {
        napi_typedarray_type type;
        napi_value arrayBuffer;
        size_t byteOffset = 0;
        size_t elementCount = 0;
        status = napi_get_typedarray_info(env, value, &type, &elementCount, data, &arrayBuffer, &byteOffset);
        if (status != napi_ok) {
            return false;
        }

        const size_t elementSize = GetTypedArrayElementSize(type);
        if (elementSize == 0) {
            *data = nullptr;
            *length = 0;
            return false;
        }

        *length = elementCount * elementSize;
        return true;
    }

    bool isArrayBuffer = false;
    status = napi_is_arraybuffer(env, value, &isArrayBuffer);
    if (status == napi_ok && isArrayBuffer) {
        return napi_get_arraybuffer_info(env, value, data, length) == napi_ok;
    }

    *data = nullptr;
    *length = 0;
    return false;
}

static void FreeServerInfo(SERVER_INFORMATION* serverInfo) {
    if (serverInfo == nullptr) {
        return;
    }

    if (serverInfo->address) {
        free((void*)serverInfo->address);
        serverInfo->address = nullptr;
    }
    if (serverInfo->serverInfoAppVersion) {
        free((void*)serverInfo->serverInfoAppVersion);
        serverInfo->serverInfoAppVersion = nullptr;
    }
    if (serverInfo->serverInfoGfeVersion) {
        free((void*)serverInfo->serverInfoGfeVersion);
        serverInfo->serverInfoGfeVersion = nullptr;
    }
    if (serverInfo->rtspSessionUrl) {
        free((void*)serverInfo->rtspSessionUrl);
        serverInfo->rtspSessionUrl = nullptr;
    }
}

static void MoveServerInfo(SERVER_INFORMATION* dest, SERVER_INFORMATION* src) {
    if (dest == nullptr || src == nullptr) {
        return;
    }

    FreeServerInfo(dest);
    *dest = *src;
    memset(src, 0, sizeof(*src));
}

static bool PrepareStartConnection(napi_env env, napi_value* args, size_t argc, SERVER_INFORMATION* serverInfo,
                                   STREAM_CONFIGURATION* streamConfig, int32_t* videoCapabilities,
                                   int32_t* hdrMode) {
    if (argc < 19 || serverInfo == nullptr || streamConfig == nullptr ||
        videoCapabilities == nullptr || hdrMode == nullptr) {
        return false;
    }

    char address[256] = {0};
    char appVersion[64] = {0};
    char gfeVersion[64] = {0};
    char rtspSessionUrl[512] = {0};

    if (!GetString(env, args[0], address, sizeof(address)) ||
        !GetString(env, args[1], appVersion, sizeof(appVersion))) {
        return false;
    }
    GetString(env, args[2], gfeVersion, sizeof(gfeVersion));
    GetString(env, args[3], rtspSessionUrl, sizeof(rtspSessionUrl));

    int32_t serverCodecModeSupport = 0;
    int32_t width = 0;
    int32_t height = 0;
    int32_t fps = 0;
    int32_t bitrate = 0;
    int32_t packetSize = 0;
    int32_t streamingRemotely = 0;
    int32_t audioConfiguration = 0;
    int32_t supportedVideoFormats = 0;
    int32_t clientRefreshRateX100 = 0;
    int32_t colorSpace = 0;
    int32_t colorRange = 0;
    bool enableMic = false;
    bool controlOnly = false;

    if (!GetInt32(env, args[4], &serverCodecModeSupport) ||
        !GetInt32(env, args[5], &width) ||
        !GetInt32(env, args[6], &height) ||
        !GetInt32(env, args[7], &fps) ||
        !GetInt32(env, args[8], &bitrate) ||
        !GetInt32(env, args[9], &packetSize) ||
        !GetInt32(env, args[10], &streamingRemotely) ||
        !GetInt32(env, args[11], &audioConfiguration) ||
        !GetInt32(env, args[12], &supportedVideoFormats) ||
        !GetInt32(env, args[13], &clientRefreshRateX100) ||
        !GetInt32(env, args[16], videoCapabilities) ||
        !GetInt32(env, args[17], &colorSpace) ||
        !GetInt32(env, args[18], &colorRange)) {
        return false;
    }

    if (argc > 19) {
        GetInt32(env, args[19], hdrMode);
    } else {
        *hdrMode = 0;
    }

    if (argc > 20) {
        GetBool(env, args[20], &enableMic);
    }
    if (argc > 21) {
        GetBool(env, args[21], &controlOnly);
    }

    void* aesKeyData = nullptr;
    size_t aesKeyLength = 0;
    void* aesIvData = nullptr;
    size_t aesIvLength = 0;
    GetByteArrayData(env, args[14], &aesKeyData, &aesKeyLength);
    GetByteArrayData(env, args[15], &aesIvData, &aesIvLength);

    memset(serverInfo, 0, sizeof(*serverInfo));
    memset(streamConfig, 0, sizeof(*streamConfig));

    serverInfo->address = strdup(address);
    serverInfo->serverInfoAppVersion = strdup(appVersion);
    serverInfo->serverInfoGfeVersion = strlen(gfeVersion) > 0 ? strdup(gfeVersion) : nullptr;
    serverInfo->rtspSessionUrl = strlen(rtspSessionUrl) > 0 ? strdup(rtspSessionUrl) : nullptr;
    if (serverInfo->address == nullptr || serverInfo->serverInfoAppVersion == nullptr ||
        (strlen(gfeVersion) > 0 && serverInfo->serverInfoGfeVersion == nullptr) ||
        (strlen(rtspSessionUrl) > 0 && serverInfo->rtspSessionUrl == nullptr)) {
        FreeServerInfo(serverInfo);
        return false;
    }
    serverInfo->serverCodecModeSupport = serverCodecModeSupport;

    streamConfig->width = width;
    streamConfig->height = height;
    streamConfig->fps = fps;
    streamConfig->bitrate = bitrate;
    streamConfig->packetSize = packetSize;
    streamConfig->streamingRemotely = streamingRemotely;
    streamConfig->audioConfiguration = audioConfiguration;
    streamConfig->supportedVideoFormats = supportedVideoFormats;
    streamConfig->clientRefreshRateX100 = clientRefreshRateX100;
    streamConfig->encryptionFlags = ENCFLG_AUDIO | ENCFLG_MICROPHONE;
    streamConfig->colorSpace = colorSpace;
    streamConfig->colorRange = colorRange;
    streamConfig->enableMic = enableMic;
    streamConfig->controlOnly = controlOnly;

    if (aesKeyData && aesKeyLength >= 16) {
        memcpy(streamConfig->remoteInputAesKey, aesKeyData, 16);
    } else {
        OH_LOG_ERROR(LOG_APP, "  riKey: INVALID (data=%{public}p, len=%{public}zu)", aesKeyData, aesKeyLength);
        FreeServerInfo(serverInfo);
        return false;
    }
    if (aesIvData && aesIvLength >= 16) {
        memcpy(streamConfig->remoteInputAesIv, aesIvData, 16);
    } else {
        OH_LOG_ERROR(LOG_APP, "  riIv: INVALID (data=%{public}p, len=%{public}zu)", aesIvData, aesIvLength);
        FreeServerInfo(serverInfo);
        return false;
    }

    bool enableHdr = (supportedVideoFormats & 0xAA00) != 0;
    int hdrType = 0;
    if (enableHdr) {
        hdrType = *hdrMode == 2 ? 2 : 1;
    }
    streamConfig->hdrMode = hdrType;

    OH_LOG_INFO(LOG_APP, "HDR config: enabled=%{public}d, hdrMode=%{public}d (client request=%{public}d), hdrType=%{public}d (0=SDR,1=HDR10,2=HLG), colorSpace=%{public}d, colorRange=%{public}d, videoFormats=0x%{public}x",
                enableHdr ? 1 : 0, streamConfig->hdrMode, *hdrMode, hdrType, colorSpace, colorRange,
                supportedVideoFormats);

    return true;
}

static StartSlot TryAcquireStartSlot() {
    std::lock_guard<std::mutex> lock(g_connectionStateMutex);
    if (g_connectionState == ConnectionState::Idle) {
        g_connectionState = ConnectionState::Starting;
        g_connectionTerminatedDuringStart = false;
        return { true, false };
    }

    if (g_connectionState == ConnectionState::Terminated) {
        g_connectionState = ConnectionState::Stopping;
        g_connectionTerminatedDuringStart = false;
        return { true, true };
    }

    return { false, false };
}

static void PromoteStartSlotAfterCleanup() {
    std::lock_guard<std::mutex> lock(g_connectionStateMutex);
    if (g_connectionState == ConnectionState::Stopping) {
        g_connectionState = ConnectionState::Starting;
        g_connectionTerminatedDuringStart = false;
    }
}

static void CompleteStartSlot(int result) {
    std::lock_guard<std::mutex> lock(g_connectionStateMutex);
    if (result == 0) {
        g_connectionState = g_connectionTerminatedDuringStart
            ? ConnectionState::Terminated
            : ConnectionState::Started;
    } else {
        g_connectionState = ConnectionState::Idle;
    }
    g_connectionTerminatedDuringStart = false;
}

static StopAction BeginStopConnection() {
    std::lock_guard<std::mutex> lock(g_connectionStateMutex);
    if (g_connectionState == ConnectionState::Starting) {
        return StopAction::InterruptStart;
    }
    if (g_connectionState == ConnectionState::Stopping) {
        return StopAction::None;
    }
    if (g_connectionState == ConnectionState::Idle || g_connectionState == ConnectionState::Started ||
        g_connectionState == ConnectionState::Terminated) {
        g_connectionState = ConnectionState::Stopping;
        return StopAction::Cleanup;
    }
    return StopAction::None;
}

static void MarkConnectionIdle() {
    std::lock_guard<std::mutex> lock(g_connectionStateMutex);
    g_connectionState = ConnectionState::Idle;
    g_connectionTerminatedDuringStart = false;
}

void MoonBridge_OnConnectionTerminated(void) {
    std::lock_guard<std::mutex> lock(g_connectionStateMutex);
    if (g_connectionState == ConnectionState::Started) {
        g_connectionState = ConnectionState::Terminated;
    } else if (g_connectionState == ConnectionState::Starting) {
        g_connectionTerminatedDuringStart = true;
    }
}

static void DoStopConnectionCleanup();

// Threading: LiStartConnection()/LiStopConnection() are not thread-safe, and this helper also updates
// global stream state. Callers must acquire the native start slot before invoking this helper.
static int StartConnectionWithPreparedInfo(SERVER_INFORMATION* serverInfo, STREAM_CONFIGURATION* streamConfig,
                                           int32_t videoCapabilities) {
    g_streamConfig = *streamConfig;
    g_videoCapabilities = videoCapabilities;
    g_videoCallbacksStruct.capabilities = videoCapabilities;

    bool enableHdr = (streamConfig->supportedVideoFormats & 0xAA00) != 0;
    VideoDecoderInstance::SetHdrConfig(enableHdr, streamConfig->hdrMode,
                                       streamConfig->colorSpace, streamConfig->colorRange);

    OH_LOG_INFO(LOG_APP, "Starting connection to %{public}s (%{public}dx%{public}d@%{public}d, bitrate=%{public}d)",
                serverInfo->address ? serverInfo->address : "",
                streamConfig->width, streamConfig->height, streamConfig->fps, streamConfig->bitrate);

    int ret = LiStartConnection(
        serverInfo,
        streamConfig,
        &g_connCallbacksStruct,
        &g_videoCallbacksStruct,
        &g_audioCallbacksStruct,
        nullptr, 0,
        nullptr, 0
    );

    OH_LOG_INFO(LOG_APP, "LiStartConnection returned: %{public}d", ret);
    return ret;
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
    
    StartSlot startSlot = TryAcquireStartSlot();
    if (!startSlot.acquired) {
        OH_LOG_WARN(LOG_APP, "MoonBridge_StartConnection: connection already active or starting");
        napi_value result;
        napi_create_int32(env, MOONBRIDGE_ERROR_BUSY, &result);
        return result;
    }
    if (startSlot.needsCleanup) {
        DoStopConnectionCleanup();
        PromoteStartSlotAfterCleanup();
    }

    int32_t videoCapabilities = 0;
    int32_t hdrMode = 0;
    FreeServerInfo(&g_serverInfo);
    if (!PrepareStartConnection(env, args, argc, &g_serverInfo, &g_streamConfig,
                                &videoCapabilities, &hdrMode)) {
        MarkConnectionIdle();
        napi_throw_error(env, nullptr, "参数不足");
        napi_value result;
        napi_create_int32(env, -1, &result);
        return result;
    }

    int ret = StartConnectionWithPreparedInfo(&g_serverInfo, &g_streamConfig, videoCapabilities);
    CompleteStartSlot(ret);
    
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

static void ExecuteStartConnectionAsync(napi_env env, void* data) {
    StartConnectionContext* context = static_cast<StartConnectionContext*>(data);
    context->result = StartConnectionWithPreparedInfo(&context->serverInfo, &context->streamConfig,
                                                      context->videoCapabilities);
    if (context->result == 0 && context->ownsServerInfo) {
        MoveServerInfo(&g_serverInfo, &context->serverInfo);
        context->ownsServerInfo = false;
    }
    if (context->ownsStartSlot) {
        CompleteStartSlot(context->result);
        context->ownsStartSlot = false;
    }
}

static void CompleteStartConnectionAsync(napi_env env, napi_status status, void* data) {
    StartConnectionContext* context = static_cast<StartConnectionContext*>(data);
    if (context->ownsStartSlot) {
        CompleteStartSlot(status == napi_ok ? context->result : -1);
    }

    napi_value result;
    napi_create_int32(env, status == napi_ok ? context->result : -1, &result);
    napi_resolve_deferred(env, context->deferred, result);

    if (context->work != nullptr) {
        napi_delete_async_work(env, context->work);
    }
    if (context->ownsServerInfo) {
        FreeServerInfo(&context->serverInfo);
    }
    delete context;
}

napi_value MoonBridge_StartConnectionAsync(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "MoonBridge_StartConnectionAsync");

    size_t argc = 22;
    napi_value args[22];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    StartSlot startSlot = TryAcquireStartSlot();
    if (!startSlot.acquired) {
        OH_LOG_WARN(LOG_APP, "MoonBridge_StartConnectionAsync: connection already active or starting");
        return CreateResolvedInt32Promise(env, MOONBRIDGE_ERROR_BUSY);
    }
    if (startSlot.needsCleanup) {
        DoStopConnectionCleanup();
        PromoteStartSlotAfterCleanup();
    }

    StartConnectionContext* context = new StartConnectionContext();
    context->env = env;
    context->ownsServerInfo = true;
    context->ownsStartSlot = true;

    int32_t videoCapabilities = 0;
    int32_t hdrMode = 0;
    if (!PrepareStartConnection(env, args, argc, &context->serverInfo, &context->streamConfig,
                                &videoCapabilities, &hdrMode)) {
        MarkConnectionIdle();
        delete context;
        napi_throw_error(env, nullptr, "参数不足");
        napi_value result;
        napi_create_int32(env, -1, &result);
        return result;
    }

    context->videoCapabilities = videoCapabilities;

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_value resourceName;
    napi_create_string_utf8(env, "MoonBridgeStartConnectionAsync", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        ExecuteStartConnectionAsync,
        CompleteStartConnectionAsync,
        context,
        &context->work
    );
    if (status != napi_ok) {
        napi_value errorResult;
        napi_create_int32(env, -1, &errorResult);
        napi_resolve_deferred(env, context->deferred, errorResult);
        MarkConnectionIdle();
        FreeServerInfo(&context->serverInfo);
        delete context;
        return promise;
    }

    status = napi_queue_async_work(env, context->work);
    if (status != napi_ok) {
        napi_value errorResult;
        napi_create_int32(env, -1, &errorResult);
        napi_resolve_deferred(env, context->deferred, errorResult);
        napi_delete_async_work(env, context->work);
        MarkConnectionIdle();
        FreeServerInfo(&context->serverInfo);
        delete context;
        return promise;
    }

    return promise;
}

// 执行停止连接的核心清理逻辑
static void DoStopConnectionCleanup() {
    LiStopConnection();

    // 重置 HDR 配置 - 在会话完全结束时重置
    VideoDecoderInstance::ResetHdrConfig();

    // 清理服务器信息
    FreeServerInfo(&g_serverInfo);
}

napi_value MoonBridge_StopConnection(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "MoonBridge_StopConnection");
    StopAction action = BeginStopConnection();
    if (action == StopAction::InterruptStart) {
        LiInterruptConnection();
        OH_LOG_INFO(LOG_APP, "Stop requested while connection is starting; interrupted pending start");
        return GetUndefined(env);
    }
    if (action == StopAction::None) {
        return GetUndefined(env);
    }

    DoStopConnectionCleanup();
    MarkConnectionIdle();
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
    GetByteArrayData(env, args[0], &data, &length);
    
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
// 剪贴板同步（Sunshine protocol extension）
// =============================================================================

/**
 * 发送剪贴板数据到主机
 * 参数：Uint8Array（包含完整的有线帧：version + kind + token + length + payload）
 * 返回：错误码 (0 = 成功, < 0 = 错误)
 */
napi_value MoonBridge_SendClipboardData(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    void* data = nullptr;
    size_t length = 0;
    GetByteArrayData(env, args[0], &data, &length);
    
    int ret = -1;
    if (data && length >= 10 && length <= 65535) {  // 最少 10 字节头，最多 65535 字节
        ret = LiSendClipboardData(data, (int)length);
    }
    
    napi_value result;
    napi_create_int32(env, ret, &result);
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
    
    auto encoder = std::make_unique<OhosOpusEncoder>();
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
    
    OhosOpusEncoder* encoder = nullptr;
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
// Native 低时延麦克风采集器
// =============================================================================

/**
 * 启动 native 低时延麦克风采集
 * @param sampleRate 采样率 (默认 48000)
 * @param channels 声道数 (默认 1)
 * @param bitrate Opus 比特率 bps (默认 64000)
 * @return 0 成功，负数失败
 */
napi_value MoonBridge_NativeMicStart(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    MicCapturerConfig cfg;
    if (argc >= 1) napi_get_value_int32(env, args[0], &cfg.sampleRate);
    if (argc >= 2) napi_get_value_int32(env, args[1], &cfg.channels);
    if (argc >= 3) napi_get_value_int32(env, args[2], &cfg.opusBitrate);

    OH_LOG_INFO(LOG_APP, "NativeMicStart: rate=%{public}d ch=%{public}d bitrate=%{public}d",
                cfg.sampleRate, cfg.channels, cfg.opusBitrate);

    // 先清理旧的
    if (g_micCapturer) {
        g_micCapturer->Cleanup();
        g_micCapturer.reset();
    }

    g_micCapturer = std::make_unique<MicCapturer>();
    int ret = g_micCapturer->Init(cfg);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "NativeMicStart Init failed: %{public}d", ret);
        g_micCapturer.reset();
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    ret = g_micCapturer->Start();
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "NativeMicStart Start failed: %{public}d", ret);
        g_micCapturer->Cleanup();
        g_micCapturer.reset();
    }

    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/**
 * 停止 native 麦克风采集
 */
napi_value MoonBridge_NativeMicStop(napi_env env, napi_callback_info info) {
    if (g_micCapturer) {
        g_micCapturer->Cleanup();
        g_micCapturer.reset();
        OH_LOG_INFO(LOG_APP, "NativeMicStop: done");
    }
    return GetUndefined(env);
}

/**
 * 暂停 native 麦克风采集
 */
napi_value MoonBridge_NativeMicPause(napi_env env, napi_callback_info info) {
    if (g_micCapturer) {
        g_micCapturer->Pause();
    }
    return GetUndefined(env);
}

/**
 * 恢复 native 麦克风采集
 */
napi_value MoonBridge_NativeMicResume(napi_env env, napi_callback_info info) {
    if (g_micCapturer) {
        g_micCapturer->Resume();
    }
    return GetUndefined(env);
}

/**
 * 获取 native 麦克风状态
 * @return {running: boolean, paused: boolean, captured: number, encoded: number, sent: number, dropped: number}
 */
napi_value MoonBridge_NativeMicGetStats(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);

    bool running = false;
    bool paused = false;
    MicCapturerStats stats = {};

    if (g_micCapturer) {
        running = g_micCapturer->IsRunning();
        paused = g_micCapturer->IsPaused();
        stats = g_micCapturer->GetStats();
    }

    napi_value val;
    napi_get_boolean(env, running, &val);
    napi_set_named_property(env, result, "running", val);

    napi_get_boolean(env, paused, &val);
    napi_set_named_property(env, result, "paused", val);

    napi_create_int64(env, (int64_t)stats.framesCapture, &val);
    napi_set_named_property(env, result, "captured", val);

    napi_create_int64(env, (int64_t)stats.framesEncoded, &val);
    napi_set_named_property(env, result, "encoded", val);

    napi_create_int64(env, (int64_t)stats.framesSent, &val);
    napi_set_named_property(env, result, "sent", val);

    napi_create_int64(env, (int64_t)stats.framesDropped, &val);
    napi_set_named_property(env, result, "dropped", val);

    return result;
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
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    // 解析可选的屏幕像素尺寸参数（arg[1]=width, arg[2]=height）
    uint64_t surfaceWidth = 0, surfaceHeight = 0;
    if (argc >= 3) {
        int32_t w = 0, h = 0;
        napi_get_value_int32(env, args[1], &w);
        napi_get_value_int32(env, args[2], &h);
        if (w > 0 && h > 0) {
            surfaceWidth = static_cast<uint64_t>(w);
            surfaceHeight = static_cast<uint64_t>(h);
        }
    }
    
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
        
        // 将 window 设置到 NativeRender，传入屏幕像素尺寸（超分辨率需要）
        if (render != nullptr) {
            render->SetNativeWindow(window, surfaceWidth, surfaceHeight);
            OH_LOG_INFO(LOG_APP, "[MoonBridge] SetVideoSurface: NativeRender initialized, surface=%{public}lux%{public}lu",
                        (unsigned long)surfaceWidth, (unsigned long)surfaceHeight);
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
    
    napi_value framesDecoded, framesDropped, avgDecodeTime;
    napi_value fps, renderedFps, bitrate, hostLatency;
    napi_value totalDecodeTime, validDecodeFrames, totalHostLatency, framesWithHostLat;
    
    napi_create_uint32(env, static_cast<uint32_t>(stats.decodedFrames), &framesDecoded);
    napi_create_uint32(env, static_cast<uint32_t>(stats.droppedFrames), &framesDropped);
    napi_create_double(env, stats.averageDecodeTimeMs, &avgDecodeTime);
    napi_create_double(env, stats.currentFps, &fps);          // 接收帧率 (Rx)
    napi_create_double(env, stats.renderedFps, &renderedFps); // 渲染帧率 (Rd)
    napi_create_double(env, stats.currentBitrate, &bitrate);
    napi_create_double(env, stats.avgHostProcessingLatency, &hostLatency);  // 主机处理延迟
    
    // 网络丢帧统计
    napi_value framesLost, totalFrames;
    napi_create_uint32(env, static_cast<uint32_t>(stats.framesLost), &framesLost);
    napi_create_uint32(env, static_cast<uint32_t>(stats.totalFrames), &totalFrames);
    
    // 累积值（用于串流结束后计算全局平均）
    napi_value globalAvgFps;
    napi_create_double(env, stats.totalDecodeTimeMs, &totalDecodeTime);
    napi_create_uint32(env, static_cast<uint32_t>(stats.validDecodeFrames), &validDecodeFrames);
    napi_create_double(env, stats.totalHostProcessingLatency, &totalHostLatency);
    napi_create_uint32(env, static_cast<uint32_t>(stats.framesWithHostLatency), &framesWithHostLat);
    napi_create_double(env, stats.globalAvgFps, &globalAvgFps);
    
    napi_set_named_property(env, result, "framesDecoded", framesDecoded);
    napi_set_named_property(env, result, "framesDropped", framesDropped);
    napi_set_named_property(env, result, "avgDecodeTimeMs", avgDecodeTime);
    napi_set_named_property(env, result, "fps", fps);             // 接收帧率 (Rx)
    napi_set_named_property(env, result, "renderedFps", renderedFps); // 渲染帧率 (Rd)
    napi_set_named_property(env, result, "bitrate", bitrate);
    napi_set_named_property(env, result, "hostLatency", hostLatency);  // 主机处理延迟（编码时间）
    napi_set_named_property(env, result, "framesLost", framesLost);
    napi_set_named_property(env, result, "totalFrames", totalFrames);
    
    // 累积值
    napi_set_named_property(env, result, "totalDecodeTimeMs", totalDecodeTime);
    napi_set_named_property(env, result, "validDecodeFrames", validDecodeFrames);
    napi_set_named_property(env, result, "totalHostLatencyMs", totalHostLatency);
    napi_set_named_property(env, result, "framesWithHostLatency", framesWithHostLat);
    napi_set_named_property(env, result, "globalAvgFps", globalAvgFps);
    
    // 分类丢帧统计（用于诊断性能问题）
    napi_value dropL1, dropL2, dropL3, dropL4, dropL5, dropQueue, dropTimeout;
    napi_create_uint32(env, static_cast<uint32_t>(stats.droppedByL1), &dropL1);
    napi_create_uint32(env, static_cast<uint32_t>(stats.droppedByL2), &dropL2);
    napi_create_uint32(env, static_cast<uint32_t>(stats.droppedByL3), &dropL3);
    napi_create_uint32(env, static_cast<uint32_t>(stats.droppedByL4), &dropL4);
    napi_create_uint32(env, static_cast<uint32_t>(stats.droppedByL5), &dropL5);
    napi_create_uint32(env, static_cast<uint32_t>(stats.droppedByQueueOverflow), &dropQueue);
    napi_create_uint32(env, static_cast<uint32_t>(stats.droppedByTimeout), &dropTimeout);
    napi_set_named_property(env, result, "droppedByL1", dropL1);
    napi_set_named_property(env, result, "droppedByL2", dropL2);
    napi_set_named_property(env, result, "droppedByL3", dropL3);
    napi_set_named_property(env, result, "droppedByL4", dropL4);
    napi_set_named_property(env, result, "droppedByL5", dropL5);
    napi_set_named_property(env, result, "droppedByQueueOverflow", dropQueue);
    napi_set_named_property(env, result, "droppedByTimeout", dropTimeout);
    
    return result;
}

napi_value MoonBridge_GetDecoderCapabilities(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);
    
    auto caps = VideoDecoderInstance::GetCapabilities();
    
    napi_value supportsH264, supportsHEVC, supportsAV1;
    napi_value maxWidth, maxHeight, maxFps;
    napi_value supportsLowLatency, supports4K60, supports4K120, supports1080p120, maxInstances;
    
    napi_get_boolean(env, caps.supportsH264, &supportsH264);
    napi_get_boolean(env, caps.supportsHEVC, &supportsHEVC);
    napi_get_boolean(env, caps.supportsAV1, &supportsAV1);
    napi_create_uint32(env, caps.maxWidth, &maxWidth);
    napi_create_uint32(env, caps.maxHeight, &maxHeight);
    napi_create_uint32(env, caps.maxFps, &maxFps);
    napi_get_boolean(env, caps.supportsLowLatency, &supportsLowLatency);
    napi_get_boolean(env, caps.supports4K60, &supports4K60);
    napi_get_boolean(env, caps.supports4K120, &supports4K120);
    napi_get_boolean(env, caps.supports1080p120, &supports1080p120);
    napi_create_int32(env, caps.maxInstances, &maxInstances);
    
    napi_set_named_property(env, result, "supportsH264", supportsH264);
    napi_set_named_property(env, result, "supportsHEVC", supportsHEVC);
    napi_set_named_property(env, result, "supportsAV1", supportsAV1);
    napi_set_named_property(env, result, "maxWidth", maxWidth);
    napi_set_named_property(env, result, "maxHeight", maxHeight);
    napi_set_named_property(env, result, "maxFps", maxFps);
    napi_set_named_property(env, result, "supportsLowLatency", supportsLowLatency);
    napi_set_named_property(env, result, "supports4K60", supports4K60);
    napi_set_named_property(env, result, "supports4K120", supports4K120);
    napi_set_named_property(env, result, "supports1080p120", supports1080p120);
    napi_set_named_property(env, result, "maxInstances", maxInstances);
    
    return result;
}

napi_value MoonBridge_SetDecoderBufferCount(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t count = 0;  // 默认自动
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
                syncMode ? "SYNC (ultra-low-latency, drain-to-latest)" : "ASYNC (default)");
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

napi_value MoonBridge_SetPostProcessEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    bool enabled = false;
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &enabled);
    }
    
    OH_LOG_INFO(LOG_APP, "MoonBridge_SetPostProcessEnabled: %{public}s", enabled ? "ON" : "OFF");
    VideoDecoderInstance::SetPostProcessEnabled(enabled);
    
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value MoonBridge_SetUpscaleMode(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t mode = 0;
    double sharpness = 0.5;
    if (argc >= 1) napi_get_value_int32(env, args[0], &mode);
    if (argc >= 2) napi_get_value_double(env, args[1], &sharpness);

    // 保存到全局变量（跨 PostProcessor 实例保留）
    VideoDecoderInstance::g_upscaleMode = mode;
    VideoDecoderInstance::g_upscaleSharpness = static_cast<float>(sharpness);

    GLPostProcessor* postProc = GLPostProcessor::GetInstance();
    postProc->SetUpscaleMode(static_cast<UpscaleMode>(mode));
    postProc->SetUpscaleSharpness(static_cast<float>(sharpness));

    OH_LOG_INFO(LOG_APP, "MoonBridge_SetUpscaleMode: mode=%{public}d sharpness=%.2f", mode, sharpness);

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value MoonBridge_GetActiveUpscaleMode(napi_env env, napi_callback_info info) {
    GLPostProcessor* postProc = GLPostProcessor::GetInstance();
    int32_t mode = static_cast<int32_t>(postProc->GetActiveUpscaleMode());
    napi_value result;
    napi_create_int32(env, mode, &result);
    return result;
}

napi_value MoonBridge_SetSdrToHdr(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    bool enabled = false;
    double peakNits = 500.0;
    double saturation = 1.3;
    double contrast = 1.0;
    if (argc >= 1) napi_get_value_bool(env, args[0], &enabled);
    if (argc >= 2) napi_get_value_double(env, args[1], &peakNits);
    if (argc >= 3) napi_get_value_double(env, args[2], &saturation);
    if (argc >= 4) napi_get_value_double(env, args[3], &contrast);

    VideoDecoderInstance::SetSdrToHdr(enabled, static_cast<float>(peakNits), static_cast<float>(saturation), static_cast<float>(contrast));

    OH_LOG_INFO(LOG_APP, "MoonBridge_SetSdrToHdr: enabled=%{public}d peakNits=%.0f saturation=%.2f contrast=%.2f", enabled ? 1 : 0, peakNits, saturation, contrast);

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

napi_value MoonBridge_SetAudioCompatMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    bool enabled = false;
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &enabled);
    }
    
    OH_LOG_INFO(LOG_APP, "MoonBridge_SetAudioCompatMode: %{public}s", enabled ? "true" : "false");
    AudioRendererInstance::SetAudioCompatMode(enabled);
    
    return GetUndefined(env);
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

// =============================================================================
// 音频振动
// =============================================================================

extern BassEnergyAnalyzer g_bassAnalyzer;

napi_value MoonBridge_SetBassVibrationConfig(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 2) {
        OH_LOG_WARN(LOG_APP, "SetBassVibrationConfig: need 2-3 args (enabled, sensitivity, [sceneMode])");
        return GetUndefined(env);
    }

    bool enabled = false;
    napi_get_value_bool(env, argv[0], &enabled);

    double sensitivity = 1.0;
    napi_get_value_double(env, argv[1], &sensitivity);

    // 第三个参数可选: sceneMode (0=游戏, 1=音乐, 2=自动)
    int sceneMode = 0;
    if (argc >= 3) {
        napi_get_value_int32(env, argv[2], &sceneMode);
    }

    g_bassAnalyzer.SetEnabled(enabled);
    g_bassAnalyzer.SetSensitivity(static_cast<float>(sensitivity));
    g_bassAnalyzer.SetSceneMode(sceneMode);

    OH_LOG_INFO(LOG_APP, "SetBassVibrationConfig: enabled=%{public}s, sensitivity=%.2f, sceneMode=%{public}d",
                enabled ? "true" : "false", sensitivity, sceneMode);

    return GetUndefined(env);
}

// =============================================================================
// XComponent 帧率设置（通过 FrameNode → ArkUI_NodeHandle，无需 libraryname）
// =============================================================================

// 动态加载的函数指针（API 12/20，运行时检测可用性）
// 帧率范围结构体（与 OH_NativeXComponent_ExpectedRateRange 布局一致）
struct XCFrameRateRange {
    int32_t min;
    int32_t max;
    int32_t expected;
};

typedef int32_t (*PFN_GetNodeHandleFromNapiValue)(napi_env, napi_value, void** /* ArkUI_NodeHandle* */);
typedef void* (*PFN_GetNativeXComponent)(void* /* ArkUI_NodeHandle */);
typedef int32_t (*PFN_XCSetFrameRateOld)(void* /* OH_NativeXComponent* */, XCFrameRateRange* /* range* */);
typedef int32_t (*PFN_XCSetFrameRateNew)(void* /* ArkUI_NodeHandle */, XCFrameRateRange /* range */);

static PFN_GetNodeHandleFromNapiValue g_pfnGetNodeHandle = nullptr;
static PFN_GetNativeXComponent g_pfnGetNativeXC = nullptr;
static PFN_XCSetFrameRateOld g_pfnXCSetFrameRateOld = nullptr;
static PFN_XCSetFrameRateNew g_pfnXCSetFrameRateNew = nullptr;
static bool g_xcFrameRateChecked = false;

static void CheckAndLoadXCFrameRateApis() {
    if (g_xcFrameRateChecked) return;
    g_xcFrameRateChecked = true;
    
    // OH_ArkUI_GetNodeHandleFromNapiValue (API 12) — libace_ndk.z.so
    g_pfnGetNodeHandle = (PFN_GetNodeHandleFromNapiValue)dlsym(RTLD_DEFAULT, 
        "OH_ArkUI_GetNodeHandleFromNapiValue");
    if (!g_pfnGetNodeHandle) {
        // RTLD_DEFAULT 可能在某些设备上找不到，回退到显式 dlopen
        void* aceHandle = dlopen("libace_ndk.z.so", RTLD_NOW);
        if (aceHandle) {
            g_pfnGetNodeHandle = (PFN_GetNodeHandleFromNapiValue)dlsym(aceHandle,
                "OH_ArkUI_GetNodeHandleFromNapiValue");
        }
    }
    if (!g_pfnGetNodeHandle) {
        OH_LOG_WARN(LOG_APP, "XCFrameRate: OH_ArkUI_GetNodeHandleFromNapiValue not found (need API 12+)");
        return;
    }
    
    // 方式1 (API 20): OH_ArkUI_XComponent_SetExpectedFrameRateRange — 直接通过 NodeHandle
    g_pfnXCSetFrameRateNew = (PFN_XCSetFrameRateNew)dlsym(RTLD_DEFAULT, 
        "OH_ArkUI_XComponent_SetExpectedFrameRateRange");
    if (!g_pfnXCSetFrameRateNew) {
        void* aceHandle = dlopen("libace_ndk.z.so", RTLD_NOW);
        if (aceHandle) {
            g_pfnXCSetFrameRateNew = (PFN_XCSetFrameRateNew)dlsym(aceHandle,
                "OH_ArkUI_XComponent_SetExpectedFrameRateRange");
        }
    }
    if (g_pfnXCSetFrameRateNew) {
        OH_LOG_INFO(LOG_APP, "XCFrameRate: API 20 OH_ArkUI_XComponent_SetExpectedFrameRateRange available");
        return;  // 优先方式，不需要继续查找
    }
    
    // 方式2 (API 12+11): OH_NativeXComponent_GetNativeXComponent + SetExpectedFrameRateRange
    g_pfnGetNativeXC = (PFN_GetNativeXComponent)dlsym(RTLD_DEFAULT, 
        "OH_NativeXComponent_GetNativeXComponent");
    g_pfnXCSetFrameRateOld = (PFN_XCSetFrameRateOld)dlsym(RTLD_DEFAULT, 
        "OH_NativeXComponent_SetExpectedFrameRateRange");
    // 回退 dlopen
    if (!g_pfnGetNativeXC || !g_pfnXCSetFrameRateOld) {
        void* aceHandle = dlopen("libace_ndk.z.so", RTLD_NOW);
        if (aceHandle) {
            if (!g_pfnGetNativeXC)
                g_pfnGetNativeXC = (PFN_GetNativeXComponent)dlsym(aceHandle,
                    "OH_NativeXComponent_GetNativeXComponent");
            if (!g_pfnXCSetFrameRateOld)
                g_pfnXCSetFrameRateOld = (PFN_XCSetFrameRateOld)dlsym(aceHandle,
                    "OH_NativeXComponent_SetExpectedFrameRateRange");
        }
    }
    
    if (g_pfnGetNativeXC && g_pfnXCSetFrameRateOld) {
        OH_LOG_INFO(LOG_APP, "XCFrameRate: API 12 GetNativeXComponent + API 11 SetExpectedFrameRateRange available");
    } else {
        OH_LOG_WARN(LOG_APP, "XCFrameRate: No XComponent frame rate API available");
    }
}

napi_value MoonBridge_SetXComponentFrameRate(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 2) {
        OH_LOG_ERROR(LOG_APP, "SetXComponentFrameRate: need 2 args (frameNode, fps)");
        return GetUndefined(env);
    }
    
    int32_t fps = 60;
    napi_get_value_int32(env, argv[1], &fps);
    
    // 加载 API
    CheckAndLoadXCFrameRateApis();
    
    if (!g_pfnGetNodeHandle) {
        OH_LOG_WARN(LOG_APP, "SetXComponentFrameRate: API not available (need API 12+)");
        return GetUndefined(env);
    }
    
    // FrameNode → ArkUI_NodeHandle
    void* nodeHandle = nullptr;
    int32_t ret = g_pfnGetNodeHandle(env, argv[0], &nodeHandle);
    if (ret != 0 || !nodeHandle) {
        OH_LOG_ERROR(LOG_APP, "SetXComponentFrameRate: GetNodeHandle failed: ret=%{public}d", ret);
        return GetUndefined(env);
    }
    
    // 方式1 (API 20): 直接通过 ArkUI_NodeHandle 设置
    if (g_pfnXCSetFrameRateNew) {
        XCFrameRateRange range = { fps, fps, fps };
        int32_t xcRet = g_pfnXCSetFrameRateNew(nodeHandle, range);
        OH_LOG_INFO(LOG_APP, "XComponent FrameRate set to %{public}d fps via ArkUI_NodeHandle (API 20): ret=%{public}d",
                    fps, xcRet);
        return GetUndefined(env);
    }
    
    // 方式2 (API 12+11): NodeHandle → OH_NativeXComponent → SetExpectedFrameRateRange
    if (g_pfnGetNativeXC && g_pfnXCSetFrameRateOld) {
        void* xComp = g_pfnGetNativeXC(nodeHandle);
        if (xComp) {
            XCFrameRateRange range = { fps, fps, fps };
            int32_t xcRet = g_pfnXCSetFrameRateOld(xComp, &range);
            OH_LOG_INFO(LOG_APP, "XComponent FrameRate set to %{public}d fps via NativeXComponent (API 12+11): ret=%{public}d",
                        fps, xcRet);
        } else {
            OH_LOG_ERROR(LOG_APP, "SetXComponentFrameRate: GetNativeXComponent returned null");
        }
        return GetUndefined(env);
    }
    
    OH_LOG_WARN(LOG_APP, "SetXComponentFrameRate: No API path available for fps=%{public}d", fps);
    return GetUndefined(env);
}
