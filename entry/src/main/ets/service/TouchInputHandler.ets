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
const TOUCH_EVENT_CANCEL = 0x04;
const TOUCH_EVENT_HOVER = 0x00;
const TOUCH_EVENT_CANCEL_ALL = 0x07;

// 手写笔工具类型常量（对应 Moonlight 协议）
const LI_TOOL_TYPE_UNKNOWN = 0x00;
const LI_TOOL_TYPE_PEN = 0x01;
const LI_TOOL_TYPE_ERASER = 0x02;

// 手写笔按钮常量
const LI_PEN_BUTTON_PRIMARY = 0x01;
const LI_PEN_BUTTON_SECONDARY = 0x02;

// 手写笔未知值常量
const LI_TILT_UNKNOWN = 0xFF;
const LI_ROT_UNKNOWN = 0xFFFF;

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
  
  // ====== 双指手势状态（用于触控板模式的右键和滚轮） ======
  /** 双指按下时的时间戳 */
  private twoFingerDownTime: number = 0;
  /** 第一根手指抬起的时间戳 */
  private firstFingerUpTime: number = 0;
  /** 是否有待处理的双指轻触（等待第二根手指抬起确认） */
  private twoFingerTapPending: boolean = false;
  /** 双指按下后是否发生了明显移动（若移动则为滚轮，不再是右键轻触） */
  private twoFingerMoved: boolean = false;
  /** 双指按下时第一根手指的起始位置 */
  private twoFingerStartX: number = 0;
  private twoFingerStartY: number = 0;
  /** 当前触摸点数量（实时跟踪） */
  private activePointerCount: number = 0;
  /** 本次手势中出现过的最大触摸点数量 */
  private maxPointerCountInGesture: number = 0;
  /** 双指滚轮模式已确认 */
  private confirmedScroll: boolean = false;
  /** 第二根手指的最后位置（用于计算滚轮增量） */
  private secondFingerLastY: number = 0;

  // 双指手势常量
  /** 双指轻触右键的时间阈值（ms）—— 双指按下到抬起在此时间内视为轻触 */
  private static readonly TWO_FINGER_TAP_THRESHOLD = 250;
  /** 双指移动阈值（px）—— 超过此距离视为滚轮，不再是轻触 */
  private static readonly TWO_FINGER_MOVE_THRESHOLD = 30;
  /** 滚轮速度因子 */
  private static readonly SCROLL_SPEED_FACTOR = 5;

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
    
    // TRACKPAD 模式：支持多指手势（双指右键 + 双指滚轮）
    if (this.mode === TouchInputMode.TRACKPAD) {
      this.handleTrackpadEvent(event);
      return;
    }
    
    // MOUSE 模式：只处理第一个触摸点
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
  
  // ====== 触控板模式多指手势处理 ======

  /**
   * 处理触控板模式的触摸事件（支持多指手势）
   * 
   * 手势逻辑：
   * - 单指移动 → 移动光标
   * - 单指轻触 → 左键点击
   * - 双指轻触 → 右键点击（参考 Android moonlight 的 TWO_FINGER_TAP 实现）
   * - 双指滑动 → 滚轮
   * - 三指轻触 → 可扩展（如弹出键盘）
   */
  private handleTrackpadEvent(event: TouchEvent): void {
    const touches = event.touches;
    const changedTouches = event.changedTouches;
    
    switch (event.type) {
      case TouchType.Down:
        this.handleTrackpadDown(touches, changedTouches, event);
        break;
      case TouchType.Move:
        this.handleTrackpadMove(touches, event);
        break;
      case TouchType.Up:
      case TouchType.Cancel:
        this.handleTrackpadUp(touches, changedTouches, event);
        break;
    }
  }

  /**
   * 触控板模式 - 按下
   */
  private handleTrackpadDown(touches: TouchObject[], changedTouches: TouchObject[], event: TouchEvent): void {
    // 更新触摸点计数
    this.activePointerCount = touches.length;
    if (this.activePointerCount > this.maxPointerCountInGesture) {
      this.maxPointerCountInGesture = this.activePointerCount;
    }

    // 为每个新按下的触摸点记录状态
    for (const touch of changedTouches) {
      this.touchStates.set(touch.id, {
        startX: touch.x,
        startY: touch.y,
        lastX: touch.x,
        lastY: touch.y,
        startTime: Date.now()
      });
    }

    // 双指按下：记录起始信息用于后续判断（右键轻触 or 滚轮）
    if (touches.length === 2) {
      this.twoFingerDownTime = Date.now();
      this.twoFingerStartX = touches[0].x;
      this.twoFingerStartY = touches[0].y;
      this.twoFingerMoved = false;
      this.twoFingerTapPending = false;
      this.confirmedScroll = false;
      this.secondFingerLastY = touches[1].y;
    }
  }

  /**
   * 触控板模式 - 移动
   */
  private handleTrackpadMove(touches: TouchObject[], event: TouchEvent): void {
    if (touches.length === 1 && this.maxPointerCountInGesture === 1) {
      // ---- 单指移动：移动光标 ----
      const touch = touches[0];
      const state = this.touchStates.get(touch.id);
      if (!state) return;

      const deltaX = touch.x - state.lastX;
      const deltaY = touch.y - state.lastY;
      state.lastX = touch.x;
      state.lastY = touch.y;

      const sensitivity = this.config.sensitivity!;
      this.nativeInput.sendMouseMove(
        Math.floor(deltaX * sensitivity),
        Math.floor(deltaY * sensitivity)
      );
    } else if (touches.length === 2) {
      // ---- 双指移动：检测是否超出移动阈值 ----
      if (!this.twoFingerMoved) {
        const dx = touches[0].x - this.twoFingerStartX;
        const dy = touches[0].y - this.twoFingerStartY;
        if (Math.sqrt(dx * dx + dy * dy) > TouchInputHandler.TWO_FINGER_MOVE_THRESHOLD) {
          this.twoFingerMoved = true;
          this.confirmedScroll = true;
        }
      }

      // 已确认为滚轮模式：用第一根手指的 Y 轴增量作为滚轮值
      if (this.confirmedScroll) {
        const touch = touches[0];
        const state = this.touchStates.get(touch.id);
        if (state) {
          const deltaY = touch.y - state.lastY;
          state.lastX = touch.x;
          state.lastY = touch.y;

          if (Math.abs(deltaY) > 0) {
            // 触感方向：手指下滑 → deltaY > 0 → 页面向下滚 → scrollAmount 为负值
            const scrollAmount = Math.round(-deltaY * TouchInputHandler.SCROLL_SPEED_FACTOR);
            this.nativeInput.sendMouseHighResScroll(scrollAmount);
          }
        }

        // 同步更新第二根手指的 lastX/lastY
        const secondState = this.touchStates.get(touches[1].id);
        if (secondState) {
          secondState.lastX = touches[1].x;
          secondState.lastY = touches[1].y;
        }
      }
    }
  }

  /**
   * 触控板模式 - 抬起
   */
  private handleTrackpadUp(touches: TouchObject[], changedTouches: TouchObject[], event: TouchEvent): void {
    const now = Date.now();
    // 计算剩余触摸点数量
    // HarmonyOS ArkUI 的 touches 在 Up 事件中不包含正在抬起的手指（类似 Web 标准），
    // 因此用已追踪的 activePointerCount 减去抬起数量来计算，确保计算一致。
    const remainingPointers = Math.max(0, this.activePointerCount - changedTouches.length);

    // ---- 双指右键检测（仿 Android Game.java 逻辑）----
    // 情况A：从2指变为1指（第一根手指抬起）
    if (this.activePointerCount === 2 && remainingPointers === 1 && !this.twoFingerMoved) {
      const elapsed = now - this.twoFingerDownTime;
      if (elapsed < TouchInputHandler.TWO_FINGER_TAP_THRESHOLD) {
        // 快速双指轻触：立即发送右键
        this.nativeInput.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
        setTimeout(() => {
          this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        }, 50);
        this.twoFingerTapPending = false;
        this.twoFingerMoved = true; // 防止重复触发
        this.resetTrackpadGesture(changedTouches);
        this.activePointerCount = remainingPointers;
        return;
      } else {
        // 非快速轻触，进入 pending 状态等待最后一根手指也抬起
        this.firstFingerUpTime = now;
        this.twoFingerTapPending = true;
      }
    }

    // 情况B：从1指变为0指（最后一根手指抬起）
    if (remainingPointers === 0) {
      if (this.twoFingerTapPending && !this.twoFingerMoved) {
        const elapsed = now - this.firstFingerUpTime;
        if (elapsed < TouchInputHandler.TWO_FINGER_TAP_THRESHOLD) {
          // 两根手指相继快速抬起：发送右键
          this.nativeInput.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
          setTimeout(() => {
            this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
          }, 50);
          this.twoFingerTapPending = false;
          this.resetTrackpadGesture(changedTouches);
          this.activePointerCount = 0;
          this.maxPointerCountInGesture = 0;
          return;
        }
      }
      this.twoFingerTapPending = false;

      // ---- 单指轻触左键检测 ----
      if (this.maxPointerCountInGesture === 1) {
        for (const touch of changedTouches) {
          const state = this.touchStates.get(touch.id);
          if (state) {
            this.checkForClick(touch, state);
          }
        }
      }

      // 手势结束，重置所有状态
      this.maxPointerCountInGesture = 0;
    }

    // 清理抬起的触摸点
    this.resetTrackpadGesture(changedTouches);
    this.activePointerCount = remainingPointers;
  }

  /**
   * 清理已抬起触摸点的状态
   */
  private resetTrackpadGesture(changedTouches: TouchObject[]): void {
    for (const touch of changedTouches) {
      this.touchStates.delete(touch.id);
    }
  }

  /**
   * 处理触摸按下 (MOUSE 模式)
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
   * 处理触摸移动 (MOUSE 模式)
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
    
    if (this.mode === TouchInputMode.MOUSE) {
      // 鼠标模式：移动光标（相对移动）
      this.nativeInput.sendMouseMove(
        Math.floor(deltaX),
        Math.floor(deltaY)
      );
    }
  }
  
  /**
   * 处理触摸抬起 (MOUSE 模式)
   */
  private handleTouchUp(touch: TouchObject, event: TouchEvent): void {
    const state = this.touchStates.get(touch.id);
    
    if (this.mode === TouchInputMode.MOUSE) {
      // 鼠标模式：释放左键
      this.nativeInput.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
    
    // 清理触摸状态
    this.touchStates.delete(touch.id);
  }
  
  /**
   * 发送归一化的触摸事件
   * 支持压感：使用历史点追踪的压力值，或 touch.force（如果可用）
   */
  private sendNormalizedTouch(eventType: number, touch: TouchObject, event: TouchEvent): void {
    const areaWidth = event.target.area.width as number;
    const areaHeight = event.target.area.height as number;
    
    // 归一化到 0.0-1.0 范围
    const normalizedX = Math.max(0, Math.min(1, touch.x / areaWidth));
    const normalizedY = Math.max(0, Math.min(1, touch.y / areaHeight));
    
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
    if (moveDistance < this.config.clickThreshold! && touchDuration < this.config.clickTimeThreshold!) {
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
    this.lastForce.clear();
    this.lastSize.clear();
    this.penUnsupported = false;
    this.penFirstEventLogged = false;
  }
}
