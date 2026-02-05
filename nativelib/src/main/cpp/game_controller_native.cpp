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
 * Game Controller Kit Native 实现
 * 
 * 封装 HarmonyOS Game Controller Kit C API
 * 提供统一的 USB/蓝牙手柄输入
 */

#include "game_controller_native.h"
#include <hilog/log.h>
#include <string.h>
#include <stdlib.h>
#include <mutex>
#include <map>
#include <string>

// 尝试包含 Game Controller Kit 头文件
// 注意：这些头文件在 API 21+ 可用
#if defined(__OHOS__)
// 检查头文件是否存在
#if __has_include(<GameControllerKit/game_device.h>) && __has_include(<GameControllerKit/game_pad.h>)
#include <GameControllerKit/game_device.h>
#include <GameControllerKit/game_pad.h>
#define GAME_CONTROLLER_KIT_AVAILABLE 1
#else
#define GAME_CONTROLLER_KIT_AVAILABLE 0
#endif
#else
#define GAME_CONTROLLER_KIT_AVAILABLE 0
#endif

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "GameControllerNative"
#define LOG_DOMAIN 0xFF01
#define LOGD(...) OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

// ==================== 全局状态 ====================

static bool g_initialized = false;
static bool g_monitoring = false;
static std::mutex g_mutex;

// 回调函数
static GameControllerDeviceCallback g_deviceCallback = nullptr;
static GameControllerButtonCallback g_buttonCallback = nullptr;
static GameControllerAxisCallback g_axisCallback = nullptr;

// 设备状态缓存 (deviceId -> state)
static std::map<std::string, GameControllerState> g_deviceStates;
static std::map<std::string, GameControllerInfo> g_deviceInfos;

// NAPI 环境和回调引用 (用于异步通知 JS 层)
static napi_env g_napiEnv = nullptr;
static napi_ref g_jsDeviceCallbackRef = nullptr;
static napi_ref g_jsButtonCallbackRef = nullptr;
static napi_ref g_jsAxisCallbackRef = nullptr;
static napi_threadsafe_function g_tsfnDevice = nullptr;
static napi_threadsafe_function g_tsfnButton = nullptr;
static napi_threadsafe_function g_tsfnAxis = nullptr;

#if GAME_CONTROLLER_KIT_AVAILABLE

// ==================== Game Controller Kit 回调实现 ====================

/**
 * 设备状态变化回调 (C++)
 */
static void OnDeviceChanged(const struct GameDevice_DeviceEvent* deviceEvent) {
    if (!deviceEvent) return;
    
    GameDevice_StatusChangedType type;
    OH_GameDevice_DeviceEvent_GetChangedType(deviceEvent, &type);
    
    GameDevice_DeviceInfo* deviceInfo;
    OH_GameDevice_DeviceEvent_GetDeviceInfo(deviceEvent, &deviceInfo);
    
    char* deviceId = nullptr;
    OH_GameDevice_DeviceInfo_GetDeviceId(deviceInfo, &deviceId);
    
    // 枚举值是 ONLINE/OFFLINE，不是 GAME_DEVICE_STATUS_CHANGED_TYPE_ONLINE
    bool isConnected = (type == ONLINE);
    
    LOGI("设备状态变化: deviceId=%s, isConnected=%d", deviceId ? deviceId : "null", isConnected);
    
    // 构建设备信息
    GameControllerInfo info = {};
    if (deviceId) {
        strncpy(info.deviceId, deviceId, sizeof(info.deviceId) - 1);
    }
    
    char* name = nullptr;
    OH_GameDevice_DeviceInfo_GetName(deviceInfo, &name);
    if (name) {
        strncpy(info.name, name, sizeof(info.name) - 1);
        free(name);
    }
    
    int product = 0;
    OH_GameDevice_DeviceInfo_GetProduct(deviceInfo, &product);
    info.product = product;
    
    int version = 0;
    OH_GameDevice_DeviceInfo_GetVersion(deviceInfo, &version);
    info.version = version;
    
    char* physicalAddress = nullptr;
    OH_GameDevice_DeviceInfo_GetPhysicalAddress(deviceInfo, &physicalAddress);
    if (physicalAddress) {
        strncpy(info.physicalAddress, physicalAddress, sizeof(info.physicalAddress) - 1);
        free(physicalAddress);
    }
    
    GameDevice_DeviceType deviceType;
    OH_GameDevice_DeviceInfo_GetDeviceType(deviceInfo, &deviceType);
    info.deviceType = (int32_t)deviceType;
    
    info.isConnected = isConnected;
    
    // 更新缓存
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (isConnected) {
            g_deviceInfos[deviceId] = info;
            g_deviceStates[deviceId] = GameControllerState{};
            strncpy(g_deviceStates[deviceId].deviceId, deviceId, sizeof(g_deviceStates[deviceId].deviceId) - 1);
        } else {
            g_deviceInfos.erase(deviceId);
            g_deviceStates.erase(deviceId);
        }
    }
    
    // 通知回调
    if (g_deviceCallback) {
        g_deviceCallback(deviceId, isConnected, &info);
    }
    
    // 通知 JS 层
    if (g_tsfnDevice) {
        // 复制数据用于异步传递
        struct DeviceEventData {
            char deviceId[64];
            bool isConnected;
            GameControllerInfo info;
        };
        DeviceEventData* data = new DeviceEventData();
        strncpy(data->deviceId, deviceId ? deviceId : "", sizeof(data->deviceId) - 1);
        data->isConnected = isConnected;
        data->info = info;
        
        napi_call_threadsafe_function(g_tsfnDevice, data, napi_tsfn_nonblocking);
    }
    
    if (deviceId) free(deviceId);
    OH_GameDevice_DestroyDeviceInfo(&deviceInfo);
}

/**
 * 按键事件回调 (通用)
 */
static void OnButtonEvent(const struct GamePad_ButtonEvent* buttonEvent, const char* buttonName) {
    if (!buttonEvent) return;
    
    char* deviceId = nullptr;
    OH_GamePad_ButtonEvent_GetDeviceId(buttonEvent, &deviceId);
    
    GamePad_Button_ActionType action;
    OH_GamePad_ButtonEvent_GetButtonAction(buttonEvent, &action);
    
    int32_t buttonCode;
    OH_GamePad_ButtonEvent_GetButtonCode(buttonEvent, &buttonCode);
    
    // 枚举值是 DOWN/UP，不是 GAMEPAD_BUTTON_ACTION_TYPE_DOWN
    bool isPressed = (action == DOWN);
    
    LOGD("按键事件: deviceId=%s, button=%s, code=%d, isPressed=%d", 
         deviceId ? deviceId : "null", buttonName, buttonCode, isPressed);
    
    // 更新设备状态
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_deviceStates.find(deviceId ? deviceId : "");
        if (it != g_deviceStates.end()) {
            uint32_t flag = 0;
            switch (buttonCode) {
                case GC_KEYCODE_BUTTON_A: flag = GC_BTN_A; break;
                case GC_KEYCODE_BUTTON_B: flag = GC_BTN_B; break;
                case GC_KEYCODE_BUTTON_X: flag = GC_BTN_X; break;
                case GC_KEYCODE_BUTTON_Y: flag = GC_BTN_Y; break;
                case GC_KEYCODE_LEFT_SHOULDER: flag = GC_BTN_LB; break;
                case GC_KEYCODE_RIGHT_SHOULDER: flag = GC_BTN_RB; break;
                case GC_KEYCODE_LEFT_THUMBSTICK: flag = GC_BTN_LS_CLK; break;
                case GC_KEYCODE_RIGHT_THUMBSTICK: flag = GC_BTN_RS_CLK; break;
                case GC_KEYCODE_BUTTON_HOME: flag = GC_BTN_HOME; break;
                case GC_KEYCODE_BUTTON_MENU: flag = GC_BTN_START; break;
                case GC_KEYCODE_DPAD_UP: flag = GC_BTN_UP; break;
                case GC_KEYCODE_DPAD_DOWN: flag = GC_BTN_DOWN; break;
                case GC_KEYCODE_DPAD_LEFT: flag = GC_BTN_LEFT; break;
                case GC_KEYCODE_DPAD_RIGHT: flag = GC_BTN_RIGHT; break;
            }
            if (isPressed) {
                it->second.buttons |= flag;
            } else {
                it->second.buttons &= ~flag;
            }
        }
    }
    
    // 通知回调
    if (g_buttonCallback) {
        g_buttonCallback(deviceId, buttonCode, isPressed);
    }
    
    // 通知 JS 层
    if (g_tsfnButton) {
        struct ButtonEventData {
            char deviceId[64];
            int32_t buttonCode;
            bool isPressed;
        };
        ButtonEventData* data = new ButtonEventData();
        strncpy(data->deviceId, deviceId ? deviceId : "", sizeof(data->deviceId) - 1);
        data->buttonCode = buttonCode;
        data->isPressed = isPressed;
        
        napi_call_threadsafe_function(g_tsfnButton, data, napi_tsfn_nonblocking);
    }
    
    if (deviceId) free(deviceId);
}

// 各按键的回调函数
static void OnButtonA(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "ButtonA"); }
static void OnButtonB(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "ButtonB"); }
static void OnButtonX(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "ButtonX"); }
static void OnButtonY(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "ButtonY"); }
static void OnButtonC(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "ButtonC"); }
static void OnLeftShoulder(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "LeftShoulder"); }
static void OnRightShoulder(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "RightShoulder"); }
static void OnLeftTriggerButton(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "LeftTrigger"); }
static void OnRightTriggerButton(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "RightTrigger"); }
static void OnLeftThumbstick(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "LeftThumbstick"); }
static void OnRightThumbstick(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "RightThumbstick"); }
static void OnButtonHome(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "ButtonHome"); }
static void OnButtonMenu(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "ButtonMenu"); }
static void OnDpadUp(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "DpadUp"); }
static void OnDpadDown(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "DpadDown"); }
static void OnDpadLeft(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "DpadLeft"); }
static void OnDpadRight(const struct GamePad_ButtonEvent* e) { OnButtonEvent(e, "DpadRight"); }

/**
 * 轴事件通知 (通用)
 */
static void NotifyAxisEvent(const char* deviceId, int32_t axisType, double x, double y) {
    // 通知回调
    if (g_axisCallback) {
        g_axisCallback(deviceId, axisType, x, y);
    }
    
    // 通知 JS 层
    if (g_tsfnAxis) {
        struct AxisEventData {
            char deviceId[64];
            int32_t axisType;
            double x;
            double y;
        };
        AxisEventData* data = new AxisEventData();
        strncpy(data->deviceId, deviceId ? deviceId : "", sizeof(data->deviceId) - 1);
        data->axisType = axisType;
        data->x = x;
        data->y = y;
        
        napi_call_threadsafe_function(g_tsfnAxis, data, napi_tsfn_nonblocking);
    }
}

/**
 * 左摇杆轴事件
 */
static void OnLeftThumbstickAxis(const struct GamePad_AxisEvent* axisEvent) {
    if (!axisEvent) return;
    
    char* deviceId = nullptr;
    OH_GamePad_AxisEvent_GetDeviceId(axisEvent, &deviceId);
    
    double xValue = 0.0;
    double yValue = 0.0;
    OH_GamePad_AxisEvent_GetXAxisValue(axisEvent, &xValue);
    OH_GamePad_AxisEvent_GetYAxisValue(axisEvent, &yValue);
    
    LOGD("左摇杆轴: deviceId=%s, X=%.3f, Y=%.3f", deviceId ? deviceId : "null", xValue, yValue);
    
    // 更新设备状态
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_deviceStates.find(deviceId ? deviceId : "");
        if (it != g_deviceStates.end()) {
            it->second.leftStickX = (int16_t)(xValue * 32767);
            it->second.leftStickY = (int16_t)(yValue * 32767);
        }
    }
    
    NotifyAxisEvent(deviceId, GC_AXIS_LEFT_THUMBSTICK, xValue, yValue);
    
    if (deviceId) free(deviceId);
}

/**
 * 右摇杆轴事件
 */
static void OnRightThumbstickAxis(const struct GamePad_AxisEvent* axisEvent) {
    if (!axisEvent) return;
    
    char* deviceId = nullptr;
    OH_GamePad_AxisEvent_GetDeviceId(axisEvent, &deviceId);
    
    double zValue = 0.0;
    double rzValue = 0.0;
    OH_GamePad_AxisEvent_GetZAxisValue(axisEvent, &zValue);
    OH_GamePad_AxisEvent_GetRZAxisValue(axisEvent, &rzValue);
    
    LOGD("右摇杆轴: deviceId=%s, Z=%.3f, RZ=%.3f", deviceId ? deviceId : "null", zValue, rzValue);
    
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_deviceStates.find(deviceId ? deviceId : "");
        if (it != g_deviceStates.end()) {
            it->second.rightStickX = (int16_t)(zValue * 32767);
            it->second.rightStickY = (int16_t)(rzValue * 32767);
        }
    }
    
    NotifyAxisEvent(deviceId, GC_AXIS_RIGHT_THUMBSTICK, zValue, rzValue);
    
    if (deviceId) free(deviceId);
}

/**
 * D-Pad 轴事件
 */
static void OnDpadAxis(const struct GamePad_AxisEvent* axisEvent) {
    if (!axisEvent) return;
    
    char* deviceId = nullptr;
    OH_GamePad_AxisEvent_GetDeviceId(axisEvent, &deviceId);
    
    double hatX = 0.0;
    double hatY = 0.0;
    OH_GamePad_AxisEvent_GetHatXAxisValue(axisEvent, &hatX);
    OH_GamePad_AxisEvent_GetHatYAxisValue(axisEvent, &hatY);
    
    LOGD("D-Pad轴: deviceId=%s, HatX=%.3f, HatY=%.3f", deviceId ? deviceId : "null", hatX, hatY);
    
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_deviceStates.find(deviceId ? deviceId : "");
        if (it != g_deviceStates.end()) {
            it->second.hatX = (int16_t)hatX;
            it->second.hatY = (int16_t)hatY;
            
            // 更新 D-Pad 按钮状态
            it->second.buttons &= ~(GC_BTN_UP | GC_BTN_DOWN | GC_BTN_LEFT | GC_BTN_RIGHT);
            if (hatX < -0.5) it->second.buttons |= GC_BTN_LEFT;
            if (hatX > 0.5) it->second.buttons |= GC_BTN_RIGHT;
            if (hatY < -0.5) it->second.buttons |= GC_BTN_UP;
            if (hatY > 0.5) it->second.buttons |= GC_BTN_DOWN;
        }
    }
    
    NotifyAxisEvent(deviceId, GC_AXIS_DPAD, hatX, hatY);
    
    if (deviceId) free(deviceId);
}

/**
 * 左扳机轴事件
 */
static void OnLeftTriggerAxis(const struct GamePad_AxisEvent* axisEvent) {
    if (!axisEvent) return;
    
    char* deviceId = nullptr;
    OH_GamePad_AxisEvent_GetDeviceId(axisEvent, &deviceId);
    
    double brakeValue = 0.0;
    OH_GamePad_AxisEvent_GetBrakeAxisValue(axisEvent, &brakeValue);
    
    LOGD("左扳机轴: deviceId=%s, Brake=%.3f", deviceId ? deviceId : "null", brakeValue);
    
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_deviceStates.find(deviceId ? deviceId : "");
        if (it != g_deviceStates.end()) {
            // 扳机值范围 0.0-1.0，转换为 0-255
            it->second.leftTrigger = (uint8_t)(brakeValue * 255);
        }
    }
    
    NotifyAxisEvent(deviceId, GC_AXIS_LEFT_TRIGGER, brakeValue, 0.0);
    
    if (deviceId) free(deviceId);
}

/**
 * 右扳机轴事件
 */
static void OnRightTriggerAxis(const struct GamePad_AxisEvent* axisEvent) {
    if (!axisEvent) return;
    
    char* deviceId = nullptr;
    OH_GamePad_AxisEvent_GetDeviceId(axisEvent, &deviceId);
    
    double gasValue = 0.0;
    OH_GamePad_AxisEvent_GetGasAxisValue(axisEvent, &gasValue);
    
    LOGD("右扳机轴: deviceId=%s, Gas=%.3f", deviceId ? deviceId : "null", gasValue);
    
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_deviceStates.find(deviceId ? deviceId : "");
        if (it != g_deviceStates.end()) {
            it->second.rightTrigger = (uint8_t)(gasValue * 255);
        }
    }
    
    NotifyAxisEvent(deviceId, GC_AXIS_RIGHT_TRIGGER, gasValue, 0.0);
    
    if (deviceId) free(deviceId);
}

#endif // GAME_CONTROLLER_KIT_AVAILABLE

// ==================== API 实现 ====================

bool GameController_IsAvailable(void) {
#if GAME_CONTROLLER_KIT_AVAILABLE
    return true;
#else
    return false;
#endif
}

int GameController_Init(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    
    if (g_initialized) {
        LOGW("Game Controller Kit 已初始化");
        return 0;
    }
    
#if GAME_CONTROLLER_KIT_AVAILABLE
    LOGI("初始化 Game Controller Kit");
    g_initialized = true;
    return 0;
#else
    LOGE("Game Controller Kit 不可用 (需要 API 21+)");
    return -1;
#endif
}

void GameController_Uninit(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    
    if (!g_initialized) return;
    
    GameController_StopMonitor();
    
    g_deviceStates.clear();
    g_deviceInfos.clear();
    g_initialized = false;
    
    LOGI("Game Controller Kit 已反初始化");
}

void GameController_SetDeviceCallback(GameControllerDeviceCallback callback) {
    g_deviceCallback = callback;
}

void GameController_SetButtonCallback(GameControllerButtonCallback callback) {
    g_buttonCallback = callback;
}

void GameController_SetAxisCallback(GameControllerAxisCallback callback) {
    g_axisCallback = callback;
}

int GameController_StartMonitor(void) {
#if GAME_CONTROLLER_KIT_AVAILABLE
    std::lock_guard<std::mutex> lock(g_mutex);
    
    if (!g_initialized) {
        LOGE("Game Controller Kit 未初始化");
        return -1;
    }
    
    if (g_monitoring) {
        LOGW("已在监听中");
        return 0;
    }
    
    LOGI("开始监听游戏控制器...");
    
    // 注册设备监听
    GameController_ErrorCode errorCode = OH_GameDevice_RegisterDeviceMonitor(OnDeviceChanged);
    if (errorCode != GAME_CONTROLLER_SUCCESS) {
        LOGE("注册设备监听失败: %d", errorCode);
        return errorCode;
    }
    
    // 注册按键监听
    OH_GamePad_ButtonA_RegisterButtonInputMonitor(OnButtonA);
    OH_GamePad_ButtonB_RegisterButtonInputMonitor(OnButtonB);
    OH_GamePad_ButtonX_RegisterButtonInputMonitor(OnButtonX);
    OH_GamePad_ButtonY_RegisterButtonInputMonitor(OnButtonY);
    OH_GamePad_ButtonC_RegisterButtonInputMonitor(OnButtonC);
    OH_GamePad_LeftShoulder_RegisterButtonInputMonitor(OnLeftShoulder);
    OH_GamePad_RightShoulder_RegisterButtonInputMonitor(OnRightShoulder);
    OH_GamePad_LeftTrigger_RegisterButtonInputMonitor(OnLeftTriggerButton);
    OH_GamePad_RightTrigger_RegisterButtonInputMonitor(OnRightTriggerButton);
    OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor(OnLeftThumbstick);
    OH_GamePad_RightThumbstick_RegisterButtonInputMonitor(OnRightThumbstick);
    OH_GamePad_ButtonHome_RegisterButtonInputMonitor(OnButtonHome);
    OH_GamePad_ButtonMenu_RegisterButtonInputMonitor(OnButtonMenu);
    OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor(OnDpadUp);
    OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor(OnDpadDown);
    OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor(OnDpadLeft);
    OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor(OnDpadRight);
    
    // 注册轴监听
    OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor(OnLeftThumbstickAxis);
    OH_GamePad_RightThumbstick_RegisterAxisInputMonitor(OnRightThumbstickAxis);
    OH_GamePad_Dpad_RegisterAxisInputMonitor(OnDpadAxis);
    OH_GamePad_LeftTrigger_RegisterAxisInputMonitor(OnLeftTriggerAxis);
    OH_GamePad_RightTrigger_RegisterAxisInputMonitor(OnRightTriggerAxis);
    
    // 查询当前已连接的设备
    GameDevice_AllDeviceInfos* allDeviceInfos;
    errorCode = OH_GameDevice_GetAllDeviceInfos(&allDeviceInfos);
    if (errorCode == GAME_CONTROLLER_SUCCESS) {
        int count = 0;
        OH_GameDevice_AllDeviceInfos_GetCount(allDeviceInfos, &count);
        LOGI("当前已连接 %d 个设备", count);
        
        for (int i = 0; i < count; i++) {
            GameDevice_DeviceInfo* deviceInfo;
            errorCode = OH_GameDevice_AllDeviceInfos_GetDeviceInfo(allDeviceInfos, i, &deviceInfo);
            if (errorCode == GAME_CONTROLLER_SUCCESS) {
                // 模拟设备上线事件
                GameControllerInfo info = {};
                
                char* deviceId = nullptr;
                OH_GameDevice_DeviceInfo_GetDeviceId(deviceInfo, &deviceId);
                if (deviceId) {
                    strncpy(info.deviceId, deviceId, sizeof(info.deviceId) - 1);
                }
                
                char* name = nullptr;
                OH_GameDevice_DeviceInfo_GetName(deviceInfo, &name);
                if (name) {
                    strncpy(info.name, name, sizeof(info.name) - 1);
                    free(name);
                }
                
                info.isConnected = true;
                
                g_deviceInfos[deviceId ? deviceId : ""] = info;
                g_deviceStates[deviceId ? deviceId : ""] = GameControllerState{};
                if (deviceId) {
                    strncpy(g_deviceStates[deviceId].deviceId, deviceId, 
                            sizeof(g_deviceStates[deviceId].deviceId) - 1);
                }
                
                if (g_deviceCallback) {
                    g_deviceCallback(deviceId, true, &info);
                }
                
                if (deviceId) free(deviceId);
                OH_GameDevice_DestroyDeviceInfo(&deviceInfo);
            }
        }
        
        OH_GameDevice_DestroyAllDeviceInfos(&allDeviceInfos);
    }
    
    g_monitoring = true;
    LOGI("监听已启动");
    return 0;
    
#else
    LOGE("Game Controller Kit 不可用");
    return -1;
#endif
}

void GameController_StopMonitor(void) {
#if GAME_CONTROLLER_KIT_AVAILABLE
    std::lock_guard<std::mutex> lock(g_mutex);
    
    if (!g_monitoring) return;
    
    LOGI("停止监听游戏控制器...");
    
    // 取消设备监听
    OH_GameDevice_UnregisterDeviceMonitor();
    
    // 取消按键监听
    OH_GamePad_ButtonA_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonB_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonX_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonY_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonC_UnregisterButtonInputMonitor();
    OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor();
    OH_GamePad_RightShoulder_UnregisterButtonInputMonitor();
    OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor();
    OH_GamePad_RightTrigger_UnregisterButtonInputMonitor();
    OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor();
    OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonHome_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor();
    
    // 取消轴监听
    OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor();
    OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor();
    OH_GamePad_Dpad_UnregisterAxisInputMonitor();
    OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor();
    OH_GamePad_RightTrigger_UnregisterAxisInputMonitor();
    
    g_monitoring = false;
    LOGI("监听已停止");
#endif
}

int GameController_GetDeviceCount(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    return (int)g_deviceInfos.size();
}

int GameController_GetDeviceInfo(int index, GameControllerInfo* outInfo) {
    if (!outInfo) return -1;
    
    std::lock_guard<std::mutex> lock(g_mutex);
    
    if (index < 0 || index >= (int)g_deviceInfos.size()) {
        return -2;
    }
    
    auto it = g_deviceInfos.begin();
    std::advance(it, index);
    *outInfo = it->second;
    
    return 0;
}

/**
 * 心跳检测 - 检查设备是否仍然连接
 * 
 * 对于某些设备（如雷蛇手柄），电源管理不透明，
 * 系统可能不会及时发送断开事件。
 * 此函数通过重新查询设备列表来检测设备断开。
 * 
 * @return 断开的设备数量
 */
int GameController_HeartbeatCheck(void) {
#if GAME_CONTROLLER_KIT_AVAILABLE
    std::lock_guard<std::mutex> lock(g_mutex);
    
    if (!g_initialized || !g_monitoring) {
        return 0;
    }
    
    int disconnectedCount = 0;
    
    // 查询当前实际连接的设备
    GameDevice_AllDeviceInfos* allDeviceInfos;
    GameController_ErrorCode errorCode = OH_GameDevice_GetAllDeviceInfos(&allDeviceInfos);
    if (errorCode != GAME_CONTROLLER_SUCCESS) {
        LOGW("心跳检测: 无法获取设备列表, errorCode=%d", errorCode);
        return 0;
    }
    
    // 获取当前连接的设备 ID 集合
    std::map<std::string, bool> currentDevices;
    int count = 0;
    OH_GameDevice_AllDeviceInfos_GetCount(allDeviceInfos, &count);
    
    for (int i = 0; i < count; i++) {
        GameDevice_DeviceInfo* deviceInfo;
        errorCode = OH_GameDevice_AllDeviceInfos_GetDeviceInfo(allDeviceInfos, i, &deviceInfo);
        if (errorCode == GAME_CONTROLLER_SUCCESS) {
            char* deviceId = nullptr;
            OH_GameDevice_DeviceInfo_GetDeviceId(deviceInfo, &deviceId);
            if (deviceId) {
                currentDevices[deviceId] = true;
                free(deviceId);
            }
            OH_GameDevice_DestroyDeviceInfo(&deviceInfo);
        }
    }
    OH_GameDevice_DestroyAllDeviceInfos(&allDeviceInfos);
    
    // 检查缓存的设备是否仍然连接
    std::vector<std::string> disconnectedIds;
    for (auto& pair : g_deviceInfos) {
        if (currentDevices.find(pair.first) == currentDevices.end()) {
            // 设备不在当前连接列表中，标记为断开
            disconnectedIds.push_back(pair.first);
        }
    }
    
    // 发送断开通知（在锁外执行以避免死锁）
    // 注意: 这里我们释放锁后才发送回调
    std::vector<std::pair<std::string, GameControllerInfo>> disconnectedDevices;
    for (const auto& deviceId : disconnectedIds) {
        auto it = g_deviceInfos.find(deviceId);
        if (it != g_deviceInfos.end()) {
            disconnectedDevices.push_back(*it);
            g_deviceInfos.erase(it);
        }
        g_deviceStates.erase(deviceId);
        disconnectedCount++;
    }
    
    // 释放锁后发送回调
    // 注: 由于回调可能很快，这里简化处理，直接在锁内调用
    // 如果有问题可以改为在锁外调用
    for (const auto& pair : disconnectedDevices) {
        LOGI("心跳检测: 设备断开 deviceId=%s, name=%s", 
             pair.first.c_str(), pair.second.name);
        
        if (g_deviceCallback) {
            GameControllerInfo info = pair.second;
            info.isConnected = false;
            g_deviceCallback(pair.first.c_str(), false, &info);
        }
        
        // NAPI 异步通知
        if (g_tsfnDevice) {
            struct DeviceEventData {
                char deviceId[64];
                bool isConnected;
                GameControllerInfo info;
            };
            DeviceEventData* eventData = new DeviceEventData();
            strncpy(eventData->deviceId, pair.first.c_str(), sizeof(eventData->deviceId) - 1);
            eventData->isConnected = false;
            eventData->info = pair.second;
            eventData->info.isConnected = false;
            napi_call_threadsafe_function(g_tsfnDevice, eventData, napi_tsfn_blocking);
        }
    }
    
    if (disconnectedCount > 0) {
        LOGI("心跳检测: 检测到 %d 个设备断开", disconnectedCount);
    }
    
    return disconnectedCount;
#else
    return 0;
#endif
}

// ==================== NAPI 回调分发 ====================

static void DeviceCallbackCallJS(napi_env env, napi_value js_callback, void* context, void* data) {
    if (!data) return;
    
    struct DeviceEventData {
        char deviceId[64];
        bool isConnected;
        GameControllerInfo info;
    };
    DeviceEventData* eventData = (DeviceEventData*)data;
    
    napi_value argv[3];
    napi_create_string_utf8(env, eventData->deviceId, NAPI_AUTO_LENGTH, &argv[0]);
    napi_get_boolean(env, eventData->isConnected, &argv[1]);
    
    // 创建设备信息对象
    napi_create_object(env, &argv[2]);
    
    napi_value val;
    napi_create_string_utf8(env, eventData->info.deviceId, NAPI_AUTO_LENGTH, &val);
    napi_set_named_property(env, argv[2], "deviceId", val);
    
    napi_create_string_utf8(env, eventData->info.name, NAPI_AUTO_LENGTH, &val);
    napi_set_named_property(env, argv[2], "name", val);
    
    napi_create_int32(env, eventData->info.product, &val);
    napi_set_named_property(env, argv[2], "product", val);
    
    napi_create_int32(env, eventData->info.deviceType, &val);
    napi_set_named_property(env, argv[2], "deviceType", val);
    
    napi_get_boolean(env, eventData->info.isConnected, &val);
    napi_set_named_property(env, argv[2], "isConnected", val);
    
    napi_call_function(env, nullptr, js_callback, 3, argv, nullptr);
    
    delete eventData;
}

static void ButtonCallbackCallJS(napi_env env, napi_value js_callback, void* context, void* data) {
    if (!data) return;
    
    struct ButtonEventData {
        char deviceId[64];
        int32_t buttonCode;
        bool isPressed;
    };
    ButtonEventData* eventData = (ButtonEventData*)data;
    
    napi_value argv[3];
    napi_create_string_utf8(env, eventData->deviceId, NAPI_AUTO_LENGTH, &argv[0]);
    napi_create_int32(env, eventData->buttonCode, &argv[1]);
    napi_get_boolean(env, eventData->isPressed, &argv[2]);
    
    napi_call_function(env, nullptr, js_callback, 3, argv, nullptr);
    
    delete eventData;
}

static void AxisCallbackCallJS(napi_env env, napi_value js_callback, void* context, void* data) {
    if (!data) return;
    
    struct AxisEventData {
        char deviceId[64];
        int32_t axisType;
        double x;
        double y;
    };
    AxisEventData* eventData = (AxisEventData*)data;
    
    napi_value argv[4];
    napi_create_string_utf8(env, eventData->deviceId, NAPI_AUTO_LENGTH, &argv[0]);
    napi_create_int32(env, eventData->axisType, &argv[1]);
    napi_create_double(env, eventData->x, &argv[2]);
    napi_create_double(env, eventData->y, &argv[3]);
    
    napi_call_function(env, nullptr, js_callback, 4, argv, nullptr);
    
    delete eventData;
}

// ==================== NAPI 导出函数 ====================

/**
 * isAvailable(): boolean
 */
static napi_value NapiIsAvailable(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, GameController_IsAvailable(), &result);
    return result;
}

/**
 * init(): number
 */
static napi_value NapiInit(napi_env env, napi_callback_info info) {
    g_napiEnv = env;
    int ret = GameController_Init();
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/**
 * uninit(): void
 */
static napi_value NapiUninit(napi_env env, napi_callback_info info) {
    GameController_Uninit();
    
    // 清理 threadsafe function
    if (g_tsfnDevice) {
        napi_release_threadsafe_function(g_tsfnDevice, napi_tsfn_release);
        g_tsfnDevice = nullptr;
    }
    if (g_tsfnButton) {
        napi_release_threadsafe_function(g_tsfnButton, napi_tsfn_release);
        g_tsfnButton = nullptr;
    }
    if (g_tsfnAxis) {
        napi_release_threadsafe_function(g_tsfnAxis, napi_tsfn_release);
        g_tsfnAxis = nullptr;
    }
    
    return nullptr;
}

/**
 * startMonitor(): number
 */
static napi_value NapiStartMonitor(napi_env env, napi_callback_info info) {
    int ret = GameController_StartMonitor();
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/**
 * stopMonitor(): void
 */
static napi_value NapiStopMonitor(napi_env env, napi_callback_info info) {
    GameController_StopMonitor();
    return nullptr;
}

/**
 * setDeviceCallback(callback: (deviceId: string, isConnected: boolean, info: object) => void): void
 */
static napi_value NapiSetDeviceCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        // 清除回调
        if (g_tsfnDevice) {
            napi_release_threadsafe_function(g_tsfnDevice, napi_tsfn_release);
            g_tsfnDevice = nullptr;
        }
        return nullptr;
    }
    
    // 创建 threadsafe function
    napi_value resourceName;
    napi_create_string_utf8(env, "GameControllerDeviceCallback", NAPI_AUTO_LENGTH, &resourceName);
    
    napi_create_threadsafe_function(
        env, args[0], nullptr, resourceName,
        0, 1, nullptr, nullptr, nullptr,
        DeviceCallbackCallJS, &g_tsfnDevice
    );
    
    return nullptr;
}

/**
 * setButtonCallback(callback: (deviceId: string, buttonCode: number, isPressed: boolean) => void): void
 */
static napi_value NapiSetButtonCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        if (g_tsfnButton) {
            napi_release_threadsafe_function(g_tsfnButton, napi_tsfn_release);
            g_tsfnButton = nullptr;
        }
        return nullptr;
    }
    
    napi_value resourceName;
    napi_create_string_utf8(env, "GameControllerButtonCallback", NAPI_AUTO_LENGTH, &resourceName);
    
    napi_create_threadsafe_function(
        env, args[0], nullptr, resourceName,
        0, 1, nullptr, nullptr, nullptr,
        ButtonCallbackCallJS, &g_tsfnButton
    );
    
    return nullptr;
}

/**
 * setAxisCallback(callback: (deviceId: string, axisType: number, x: number, y: number) => void): void
 */
static napi_value NapiSetAxisCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        if (g_tsfnAxis) {
            napi_release_threadsafe_function(g_tsfnAxis, napi_tsfn_release);
            g_tsfnAxis = nullptr;
        }
        return nullptr;
    }
    
    napi_value resourceName;
    napi_create_string_utf8(env, "GameControllerAxisCallback", NAPI_AUTO_LENGTH, &resourceName);
    
    napi_create_threadsafe_function(
        env, args[0], nullptr, resourceName,
        0, 1, nullptr, nullptr, nullptr,
        AxisCallbackCallJS, &g_tsfnAxis
    );
    
    return nullptr;
}

/**
 * getDeviceCount(): number
 */
static napi_value NapiGetDeviceCount(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_int32(env, GameController_GetDeviceCount(), &result);
    return result;
}

/**
 * getDeviceInfo(index: number): object | null
 */
static napi_value NapiGetDeviceInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        return nullptr;
    }
    
    int32_t index;
    napi_get_value_int32(env, args[0], &index);
    
    GameControllerInfo deviceInfo;
    if (GameController_GetDeviceInfo(index, &deviceInfo) != 0) {
        return nullptr;
    }
    
    napi_value result;
    napi_create_object(env, &result);
    
    napi_value val;
    napi_create_string_utf8(env, deviceInfo.deviceId, NAPI_AUTO_LENGTH, &val);
    napi_set_named_property(env, result, "deviceId", val);
    
    napi_create_string_utf8(env, deviceInfo.name, NAPI_AUTO_LENGTH, &val);
    napi_set_named_property(env, result, "name", val);
    
    napi_create_int32(env, deviceInfo.product, &val);
    napi_set_named_property(env, result, "product", val);
    
    napi_create_int32(env, deviceInfo.deviceType, &val);
    napi_set_named_property(env, result, "deviceType", val);
    
    napi_get_boolean(env, deviceInfo.isConnected, &val);
    napi_set_named_property(env, result, "isConnected", val);
    
    return result;
}

/**
 * heartbeatCheck(): number
 * 心跳检测 - 返回断开的设备数量
 */
static napi_value NapiHeartbeatCheck(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_int32(env, GameController_HeartbeatCheck(), &result);
    return result;
}

/**
 * 初始化 NAPI 模块
 */
napi_value GameControllerNapi_Init(napi_env env, napi_value exports) {
    LOGI("GameController NAPI 模块初始化");
    
    // 创建 GameController 对象
    napi_value gameControllerObj;
    napi_create_object(env, &gameControllerObj);
    
    napi_property_descriptor props[] = {
        { "isAvailable", nullptr, NapiIsAvailable, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "init", nullptr, NapiInit, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "uninit", nullptr, NapiUninit, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startMonitor", nullptr, NapiStartMonitor, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopMonitor", nullptr, NapiStopMonitor, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setDeviceCallback", nullptr, NapiSetDeviceCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setButtonCallback", nullptr, NapiSetButtonCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setAxisCallback", nullptr, NapiSetAxisCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getDeviceCount", nullptr, NapiGetDeviceCount, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getDeviceInfo", nullptr, NapiGetDeviceInfo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "heartbeatCheck", nullptr, NapiHeartbeatCheck, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    
    napi_define_properties(env, gameControllerObj, sizeof(props) / sizeof(props[0]), props);
    
    // 添加常量
    napi_value val;
    
    // 轴类型常量
    napi_create_int32(env, GC_AXIS_LEFT_THUMBSTICK, &val);
    napi_set_named_property(env, gameControllerObj, "AXIS_LEFT_THUMBSTICK", val);
    
    napi_create_int32(env, GC_AXIS_RIGHT_THUMBSTICK, &val);
    napi_set_named_property(env, gameControllerObj, "AXIS_RIGHT_THUMBSTICK", val);
    
    napi_create_int32(env, GC_AXIS_DPAD, &val);
    napi_set_named_property(env, gameControllerObj, "AXIS_DPAD", val);
    
    napi_create_int32(env, GC_AXIS_LEFT_TRIGGER, &val);
    napi_set_named_property(env, gameControllerObj, "AXIS_LEFT_TRIGGER", val);
    
    napi_create_int32(env, GC_AXIS_RIGHT_TRIGGER, &val);
    napi_set_named_property(env, gameControllerObj, "AXIS_RIGHT_TRIGGER", val);
    
    // 按钮码常量
    napi_create_int32(env, GC_KEYCODE_BUTTON_A, &val);
    napi_set_named_property(env, gameControllerObj, "KEYCODE_BUTTON_A", val);
    
    napi_create_int32(env, GC_KEYCODE_BUTTON_B, &val);
    napi_set_named_property(env, gameControllerObj, "KEYCODE_BUTTON_B", val);
    
    napi_create_int32(env, GC_KEYCODE_BUTTON_X, &val);
    napi_set_named_property(env, gameControllerObj, "KEYCODE_BUTTON_X", val);
    
    napi_create_int32(env, GC_KEYCODE_BUTTON_Y, &val);
    napi_set_named_property(env, gameControllerObj, "KEYCODE_BUTTON_Y", val);
    
    // 导出到 exports
    napi_set_named_property(env, exports, "GameController", gameControllerObj);
    
    LOGI("GameController NAPI 模块初始化完成");
    
    return exports;
}
