/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import {
  TOUCH_EVENT_CANCEL_ALL,
  TOUCH_EVENT_DOWN,
  TOUCH_EVENT_MOVE,
  TOUCH_EVENT_UP,
  LI_ERR_UNSUPPORTED,
} from '../streaming/MoonBridge';

/** DS5 touchpad output owned by the active streaming session. */
export interface Ds5TouchpadInputSink {
  sendDs5TouchpadEvent(eventType: number, pointerId: number,
    x: number, y: number, pressure: number): number;
  setDs5TouchpadButtonPressed(pressed: boolean): void;
}

export const DS5_TOUCH_FEEDBACK_DOWN = 1;
export const DS5_TOUCH_FEEDBACK_MOVE = 2;
export const DS5_TOUCH_FEEDBACK_UP = 3;
export const DS5_TOUCH_FEEDBACK_CANCEL = 4;
export const DS5_TOUCH_FEEDBACK_CLICK_DOWN = 5;
export const DS5_TOUCH_FEEDBACK_CLICK_UP = 6;

/** Local-only feedback for showing the touch contact without changing input. */
export interface Ds5TouchpadFeedback {
  type: number;
  pointerId: number;
  x: number;
  y: number;
}

interface Ds5TouchState {
  startX: number;
  startY: number;
  lastX: number;
  lastY: number;
  startTime: number;
  tapEligible: boolean;
}

const MAX_TOUCHES = 2;
const TAP_TIME_THRESHOLD_MS = 250;
const TAP_MOVEMENT_THRESHOLD = 24;
const CLICK_RELEASE_DELAY_MS = 50;

/**
 * Maps the screen surface to a DualSense touchpad.
 *
 * Touch contacts and the clickpad button are separate protocol states. A
 * short single-finger tap presses the clickpad while the contact is still
 * active, then releases both states in order.
 */
export class Ds5TouchpadGestureHandler {
  private sink: Ds5TouchpadInputSink | null = null;
  private touches: Map<number, Ds5TouchState> = new Map();
  private clickReleaseTimer: number = -1;
  private clickPressed: boolean = false;
  private clickPointerId: number = -1;
  private clickX: number = 0;
  private clickY: number = 0;
  private tapToClickEnabled: boolean = true;
  private unsupportedReported: boolean = false;
  private onUnsupported: (() => void) | null = null;
  private onFeedback: ((feedback: Ds5TouchpadFeedback) => void) | null = null;

  setSink(sink: Ds5TouchpadInputSink | null): void {
    if (this.sink === sink) return;
    this.cancelActiveInput();
    this.sink = sink;
    this.unsupportedReported = false;
  }

  setUnsupportedCallback(callback: (() => void) | null): void {
    this.onUnsupported = callback;
  }

  setFeedbackCallback(callback: ((feedback: Ds5TouchpadFeedback) => void) | null): void {
    this.onFeedback = callback;
  }

  /** 将单指短触映射为 DualSense 触控板机械按键。 */
  setTapToClickEnabled(enabled: boolean): void {
    this.tapToClickEnabled = enabled;
    if (!enabled) this.releaseClickButton();
  }

  handleEvent(event: TouchEvent): void {
    if (!this.sink) return;

    switch (event.type) {
      case TouchType.Down:
        this.handleDown(event);
        break;
      case TouchType.Move:
        this.handleMove(event);
        break;
      case TouchType.Up:
        this.handleUp(event);
        break;
      case TouchType.Cancel:
        this.cancelActiveInput();
        break;
    }
  }

  cancelActiveInput(): void {
    const sink = this.sink;
    if (sink && this.touches.size > 0) {
      this.sendTouch(TOUCH_EVENT_CANCEL_ALL, 0, 0, 0, 0);
    }
    this.touches.clear();
    this.releaseClickButton();
  }

  dispose(): void {
    this.cancelActiveInput();
    this.sink = null;
    this.onUnsupported = null;
    this.onFeedback = null;
    this.unsupportedReported = false;
  }

  private handleDown(event: TouchEvent): void {
    const areaWidth = Number(event.target.area.width);
    const areaHeight = Number(event.target.area.height);
    if (areaWidth <= 0 || areaHeight <= 0) return;

    const changedTouches = event.changedTouches;
    for (let i = 0; i < changedTouches.length; i++) {
      const touch = changedTouches[i];
      if (this.touches.has(touch.id) || this.touches.size >= MAX_TOUCHES) {
        this.markMultiTouchGesture();
        continue;
      }

      const isOnlyTouch = this.touches.size === 0 && event.touches.length <= 1;
      if (!isOnlyTouch) this.markMultiTouchGesture();

      const x = this.normalize(touch.x, areaWidth);
      const y = this.normalize(touch.y, areaHeight);
      const pressure = this.getPressure(touch, true);
      const ret = this.sendTouch(TOUCH_EVENT_DOWN, touch.id, x, y, pressure);
      if (ret < 0) continue;

      const state: Ds5TouchState = {
        startX: touch.x,
        startY: touch.y,
        lastX: touch.x,
        lastY: touch.y,
        startTime: Date.now(),
        tapEligible: isOnlyTouch,
      };
      this.touches.set(touch.id, state);
    }

    if (this.touches.size > 1) this.markMultiTouchGesture();
  }

  private handleMove(event: TouchEvent): void {
    const areaWidth = Number(event.target.area.width);
    const areaHeight = Number(event.target.area.height);
    if (areaWidth <= 0 || areaHeight <= 0) return;

    const activeTouches = event.touches;
    for (let i = 0; i < activeTouches.length; i++) {
      const touch = activeTouches[i];
      const state = this.touches.get(touch.id);
      if (!state) continue;

      if (this.exceedsTapMovement(touch, state)) state.tapEligible = false;
      state.lastX = touch.x;
      state.lastY = touch.y;
      this.sendTouch(
        TOUCH_EVENT_MOVE,
        touch.id,
        this.normalize(touch.x, areaWidth),
        this.normalize(touch.y, areaHeight),
        this.getPressure(touch, true),
      );
    }
  }

  private handleUp(event: TouchEvent): void {
    const areaWidth = Number(event.target.area.width);
    const areaHeight = Number(event.target.area.height);
    if (areaWidth <= 0 || areaHeight <= 0) {
      this.cancelActiveInput();
      return;
    }

    const now = Date.now();
    const changedTouches = event.changedTouches;
    if (changedTouches.length === 0 && event.touches.length === 0 && this.touches.size > 0) {
      this.cancelActiveInput();
      return;
    }
    for (let i = 0; i < changedTouches.length; i++) {
      const touch = changedTouches[i];
      const state = this.touches.get(touch.id);
      if (!state) continue;

      const normalizedX = this.normalize(touch.x, areaWidth);
      const normalizedY = this.normalize(touch.y, areaHeight);
      if (this.tapToClickEnabled && this.isTap(touch, state, now)) {
        this.pressClickButton(touch.id, normalizedX, normalizedY);
      }
      this.sendTouch(
        TOUCH_EVENT_UP,
        touch.id,
        normalizedX,
        normalizedY,
        0,
      );
      this.touches.delete(touch.id);
    }
  }

  private sendTouch(eventType: number, pointerId: number,
    x: number, y: number, pressure: number): number {
    const sink = this.sink;
    if (!sink) return -2;

    const ret = sink.sendDs5TouchpadEvent(eventType, pointerId, x, y, pressure);
    if (ret >= 0 && this.onFeedback) {
      let feedbackType = eventType;
      if (eventType === TOUCH_EVENT_CANCEL_ALL) {
        feedbackType = DS5_TOUCH_FEEDBACK_CANCEL;
      }
      const feedback: Ds5TouchpadFeedback = {
        type: feedbackType,
        pointerId: pointerId,
        x: x,
        y: y
      };
      this.onFeedback(feedback);
    }
    if (ret === LI_ERR_UNSUPPORTED && !this.unsupportedReported) {
      this.unsupportedReported = true;
      const callback = this.onUnsupported;
      if (callback) callback();
    }
    return ret;
  }

  private pressClickButton(pointerId: number, x: number, y: number): void {
    const sink = this.sink;
    if (!sink) return;

    if (this.clickReleaseTimer !== -1) {
      clearTimeout(this.clickReleaseTimer);
      this.clickReleaseTimer = -1;
    }
    if (this.clickPressed) sink.setDs5TouchpadButtonPressed(false);

    sink.setDs5TouchpadButtonPressed(true);
    this.clickPressed = true;
    this.clickPointerId = pointerId;
    this.clickX = x;
    this.clickY = y;
    if (this.onFeedback) {
      const feedback: Ds5TouchpadFeedback = {
        type: DS5_TOUCH_FEEDBACK_CLICK_DOWN,
        pointerId: pointerId,
        x: x,
        y: y
      };
      this.onFeedback(feedback);
    }
    this.clickReleaseTimer = setTimeout(() => {
      this.clickReleaseTimer = -1;
      this.releaseClickButton();
    }, CLICK_RELEASE_DELAY_MS);
  }

  private releaseClickButton(): void {
    if (this.clickReleaseTimer !== -1) {
      clearTimeout(this.clickReleaseTimer);
      this.clickReleaseTimer = -1;
    }
    if (!this.clickPressed) return;

    const sink = this.sink;
    if (sink) sink.setDs5TouchpadButtonPressed(false);
    if (this.onFeedback) {
      const feedback: Ds5TouchpadFeedback = {
        type: DS5_TOUCH_FEEDBACK_CLICK_UP,
        pointerId: this.clickPointerId,
        x: this.clickX,
        y: this.clickY
      };
      this.onFeedback(feedback);
    }
    this.clickPressed = false;
    this.clickPointerId = -1;
  }

  private markMultiTouchGesture(): void {
    this.touches.forEach((state: Ds5TouchState): void => {
      state.tapEligible = false;
    });
  }

  private isTap(touch: TouchObject, state: Ds5TouchState, now: number): boolean {
    return state.tapEligible &&
      now - state.startTime <= TAP_TIME_THRESHOLD_MS &&
      !this.exceedsTapMovement(touch, state);
  }

  private exceedsTapMovement(touch: TouchObject, state: Ds5TouchState): boolean {
    return Math.abs(touch.x - state.startX) > TAP_MOVEMENT_THRESHOLD ||
      Math.abs(touch.y - state.startY) > TAP_MOVEMENT_THRESHOLD;
  }

  private getPressure(touch: TouchObject, active: boolean): number {
    if (!active) return 0;
    const pressure = touch.pressure ?? 1.0;
    return Math.max(0, Math.min(1, pressure));
  }

  private normalize(value: number, extent: number): number {
    return Math.max(0, Math.min(1, value / extent));
  }
}
