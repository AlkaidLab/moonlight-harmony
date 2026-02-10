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
