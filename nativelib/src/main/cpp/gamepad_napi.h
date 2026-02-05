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
 * USB 手柄 NAPI 绑定头文件
 * 
 * 用于将 USB HID 手柄功能暴露给 ArkTS 层
 */

#ifndef GAMEPAD_NAPI_H
#define GAMEPAD_NAPI_H

#include <napi/native_api.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 手柄状态结构 (用于 NAPI 传输)
 */
typedef struct {
    int32_t deviceId;       // 设备 ID
    uint32_t buttons;       // 按钮位掩码
    int16_t leftStickX;     // 左摇杆 X (-32768 to 32767)
    int16_t leftStickY;     // 左摇杆 Y
    int16_t rightStickX;    // 右摇杆 X
    int16_t rightStickY;    // 右摇杆 Y
    uint8_t leftTrigger;    // 左扳机 (0-255)
    uint8_t rightTrigger;   // 右扳机 (0-255)
} NapiGamepadState;

/**
 * 手柄信息结构
 */
typedef struct {
    int32_t deviceId;
    uint16_t vendorId;
    uint16_t productId;
    char name[256];
    int32_t type;           // 0=Unknown, 1=Xbox, 2=PlayStation, 3=Switch
    bool isConnected;
} NapiGamepadInfo;

/**
 * 按钮标志位 (与 Moonlight 协议一致)
 */
#define BTN_FLAG_UP          0x0001
#define BTN_FLAG_DOWN        0x0002
#define BTN_FLAG_LEFT        0x0004
#define BTN_FLAG_RIGHT       0x0008
#define BTN_FLAG_START       0x0010
#define BTN_FLAG_BACK        0x0020
#define BTN_FLAG_LS_CLK      0x0040
#define BTN_FLAG_RS_CLK      0x0080
#define BTN_FLAG_LB          0x0100
#define BTN_FLAG_RB          0x0200
#define BTN_FLAG_HOME        0x0400
#define BTN_FLAG_A           0x1000
#define BTN_FLAG_B           0x2000
#define BTN_FLAG_X           0x4000
#define BTN_FLAG_Y           0x8000

// 扩展按钮 (用于 special button)
#define BTN_FLAG_PADDLE1     0x00010000
#define BTN_FLAG_PADDLE2     0x00020000
#define BTN_FLAG_PADDLE3     0x00040000
#define BTN_FLAG_PADDLE4     0x00080000
#define BTN_FLAG_TOUCHPAD    0x00100000
#define BTN_FLAG_MISC        0x00200000

/**
 * NAPI 导出函数
 */

// 初始化模块
napi_value GamepadNapi_Init(napi_env env, napi_value exports);

// 解析 HID 报告 (根据 VID/PID 选择解析器)
// parseHidReport(vendorId: number, productId: number, data: Uint8Array): GamepadState
napi_value GamepadNapi_ParseHidReport(napi_env env, napi_callback_info info);

// 获取已知手柄的类型
// getGamepadType(vendorId: number, productId: number): number
napi_value GamepadNapi_GetGamepadType(napi_env env, napi_callback_info info);

// 检查是否支持的手柄
// isSupportedGamepad(vendorId: number, productId: number): boolean
napi_value GamepadNapi_IsSupportedGamepad(napi_env env, napi_callback_info info);

// 获取手柄名称
// getGamepadName(vendorId: number, productId: number): string
napi_value GamepadNapi_GetGamepadName(napi_env env, napi_callback_info info);

// 生成 Rumble 命令 (返回要发送到 HID 设备的数据)
// createRumbleCommand(vendorId: number, productId: number, lowFreq: number, highFreq: number): Uint8Array | null
napi_value GamepadNapi_CreateRumbleCommand(napi_env env, napi_callback_info info);

#ifdef __cplusplus
}
#endif

#endif // GAMEPAD_NAPI_H
