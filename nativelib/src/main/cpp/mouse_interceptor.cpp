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
 * 鼠标事件监听器实现
 *
 * 解决问题：ArkUI .onMouse 回调的投递频率受 UI 渲染帧率限制，
 * 无触摸时系统节流至 ~30Hz。本模块使用 OH_Input_AddMouseEventMonitor
 * 在系统输入管线层级监听鼠标事件（不消费事件，触摸/滚轮不受影响），
 * 以硬件轮询率直接转发给 moonlight-common-c，实现全速鼠标回报。
 *
 * 权限: ohos.permission.INPUT_MONITORING
 */

#include "mouse_interceptor.h"
#include <multimodalinput/oh_input_manager.h>
#include <hilog/log.h>
#include <cstring>
#include <atomic>

#include "moonlight-common-c/src/Limelight.h"

#define LOG_TAG "MouseInterceptor"
#define LOG_DOMAIN 0xFF11
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

// ==================== 配置状态 ====================

static std::atomic<bool> g_active{false};
static std::atomic<bool> g_absoluteMode{false};
static std::atomic<int32_t> g_viewWidth{1920};
static std::atomic<int32_t> g_viewHeight{1080};
static std::atomic<float> g_density{1.0f};

// 相对模式：上一次鼠标屏幕坐标（用于计算 delta）
static int32_t g_lastX = -1;
static int32_t g_lastY = -1;

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
 */
static void OnMouseEvent(const Input_MouseEvent *event)
{
    if (!event) return;

    int32_t action = OH_Input_GetMouseEventAction(event);
    int32_t x = OH_Input_GetMouseEventDisplayX(event);
    int32_t y = OH_Input_GetMouseEventDisplayY(event);

    switch (action) {
        case MOUSE_ACTION_MOVE: {
            if (g_absoluteMode.load(std::memory_order_relaxed)) {
                float density = g_density.load(std::memory_order_relaxed);
                int32_t vw = g_viewWidth.load(std::memory_order_relaxed);
                int32_t vh = g_viewHeight.load(std::memory_order_relaxed);
                short vpX = (short)(x / density);
                short vpY = (short)(y / density);
                LiSendMousePositionEvent(vpX, vpY, (short)vw, (short)vh);
            } else {
                if (g_lastX >= 0 && g_lastY >= 0) {
                    int32_t dx = x - g_lastX;
                    int32_t dy = y - g_lastY;
                    if (dx != 0 || dy != 0) {
                        LiSendMouseMoveEvent((short)dx, (short)dy);
                    }
                }
                g_lastX = x;
                g_lastY = y;
            }
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
            g_lastX = x;
            g_lastY = y;
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
        g_lastX = -1;
        g_lastY = -1;
        LOGI("鼠标监听器已启动（全速轮询，不消费事件）");
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
        g_lastX = -1;
        g_lastY = -1;
        LOGI("鼠标监听器已停止");
    }

    napi_value nResult;
    napi_create_int32(env, result, &nResult);
    return nResult;
}

/**
 * configureMouseInterceptor(absoluteMode: boolean, viewWidth: number, viewHeight: number, density: number): void
 * 配置监听器参数（可在运行中调用）。
 */
static napi_value ConfigureMouseInterceptor(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc >= 4) {
        bool absoluteMode;
        int32_t viewWidth, viewHeight;
        double density;

        napi_get_value_bool(env, argv[0], &absoluteMode);
        napi_get_value_int32(env, argv[1], &viewWidth);
        napi_get_value_int32(env, argv[2], &viewHeight);
        napi_get_value_double(env, argv[3], &density);

        g_absoluteMode.store(absoluteMode, std::memory_order_relaxed);
        g_viewWidth.store(viewWidth, std::memory_order_relaxed);
        g_viewHeight.store(viewHeight, std::memory_order_relaxed);
        g_density.store((float)density, std::memory_order_relaxed);

        g_lastX = -1;
        g_lastY = -1;

        LOGI("配置更新: absolute=%{public}d, view=%{public}dx%{public}d, density=%.1f",
             absoluteMode, viewWidth, viewHeight, (float)density);
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
