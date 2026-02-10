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
 * 按键事件拦截器实现
 *
 * 参考: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/interceptor-guidelines
 *
 * 拦截所有按键事件，通过 napi_threadsafe_function 回调到 ArkTS 层。
 * ArkTS 层可以判断按键类型并做相应处理（转发给 GamepadManager 等）。
 */

#include "input_interceptor.h"
#include <multimodalinput/oh_input_manager.h>
#include <hilog/log.h>
#include <cstring>
#include <dlfcn.h>

#define LOG_TAG "InputInterceptor"
#define LOG_DOMAIN 0xFF10
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

// ==================== 数据结构 ====================

/**
 * 拦截到的按键事件数据（用于跨线程传递）
 */
struct InterceptedKeyEvent {
    int32_t keyCode;
    int32_t action;     // KEY_ACTION_DOWN=1, KEY_ACTION_UP=2
    int64_t actionTime;
};

// ==================== 全局状态 ====================

static napi_threadsafe_function g_tsCallback = nullptr;
static bool g_interceptorActive = false;

// ==================== 按键注入 API 动态加载 (API 13+) ====================
// OH_Input_InjectKeyEvent 等函数在 API 12 SDK 中不存在，
// 通过 dlsym 在运行时检测可用性，用于回注被拦截的音量键。

typedef Input_Result (*PFN_CreateKeyEvent)(Input_KeyEvent **keyEvent);
typedef void (*PFN_DestroyKeyEvent)(Input_KeyEvent **keyEvent);
typedef Input_Result (*PFN_SetKeyEventKeyCode)(Input_KeyEvent *keyEvent, int32_t keyCode);
typedef Input_Result (*PFN_SetKeyEventAction)(Input_KeyEvent *keyEvent, int32_t action);
typedef Input_Result (*PFN_SetKeyEventActionTime)(Input_KeyEvent *keyEvent, int64_t actionTime);
typedef Input_Result (*PFN_InjectKeyEvent)(const Input_KeyEvent *keyEvent);

static PFN_CreateKeyEvent g_pfnCreateKeyEvent = nullptr;
static PFN_DestroyKeyEvent g_pfnDestroyKeyEvent = nullptr;
static PFN_SetKeyEventKeyCode g_pfnSetKeyCode = nullptr;
static PFN_SetKeyEventAction g_pfnSetAction = nullptr;
static PFN_SetKeyEventActionTime g_pfnSetActionTime = nullptr;
static PFN_InjectKeyEvent g_pfnInjectKeyEvent = nullptr;
static bool g_injectApiChecked = false;
static bool g_injectApiAvailable = false;

/**
 * 检查并加载按键注入 API（仅在高版本 API 设备上可用）
 */
static bool CheckAndLoadInjectApi()
{
    if (g_injectApiChecked) {
        return g_injectApiAvailable;
    }
    g_injectApiChecked = true;

    void *handle = dlopen("libohinput.so", RTLD_NOW);
    if (!handle) {
        LOGW("Failed to dlopen libohinput.so for inject API");
        return false;
    }

    g_pfnCreateKeyEvent   = (PFN_CreateKeyEvent)dlsym(handle, "OH_Input_CreateKeyEvent");
    g_pfnDestroyKeyEvent  = (PFN_DestroyKeyEvent)dlsym(handle, "OH_Input_DestroyKeyEvent");
    g_pfnSetKeyCode       = (PFN_SetKeyEventKeyCode)dlsym(handle, "OH_Input_SetKeyEventKeyCode");
    g_pfnSetAction        = (PFN_SetKeyEventAction)dlsym(handle, "OH_Input_SetKeyEventAction");
    g_pfnSetActionTime    = (PFN_SetKeyEventActionTime)dlsym(handle, "OH_Input_SetKeyEventActionTime");
    g_pfnInjectKeyEvent   = (PFN_InjectKeyEvent)dlsym(handle, "OH_Input_InjectKeyEvent");

    if (g_pfnCreateKeyEvent && g_pfnDestroyKeyEvent && g_pfnSetKeyCode &&
        g_pfnSetAction && g_pfnSetActionTime && g_pfnInjectKeyEvent) {
        g_injectApiAvailable = true;
        LOGI("Key inject API available (API 13+), volume key re-injection enabled");
    } else {
        LOGW("Key inject API not available, anti-hijack feature should be disabled");
        g_pfnCreateKeyEvent  = nullptr;
        g_pfnDestroyKeyEvent = nullptr;
        g_pfnSetKeyCode      = nullptr;
        g_pfnSetAction       = nullptr;
        g_pfnSetActionTime   = nullptr;
        g_pfnInjectKeyEvent  = nullptr;
    }
    // 不 dlclose，保持库加载
    return g_injectApiAvailable;
}

// ==================== 音量键回注 ====================

static bool isVolumeKey(int32_t keyCode)
{
    return keyCode == 16 || keyCode == 17 || keyCode == 22;  // VOLUME_UP / VOLUME_DOWN / VOLUME_MUTE
}

/**
 * 将被拦截的音量键回注到系统，恢复正常音量控制
 * @return true 回注成功，false 回注失败（需回退到 ArkTS 应用音量）
 */
static bool reinjectVolumeKey(const Input_KeyEvent *srcEvent)
{
    if (!g_injectApiAvailable) return false;

    Input_KeyEvent *newEvent = nullptr;
    if (g_pfnCreateKeyEvent(&newEvent) != INPUT_SUCCESS || !newEvent) {
        LOGW("Failed to create key event for re-injection");
        return false;
    }

    g_pfnSetKeyCode(newEvent, OH_Input_GetKeyEventKeyCode(srcEvent));
    g_pfnSetAction(newEvent, OH_Input_GetKeyEventAction(srcEvent));
    g_pfnSetActionTime(newEvent, OH_Input_GetKeyEventActionTime(srcEvent));

    Input_Result ret = g_pfnInjectKeyEvent(newEvent);
    g_pfnDestroyKeyEvent(&newEvent);

    if (ret != INPUT_SUCCESS) {
        LOGW("Failed to inject volume key event: %{public}d (permission denied?)", ret);
        return false;
    }
    return true;
}

// ==================== 回调函数 ====================

/**
 * 按键事件拦截回调（在 Input 线程中调用）
 * - 音量键：优先回注到系统；失败则转发给 ArkTS 做应用级音量调节
 * - 其他按键：转发给 ArkTS 层处理
 */
static void OnKeyEventCallback(const Input_KeyEvent *keyEvent)
{
    if (!keyEvent) return;

    int32_t keyCode = OH_Input_GetKeyEventKeyCode(keyEvent);

    // 音量键：尝试回注到系统
    if (isVolumeKey(keyCode)) {
        if (reinjectVolumeKey(keyEvent)) {
            return;  // 回注成功，系统会处理音量变化
        }
        // 回注失败（无权限或 API 不可用），回退：转发给 ArkTS 做应用音量调节
    }

    // 转发给 ArkTS
    if (!g_tsCallback) return;

    auto *data = new InterceptedKeyEvent();
    data->keyCode = keyCode;
    data->action = OH_Input_GetKeyEventAction(keyEvent);
    data->actionTime = OH_Input_GetKeyEventActionTime(keyEvent);

    napi_status status = napi_call_threadsafe_function(g_tsCallback, data, napi_tsfn_nonblocking);
    if (status != napi_ok) {
        LOGW("napi_call_threadsafe_function failed: %{public}d", status);
        delete data;
    }
}

/**
 * JS 线程回调：将拦截到的按键事件传递给 ArkTS 回调函数
 */
static void CallJsCallback(napi_env env, napi_value jsCallback, void *context, void *data)
{
    if (!env || !jsCallback || !data) {
        if (data) delete static_cast<InterceptedKeyEvent *>(data);
        return;
    }

    auto *event = static_cast<InterceptedKeyEvent *>(data);

    // 构造参数: { keyCode: number, action: number, actionTime: number }
    napi_value jsEvent;
    napi_create_object(env, &jsEvent);

    napi_value keyCodeVal, actionVal, actionTimeVal;
    napi_create_int32(env, event->keyCode, &keyCodeVal);
    napi_create_int32(env, event->action, &actionVal);
    napi_create_int64(env, event->actionTime, &actionTimeVal);

    napi_set_named_property(env, jsEvent, "keyCode", keyCodeVal);
    napi_set_named_property(env, jsEvent, "action", actionVal);
    napi_set_named_property(env, jsEvent, "actionTime", actionTimeVal);

    // 调用 ArkTS 回调
    napi_value result;
    napi_call_function(env, nullptr, jsCallback, 1, &jsEvent, &result);

    delete event;
}

// ==================== NAPI 接口 ====================

/**
 * addKeyInterceptor(callback: (event: {keyCode, action, actionTime}) => void): number
 *
 * 启用按键拦截器。返回 0 表示成功。
 */
static napi_value AddKeyInterceptor(napi_env env, napi_callback_info info)
{
    // 确保 inject API 已加载（用于回注音量键）
    CheckAndLoadInjectApi();

    // 解析参数：callback 函数
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 1) {
        LOGE("addKeyInterceptor: 缺少回调函数参数");
        napi_value ret;
        napi_create_int32(env, -1, &ret);
        return ret;
    }

    // 如果已经有拦截器，先移除
    if (g_interceptorActive) {
        OH_Input_RemoveKeyEventInterceptor();
        g_interceptorActive = false;
    }
    if (g_tsCallback) {
        napi_release_threadsafe_function(g_tsCallback, napi_tsfn_abort);
        g_tsCallback = nullptr;
    }

    // 创建 threadsafe function
    napi_value asyncResourceName;
    napi_create_string_utf8(env, "KeyInterceptorCallback", NAPI_AUTO_LENGTH, &asyncResourceName);

    napi_status status = napi_create_threadsafe_function(
        env,
        argv[0],           // JS callback
        nullptr,           // async resource
        asyncResourceName, // async resource name
        0,                 // max queue size (0 = unlimited)
        1,                 // initial thread count
        nullptr,           // thread finalize data
        nullptr,           // thread finalize callback
        nullptr,           // context
        CallJsCallback,    // call JS callback
        &g_tsCallback
    );

    if (status != napi_ok) {
        LOGE("创建 threadsafe function 失败: %{public}d", status);
        napi_value ret;
        napi_create_int32(env, -2, &ret);
        return ret;
    }

    // 创建按键事件拦截器
    Input_Result inputRet = OH_Input_AddKeyEventInterceptor(OnKeyEventCallback, nullptr);
    if (inputRet != INPUT_SUCCESS) {
        LOGE("OH_Input_AddKeyEventInterceptor 失败: %{public}d", inputRet);
        napi_release_threadsafe_function(g_tsCallback, napi_tsfn_abort);
        g_tsCallback = nullptr;
        napi_value ret;
        napi_create_int32(env, inputRet, &ret);
        return ret;
    }

    g_interceptorActive = true;
    LOGI("按键拦截器已启用");

    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

/**
 * removeKeyInterceptor(): number
 *
 * 移除按键拦截器。返回 0 表示成功。
 */
static napi_value RemoveKeyInterceptor(napi_env env, napi_callback_info info)
{
    int32_t result = 0;

    if (g_interceptorActive) {
        Input_Result inputRet = OH_Input_RemoveKeyEventInterceptor();
        if (inputRet != INPUT_SUCCESS) {
            LOGW("OH_Input_RemoveKeyEventInterceptor 失败: %{public}d", inputRet);
            result = inputRet;
        }
        g_interceptorActive = false;
        LOGI("按键拦截器已移除");
    }

    if (g_tsCallback) {
        napi_release_threadsafe_function(g_tsCallback, napi_tsfn_release);
        g_tsCallback = nullptr;
    }

    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

/**
 * isKeyInterceptorActive(): boolean
 *
 * 查询拦截器是否处于活跃状态
 */
static napi_value IsKeyInterceptorActive(napi_env env, napi_callback_info info)
{
    napi_value ret;
    napi_get_boolean(env, g_interceptorActive, &ret);
    return ret;
}

/**
 * isInjectApiAvailable(): boolean
 *
 * 查询按键注入 API 是否可用（API 13+ 设备上为 true）
 * 在 API 12 设备上返回 false，此时不应启用反劫持功能（会吃掉音量键且无法回注）
 */
static napi_value IsInjectApiAvailable(napi_env env, napi_callback_info info)
{
    CheckAndLoadInjectApi();
    napi_value ret;
    napi_get_boolean(env, g_injectApiAvailable, &ret);
    return ret;
}

// ==================== 模块初始化 ====================

napi_value InputInterceptor_Init(napi_env env, napi_value exports)
{
    // 创建 InputInterceptor 子对象
    napi_value interceptorObj;
    napi_create_object(env, &interceptorObj);

    napi_property_descriptor methods[] = {
        {"addKeyInterceptor", nullptr, AddKeyInterceptor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"removeKeyInterceptor", nullptr, RemoveKeyInterceptor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isKeyInterceptorActive", nullptr, IsKeyInterceptorActive, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isInjectApiAvailable", nullptr, IsInjectApiAvailable, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, interceptorObj, sizeof(methods) / sizeof(methods[0]), methods);

    // 挂载到 exports.InputInterceptor
    napi_set_named_property(env, exports, "InputInterceptor", interceptorObj);

    LOGI("InputInterceptor NAPI 已初始化");
    return exports;
}
