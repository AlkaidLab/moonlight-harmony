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
 * 鼠标事件监听器实现（绝对模式）
 *
 * 解决问题：ArkUI .onMouse 回调的投递频率受 UI 渲染帧率限制，
 * 无触摸时系统节流至 ~30Hz。本模块使用 OH_Input_AddMouseEventMonitor
 * 在系统输入管线层级监听鼠标事件（不消费事件，触摸/滚轮不受影响），
 * 以硬件轮询率直接转发给 moonlight-common-c，实现全速鼠标回报。
 *
 * 始终使用绝对模式（LiSendMousePositionEvent）：
 * HarmonyOS 没有 Pointer Capture API，无法将光标锁定到窗口内，
 * 相对模式下光标到达屏幕/窗口边缘时无法继续产生 delta，导致鼠标卡住。
 * Android Moonlight 在没有 Pointer Capture 时同样回退到绝对模式。
 *
 * 权限: ohos.permission.INPUT_MONITORING
 */

#include "mouse_interceptor.h"
#include <multimodalinput/oh_input_manager.h>
#include <hilog/log.h>
#include <atomic>

#include "moonlight-common-c/src/Limelight.h"

#define LOG_TAG "MouseInterceptor"
#define LOG_DOMAIN 0xFF11
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

// ==================== 配置状态 ====================

static std::atomic<bool> g_active{false};

// 窗口矩形（物理 px）：用于将屏幕坐标映射到远端屏幕
// 全屏模式：窗口=屏幕 → 整个屏幕映射到远端
// 窗口模式：窗口区域映射到远端全屏，窗口外区域夹紧到边缘
static std::atomic<int32_t> g_windowX{0};
static std::atomic<int32_t> g_windowY{0};
static std::atomic<int32_t> g_windowWidth{1080};
static std::atomic<int32_t> g_windowHeight{2400};

// ==================== 按钮映射 ====================

/**
 * HarmonyOS 鼠标按钮 → Moonlight 按钮常量
 * MOUSE_BUTTON_LEFT(0)→BUTTON_LEFT(0x01), MIDDLE(1)→0x02, RIGHT(2)→0x03,
 * FORWARD(3)→BUTTON_X2(0x05), BACK(4)→BUTTON_X1(0x04)
 */
static int MapMouseButton(int32_t button)
{
    switch (button) {
        case 0: return BUTTON_LEFT;
        case 1: return BUTTON_MIDDLE;
        case 2: return BUTTON_RIGHT;
        case 3: return BUTTON_X2;     // Forward
        case 4: return BUTTON_X1;     // Back
        default: return 0;
    }
}

// ==================== 鼠标事件监听回调 ====================

/**
 * 在系统输入线程中调用，不经过 ArkUI 渲染循环。
 * Monitor 不消费事件，触摸和滚轮事件完全不受影响。
 *
 * 绝对模式：屏幕 px → 窗口相对坐标 → 映射到远端屏幕
 */
static void OnMouseEvent(const Input_MouseEvent *event)
{
    if (!event) return;

    int32_t action = OH_Input_GetMouseEventAction(event);

    switch (action) {
        case MOUSE_ACTION_MOVE: {
            int32_t x = OH_Input_GetMouseEventDisplayX(event);
            int32_t y = OH_Input_GetMouseEventDisplayY(event);
            int32_t wx = g_windowX.load(std::memory_order_relaxed);
            int32_t wy = g_windowY.load(std::memory_order_relaxed);
            int32_t ww = g_windowWidth.load(std::memory_order_relaxed);
            int32_t wh = g_windowHeight.load(std::memory_order_relaxed);

            // 屏幕 px → 窗口相对坐标 → 夹紧到窗口边界
            // 全屏时 wx=0,wy=0 → 等价于屏幕坐标直接映射
            int32_t relX = x - wx;
            int32_t relY = y - wy;
            if (relX < 0) relX = 0; else if (relX > ww) relX = ww;
            if (relY < 0) relY = 0; else if (relY > wh) relY = wh;
            LiSendMousePositionEvent((short)relX, (short)relY, (short)ww, (short)wh);
            break;
        }

        case MOUSE_ACTION_BUTTON_DOWN:
        case MOUSE_ACTION_BUTTON_UP: {
            int32_t btn = OH_Input_GetMouseEventButton(event);
            int moonBtn = MapMouseButton(btn);
            if (moonBtn > 0) {
                char moonAction = (action == MOUSE_ACTION_BUTTON_DOWN)
                    ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE;
                LiSendMouseButtonEvent(moonAction, moonBtn);
            }
            break;
        }

        default:
            break;
    }
}

// ==================== NAPI 接口 ====================

/**
 * addMouseInterceptor(): number
 * 启用鼠标事件监听器，成功返回 0。
 */
static napi_value AddMouseInterceptor(napi_env env, napi_callback_info info)
{
    if (g_active.load()) {
        OH_Input_RemoveMouseEventMonitor(OnMouseEvent);
        g_active.store(false);
    }

    Input_Result ret = OH_Input_AddMouseEventMonitor(OnMouseEvent);
    if (ret == INPUT_SUCCESS) {
        g_active.store(true);
        LOGI("鼠标监听器已启动（绝对模式，全速轮询）");
    } else {
        LOGE("鼠标监听器启动失败: %{public}d", ret);
    }

    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/**
 * removeMouseInterceptor(): number
 * 移除鼠标事件监听器，成功返回 0。
 */
static napi_value RemoveMouseInterceptor(napi_env env, napi_callback_info info)
{
    int32_t result = 0;
    if (g_active.load()) {
        Input_Result ret = OH_Input_RemoveMouseEventMonitor(OnMouseEvent);
        if (ret != INPUT_SUCCESS) {
            LOGW("移除鼠标监听器失败: %{public}d", ret);
            result = ret;
        }
        g_active.store(false);
        LOGI("鼠标监听器已停止");
    }

    napi_value nResult;
    napi_create_int32(env, result, &nResult);
    return nResult;
}

/**
 * configureMouseInterceptor(windowX: number, windowY: number,
 *                           windowWidth: number, windowHeight: number): void
 * 配置窗口矩形（可在运行中调用）。
 * 全屏模式：传入 (0, 0, screenWidth, screenHeight)
 * 窗口模式：传入实际窗口位置和尺寸
 */
static napi_value ConfigureMouseInterceptor(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc >= 4) {
        int32_t windowX, windowY, windowWidth, windowHeight;

        napi_get_value_int32(env, argv[0], &windowX);
        napi_get_value_int32(env, argv[1], &windowY);
        napi_get_value_int32(env, argv[2], &windowWidth);
        napi_get_value_int32(env, argv[3], &windowHeight);

        if (windowWidth > 0 && windowHeight > 0) {
            g_windowX.store(windowX, std::memory_order_relaxed);
            g_windowY.store(windowY, std::memory_order_relaxed);
            g_windowWidth.store(windowWidth, std::memory_order_relaxed);
            g_windowHeight.store(windowHeight, std::memory_order_relaxed);
        }

        LOGI("配置更新: window=(%{public}d,%{public}d,%{public}dx%{public}d) px",
             windowX, windowY, windowWidth, windowHeight);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * isMouseInterceptorActive(): boolean
 */
static napi_value IsMouseInterceptorActive(napi_env env, napi_callback_info info)
{
    napi_value result;
    napi_get_boolean(env, g_active.load(), &result);
    return result;
}

// ==================== 模块初始化 ====================

napi_value MouseInterceptor_Init(napi_env env, napi_value exports)
{
    napi_value interceptorObj;
    napi_create_object(env, &interceptorObj);

    napi_property_descriptor methods[] = {
        {"addMouseInterceptor", nullptr, AddMouseInterceptor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"removeMouseInterceptor", nullptr, RemoveMouseInterceptor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"configureMouseInterceptor", nullptr, ConfigureMouseInterceptor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isMouseInterceptorActive", nullptr, IsMouseInterceptorActive, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, interceptorObj, sizeof(methods) / sizeof(methods[0]), methods);
    napi_set_named_property(env, exports, "MouseInterceptor", interceptorObj);

    LOGI("MouseInterceptor NAPI 已初始化");
    return exports;
}
