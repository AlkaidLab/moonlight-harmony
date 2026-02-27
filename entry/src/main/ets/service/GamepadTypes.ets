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
 * 手柄相关类型定义、常量和按键映射表
 * 从 GamepadManager 中解耦的公共类型模块
 */

// ==================== 类型定义 ====================

/**
 * 手柄状态数据结构
 */
export interface GamepadState {
  buttons: number;
  leftStickX: number;
  leftStickY: number;
  rightStickX: number;
  rightStickY: number;
  leftTrigger: number;
  rightTrigger: number;
}

/**
 * 手柄设备信息
 */
export interface GamepadInfo {
  id: number;
  name: string;
  bus?: number;
  vendor?: number;
  product?: number;
  isUsb?: boolean;
  isBluetooth?: boolean;
}

/**
 * 手柄输入事件监听器接口
 */
export interface GamepadInputListener {
  /**
   * 手柄连接
   * @param deviceId 槽位 ID
   * @param name 设备名称
   * @param controllerType 控制器类型 (0=Unknown, 1=Xbox, 2=PS, 3=Nintendo)
   */
  onGamepadConnected: (deviceId: number, name: string, controllerType: number) => void;
  onGamepadDisconnected: (deviceId: number) => void;
  onGamepadInput: (deviceId: number, state: GamepadState) => void;
}

// ==================== 常量定义 ====================

/** 设备总线类型（Linux input.h BUS_* 定义） */
export class DeviceBusType {
  static readonly BUS_USB = 0x03;
  static readonly BUS_BLUETOOTH = 0x05;
}

/** Moonlight 按键标志位 */
export class MoonlightButton {
  static readonly UP = 0x0001;
  static readonly DOWN = 0x0002;
  static readonly LEFT = 0x0004;
  static readonly RIGHT = 0x0008;
  static readonly START = 0x0010;
  static readonly BACK = 0x0020;
  static readonly LS = 0x0040;
  static readonly RS = 0x0080;
  static readonly LB = 0x0100;
  static readonly RB = 0x0200;
  static readonly SPECIAL = 0x0400;
  static readonly A = 0x1000;
  static readonly B = 0x2000;
  static readonly X = 0x4000;
  static readonly Y = 0x8000;
  static readonly DPAD_MASK = MoonlightButton.UP | MoonlightButton.DOWN | MoonlightButton.LEFT | MoonlightButton.RIGHT;
}

/**
 * 2313 按键动作类型
 * 'guide' - 发送 Guide/Home 键
 * 'select' - 发送 Select/Back 键
 * 'toggle_mouse' - 切换鼠标模式
 * 'toggle_perf' - 切换性能图层
 * 'show_menu' - 显示 ESC 菜单
 * 'none' - 不做任何操作
 */
export type GCButton2313Action = 'guide' | 'select' | 'toggle_mouse' | 'toggle_perf' | 'show_menu' | 'none';

/**
 * 2313 自定义动作回调接口
 */
export interface GCButton2313ActionCallback {
  onToggleMouse?: () => void;
  onTogglePerf?: () => void;
  onShowMenu?: () => void;
}

/** 摇杆轴值范围 */
export const AXIS_MAX = 32767;
export const TRIGGER_MAX = 255;
export const RUMBLE_MAX = 65535;

/**
 * 将无符号 16-bit 值转换为有符号 16-bit 值
 * USB HID 报告中轴数据通常以 uint16 传输，需转换为 int16
 */
export function toSigned16(value: number): number {
  return value > 32767 ? value - 65536 : value;
}

/**
 * 从 Uint8Array 中读取小端序有符号 16-bit 整数
 * 用于解析 USB HID 输入报告中的轴/传感器数据
 */
export function readShortLE(buffer: Uint8Array, offset: number): number {
  const value = buffer[offset] | (buffer[offset + 1] << 8);
  return toSigned16(value);
}

/** 特殊按键码范围（2311-2315）- 仅用于传统 InputKit 路径的设备路由判断 */
export const SPECIAL_KEYCODE_MIN = 2311;
export const SPECIAL_KEYCODE_MAX = 2315;

/** 已知厂商 ID */
export class VendorId {
  static readonly MICROSOFT = 0x045e;
  static readonly SONY = 0x054c;
  static readonly NINTENDO = 0x057e;
}

/** 已知产品 ID */
export class ProductId {
  // Sony
  static readonly DUALSENSE = 0x0ce6;
  static readonly DUALSENSE_EDGE = 0x0df2;
  // Nintendo
  static readonly SWITCH_PRO = 0x2009;
}

/**
 * 控制器类型常量（与 Moonlight 协议 LI_CTYPE_* 一致）
 * 0=Unknown, 1=Xbox, 2=PS, 3=Nintendo
 */
export class MoonlightControllerType {
  static readonly UNKNOWN = 0;
  static readonly XBOX = 1;
  static readonly PS = 2;
  static readonly NINTENDO = 3;

  /**
   * 根据 VID/PID 推断控制器类型
   */
  static fromVendorProduct(vendorId: number, _productId: number): number {
    switch (vendorId) {
      case VendorId.MICROSOFT:
        return MoonlightControllerType.XBOX;
      case VendorId.SONY:
        return MoonlightControllerType.PS;
      case VendorId.NINTENDO:
        return MoonlightControllerType.NINTENDO;
      default:
        return MoonlightControllerType.XBOX;  // 未知设备默认模拟 Xbox
    }
  }

  /**
   * 根据设备名称推断控制器类型（用于 GCK 模式，无 VID/PID 信息时）
   */
  static fromDeviceName(name: string): number {
    const lower = name.toLowerCase();
    if (lower.includes('dualsense') || lower.includes('dualshock') ||
        lower.includes('playstation') || lower.includes('ps5') || lower.includes('ps4')) {
      return MoonlightControllerType.PS;
    }
    if (lower.includes('switch') || lower.includes('nintendo') ||
        lower.includes('joy-con') || lower.includes('joycon') || lower.includes('pro controller')) {
      return MoonlightControllerType.NINTENDO;
    }
    // Xbox / 未知设备默认 Xbox
    return MoonlightControllerType.XBOX;
  }
}

// ==================== 按键映射表 ====================

/** InputKit 按键码到 Moonlight 按钮的映射 */
export const buttonMap = new Map<number, number>([
  // D-Pad
  [19, MoonlightButton.UP],     // KEYCODE_DPAD_UP
  [20, MoonlightButton.DOWN],   // KEYCODE_DPAD_DOWN
  [21, MoonlightButton.LEFT],   // KEYCODE_DPAD_LEFT
  [22, MoonlightButton.RIGHT],  // KEYCODE_DPAD_RIGHT
  // Face buttons
  [96, MoonlightButton.A],      // KEYCODE_BUTTON_A
  [97, MoonlightButton.B],      // KEYCODE_BUTTON_B
  [99, MoonlightButton.X],      // KEYCODE_BUTTON_X
  [100, MoonlightButton.Y],     // KEYCODE_BUTTON_Y
  // Shoulder buttons
  [102, MoonlightButton.LB],    // KEYCODE_BUTTON_L1
  [103, MoonlightButton.RB],    // KEYCODE_BUTTON_R1
  // Stick buttons
  [106, MoonlightButton.LS],    // KEYCODE_BUTTON_THUMBL
  [107, MoonlightButton.RS],    // KEYCODE_BUTTON_THUMBR
  // Start/Back
  [108, MoonlightButton.START], // KEYCODE_BUTTON_START
  [109, MoonlightButton.BACK],  // KEYCODE_BUTTON_SELECT
  // Special
  [110, MoonlightButton.SPECIAL], // KEYCODE_BUTTON_MODE
  // GC Kit 按键码（某些蓝牙手柄可能通过 KeyEvent 发送这些码）
  [2311, MoonlightButton.BACK],   // KEYCODE_BUTTON_SELECT - Select 键
  [2312, MoonlightButton.START],  // KEYCODE_BUTTON_START - Start 键
  [2313, MoonlightButton.SPECIAL], // KEYCODE_BUTTON_MODE - Home 键（可自定义）
  [2314, MoonlightButton.LS],     // KEYCODE_BUTTON_THUMBL - 左摇杆按下
  [2315, MoonlightButton.RS],     // KEYCODE_BUTTON_THUMBR - 右摇杆按下
]);

/** Game Controller Kit 按键码到 Moonlight 按钮的映射 */
export const gcButtonMap = new Map<number, number>([
  // Face buttons
  [2301, MoonlightButton.A],      // BUTTON_A
  [2302, MoonlightButton.B],      // BUTTON_B
  [2303, MoonlightButton.BACK],   // BUTTON_C - 映射为 Select/Back（鸿蒙不支持原生 Select 按键）
  [2304, MoonlightButton.X],      // BUTTON_X
  [2305, MoonlightButton.Y],      // BUTTON_Y
  // Shoulder buttons
  [2307, MoonlightButton.LB],     // LEFT_SHOULDER
  [2308, MoonlightButton.RB],     // RIGHT_SHOULDER
  // Thumbstick buttons
  [2314, MoonlightButton.LS],     // LEFT_THUMBSTICK
  [2315, MoonlightButton.RS],     // RIGHT_THUMBSTICK
  // Menu buttons - 根据测试调整
  [2311, MoonlightButton.BACK],   // 实测为 Select/Back 键
  [2312, MoonlightButton.START],  // BUTTON_MENU (Start)
  [2313, MoonlightButton.SPECIAL],// 默认为 Guide/Home，可用户自定义
  // D-Pad
  [2012, MoonlightButton.UP],     // DPAD_UP
  [2013, MoonlightButton.DOWN],   // DPAD_DOWN
  [2014, MoonlightButton.LEFT],   // DPAD_LEFT
  [2015, MoonlightButton.RIGHT],  // DPAD_RIGHT
]);

/** 手柄设备名称关键词（用于识别手柄） */
export const GAMEPAD_NAME_KEYWORDS: string[] = [
  // 通用关键词
  'controller', 'gamepad', 'joystick', 'joypad',
  'fightstick', 'fight stick', 'arcade stick',
  // 主流主机手柄
  'xbox', 'playstation', 'dualshock', 'dualsense',
  'switch', 'pro controller', 'joycon', 'joy-con', 'stadia', 'ouya',
  // 国际外设品牌
  'gamesir', 'razer', '8bitdo', 'steelseries',
  'logitech', 'hori', 'horipad', 'powera', 'scuf',
  'turtle beach', 'thrustmaster', 'madcatz', 'mad catz',
  'saitek', 'pdp', 'nvidia', 'shield',
  'backbone', 'hyperkin', 'nacon', 'victrix',
  'qanba', 'mayflash', 'gulikit', 'gpd',
  'moga', 'elecom', 'gamevice', 'rotor riot',
  'astro', 'hyperx', 'flashfire',
  // 国产手柄品牌
  'betop', 'beitong', '北通',
  'flydigi', '飞智',
  'pxn', '莱仕达',
  'ipega',
  'mocute', '魔操特',
  'newgame', '新游',
  'rapoo', '雷柏', '小鸡', '盖世小鸡',
  'easysmx', 'bigbigwon', '谷粒',
  'aula', '狼蛛',
];

/** 非手柄设备关键词（用于排除） */
export const NON_GAMEPAD_KEYWORDS: string[] = [
  'keyboard', '键盘', 'mouse', '鼠标', 'touchpad', 'trackpad', '触摸板',
  'watch', '手表', 'wearable', 'band', '手环', 'smartwatch', 'fitness',
  'huawei watch', 'galaxy watch', 'apple watch', 'mi band', 'amazfit'
];

/**
 * 检查设备名是否应被排除
 * 当名称同时包含手柄关键词和非手柄关键词时（如 "Gamesir G8+ keyboard"），
 * 优先视为手柄，不排除
 */
export function isNonGamepadByName(nameLower: string): boolean {
  const hasNonGamepadKeyword = NON_GAMEPAD_KEYWORDS.some(kw => nameLower.includes(kw));
  if (!hasNonGamepadKeyword) return false;
  // 名称同时命中手柄关键词 → 不排除（如 "gamesir g8+ keyboard"）
  const hasGamepadKeyword = GAMEPAD_NAME_KEYWORDS.some(kw => nameLower.includes(kw));
  return !hasGamepadKeyword;
}
