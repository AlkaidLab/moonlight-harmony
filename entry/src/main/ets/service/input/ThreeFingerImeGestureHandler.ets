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
 * 三指触摸唤出系统 IME 的本地手势状态机。
 *
 * 该手势优先于远端触摸输入和双指缩放。触发后持续消费本组触摸，
 * 直到所有手指抬起，避免远端收到半截多指触摸或鼠标拖拽。
 */

export enum ThreeFingerImeGestureResult {
  PASS_THROUGH,
  CONSUMED,
  TRIGGERED
}

export class ThreeFingerImeGestureHandler {
  private static readonly RESET_WATCHDOG_MS: number = 3000;

  private gestureActive: boolean = false;
  private lastActiveCount: number = 0;
  private resetTimer: number | null = null;

  handleTouchEvent(event: TouchEvent, canTrigger: boolean): ThreeFingerImeGestureResult {
    if (event.source === SourceType.Mouse) {
      return ThreeFingerImeGestureResult.PASS_THROUGH;
    }

    const activeFingerCount = this.getActiveFingerCount(event);
    this.lastActiveCount = activeFingerCount;

    if (this.gestureActive) {
      if (activeFingerCount === 0) {
        this.reset();
      }
      return ThreeFingerImeGestureResult.CONSUMED;
    }

    if (!canTrigger || activeFingerCount < 3) {
      return ThreeFingerImeGestureResult.PASS_THROUGH;
    }

    this.gestureActive = true;
    this.scheduleResetWatchdog();
    return ThreeFingerImeGestureResult.TRIGGERED;
  }

  dispose(): void {
    this.reset();
  }

  private scheduleResetWatchdog(): void {
    if (this.resetTimer !== null) {
      clearTimeout(this.resetTimer);
    }

    this.resetTimer = setTimeout(() => {
      this.resetTimer = null;
      if (!this.gestureActive) {
        return;
      }
      if (this.lastActiveCount === 0) {
        this.reset();
        return;
      }
      this.scheduleResetWatchdog();
    }, ThreeFingerImeGestureHandler.RESET_WATCHDOG_MS);
  }

  private reset(): void {
    this.gestureActive = false;
    this.lastActiveCount = 0;
    if (this.resetTimer !== null) {
      clearTimeout(this.resetTimer);
      this.resetTimer = null;
    }
  }

  private getActiveFingerCount(event: TouchEvent): number {
    if (event.type !== TouchType.Up && event.type !== TouchType.Cancel) {
      return event.touches.length;
    }

    let count = 0;
    for (let i = 0; i < event.touches.length; i++) {
      let isChanged: boolean = false;
      for (let j = 0; j < event.changedTouches.length; j++) {
        if (event.touches[i].id === event.changedTouches[j].id) {
          isChanged = true;
          break;
        }
      }
      if (!isChanged) {
        count++;
      }
    }
    return count;
  }
}
