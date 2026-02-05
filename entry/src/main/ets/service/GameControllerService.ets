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
 * 提供统一的 USB/蓝牙手柄输入接口
 * 基于 HarmonyOS Game Controller Kit (API 21+)
 */

import nativeLib from 'libmoonlight_nativelib.so';

/**
 * 设备信息
 */
export interface GameControllerDeviceInfo {
  deviceId: string;
  name: string;
  product: number;
  deviceType: number;  // 0=未知, 1=手柄
  isConnected: boolean;
}

/**
 * 设备状态变化回调
 */
export type DeviceCallback = (deviceId: string, isConnected: boolean, info: GameControllerDeviceInfo) => void;

/**
 * 按键事件回调
 */
export type ButtonCallback = (deviceId: string, buttonCode: number, isPressed: boolean) => void;

/**
 * 轴事件回调
 */
export type AxisCallback = (deviceId: string, axisType: number, x: number, y: number) => void;

/**
 * Game Controller Kit 原生接口
 */
interface NativeGameController {
  isAvailable(): boolean;
  init(): number;
  uninit(): void;
  startMonitor(): number;
  stopMonitor(): void;
  setDeviceCallback(callback: DeviceCallback | null): void;
  setButtonCallback(callback: ButtonCallback | null): void;
  setAxisCallback(callback: AxisCallback | null): void;
  getDeviceCount(): number;
  getDeviceInfo(index: number): GameControllerDeviceInfo | null;
  heartbeatCheck(): number;  // 心跳检测 - 返回断开的设备数量
  
  // 常量
  AXIS_LEFT_THUMBSTICK: number;
  AXIS_RIGHT_THUMBSTICK: number;
  AXIS_DPAD: number;
  AXIS_LEFT_TRIGGER: number;
  AXIS_RIGHT_TRIGGER: number;
  
  KEYCODE_BUTTON_A: number;
  KEYCODE_BUTTON_B: number;
  KEYCODE_BUTTON_X: number;
  KEYCODE_BUTTON_Y: number;
}

/**
 * 原生库模块接口
 */
interface NativeLibModule {
  GameController?: NativeGameController;
}

// 获取原生模块
const native = (nativeLib as NativeLibModule).GameController;

/**
 * 轴类型常量
 */
export class AxisType {
  static readonly LEFT_THUMBSTICK = 0;
  static readonly RIGHT_THUMBSTICK = 1;
  static readonly DPAD = 2;
  static readonly LEFT_TRIGGER = 3;
  static readonly RIGHT_TRIGGER = 4;
}

/**
 * 按键码常量 (与 Game Controller Kit 一致)
 */
export class ButtonCode {
  static readonly BUTTON_A = 2301;
  static readonly BUTTON_B = 2302;
  static readonly BUTTON_C = 2303;
  static readonly BUTTON_X = 2304;
  static readonly BUTTON_Y = 2305;
  static readonly LEFT_SHOULDER = 2307;
  static readonly RIGHT_SHOULDER = 2308;
  static readonly LEFT_TRIGGER = 2309;
  static readonly RIGHT_TRIGGER = 2310;
  static readonly BUTTON_HOME = 2311;
  static readonly BUTTON_MENU = 2312;
  static readonly LEFT_THUMBSTICK = 2314;
  static readonly RIGHT_THUMBSTICK = 2315;
  static readonly DPAD_UP = 2012;
  static readonly DPAD_DOWN = 2013;
  static readonly DPAD_LEFT = 2014;
  static readonly DPAD_RIGHT = 2015;
}

/**
 * 按键码到 Moonlight 按钮标志的映射
 * ArkTS 不支持计算属性名，改用 Map
 */
const buttonCodeToFlagMap = new Map<number, number>();
buttonCodeToFlagMap.set(ButtonCode.BUTTON_A, 0x1000);
buttonCodeToFlagMap.set(ButtonCode.BUTTON_B, 0x2000);
buttonCodeToFlagMap.set(ButtonCode.BUTTON_X, 0x4000);
buttonCodeToFlagMap.set(ButtonCode.BUTTON_Y, 0x8000);
buttonCodeToFlagMap.set(ButtonCode.LEFT_SHOULDER, 0x0100);
buttonCodeToFlagMap.set(ButtonCode.RIGHT_SHOULDER, 0x0200);
buttonCodeToFlagMap.set(ButtonCode.LEFT_THUMBSTICK, 0x0040);
buttonCodeToFlagMap.set(ButtonCode.RIGHT_THUMBSTICK, 0x0080);
buttonCodeToFlagMap.set(ButtonCode.BUTTON_HOME, 0x0400);
buttonCodeToFlagMap.set(ButtonCode.BUTTON_MENU, 0x0010);  // START
buttonCodeToFlagMap.set(ButtonCode.DPAD_UP, 0x0001);
buttonCodeToFlagMap.set(ButtonCode.DPAD_DOWN, 0x0002);
buttonCodeToFlagMap.set(ButtonCode.DPAD_LEFT, 0x0004);
buttonCodeToFlagMap.set(ButtonCode.DPAD_RIGHT, 0x0008);

export function getButtonFlag(buttonCode: number): number {
  return buttonCodeToFlagMap.get(buttonCode) ?? 0;
}

/**
 * Game Controller Kit 服务类
 * 
 * 提供统一的 USB 和蓝牙手柄输入
 */
export class GameControllerService {
  private static instance: GameControllerService;
  private initialized: boolean = false;
  private monitoring: boolean = false;
  
  private deviceCallback: DeviceCallback | null = null;
  private buttonCallback: ButtonCallback | null = null;
  private axisCallback: AxisCallback | null = null;
  
  private constructor() {}
  
  static getInstance(): GameControllerService {
    if (!GameControllerService.instance) {
      GameControllerService.instance = new GameControllerService();
    }
    return GameControllerService.instance;
  }
  
  /**
   * 检查 Game Controller Kit 是否可用
   */
  isAvailable(): boolean {
    if (!native) {
      console.warn('[GameController] Native 模块不可用');
      return false;
    }
    return native.isAvailable();
  }
  
  /**
   * 初始化服务
   */
  init(): boolean {
    if (!native) {
      console.error('[GameController] Native 模块不可用');
      return false;
    }
    
    if (this.initialized) {
      console.warn('[GameController] 已初始化');
      return true;
    }
    
    const result = native.init();
    if (result === 0) {
      this.initialized = true;
      console.info('[GameController] 初始化成功');
      return true;
    } else {
      console.error(`[GameController] 初始化失败: ${result}`);
      return false;
    }
  }
  
  /**
   * 反初始化
   */
  uninit(): void {
    if (!native || !this.initialized) return;
    
    this.stopMonitor();
    native.uninit();
    this.initialized = false;
    console.info('[GameController] 已反初始化');
  }
  
  /**
   * 设置设备状态变化回调
   */
  setDeviceCallback(callback: DeviceCallback | null): void {
    this.deviceCallback = callback;
    if (native) {
      native.setDeviceCallback(callback);
    }
  }
  
  /**
   * 设置按键事件回调
   */
  setButtonCallback(callback: ButtonCallback | null): void {
    this.buttonCallback = callback;
    if (native) {
      native.setButtonCallback(callback);
    }
  }
  
  /**
   * 设置轴事件回调
   */
  setAxisCallback(callback: AxisCallback | null): void {
    this.axisCallback = callback;
    if (native) {
      native.setAxisCallback(callback);
    }
  }
  
  /**
   * 开始监听
   */
  startMonitor(): boolean {
    if (!native || !this.initialized) {
      console.error('[GameController] 未初始化');
      return false;
    }
    
    if (this.monitoring) {
      console.warn('[GameController] 已在监听中');
      return true;
    }
    
    const result = native.startMonitor();
    if (result === 0) {
      this.monitoring = true;
      console.info('[GameController] 开始监听');
      return true;
    } else {
      console.error(`[GameController] 开始监听失败: ${result}`);
      return false;
    }
  }
  
  /**
   * 停止监听
   */
  stopMonitor(): void {
    if (!native || !this.monitoring) return;
    
    native.stopMonitor();
    this.monitoring = false;
    console.info('[GameController] 停止监听');
  }
  
  /**
   * 获取已连接设备数量
   */
  getDeviceCount(): number {
    if (!native) return 0;
    return native.getDeviceCount();
  }
  
  /**
   * 获取设备信息
   */
  getDeviceInfo(index: number): GameControllerDeviceInfo | null {
    if (!native) return null;
    return native.getDeviceInfo(index);
  }
  
  /**
   * 获取所有已连接设备
   */
  getAllDevices(): GameControllerDeviceInfo[] {
    const devices: GameControllerDeviceInfo[] = [];
    const count = this.getDeviceCount();
    for (let i = 0; i < count; i++) {
      const info = this.getDeviceInfo(i);
      if (info) {
        devices.push(info);
      }
    }
    return devices;
  }

  /**
   * 心跳检测 - 检查设备是否仍然连接
   * 
   * 对于某些设备（如雷蛇手柄），电源管理不透明，
   * 系统可能不会及时发送断开事件。
   * 此函数通过重新查询设备列表来检测设备断开。
   * 
   * @returns 断开的设备数量
   */
  heartbeatCheck(): number {
    if (!native || !this.initialized || !this.monitoring) {
      return 0;
    }
    return native.heartbeatCheck();
  }
}

// 导出单例
export const gameControllerService = GameControllerService.getInstance();
