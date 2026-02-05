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
 * 触摸输入处理器
 * 
 * 处理触摸事件并转换为相应的输入指令
 */
import nativeLib from 'libmoonlight_nativelib.so';

/**
 * 触摸输入模式
 */
export enum TouchInputMode {
  TRACKPAD = 'trackpad',  // 触摸板模式：相对移动
  DIRECT = 'direct',      // 直接触摸模式：绝对坐标
  MOUSE = 'mouse'         // 鼠标模式：相对移动 + 按键
}

// 鼠标按钮常量
const BUTTON_ACTION_PRESS = 0x07;
const BUTTON_ACTION_RELEASE = 0x08;
const BUTTON_LEFT = 0x01;
const BUTTON_RIGHT = 0x03;

// 触摸事件常量
const TOUCH_EVENT_DOWN = 0x01;
const TOUCH_EVENT_UP = 0x02;
const TOUCH_EVENT_MOVE = 0x03;

/**
 * Native 输入模块接口
 */
interface NativeInputModule {
  sendMouseMove(deltaX: number, deltaY: number): void;
  sendMousePosition(x: number, y: number, refWidth: number, refHeight: number): void;
  sendMouseButton(buttonEvent: number, mouseButton: number): void;
  sendTouchEvent(eventType: number, pointerId: number, x: number, y: number,
    pressureOrDistance: number, contactAreaMajor: number, contactAreaMinor: number,
    rotation: number): void;
}

/**
 * 触摸状态
 */
interface TouchState {
  startX: number;     // 起始位置
  startY: number;
  lastX: number;      // 最后位置（用于计算相对移动）
  lastY: number;
  startTime: number;
}

/**
 * 触摸输入处理器配置
 */
export interface TouchInputConfig {
  /** 触摸灵敏度 */
  sensitivity?: number;
  /** 点击移动阈值（低于此值视为点击） */
  clickThreshold?: number;
  /** 长按时间阈值（毫秒） */
  longPressThreshold?: number;
}

/**
 * TouchInputHandler - 触摸输入处理器
 */
export class TouchInputHandler {
  private nativeInput: NativeInputModule;
  private mode: TouchInputMode = TouchInputMode.TRACKPAD;
  private touchStates: Map<number, TouchState> = new Map();
  private config: TouchInputConfig;
  
  // 默认配置
  private static readonly DEFAULT_SENSITIVITY = 1.5;
  private static readonly DEFAULT_CLICK_THRESHOLD = 20;  // 提高阈值，减少误触发
  private static readonly DEFAULT_LONG_PRESS_THRESHOLD = 500;
  
  constructor(config?: TouchInputConfig) {
    this.nativeInput = nativeLib as NativeInputModule;
    this.config = {
      sensitivity: config?.sensitivity ?? TouchInputHandler.DEFAULT_SENSITIVITY,
      clickThreshold: config?.clickThreshold ?? TouchInputHandler.DEFAULT_CLICK_THRESHOLD,
      longPressThreshold: config?.longPressThreshold ?? TouchInputHandler.DEFAULT_LONG_PRESS_THRESHOLD
    };
  }
  
  /**
   * 设置触摸模式
   */
  setMode(mode: TouchInputMode): void {
    this.mode = mode;
    console.info(`TouchInputHandler: 模式切换为 ${mode}`);
  }
  
  /**
   * 获取当前模式
   */
  getMode(): TouchInputMode {
    return this.mode;
  }
  
  /**
   * 设置灵敏度
   */
  setSensitivity(sensitivity: number): void {
    this.config.sensitivity = sensitivity;
  }
  
  /**
   * 处理触摸事件
   */
  handleTouchEvent(event: TouchEvent): void {
    const touches = event.touches;
    if (touches.length === 0) {
      return;
    }
    
    // DIRECT 模式支持多点触控，需要处理所有触摸点
    if (this.mode === TouchInputMode.DIRECT) {
      this.handleMultiTouchEvent(event);
      return;
    }
    
    // 其他模式只处理第一个触摸点
    const touch = touches[0];
    
    switch (event.type) {
      case TouchType.Down:
        this.handleTouchDown(touch, event);
        break;
      case TouchType.Move:
        this.handleTouchMove(touch, event);
        break;
      case TouchType.Up:
      case TouchType.Cancel:
        this.handleTouchUp(touch, event);
        break;
    }
  }
  
  /**
   * 处理多点触控事件（DIRECT 模式）
   * 支持高采样率：处理历史触摸点 + 当前触摸点
   */
  private handleMultiTouchEvent(event: TouchEvent): void {
    const touches = event.touches;
    const changedTouches = event.changedTouches;
    const areaWidth = event.target.area.width as number;
    const areaHeight = event.target.area.height as number;
    
    switch (event.type) {
      case TouchType.Down:
        // 处理新按下的触摸点
        for (let i = 0; i < changedTouches.length; i++) {
          const touch = changedTouches[i];
          this.touchStates.set(touch.id, {
            startX: touch.x,
            startY: touch.y,
            lastX: touch.x,
            lastY: touch.y,
            startTime: Date.now()
          });
          this.sendNormalizedTouch(TOUCH_EVENT_DOWN, touch, event);
        }
        break;
        
      case TouchType.Move:
        // 首先处理历史触摸点（更高的采样率）
        try {
          const historicalPoints = event.getHistoricalPoints();
          if (historicalPoints && historicalPoints.length > 0) {
            const now = Date.now();
            // 最多处理最近 100ms 内的历史点，避免处理过旧的数据
            const maxAge = 100;
            
            for (let i = 0; i < historicalPoints.length; i++) {
              const histPoint = historicalPoints[i];
              
              // 跳过太旧的历史点
              if (histPoint.timestamp && (now - histPoint.timestamp) > maxAge) {
                continue;
              }
              
              const histTouch = histPoint.touchObject;
              const state = this.touchStates.get(histTouch.id);
              if (state) {
                this.sendNormalizedTouchDirect(
                  TOUCH_EVENT_MOVE,
                  histTouch.id,
                  histTouch.x,
                  histTouch.y,
                  areaWidth,
                  areaHeight,
                  histPoint.force || 1.0,
                  histPoint.size || 0.05
                );
              }
            }
          }
        } catch (e) {
          // 某些设备可能不支持 getHistoricalPoints，忽略错误
        }
        
        // 然后处理当前触摸点
        for (let i = 0; i < touches.length; i++) {
          const touch = touches[i];
          const state = this.touchStates.get(touch.id);
          if (state) {
            state.lastX = touch.x;
            state.lastY = touch.y;
            this.sendNormalizedTouch(TOUCH_EVENT_MOVE, touch, event);
          }
        }
        break;
        
      case TouchType.Up:
      case TouchType.Cancel:
        // 处理抬起的触摸点
        for (let i = 0; i < changedTouches.length; i++) {
          const touch = changedTouches[i];
          this.sendNormalizedTouch(TOUCH_EVENT_UP, touch, event);
          this.touchStates.delete(touch.id);
        }
        break;
    }
  }
  
  /**
   * 处理触摸按下 (TRACKPAD 和 MOUSE 模式)
   */
  private handleTouchDown(touch: TouchObject, event: TouchEvent): void {
    // 记录触摸状态
    this.touchStates.set(touch.id, {
      startX: touch.x,   // 记录起始位置（用于判断是否为点击）
      startY: touch.y,
      lastX: touch.x,    // 最后位置（用于计算相对移动）
      lastY: touch.y,
      startTime: Date.now()
    });
    
    if (this.mode === TouchInputMode.MOUSE) {
      // 鼠标模式：触摸作为左键点击
      this.nativeInput.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    }
    // trackpad 模式：按下不做动作，等待移动
  }
  
  /**
   * 处理触摸移动 (TRACKPAD 和 MOUSE 模式)
   */
  private handleTouchMove(touch: TouchObject, event: TouchEvent): void {
    const state = this.touchStates.get(touch.id);
    if (!state) {
      return;
    }
    
    const deltaX = touch.x - state.lastX;
    const deltaY = touch.y - state.lastY;
    
    // 更新状态
    state.lastX = touch.x;
    state.lastY = touch.y;
    
    if (this.mode === TouchInputMode.TRACKPAD) {
      // 触摸板模式：发送相对移动
      const sensitivity = this.config.sensitivity!;
      this.nativeInput.sendMouseMove(
        Math.floor(deltaX * sensitivity),
        Math.floor(deltaY * sensitivity)
      );
    } else if (this.mode === TouchInputMode.MOUSE) {
      // 鼠标模式：移动光标
      this.nativeInput.sendMouseMove(
        Math.floor(deltaX),
        Math.floor(deltaY)
      );
    }
  }
  
  /**
   * 处理触摸抬起 (TRACKPAD 和 MOUSE 模式)
   */
  private handleTouchUp(touch: TouchObject, event: TouchEvent): void {
    const state = this.touchStates.get(touch.id);
    
    if (this.mode === TouchInputMode.MOUSE) {
      // 鼠标模式：释放左键
      this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    } else if (this.mode === TouchInputMode.TRACKPAD && state) {
      // 触摸板模式：检测点击
      this.checkForClick(touch, state);
    }
    
    // 清理触摸状态
    this.touchStates.delete(touch.id);
  }
  
  /**
   * 发送归一化的触摸事件
   */
  private sendNormalizedTouch(eventType: number, touch: TouchObject, event: TouchEvent): void {
    const areaWidth = event.target.area.width as number;
    const areaHeight = event.target.area.height as number;
    
    // 归一化到 0.0-1.0 范围
    const normalizedX = Math.max(0, Math.min(1, touch.x / areaWidth));
    const normalizedY = Math.max(0, Math.min(1, touch.y / areaHeight));
    
    const pressure = eventType === TOUCH_EVENT_UP ? 0 : 1.0;
    const contactArea = eventType === TOUCH_EVENT_UP ? 0 : 0.05;
    
    this.nativeInput.sendTouchEvent(
      eventType,
      touch.id,
      normalizedX,
      normalizedY,
      pressure,
      contactArea,
      contactArea,
      0  // rotation
    );
  }
  
  /**
   * 直接发送归一化的触摸事件（用于历史触摸点）
   */
  private sendNormalizedTouchDirect(
    eventType: number,
    pointerId: number,
    x: number,
    y: number,
    areaWidth: number,
    areaHeight: number,
    pressure: number,
    size: number
  ): void {
    const normalizedX = Math.max(0, Math.min(1, x / areaWidth));
    const normalizedY = Math.max(0, Math.min(1, y / areaHeight));
    
    this.nativeInput.sendTouchEvent(
      eventType,
      pointerId,
      normalizedX,
      normalizedY,
      pressure,
      size,
      size,
      0
    );
  }
  
  /**
   * 检测并处理点击（仅在移动距离很小时触发）
   * 注意：只有当触摸几乎没有移动时才视为点击，避免移动操作被误判
   */
  private checkForClick(touch: TouchObject, state: TouchState): void {
    // 使用起始位置和结束位置计算总移动距离
    const moveDistance = Math.abs(touch.x - state.startX) + Math.abs(touch.y - state.startY);
    
    // 检查触摸持续时间
    const touchDuration = Date.now() - state.startTime;
    
    // 只有当移动距离很小且触摸时间较短时才视为点击
    // 长时间触摸+小移动可能是用户在等待/思考，不应视为点击
    if (moveDistance < this.config.clickThreshold! && touchDuration < 300) {
      this.nativeInput.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_LEFT);
      setTimeout(() => {
        this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
      }, 50);
    }
  }
  
  /**
   * 发送右键点击
   */
  sendRightClick(): void {
    this.nativeInput.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
    setTimeout(() => {
      this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
    }, 50);
  }
  
  /**
   * 发送左键点击
   */
  sendLeftClick(): void {
    this.nativeInput.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    setTimeout(() => {
      this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }, 50);
  }
  
  /**
   * 清理资源
   */
  dispose(): void {
    this.touchStates.clear();
  }
}
