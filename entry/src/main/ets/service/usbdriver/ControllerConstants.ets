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
 * USB 控制器常量定义
 * 
 * 参考 Android moonlight-android ControllerPacket
 */

// 按钮标志位定义
export class ButtonFlags {
  static readonly UP_FLAG: number = 0x0001;
  static readonly DOWN_FLAG: number = 0x0002;
  static readonly LEFT_FLAG: number = 0x0004;
  static readonly RIGHT_FLAG: number = 0x0008;
  static readonly PLAY_FLAG: number = 0x0010;     // Start
  static readonly BACK_FLAG: number = 0x0020;     // Select/Back
  static readonly LS_CLK_FLAG: number = 0x0040;   // 左摇杆按下
  static readonly RS_CLK_FLAG: number = 0x0080;   // 右摇杆按下
  static readonly LB_FLAG: number = 0x0100;       // 左肩键
  static readonly RB_FLAG: number = 0x0200;       // 右肩键
  static readonly SPECIAL_BUTTON_FLAG: number = 0x0400;  // Xbox/PS/Home 按钮
  static readonly A_FLAG: number = 0x1000;
  static readonly B_FLAG: number = 0x2000;
  static readonly X_FLAG: number = 0x4000;
  static readonly Y_FLAG: number = 0x8000;
  static readonly TOUCHPAD_FLAG: number = 0x040000;  // 触摸板按钮 (DualShock4/DualSense)
  static readonly MISC_FLAG: number = 0x080000;      // 杂项按钮 (Capture 等)
}

// 控制器类型
export class ControllerType {
  static readonly UNKNOWN: number = 0;
  static readonly XBOX: number = 1;
  static readonly PS: number = 2;
  static readonly NINTENDO: number = 3;
}

// 控制器能力标志
export class ControllerCapabilities {
  static readonly ANALOG_TRIGGERS: number = 0x01;   // 模拟扳机
  static readonly RUMBLE: number = 0x02;            // 震动反馈
  static readonly TRIGGER_RUMBLE: number = 0x04;    // 扳机震动
  static readonly TOUCHPAD: number = 0x08;          // 触摸板
  static readonly ACCEL: number = 0x10;             // 加速度计
  static readonly GYRO: number = 0x20;              // 陀螺仪
  static readonly BATTERY: number = 0x40;           // 电池状态
  static readonly RGB_LED: number = 0x80;           // RGB LED
}

// 运动数据类型
export class MotionType {
  static readonly GYRO: number = 1;
  static readonly ACCEL: number = 2;
}

// D-Pad 方向值（用于 DualShock 风格的 D-Pad）
export class DPadDirection {
  static readonly UP: number = 0;
  static readonly UP_RIGHT: number = 1;
  static readonly RIGHT: number = 2;
  static readonly DOWN_RIGHT: number = 3;
  static readonly DOWN: number = 4;
  static readonly DOWN_LEFT: number = 5;
  static readonly LEFT: number = 6;
  static readonly UP_LEFT: number = 7;
  static readonly NEUTRAL: number = 8;
}

// USB 设备类常量
export class UsbClass {
  static readonly USB_CLASS_HID: number = 3;
  static readonly USB_CLASS_VENDOR_SPEC: number = 255;
}

// USB 传输方向
export class UsbDirection {
  static readonly USB_DIR_IN: number = 0x80;
  static readonly USB_DIR_OUT: number = 0x00;
}

// Xbox 360 常量
export class Xbox360 {
  static readonly IFACE_SUBCLASS: number = 93;
  static readonly IFACE_PROTOCOL: number = 1;  // Wired only
  static readonly SUPPORTED_VENDORS: number[] = [
    0x0079, // GPD Win 2
    0x044f, // Thrustmaster
    0x045e, // Microsoft
    0x046d, // Logitech
    0x056e, // Elecom
    0x06a3, // Saitek
    0x0738, // Mad Catz
    0x07ff, // Mad Catz
    0x0e6f, // Unknown
    0x0f0d, // Hori
    0x1038, // SteelSeries
    0x11c9, // Nacon
    0x1209, // Ardwiino
    0x12ab, // Unknown
    0x1430, // RedOctane
    0x146b, // BigBen
    0x1532, // Razer Sabertooth
    0x15e4, // Numark
    0x162e, // Joytech
    0x1689, // Razer Onza
    0x1949, // Lab126 (Amazon Luna)
    0x1bad, // Harmonix
    0x20d6, // PowerA
    0x24c6, // PowerA
    0x2f24, // GameSir
    0x2dc8, // 8BitDo
  ];
}

// Xbox One 常量
export class XboxOne {
  static readonly IFACE_SUBCLASS: number = 71;
  static readonly IFACE_PROTOCOL: number = 208;
  static readonly SUPPORTED_VENDORS: number[] = [
    0x045e, // Microsoft
    0x0738, // Mad Catz
    0x0e6f, // Unknown
    0x0f0d, // Hori
    0x1532, // Razer Wildcat
    0x20d6, // PowerA
    0x24c6, // PowerA
    0x2e24, // Hyperkin
    0x2dc8, // 8BitDo
  ];
}

// DualShock 4 常量
export class DualShock4 {
  static readonly VID: number = 0x054C;  // Sony
  static readonly PIDS: number[] = [
    0x05c4,  // DualShock 4 v1
    0x09cc,  // DualShock 4 v2
  ];
}

// DualSense 常量
export class DualSense {
  static readonly VID: number = 0x054C;  // Sony
  static readonly PIDS: number[] = [
    0x0ce6,  // DualSense
    0x0df2,  // DualSense Edge
  ];
}

// Nintendo Switch 常量
export class SwitchPro {
  static readonly VID: number = 0x057e;  // Nintendo
  static readonly PRO_PID: number = 0x2009;
  static readonly JOYCON_LEFT_PID: number = 0x2006;
  static readonly JOYCON_RIGHT_PID: number = 0x2007;
  static readonly JOYCON_PAIR_PID: number = 0x2008;
}
