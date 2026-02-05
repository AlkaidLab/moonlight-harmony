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
 * 应用状态服务
 * 
 * 用于监听和通知应用的前后台状态变化
 */
import { emitter } from '@kit.BasicServicesKit';

// 应用状态变化事件 ID
export const APP_STATE_EVENT_ID = 10001;

export enum AppState {
  FOREGROUND = 'foreground',
  BACKGROUND = 'background'
}

export interface AppStateEvent {
  state: AppState;
  timestamp: number;
}

/**
 * 应用状态服务单例
 */
export class AppStateService {
  private static instance: AppStateService;
  private currentState: AppState = AppState.FOREGROUND;
  private listeners: Set<(state: AppState) => void> = new Set();
  
  private constructor() {}
  
  static getInstance(): AppStateService {
    if (!AppStateService.instance) {
      AppStateService.instance = new AppStateService();
    }
    return AppStateService.instance;
  }
  
  /**
   * 获取当前应用状态
   */
  getCurrentState(): AppState {
    return this.currentState;
  }
  
  /**
   * 应用进入前台
   */
  onForeground(): void {
    if (this.currentState !== AppState.FOREGROUND) {
      this.currentState = AppState.FOREGROUND;
      console.info('[AppStateService] 应用进入前台');
      this.notifyListeners();
      this.emitEvent();
    }
  }
  
  /**
   * 应用进入后台
   */
  onBackground(): void {
    if (this.currentState !== AppState.BACKGROUND) {
      this.currentState = AppState.BACKGROUND;
      console.info('[AppStateService] 应用进入后台');
      this.notifyListeners();
      this.emitEvent();
    }
  }
  
  /**
   * 添加状态变化监听器
   */
  addListener(callback: (state: AppState) => void): void {
    this.listeners.add(callback);
  }
  
  /**
   * 移除状态变化监听器
   */
  removeListener(callback: (state: AppState) => void): void {
    this.listeners.delete(callback);
  }
  
  /**
   * 订阅状态变化事件（使用 emitter）
   */
  subscribe(callback: (event: emitter.EventData) => void): void {
    const innerEvent: emitter.InnerEvent = {
      eventId: APP_STATE_EVENT_ID
    };
    emitter.on(innerEvent, callback);
  }
  
  /**
   * 取消订阅状态变化事件
   */
  unsubscribe(): void {
    emitter.off(APP_STATE_EVENT_ID);
  }
  
  private notifyListeners(): void {
    this.listeners.forEach(callback => {
      try {
        callback(this.currentState);
      } catch (err) {
        console.error('[AppStateService] 监听器回调错误:', err);
      }
    });
  }
  
  private emitEvent(): void {
    const eventData: emitter.EventData = {
      data: {
        state: this.currentState,
        timestamp: Date.now()
      }
    };
    const innerEvent: emitter.InnerEvent = {
      eventId: APP_STATE_EVENT_ID,
      priority: emitter.EventPriority.HIGH
    };
    emitter.emit(innerEvent, eventData);
  }
}
