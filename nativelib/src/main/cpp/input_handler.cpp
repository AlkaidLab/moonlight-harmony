#include "input_handler.h"
#include <hilog/log.h>

#define LOG_TAG "InputHandler"

/**
 * 发送鼠标移动事件
 * 
 * 参数:
 * - deltaX: X 轴偏移
 * - deltaY: Y 轴偏移
 */
napi_value InputHandler::SendMouseMove(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        return nullptr;
    }
    
    double deltaX, deltaY;
    napi_get_value_double(env, args[0], &deltaX);
    napi_get_value_double(env, args[1], &deltaY);
    
    // TODO: 调用 moonlight-common-c 发送鼠标移动
    // LiSendMouseMoveEvent((short)deltaX, (short)deltaY);
    
    return nullptr;
}

/**
 * 发送鼠标按钮事件
 * 
 * 参数:
 * - button: 按钮编号 (0=左键, 1=中键, 2=右键)
 * - isPressed: 是否按下
 */
napi_value InputHandler::SendMouseButton(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        return nullptr;
    }
    
    int32_t button;
    bool isPressed;
    napi_get_value_int32(env, args[0], &button);
    napi_get_value_bool(env, args[1], &isPressed);
    
    // TODO: 调用 moonlight-common-c
    // if (isPressed) {
    //     LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, button);
    // } else {
    //     LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
    // }
    
    return nullptr;
}

/**
 * 发送鼠标滚轮事件
 */
napi_value InputHandler::SendMouseScroll(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        return nullptr;
    }
    
    double scrollX, scrollY;
    napi_get_value_double(env, args[0], &scrollX);
    napi_get_value_double(env, args[1], &scrollY);
    
    // TODO: LiSendScrollEvent((short)scrollY);
    
    return nullptr;
}

/**
 * 发送键盘事件
 * 
 * 参数:
 * - keyCode: 键码
 * - isPressed: 是否按下
 * - modifiers: 修饰键状态
 */
napi_value InputHandler::SendKeyboard(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        return nullptr;
    }
    
    int32_t keyCode;
    bool isPressed;
    int32_t modifiers = 0;
    
    napi_get_value_int32(env, args[0], &keyCode);
    napi_get_value_bool(env, args[1], &isPressed);
    if (argc >= 3) {
        napi_get_value_int32(env, args[2], &modifiers);
    }
    
    // TODO: 调用 moonlight-common-c
    // LiSendKeyboardEvent(keyCode, isPressed ? KEY_ACTION_DOWN : KEY_ACTION_UP, modifiers);
    
    return nullptr;
}

/**
 * 发送手柄事件
 * 
 * 参数:
 * - controllerIndex: 手柄索引
 * - buttonFlags: 按钮状态位掩码
 * - leftStickX, leftStickY: 左摇杆
 * - rightStickX, rightStickY: 右摇杆
 * - leftTrigger, rightTrigger: 扳机
 */
napi_value InputHandler::SendController(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 8) {
        return nullptr;
    }
    
    int32_t controllerIndex, buttonFlags;
    int32_t leftStickX, leftStickY, rightStickX, rightStickY;
    int32_t leftTrigger, rightTrigger;
    
    napi_get_value_int32(env, args[0], &controllerIndex);
    napi_get_value_int32(env, args[1], &buttonFlags);
    napi_get_value_int32(env, args[2], &leftStickX);
    napi_get_value_int32(env, args[3], &leftStickY);
    napi_get_value_int32(env, args[4], &rightStickX);
    napi_get_value_int32(env, args[5], &rightStickY);
    napi_get_value_int32(env, args[6], &leftTrigger);
    napi_get_value_int32(env, args[7], &rightTrigger);
    
    // TODO: 调用 moonlight-common-c
    /*
    LiSendMultiControllerEvent(
        controllerIndex,
        0xFFFF,  // activeGamepadMask
        buttonFlags,
        (unsigned char)leftTrigger,
        (unsigned char)rightTrigger,
        (short)leftStickX,
        (short)leftStickY,
        (short)rightStickX,
        (short)rightStickY
    );
    */
    
    return nullptr;
}

/**
 * 发送触控事件
 */
napi_value InputHandler::SendTouch(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 5) {
        return nullptr;
    }
    
    int32_t eventType, pointerId;
    double x, y, pressure;
    
    napi_get_value_int32(env, args[0], &eventType);
    napi_get_value_int32(env, args[1], &pointerId);
    napi_get_value_double(env, args[2], &x);
    napi_get_value_double(env, args[3], &y);
    napi_get_value_double(env, args[4], &pressure);
    
    // TODO: 调用 moonlight-common-c 发送触控事件
    
    return nullptr;
}
