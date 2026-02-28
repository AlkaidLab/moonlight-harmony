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
 * 鼠标事件监听器实现（绝对/相对双模式）
 *
 * 解决问题：ArkUI .onMouse 回调的投递频率受 UI 渲染帧率限制，
 * 无触摸时系统节流至 ~30Hz。本模块使用 OH_Input_AddMouseEventMonitor
 * 在系统输入管线层级监听鼠标事件（不消费事件，触摸/滚轮不受影响），
 * 以硬件轮询率直接转发给 moonlight-common-c，实现全速鼠标回报。
 *
 * 绝对模式（默认，适合远程桌面）：
 *   窗口坐标 → 比例映射到远端全屏。精确定位，无加速。
 *
 * 相对模式（游戏模式，适合 FPS/TPS）：
 *   计算帧间增量 → LiSendMouseMoveEvent(dx, dy)。
 *   使用 OH_Input_InjectMouseEvent（公开 API 12+）实现光标回弹：
 *   当光标接近屏幕边缘时注入 MOVE 到屏幕中心，实现近乎无限行程。
 *   采用状态机 + 位置匹配识别回弹事件：发起回弹后进入 pending 状态，
 *   期间暂停增量发送，直到收到坐标匹配中心的事件或超时恢复。
 *
 * 权限: ohos.permission.INPUT_MONITORING
 */

#include "mouse_interceptor.h"
#include <multimodalinput/oh_input_manager.h>
#include <hilog/log.h>
#include <atomic>
#include <chrono>

#include "moonlight-common-c/src/Limelight.h"

#define LOG_TAG "MouseInterceptor"
#define LOG_DOMAIN 0xFF11
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

// ==================== 配置状态 ====================

static std::atomic<bool> g_active{false};

// 鼠标模式：false=绝对模式（远程桌面），true=相对模式（游戏）
static std::atomic<bool> g_relativeMode{false};

// 窗口矩形（物理 px）：绝对模式下用于坐标映射
static std::atomic<int32_t> g_windowX{0};
static std::atomic<int32_t> g_windowY{0};
static std::atomic<int32_t> g_windowWidth{1080};
static std::atomic<int32_t> g_windowHeight{2400};

// 屏幕尺寸（物理 px）：相对模式下用于边缘检测和光标回弹
static std::atomic<int32_t> g_screenWidth{1080};
static std::atomic<int32_t> g_screenHeight{2400};

// ==================== 相对模式状态 ====================

// 上一帧鼠标位置（用于计算增量）
static int32_t g_lastX = -1;
static int32_t g_lastY = -1;

// 回弹状态机：
//   false = 正常状态，正常计算增量并发送
//   true  = 已发起回弹注入，等待光标到达中心；期间所有事件仅更新锚点，不发送增量
static std::atomic<bool> g_warpPending{false};

// 回弹目标坐标（注入时写入，回调中用于位置匹配）
static int32_t g_warpTargetX = 0;
static int32_t g_warpTargetY = 0;

// 位置匹配容差（px）：系统可能对注入坐标做微小调整
static constexpr int32_t WARP_TOLERANCE = 2;

// 回弹超时保护：如果注入事件丢失，超时后自动恢复正常状态
static int64_t g_warpTimestampMs = 0;
static constexpr int64_t WARP_TIMEOUT_MS = 100;

// 回弹注入事件对象（复用避免频繁创建/销毁）
static Input_MouseEvent* g_injectEvent = nullptr;

// 边缘检测阈值（px）：光标距屏幕边缘小于此值时触发回弹
static constexpr int32_t EDGE_THRESHOLD = 50;

// ==================== 按钮映射 ====================

/**
 * HarmonyOS 鼠标按钮 → Moonlight 按钮常量
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

// ==================== 光标回弹 ====================

/**
 * 将光标传送到屏幕中心，实现无限行程。
 *
 * 进入 warpPending 状态后，OnMouseEvent 会暂停发送增量，
 * 直到收到坐标匹配中心的事件（回弹到达）或超时恢复。
 * 这彻底避免了回弹产生的巨大虚假增量。
 */
static void WarpCursorToCenter()
{
    if (!g_injectEvent) return;

    int32_t sw = g_screenWidth.load(std::memory_order_relaxed);
    int32_t sh = g_screenHeight.load(std::memory_order_relaxed);
    int32_t centerX = sw / 2;
    int32_t centerY = sh / 2;

    g_warpTargetX = centerX;
    g_warpTargetY = centerY;

    auto now = std::chrono::steady_clock::now();
    g_warpTimestampMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()).count();
    g_warpPending.store(true, std::memory_order_release);

    OH_Input_SetMouseEventAction(g_injectEvent, MOUSE_ACTION_MOVE);
    OH_Input_SetMouseEventDisplayX(g_injectEvent, centerX);
    OH_Input_SetMouseEventDisplayY(g_injectEvent, centerY);
    OH_Input_SetMouseEventActionTime(g_injectEvent, -1);

    int32_t ret = OH_Input_InjectMouseEvent(g_injectEvent);
    if (ret != INPUT_SUCCESS) {
        g_warpPending.store(false, std::memory_order_release);
        LOGW("光标回弹注入失败: %{public}d", ret);
    }
}

/**
 * 检测光标是否接近屏幕边缘
 */
static bool IsNearEdge(int32_t x, int32_t y)
{
    int32_t sw = g_screenWidth.load(std::memory_order_relaxed);
    int32_t sh = g_screenHeight.load(std::memory_order_relaxed);
    return x < EDGE_THRESHOLD || x > sw - EDGE_THRESHOLD ||
           y < EDGE_THRESHOLD || y > sh - EDGE_THRESHOLD;
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

    switch (action) {
        case MOUSE_ACTION_MOVE: {
            int32_t x = OH_Input_GetMouseEventDisplayX(event);
            int32_t y = OH_Input_GetMouseEventDisplayY(event);

            if (g_relativeMode.load(std::memory_order_relaxed)) {
                // ── 相对模式（游戏）──

                if (g_warpPending.load(std::memory_order_acquire)) {
                    // 回弹进行中：检查是否为回弹到达事件（位置匹配中心）
                    int32_t diffX = x - g_warpTargetX;
                    int32_t diffY = y - g_warpTargetY;
                    if (diffX >= -WARP_TOLERANCE && diffX <= WARP_TOLERANCE &&
                        diffY >= -WARP_TOLERANCE && diffY <= WARP_TOLERANCE) {
                        // 回弹到达：重置锚点到当前位置，恢复正常状态
                        g_lastX = x;
                        g_lastY = y;
                        g_warpPending.store(false, std::memory_order_release);
                        return;
                    }

                    // 超时保护：注入事件可能丢失，避免永久卡在 pending 状态
                    auto now = std::chrono::steady_clock::now();
                    int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now.time_since_epoch()).count();
                    if (nowMs - g_warpTimestampMs > WARP_TIMEOUT_MS) {
                        g_warpPending.store(false, std::memory_order_release);
                        g_lastX = x;
                        g_lastY = y;
                        LOGW("回弹超时，恢复正常状态 pos=(%{public}d,%{public}d)", x, y);
                        return;
                    }

                    // 仍在等待回弹到达：仅更新锚点，不发送增量
                    g_lastX = x;
                    g_lastY = y;
                    return;
                }

                // 正常状态：计算并发送增量
                if (g_lastX >= 0 && g_lastY >= 0) {
                    int32_t dx = x - g_lastX;
                    int32_t dy = y - g_lastY;
                    if (dx != 0 || dy != 0) {
                        LiSendMouseMoveEvent((short)dx, (short)dy);
                    }
                }
                g_lastX = x;
                g_lastY = y;

                // 边缘检测 → 光标回弹到屏幕中心
                if (IsNearEdge(x, y)) {
                    WarpCursorToCenter();
                }
            } else {
                // ── 绝对模式（远程桌面）──
                int32_t wx = g_windowX.load(std::memory_order_relaxed);
                int32_t wy = g_windowY.load(std::memory_order_relaxed);
                int32_t ww = g_windowWidth.load(std::memory_order_relaxed);
                int32_t wh = g_windowHeight.load(std::memory_order_relaxed);

                int32_t relX = x - wx;
                int32_t relY = y - wy;
                if (relX < 0) relX = 0; else if (relX > ww) relX = ww;
                if (relY < 0) relY = 0; else if (relY > wh) relY = wh;
                LiSendMousePositionEvent((short)relX, (short)relY, (short)ww, (short)wh);
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
            break;
        }

        default:
            break;
    }
}

// ==================== NAPI 接口 ====================

/**
 * addMouseInterceptor(): number
 */
static napi_value AddMouseInterceptor(napi_env env, napi_callback_info info)
{
    if (g_active.load()) {
        OH_Input_RemoveMouseEventMonitor(OnMouseEvent);
        g_active.store(false);
    }

    // 创建复用的注入事件对象（相对模式光标回弹用）
    if (!g_injectEvent) {
        g_injectEvent = OH_Input_CreateMouseEvent();
    }

    // 重置相对模式状态
    g_lastX = -1;
    g_lastY = -1;
    g_warpPending.store(false);

    Input_Result ret = OH_Input_AddMouseEventMonitor(OnMouseEvent);
    if (ret == INPUT_SUCCESS) {
        g_active.store(true);
        bool relative = g_relativeMode.load();
        LOGI("鼠标监听器已启动（%{public}s模式，全速轮询）", relative ? "相对/游戏" : "绝对/桌面");
    } else {
        LOGE("鼠标监听器启动失败: %{public}d", ret);
    }

    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/**
 * removeMouseInterceptor(): number
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

    // 清理注入事件对象
    if (g_injectEvent) {
        OH_Input_DestroyMouseEvent(&g_injectEvent);
        g_injectEvent = nullptr;
    }

    napi_value nResult;
    napi_create_int32(env, result, &nResult);
    return nResult;
}

/**
 * configureMouseInterceptor(windowX, windowY, windowWidth, windowHeight,
 *                           screenWidth, screenHeight, relativeMode): void
 * 配置参数（可在运行中调用）。
 */
static napi_value ConfigureMouseInterceptor(napi_env env, napi_callback_info info)
{
    size_t argc = 7;
    napi_value argv[7];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc >= 7) {
        int32_t windowX, windowY, windowWidth, windowHeight;
        int32_t screenWidth, screenHeight;
        bool relativeMode;

        napi_get_value_int32(env, argv[0], &windowX);
        napi_get_value_int32(env, argv[1], &windowY);
        napi_get_value_int32(env, argv[2], &windowWidth);
        napi_get_value_int32(env, argv[3], &windowHeight);
        napi_get_value_int32(env, argv[4], &screenWidth);
        napi_get_value_int32(env, argv[5], &screenHeight);
        napi_get_value_bool(env, argv[6], &relativeMode);

        if (windowWidth > 0 && windowHeight > 0) {
            g_windowX.store(windowX, std::memory_order_relaxed);
            g_windowY.store(windowY, std::memory_order_relaxed);
            g_windowWidth.store(windowWidth, std::memory_order_relaxed);
            g_windowHeight.store(windowHeight, std::memory_order_relaxed);
        }
        if (screenWidth > 0 && screenHeight > 0) {
            g_screenWidth.store(screenWidth, std::memory_order_relaxed);
            g_screenHeight.store(screenHeight, std::memory_order_relaxed);
        }

        bool prevMode = g_relativeMode.load();
        g_relativeMode.store(relativeMode, std::memory_order_relaxed);

        // 模式切换时重置增量追踪状态
        if (relativeMode != prevMode) {
            g_lastX = -1;
            g_lastY = -1;
            g_warpPending.store(false);
        }

        LOGI("配置更新: window=(%{public}d,%{public}d,%{public}dx%{public}d) screen=%{public}dx%{public}d mode=%{public}s",
             windowX, windowY, windowWidth, windowHeight,
             screenWidth, screenHeight,
             relativeMode ? "相对/游戏" : "绝对/桌面");
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
