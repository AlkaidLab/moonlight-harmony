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
import { PointXY } from './PanZoomHandler';
import { TrackpadGestureHandler, TrackpadInputSink, TrackpadConfig } from './TrackpadGestureHandler';
import { Ds5TouchpadGestureHandler, Ds5TouchpadInputSink } from './Ds5TouchpadGestureHandler';
import {
  BUTTON_ACTION_PRESS,
  BUTTON_ACTION_RELEASE,
  BUTTON_LEFT,
  BUTTON_RIGHT,
  TOUCH_EVENT_DOWN,
  TOUCH_EVENT_UP,
  TOUCH_EVENT_MOVE,
  TOUCH_EVENT_CANCEL,
  TOUCH_EVENT_HOVER,
  TOUCH_EVENT_CANCEL_ALL,
  LI_TOOL_TYPE_UNKNOWN,
  LI_TOOL_TYPE_PEN,
  LI_TOOL_TYPE_ERASER,
  LI_PEN_BUTTON_PRIMARY,
  LI_PEN_BUTTON_SECONDARY,
  LI_TILT_UNKNOWN,
  LI_ROT_UNKNOWN
} from '../streaming/MoonBridge';

/**
 * 触摸输入模式
 */
export enum TouchInputMode {
  TRACKPAD = 'trackpad',  // 触摸板模式：相对移动
  DIRECT = 'direct',      // 直接触摸模式：绝对坐标（多点触控协议）
  MOUSE = 'mouse',        // 鼠标模式：绝对定位 + 死区 + 长按右键 + 双指滚轮
  DS5_TOUCHPAD = 'ds5_touchpad' // 屏幕映射 DualSense 触控板
}

/**
 * Native 输入模块接口
 */
interface NativeInputModule {
  sendMouseMove(deltaX: number, deltaY: number): void;
  sendMousePosition(x: number, y: number, refWidth: number, refHeight: number): void;
  sendMouseButton(buttonEvent: number, mouseButton: number): void;
  sendMouseHighResScroll(scrollAmount: number): void;
  sendTouchEvent(eventType: number, pointerId: number, x: number, y: number,
    pressureOrDistance: number, contactAreaMajor: number, contactAreaMinor: number,
    rotation: number): void;
  sendPenEvent(eventType: number, toolType: number, penButtons: number,
    x: number, y: number, pressureOrDistance: number,
    contactAreaMajor: number, contactAreaMinor: number,
    rotation: number, tilt: number): number;
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
  /** 点击最大时长阈值（毫秒，超过此值不视为点击） */
  clickTimeThreshold?: number;
}

/**
 * NativeInputModule → TrackpadInputSink 适配器
 */
class NativeTrackpadSink implements TrackpadInputSink {
  private native: NativeInputModule;

  constructor(native: NativeInputModule) {
    this.native = native;
  }

  sendMouseMove(deltaX: number, deltaY: number): void {
    this.native.sendMouseMove(deltaX, deltaY);
  }

  sendMouseButton(buttonEvent: number, mouseButton: number): void {
    this.native.sendMouseButton(buttonEvent, mouseButton);
  }

  sendMouseHighResScroll(scrollAmount: number): void {
    this.native.sendMouseHighResScroll(scrollAmount);
  }
}

/**
 * NativeTrackpadConfig - TrackpadConfig 的具名实现
 */
class NativeTrackpadConfig implements TrackpadConfig {
  sensitivity: number;
  tapTimeThreshold: number;
  enableDoubleClickDrag: boolean;

  constructor(sensitivity: number, tapTimeThreshold: number, enableDoubleClickDrag: boolean) {
    this.sensitivity = sensitivity;
    this.tapTimeThreshold = tapTimeThreshold;
    this.enableDoubleClickDrag = enableDoubleClickDrag;
  }
}

/**
 * TouchInputHandler - 触摸输入处理器
 */
export class TouchInputHandler {
  private nativeInput: NativeInputModule;
  private mode: TouchInputMode = TouchInputMode.TRACKPAD;
  private touchStates: Map<number, TouchState> = new Map();
  private config: TouchInputConfig;
  /** 每个触摸点的最后已知压力值（从历史点追踪） */
  private lastForce: Map<number, number> = new Map();
  /** 每个触摸点的最后已知接触面积（从历史点追踪） */
  private lastSize: Map<number, number> = new Map();
  /** 是否已检测到手写笔不被主机支持（sendPenEvent 返回 LI_ERR_UNSUPPORTED） */
  private penUnsupported: boolean = false;
  /** 手写笔首次事件日志标记 */
  private penFirstEventLogged: boolean = false;
  
  /** HarmonyOS HistoricalPoint.force 最大值，用于归一化 */
  private static readonly FORCE_MAX = 65535.0;

  /** 触控板手势处理器（对齐 Android RelativeTouchContext） */
  private trackpad: TrackpadGestureHandler;
  /** 屏幕映射 DualSense 触控板（与普通鼠标触控板完全独立） */
  private ds5Touchpad: Ds5TouchpadGestureHandler = new Ds5TouchpadGestureHandler();

  // ====== 鼠标模式状态（绝对定位 + 死区 + 长按右键，对齐 Android AbsoluteTouchContext） ======
  /** 主手指按下位置 */
  private mouseDownX: number = 0;
  private mouseDownY: number = 0;
  private mouseDownTime: number = 0;
  /** 上次抬起位置（用于双击判定） */
  private mouseLastUpX: number = 0;
  private mouseLastUpY: number = 0;
  private mouseLastUpTime: number = 0;
  /** 当前主手指位置 */
  private mouseLastX: number = 0;
  private mouseLastY: number = 0;
  /** 手势是否已取消（第二根手指出现时取消主手指） */
  private mouseCancelled: boolean = false;
  /** 是否已确认为点击（死区时间/距离超过后） */
  private mouseConfirmedTap: boolean = false;
  /** 是否已确认为长按（默认 650ms 后切换为右键） */
  private mouseConfirmedLongPress: boolean = false;
  /** 长按定时器 */
  private mouseLongPressTimer: number = -1;
  /** 死区定时器（默认 100ms 后确认点击） */
  private mouseTapDownTimer: number = -1;
  /** 左键释放延迟定时器（快速点击时默认延迟 100ms 释放） */
  private mouseLeftButtonUpTimer: number = -1;
  /** 主手指 ID */
  private mousePrimaryFingerId: number = -1;
  /** 第二根手指 ID（用于滚轮） */
  private mouseSecondFingerId: number = -1;
  /** 第二根手指的最后 Y 位置 */
  private mouseSecondFingerLastY: number = 0;
  /** 组件区域尺寸（缓存，用于 sendMousePosition） */
  private mouseAreaWidth: number = 0;
  private mouseAreaHeight: number = 0;

  /** 坐标变换函数：将 ArkUI 触摸坐标转换为视频画面内的实际坐标（用于缩放/平移状态） */
  private coordinateTransform: ((x: number, y: number) => PointXY) | null = null;

  // 鼠标模式常量（与 Android AbsoluteTouchContext 一致）
  /** 标准长按时间阈值（ms） */
  private static readonly MOUSE_LONG_PRESS_TIME_NORMAL = 650;
  /** 低延迟长按时间阈值（ms） */
  private static readonly MOUSE_LONG_PRESS_TIME_LOW_LATENCY = 500;
  /** 长按移动距离阈值（px）—— 超过后取消长按 */
  private static readonly MOUSE_LONG_PRESS_DISTANCE = 30;
  /** 标准死区时间阈值（ms）—— 按下后此时间内不响应移动 */
  private static readonly MOUSE_DEADZONE_TIME_NORMAL = 100;
  /** 低延迟死区时间阈值（ms） */
  private static readonly MOUSE_DEADZONE_TIME_LOW_LATENCY = 50;
  /** 死区距离阈值（px）—— 移动超过此距离立即确认点击 */
  private static readonly MOUSE_DEADZONE_DISTANCE = 20;
  /** 标准点击释放延迟（ms） */
  private static readonly MOUSE_CLICK_RELEASE_DELAY_NORMAL = 100;
  /** 低延迟点击释放延迟（ms） */
  private static readonly MOUSE_CLICK_RELEASE_DELAY_LOW_LATENCY = 40;
  /** 双击时间阈值（ms）—— 两次点击间隔小于此值视为双击 */
  private mouseDoubleTapTime: number = 250;
  /** 双击距离阈值（px）—— 两次点击位置距离小于此值视为双击 */
  private static readonly MOUSE_DOUBLE_TAP_DISTANCE = 60;
  /** 鼠标模式滚轮速度因子 */
  private static readonly MOUSE_SCROLL_SPEED_FACTOR = 3;
  /** 是否启用双击拖动 */
  private enableDoubleClickDrag: boolean = false;
  /** 当前长按时间阈值（ms） */
  private mouseLongPressTime: number = TouchInputHandler.MOUSE_LONG_PRESS_TIME_NORMAL;
  /** 当前死区时间阈值（ms） */
  private mouseDeadzoneTime: number = TouchInputHandler.MOUSE_DEADZONE_TIME_NORMAL;
  /** 当前点击释放延迟（ms） */
  private mouseClickReleaseDelay: number = TouchInputHandler.MOUSE_CLICK_RELEASE_DELAY_NORMAL;

  // 默认配置
  private static readonly DEFAULT_SENSITIVITY = 1.5;
  private static readonly DEFAULT_CLICK_THRESHOLD = 20;  // 提高阈值，减少误触发
  private static readonly DEFAULT_CLICK_TIME_THRESHOLD = 300;  // 点击最大时长
  
  constructor(config?: TouchInputConfig) {
    this.nativeInput = nativeLib as NativeInputModule;
    this.config = {
      sensitivity: config?.sensitivity ?? TouchInputHandler.DEFAULT_SENSITIVITY,
      clickThreshold: config?.clickThreshold ?? TouchInputHandler.DEFAULT_CLICK_THRESHOLD,
      clickTimeThreshold: config?.clickTimeThreshold ?? TouchInputHandler.DEFAULT_CLICK_TIME_THRESHOLD,
    };
    this.trackpad = new TrackpadGestureHandler(
      new NativeTrackpadSink(this.nativeInput),
      new NativeTrackpadConfig(this.config.sensitivity!, 250, false),
    );
  }

  /**
   * 配置双击时间阈值（从设置读取后调用）
   */
  setDoubleTapTimeThreshold(threshold: number): void {
    this.trackpad.updateConfig(undefined, threshold, undefined);
    this.mouseDoubleTapTime = threshold;
  }

  /**
   * 配置是否启用双击拖动（从设置读取后调用）
   */
  setEnableDoubleClickDrag(enable: boolean): void {
    this.trackpad.updateConfig(undefined, undefined, enable);
    this.enableDoubleClickDrag = enable;
  }

  /**
   * 配置低延迟触摸参数（从设置读取后调用）
   */
  setLowLatencyTouch(enable: boolean): void {
    this.mouseLongPressTime = enable
      ? TouchInputHandler.MOUSE_LONG_PRESS_TIME_LOW_LATENCY
      : TouchInputHandler.MOUSE_LONG_PRESS_TIME_NORMAL;
    this.mouseDeadzoneTime = enable
      ? TouchInputHandler.MOUSE_DEADZONE_TIME_LOW_LATENCY
      : TouchInputHandler.MOUSE_DEADZONE_TIME_NORMAL;
    this.mouseClickReleaseDelay = enable
      ? TouchInputHandler.MOUSE_CLICK_RELEASE_DELAY_LOW_LATENCY
      : TouchInputHandler.MOUSE_CLICK_RELEASE_DELAY_NORMAL;
    this.trackpad.updateLatencyMode(enable);
  }

  /**
   * 设置坐标变换函数（用于画面缩放/平移状态下的坐标修正）
   * 传入 null 清除变换
   */
  setCoordinateTransform(transform: ((x: number, y: number) => PointXY) | null): void {
    this.coordinateTransform = transform;
  }
  
  /**
   * 归一化压力值到 [0, 1.0] 范围
   * HarmonyOS HistoricalPoint.force 范围为 [0, 65535)
   * 若 force > 1.0 则视为原始传感器值，进行归一化
   * 若 force 在 [0, 1.0] 范围内则直接使用
   */
  private normalizeForce(force: number): number {
    if (force <= 0) {
      return 0;
    }
    if (force > 1.0) {
      // 原始传感器值，归一化到 [0, 1.0]
      return Math.min(1.0, force / TouchInputHandler.FORCE_MAX);
    }
    return force;
  }
  
  /**
   * 获取触摸点的当前压力值
   * 优先使用历史点追踪的 force，不可用时返回默认值
   */
  private getTrackedForce(pointerId: number, defaultForce: number = 1.0): number {
    const force = this.lastForce.get(pointerId);
    return force !== undefined ? force : defaultForce;
  }
  
  /**
   * 获取触摸点的当前接触面积
   */
  private getTrackedSize(pointerId: number, defaultSize: number = 0.05): number {
    const size = this.lastSize.get(pointerId);
    return size !== undefined ? size : defaultSize;
  }
  
  /**
   * 获取绝对鼠标管理器
   */
  /**
   * 设置触摸模式
   *
   * 切换模式时主动清理 MOUSE 模式遗留状态并释放可能卡住的左/右键，
   * 避免 Cancel 事件丢失或 ArkUI 命中测试抖动导致的"左键卡按下"
   * 进而让后续自定义右键等动作在主机端被忽略。
   * 对于目标端本就松开的按键，多发一次 RELEASE 是无副作用的 no-op。
   */
  setMode(mode: TouchInputMode): void {
    if (this.mode === TouchInputMode.MOUSE && mode !== TouchInputMode.MOUSE) {
      this.resetMouseState(true);
    }
    if (this.mode === TouchInputMode.DS5_TOUCHPAD && mode !== TouchInputMode.DS5_TOUCHPAD) {
      this.ds5Touchpad.cancelActiveInput();
    }
    this.mode = mode;
    console.info(`TouchInputHandler: 模式切换为 ${mode}`);
  }

  /** 绑定当前串流会话的 DS5 触控输出。 */
  setDs5TouchpadSink(sink: Ds5TouchpadInputSink | null): void {
    this.ds5Touchpad.setSink(sink);
  }

  /** 设置 DS5 触控板不受支持时的回退通知。 */
  setDs5TouchpadUnsupportedCallback(callback: (() => void) | null): void {
    this.ds5Touchpad.setUnsupportedCallback(callback);
  }

  /**
   * 取消当前触摸/鼠标手势。
   *
   * 用于本地系统手势（如三指唤出 IME）接管输入前，防止远端保留
   * 已按下的触摸点、鼠标左键/右键或触控板拖拽状态。
   */
  cancelActiveInput(): void {
    this.trackpad.dispose();
    this.resetMouseState(true);
    this.ds5Touchpad.cancelActiveInput();
    this.touchStates.clear();
    this.lastForce.clear();
    this.lastSize.clear();
    this.nativeInput.sendTouchEvent(
      TOUCH_EVENT_CANCEL_ALL,
      0,
      0,
      0,
      0,
      0,
      0,
      0
    );
  }

  /**
   * 重置 MOUSE 模式状态 + 释放可能卡住的鼠标键
   * @param releaseButtons 是否向主机发送 LEFT/RIGHT RELEASE（防御性释放）
   */
  private resetMouseState(releaseButtons: boolean): void {
    // 取消所有定时器
    this.cancelMouseLongPressTimer();
    this.cancelMouseTapDownTimer();
    if (this.mouseLeftButtonUpTimer !== -1) {
      clearTimeout(this.mouseLeftButtonUpTimer);
      this.mouseLeftButtonUpTimer = -1;
    }
    // 释放可能卡在主机端的鼠标键
    if (releaseButtons) {
      if (this.mouseConfirmedLongPress) {
        this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
      }
      if (this.mouseConfirmedTap) {
        this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
      }
    }
    // 清空手指 / 标志位
    this.mousePrimaryFingerId = -1;
    this.mouseSecondFingerId = -1;
    this.mouseCancelled = false;
    this.mouseConfirmedTap = false;
    this.mouseConfirmedLongPress = false;
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
    this.trackpad.updateConfig(sensitivity, undefined, undefined);
  }
  
  /**
   * 处理触摸事件
   */
  handleTouchEvent(event: TouchEvent): void {
    const touches = event.touches;

    // DS5 触控板的 Up/Cancel 可能只携带 changedTouches，不能在这里提前返回。
    if (this.mode === TouchInputMode.DS5_TOUCHPAD) {
      this.ds5Touchpad.handleEvent(event);
      return;
    }

    if (touches.length === 0) return;

    // 检测手写笔输入：SourceTool.Pen = 2
    // 仅在 DIRECT 模式下发送 Pen 协议事件（带压感/倾斜），
    // TRACKPAD/MOUSE 模式下手写笔当作手指处理（控制光标）
    if (event.sourceTool === SourceTool.Pen && this.mode === TouchInputMode.DIRECT && !this.penUnsupported) {
      this.handlePenEvent(event);
      return;
    }
    
    // DIRECT 模式支持多点触控，需要处理所有触摸点
    if (this.mode === TouchInputMode.DIRECT) {
      this.handleMultiTouchEvent(event);
      return;
    }
    
    // TRACKPAD 模式：委托给 TrackpadGestureHandler
    if (this.mode === TouchInputMode.TRACKPAD) {
      this.trackpad.handleEvent(event);
      return;
    }
    
    // MOUSE 模式：绝对定位 + 死区 + 长按右键 + 双指滚轮（对齐 Android AbsoluteTouchContext）
    this.handleMouseEvent(event);
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
          // DOWN 时尚无历史压力数据，使用默认值 1.0
          this.lastForce.set(touch.id, 1.0);
          this.lastSize.set(touch.id, 0.05);
          this.sendNormalizedTouch(TOUCH_EVENT_DOWN, touch, event);
        }
        break;
        
      case TouchType.Move:
        // 首先处理历史触摸点（更高的采样率，且包含真实压力数据）
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
                // 归一化历史点的压力和接触面积
                const normalizedForce = histPoint.force > 0
                  ? this.normalizeForce(histPoint.force) : this.getTrackedForce(histTouch.id);
                const contactSize = histPoint.size || this.getTrackedSize(histTouch.id);
                
                // 追踪每个触摸点的最新压力和面积
                this.lastForce.set(histTouch.id, normalizedForce);
                this.lastSize.set(histTouch.id, contactSize);
                
                this.sendNormalizedTouchDirect(
                  TOUCH_EVENT_MOVE,
                  histTouch.id,
                  histTouch.x,
                  histTouch.y,
                  areaWidth,
                  areaHeight,
                  normalizedForce,
                  contactSize
                );
              }
            }
          }
        } catch (e) {
          // 某些设备可能不支持 getHistoricalPoints，忽略错误
        }
        
        // 然后处理当前触摸点（使用历史点追踪的压力值）
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
          this.lastForce.delete(touch.id);
          this.lastSize.delete(touch.id);
        }
        break;
    }
  }
  
  // ====== MOUSE 模式：绝对定位（对齐 Android AbsoluteTouchContext） ======

  /**
   * 计算两点间距离是否超过阈值
   */
  private mouseDistanceExceeds(deltaX: number, deltaY: number, limit: number): boolean {
    return Math.sqrt(deltaX * deltaX + deltaY * deltaY) > limit;
  }

  /**
   * 更新绝对鼠标位置（限制在组件区域内）
   */
  private mouseUpdatePosition(eventX: number, eventY: number): void {
    // 坐标变换（画面缩放/平移状态下修正触摸坐标）
    let posX = eventX;
    let posY = eventY;
    if (this.coordinateTransform) {
      const transformed = this.coordinateTransform(posX, posY);
      posX = transformed.x;
      posY = transformed.y;
    }
    const x = Math.min(Math.max(posX, 0), this.mouseAreaWidth);
    const y = Math.min(Math.max(posY, 0), this.mouseAreaHeight);
    this.nativeInput.sendMousePosition(
      Math.floor(x), Math.floor(y),
      Math.floor(this.mouseAreaWidth), Math.floor(this.mouseAreaHeight)
    );
  }

  /**
   * 确认点击（死区时间/距离超过后调用）
   * 发送绝对鼠标位置 + 左键按下
   */
  private mouseTapConfirmed(): void {
    if (this.mouseConfirmedTap || this.mouseConfirmedLongPress) {
      return;
    }
    this.mouseConfirmedTap = true;
    this.cancelMouseTapDownTimer();

    // 双击判定：如果启用双击拖动且本次按下距上次抬起很近且时间短，不重定位（方便双击）
    if (!this.enableDoubleClickDrag ||
        this.mouseDownTime - this.mouseLastUpTime > this.mouseDoubleTapTime ||
        this.mouseDistanceExceeds(
          this.mouseDownX - this.mouseLastUpX,
          this.mouseDownY - this.mouseLastUpY,
          TouchInputHandler.MOUSE_DOUBLE_TAP_DISTANCE)) {
      this.mouseUpdatePosition(this.mouseDownX, this.mouseDownY);
    }
    this.nativeInput.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_LEFT);
  }

  /**
   * 取消主手指手势（第二根手指出现时调用）
   */
  private mouseCancelTouch(): void {
    this.mouseCancelled = true;
    this.cancelMouseLongPressTimer();
    this.cancelMouseTapDownTimer();

    if (this.mouseConfirmedLongPress) {
      this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
    } else if (this.mouseConfirmedTap) {
      this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
  }

  private startMouseLongPressTimer(): void {
    this.cancelMouseLongPressTimer();
    this.mouseLongPressTimer = setTimeout(() => {
      this.cancelMouseTapDownTimer();
      this.mouseConfirmedLongPress = true;
      if (this.mouseConfirmedTap) {
        this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
      }
      this.nativeInput.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
    }, this.mouseLongPressTime);
  }

  private cancelMouseLongPressTimer(): void {
    if (this.mouseLongPressTimer !== -1) {
      clearTimeout(this.mouseLongPressTimer);
      this.mouseLongPressTimer = -1;
    }
  }

  private startMouseTapDownTimer(): void {
    this.cancelMouseTapDownTimer();
    this.mouseTapDownTimer = setTimeout(() => {
      this.mouseTapConfirmed();
    }, this.mouseDeadzoneTime);
  }

  private cancelMouseTapDownTimer(): void {
    if (this.mouseTapDownTimer !== -1) {
      clearTimeout(this.mouseTapDownTimer);
      this.mouseTapDownTimer = -1;
    }
  }

  /**
   * 处理鼠标模式触摸事件（对齐 Android AbsoluteTouchContext，但以 event.touches 为权威状态）
   *
   * 每次事件先做"对账"：若 primary / second 手指不在 event.touches 中，
   * 说明手指已抬起，无论是否有对应的 Up/Cancel / changedTouches 是否包含该手指，
   * 一律走 release 流程。这样根治 ArkUI 下 Cancel 丢 primary、命中测试抖动、
   * overlay 插入、返回手势中断等导致的手指状态残留。
   *
   * - 主手指：绝对定位 + 死区 + 长按右键
   * - 第二根手指：垂直滚轮 + 取消主手指手势
   */
  private handleMouseEvent(event: TouchEvent): void {
    this.mouseAreaWidth = event.target.area.width as number;
    this.mouseAreaHeight = event.target.area.height as number;

    // 1. 对账：以 event.touches 为权威，清理已消失的手指
    this.reconcileMouseFingers(event);

    // 2. 按事件类型分发 changedTouches（抬起路径已在对账阶段处理）
    const changedTouches = event.changedTouches;
    switch (event.type) {
      case TouchType.Down:
        for (const touch of changedTouches) {
          if (this.mousePrimaryFingerId === -1) {
            this.onMousePrimaryDown(touch);
          } else if (this.mouseSecondFingerId === -1 && touch.id !== this.mousePrimaryFingerId) {
            this.onMouseSecondDown(touch);
          }
          // 第三根及以上：忽略
        }
        break;

      case TouchType.Move:
        for (const touch of changedTouches) {
          if (touch.id === this.mousePrimaryFingerId && !this.mouseCancelled) {
            this.onMousePrimaryMove(touch);
          } else if (touch.id === this.mouseSecondFingerId) {
            this.onMouseSecondMove(touch);
          }
        }
        break;

      case TouchType.Up:
      case TouchType.Cancel:
        // 已在对账阶段处理
        break;
    }
  }

  /**
   * 对账：若 primary / second 不在 event.touches 中，视为已抬起并释放。
   *
   * ArkUI 在 Up/Cancel 事件里 event.touches 是否包含正在抬起的手指行为不一致，
   * 这里统一把 changedTouches（仅对 Up/Cancel）当作"正在抬起"从 active 中剔除，
   * 两种约定都能正确收敛。
   */
  private reconcileMouseFingers(event: TouchEvent): void {
    const isLiftEvent = event.type === TouchType.Up || event.type === TouchType.Cancel;
    const liftingIds: Set<number> = new Set<number>();
    if (isLiftEvent) {
      for (const t of event.changedTouches) liftingIds.add(t.id);
    }
    const activeIds: Set<number> = new Set<number>();
    for (const t of event.touches) {
      if (!liftingIds.has(t.id)) activeIds.add(t.id);
    }

    if (this.mousePrimaryFingerId !== -1 && !activeIds.has(this.mousePrimaryFingerId)) {
      const final = event.changedTouches.find((t: TouchObject) => t.id === this.mousePrimaryFingerId);
      const x = final ? final.x : this.mouseLastX;
      const y = final ? final.y : this.mouseLastY;
      this.onMousePrimaryRelease(x, y);
    }

    if (this.mouseSecondFingerId !== -1 && !activeIds.has(this.mouseSecondFingerId)) {
      this.mouseSecondFingerId = -1;
    }
  }

  private onMousePrimaryDown(touch: TouchObject): void {
    this.mousePrimaryFingerId = touch.id;
    this.mouseDownX = this.mouseLastX = touch.x;
    this.mouseDownY = this.mouseLastY = touch.y;
    this.mouseDownTime = Date.now();
    this.mouseCancelled = false;
    this.mouseConfirmedTap = false;
    this.mouseConfirmedLongPress = false;

    this.startMouseTapDownTimer();
    this.startMouseLongPressTimer();
  }

  private onMouseSecondDown(touch: TouchObject): void {
    this.mouseSecondFingerId = touch.id;
    this.mouseSecondFingerLastY = touch.y;
    this.mouseCancelTouch();
  }

  private onMousePrimaryMove(touch: TouchObject): void {
    // 移动过远 → 取消长按
    if (this.mouseDistanceExceeds(
      touch.x - this.mouseDownX, touch.y - this.mouseDownY,
      TouchInputHandler.MOUSE_LONG_PRESS_DISTANCE)) {
      this.cancelMouseLongPressTimer();
    }
    // 死区外 → 确认点击并更新绝对位置
    if (this.mouseConfirmedTap
        || this.mouseDistanceExceeds(
          touch.x - this.mouseDownX, touch.y - this.mouseDownY,
          TouchInputHandler.MOUSE_DEADZONE_DISTANCE)) {
      this.mouseTapConfirmed();
      this.mouseUpdatePosition(touch.x, touch.y);
    }
    this.mouseLastX = touch.x;
    this.mouseLastY = touch.y;
  }

  private onMouseSecondMove(touch: TouchObject): void {
    const deltaY = touch.y - this.mouseSecondFingerLastY;
    this.nativeInput.sendMouseHighResScroll(
      Math.round(deltaY * TouchInputHandler.MOUSE_SCROLL_SPEED_FACTOR)
    );
    this.mouseSecondFingerLastY = touch.y;
  }

  /**
   * primary 手指释放的统一路径（对账 + 正常 Up/Cancel 共享）
   */
  private onMousePrimaryRelease(finalX: number, finalY: number): void {
    this.mousePrimaryFingerId = -1;

    if (!this.mouseCancelled) {
      this.cancelMouseLongPressTimer();
      this.cancelMouseTapDownTimer();

      if (this.mouseConfirmedLongPress) {
        this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
      } else if (this.mouseConfirmedTap) {
        this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
      } else {
        // 死区时间内完成的快速点击：立即按下，按当前触摸参数延迟释放
        this.mouseTapConfirmed();
        if (this.mouseLeftButtonUpTimer !== -1) {
          clearTimeout(this.mouseLeftButtonUpTimer);
        }
        this.mouseLeftButtonUpTimer = setTimeout(() => {
          this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
          this.mouseLeftButtonUpTimer = -1;
        }, this.mouseClickReleaseDelay);
      }
    }

    this.mouseLastUpX = finalX;
    this.mouseLastUpY = finalY;
    this.mouseLastUpTime = Date.now();
  }
  
  /**
   * 发送归一化的触摸事件
   * 支持压感：使用历史点追踪的压力值，或 touch.force（如果可用）
   */
  private sendNormalizedTouch(eventType: number, touch: TouchObject, event: TouchEvent): void {
    const areaWidth = event.target.area.width as number;
    const areaHeight = event.target.area.height as number;
    
    // 坐标变换（画面缩放/平移状态下修正触摸坐标）
    let touchX = touch.x;
    let touchY = touch.y;
    if (this.coordinateTransform) {
      const transformed = this.coordinateTransform(touchX, touchY);
      touchX = transformed.x;
      touchY = transformed.y;
    }
    
    // 归一化到 0.0-1.0 范围
    const normalizedX = Math.max(0, Math.min(1, touchX / areaWidth));
    const normalizedY = Math.max(0, Math.min(1, touchY / areaHeight));
    
    // 压感处理：
    // 1. UP 事件 → 0
    // 2. TouchObject.force（某些 API 版本可能提供）
    // 3. 从历史点追踪的最后已知压力值
    // 4. 默认值 1.0
    let pressure: number;
    let contactArea: number;
    if (eventType === TOUCH_EVENT_UP) {
      pressure = 0;
      contactArea = 0;
    } else {
      pressure = this.getTrackedForce(touch.id);
      contactArea = this.getTrackedSize(touch.id);
    }
    
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
    // 坐标变换（画面缩放/平移状态下修正触摸坐标）
    let touchX = x;
    let touchY = y;
    if (this.coordinateTransform) {
      const transformed = this.coordinateTransform(touchX, touchY);
      touchX = transformed.x;
      touchY = transformed.y;
    }
    
    const normalizedX = Math.max(0, Math.min(1, touchX / areaWidth));
    const normalizedY = Math.max(0, Math.min(1, touchY / areaHeight));
    
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

  // ====== 手写笔（Pen/Stylus）处理 ======

  /**
   * 检测手写笔的工具类型
   * ArkUI SourceTool.Pen = 2, 这里还需要区分橡皮擦
   * 注意：ArkUI 没有直接区分 PEN 和 ERASER 的 SourceTool，
   * 但 InputKit 的 ToolType 有 RUBBER = 2 和 PENCIL = 4
   * 这里我们只能通过 SourceTool 判断是否为笔类输入
   */
  private getPenToolType(): number {
    // ArkUI 层面暂无橡皮擦区分，统一为 PEN
    return LI_TOOL_TYPE_PEN;
  }

  /**
   * 将 ArkUI 的 tiltX + tiltY（度）转换为 Moonlight 协议的单一倾斜角度
   *
   * ArkUI tiltX: 手写笔在 X 轴方向的投影角度 [-90, 90]
   * ArkUI tiltY: 手写笔在 Y 轴方向的投影角度 [-90, 90]
   * Moonlight tilt: 从垂直方向的偏离角度 [0, 90]，0 = 垂直，90 = 水平
   */
  private computePenTilt(tiltX: number, tiltY: number): number {
    if (tiltX === 0 && tiltY === 0) {
      return 0; // 垂直于屏幕
    }
    const tiltXRad = tiltX * Math.PI / 180;
    const tiltYRad = tiltY * Math.PI / 180;
    // 从 tiltX/tiltY 投影角合成总倾斜角
    const tanTiltX = Math.tan(tiltXRad);
    const tanTiltY = Math.tan(tiltYRad);
    const tiltRad = Math.atan(Math.sqrt(tanTiltX * tanTiltX + tanTiltY * tanTiltY));
    return Math.min(90, Math.round(tiltRad * 180 / Math.PI));
  }

  /**
   * 获取手写笔旋转角度（0-359度）
   * ArkUI BaseEvent.rollAngle 为 Z 轴旋转角（API 17+）
   */
  private computePenRotation(event: TouchEvent): number {
    // rollAngle 是 API 17+ 的可选属性
    const rollAngle = event.rollAngle;
    if (rollAngle !== undefined && rollAngle !== null) {
      let degrees = Math.round(rollAngle);
      if (degrees < 0) {
        degrees += 360;
      }
      return degrees % 360;
    }
    return LI_ROT_UNKNOWN;
  }

  /**
   * 处理手写笔事件（仅 DIRECT 模式）
   * 将手写笔触摸事件转化为 Moonlight 的 PenEvent
   */
  private handlePenEvent(event: TouchEvent): void {
    const touches = event.touches;
    const changedTouches = event.changedTouches;
    const areaWidth = event.target.area.width as number;
    const areaHeight = event.target.area.height as number;

    // 从 BaseEvent 获取笔的压感和倾斜信息
    const eventPressure = event.pressure ?? 0;
    const tiltX = event.tiltX ?? 0;
    const tiltY = event.tiltY ?? 0;
    const tilt = this.computePenTilt(tiltX, tiltY);
    const rotation = this.computePenRotation(event);
    const toolType = this.getPenToolType();

    // 首次手写笔事件诊断日志
    if (!this.penFirstEventLogged) {
      this.penFirstEventLogged = true;
      console.info(`手写笔首次事件: sourceTool=${event.sourceTool}, pressure=${eventPressure}, ` +
        `tiltX=${tiltX}, tiltY=${tiltY}, computedTilt=${tilt}, rotation=${rotation}, ` +
        `type=${event.type}, pointers=${touches.length}`);
    }

    switch (event.type) {
      case TouchType.Down:
        for (let i = 0; i < changedTouches.length; i++) {
          const touch = changedTouches[i];
          this.touchStates.set(touch.id, {
            startX: touch.x, startY: touch.y,
            lastX: touch.x, lastY: touch.y,
            startTime: Date.now()
          });

          const normalizedX = Math.max(0, Math.min(1, touch.x / areaWidth));
          const normalizedY = Math.max(0, Math.min(1, touch.y / areaHeight));
          // 手写笔通常只有一个触点，使用 BaseEvent 上的压感
          const pressure = eventPressure;
          // 尝试获取 per-touch 接触面积（API 15+）
          const contactW = touch.width ?? 0;
          const contactH = touch.height ?? 0;
          // 归一化接触面积到视图尺寸
          const areaMajor = areaWidth > 0 ? Math.min(contactW, areaWidth) / areaWidth : 0;
          const areaMinor = areaHeight > 0 ? Math.min(contactH, areaHeight) / areaHeight : 0;

          const ret = this.nativeInput.sendPenEvent(
            TOUCH_EVENT_DOWN, toolType, 0, // penButtons: ArkUI 无按钮信息
            normalizedX, normalizedY, pressure,
            areaMajor, areaMinor, rotation, tilt
          );
          // 检测主机是否支持 Pen 事件
          if (ret === -7) { // LI_ERR_UNSUPPORTED = -7
            console.warn('手写笔: 主机不支持 Pen 事件，回退到 Touch 事件');
            this.penUnsupported = true;
            // 回退：用 touch 事件重新发送
            this.sendNormalizedTouch(TOUCH_EVENT_DOWN, touch, event);
            return;
          }
        }
        break;

      case TouchType.Move:
        // 处理历史点（高采样率）
        try {
          const historicalPoints = event.getHistoricalPoints();
          if (historicalPoints && historicalPoints.length > 0) {
            const now = Date.now();
            for (let i = 0; i < historicalPoints.length; i++) {
              const histPoint = historicalPoints[i];
              if (histPoint.timestamp && (now - histPoint.timestamp) > 100) {
                continue;
              }
              const histTouch = histPoint.touchObject;
              const state = this.touchStates.get(histTouch.id);
              if (state) {
                const normalizedX = Math.max(0, Math.min(1, histTouch.x / areaWidth));
                const normalizedY = Math.max(0, Math.min(1, histTouch.y / areaHeight));
                // 历史点的压力
                const histPressure = histPoint.force > 0
                  ? this.normalizeForce(histPoint.force) : eventPressure;
                const histSize = histPoint.size || 0;

                this.nativeInput.sendPenEvent(
                  TOUCH_EVENT_MOVE, toolType, 0,
                  normalizedX, normalizedY, histPressure,
                  histSize, histSize, rotation, tilt
                );
              }
            }
          }
        } catch (_e) {
          // 忽略不支持 getHistoricalPoints 的设备
        }

        // 处理当前触摸点
        for (let i = 0; i < touches.length; i++) {
          const touch = touches[i];
          const state = this.touchStates.get(touch.id);
          if (state) {
            state.lastX = touch.x;
            state.lastY = touch.y;

            const normalizedX = Math.max(0, Math.min(1, touch.x / areaWidth));
            const normalizedY = Math.max(0, Math.min(1, touch.y / areaHeight));
            const pressure = touch.pressure ?? eventPressure;
            const contactW = touch.width ?? 0;
            const contactH = touch.height ?? 0;
            const areaMajor = areaWidth > 0 ? Math.min(contactW, areaWidth) / areaWidth : 0;
            const areaMinor = areaHeight > 0 ? Math.min(contactH, areaHeight) / areaHeight : 0;

            this.nativeInput.sendPenEvent(
              TOUCH_EVENT_MOVE, toolType, 0,
              normalizedX, normalizedY, pressure,
              areaMajor, areaMinor, rotation, tilt
            );
          }
        }
        break;

      case TouchType.Up:
      case TouchType.Cancel:
        for (let i = 0; i < changedTouches.length; i++) {
          const touch = changedTouches[i];
          const normalizedX = Math.max(0, Math.min(1, touch.x / areaWidth));
          const normalizedY = Math.max(0, Math.min(1, touch.y / areaHeight));

          const upEventType = event.type === TouchType.Cancel ? TOUCH_EVENT_CANCEL : TOUCH_EVENT_UP;

          this.nativeInput.sendPenEvent(
            upEventType, toolType, 0,
            normalizedX, normalizedY, 0, // pressure = 0 on up
            0, 0, rotation, tilt
          );
          this.touchStates.delete(touch.id);
        }
        break;
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
    this.trackpad.dispose();
    this.ds5Touchpad.dispose();
    this.resetMouseState(false);
    this.touchStates.clear();
    this.lastForce.clear();
    this.lastSize.clear();
    this.penUnsupported = false;
    this.penFirstEventLogged = false;
  }
}
