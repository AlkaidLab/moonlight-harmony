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
 * SDL GameControllerDB 兼容映射系统实现
 * 
 * 包含常见手柄的预定义映射，基于 SDL GameControllerDB 数据
 * https://github.com/gabomdq/SDL_GameControllerDB
 */

#include "sdl_gamecontrollerdb.h"
#include "gamepad_napi.h"  // 使用其中定义的 BTN_FLAG_* 常量
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

// ==================== 辅助宏：快速创建映射 ====================
#define BTN(idx) { MAPPING_BUTTON, idx, 0, false, 0, 255 }
#define AXIS(idx) { MAPPING_AXIS, idx, 0, false, 0, 255 }
#define AXIS_INV(idx) { MAPPING_AXIS, idx, 0, true, 0, 255 }
#define HAT(idx, mask) { MAPPING_HAT, idx, mask, false, 0, 255 }
#define NONE { MAPPING_NONE, 0, 0, false, 0, 255 }

// ==================== 预定义映射数据库 ====================
// 按 VID 分组排列

static const GamepadMapping g_mappingDatabase[] = {
    
    // ==================== Microsoft Xbox 系列 ====================
    // Xbox 360 Controller - 标准 XInput 布局
    {
        .vendorId = 0x045E, .productId = 0x028E,
        .name = "Xbox 360 Controller",
        .a = BTN(0), .b = BTN(1), .x = BTN(2), .y = BTN(3),
        .back = BTN(6), .guide = BTN(8), .start = BTN(7),
        .leftstick = BTN(9), .rightstick = BTN(10),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(3), .righty = AXIS(4),
        .lefttrigger = AXIS(2), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // Xbox One Controller
    {
        .vendorId = 0x045E, .productId = 0x02D1,
        .name = "Xbox One Controller",
        .a = BTN(0), .b = BTN(1), .x = BTN(2), .y = BTN(3),
        .back = BTN(6), .guide = BTN(8), .start = BTN(7),
        .leftstick = BTN(9), .rightstick = BTN(10),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(3), .righty = AXIS(4),
        .lefttrigger = AXIS(2), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // Xbox Series X|S Controller
    {
        .vendorId = 0x045E, .productId = 0x0B12,
        .name = "Xbox Series X Controller",
        .a = BTN(0), .b = BTN(1), .x = BTN(2), .y = BTN(3),
        .back = BTN(6), .guide = BTN(8), .start = BTN(7),
        .leftstick = BTN(9), .rightstick = BTN(10),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(3), .righty = AXIS(4),
        .lefttrigger = AXIS(2), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // ==================== Sony PlayStation 系列 ====================
    // DualShock 4
    {
        .vendorId = 0x054C, .productId = 0x05C4,
        .name = "DualShock 4",
        .a = BTN(1), .b = BTN(2), .x = BTN(0), .y = BTN(3),  // Cross=A, Circle=B, Square=X, Triangle=Y
        .back = BTN(8), .guide = BTN(12), .start = BTN(9),
        .leftstick = BTN(10), .rightstick = BTN(11),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(5),
        .lefttrigger = AXIS(3), .righttrigger = AXIS(4),
        .reportOffset = 1, .reportLength = 64  // 跳过 Report ID
    },
    
    // DualShock 4 v2
    {
        .vendorId = 0x054C, .productId = 0x09CC,
        .name = "DualShock 4 v2",
        .a = BTN(1), .b = BTN(2), .x = BTN(0), .y = BTN(3),
        .back = BTN(8), .guide = BTN(12), .start = BTN(9),
        .leftstick = BTN(10), .rightstick = BTN(11),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(5),
        .lefttrigger = AXIS(3), .righttrigger = AXIS(4),
        .reportOffset = 1, .reportLength = 64
    },
    
    // DualSense
    {
        .vendorId = 0x054C, .productId = 0x0CE6,
        .name = "DualSense Controller",
        .a = BTN(1), .b = BTN(2), .x = BTN(0), .y = BTN(3),
        .back = BTN(8), .guide = BTN(12), .start = BTN(9),
        .leftstick = BTN(10), .rightstick = BTN(11),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(5),
        .lefttrigger = AXIS(3), .righttrigger = AXIS(4),
        .reportOffset = 1, .reportLength = 78
    },
    
    // ==================== Nintendo Switch 系列 ====================
    // Switch Pro Controller
    {
        .vendorId = 0x057E, .productId = 0x2009,
        .name = "Switch Pro Controller",
        .a = BTN(1), .b = BTN(0), .x = BTN(3), .y = BTN(2),  // Nintendo 布局: A/B, X/Y 互换
        .back = BTN(8), .guide = BTN(12), .start = BTN(9),
        .leftstick = BTN(10), .rightstick = BTN(11),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = BTN(6), .righttrigger = BTN(7),  // ZL/ZR 是数字按钮
        .reportOffset = 0, .reportLength = 64
    },
    
    // ==================== 8BitDo 系列 ====================
    // 8BitDo Pro 2
    {
        .vendorId = 0x2DC8, .productId = 0x6006,
        .name = "8BitDo Pro 2",
        .a = BTN(0), .b = BTN(1), .x = BTN(2), .y = BTN(3),
        .back = BTN(6), .guide = BTN(8), .start = BTN(7),
        .leftstick = BTN(9), .rightstick = BTN(10),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = AXIS(4), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // 8BitDo Ultimate
    {
        .vendorId = 0x2DC8, .productId = 0x3104,
        .name = "8BitDo Ultimate",
        .a = BTN(0), .b = BTN(1), .x = BTN(2), .y = BTN(3),
        .back = BTN(6), .guide = BTN(8), .start = BTN(7),
        .leftstick = BTN(9), .rightstick = BTN(10),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = AXIS(4), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // ==================== Logitech 系列 ====================
    // Logitech F310
    {
        .vendorId = 0x046D, .productId = 0xC21D,
        .name = "Logitech F310",
        .a = BTN(1), .b = BTN(2), .x = BTN(0), .y = BTN(3),
        .back = BTN(8), .guide = BTN(12), .start = BTN(9),
        .leftstick = BTN(10), .rightstick = BTN(11),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = BTN(6), .righttrigger = BTN(7),
        .reportOffset = 0, .reportLength = 0
    },
    
    // Logitech F710
    {
        .vendorId = 0x046D, .productId = 0xC21F,
        .name = "Logitech F710",
        .a = BTN(1), .b = BTN(2), .x = BTN(0), .y = BTN(3),
        .back = BTN(8), .guide = BTN(12), .start = BTN(9),
        .leftstick = BTN(10), .rightstick = BTN(11),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = AXIS(4), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // ==================== Razer 系列 ====================
    // Razer Wolverine Ultimate
    {
        .vendorId = 0x1532, .productId = 0x0A14,
        .name = "Razer Wolverine Ultimate",
        .a = BTN(0), .b = BTN(1), .x = BTN(2), .y = BTN(3),
        .back = BTN(6), .guide = BTN(8), .start = BTN(7),
        .leftstick = BTN(9), .rightstick = BTN(10),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = AXIS(4), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // ==================== 通用廉价手柄 ====================
    // 注意: VID 0x413D 手柄使用特殊的 HID 报告格式，
    // 已在 parseGenericHidReport() 中专门处理，不在此数据库中定义
    
    // DragonRise 通用手柄
    {
        .vendorId = 0x0079, .productId = 0x0006,
        .name = "DragonRise Generic Controller",
        .a = BTN(2), .b = BTN(1), .x = BTN(3), .y = BTN(0),
        .back = BTN(8), .guide = NONE, .start = BTN(9),
        .leftstick = BTN(10), .rightstick = BTN(11),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = BTN(6), .righttrigger = BTN(7),
        .reportOffset = 0, .reportLength = 0
    },
    
    // ==================== HORI 系列 ====================
    // HORI Fighting Stick
    {
        .vendorId = 0x0F0D, .productId = 0x00C1,
        .name = "HORI Fighting Stick",
        .a = BTN(1), .b = BTN(2), .x = BTN(0), .y = BTN(3),
        .back = BTN(8), .guide = BTN(12), .start = BTN(9),
        .leftstick = BTN(10), .rightstick = BTN(11),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = NONE, .lefty = NONE,  // 摇杆: HAT 直接映射
        .rightx = NONE, .righty = NONE,
        .lefttrigger = BTN(6), .righttrigger = BTN(7),
        .reportOffset = 0, .reportLength = 0
    },
    
    // HORIPAD
    {
        .vendorId = 0x0F0D, .productId = 0x0067,
        .name = "HORIPAD",
        .a = BTN(0), .b = BTN(1), .x = BTN(2), .y = BTN(3),
        .back = BTN(6), .guide = BTN(8), .start = BTN(7),
        .leftstick = BTN(9), .rightstick = BTN(10),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = AXIS(4), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // ==================== PowerA 系列 ====================
    {
        .vendorId = 0x20D6, .productId = 0xA711,
        .name = "PowerA Xbox Controller",
        .a = BTN(0), .b = BTN(1), .x = BTN(2), .y = BTN(3),
        .back = BTN(6), .guide = BTN(8), .start = BTN(7),
        .leftstick = BTN(9), .rightstick = BTN(10),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = AXIS(4), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // ==================== SteelSeries 系列 ====================
    // SteelSeries Stratus Duo
    {
        .vendorId = 0x1038, .productId = 0x1430,
        .name = "SteelSeries Stratus Duo",
        .a = BTN(0), .b = BTN(1), .x = BTN(2), .y = BTN(3),
        .back = BTN(6), .guide = BTN(8), .start = BTN(7),
        .leftstick = BTN(9), .rightstick = BTN(10),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = AXIS(4), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // ==================== GameSir 系列 ====================
    {
        .vendorId = 0x3575, .productId = 0x0620,
        .name = "GameSir Nova",
        .a = BTN(0), .b = BTN(1), .x = BTN(2), .y = BTN(3),
        .back = BTN(6), .guide = BTN(8), .start = BTN(7),
        .leftstick = BTN(9), .rightstick = BTN(10),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = AXIS(4), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // ==================== GuliKit 系列 ====================
    {
        .vendorId = 0x3820, .productId = 0x0009,
        .name = "GuliKit KingKong 2 Pro",
        .a = BTN(1), .b = BTN(0), .x = BTN(3), .y = BTN(2),  // Nintendo 布局
        .back = BTN(8), .guide = BTN(12), .start = BTN(9),
        .leftstick = BTN(10), .rightstick = BTN(11),
        .leftshoulder = BTN(4), .rightshoulder = BTN(5),
        .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
        .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
        .leftx = AXIS(0), .lefty = AXIS(1),
        .rightx = AXIS(2), .righty = AXIS(3),
        .lefttrigger = AXIS(4), .righttrigger = AXIS(5),
        .reportOffset = 0, .reportLength = 0
    },
    
    // 结束标记
    { 0, 0, NULL, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, 0, 0 }
};

// ==================== 厂商默认映射 (当 PID 未知时使用) ====================
// Xbox 风格默认模板
static const GamepadMapping g_xboxDefaultMapping = {
    .vendorId = 0, .productId = 0,
    .name = "Xbox-style Default",
    .a = BTN(0), .b = BTN(1), .x = BTN(2), .y = BTN(3),
    .back = BTN(6), .guide = BTN(8), .start = BTN(7),
    .leftstick = BTN(9), .rightstick = BTN(10),
    .leftshoulder = BTN(4), .rightshoulder = BTN(5),
    .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
    .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
    .leftx = AXIS(0), .lefty = AXIS(1),
    .rightx = AXIS(2), .righty = AXIS(3),
    .lefttrigger = AXIS(4), .righttrigger = AXIS(5),
    .reportOffset = 0, .reportLength = 0
};

// PlayStation 风格默认模板
static const GamepadMapping g_psDefaultMapping = {
    .vendorId = 0, .productId = 0,
    .name = "PlayStation-style Default",
    .a = BTN(1), .b = BTN(2), .x = BTN(0), .y = BTN(3),  // Cross, Circle, Square, Triangle
    .back = BTN(8), .guide = BTN(12), .start = BTN(9),
    .leftstick = BTN(10), .rightstick = BTN(11),
    .leftshoulder = BTN(4), .rightshoulder = BTN(5),
    .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
    .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
    .leftx = AXIS(0), .lefty = AXIS(1),
    .rightx = AXIS(2), .righty = AXIS(5),
    .lefttrigger = AXIS(3), .righttrigger = AXIS(4),
    .reportOffset = 1, .reportLength = 64
};

// Nintendo 风格默认模板
static const GamepadMapping g_nintendoDefaultMapping = {
    .vendorId = 0, .productId = 0,
    .name = "Nintendo-style Default",
    .a = BTN(1), .b = BTN(0), .x = BTN(3), .y = BTN(2),  // A/B, X/Y 互换
    .back = BTN(8), .guide = BTN(12), .start = BTN(9),
    .leftstick = BTN(10), .rightstick = BTN(11),
    .leftshoulder = BTN(4), .rightshoulder = BTN(5),
    .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
    .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
    .leftx = AXIS(0), .lefty = AXIS(1),
    .rightx = AXIS(2), .righty = AXIS(3),
    .lefttrigger = BTN(6), .righttrigger = BTN(7),
    .reportOffset = 0, .reportLength = 0
};

// 通用默认模板 (DirectInput 风格)
static const GamepadMapping g_genericDefaultMapping = {
    .vendorId = 0, .productId = 0,
    .name = "Generic DirectInput Default",
    .a = BTN(1), .b = BTN(2), .x = BTN(0), .y = BTN(3),
    .back = BTN(8), .guide = NONE, .start = BTN(9),
    .leftstick = BTN(10), .rightstick = BTN(11),
    .leftshoulder = BTN(4), .rightshoulder = BTN(5),
    .dpup = HAT(0, HAT_UP), .dpdown = HAT(0, HAT_DOWN),
    .dpleft = HAT(0, HAT_LEFT), .dpright = HAT(0, HAT_RIGHT),
    .leftx = AXIS(0), .lefty = AXIS(1),
    .rightx = AXIS(2), .righty = AXIS(3),
    .lefttrigger = BTN(6), .righttrigger = BTN(7),
    .reportOffset = 0, .reportLength = 0
};

// ==================== 厂商 VID 到默认映射的查找表 ====================
typedef struct {
    uint16_t vendorId;
    const GamepadMapping* defaultMapping;
} VendorDefaultEntry;

static const VendorDefaultEntry g_vendorDefaults[] = {
    { 0x045E, &g_xboxDefaultMapping },      // Microsoft
    { 0x054C, &g_psDefaultMapping },        // Sony
    { 0x057E, &g_nintendoDefaultMapping },  // Nintendo
    { 0x2DC8, &g_xboxDefaultMapping },      // 8BitDo (通常 Xbox 模式)
    { 0x046D, &g_xboxDefaultMapping },      // Logitech
    { 0x1532, &g_xboxDefaultMapping },      // Razer
    { 0x0F0D, &g_xboxDefaultMapping },      // HORI
    { 0x20D6, &g_xboxDefaultMapping },      // PowerA
    { 0x0E6F, &g_xboxDefaultMapping },      // PDP
    { 0x0738, &g_xboxDefaultMapping },      // MadCatz
    { 0x1038, &g_xboxDefaultMapping },      // SteelSeries
    { 0x044F, &g_xboxDefaultMapping },      // Thrustmaster
    { 0x11C0, &g_psDefaultMapping },        // Nacon
    { 0x146B, &g_psDefaultMapping },        // BigBen
    { 0x2C22, &g_psDefaultMapping },        // Qanba
    { 0x3820, &g_nintendoDefaultMapping },  // GuliKit
    { 0x3575, &g_xboxDefaultMapping },      // GameSir
    { 0x0079, &g_genericDefaultMapping },   // DragonRise
    { 0x0810, &g_genericDefaultMapping },   // Generic
    { 0x413D, &g_genericDefaultMapping },   // Generic (用户的手柄)
    { 0, NULL }
};

// ==================== API 实现 ====================

const GamepadMapping* findGamepadMapping(uint16_t vendorId, uint16_t productId) {
    for (int i = 0; g_mappingDatabase[i].name != NULL; i++) {
        if (g_mappingDatabase[i].vendorId == vendorId && 
            g_mappingDatabase[i].productId == productId) {
            return &g_mappingDatabase[i];
        }
    }
    return NULL;
}

const GamepadMapping* getDefaultMappingByVendor(uint16_t vendorId) {
    for (int i = 0; g_vendorDefaults[i].defaultMapping != NULL; i++) {
        if (g_vendorDefaults[i].vendorId == vendorId) {
            return g_vendorDefaults[i].defaultMapping;
        }
    }
    return &g_genericDefaultMapping;
}

// ==================== SDL 映射字符串解析器 ====================

/**
 * 解析单个映射元素 (如 "b0", "a1", "h0.1")
 */
static bool parseElement(const char* str, MappingSource* out) {
    if (!str || !out) return false;
    
    out->type = MAPPING_NONE;
    out->index = 0;
    out->hatMask = 0;
    out->inverted = false;
    out->rangeMin = 0;
    out->rangeMax = 255;
    
    // 检查是否反转 (a~0 格式)
    bool inverted = false;
    if (str[0] == '~') {
        inverted = true;
        str++;
    }
    
    char type = str[0];
    const char* rest = str + 1;
    
    switch (type) {
        case 'b':
            out->type = MAPPING_BUTTON;
            out->index = atoi(rest);
            break;
            
        case 'a':
            out->type = MAPPING_AXIS;
            out->inverted = inverted;
            // 检查 a0+ 或 a0- 格式
            {
                char* endptr;
                out->index = strtol(rest, &endptr, 10);
                if (*endptr == '+') {
                    out->rangeMin = 128;
                    out->rangeMax = 255;
                } else if (*endptr == '-') {
                    out->rangeMin = 0;
                    out->rangeMax = 128;
                }
            }
            break;
            
        case 'h':
            out->type = MAPPING_HAT;
            // 格式: h0.1, h0.2, h0.4, h0.8
            {
                const char* dotPos = strchr(rest, '.');
                if (dotPos) {
                    out->index = atoi(rest);
                    out->hatMask = atoi(dotPos + 1);
                }
            }
            break;
            
        default:
            return false;
    }
    
    return true;
}

bool parseSDLMappingString(const char* mappingString, GamepadMapping* outMapping) {
    if (!mappingString || !outMapping) return false;
    
    // 初始化所有映射为 NONE
    memset(outMapping, 0, sizeof(GamepadMapping));
    
    // 复制字符串以便修改
    char* str = strdup(mappingString);
    if (!str) return false;
    
    // 解析 GUID (跳过)
    char* token = strtok(str, ",");
    if (!token) { free(str); return false; }
    
    // 解析名称
    token = strtok(NULL, ",");
    if (token) {
        outMapping->name = strdup(token);
    }
    
    // 解析映射对
    while ((token = strtok(NULL, ",")) != NULL) {
        char* colonPos = strchr(token, ':');
        if (!colonPos) continue;
        
        *colonPos = '\0';
        const char* key = token;
        const char* value = colonPos + 1;
        
        MappingSource src;
        if (!parseElement(value, &src)) continue;
        
        // 按键名匹配
        if (strcmp(key, "a") == 0) outMapping->a = src;
        else if (strcmp(key, "b") == 0) outMapping->b = src;
        else if (strcmp(key, "x") == 0) outMapping->x = src;
        else if (strcmp(key, "y") == 0) outMapping->y = src;
        else if (strcmp(key, "back") == 0) outMapping->back = src;
        else if (strcmp(key, "guide") == 0) outMapping->guide = src;
        else if (strcmp(key, "start") == 0) outMapping->start = src;
        else if (strcmp(key, "leftstick") == 0) outMapping->leftstick = src;
        else if (strcmp(key, "rightstick") == 0) outMapping->rightstick = src;
        else if (strcmp(key, "leftshoulder") == 0) outMapping->leftshoulder = src;
        else if (strcmp(key, "rightshoulder") == 0) outMapping->rightshoulder = src;
        else if (strcmp(key, "dpup") == 0) outMapping->dpup = src;
        else if (strcmp(key, "dpdown") == 0) outMapping->dpdown = src;
        else if (strcmp(key, "dpleft") == 0) outMapping->dpleft = src;
        else if (strcmp(key, "dpright") == 0) outMapping->dpright = src;
        else if (strcmp(key, "leftx") == 0) outMapping->leftx = src;
        else if (strcmp(key, "lefty") == 0) outMapping->lefty = src;
        else if (strcmp(key, "rightx") == 0) outMapping->rightx = src;
        else if (strcmp(key, "righty") == 0) outMapping->righty = src;
        else if (strcmp(key, "lefttrigger") == 0) outMapping->lefttrigger = src;
        else if (strcmp(key, "righttrigger") == 0) outMapping->righttrigger = src;
    }
    
    free(str);
    return true;
}

// ==================== 映射应用 ====================

/**
 * 从 HID 报告中读取按钮状态
 */
static bool readButton(const uint8_t* data, int len, const MappingSource* src, int buttonByteOffset) {
    if (src->type != MAPPING_BUTTON) return false;
    
    int byteIndex = buttonByteOffset + (src->index / 8);
    int bitIndex = src->index % 8;
    
    if (byteIndex >= len) return false;
    
    return (data[byteIndex] & (1 << bitIndex)) != 0;
}

/**
 * 从 HID 报告中读取轴值
 */
static int16_t readAxis(const uint8_t* data, int len, const MappingSource* src, int axisOffset) {
    if (src->type != MAPPING_AXIS) return 0;
    
    int index = axisOffset + src->index;
    if (index >= len) return 0;
    
    int value = data[index];
    
    // 应用反转
    if (src->inverted) {
        value = 255 - value;
    }
    
    // 转换到 -32768 ~ 32767 范围
    return (int16_t)(((int)value - 128) << 8);
}

/**
 * 检查 HAT 方向
 */
static bool checkHat(const uint8_t* data, int len, const MappingSource* src, int hatOffset) {
    if (src->type != MAPPING_HAT) return false;
    
    int index = hatOffset + src->index;
    if (index >= len) return false;
    
    uint8_t hatValue = data[index] & 0x0F;
    
    // HAT 值 0-7 映射到方向
    static const uint8_t hatToMask[] = {
        HAT_UP,                     // 0: 上
        HAT_UP | HAT_RIGHT,         // 1: 右上
        HAT_RIGHT,                  // 2: 右
        HAT_DOWN | HAT_RIGHT,       // 3: 右下
        HAT_DOWN,                   // 4: 下
        HAT_DOWN | HAT_LEFT,        // 5: 左下
        HAT_LEFT,                   // 6: 左
        HAT_UP | HAT_LEFT           // 7: 左上
    };
    
    if (hatValue > 7) return false;  // 中立或无效
    
    return (hatToMask[hatValue] & src->hatMask) != 0;
}

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
) {
    if (!mapping || !data || len < 8) return;
    
    *outButtons = 0;
    *outLeftStickX = 0;
    *outLeftStickY = 0;
    *outRightStickX = 0;
    *outRightStickY = 0;
    *outLeftTrigger = 0;
    *outRightTrigger = 0;
    
    int offset = mapping->reportOffset;
    int buttonOffset = offset + 4;  // 通常按钮在摇杆数据后面
    int hatOffset = offset + 4;     // HAT 通常紧随摇杆
    int axisOffset = offset;        // 轴从偏移开始
    
    // 读取摇杆
    if (mapping->leftx.type == MAPPING_AXIS) {
        *outLeftStickX = readAxis(data, len, &mapping->leftx, axisOffset);
    }
    if (mapping->lefty.type == MAPPING_AXIS) {
        *outLeftStickY = readAxis(data, len, &mapping->lefty, axisOffset);
    }
    if (mapping->rightx.type == MAPPING_AXIS) {
        *outRightStickX = readAxis(data, len, &mapping->rightx, axisOffset);
    }
    if (mapping->righty.type == MAPPING_AXIS) {
        *outRightStickY = readAxis(data, len, &mapping->righty, axisOffset);
    }
    
    // 读取扳机 (可能是按钮或轴)
    if (mapping->lefttrigger.type == MAPPING_AXIS) {
        int idx = axisOffset + mapping->lefttrigger.index;
        if (idx < len) *outLeftTrigger = data[idx];
    } else if (mapping->lefttrigger.type == MAPPING_BUTTON) {
        if (readButton(data, len, &mapping->lefttrigger, buttonOffset)) {
            *outLeftTrigger = 255;
        }
    }
    
    if (mapping->righttrigger.type == MAPPING_AXIS) {
        int idx = axisOffset + mapping->righttrigger.index;
        if (idx < len) *outRightTrigger = data[idx];
    } else if (mapping->righttrigger.type == MAPPING_BUTTON) {
        if (readButton(data, len, &mapping->righttrigger, buttonOffset)) {
            *outRightTrigger = 255;
        }
    }
    
    // 读取面板按钮
    #define CHECK_BTN(mapping_field, flag) \
        if (mapping->mapping_field.type == MAPPING_BUTTON && readButton(data, len, &mapping->mapping_field, buttonOffset)) \
            *outButtons |= flag; \
        else if (mapping->mapping_field.type == MAPPING_HAT && checkHat(data, len, &mapping->mapping_field, hatOffset)) \
            *outButtons |= flag;
    
    CHECK_BTN(a, BTN_FLAG_A);
    CHECK_BTN(b, BTN_FLAG_B);
    CHECK_BTN(x, BTN_FLAG_X);
    CHECK_BTN(y, BTN_FLAG_Y);
    CHECK_BTN(leftshoulder, BTN_FLAG_LB);
    CHECK_BTN(rightshoulder, BTN_FLAG_RB);
    CHECK_BTN(back, BTN_FLAG_BACK);
    CHECK_BTN(start, BTN_FLAG_START);
    CHECK_BTN(guide, BTN_FLAG_HOME);
    CHECK_BTN(leftstick, BTN_FLAG_LS_CLK);
    CHECK_BTN(rightstick, BTN_FLAG_RS_CLK);
    CHECK_BTN(dpup, BTN_FLAG_UP);
    CHECK_BTN(dpdown, BTN_FLAG_DOWN);
    CHECK_BTN(dpleft, BTN_FLAG_LEFT);
    CHECK_BTN(dpright, BTN_FLAG_RIGHT);
    
    #undef CHECK_BTN
}
