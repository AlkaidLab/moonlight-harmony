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
 * Native HID 手柄解析器服务
 * 
 * 封装原生层的 HID 报告解析功能
 * 提供简洁的 ArkTS API
 */

import nativelib from 'libmoonlight_nativelib.so';
import { NativeGamepadState, NativeButtonFlags, NativeGamepadType } from './NativeGamepad';

const TAG = '[NativeHidParser]';

/**
 * 原生 HID 解析器接口 (从 NAPI 导出)
 */
interface NativeGamepadModule {
  parseHidReport(vendorId: number, productId: number, data: Uint8Array, forceType?: number): NativeGamepadState;
  getGamepadType(vendorId: number, productId: number): number;
  isSupportedGamepad(vendorId: number, productId: number): boolean;
  getGamepadName(vendorId: number, productId: number): string;
  createRumbleCommand(vendorId: number, productId: number, lowFreq: number, highFreq: number): Uint8Array | null;
}

/**
 * Native HID 解析器服务
 */
export class NativeHidParserService {
  private static instance: NativeHidParserService | null = null;
  private gamepadModule: NativeGamepadModule | null = null;
  private initialized: boolean = false;

  private constructor() {
  }

  /**
   * 获取单例实例
   */
  static getInstance(): NativeHidParserService {
    if (!NativeHidParserService.instance) {
      NativeHidParserService.instance = new NativeHidParserService();
    }
    return NativeHidParserService.instance;
  }

  /**
   * 初始化服务
   */
  init(): boolean {
    if (this.initialized) {
      return true;
    }

    try {
      // 获取 Gamepad 模块
      // 直接访问 nativelib.Gamepad，避免使用 'in' 操作符
      interface NativeLibWithGamepad {
        Gamepad?: NativeGamepadModule;
      }
      const lib = nativelib as NativeLibWithGamepad;
      if (lib.Gamepad !== undefined) {
        this.gamepadModule = lib.Gamepad;
        this.initialized = true;
        console.info(`${TAG} 原生 Gamepad 模块已加载`);
        return true;
      } else {
        console.error(`${TAG} 原生库中未找到 Gamepad 模块`);
        return false;
      }
    } catch (err) {
      console.error(`${TAG} 加载原生库失败:`, err);
      return false;
    }
  }

  /**
   * 检查是否已初始化
   */
  isInitialized(): boolean {
    return this.initialized;
  }

  /**
   * 解析 HID 报告
   * @param vendorId 设备厂商 ID
   * @param productId 设备产品 ID
   * @param data HID 报告数据
   * @param forceType 可选，强制使用的协议类型 (0=自动, 1=Xbox, 2=DS4, 3=Switch, 5=DualSense)
   * @returns 解析后的手柄状态，如果解析失败返回 null
   */
  parseHidReport(vendorId: number, productId: number, data: Uint8Array, forceType?: number): NativeGamepadState | null {
    if (!this.gamepadModule) {
      console.warn(`${TAG} 服务未初始化`);
      return null;
    }

    try {
      return this.gamepadModule.parseHidReport(vendorId, productId, data, forceType ?? 0);
    } catch (err) {
      console.error(`${TAG} 解析 HID 报告失败:`, err);
      return null;
    }
  }

  /**
   * 获取手柄类型
   * @param vendorId 设备厂商 ID
   * @param productId 设备产品 ID
   * @returns 手柄类型枚举值
   */
  getGamepadType(vendorId: number, productId: number): NativeGamepadType {
    if (!this.gamepadModule) {
      return NativeGamepadType.UNKNOWN;
    }

    try {
      return this.gamepadModule.getGamepadType(vendorId, productId) as NativeGamepadType;
    } catch (err) {
      return NativeGamepadType.UNKNOWN;
    }
  }

  /**
   * 检查是否为支持的手柄
   * @param vendorId 设备厂商 ID
   * @param productId 设备产品 ID
   * @returns 是否支持
   */
  isSupportedGamepad(vendorId: number, productId: number): boolean {
    if (!this.gamepadModule) {
      return false;
    }

    try {
      return this.gamepadModule.isSupportedGamepad(vendorId, productId);
    } catch (err) {
      return false;
    }
  }

  /**
   * 获取手柄名称
   * @param vendorId 设备厂商 ID
   * @param productId 设备产品 ID
   * @returns 手柄名称
   */
  getGamepadName(vendorId: number, productId: number): string {
    if (!this.gamepadModule) {
      return 'Unknown Gamepad';
    }

    try {
      return this.gamepadModule.getGamepadName(vendorId, productId);
    } catch (err) {
      return 'Unknown Gamepad';
    }
  }

  /**
   * 创建震动命令
   * @param vendorId 设备厂商 ID
   * @param productId 设备产品 ID
   * @param lowFreq 低频震动强度 (0-65535)
   * @param highFreq 高频震动强度 (0-65535)
   * @returns 震动命令数据，如果不支持则返回 null
   */
  createRumbleCommand(vendorId: number, productId: number, lowFreq: number, highFreq: number): Uint8Array | null {
    if (!this.gamepadModule) {
      return null;
    }

    try {
      return this.gamepadModule.createRumbleCommand(vendorId, productId, lowFreq, highFreq);
    } catch (err) {
      return null;
    }
  }
}

// 重新导出类型，方便外部使用
export { NativeGamepadState, NativeButtonFlags, NativeGamepadType } from './NativeGamepad';
