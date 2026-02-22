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
#include <dlfcn.h>

// 尝试包含 Game Controller Kit 头文件 (仅用于类型定义)
// 注意：这些头文件在 API 21+ 可用
#if defined(__OHOS__)
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

// ==================== 动态加载 Game Controller Kit ====================
// libohgame_controller.z.so 不存在于所有设备 (如 HarmonyOS 5.0.5 Mate 60)
// 从 CMake 移除硬链接依赖，改为运行时 dlopen + dlsym
// 所有 OH_Game* 函数通过函数指针调用，避免未解析符号导致 native 模块加载失败

#if GAME_CONTROLLER_KIT_AVAILABLE

// Step 1: 使用 decltype 从 SDK 头文件声明中获取函数指针类型，并声明静态函数指针变量
// decltype 是不求值上下文，不会产生对原始函数符号的引用
#define DECLARE_FUNC_PTR(name) \
    using PFN_##name = decltype(&name); \
    static PFN_##name pfn_##name = nullptr;

// DeviceEvent 查询函数
DECLARE_FUNC_PTR(OH_GameDevice_DeviceEvent_GetChangedType)
DECLARE_FUNC_PTR(OH_GameDevice_DeviceEvent_GetDeviceInfo)
DECLARE_FUNC_PTR(OH_GameDevice_DeviceInfo_GetDeviceId)
DECLARE_FUNC_PTR(OH_GameDevice_DeviceInfo_GetName)
DECLARE_FUNC_PTR(OH_GameDevice_DeviceInfo_GetProduct)
DECLARE_FUNC_PTR(OH_GameDevice_DeviceInfo_GetVersion)
DECLARE_FUNC_PTR(OH_GameDevice_DeviceInfo_GetPhysicalAddress)
DECLARE_FUNC_PTR(OH_GameDevice_DeviceInfo_GetDeviceType)
DECLARE_FUNC_PTR(OH_GameDevice_DestroyDeviceInfo)

// ButtonEvent 查询函数
DECLARE_FUNC_PTR(OH_GamePad_ButtonEvent_GetDeviceId)
DECLARE_FUNC_PTR(OH_GamePad_ButtonEvent_GetButtonAction)
DECLARE_FUNC_PTR(OH_GamePad_ButtonEvent_GetButtonCode)

// AxisEvent 查询函数
DECLARE_FUNC_PTR(OH_GamePad_AxisEvent_GetDeviceId)
DECLARE_FUNC_PTR(OH_GamePad_AxisEvent_GetXAxisValue)
DECLARE_FUNC_PTR(OH_GamePad_AxisEvent_GetYAxisValue)
DECLARE_FUNC_PTR(OH_GamePad_AxisEvent_GetZAxisValue)
DECLARE_FUNC_PTR(OH_GamePad_AxisEvent_GetRZAxisValue)
DECLARE_FUNC_PTR(OH_GamePad_AxisEvent_GetHatXAxisValue)
DECLARE_FUNC_PTR(OH_GamePad_AxisEvent_GetHatYAxisValue)
DECLARE_FUNC_PTR(OH_GamePad_AxisEvent_GetBrakeAxisValue)
DECLARE_FUNC_PTR(OH_GamePad_AxisEvent_GetGasAxisValue)

// 设备监听注册/注销
DECLARE_FUNC_PTR(OH_GameDevice_RegisterDeviceMonitor)
DECLARE_FUNC_PTR(OH_GameDevice_UnregisterDeviceMonitor)

// 按键监听注册
DECLARE_FUNC_PTR(OH_GamePad_ButtonA_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonB_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonX_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonY_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonC_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_LeftShoulder_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_RightShoulder_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_LeftTrigger_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_RightTrigger_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_RightThumbstick_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonHome_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonMenu_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor)

// 轴监听注册
DECLARE_FUNC_PTR(OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_RightThumbstick_RegisterAxisInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_Dpad_RegisterAxisInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_LeftTrigger_RegisterAxisInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_RightTrigger_RegisterAxisInputMonitor)

// 按键监听注销
DECLARE_FUNC_PTR(OH_GamePad_ButtonA_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonB_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonX_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonY_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonC_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_RightShoulder_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_RightTrigger_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonHome_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor)

// 轴监听注销
DECLARE_FUNC_PTR(OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_Dpad_UnregisterAxisInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor)
DECLARE_FUNC_PTR(OH_GamePad_RightTrigger_UnregisterAxisInputMonitor)

// 全设备查询
DECLARE_FUNC_PTR(OH_GameDevice_GetAllDeviceInfos)
DECLARE_FUNC_PTR(OH_GameDevice_AllDeviceInfos_GetCount)
DECLARE_FUNC_PTR(OH_GameDevice_AllDeviceInfos_GetDeviceInfo)
DECLARE_FUNC_PTR(OH_GameDevice_DestroyAllDeviceInfos)

#undef DECLARE_FUNC_PTR

// Step 2: 宏重定向 - 将所有 OH_Game* 函数调用重定向为函数指针调用
// 代码中的直接函数调用 OH_Xxx() 将被预处理器展开为 pfn_OH_Xxx()
#define OH_GameDevice_DeviceEvent_GetChangedType pfn_OH_GameDevice_DeviceEvent_GetChangedType
#define OH_GameDevice_DeviceEvent_GetDeviceInfo pfn_OH_GameDevice_DeviceEvent_GetDeviceInfo
#define OH_GameDevice_DeviceInfo_GetDeviceId pfn_OH_GameDevice_DeviceInfo_GetDeviceId
#define OH_GameDevice_DeviceInfo_GetName pfn_OH_GameDevice_DeviceInfo_GetName
#define OH_GameDevice_DeviceInfo_GetProduct pfn_OH_GameDevice_DeviceInfo_GetProduct
#define OH_GameDevice_DeviceInfo_GetVersion pfn_OH_GameDevice_DeviceInfo_GetVersion
#define OH_GameDevice_DeviceInfo_GetPhysicalAddress pfn_OH_GameDevice_DeviceInfo_GetPhysicalAddress
#define OH_GameDevice_DeviceInfo_GetDeviceType pfn_OH_GameDevice_DeviceInfo_GetDeviceType
#define OH_GameDevice_DestroyDeviceInfo pfn_OH_GameDevice_DestroyDeviceInfo
#define OH_GamePad_ButtonEvent_GetDeviceId pfn_OH_GamePad_ButtonEvent_GetDeviceId
#define OH_GamePad_ButtonEvent_GetButtonAction pfn_OH_GamePad_ButtonEvent_GetButtonAction
#define OH_GamePad_ButtonEvent_GetButtonCode pfn_OH_GamePad_ButtonEvent_GetButtonCode
#define OH_GamePad_AxisEvent_GetDeviceId pfn_OH_GamePad_AxisEvent_GetDeviceId
#define OH_GamePad_AxisEvent_GetXAxisValue pfn_OH_GamePad_AxisEvent_GetXAxisValue
#define OH_GamePad_AxisEvent_GetYAxisValue pfn_OH_GamePad_AxisEvent_GetYAxisValue
#define OH_GamePad_AxisEvent_GetZAxisValue pfn_OH_GamePad_AxisEvent_GetZAxisValue
#define OH_GamePad_AxisEvent_GetRZAxisValue pfn_OH_GamePad_AxisEvent_GetRZAxisValue
#define OH_GamePad_AxisEvent_GetHatXAxisValue pfn_OH_GamePad_AxisEvent_GetHatXAxisValue
#define OH_GamePad_AxisEvent_GetHatYAxisValue pfn_OH_GamePad_AxisEvent_GetHatYAxisValue
#define OH_GamePad_AxisEvent_GetBrakeAxisValue pfn_OH_GamePad_AxisEvent_GetBrakeAxisValue
#define OH_GamePad_AxisEvent_GetGasAxisValue pfn_OH_GamePad_AxisEvent_GetGasAxisValue
#define OH_GameDevice_RegisterDeviceMonitor pfn_OH_GameDevice_RegisterDeviceMonitor
#define OH_GameDevice_UnregisterDeviceMonitor pfn_OH_GameDevice_UnregisterDeviceMonitor
#define OH_GamePad_ButtonA_RegisterButtonInputMonitor pfn_OH_GamePad_ButtonA_RegisterButtonInputMonitor
#define OH_GamePad_ButtonB_RegisterButtonInputMonitor pfn_OH_GamePad_ButtonB_RegisterButtonInputMonitor
#define OH_GamePad_ButtonX_RegisterButtonInputMonitor pfn_OH_GamePad_ButtonX_RegisterButtonInputMonitor
#define OH_GamePad_ButtonY_RegisterButtonInputMonitor pfn_OH_GamePad_ButtonY_RegisterButtonInputMonitor
#define OH_GamePad_ButtonC_RegisterButtonInputMonitor pfn_OH_GamePad_ButtonC_RegisterButtonInputMonitor
#define OH_GamePad_LeftShoulder_RegisterButtonInputMonitor pfn_OH_GamePad_LeftShoulder_RegisterButtonInputMonitor
#define OH_GamePad_RightShoulder_RegisterButtonInputMonitor pfn_OH_GamePad_RightShoulder_RegisterButtonInputMonitor
#define OH_GamePad_LeftTrigger_RegisterButtonInputMonitor pfn_OH_GamePad_LeftTrigger_RegisterButtonInputMonitor
#define OH_GamePad_RightTrigger_RegisterButtonInputMonitor pfn_OH_GamePad_RightTrigger_RegisterButtonInputMonitor
#define OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor pfn_OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor
#define OH_GamePad_RightThumbstick_RegisterButtonInputMonitor pfn_OH_GamePad_RightThumbstick_RegisterButtonInputMonitor
#define OH_GamePad_ButtonHome_RegisterButtonInputMonitor pfn_OH_GamePad_ButtonHome_RegisterButtonInputMonitor
#define OH_GamePad_ButtonMenu_RegisterButtonInputMonitor pfn_OH_GamePad_ButtonMenu_RegisterButtonInputMonitor
#define OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor pfn_OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor
#define OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor pfn_OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor
#define OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor pfn_OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor
#define OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor pfn_OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor
#define OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor pfn_OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor
#define OH_GamePad_RightThumbstick_RegisterAxisInputMonitor pfn_OH_GamePad_RightThumbstick_RegisterAxisInputMonitor
#define OH_GamePad_Dpad_RegisterAxisInputMonitor pfn_OH_GamePad_Dpad_RegisterAxisInputMonitor
#define OH_GamePad_LeftTrigger_RegisterAxisInputMonitor pfn_OH_GamePad_LeftTrigger_RegisterAxisInputMonitor
#define OH_GamePad_RightTrigger_RegisterAxisInputMonitor pfn_OH_GamePad_RightTrigger_RegisterAxisInputMonitor
#define OH_GamePad_ButtonA_UnregisterButtonInputMonitor pfn_OH_GamePad_ButtonA_UnregisterButtonInputMonitor
#define OH_GamePad_ButtonB_UnregisterButtonInputMonitor pfn_OH_GamePad_ButtonB_UnregisterButtonInputMonitor
#define OH_GamePad_ButtonX_UnregisterButtonInputMonitor pfn_OH_GamePad_ButtonX_UnregisterButtonInputMonitor
#define OH_GamePad_ButtonY_UnregisterButtonInputMonitor pfn_OH_GamePad_ButtonY_UnregisterButtonInputMonitor
#define OH_GamePad_ButtonC_UnregisterButtonInputMonitor pfn_OH_GamePad_ButtonC_UnregisterButtonInputMonitor
#define OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor pfn_OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor
#define OH_GamePad_RightShoulder_UnregisterButtonInputMonitor pfn_OH_GamePad_RightShoulder_UnregisterButtonInputMonitor
#define OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor pfn_OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor
#define OH_GamePad_RightTrigger_UnregisterButtonInputMonitor pfn_OH_GamePad_RightTrigger_UnregisterButtonInputMonitor
#define OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor pfn_OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor
#define OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor pfn_OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor
#define OH_GamePad_ButtonHome_UnregisterButtonInputMonitor pfn_OH_GamePad_ButtonHome_UnregisterButtonInputMonitor
#define OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor pfn_OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor
#define OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor pfn_OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor
#define OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor pfn_OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor
#define OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor pfn_OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor
#define OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor pfn_OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor
#define OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor pfn_OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor
#define OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor pfn_OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor
#define OH_GamePad_Dpad_UnregisterAxisInputMonitor pfn_OH_GamePad_Dpad_UnregisterAxisInputMonitor
#define OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor pfn_OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor
#define OH_GamePad_RightTrigger_UnregisterAxisInputMonitor pfn_OH_GamePad_RightTrigger_UnregisterAxisInputMonitor
#define OH_GameDevice_GetAllDeviceInfos pfn_OH_GameDevice_GetAllDeviceInfos
#define OH_GameDevice_AllDeviceInfos_GetCount pfn_OH_GameDevice_AllDeviceInfos_GetCount
#define OH_GameDevice_AllDeviceInfos_GetDeviceInfo pfn_OH_GameDevice_AllDeviceInfos_GetDeviceInfo
#define OH_GameDevice_DestroyAllDeviceInfos pfn_OH_GameDevice_DestroyAllDeviceInfos

#endif // GAME_CONTROLLER_KIT_AVAILABLE

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

// 运行时动态库加载状态
// Game Controller Kit 的 .so 可能不存在于所有设备上 (如 HarmonyOS 5.0.5 Mate 60)
// 使用 dlopen 在运行时按需加载，避免硬依赖导致整个 native 模块加载失败
static void* g_gcLibHandle = nullptr;
static bool g_gcLibAvailable = false;

/**
 * 尝试在运行时加载 Game Controller Kit 动态库
 * 使用 dlopen 加载 .so，然后用 dlsym 获取所有函数指针
 */
static bool TryLoadGameControllerLib() {
    if (g_gcLibHandle) return true;
    
    g_gcLibHandle = dlopen("libohgame_controller.z.so", RTLD_LAZY);
    if (!g_gcLibHandle) {
        LOGW("Game Controller Kit 动态库不可用: %s", dlerror());
        g_gcLibAvailable = false;
        return false;
    }
    
#if GAME_CONTROLLER_KIT_AVAILABLE
    // 使用 dlsym 加载所有函数指针
    // 注意: 函数名在 #define 重定向之前已被宏展开为 pfn_ 前缀
    // 这里使用字符串字面量直接指定原始符号名
    #define LOAD_FUNC(name) pfn_##name = (PFN_##name)dlsym(g_gcLibHandle, #name)
    
    // DeviceEvent 查询函数
    LOAD_FUNC(OH_GameDevice_DeviceEvent_GetChangedType);
    LOAD_FUNC(OH_GameDevice_DeviceEvent_GetDeviceInfo);
    LOAD_FUNC(OH_GameDevice_DeviceInfo_GetDeviceId);
    LOAD_FUNC(OH_GameDevice_DeviceInfo_GetName);
    LOAD_FUNC(OH_GameDevice_DeviceInfo_GetProduct);
    LOAD_FUNC(OH_GameDevice_DeviceInfo_GetVersion);
    LOAD_FUNC(OH_GameDevice_DeviceInfo_GetPhysicalAddress);
    LOAD_FUNC(OH_GameDevice_DeviceInfo_GetDeviceType);
    LOAD_FUNC(OH_GameDevice_DestroyDeviceInfo);
    
    // ButtonEvent 查询函数
    LOAD_FUNC(OH_GamePad_ButtonEvent_GetDeviceId);
    LOAD_FUNC(OH_GamePad_ButtonEvent_GetButtonAction);
    LOAD_FUNC(OH_GamePad_ButtonEvent_GetButtonCode);
    
    // AxisEvent 查询函数
    LOAD_FUNC(OH_GamePad_AxisEvent_GetDeviceId);
    LOAD_FUNC(OH_GamePad_AxisEvent_GetXAxisValue);
    LOAD_FUNC(OH_GamePad_AxisEvent_GetYAxisValue);
    LOAD_FUNC(OH_GamePad_AxisEvent_GetZAxisValue);
    LOAD_FUNC(OH_GamePad_AxisEvent_GetRZAxisValue);
    LOAD_FUNC(OH_GamePad_AxisEvent_GetHatXAxisValue);
    LOAD_FUNC(OH_GamePad_AxisEvent_GetHatYAxisValue);
    LOAD_FUNC(OH_GamePad_AxisEvent_GetBrakeAxisValue);
    LOAD_FUNC(OH_GamePad_AxisEvent_GetGasAxisValue);
    
    // 设备监听注册/注销
    LOAD_FUNC(OH_GameDevice_RegisterDeviceMonitor);
    LOAD_FUNC(OH_GameDevice_UnregisterDeviceMonitor);
    
    // 按键监听注册
    LOAD_FUNC(OH_GamePad_ButtonA_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonB_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonX_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonY_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonC_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_LeftShoulder_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_RightShoulder_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_LeftTrigger_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_RightTrigger_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_RightThumbstick_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonHome_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonMenu_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor);
    
    // 轴监听注册
    LOAD_FUNC(OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor);
    LOAD_FUNC(OH_GamePad_RightThumbstick_RegisterAxisInputMonitor);
    LOAD_FUNC(OH_GamePad_Dpad_RegisterAxisInputMonitor);
    LOAD_FUNC(OH_GamePad_LeftTrigger_RegisterAxisInputMonitor);
    LOAD_FUNC(OH_GamePad_RightTrigger_RegisterAxisInputMonitor);
    
    // 按键监听注销
    LOAD_FUNC(OH_GamePad_ButtonA_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonB_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonX_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonY_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonC_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_RightShoulder_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_RightTrigger_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonHome_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor);
    LOAD_FUNC(OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor);
    
    // 轴监听注销
    LOAD_FUNC(OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor);
    LOAD_FUNC(OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor);
    LOAD_FUNC(OH_GamePad_Dpad_UnregisterAxisInputMonitor);
    LOAD_FUNC(OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor);
    LOAD_FUNC(OH_GamePad_RightTrigger_UnregisterAxisInputMonitor);
    
    // 全设备查询
    LOAD_FUNC(OH_GameDevice_GetAllDeviceInfos);
    LOAD_FUNC(OH_GameDevice_AllDeviceInfos_GetCount);
    LOAD_FUNC(OH_GameDevice_AllDeviceInfos_GetDeviceInfo);
    LOAD_FUNC(OH_GameDevice_DestroyAllDeviceInfos);
    
    #undef LOAD_FUNC
    
    // 验证关键函数是否加载成功
    if (!pfn_OH_GameDevice_RegisterDeviceMonitor) {
        LOGW("Game Controller Kit 核心函数加载失败");
        dlclose(g_gcLibHandle);
        g_gcLibHandle = nullptr;
        g_gcLibAvailable = false;
        return false;
    }
#endif
    
    LOGI("Game Controller Kit 动态库加载成功");
    g_gcLibAvailable = true;
    return true;
}

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
                case GC_KEYCODE_BUTTON_C: flag = GC_BTN_BACK; break;  // ButtonC = Select/Back（鸿蒙无原生 Select 按键）
                case GC_KEYCODE_BUTTON_X: flag = GC_BTN_X; break;
                case GC_KEYCODE_BUTTON_Y: flag = GC_BTN_Y; break;
                case GC_KEYCODE_LEFT_SHOULDER: flag = GC_BTN_LB; break;
                case GC_KEYCODE_RIGHT_SHOULDER: flag = GC_BTN_RB; break;
                case GC_KEYCODE_LEFT_THUMBSTICK: flag = GC_BTN_LS_CLK; break;
                case GC_KEYCODE_RIGHT_THUMBSTICK: flag = GC_BTN_RS_CLK; break;
                case GC_KEYCODE_BUTTON_HOME: flag = GC_BTN_BACK; break;  // GCK 名为 Home，实测为 Select/Back
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
        
        napi_status status = napi_call_threadsafe_function(g_tsfnAxis, data, napi_tsfn_nonblocking);
        if (status != napi_ok) {
            LOGE("napi_call_threadsafe_function(axis) 失败: status=%d", status);
            delete data;
        }
    } else {
        LOGW("NotifyAxisEvent: g_tsfnAxis 为空，轴事件丢失 (axisType=%d)", axisType);
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
    // 编译时头文件可用, 运行时通过 dlopen 检查库是否存在
    // 首次调用时尝试加载，确保在 Init() 之前调用也能正确返回
    if (!g_gcLibHandle) {
        TryLoadGameControllerLib();
    }
    return g_gcLibAvailable;
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
    // 运行时尝试加载动态库
    if (!TryLoadGameControllerLib()) {
        LOGW("Game Controller Kit 动态库不存在，手柄功能将不可用");
        // 标记初始化完成但不可用，不报错 - 这是可选功能
        g_initialized = true;
        return 0;
    }
    
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
    
    if (g_gcLibAvailable) {
        GameController_StopMonitor();
    }
    
    g_deviceStates.clear();
    g_deviceInfos.clear();
    g_initialized = false;
    
    // 关闭动态库
    if (g_gcLibHandle) {
        dlclose(g_gcLibHandle);
        g_gcLibHandle = nullptr;
        g_gcLibAvailable = false;
    }
    
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
    
    if (!g_gcLibAvailable) {
        LOGW("Game Controller Kit 动态库未加载，跳过手柄监听");
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
    // 注意: 此函数可能在 Uninit 的锁内被调用，不要再加锁
    
    if (!g_monitoring) return;
    
    if (!g_gcLibAvailable) {
        g_monitoring = false;
        return;
    }
    
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

int GameController_RefreshDevices(void) {
#if GAME_CONTROLLER_KIT_AVAILABLE
    std::lock_guard<std::mutex> lock(g_mutex);

    if (!g_initialized || !g_gcLibAvailable) {
        LOGW("RefreshDevices: GCK 未初始化或不可用");
        return -1;
    }

    // 查询系统当前连接的设备
    GameDevice_AllDeviceInfos* allDeviceInfos;
    GameController_ErrorCode errorCode = OH_GameDevice_GetAllDeviceInfos(&allDeviceInfos);
    if (errorCode != GAME_CONTROLLER_SUCCESS) {
        LOGW("RefreshDevices: OH_GameDevice_GetAllDeviceInfos 失败, errorCode=%d", errorCode);
        return -1;
    }

    int count = 0;
    OH_GameDevice_AllDeviceInfos_GetCount(allDeviceInfos, &count);
    LOGI("RefreshDevices: 系统报告 %d 个设备", count);

    // 构建当前设备集合
    std::map<std::string, GameControllerInfo> currentDevices;
    for (int i = 0; i < count; i++) {
        GameDevice_DeviceInfo* deviceInfo;
        errorCode = OH_GameDevice_AllDeviceInfos_GetDeviceInfo(allDeviceInfos, i, &deviceInfo);
        if (errorCode != GAME_CONTROLLER_SUCCESS) continue;

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

        info.isConnected = true;

        std::string key = deviceId ? deviceId : "";
        currentDevices[key] = info;

        if (deviceId) free(deviceId);
        OH_GameDevice_DestroyDeviceInfo(&deviceInfo);
    }
    OH_GameDevice_DestroyAllDeviceInfos(&allDeviceInfos);

    // 差异对比：找出新上线的设备
    int newDeviceCount = 0;
    std::vector<std::pair<std::string, GameControllerInfo>> newDevices;
    for (auto& pair : currentDevices) {
        if (g_deviceInfos.find(pair.first) == g_deviceInfos.end()) {
            newDevices.push_back(pair);
            newDeviceCount++;
        }
    }

    // 差异对比：找出消失的设备
    std::vector<std::pair<std::string, GameControllerInfo>> goneDevices;
    for (auto& pair : g_deviceInfos) {
        if (currentDevices.find(pair.first) == currentDevices.end()) {
            goneDevices.push_back(pair);
        }
    }

    // 更新缓存：添加新设备
    for (auto& pair : newDevices) {
        g_deviceInfos[pair.first] = pair.second;
        g_deviceStates[pair.first] = GameControllerState{};
        strncpy(g_deviceStates[pair.first].deviceId, pair.first.c_str(),
                sizeof(g_deviceStates[pair.first].deviceId) - 1);
        LOGI("RefreshDevices: 新设备上线 deviceId=%s, name=%s",
             pair.first.c_str(), pair.second.name);
    }

    // 更新缓存：移除消失的设备
    for (auto& pair : goneDevices) {
        g_deviceInfos.erase(pair.first);
        g_deviceStates.erase(pair.first);
        LOGI("RefreshDevices: 设备离线 deviceId=%s, name=%s",
             pair.first.c_str(), pair.second.name);
    }

    // 发送回调（在锁内，简化处理）
    for (auto& pair : newDevices) {
        if (g_deviceCallback) {
            g_deviceCallback(pair.first.c_str(), true, &pair.second);
        }
        if (g_tsfnDevice) {
            struct DeviceEventData {
                char deviceId[64];
                bool isConnected;
                GameControllerInfo info;
            };
            DeviceEventData* data = new DeviceEventData();
            strncpy(data->deviceId, pair.first.c_str(), sizeof(data->deviceId) - 1);
            data->isConnected = true;
            data->info = pair.second;
            napi_call_threadsafe_function(g_tsfnDevice, data, napi_tsfn_nonblocking);
        }
    }
    for (auto& pair : goneDevices) {
        if (g_deviceCallback) {
            GameControllerInfo info = pair.second;
            info.isConnected = false;
            g_deviceCallback(pair.first.c_str(), false, &info);
        }
        if (g_tsfnDevice) {
            struct DeviceEventData {
                char deviceId[64];
                bool isConnected;
                GameControllerInfo info;
            };
            DeviceEventData* data = new DeviceEventData();
            strncpy(data->deviceId, pair.first.c_str(), sizeof(data->deviceId) - 1);
            data->isConnected = false;
            data->info = pair.second;
            data->info.isConnected = false;
            napi_call_threadsafe_function(g_tsfnDevice, data, napi_tsfn_nonblocking);
        }
    }

    LOGI("RefreshDevices: 新增 %d 个, 移除 %d 个, 当前共 %d 个设备",
         (int)newDevices.size(), (int)goneDevices.size(), (int)g_deviceInfos.size());
    return newDeviceCount;
#else
    return -1;
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
    
    if (!g_initialized || !g_monitoring || !g_gcLibAvailable) {
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

    napi_create_string_utf8(env, eventData->info.physicalAddress, NAPI_AUTO_LENGTH, &val);
    napi_set_named_property(env, argv[2], "physicalAddress", val);
    
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
    
    // 先保存旧的 tsfn，创建新的后再释放旧的，避免 g_tsfnDevice 在并发读取时无效
    napi_threadsafe_function oldTsfn = g_tsfnDevice;
    
    napi_value resourceName;
    napi_create_string_utf8(env, "GameControllerDeviceCallback", NAPI_AUTO_LENGTH, &resourceName);
    
    napi_status status = napi_create_threadsafe_function(
        env, args[0], nullptr, resourceName,
        0, 1, nullptr, nullptr, nullptr,
        DeviceCallbackCallJS, &g_tsfnDevice
    );
    if (status != napi_ok) {
        LOGE("创建 Device threadsafe function 失败: %d", status);
        g_tsfnDevice = oldTsfn;  // 恢复旧的
        return nullptr;
    }
    
    // 释放旧的 threadsafe function，防止资源泄漏
    if (oldTsfn) {
        napi_release_threadsafe_function(oldTsfn, napi_tsfn_release);
    }
    
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
    
    napi_threadsafe_function oldTsfn = g_tsfnButton;
    
    napi_value resourceName;
    napi_create_string_utf8(env, "GameControllerButtonCallback", NAPI_AUTO_LENGTH, &resourceName);
    
    napi_status status = napi_create_threadsafe_function(
        env, args[0], nullptr, resourceName,
        0, 1, nullptr, nullptr, nullptr,
        ButtonCallbackCallJS, &g_tsfnButton
    );
    if (status != napi_ok) {
        LOGE("创建 Button threadsafe function 失败: %d", status);
        g_tsfnButton = oldTsfn;
        return nullptr;
    }
    
    if (oldTsfn) {
        napi_release_threadsafe_function(oldTsfn, napi_tsfn_release);
    }
    
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
    
    napi_threadsafe_function oldTsfn = g_tsfnAxis;
    
    napi_value resourceName;
    napi_create_string_utf8(env, "GameControllerAxisCallback", NAPI_AUTO_LENGTH, &resourceName);
    
    napi_status status = napi_create_threadsafe_function(
        env, args[0], nullptr, resourceName,
        0, 1, nullptr, nullptr, nullptr,
        AxisCallbackCallJS, &g_tsfnAxis
    );
    if (status != napi_ok) {
        LOGE("创建 Axis threadsafe function 失败: %d", status);
        g_tsfnAxis = oldTsfn;
        return nullptr;
    }
    
    if (oldTsfn) {
        napi_release_threadsafe_function(oldTsfn, napi_tsfn_release);
    }
    
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

    napi_create_string_utf8(env, deviceInfo.physicalAddress, NAPI_AUTO_LENGTH, &val);
    napi_set_named_property(env, result, "physicalAddress", val);
    
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
 * refreshDevices(): number
 * 主动刷新设备缓存 - 返回新发现的设备数量
 */
static napi_value NapiRefreshDevices(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_int32(env, GameController_RefreshDevices(), &result);
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
        { "refreshDevices", nullptr, NapiRefreshDevices, nullptr, nullptr, nullptr, napi_default, nullptr },
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
