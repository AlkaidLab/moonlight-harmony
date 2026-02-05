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
 * SDL GameControllerDB 兼容映射系统
 * 
 * 从 SDL GameControllerDB (https://github.com/gabomdq/SDL_GameControllerDB) 移植
 * 将 SDL 映射字符串格式转换为原生 C 结构
 * 
 * SDL 映射字符串格式:
 * GUID,name,platform:mapping_string
 * mapping_string: a:b0,b:b1,x:b2,y:b3,back:b6,guide:b8,start:b7,leftstick:b9,...
 * 
 * 元素类型:
 * - b# = 按钮 (e.g., b0 = 按钮0)
 * - a# = 轴 (e.g., a0 = 轴0)
 * - h#.# = HAT (e.g., h0.1 = HAT0 上)
 */

#ifndef SDL_GAMECONTROLLERDB_H
#define SDL_GAMECONTROLLERDB_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ==================== 映射源类型 ====================
typedef enum {
    MAPPING_NONE = 0,
    MAPPING_BUTTON,     // b# - 按钮索引
    MAPPING_AXIS,       // a# - 轴索引
    MAPPING_HAT,        // h#.# - HAT 方向
} MappingSourceType;

// HAT 方向位掩码 (SDL 兼容)
#define HAT_UP      0x01
#define HAT_RIGHT   0x02
#define HAT_DOWN    0x04
#define HAT_LEFT    0x08

// ==================== 单个映射项 ====================
typedef struct {
    MappingSourceType type;
    int index;          // 按钮/轴/HAT 索引
    int hatMask;        // HAT 方向掩码 (仅 type=MAPPING_HAT 时使用)
    bool inverted;      // 轴是否反转 (a~# 格式)
    int rangeMin;       // 轴范围映射 (a#+, a#- 格式)
    int rangeMax;
} MappingSource;

// ==================== 完整手柄映射 ====================
typedef struct {
    uint16_t vendorId;
    uint16_t productId;
    const char* name;
    
    // 按钮映射 (从 HID 报告到标准 Xbox 布局)
    MappingSource a;            // A 按钮
    MappingSource b;            // B 按钮
    MappingSource x;            // X 按钮
    MappingSource y;            // Y 按钮
    MappingSource back;         // Back/Select 按钮
    MappingSource guide;        // Guide/Home 按钮
    MappingSource start;        // Start 按钮
    MappingSource leftstick;    // 左摇杆按下 (L3)
    MappingSource rightstick;   // 右摇杆按下 (R3)
    MappingSource leftshoulder; // LB
    MappingSource rightshoulder;// RB
    MappingSource dpup;         // D-Pad 上
    MappingSource dpdown;       // D-Pad 下
    MappingSource dpleft;       // D-Pad 左
    MappingSource dpright;      // D-Pad 右
    
    // 轴映射
    MappingSource leftx;        // 左摇杆 X
    MappingSource lefty;        // 左摇杆 Y
    MappingSource rightx;       // 右摇杆 X
    MappingSource righty;       // 右摇杆 Y
    MappingSource lefttrigger;  // 左扳机 (LT)
    MappingSource righttrigger; // 右扳机 (RT)
    
    // 额外信息
    int reportOffset;           // HID 报告数据偏移 (跳过 Report ID)
    int reportLength;           // 期望的 HID 报告长度
} GamepadMapping;

// ==================== 预定义映射数据库 ====================
// 基于 SDL GameControllerDB 数据，针对常见手柄预定义

/**
 * 查找手柄映射
 * @param vendorId USB Vendor ID
 * @param productId USB Product ID
 * @return 映射结构指针，未找到返回 NULL
 */
const GamepadMapping* findGamepadMapping(uint16_t vendorId, uint16_t productId);

/**
 * 基于 VID 获取默认映射模板
 * @param vendorId USB Vendor ID
 * @return 默认映射模板指针
 */
const GamepadMapping* getDefaultMappingByVendor(uint16_t vendorId);

/**
 * 解析 SDL 映射字符串 (运行时)
 * @param mappingString SDL 格式的映射字符串
 * @param outMapping 输出映射结构
 * @return 成功返回 true
 */
bool parseSDLMappingString(const char* mappingString, GamepadMapping* outMapping);

/**
 * 使用映射解析 HID 报告
 * @param mapping 映射规则
 * @param data HID 报告数据
 * @param len 数据长度
 * @param outButtons 输出按钮状态 (BTN_FLAG_* 位掩码)
 * @param outLeftStickX 输出左摇杆 X (-32768 到 32767)
 * @param outLeftStickY 输出左摇杆 Y
 * @param outRightStickX 输出右摇杆 X
 * @param outRightStickY 输出右摇杆 Y
 * @param outLeftTrigger 输出左扳机 (0-255)
 * @param outRightTrigger 输出右扳机 (0-255)
 */
void applyGamepadMapping(
    const GamepadMapping* mapping,
    const uint8_t* data,
    int len,
    uint32_t* outButtons,
    int16_t* outLeftStickX,
    int16_t* outLeftStickY,
    int16_t* outRightStickX,
    int16_t* outRightStickY,
    uint8_t* outLeftTrigger,
    uint8_t* outRightTrigger
);

// ==================== 按钮标志 (与 gamepad_napi.h 保持一致) ====================
// 使用 gamepad_napi.h 中的定义，这里只是重新声明以防止重复定义错误
#ifndef BTN_FLAG_A
// 这些值与 Moonlight 协议一致
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
#endif

#ifdef __cplusplus
}
#endif

#endif // SDL_GAMECONTROLLERDB_H
