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
 * 输入拦截器服务
 *
 * 封装 Native 层按键事件拦截器，串流时启用以拦截被系统劫持的手柄按键
 * （如蓝牙手柄 Home/Mode 键 keyCode 2313）
 *
 * 使用方法:
 *   InputInterceptorService.getInstance().start(callback)  // 串流开始时
 *   InputInterceptorService.getInstance().stop()           // 串流结束时
 */

import nativeLib from 'libmoonlight_nativelib.so';

/**
 * 拦截到的按键事件
 */
export interface InterceptedKeyEvent {
  keyCode: number;
  action: number;      // 1 = KEY_DOWN, 2 = KEY_UP
  actionTime: number;
}

/**
 * 按键拦截回调
 */
export type KeyInterceptCallback = (event: InterceptedKeyEvent) => void;

// Native 模块接口声明
interface InputInterceptorNative {
  addKeyInterceptor(callback: (event: InterceptedKeyEvent) => void): number;
  removeKeyInterceptor(): number;
  isKeyInterceptorActive(): boolean;
  isInjectApiAvailable(): boolean;
}

interface MouseInterceptorNative {
  addMouseInterceptor(): number;
  removeMouseInterceptor(): number;
  configureMouseInterceptor(windowX: number, windowY: number,
                            windowWidth: number, windowHeight: number,
                            screenWidth: number, screenHeight: number,
                            relativeMode: boolean): void;
  isMouseInterceptorActive(): boolean;
}

/**
 * 输入拦截器服务（单例）
 */
export class InputInterceptorService {
  private static instance: InputInterceptorService;
  private native: InputInterceptorNative;
  private active: boolean = false;

  private constructor() {
    this.native = (nativeLib as Record<string, Object>)['InputInterceptor'] as InputInterceptorNative;
  }

  static getInstance(): InputInterceptorService {
    if (!InputInterceptorService.instance) {
      InputInterceptorService.instance = new InputInterceptorService();
    }
    return InputInterceptorService.instance;
  }

  /**
   * 启动按键拦截器
   * @param callback 接收拦截到的按键事件
   * @returns 0 成功，其他为错误码
   */
  start(callback: KeyInterceptCallback): number {
    if (this.active) {
      this.stop();
    }

    if (!this.native) {
      console.warn('InputInterceptor: Native 模块不可用');
      return -1;
    }

    const result = this.native.addKeyInterceptor(callback);
    if (result === 0) {
      this.active = true;
      console.info('InputInterceptor: 按键拦截器已启动');
    } else {
      console.warn(`InputInterceptor: 启动失败，错误码=${result}`);
    }
    return result;
  }

  /**
   * 停止按键拦截器
   */
  stop(): void {
    if (!this.active || !this.native) {
      return;
    }

    this.native.removeKeyInterceptor();
    this.active = false;
    console.info('InputInterceptor: 按键拦截器已停止');
  }

  /**
   * 查询是否处于活跃状态
   */
  isActive(): boolean {
    if (this.native) {
      return this.native.isKeyInterceptorActive();
    }
    return false;
  }

  /**
   * 查询按键注入 API 是否可用（API 13+ 设备）
   * 返回 false 时不应启用反劫持功能（音量键会被吃掉且无法回注）
   */
  isInjectApiAvailable(): boolean {
    if (this.native) {
      return this.native.isInjectApiAvailable();
    }
    return false;
  }
}

/**
 * 鼠标事件拦截器服务（单例）
 *
 * 使用 OH_Input_AddMouseEventMonitor 在系统输入管线层级监听鼠标事件（不消费），
 * 绕过 ArkUI 渲染帧率限制（不触摸时 .onMouse 降至 ~30Hz），
 * 以硬件原始轮询率直接调用 moonlight-common-c 输入 API。
 *
 * 使用方法:
 *   MouseInterceptorService.getInstance().configure(...)  // 配置参数
 *   MouseInterceptorService.getInstance().start()         // 串流开始时
 *   MouseInterceptorService.getInstance().stop()          // 串流结束/菜单弹出时
 */
export class MouseInterceptorService {
  private static instance: MouseInterceptorService;
  private native: MouseInterceptorNative | null;
  private active: boolean = false;

  private constructor() {
    this.native = (nativeLib as Record<string, Object>)['MouseInterceptor'] as MouseInterceptorNative;
  }

  static getInstance(): MouseInterceptorService {
    if (!MouseInterceptorService.instance) {
      MouseInterceptorService.instance = new MouseInterceptorService();
    }
    return MouseInterceptorService.instance;
  }

  /**
   * 配置拦截器参数（可在运行中调用以更新）
   * @param windowX 窗口 X 坐标 (px)
   * @param windowY 窗口 Y 坐标 (px)
   * @param windowWidth 窗口宽度 (px)
   * @param windowHeight 窗口高度 (px)
   * @param screenWidth 屏幕宽度 (px)
   * @param screenHeight 屏幕高度 (px)
   * @param relativeMode 相对模式（游戏用）
   */
  configure(windowX: number, windowY: number,
            windowWidth: number, windowHeight: number,
            screenWidth: number, screenHeight: number,
            relativeMode: boolean): void {
    if (!this.native) return;
    this.native.configureMouseInterceptor(windowX, windowY, windowWidth, windowHeight,
                                          screenWidth, screenHeight, relativeMode);
  }

  /**
   * 启动鼠标拦截器
   * @returns 0 成功，其他为错误码
   */
  start(): number {
    if (this.active) {
      this.stop();
    }
    if (!this.native) {
      console.warn('MouseInterceptor: Native 模块不可用');
      return -1;
    }

    const result = this.native.addMouseInterceptor();
    if (result === 0) {
      this.active = true;
      console.info('MouseInterceptor: 鼠标拦截器已启动（全速轮询）');
    } else {
      console.warn(`MouseInterceptor: 启动失败，错误码=${result}`);
    }
    return result;
  }

  /**
   * 停止鼠标拦截器
   */
  stop(): void {
    if (!this.active || !this.native) return;
    this.native.removeMouseInterceptor();
    this.active = false;
    console.info('MouseInterceptor: 鼠标拦截器已停止');
  }

  isActive(): boolean {
    if (this.native) {
      return this.native.isMouseInterceptorActive();
    }
    return false;
  }
}
