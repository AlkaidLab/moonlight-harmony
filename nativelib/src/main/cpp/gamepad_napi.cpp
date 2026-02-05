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
 * USB 手柄 NAPI 绑定实现
 * 
 * 将 USB HID 手柄解析功能暴露给 ArkTS 层
 * 支持多种手柄: Xbox, PlayStation, Switch, 通用 HID
 */

#include "gamepad_napi.h"
#include "sdl_gamecontrollerdb.h"
#include <hilog/log.h>
#include <string.h>
#include <stdlib.h>
#include <cstdio>

#define LOG_TAG "GamepadNAPI"
#define LOG_DOMAIN 0xFF00
#define LOGD(...) OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

// ==================== 已知手柄 VID/PID 数据库 ====================
// 数据来源: SDL GameControllerDB (https://github.com/gabomdq/SDL_GameControllerDB)
// 类型: 0=Unknown/Generic, 1=Xbox, 2=PlayStation, 3=Switch

typedef struct {
    uint16_t vendorId;
    uint16_t productId;
    const char* name;
    int32_t type;           // 0=Unknown, 1=Xbox, 2=PlayStation, 3=Switch
    int reportLength;       // 期望的报告长度, 0=不限
} KnownGamepad;

static const KnownGamepad g_knownGamepads[] = {
    // ==================== Microsoft Xbox 系列 ====================
    {0x045E, 0x0202, "Xbox Controller", 1, 0},
    {0x045E, 0x0285, "Xbox Controller S", 1, 0},
    {0x045E, 0x0289, "Xbox Controller S", 1, 0},
    {0x045E, 0x028E, "Xbox 360 Controller", 1, 0},
    {0x045E, 0x028F, "Xbox 360 Wireless Controller", 1, 0},
    {0x045E, 0x0291, "Xbox 360 Wireless Controller", 1, 0},
    {0x045E, 0x02D1, "Xbox One Controller", 1, 0},
    {0x045E, 0x02DD, "Xbox One Controller", 1, 0},
    {0x045E, 0x02E0, "Xbox One S Controller", 1, 0},
    {0x045E, 0x02E3, "Xbox One Elite Controller", 1, 0},
    {0x045E, 0x02EA, "Xbox One S Controller", 1, 0},
    {0x045E, 0x02FF, "Xbox One Controller", 1, 0},
    {0x045E, 0x0719, "Xbox 360 Wireless Receiver", 1, 0},
    {0x045E, 0x0B00, "Xbox Elite Controller Series 2", 1, 0},
    {0x045E, 0x0B05, "Xbox Elite Controller Series 2", 1, 0},
    {0x045E, 0x0B0A, "Xbox Adaptive Controller", 1, 0},
    {0x045E, 0x0B12, "Xbox Series X Controller", 1, 0},
    {0x045E, 0x0B13, "Xbox Series X Controller", 1, 0},
    {0x045E, 0x0B20, "Xbox Series X Controller", 1, 0},
    {0x045E, 0x0B21, "Xbox Adaptive Controller", 1, 0},
    {0x045E, 0x0B22, "Xbox Elite Controller Series 2", 1, 0},
    
    // ==================== Sony PlayStation 系列 ====================
    {0x054C, 0x0268, "PlayStation 3 Controller", 2, 49},
    {0x054C, 0x042F, "PlayStation Move Controller", 2, 0},
    {0x054C, 0x05C4, "DualShock 4", 2, 64},
    {0x054C, 0x05C5, "DualShock 4 Wireless Dongle", 2, 64},
    {0x054C, 0x09CC, "DualShock 4 v2", 2, 64},
    {0x054C, 0x0BA0, "DualShock 4 Wireless Dongle", 2, 64},
    {0x054C, 0x0CE6, "DualSense Controller", 2, 78},
    {0x054C, 0x0DF2, "DualSense Edge Controller", 2, 78},
    {0x054C, 0x0E5F, "PS5 Access Controller", 2, 78},
    {0x054C, 0xDA0C, "PlayStation Classic Controller", 2, 0},
    
    // ==================== Nintendo 系列 ====================
    {0x057E, 0x0306, "Wii Remote", 3, 0},
    {0x057E, 0x0330, "Wii U Pro Controller", 3, 0},
    {0x057E, 0x0337, "Wii U GameCube Adapter", 3, 0},
    {0x057E, 0x2006, "Joy-Con (L)", 3, 49},
    {0x057E, 0x2007, "Joy-Con (R)", 3, 49},
    {0x057E, 0x2009, "Switch Pro Controller", 3, 64},
    {0x057E, 0x200E, "Joy-Con Charging Grip", 3, 49},
    {0x057E, 0x2017, "SNES Controller", 3, 0},
    {0x057E, 0x2019, "Nintendo 64 Controller", 3, 0},
    {0x057E, 0x201A, "Nintendo Switch Online GameCube", 3, 0},
    {0x057E, 0x201E, "Nintendo Switch 2 Pro Controller", 3, 0},
    {0x057E, 0x2020, "Nintendo Switch Online Famicom", 3, 0},
    
    // ==================== 8BitDo ====================
    {0x2DC8, 0x0651, "8BitDo M30", 1, 0},
    {0x2DC8, 0x0652, "8BitDo M30 Bluetooth", 1, 0},
    {0x2DC8, 0x1003, "8BitDo NES30 Pro", 1, 0},
    {0x2DC8, 0x2100, "8BitDo SN30 Pro", 1, 0},
    {0x2DC8, 0x2101, "8BitDo SN30 Pro", 1, 0},
    {0x2DC8, 0x2180, "8BitDo Pro 2", 1, 0},
    {0x2DC8, 0x3010, "8BitDo Ultimate 2.4G", 1, 0},
    {0x2DC8, 0x3011, "8BitDo Ultimate 2.4G", 1, 0},
    {0x2DC8, 0x3104, "8BitDo Ultimate", 1, 0},
    {0x2DC8, 0x3105, "8BitDo Ultimate Wireless", 1, 0},
    {0x2DC8, 0x3106, "8BitDo Ultimate 2C", 1, 0},
    {0x2DC8, 0x5001, "8BitDo Zero 2", 1, 0},
    {0x2DC8, 0x6001, "8BitDo SN30 Pro+", 1, 0},
    {0x2DC8, 0x6002, "8BitDo SN30 Pro+ 2", 1, 0},
    {0x2DC8, 0x6006, "8BitDo Pro 2", 1, 0},
    {0x2DC8, 0x9015, "8BitDo Pro 2 Wired", 1, 0},
    
    // ==================== Logitech ====================
    {0x046D, 0xC216, "Logitech Dual Action", 1, 0},
    {0x046D, 0xC218, "Logitech RumblePad 2", 1, 0},
    {0x046D, 0xC219, "Logitech F710 Wireless", 1, 0},
    {0x046D, 0xC21A, "Logitech Precision", 1, 0},
    {0x046D, 0xC21D, "Logitech F310", 1, 0},
    {0x046D, 0xC21E, "Logitech F510", 1, 0},
    {0x046D, 0xC21F, "Logitech F710", 1, 0},
    {0x046D, 0xC242, "Logitech ChillStream", 1, 0},
    {0x046D, 0xC248, "Logitech G Xbox Controller", 1, 0},
    {0x046D, 0xCABB, "Logitech G Xbox Controller", 1, 0},
    
    // ==================== Razer ====================
    {0x1532, 0x0037, "Razer Sabertooth", 1, 0},
    {0x1532, 0x0705, "Razer Junglecat", 1, 0},
    {0x1532, 0x0900, "Razer Serval", 1, 0},
    {0x1532, 0x0A00, "Razer Raiju", 2, 64},
    {0x1532, 0x0A03, "Razer Wildcat", 1, 0},
    {0x1532, 0x0A14, "Razer Raiju Ultimate", 2, 64},
    {0x1532, 0x0A15, "Razer Raiju Tournament", 2, 64},
    {0x1532, 0x1000, "Razer Raiju Mobile", 1, 0},
    {0x1532, 0x1004, "Razer Kishi", 1, 0},
    {0x1532, 0x1008, "Razer Kishi V2", 1, 0},
    {0x1532, 0x1100, "Razer Wolverine", 1, 0},
    {0x1532, 0x1007, "Razer Wolverine V2", 1, 0},
    {0x1532, 0x100A, "Razer Wolverine V2 Chroma", 1, 0},
    
    // ==================== HORI ====================
    {0x0F0D, 0x0004, "Hori Fighting Stick 3", 2, 0},
    {0x0F0D, 0x000A, "Hori Fighting Stick EX2", 1, 0},
    {0x0F0D, 0x000D, "Hori Fighting Stick EX2", 1, 0},
    {0x0F0D, 0x0011, "Hori Real Arcade Pro 3", 2, 0},
    {0x0F0D, 0x0016, "Hori Real Arcade Pro EX", 1, 0},
    {0x0F0D, 0x001B, "Hori Real Arcade Pro VX", 1, 0},
    {0x0F0D, 0x0022, "Hori Real Arcade Pro V3", 2, 0},
    {0x0F0D, 0x005B, "Hori Fight Stick Alpha", 1, 0},
    {0x0F0D, 0x005C, "Hori Fighting Stick Mini 4", 2, 64},
    {0x0F0D, 0x005E, "Hori Fighting Commander 4", 2, 64},
    {0x0F0D, 0x0063, "Hori Fighting Commander", 1, 0},
    {0x0F0D, 0x0066, "Horipad 4 FPS", 2, 64},
    {0x0F0D, 0x0067, "Horipad One", 1, 0},
    {0x0F0D, 0x0078, "Hori Real Arcade Pro V Kai", 1, 0},
    {0x0F0D, 0x0084, "Hori Fighting Commander", 2, 64},
    {0x0F0D, 0x0085, "Hori Fighting Stick V5", 1, 0},
    {0x0F0D, 0x0087, "Hori Fighting Stick Mini", 2, 64},
    {0x0F0D, 0x008A, "Hori Real Arcade Pro VLX", 1, 0},
    {0x0F0D, 0x008B, "Hori Fighting Stick Mini", 1, 0},
    {0x0F0D, 0x00A0, "Hori TAC Pro", 2, 64},
    {0x0F0D, 0x00AA, "Hori Split Pad Pro", 3, 0},
    {0x0F0D, 0x00C1, "Horipad for Nintendo Switch", 3, 0},
    {0x0F0D, 0x00C6, "Hori Horipad for Steam", 1, 0},
    {0x0F0D, 0x00DC, "Hori Fighting Commander OCTA", 2, 64},
    {0x0F0D, 0x00EE, "Hori Split Pad Compact", 3, 0},
    {0x0F0D, 0x00F6, "Horipad Pro for Xbox", 1, 0},
    
    // ==================== PowerA ====================
    {0x20D6, 0x2001, "PowerA Xbox One Controller", 1, 0},
    {0x20D6, 0x2002, "PowerA Nintendo Switch Controller", 3, 0},
    {0x20D6, 0x2006, "PowerA Nano Enhanced", 3, 0},
    {0x20D6, 0x2009, "PowerA Enhanced Wireless", 3, 0},
    {0x20D6, 0x200D, "PowerA Spectra Infinity", 1, 0},
    {0x20D6, 0x280D, "PowerA Nano Enhanced", 3, 0},
    {0x20D6, 0x89E5, "PowerA Xbox One Controller", 1, 0},
    {0x20D6, 0xA711, "PowerA Xbox Series X Controller", 1, 0},
    {0x20D6, 0xA713, "PowerA Xbox Series X Controller", 1, 0},
    {0x20D6, 0xA720, "PowerA Xbox Series X Controller", 1, 0},
    
    // ==================== PDP ====================
    {0x0E6F, 0x0113, "PDP Afterglow AX.1", 1, 0},
    {0x0E6F, 0x011F, "PDP Rock Candy Wired", 1, 0},
    {0x0E6F, 0x0139, "PDP Afterglow Prismatic", 1, 0},
    {0x0E6F, 0x013A, "PDP Xbox One Controller", 1, 0},
    {0x0E6F, 0x0146, "PDP Xbox One Controller", 1, 0},
    {0x0E6F, 0x0147, "PDP Xbox One Controller", 1, 0},
    {0x0E6F, 0x0161, "PDP Xbox One Controller", 1, 0},
    {0x0E6F, 0x0162, "PDP Xbox One Controller", 1, 0},
    {0x0E6F, 0x0163, "PDP Xbox One Controller", 1, 0},
    {0x0E6F, 0x0164, "PDP Battlefield One", 1, 0},
    {0x0E6F, 0x0201, "PDP PS3 Controller", 2, 0},
    {0x0E6F, 0x0203, "PDP Mortal Kombat X", 1, 0},
    {0x0E6F, 0x0213, "PDP Afterglow", 1, 0},
    {0x0E6F, 0x021F, "PDP Rock Candy", 1, 0},
    {0x0E6F, 0x02A1, "PDP Realmz", 3, 0},
    {0x0E6F, 0x02A4, "PDP Afterglow", 3, 0},
    {0x0E6F, 0x02A5, "PDP Faceoff Deluxe", 3, 0},
    {0x0E6F, 0x02AB, "PDP Faceoff Pro", 3, 0},
    
    // ==================== Mad Catz ====================
    {0x0738, 0x4716, "MadCatz Xbox 360 Controller", 1, 0},
    {0x0738, 0x4718, "MadCatz Street Fighter IV FightStick SE", 1, 0},
    {0x0738, 0x4726, "MadCatz Xbox 360 Controller", 1, 0},
    {0x0738, 0x4728, "MadCatz Street Fighter IV FightPad", 1, 0},
    {0x0738, 0x4736, "MadCatz MicroCon", 1, 0},
    {0x0738, 0x4740, "MadCatz Beat Pad", 1, 0},
    {0x0738, 0x9871, "MadCatz PS4 Fightstick", 2, 64},
    {0x0738, 0xB726, "MadCatz Xbox One Controller", 1, 0},
    {0x0738, 0xCB02, "MadCatz Saitek Cyborg Rumble Pad", 1, 0},
    {0x0738, 0xCB03, "MadCatz Saitek P3200 Rumble Pad", 1, 0},
    
    // ==================== SteelSeries ====================
    {0x1038, 0x1412, "SteelSeries Free", 1, 0},
    {0x1038, 0x1420, "SteelSeries Stratus XL", 1, 0},
    {0x1038, 0x1430, "SteelSeries Stratus XL", 1, 0},
    {0x1038, 0x1431, "SteelSeries Stratus XL", 1, 0},
    {0x1038, 0x1432, "SteelSeries Stratus Duo", 1, 0},
    {0x1038, 0x1434, "SteelSeries Nimbus", 1, 0},
    
    // ==================== GameSir ====================
    {0x05AC, 0x055D, "GameSir G3s", 1, 0},
    {0x05AC, 0x3D03, "GameSir T4", 1, 0},
    {0x3537, 0x0411, "GameSir X4A", 1, 0},
    
    // ==================== Thrustmaster ====================
    {0x044F, 0xB315, "Thrustmaster Dual Analog 3.2", 1, 0},
    {0x044F, 0xB323, "Thrustmaster Dual Trigger 3-in-1", 1, 0},
    {0x044F, 0xB326, "Thrustmaster Gamepad GP XID", 1, 0},
    {0x044F, 0xD003, "Thrustmaster eSwap PRO", 2, 64},
    {0x044F, 0xD008, "Thrustmaster eSwap X PRO", 1, 0},
    {0x044F, 0xD00D, "Thrustmaster eSwap S", 1, 0},
    
    // ==================== Nacon / BigBen ====================
    {0x11C0, 0x4001, "Nacon Revolution Pro", 2, 64},
    {0x11C0, 0x4003, "Nacon Revolution Pro 2", 2, 64},
    {0x11C0, 0x4006, "Nacon Daija Arcade Stick", 2, 64},
    {0x11C0, 0x5510, "Nacon MG-X Pro", 1, 0},
    {0x11C0, 0x5611, "Nacon RIG Pro Compact", 1, 0},
    {0x146B, 0x0603, "BigBen Interactive PS3 Controller", 2, 0},
    {0x146B, 0x0604, "BigBen Interactive PS3 Controller", 2, 0},
    {0x146B, 0x0D01, "BigBen Interactive PS4 Controller", 2, 64},
    {0x146B, 0x0D02, "BigBen Interactive Nacon Controller", 2, 64},
    
    // ==================== Qanba ====================
    {0x2C22, 0x2000, "Qanba Drone", 2, 64},
    {0x2C22, 0x2200, "Qanba Drone", 2, 64},
    {0x2C22, 0x2300, "Qanba Obsidian", 2, 64},
    {0x2C22, 0x2500, "Qanba Dragon", 2, 64},
    {0x2C22, 0x2502, "Qanba Arcade Joystick", 2, 64},
    
    // ==================== GuliKit ====================
    {0x3820, 0x0009, "GuliKit KingKong Pro", 3, 0},
    {0x3820, 0x0060, "GuliKit Route Controller Pro", 3, 0},
    {0x3820, 0x2110, "GuliKit KingKong 2 Pro", 3, 0},
    
    // ==================== Betop ====================
    {0x20BC, 0x5500, "Beitong S2", 1, 0},
    
    // ==================== DragonRise / Generic ====================
    {0x0079, 0x0006, "DragonRise Gamepad", 0, 0},
    {0x0079, 0x0011, "DragonRise Gamepad", 0, 0},
    {0x0079, 0x0018, "Mayflash GameCube Adapter", 0, 0},
    {0x0079, 0x1843, "DragonRise Gamepad", 0, 0},
    {0x0583, 0x2060, "Trust GXT 540", 0, 0},
    {0x0583, 0xA009, "Trust GXT 570", 0, 0},
    {0x0810, 0xE501, "Generic Gamepad", 0, 0},
    {0x0E8F, 0x0003, "GreenAsia Joystick", 0, 0},
    {0x0E8F, 0x0012, "GreenAsia Joystick", 0, 0},
    {0x0E8F, 0x3010, "GreenAsia PS2 Adapter", 0, 0},
    {0x0E8F, 0x3013, "GreenAsia PS2 Adapter", 0, 0},
    {0x11C9, 0x55F0, "Nacon GC-100XF", 0, 0},
    {0x12BD, 0xD012, "2 In 1 Joystick", 0, 0},
    {0x1345, 0x6006, "RetroFlag Gamepad", 0, 0},
    {0x1949, 0x0402, "AmazonBasics Controller", 1, 0},
    {0x1BAD, 0xF016, "MadCatz Xbox 360 Controller", 1, 0},
    {0x1BAD, 0xF018, "MadCatz Xbox 360 FightPad", 1, 0},
    {0x1BAD, 0xF019, "MadCatz Brawlstick", 1, 0},
    {0x1BAD, 0xF501, "MadCatz Xbox 360 Controller", 1, 0},
    {0x1BAD, 0xF502, "MadCatz Xbox 360 Controller", 1, 0},
    {0x24C6, 0x5000, "Razer Atrox", 1, 0},
    {0x24C6, 0x5300, "PowerA Mini Pro EX", 1, 0},
    {0x24C6, 0x5303, "Xbox Airflo Wired", 1, 0},
    {0x24C6, 0x530A, "Xbox Rock Candy", 1, 0},
    {0x24C6, 0x5500, "HORI Fighting Commander", 1, 0},
    {0x24C6, 0x5501, "HORI Fighting Stick VX", 1, 0},
    {0x24C6, 0x5502, "HORI Fighting Stick EX2", 1, 0},
    {0x24C6, 0x5503, "HORI Fighting Edge", 1, 0},
    {0x24C6, 0x550D, "HORI Fighting Commander", 1, 0},
    {0x24C6, 0x550E, "HORI Real Arcade Pro V Kai", 1, 0},
    {0x24C6, 0x5510, "HORI Fighting Commander ONE", 1, 0},
    {0x24C6, 0x5B00, "Thrustmaster GPX", 1, 0},
    {0x24C6, 0x5B02, "Thrustmaster GPX Controller", 1, 0},
    {0x24C6, 0x5B03, "Thrustmaster Ferrari 458", 1, 0},
    {0x24C6, 0xFAFE, "Rock Candy Xbox 360", 1, 0},
    
    // ==================== Backbone ====================
    {0x358A, 0x0002, "Backbone One", 1, 0},
    {0x358A, 0x0003, "Backbone One PlayStation", 2, 64},
    {0x358A, 0x0004, "Backbone One", 1, 0},
    
    // ==================== Moga ====================
    {0xC624, 0x2A89, "Moga XP5-X Plus", 1, 0},
    {0xC624, 0x2B89, "Moga XP5-X Plus", 1, 0},
    {0xC624, 0x1A89, "Moga XP5-X Plus", 1, 0},
    {0xC624, 0x1B89, "Moga XP5-X Plus", 1, 0},
    
    // ==================== SCUF / Victrix ====================
    {0x0C12, 0x0EF6, "Hitbox Arcade", 2, 64},
    {0x0C12, 0x1CF6, "Victrix Pro FS", 2, 64},
    {0x0C12, 0x0E1C, "SCUF Impact", 2, 64},
    {0x0C12, 0x0E15, "SCUF Infinity4PS Pro", 2, 64},
    
    // ==================== AYN / Handheld ====================
    {0x2F24, 0x0082, "AYN Odin", 1, 0},
    {0x2F24, 0x0086, "AYN Odin 2", 1, 0},
    {0x2F24, 0x008D, "AYN Odin2 Mini", 1, 0},
    {0x3285, 0x0E1D, "GPD Win Controller", 1, 0},
    {0x3285, 0x0E20, "GPD Win Controller", 1, 0},
    
    // ==================== Gamesir / Flydigi ====================
    {0x3575, 0x0620, "GameSir Nova", 1, 0},
    {0x3575, 0x0621, "GameSir Nova", 1, 0},
    
    // ==================== 通用 USB 手柄 ====================
    // 注意: VID 0x413D 不在数据库中，需要用户测试后添加正确的报告格式
    {0x045E, 0x0026, "SideWinder GamePad Pro", 0, 0},
    {0x045E, 0x0027, "SideWinder", 0, 0},
    {0x1A34, 0x0802, "Generic Xbox Gamepad", 1, 0},
    {0x1A34, 0x0836, "Generic Xbox Gamepad", 1, 0},
    {0x2563, 0x0575, "Generic Switch Controller", 3, 0},
    {0x2563, 0x0526, "Generic Switch Controller", 3, 0},
    {0x0001, 0x0001, "Generic USB Gamepad", 0, 0},  // 超通用回退
    
    // 结束标记
    {0, 0, NULL, 0, 0}
};

// ==================== VID 回退表 (当 PID 未知时使用) ====================
// 基于厂商 VID 推断手柄类型

typedef struct {
    uint16_t vendorId;
    const char* vendorName;
    int32_t defaultType;
} VendorFallback;

static const VendorFallback g_vendorFallbacks[] = {
    {0x045E, "Microsoft", 1},           // Xbox
    {0x054C, "Sony", 2},                // PlayStation
    {0x057E, "Nintendo", 3},            // Switch
    {0x2DC8, "8BitDo", 1},              // Usually Xbox mode
    {0x046D, "Logitech", 1},            // XInput mode
    {0x1532, "Razer", 1},               // Usually Xbox
    {0x0F0D, "HORI", 1},                // Varies
    {0x20D6, "PowerA", 1},              // Xbox/Switch
    {0x0E6F, "PDP", 1},                 // Xbox
    {0x0738, "MadCatz", 1},             // Xbox
    {0x1038, "SteelSeries", 1},         // Xbox
    {0x044F, "Thrustmaster", 1},        // Xbox
    {0x11C0, "Nacon", 2},               // PlayStation
    {0x146B, "BigBen", 2},              // PlayStation
    {0x2C22, "Qanba", 2},               // PlayStation
    {0x3820, "GuliKit", 3},             // Switch
    // 注意: 0x413D 不在回退表中，需要用户提供正确的 HID 报告格式
    {0x0079, "DragonRise", 0},          // Generic
    {0x0810, "Generic", 0},             // Generic
    {0x0001, "Generic", 0},             // Generic
    {0, NULL, 0}
};

// ==================== 手柄信息查询 ====================

/**
 * 查找手柄信息 (精确匹配 VID/PID)
 */
static const KnownGamepad* findGamepad(uint16_t vendorId, uint16_t productId) {
    for (int i = 0; g_knownGamepads[i].name != NULL; i++) {
        if (g_knownGamepads[i].vendorId == vendorId && 
            g_knownGamepads[i].productId == productId) {
            return &g_knownGamepads[i];
        }
    }
    return NULL;
}

/**
 * 基于 VID 推断手柄类型 (当 PID 未知时)
 * @return 类型: 0=Unknown, 1=Xbox, 2=PlayStation, 3=Switch
 */
static int32_t inferGamepadTypeByVendor(uint16_t vendorId) {
    for (int i = 0; g_vendorFallbacks[i].vendorName != NULL; i++) {
        if (g_vendorFallbacks[i].vendorId == vendorId) {
            LOGI("Using vendor fallback: VID=0x%04X -> type=%d (%s)", 
                 vendorId, g_vendorFallbacks[i].defaultType, g_vendorFallbacks[i].vendorName);
            return g_vendorFallbacks[i].defaultType;
        }
    }
    return 0; // Generic
}

/**
 * 获取手柄类型 (优先精确匹配，否则用 VID 回退)
 */
static int32_t getGamepadType(uint16_t vendorId, uint16_t productId) {
    const KnownGamepad* gamepad = findGamepad(vendorId, productId);
    if (gamepad) {
        return gamepad->type;
    }
    return inferGamepadTypeByVendor(vendorId);
}

// ==================== HID 报告解析 ====================

/**
 * 解析通用 USB HID 手柄报告
 * 
 * 尝试几种常见的 DirectInput 手柄报告格式：
 * 
 * 格式1 (8字节标准 DI): 大多数便宜手柄
 * [0] = Left Stick X (0-255, 128=center)
 * [1] = Left Stick Y
 * [2] = Right Stick X
 * [3] = Right Stick Y
 * [4] = HAT/D-Pad (0-7 方向, 0x0F/8=neutral)
 * [5] = Buttons 1-8 (A,B,X,Y,LB,RB,Back,Start)
 * [6] = Buttons 9-16 (LS,RS,Home,...)
 * [7] = Z-axis (扳机)
 * 
 * 格式2 (10字节带Report ID):
 * [0] = Report ID (0x01)
 * [1-4] = 摇杆
 * [5] = 按钮/HAT
 * ...
 * 
 * 格式3 (PS3类): 部分国产手柄模仿
 */
static void parseGenericHidReport(const uint8_t* data, size_t len, NapiGamepadState* state) {
    if (len < 8) return;
    
    state->buttons = 0;
    state->leftTrigger = 0;
    state->rightTrigger = 0;
    
    // 检测报告格式
    int format = 0;
    int stickOffset = 0;
    
    // 判断是否有 Report ID 前缀
    // 通常 Report ID = 0x01，且后面的摇杆数据在中间位置
    if (data[0] == 0x01 && len >= 9) {
        // 检查第 1-4 字节是否像摇杆数据（应该在 0x00-0xFF 范围，中心约 0x7F-0x80）
        uint8_t lx = data[1], ly = data[2], rx = data[3], ry = data[4];
        // 如果都在合理范围内且有变化
        if (lx >= 0x00 && lx <= 0xFF && ly >= 0x00 && ly <= 0xFF) {
            format = 2;  // 带 Report ID 的格式
            stickOffset = 1;
        }
    }
    
    if (format == 0) {
        // 格式1: 标准 8 字节 DirectInput
        format = 1;
        stickOffset = 0;
    }
    
    // 解析摇杆 (无论哪种格式，摇杆都是 0-255, 128=中心)
    // 映射 [0, 255] -> [-32768, 32512]，使用 <<8 (*256) 避免 int16_t 溢出
    // 原来的 *257 会导致边界值溢出: (0-128)*257 = -32896 溢出为 32640 (错误的正值!)
    state->leftStickX = (int16_t)(((int)data[stickOffset + 0] - 128) << 8);
    state->leftStickY = (int16_t)(((int)data[stickOffset + 1] - 128) << 8);
    state->rightStickX = (int16_t)(((int)data[stickOffset + 2] - 128) << 8);
    state->rightStickY = (int16_t)(((int)data[stickOffset + 3] - 128) << 8);
    
    // 根据格式解析按钮
    if (format == 2 && len >= 9) {
        // 格式2: 带 Report ID (常见国产手柄)
        //
        // 经过对 VID 0x413D, PID 0x2103 手柄的完整实测:
        // [0] = Report ID (0x01)
        // [1-4] = 摇杆 (LX, LY, RX, RY), 中心=0x80
        // [5] = D-Pad/HAT (上=0x00, 右=0x02, 下=0x04, 左=0x06, 空闲=0x0F)
        // [6] = 面板按钮 (A=0x01, B=0x02, X=0x08, Y=0x10, LB=0x40, RB=0x80)
        // [7] = 功能按钮 (Select=0x04, Start=0x08) - 只有 [8]=0x00 时有效
        // [8] = 噪声标志 (0x00=有效, 0xFF=噪声)
        // [9] = 扩展 (未使用)
        
        uint8_t hatByte = data[5];     // D-Pad
        uint8_t faceButtons = data[6]; // A/B/X/Y/LB/RB
        uint8_t funcButtons = data[7]; // LT/RT/Select/Start
        uint8_t extraByte = data[8];   // 某些手柄的扩展状态
        
        // 注意：这个手柄的 LT/RT 是数字按钮，不是模拟扳机
        // LT=0x01, RT=0x02
        
        // D-Pad (data[5])
        // 上=0x00, 右=0x02, 下=0x04, 左=0x06, 空闲=0x0F
        // 可能还有对角线：右上=0x01, 右下=0x03, 左下=0x05, 左上=0x07
        switch (hatByte) {
            case 0x00: state->buttons |= BTN_FLAG_UP; break;
            case 0x01: state->buttons |= BTN_FLAG_UP | BTN_FLAG_RIGHT; break;
            case 0x02: state->buttons |= BTN_FLAG_RIGHT; break;
            case 0x03: state->buttons |= BTN_FLAG_DOWN | BTN_FLAG_RIGHT; break;
            case 0x04: state->buttons |= BTN_FLAG_DOWN; break;
            case 0x05: state->buttons |= BTN_FLAG_DOWN | BTN_FLAG_LEFT; break;
            case 0x06: state->buttons |= BTN_FLAG_LEFT; break;
            case 0x07: state->buttons |= BTN_FLAG_UP | BTN_FLAG_LEFT; break;
            // 0x0F 或其他 = 空闲
        }
        
        // 面板按钮 (data[6]) - 实测映射
        if (faceButtons & 0x01) state->buttons |= BTN_FLAG_A;
        if (faceButtons & 0x02) state->buttons |= BTN_FLAG_B;
        if (faceButtons & 0x08) state->buttons |= BTN_FLAG_X;
        if (faceButtons & 0x10) state->buttons |= BTN_FLAG_Y;
        if (faceButtons & 0x40) state->buttons |= BTN_FLAG_LB;
        if (faceButtons & 0x80) state->buttons |= BTN_FLAG_RB;
        // 0x04 和 0x20 未使用
        
        // 功能按钮 (data[7]) - 包含 LT/RT/Select/Start
        // LT=0x01, RT=0x02, Select=0x04, Start=0x08
        if (funcButtons & 0x04) state->buttons |= BTN_FLAG_BACK;   // Select
        if (funcButtons & 0x08) state->buttons |= BTN_FLAG_START;  // Start
        // VID 0x413D 实测: LS=0x20, RS=0x40
        // 注意：原来假设是 LS=0x10, RS=0x20，但用户实测发现 L3 显示 RS_CLK(0x80)，R3 显示 HOME(0x400)
        // 说明需要修正映射：L3 在 bit5(0x20)，R3 在 bit6(0x40)
        if (funcButtons & 0x20) state->buttons |= BTN_FLAG_LS_CLK;  // L3 (实测为 0x20)
        if (funcButtons & 0x40) state->buttons |= BTN_FLAG_RS_CLK;  // R3 (实测为 0x40)
        if (funcButtons & 0x10) state->buttons |= BTN_FLAG_HOME;    // Home (移到 0x10)
        
        // LT/RT 是数字按钮，映射为模拟扳机的最大值
        if (funcButtons & 0x01) {
            state->leftTrigger = 255;  // LT 按下
        }
        if (funcButtons & 0x02) {
            state->rightTrigger = 255; // RT 按下
        }
        
    } else {
        // 格式1: 标准 DirectInput 8 字节
        uint8_t hat = data[4];
        uint8_t btns1 = data[5];
        uint8_t btns2 = (len > 6) ? data[6] : 0;
        
        // HAT (低 4 位, 0x0F = neutral)
        uint8_t hatDir = hat & 0x0F;
        if (hatDir <= 7) {
            static const uint32_t hatMap[] = {
                BTN_FLAG_UP,                          // 0
                BTN_FLAG_UP | BTN_FLAG_RIGHT,         // 1
                BTN_FLAG_RIGHT,                       // 2
                BTN_FLAG_DOWN | BTN_FLAG_RIGHT,       // 3
                BTN_FLAG_DOWN,                        // 4
                BTN_FLAG_DOWN | BTN_FLAG_LEFT,        // 5
                BTN_FLAG_LEFT,                        // 6
                BTN_FLAG_UP | BTN_FLAG_LEFT           // 7
            };
            state->buttons |= hatMap[hatDir];
        }
        
        // 按钮 (标准 DirectInput 位掩码)
        // 通常: 1=X, 2=A, 3=B, 4=Y, 5=LB, 6=RB, 7=LT, 8=RT
        // 或: 1=A, 2=B, 3=X, 4=Y, 5=LB, 6=RB, 7=Back, 8=Start
        if (btns1 & 0x01) state->buttons |= BTN_FLAG_X;
        if (btns1 & 0x02) state->buttons |= BTN_FLAG_A;
        if (btns1 & 0x04) state->buttons |= BTN_FLAG_B;
        if (btns1 & 0x08) state->buttons |= BTN_FLAG_Y;
        if (btns1 & 0x10) state->buttons |= BTN_FLAG_LB;
        if (btns1 & 0x20) state->buttons |= BTN_FLAG_RB;
        if (btns1 & 0x40) state->buttons |= BTN_FLAG_BACK;  // LT作为数字按钮
        if (btns1 & 0x80) state->buttons |= BTN_FLAG_START; // RT作为数字按钮
        
        // 第二组按钮
        if (btns2 & 0x01) state->buttons |= BTN_FLAG_BACK;
        if (btns2 & 0x02) state->buttons |= BTN_FLAG_START;
        if (btns2 & 0x04) state->buttons |= BTN_FLAG_LS_CLK;
        if (btns2 & 0x08) state->buttons |= BTN_FLAG_RS_CLK;
        if (btns2 & 0x10) state->buttons |= BTN_FLAG_HOME;
        
        // Z-axis 作为扳机 (如果有)
        if (len > 7) {
            uint8_t z = data[7];
            if (z < 128) {
                state->leftTrigger = (128 - z) * 2;
            } else if (z > 128) {
                state->rightTrigger = (z - 128) * 2;
            }
        }
    }
    
    // 调试日志 - 仅在有按钮按下时输出以减少日志频率
    // LOGD("Generic HID (fmt=%d): sticks(%d,%d,%d,%d) btns=0x%04x lt=%d rt=%d",
    //      format,
    //      state->leftStickX, state->leftStickY,
    //      state->rightStickX, state->rightStickY,
    //      state->buttons, state->leftTrigger, state->rightTrigger);
}

/**
 * 解析 DualShock 4 报告
 * USB 报告格式 (64 bytes):
 * [0] = Report ID (0x01)
 * [1] = Left Stick X
 * [2] = Left Stick Y
 * [3] = Right Stick X
 * [4] = Right Stick Y
 * [5] = Buttons (D-Pad low 4 bits, Square/X/Circle/Triangle high 4 bits)
 * [6] = Buttons (L1/R1/L2/R2/Share/Options/L3/R3)
 * [7] = PS button + Touchpad
 * [8] = L2 analog
 * [9] = R2 analog
 */
static void parseDS4Report(const uint8_t* data, size_t len, NapiGamepadState* state) {
    if (len < 10) return;
    
    // 调试：打印前 16 字节的数据
    LOGI("DS4 Report (len=%zu): %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X",
         len,
         data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
         data[8], data[9], data[10], data[11], data[12], data[13], data[14], data[15]);
    
    // 摇杆 (0x00-0xFF -> -32768 to 32512)
    // 使用 <<8 (*256) 避免 int16_t 溢出导致的方向反转
    // Y 轴方向由上层 GamepadManager 统一处理取反
    state->leftStickX = (int16_t)(((int)data[1] - 128) << 8);
    state->leftStickY = (int16_t)(((int)data[2] - 128) << 8);
    state->rightStickX = (int16_t)(((int)data[3] - 128) << 8);
    state->rightStickY = (int16_t)(((int)data[4] - 128) << 8);
    
    // 扳机 (模拟)
    state->leftTrigger = data[8];
    state->rightTrigger = data[9];
    
    // 调试：打印扳机值
    LOGI("DS4 Triggers: L2=%d R2=%d", state->leftTrigger, state->rightTrigger);
    
    // D-Pad (low nibble of byte 5)
    state->buttons = 0;
    uint8_t dpad = data[5] & 0x0F;
    switch (dpad) {
        case 0: state->buttons |= BTN_FLAG_UP; break;
        case 1: state->buttons |= BTN_FLAG_UP | BTN_FLAG_RIGHT; break;
        case 2: state->buttons |= BTN_FLAG_RIGHT; break;
        case 3: state->buttons |= BTN_FLAG_DOWN | BTN_FLAG_RIGHT; break;
        case 4: state->buttons |= BTN_FLAG_DOWN; break;
        case 5: state->buttons |= BTN_FLAG_DOWN | BTN_FLAG_LEFT; break;
        case 6: state->buttons |= BTN_FLAG_LEFT; break;
        case 7: state->buttons |= BTN_FLAG_UP | BTN_FLAG_LEFT; break;
        default: break;
    }
    
    // 面板按钮 (high nibble of byte 5)
    if (data[5] & 0x10) state->buttons |= BTN_FLAG_X;       // Square
    if (data[5] & 0x20) state->buttons |= BTN_FLAG_A;       // Cross
    if (data[5] & 0x40) state->buttons |= BTN_FLAG_B;       // Circle
    if (data[5] & 0x80) state->buttons |= BTN_FLAG_Y;       // Triangle
    
    // 肩部按钮 (byte 6)
    if (data[6] & 0x01) state->buttons |= BTN_FLAG_LB;      // L1
    if (data[6] & 0x02) state->buttons |= BTN_FLAG_RB;      // R1
    // L2/R2 数字信号被模拟值覆盖
    if (data[6] & 0x10) state->buttons |= BTN_FLAG_BACK;    // Share
    if (data[6] & 0x20) state->buttons |= BTN_FLAG_START;   // Options
    if (data[6] & 0x40) state->buttons |= BTN_FLAG_LS_CLK;  // L3
    if (data[6] & 0x80) state->buttons |= BTN_FLAG_RS_CLK;  // R3
    
    // PS 按钮 (byte 7)
    if (data[7] & 0x01) state->buttons |= BTN_FLAG_HOME;    // PS
    if (data[7] & 0x02) state->buttons |= BTN_FLAG_TOUCHPAD; // Touchpad click
}

/**
 * 解析 DualSense 报告
 * USB 报告格式 (78 bytes):
 * [0] = Report ID (0x01)
 * [1-4] = 摇杆 (同 DS4)
 * [5-7] = 按钮
 * [8-9] = L2/R2 模拟
 */
static void parseDualSenseReport(const uint8_t* data, size_t len, NapiGamepadState* state) {
    if (len < 10) return;
    
    // 摇杆 (0x00-0xFF -> -32768 to 32512)
    // 使用 <<8 (*256) 避免 int16_t 溢出导致的方向反转
    // Y 轴方向由上层 GamepadManager 统一处理取反
    state->leftStickX = (int16_t)(((int)data[1] - 128) << 8);
    state->leftStickY = (int16_t)(((int)data[2] - 128) << 8);
    state->rightStickX = (int16_t)(((int)data[3] - 128) << 8);
    state->rightStickY = (int16_t)(((int)data[4] - 128) << 8);
    
    // 扳机
    state->leftTrigger = data[5];
    state->rightTrigger = data[6];
    
    // 按钮布局类似 DS4
    state->buttons = 0;
    uint8_t buttons1 = data[8];
    uint8_t buttons2 = data[9];
    uint8_t buttons3 = (len > 10) ? data[10] : 0;
    
    // D-Pad
    uint8_t dpad = buttons1 & 0x0F;
    switch (dpad) {
        case 0: state->buttons |= BTN_FLAG_UP; break;
        case 1: state->buttons |= BTN_FLAG_UP | BTN_FLAG_RIGHT; break;
        case 2: state->buttons |= BTN_FLAG_RIGHT; break;
        case 3: state->buttons |= BTN_FLAG_DOWN | BTN_FLAG_RIGHT; break;
        case 4: state->buttons |= BTN_FLAG_DOWN; break;
        case 5: state->buttons |= BTN_FLAG_DOWN | BTN_FLAG_LEFT; break;
        case 6: state->buttons |= BTN_FLAG_LEFT; break;
        case 7: state->buttons |= BTN_FLAG_UP | BTN_FLAG_LEFT; break;
        default: break;
    }
    
    // 面板按钮
    if (buttons1 & 0x10) state->buttons |= BTN_FLAG_X;
    if (buttons1 & 0x20) state->buttons |= BTN_FLAG_A;
    if (buttons1 & 0x40) state->buttons |= BTN_FLAG_B;
    if (buttons1 & 0x80) state->buttons |= BTN_FLAG_Y;
    
    // 肩部按钮
    if (buttons2 & 0x01) state->buttons |= BTN_FLAG_LB;
    if (buttons2 & 0x02) state->buttons |= BTN_FLAG_RB;
    if (buttons2 & 0x10) state->buttons |= BTN_FLAG_BACK;
    if (buttons2 & 0x20) state->buttons |= BTN_FLAG_START;
    if (buttons2 & 0x40) state->buttons |= BTN_FLAG_LS_CLK;
    if (buttons2 & 0x80) state->buttons |= BTN_FLAG_RS_CLK;
    
    // PS/Mute/Touchpad
    if (buttons3 & 0x01) state->buttons |= BTN_FLAG_HOME;
    if (buttons3 & 0x02) state->buttons |= BTN_FLAG_TOUCHPAD;
}

/**
 * 解析 Xbox 系列手柄报告
 */
static void parseXboxReport(const uint8_t* data, size_t len, NapiGamepadState* state) {
    if (len < 17) {
        // 短格式 Xbox 360 风格
        if (len >= 8) {
            state->buttons = 0;
            
            // 按钮 bytes 2-3 (little endian)
            uint16_t btns = data[2] | (data[3] << 8);
            if (btns & 0x0001) state->buttons |= BTN_FLAG_UP;
            if (btns & 0x0002) state->buttons |= BTN_FLAG_DOWN;
            if (btns & 0x0004) state->buttons |= BTN_FLAG_LEFT;
            if (btns & 0x0008) state->buttons |= BTN_FLAG_RIGHT;
            if (btns & 0x0010) state->buttons |= BTN_FLAG_START;
            if (btns & 0x0020) state->buttons |= BTN_FLAG_BACK;
            if (btns & 0x0040) state->buttons |= BTN_FLAG_LS_CLK;
            if (btns & 0x0080) state->buttons |= BTN_FLAG_RS_CLK;
            if (btns & 0x0100) state->buttons |= BTN_FLAG_LB;
            if (btns & 0x0200) state->buttons |= BTN_FLAG_RB;
            if (btns & 0x0400) state->buttons |= BTN_FLAG_HOME;
            if (btns & 0x1000) state->buttons |= BTN_FLAG_A;
            if (btns & 0x2000) state->buttons |= BTN_FLAG_B;
            if (btns & 0x4000) state->buttons |= BTN_FLAG_X;
            if (btns & 0x8000) state->buttons |= BTN_FLAG_Y;
            
            // 扳机 (bytes 4-5)
            state->leftTrigger = data[4];
            state->rightTrigger = data[5];
            
            // 摇杆 (bytes 6-13, little endian int16)
            if (len >= 14) {
                state->leftStickX = (int16_t)(data[6] | (data[7] << 8));
                state->leftStickY = (int16_t)(data[8] | (data[9] << 8));
                state->rightStickX = (int16_t)(data[10] | (data[11] << 8));
                state->rightStickY = (int16_t)(data[12] | (data[13] << 8));
            }
        }
        return;
    }
    
    // 标准 Xbox One / Series 格式
    state->buttons = 0;
    
    uint16_t btns = data[4] | (data[5] << 8);
    if (btns & 0x0001) state->buttons |= BTN_FLAG_UP;
    if (btns & 0x0002) state->buttons |= BTN_FLAG_DOWN;
    if (btns & 0x0004) state->buttons |= BTN_FLAG_LEFT;
    if (btns & 0x0008) state->buttons |= BTN_FLAG_RIGHT;
    if (btns & 0x0010) state->buttons |= BTN_FLAG_START;
    if (btns & 0x0020) state->buttons |= BTN_FLAG_BACK;
    if (btns & 0x0040) state->buttons |= BTN_FLAG_LS_CLK;
    if (btns & 0x0080) state->buttons |= BTN_FLAG_RS_CLK;
    if (btns & 0x0100) state->buttons |= BTN_FLAG_LB;
    if (btns & 0x0200) state->buttons |= BTN_FLAG_RB;
    if (btns & 0x0400) state->buttons |= BTN_FLAG_HOME;
    if (btns & 0x1000) state->buttons |= BTN_FLAG_A;
    if (btns & 0x2000) state->buttons |= BTN_FLAG_B;
    if (btns & 0x4000) state->buttons |= BTN_FLAG_X;
    if (btns & 0x8000) state->buttons |= BTN_FLAG_Y;
    
    // 扳机 (10-bit, bytes 6-9)
    state->leftTrigger = (uint8_t)(((data[6] | (data[7] << 8)) * 255) / 1023);
    state->rightTrigger = (uint8_t)(((data[8] | (data[9] << 8)) * 255) / 1023);
    
    // 摇杆 (16-bit signed, bytes 10-17)
    state->leftStickX = (int16_t)(data[10] | (data[11] << 8));
    state->leftStickY = (int16_t)(data[12] | (data[13] << 8));
    state->rightStickX = (int16_t)(data[14] | (data[15] << 8));
    state->rightStickY = (int16_t)(data[16] | (data[17] << 8));
}

/**
 * 解析 Switch Pro Controller 报告
 */
static void parseSwitchProReport(const uint8_t* data, size_t len, NapiGamepadState* state) {
    if (len < 12) return;
    
    state->buttons = 0;
    
    // Switch Pro 标准输入报告 (0x30)
    if (data[0] == 0x30 && len >= 13) {
        // 按钮 bytes 3-5
        uint8_t b1 = data[3];  // Right side
        uint8_t b2 = data[4];  // Shared buttons
        uint8_t b3 = data[5];  // Left side
        
        // 右侧按钮
        if (b1 & 0x01) state->buttons |= BTN_FLAG_Y;
        if (b1 & 0x02) state->buttons |= BTN_FLAG_X;
        if (b1 & 0x04) state->buttons |= BTN_FLAG_B;
        if (b1 & 0x08) state->buttons |= BTN_FLAG_A;
        if (b1 & 0x40) state->buttons |= BTN_FLAG_RB;
        if (b1 & 0x80) state->buttons |= BTN_FLAG_HOME; // ZR as trigger
        
        // 共享按钮
        if (b2 & 0x01) state->buttons |= BTN_FLAG_BACK;   // Minus
        if (b2 & 0x02) state->buttons |= BTN_FLAG_START;  // Plus
        if (b2 & 0x04) state->buttons |= BTN_FLAG_RS_CLK;
        if (b2 & 0x08) state->buttons |= BTN_FLAG_LS_CLK;
        if (b2 & 0x10) state->buttons |= BTN_FLAG_HOME;
        if (b2 & 0x20) state->buttons |= BTN_FLAG_MISC;   // Capture
        
        // 左侧按钮
        if (b3 & 0x01) state->buttons |= BTN_FLAG_DOWN;
        if (b3 & 0x02) state->buttons |= BTN_FLAG_UP;
        if (b3 & 0x04) state->buttons |= BTN_FLAG_RIGHT;
        if (b3 & 0x08) state->buttons |= BTN_FLAG_LEFT;
        if (b3 & 0x40) state->buttons |= BTN_FLAG_LB;
        
        // 摇杆 (12-bit, packed)
        // Left stick: bytes 6-8
        int16_t lx = data[6] | ((data[7] & 0x0F) << 8);
        int16_t ly = (data[7] >> 4) | (data[8] << 4);
        // Right stick: bytes 9-11
        int16_t rx = data[9] | ((data[10] & 0x0F) << 8);
        int16_t ry = (data[10] >> 4) | (data[11] << 4);
        
        // 转换到 -32768 to 32767
        // Y 轴方向由上层 GamepadManager 统一处理取反
        state->leftStickX = (int16_t)((lx - 2048) * 16);
        state->leftStickY = (int16_t)((ly - 2048) * 16);
        state->rightStickX = (int16_t)((rx - 2048) * 16);
        state->rightStickY = (int16_t)((ry - 2048) * 16);
        
        // Switch Pro 没有模拟扳机
        state->leftTrigger = (b3 & 0x80) ? 255 : 0;  // ZL
        state->rightTrigger = (b1 & 0x80) ? 255 : 0; // ZR
    }
}

// ==================== NAPI 函数实现 ====================

napi_value GamepadNapi_ParseHidReport(napi_env env, napi_callback_info info) {
    size_t argc = 4;  // 支持可选的第4个参数（强制协议类型）
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    
    if (argc < 3) {
        napi_throw_error(env, NULL, "Expected 3-4 arguments: vendorId, productId, data, [forceType]");
        return NULL;
    }
    
    // 获取 VID/PID
    uint32_t vendorId, productId;
    napi_get_value_uint32(env, args[0], &vendorId);
    napi_get_value_uint32(env, args[1], &productId);
    
    // 获取可选的强制协议类型
    // 0 = 自动检测, 1 = Xbox, 2 = PlayStation(DS4/DualSense), 3 = Switch, 4 = Generic
    int forceType = 0;
    if (argc >= 4) {
        napi_valuetype type;
        napi_typeof(env, args[3], &type);
        if (type == napi_number) {
            napi_get_value_int32(env, args[3], &forceType);
        }
    }
    
    // 获取数据
    bool isArrayBuffer;
    napi_is_arraybuffer(env, args[2], &isArrayBuffer);
    
    uint8_t* data;
    size_t len;
    
    if (isArrayBuffer) {
        napi_get_arraybuffer_info(env, args[2], (void**)&data, &len);
    } else {
        // 尝试作为 TypedArray
        napi_typedarray_type type;
        napi_value arrayBuffer;
        size_t offset;
        napi_get_typedarray_info(env, args[2], &type, &len, (void**)&data, &arrayBuffer, &offset);
    }
    
    // 解析报告
    NapiGamepadState state = {0};
    state.deviceId = 0;
    
    // 使用强制类型或自动推断
    int type = (forceType > 0) ? forceType : getGamepadType((uint16_t)vendorId, (uint16_t)productId);
    
    // 记录日志帮助调试
    if (forceType > 0) {
        LOGI("Force protocol type=%d for VID=0x%04X PID=0x%04X", forceType, vendorId, productId);
    } else {
        const KnownGamepad* gamepad = findGamepad((uint16_t)vendorId, (uint16_t)productId);
        if (!gamepad) {
            LOGI("Unknown gamepad VID=0x%04X PID=0x%04X, using inferred type=%d", vendorId, productId, type);
        }
    }
    
    // 尝试使用 SDL GameControllerDB 映射
    // 对于 Generic 类型 (0 或 4)，优先查找 SDL 映射数据库
    bool usedSDLMapping = false;
    if (type == 0 || type == 4) {
        const GamepadMapping* sdlMapping = findGamepadMapping((uint16_t)vendorId, (uint16_t)productId);
        if (sdlMapping) {
            LOGI("Using SDL GameControllerDB mapping for %s (VID=0x%04X PID=0x%04X)",
                 sdlMapping->name, vendorId, productId);
            applyGamepadMapping(
                sdlMapping,
                data, (int)len,
                &state.buttons,
                &state.leftStickX, &state.leftStickY,
                &state.rightStickX, &state.rightStickY,
                &state.leftTrigger, &state.rightTrigger
            );
            usedSDLMapping = true;
        }
    }
    
    // 如果没有使用 SDL 映射，使用传统解析器
    if (!usedSDLMapping) {
        switch (type) {
            case 1: // Xbox
                parseXboxReport(data, len, &state);
                break;
            case 2: // PlayStation (DS4)
                parseDS4Report(data, len, &state);
                break;
            case 3: // Switch
                parseSwitchProReport(data, len, &state);
                break;
            case 5: // DualSense (PS5)
                parseDualSenseReport(data, len, &state);
                break;
            default: // Generic (0 or 4)
                parseGenericHidReport(data, len, &state);
                break;
        }
    }
    
    // 创建返回对象
    napi_value result;
    napi_create_object(env, &result);
    
    napi_value val;
    napi_create_int32(env, state.deviceId, &val);
    napi_set_named_property(env, result, "deviceId", val);
    
    napi_create_uint32(env, state.buttons, &val);
    napi_set_named_property(env, result, "buttons", val);
    
    napi_create_int32(env, state.leftStickX, &val);
    napi_set_named_property(env, result, "leftStickX", val);
    
    napi_create_int32(env, state.leftStickY, &val);
    napi_set_named_property(env, result, "leftStickY", val);
    
    napi_create_int32(env, state.rightStickX, &val);
    napi_set_named_property(env, result, "rightStickX", val);
    
    napi_create_int32(env, state.rightStickY, &val);
    napi_set_named_property(env, result, "rightStickY", val);
    
    napi_create_uint32(env, state.leftTrigger, &val);
    napi_set_named_property(env, result, "leftTrigger", val);
    
    napi_create_uint32(env, state.rightTrigger, &val);
    napi_set_named_property(env, result, "rightTrigger", val);
    
    return result;
}

napi_value GamepadNapi_GetGamepadType(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    
    uint32_t vendorId, productId;
    napi_get_value_uint32(env, args[0], &vendorId);
    napi_get_value_uint32(env, args[1], &productId);
    
    // 使用增强的类型推断（精确匹配 + VID 回退）
    int32_t type = getGamepadType((uint16_t)vendorId, (uint16_t)productId);
    
    napi_value result;
    napi_create_int32(env, type, &result);
    return result;
}

napi_value GamepadNapi_IsSupportedGamepad(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    
    uint32_t vendorId, productId;
    napi_get_value_uint32(env, args[0], &vendorId);
    napi_get_value_uint32(env, args[1], &productId);
    
    // 精确匹配或已知厂商都视为支持
    const KnownGamepad* gamepad = findGamepad((uint16_t)vendorId, (uint16_t)productId);
    bool supported = (gamepad != NULL);
    
    // 如果没有精确匹配，检查是否为已知厂商
    if (!supported) {
        int32_t inferredType = inferGamepadTypeByVendor((uint16_t)vendorId);
        supported = (inferredType != 0); // 非 Generic 类型视为支持
    }
    
    napi_value result;
    napi_get_boolean(env, supported, &result);
    return result;
}

napi_value GamepadNapi_GetGamepadName(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    
    uint32_t vendorId, productId;
    napi_get_value_uint32(env, args[0], &vendorId);
    napi_get_value_uint32(env, args[1], &productId);
    
    const KnownGamepad* gamepad = findGamepad((uint16_t)vendorId, (uint16_t)productId);
    
    // 使用静态缓冲区存储生成的名称（线程不安全，但简单）
    static char nameBuffer[64];
    const char* name;
    
    if (gamepad) {
        name = gamepad->name;
    } else {
        // 尝试基于 VID 生成有意义的名称
        const char* vendorName = "Unknown";
        for (int i = 0; g_vendorFallbacks[i].vendorName != NULL; i++) {
            if (g_vendorFallbacks[i].vendorId == (uint16_t)vendorId) {
                vendorName = g_vendorFallbacks[i].vendorName;
                break;
            }
        }
        snprintf(nameBuffer, sizeof(nameBuffer), "%s Gamepad (0x%04X:0x%04X)", 
                 vendorName, vendorId, productId);
        name = nameBuffer;
    }
    
    napi_value result;
    napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &result);
    return result;
}

/**
 * 检查是否有 SDL GameControllerDB 映射
 * hasSDLMapping(vendorId, productId) -> boolean
 */
napi_value GamepadNapi_HasSDLMapping(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    
    uint32_t vendorId, productId;
    napi_get_value_uint32(env, args[0], &vendorId);
    napi_get_value_uint32(env, args[1], &productId);
    
    const GamepadMapping* mapping = findGamepadMapping((uint16_t)vendorId, (uint16_t)productId);
    
    napi_value result;
    napi_get_boolean(env, mapping != NULL, &result);
    return result;
}

/**
 * 获取 SDL 映射信息
 * getSDLMappingInfo(vendorId, productId) -> { name: string, hasMapping: boolean } | null
 */
napi_value GamepadNapi_GetSDLMappingInfo(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    
    uint32_t vendorId, productId;
    napi_get_value_uint32(env, args[0], &vendorId);
    napi_get_value_uint32(env, args[1], &productId);
    
    const GamepadMapping* mapping = findGamepadMapping((uint16_t)vendorId, (uint16_t)productId);
    
    if (!mapping) {
        // 尝试获取默认映射
        mapping = getDefaultMappingByVendor((uint16_t)vendorId);
    }
    
    napi_value result;
    napi_create_object(env, &result);
    
    napi_value val;
    if (mapping) {
        napi_create_string_utf8(env, mapping->name, NAPI_AUTO_LENGTH, &val);
        napi_set_named_property(env, result, "name", val);
        
        napi_get_boolean(env, true, &val);
        napi_set_named_property(env, result, "hasMapping", val);
        
        // 返回映射类型信息
        const char* mappingType = "generic";
        const GamepadMapping* exact = findGamepadMapping((uint16_t)vendorId, (uint16_t)productId);
        if (exact) {
            mappingType = "exact";
        } else {
            mappingType = "vendor-default";
        }
        napi_create_string_utf8(env, mappingType, NAPI_AUTO_LENGTH, &val);
        napi_set_named_property(env, result, "mappingType", val);
    } else {
        napi_get_null(env, &result);
    }
    
    return result;
}

napi_value GamepadNapi_CreateRumbleCommand(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    
    uint32_t vendorId, productId, lowFreq, highFreq;
    napi_get_value_uint32(env, args[0], &vendorId);
    napi_get_value_uint32(env, args[1], &productId);
    napi_get_value_uint32(env, args[2], &lowFreq);
    napi_get_value_uint32(env, args[3], &highFreq);
    
    // 获取手柄类型（使用增强的回退逻辑）
    int32_t type = getGamepadType((uint16_t)vendorId, (uint16_t)productId);
    if (type == 0) {
        // Generic 类型不支持震动
        napi_value result;
        napi_get_null(env, &result);
        return result;
    }
    
    // 根据手柄类型生成不同的 Rumble 命令
    uint8_t cmd[64] = {0};
    size_t cmdLen = 0;
    
    switch (type) {
        case 2: // PlayStation
            if (productId == 0x0CE6 || productId == 0x0DF2 || productId == 0x0E5F) {
                // DualSense rumble
                cmd[0] = 0x02;
                cmd[1] = 0x03;  // Flag for motor rumble
                cmd[2] = 0x00;  // Flags
                cmd[3] = (uint8_t)(lowFreq >> 8);   // Right motor
                cmd[4] = (uint8_t)(highFreq >> 8);  // Left motor
                cmdLen = 48;
            } else {
                // DS4 rumble
                cmd[0] = 0x05;
                cmd[1] = 0xFF;
                cmd[4] = (uint8_t)(highFreq >> 8);  // Big motor
                cmd[5] = (uint8_t)(lowFreq >> 8);   // Small motor
                cmdLen = 32;
            }
            break;
            
        case 3: // Switch
            // Switch Pro Controller uses different rumble format
            // This is a simplified version
            cmd[0] = 0x10;  // Rumble command
            cmd[1] = 0x00;
            // HD rumble data (simplified)
            cmd[2] = (lowFreq > 0) ? 0x80 : 0x00;
            cmd[6] = (highFreq > 0) ? 0x80 : 0x00;
            cmdLen = 10;
            break;
            
        default:
            // Generic/Xbox - many don't support rumble via HID output
            napi_value result;
            napi_get_null(env, &result);
            return result;
    }
    
    // 创建 Uint8Array
    void* cmdData;
    napi_value arrayBuffer, result;
    napi_create_arraybuffer(env, cmdLen, &cmdData, &arrayBuffer);
    memcpy(cmdData, cmd, cmdLen);
    napi_create_typedarray(env, napi_uint8_array, cmdLen, arrayBuffer, 0, &result);
    
    return result;
}

napi_value GamepadNapi_Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"parseHidReport", NULL, GamepadNapi_ParseHidReport, NULL, NULL, NULL, napi_default, NULL},
        {"getGamepadType", NULL, GamepadNapi_GetGamepadType, NULL, NULL, NULL, napi_default, NULL},
        {"isSupportedGamepad", NULL, GamepadNapi_IsSupportedGamepad, NULL, NULL, NULL, napi_default, NULL},
        {"getGamepadName", NULL, GamepadNapi_GetGamepadName, NULL, NULL, NULL, napi_default, NULL},
        {"createRumbleCommand", NULL, GamepadNapi_CreateRumbleCommand, NULL, NULL, NULL, napi_default, NULL},
        // SDL GameControllerDB 映射相关
        {"hasSDLMapping", NULL, GamepadNapi_HasSDLMapping, NULL, NULL, NULL, napi_default, NULL},
        {"getSDLMappingInfo", NULL, GamepadNapi_GetSDLMappingInfo, NULL, NULL, NULL, napi_default, NULL},
    };
    
    napi_value gamepadObj;
    napi_create_object(env, &gamepadObj);
    napi_define_properties(env, gamepadObj, sizeof(desc) / sizeof(desc[0]), desc);
    napi_set_named_property(env, exports, "Gamepad", gamepadObj);
    
    LOGI("GamepadNapi initialized with SDL GameControllerDB support");
    return exports;
}
