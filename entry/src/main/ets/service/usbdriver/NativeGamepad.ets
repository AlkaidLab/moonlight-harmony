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
 * Native Gamepad NAPI 接口声明
 * 
 * 暴露原生层的 HID 手柄解析功能
 */

/**
 * 手柄状态接口
 */
export interface NativeGamepadState {
  deviceId: number;
  buttons: number;
  leftStickX: number;
  leftStickY: number;
  rightStickX: number;
  rightStickY: number;
  leftTrigger: number;
  rightTrigger: number;
}

/**
 * 按钮标志位常量 (与 Moonlight 协议一致)
 */
export class NativeButtonFlags {
  static readonly UP: number = 0x0001;
  static readonly DOWN: number = 0x0002;
  static readonly LEFT: number = 0x0004;
  static readonly RIGHT: number = 0x0008;
  static readonly START: number = 0x0010;
  static readonly BACK: number = 0x0020;
  static readonly LS_CLK: number = 0x0040;
  static readonly RS_CLK: number = 0x0080;
  static readonly LB: number = 0x0100;
  static readonly RB: number = 0x0200;
  static readonly HOME: number = 0x0400;
  static readonly A: number = 0x1000;
  static readonly B: number = 0x2000;
  static readonly X: number = 0x4000;
  static readonly Y: number = 0x8000;
  // 扩展按钮
  static readonly PADDLE1: number = 0x00010000;
  static readonly PADDLE2: number = 0x00020000;
  static readonly PADDLE3: number = 0x00040000;
  static readonly PADDLE4: number = 0x00080000;
  static readonly TOUCHPAD: number = 0x00100000;
  static readonly MISC: number = 0x00200000;
}

/**
 * 手柄类型枚举
 */
export enum NativeGamepadType {
  UNKNOWN = 0,
  XBOX = 1,
  PLAYSTATION = 2,
  SWITCH = 3,
}

/**
 * Native Gamepad 接口
 * 
 * 这些方法由原生层 (gamepad_napi.cpp) 实现
 */
export interface NativeGamepadInterface {
  /**
   * 解析 HID 报告数据
   * @param vendorId 设备厂商 ID
   * @param productId 设备产品 ID
   * @param data HID 报告数据
   * @param forceType 可选，强制使用的协议类型 (0=自动, 1=Xbox, 2=DS4, 3=Switch, 5=DualSense)
   * @returns 解析后的手柄状态
   */
  parseHidReport(vendorId: number, productId: number, data: Uint8Array, forceType?: number): NativeGamepadState;

  /**
   * 获取手柄类型
   * @param vendorId 设备厂商 ID
   * @param productId 设备产品 ID
   * @returns 手柄类型 (0=Unknown, 1=Xbox, 2=PlayStation, 3=Switch)
   */
  getGamepadType(vendorId: number, productId: number): number;

  /**
   * 检查是否为支持的手柄
   * @param vendorId 设备厂商 ID
   * @param productId 设备产品 ID
   * @returns 是否支持
   */
  isSupportedGamepad(vendorId: number, productId: number): boolean;

  /**
   * 获取手柄名称
   * @param vendorId 设备厂商 ID
   * @param productId 设备产品 ID
   * @returns 手柄名称
   */
  getGamepadName(vendorId: number, productId: number): string;

  /**
   * 创建震动命令
   * @param vendorId 设备厂商 ID
   * @param productId 设备产品 ID
   * @param lowFreq 低频震动强度 (0-65535)
   * @param highFreq 高频震动强度 (0-65535)
   * @returns 震动命令数据，如果不支持则返回 null
   */
  createRumbleCommand(vendorId: number, productId: number, lowFreq: number, highFreq: number): Uint8Array | null;
}
