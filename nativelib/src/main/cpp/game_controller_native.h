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
 * Game Controller Kit Native 封装
 * 
 * 提供统一的游戏手柄输入接口，支持 USB 和蓝牙手柄
 * 基于 HarmonyOS Game Controller Kit API
 * 
 * 参考文档: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/game-controller-kit
 */

#ifndef GAME_CONTROLLER_NATIVE_H
#define GAME_CONTROLLER_NATIVE_H

#include <napi/native_api.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ==================== 手柄状态结构 ====================

/**
 * 手柄状态
 */
typedef struct {
    char deviceId[64];      // 设备 ID (字符串)
    uint32_t buttons;       // 按钮位掩码
    int16_t leftStickX;     // 左摇杆 X (-32768 to 32767)
    int16_t leftStickY;     // 左摇杆 Y
    int16_t rightStickX;    // 右摇杆 X
    int16_t rightStickY;    // 右摇杆 Y
    uint8_t leftTrigger;    // 左扳机 (0-255)
    uint8_t rightTrigger;   // 右扳机 (0-255)
    int16_t hatX;           // D-Pad X (-1, 0, 1)
    int16_t hatY;           // D-Pad Y (-1, 0, 1)
} GameControllerState;

/**
 * 手柄设备信息
 */
typedef struct {
    char deviceId[64];      // 设备 ID
    char name[256];         // 设备名称
    int32_t product;        // 产品 ID
    int32_t version;        // 版本
    char physicalAddress[64]; // 物理地址
    int32_t deviceType;     // 设备类型 (0=未知, 1=手柄)
    bool isConnected;       // 是否已连接
} GameControllerInfo;

// ==================== 按钮标志位 ====================
// 与 Moonlight 协议一致

#define GC_BTN_UP          0x0001
#define GC_BTN_DOWN        0x0002
#define GC_BTN_LEFT        0x0004
#define GC_BTN_RIGHT       0x0008
#define GC_BTN_START       0x0010
#define GC_BTN_BACK        0x0020
#define GC_BTN_LS_CLK      0x0040
#define GC_BTN_RS_CLK      0x0080
#define GC_BTN_LB          0x0100
#define GC_BTN_RB          0x0200
#define GC_BTN_HOME        0x0400
#define GC_BTN_A           0x1000
#define GC_BTN_B           0x2000
#define GC_BTN_X           0x4000
#define GC_BTN_Y           0x8000

// ==================== 按键码 (与 Game Controller Kit 一致) ====================

#define GC_KEYCODE_BUTTON_A           2301
#define GC_KEYCODE_BUTTON_B           2302
#define GC_KEYCODE_BUTTON_C           2303
#define GC_KEYCODE_BUTTON_X           2304
#define GC_KEYCODE_BUTTON_Y           2305
#define GC_KEYCODE_LEFT_SHOULDER      2307
#define GC_KEYCODE_RIGHT_SHOULDER     2308
#define GC_KEYCODE_LEFT_TRIGGER       2309
#define GC_KEYCODE_RIGHT_TRIGGER      2310
#define GC_KEYCODE_BUTTON_HOME        2311
#define GC_KEYCODE_BUTTON_MENU        2312
#define GC_KEYCODE_LEFT_THUMBSTICK    2314
#define GC_KEYCODE_RIGHT_THUMBSTICK   2315
#define GC_KEYCODE_DPAD_UP            2012
#define GC_KEYCODE_DPAD_DOWN          2013
#define GC_KEYCODE_DPAD_LEFT          2014
#define GC_KEYCODE_DPAD_RIGHT         2015

// ==================== 回调函数类型 ====================

/**
 * 设备状态变化回调
 * @param deviceId 设备 ID
 * @param isConnected true=上线, false=下线
 * @param info 设备信息 (仅上线时有效)
 */
typedef void (*GameControllerDeviceCallback)(
    const char* deviceId,
    bool isConnected,
    const GameControllerInfo* info
);

/**
 * 按键事件回调
 * @param deviceId 设备 ID
 * @param buttonCode 按键码
 * @param isPressed true=按下, false=释放
 */
typedef void (*GameControllerButtonCallback)(
    const char* deviceId,
    int32_t buttonCode,
    bool isPressed
);

/**
 * 轴事件回调
 * @param deviceId 设备 ID
 * @param axisType 轴类型 (0=左摇杆, 1=右摇杆, 2=D-Pad, 3=左扳机, 4=右扳机)
 * @param x X 轴值 (-1.0 to 1.0)
 * @param y Y 轴值 (-1.0 to 1.0) (扳机没有 Y 轴)
 */
typedef void (*GameControllerAxisCallback)(
    const char* deviceId,
    int32_t axisType,
    double x,
    double y
);

// ==================== 轴类型常量 ====================

#define GC_AXIS_LEFT_THUMBSTICK   0
#define GC_AXIS_RIGHT_THUMBSTICK  1
#define GC_AXIS_DPAD              2
#define GC_AXIS_LEFT_TRIGGER      3
#define GC_AXIS_RIGHT_TRIGGER     4

// ==================== API 函数 ====================

/**
 * 初始化 Game Controller Kit
 * @return 0=成功, 其他=错误码
 */
int GameController_Init(void);

/**
 * 反初始化
 */
void GameController_Uninit(void);

/**
 * 设置设备状态变化回调
 */
void GameController_SetDeviceCallback(GameControllerDeviceCallback callback);

/**
 * 设置按键事件回调
 */
void GameController_SetButtonCallback(GameControllerButtonCallback callback);

/**
 * 设置轴事件回调
 */
void GameController_SetAxisCallback(GameControllerAxisCallback callback);

/**
 * 开始监听
 * @return 0=成功, 其他=错误码
 */
int GameController_StartMonitor(void);

/**
 * 停止监听
 */
void GameController_StopMonitor(void);

/**
 * 获取所有已连接设备数量
 */
int GameController_GetDeviceCount(void);

/**
 * 获取设备信息
 * @param index 设备索引 (0 到 count-1)
 * @param outInfo 输出设备信息
 * @return 0=成功, 其他=错误码
 */
int GameController_GetDeviceInfo(int index, GameControllerInfo* outInfo);

/**
 * 判断 Game Controller Kit 是否可用
 * (API 21+ 且系统支持)
 */
bool GameController_IsAvailable(void);

/**
 * 心跳检测 - 检查设备是否仍然连接
 * 
 * 对于某些设备（如雷蛇手柄），电源管理不透明，
 * 系统可能不会及时发送断开事件。
 * 此函数通过重新查询设备列表来检测设备断开。
 * 
 * @return 断开的设备数量
 */
int GameController_HeartbeatCheck(void);

// ==================== NAPI 导出函数 ====================

/**
 * 初始化 NAPI 模块
 */
napi_value GameControllerNapi_Init(napi_env env, napi_value exports);

#ifdef __cplusplus
}
#endif

#endif // GAME_CONTROLLER_NATIVE_H
