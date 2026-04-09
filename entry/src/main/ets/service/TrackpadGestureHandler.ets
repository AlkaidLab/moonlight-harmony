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
 * 触控板手势处理器
 *
 * 对齐 Android RelativeTouchContext 的完整手势状态机：
 * - 单指滑动 → 相对鼠标移动（带死区确认）
 * - 单指轻触 → 左键点击
 * - 长按 (650ms) → 左键拖拽
 * - 双击拖拽 → 快速双击第二次按住拖拽，松手发送双击
 * - 双指轻触 → 右键点击
 * - 双指滑动 → 滚轮
 */
import {
  BUTTON_ACTION_PRESS,
  BUTTON_ACTION_RELEASE,
  BUTTON_LEFT,
  BUTTON_RIGHT,
} from './MoonBridge';

/** 发送输入事件所需的最小接口 */
export interface TrackpadInputSink {
  sendMouseMove(deltaX: number, deltaY: number): void;
  sendMouseButton(buttonEvent: number, mouseButton: number): void;
  sendMouseHighResScroll(scrollAmount: number): void;
}

/** 触控板配置 */
export interface TrackpadConfig {
  /** 灵敏度乘数，默认 1.5 */
  sensitivity: number;
  /** 双指轻触/双击时间阈值 (ms) */
  tapTimeThreshold: number;
  /** 是否启用双击拖拽 */
  enableDoubleClickDrag: boolean;
}

// ---------- 内部类型 ----------

interface FingerState {
  startX: number;
  startY: number;
  lastX: number;
  lastY: number;
  startTime: number;
}

// ---------- 常量（对齐 Android RelativeTouchContext） ----------

/** 单次偏移超过此值不再视为轻触 (px) */
const TAP_MOVEMENT_THRESHOLD = 40;
/** 累计移动超过此值确认为移动 (px) */
const TAP_DISTANCE_THRESHOLD = 50;
/** 轻触最大时长 (ms) */
const TAP_TIME_THRESHOLD = 250;
/** 长按拖拽时间 (ms) */
const DRAG_TIME_THRESHOLD = 650;
/** 双击待定态下开始拖拽的移动阈值 (px) */
const DRAG_START_THRESHOLD = 10;
/** 双击按住确认拖拽时间 (ms) */
const DOUBLE_TAP_HOLD_THRESHOLD = 200;
/** 双击两次位置最大偏差 (px) */
const DOUBLE_TAP_MOVEMENT_THRESHOLD = 40;
/** 双指移动阈值 — 超过后视为滚轮 (px) */
const TWO_FINGER_MOVE_THRESHOLD = 30;
/** 滚轮速度因子 */
const SCROLL_SPEED_FACTOR = 5;

export class TrackpadGestureHandler {
  private sink: TrackpadInputSink;
  private config: TrackpadConfig;

  // ---- 手指追踪 ----
  private fingers = new Map<number, FingerState>();
  private activeCount = 0;
  private maxCountInGesture = 0;

  // ---- 单指移动/拖拽状态 ----
  private confirmedMove = false;
  private confirmedDrag = false;
  private distanceMoved = 0;
  private dragTimer: number = -1;

  // ---- 双击拖拽状态 ----
  private isDoubleClickDrag = false;
  private isPotentialDoubleClick = false;
  private lastTapUpTime = 0;
  private lastTapUpX = 0;
  private lastTapUpY = 0;
  private singleTapTimer: number = -1;
  private doubleTapHoldTimer: number = -1;

  // ---- 双指手势状态 ----
  private twoFingerDownTime = 0;
  private firstFingerUpTime = 0;
  private twoFingerTapPending = false;
  private twoFingerMoved = false;
  private twoFingerStartX = 0;
  private twoFingerStartY = 0;
  private confirmedScroll = false;

  constructor(sink: TrackpadInputSink, config: TrackpadConfig) {
    this.sink = sink;
    this.config = config;
  }

  // ==================== 公共配置 ====================

  updateConfig(sensitivity?: number, tapTimeThreshold?: number, enableDoubleClickDrag?: boolean): void {
    if (sensitivity !== undefined) this.config.sensitivity = sensitivity;
    if (tapTimeThreshold !== undefined) this.config.tapTimeThreshold = tapTimeThreshold;
    if (enableDoubleClickDrag !== undefined) this.config.enableDoubleClickDrag = enableDoubleClickDrag;
  }

  // ==================== 事件入口 ====================

  handleEvent(event: TouchEvent): void {
    const touches = event.touches;
    const changedTouches = event.changedTouches;
    switch (event.type) {
      case TouchType.Down:
        this.onDown(touches, changedTouches);
        break;
      case TouchType.Move:
        this.onMove(touches);
        break;
      case TouchType.Up:
      case TouchType.Cancel:
        this.onUp(touches, changedTouches);
        break;
    }
  }

  dispose(): void {
    this.cancelDragTimer();
    this.cancelSingleTapTimer();
    this.cancelDoubleTapHoldTimer();
    this.fingers.clear();
  }

  // ==================== Down ====================

  private onDown(touches: TouchObject[], changed: TouchObject[]): void {
    const now = Date.now();
    this.activeCount = touches.length;
    if (this.activeCount > this.maxCountInGesture) {
      this.maxCountInGesture = this.activeCount;
    }

    for (const t of changed) {
      this.fingers.set(t.id, {
        startX: t.x, startY: t.y,
        lastX: t.x, lastY: t.y,
        startTime: now
      });
    }

    // 单指手势：拖拽/双击判定
    if (changed.length > 0 && this.activeCount === 1) {
      this.cancelSingleTapTimer();
      this.cancelDoubleTapHoldTimer();
      this.resetGestureFlags();

      if (this.config.enableDoubleClickDrag && this.detectDoubleTapStart(changed[0], now)) {
        return; // 进入双击待定状态，不启动长按计时器
      }
      this.startDragTimer();
    }

    // 双指按下
    if (touches.length === 2) {
      this.cancelDragTimer();
      this.twoFingerDownTime = now;
      this.twoFingerStartX = touches[0].x;
      this.twoFingerStartY = touches[0].y;
      this.twoFingerMoved = false;
      this.twoFingerTapPending = false;
      this.confirmedScroll = false;
    }
  }

  // ==================== Move ====================

  private onMove(touches: TouchObject[]): void {
    if (touches.length === 1 && this.maxCountInGesture === 1) {
      this.onSingleFingerMove(touches[0]);
    } else if (touches.length === 2) {
      this.onTwoFingerMove(touches);
    }
  }

  private onSingleFingerMove(touch: TouchObject): void {
    const state = this.fingers.get(touch.id);
    if (!state) return;

    // 双击待定 → 检测是否达到拖拽阈值
    if (this.isPotentialDoubleClick) {
      if (this.exceedsThreshold(touch, state, DRAG_START_THRESHOLD)) {
        this.cancelDoubleTapHoldTimer();
        this.isPotentialDoubleClick = false;
        this.isDoubleClickDrag = true;
        this.confirmedMove = true;
        this.sink.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_LEFT);
      }
    }

    // 超出轻触范围 → 取消待发送的单击
    if (!this.isWithinTapBounds(touch, state)) {
      this.cancelSingleTapTimer();
    }

    const dx = touch.x - state.lastX;
    const dy = touch.y - state.lastY;

    // 死区判定
    if (!this.confirmedMove && !this.confirmedDrag && !this.isPotentialDoubleClick) {
      this.checkConfirmMove(touch, state, dx, dy);
    }

    // 已确认移动/拖拽 → 发送鼠标移动
    if (this.confirmedMove || this.confirmedDrag || this.isDoubleClickDrag) {
      const s = this.config.sensitivity;
      const sdx = Math.round(dx * s);
      const sdy = Math.round(dy * s);
      if (sdx !== 0) state.lastX = touch.x;
      if (sdy !== 0) state.lastY = touch.y;
      if (sdx !== 0 || sdy !== 0) {
        this.sink.sendMouseMove(sdx, sdy);
      }
    } else {
      state.lastX = touch.x;
      state.lastY = touch.y;
    }
  }

  private onTwoFingerMove(touches: TouchObject[]): void {
    if (!this.twoFingerMoved) {
      const dx = touches[0].x - this.twoFingerStartX;
      const dy = touches[0].y - this.twoFingerStartY;
      if (Math.sqrt(dx * dx + dy * dy) > TWO_FINGER_MOVE_THRESHOLD) {
        this.twoFingerMoved = true;
        this.confirmedScroll = true;
      }
    }

    if (this.confirmedScroll) {
      const state = this.fingers.get(touches[0].id);
      if (state) {
        const dy = touches[0].y - state.lastY;
        state.lastX = touches[0].x;
        state.lastY = touches[0].y;
        if (Math.abs(dy) > 0) {
          this.sink.sendMouseHighResScroll(Math.round(dy * SCROLL_SPEED_FACTOR));
        }
      }
      // 同步第二根手指
      const s2 = this.fingers.get(touches[1].id);
      if (s2) {
        s2.lastX = touches[1].x;
        s2.lastY = touches[1].y;
      }
    }
  }

  // ==================== Up ====================

  private onUp(touches: TouchObject[], changed: TouchObject[]): void {
    const now = Date.now();
    const remaining = Math.max(0, this.activeCount - changed.length);

    // 双击待定态抬起 → 发送双击
    if (this.isPotentialDoubleClick && remaining === 0) {
      this.cancelDoubleTapHoldTimer();
      this.isPotentialDoubleClick = false;
      this.sendDoubleClick();
      this.lastTapUpTime = 0;
      this.finishGesture(changed);
      return;
    }

    // 双击拖拽结束 → 释放左键
    if (this.isDoubleClickDrag && remaining === 0) {
      this.sink.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
      this.isDoubleClickDrag = false;
      this.lastTapUpTime = 0;
      this.finishGesture(changed);
      return;
    }

    // 双指右键 - 情况A：从 2→1
    if (this.activeCount === 2 && remaining === 1 && !this.twoFingerMoved) {
      const elapsed = now - this.twoFingerDownTime;
      if (elapsed < this.config.tapTimeThreshold) {
        this.sendRightClick();
        this.twoFingerTapPending = false;
        this.twoFingerMoved = true;
        this.removeFingers(changed);
        this.activeCount = remaining;
        return;
      } else {
        this.firstFingerUpTime = now;
        this.twoFingerTapPending = true;
      }
    }

    // 所有手指抬起
    if (remaining === 0) {
      this.cancelDragTimer();

      // 双指右键 - 情况B：从 1→0
      if (this.twoFingerTapPending && !this.twoFingerMoved) {
        if (now - this.firstFingerUpTime < this.config.tapTimeThreshold) {
          this.sendRightClick();
          this.twoFingerTapPending = false;
          this.finishGesture(changed);
          return;
        }
      }
      this.twoFingerTapPending = false;

      // 长按拖拽结束
      if (this.confirmedDrag) {
        this.sink.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        this.lastTapUpTime = 0;
      }
      // 单指轻触
      else if (this.maxCountInGesture === 1) {
        for (const t of changed) {
          const s = this.fingers.get(t.id);
          if (s) this.checkForTap(t, s, now);
        }
      }

      this.maxCountInGesture = 0;
      this.confirmedMove = false;
      this.confirmedDrag = false;
      this.confirmedScroll = false;
      this.distanceMoved = 0;
    }

    this.removeFingers(changed);
    this.activeCount = remaining;
  }

  // ==================== 辅助方法 ====================

  private resetGestureFlags(): void {
    this.confirmedMove = false;
    this.confirmedDrag = false;
    this.confirmedScroll = false;
    this.distanceMoved = 0;
    this.isDoubleClickDrag = false;
    this.isPotentialDoubleClick = false;
  }

  private isWithinTapBounds(touch: TouchObject, state: FingerState): boolean {
    return Math.abs(touch.x - state.startX) <= TAP_MOVEMENT_THRESHOLD &&
      Math.abs(touch.y - state.startY) <= TAP_MOVEMENT_THRESHOLD;
  }

  private exceedsThreshold(touch: TouchObject, state: FingerState, threshold: number): boolean {
    return Math.abs(touch.x - state.startX) > threshold ||
      Math.abs(touch.y - state.startY) > threshold;
  }

  private checkConfirmMove(touch: TouchObject, state: FingerState, dx: number, dy: number): void {
    if (!this.isWithinTapBounds(touch, state)) {
      this.confirmedMove = true;
      this.cancelDragTimer();
      return;
    }
    this.distanceMoved += Math.sqrt(dx * dx + dy * dy);
    if (this.distanceMoved >= TAP_DISTANCE_THRESHOLD) {
      this.confirmedMove = true;
      this.cancelDragTimer();
    }
  }

  private detectDoubleTapStart(touch: TouchObject, now: number): boolean {
    const dt = now - this.lastTapUpTime;
    const dxPos = Math.abs(touch.x - this.lastTapUpX);
    const dyPos = Math.abs(touch.y - this.lastTapUpY);
    if (dt <= this.config.tapTimeThreshold &&
      dxPos <= DOUBLE_TAP_MOVEMENT_THRESHOLD &&
      dyPos <= DOUBLE_TAP_MOVEMENT_THRESHOLD) {
      this.cancelSingleTapTimer();
      this.isPotentialDoubleClick = true;
      this.cancelDragTimer();
      this.startDoubleTapHoldTimer();
      return true;
    }
    return false;
  }

  /** 检测是否满足轻触条件并发送点击 */
  private checkForTap(touch: TouchObject, state: FingerState, eventTime: number): void {
    if (this.confirmedDrag || this.confirmedMove || this.confirmedScroll) return;

    const timeDelta = eventTime - state.startTime;
    if (!this.isWithinTapBounds(touch, state) || timeDelta > TAP_TIME_THRESHOLD) {
      this.lastTapUpTime = 0;
      return;
    }

    if (this.config.enableDoubleClickDrag) {
      this.lastTapUpTime = eventTime;
      this.lastTapUpX = touch.x;
      this.lastTapUpY = touch.y;
      this.singleTapTimer = setTimeout(() => {
        this.sendClick(BUTTON_LEFT);
        this.singleTapTimer = -1;
      }, this.config.tapTimeThreshold);
    } else {
      this.lastTapUpTime = 0;
      this.sendClick(BUTTON_LEFT);
    }
  }

  // ---- 输入发送 ----

  private sendClick(button: number): void {
    this.sink.sendMouseButton(BUTTON_ACTION_PRESS, button);
    setTimeout(() => this.sink.sendMouseButton(BUTTON_ACTION_RELEASE, button), 100);
  }

  private sendRightClick(): void {
    this.sink.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
    setTimeout(() => this.sink.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_RIGHT), 50);
  }

  private sendDoubleClick(): void {
    this.sink.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    this.sink.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    this.sink.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    setTimeout(() => this.sink.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT), 100);
  }

  // ---- 手指管理 ----

  private removeFingers(changed: TouchObject[]): void {
    for (const t of changed) this.fingers.delete(t.id);
  }

  private finishGesture(changed: TouchObject[]): void {
    this.removeFingers(changed);
    this.activeCount = 0;
    this.maxCountInGesture = 0;
  }

  // ---- 定时器管理 ----

  private startDragTimer(): void {
    this.cancelDragTimer();
    this.dragTimer = setTimeout(() => {
      if (this.confirmedMove || this.maxCountInGesture !== 1) return;
      this.confirmedDrag = true;
      this.sink.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    }, DRAG_TIME_THRESHOLD);
  }

  private cancelDragTimer(): void {
    if (this.dragTimer !== -1) {
      clearTimeout(this.dragTimer);
      this.dragTimer = -1;
    }
  }

  private startDoubleTapHoldTimer(): void {
    this.cancelDoubleTapHoldTimer();
    this.doubleTapHoldTimer = setTimeout(() => {
      if (!this.isPotentialDoubleClick) return;
      this.isPotentialDoubleClick = false;
      this.isDoubleClickDrag = true;
      this.confirmedMove = true;
      this.sink.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    }, DOUBLE_TAP_HOLD_THRESHOLD);
  }

  private cancelDoubleTapHoldTimer(): void {
    if (this.doubleTapHoldTimer !== -1) {
      clearTimeout(this.doubleTapHoldTimer);
      this.doubleTapHoldTimer = -1;
    }
  }

  private cancelSingleTapTimer(): void {
    if (this.singleTapTimer !== -1) {
      clearTimeout(this.singleTapTimer);
      this.singleTapTimer = -1;
    }
  }
}
