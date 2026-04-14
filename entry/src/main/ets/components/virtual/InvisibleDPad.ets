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
 * 隐藏式虚拟数字摇杆组件（Invisible D-Pad Stick）
 *
 * 参照 Android InvisibleDigitalStick.java 的设计：
 * - 不触摸时完全透明（仅编辑模式显示虚线边框）
 * - 手指触摸时，触摸点成为摇杆圆心，摇杆在该位置出现
 * - 手指滑动产生上/下/左/右数字方向输入（而非模拟量）
 * - 手指抬起后摇杆消失，所有方向释放
 *
 * 输出方向位掩码（与 VirtualDPad/GamepadButton 一致）
 */

import { DPAD_LEFT, DPAD_UP, DPAD_RIGHT, DPAD_DOWN } from './VirtualDPad';

/** 方向变化回调，参数为方向位掩码组合（0 = 无方向） */
export type InvisibleDPadDirectionCallback = (direction: number) => void;

/** 双击回调 */
export type InvisibleDPadClickCallback = () => void;

/** 释放回调 */
export type InvisibleDPadRevokeCallback = () => void;

/** 是否处于编辑模式 */
export type InvisibleDPadEditModeGetter = () => boolean;

@Component
export struct InvisibleDPad {
  /** 触摸区域宽度 (vp) */
  @Prop areaWidth: number = 200;
  /** 触摸区域高度 (vp) */
  @Prop areaHeight: number = 200;
  /** 摇杆可视半径 (vp) */
  @Prop stickRadius: number = 60;
  /** 方向判定阈值比例 (0-1)，超过此比例判定为该方向 */
  @Prop directionThreshold: number = 0.30;
  /** 外圆颜色 */
  @Prop ringColor: string = '#6050C080';
  /** 内摇杆颜色 */
  @Prop stickColor: string = '#A050C080';
  /** 按下时颜色 */
  @Prop pressedColor: string = '#C070E090';
  /** 编辑模式下边框颜色 */
  @Prop editBorderColor: string = '#80FFFFFF';
  /** 透明度 0-100 */
  @Prop opacity_: number = 80;

  // 回调
  onDirectionChange: InvisibleDPadDirectionCallback = (_dir: number): void => {};
  onStickClick: InvisibleDPadClickCallback = (): void => {};
  onDoubleClick: InvisibleDPadClickCallback = (): void => {};
  onRevoke: InvisibleDPadRevokeCallback = (): void => {};
  isEditMode: InvisibleDPadEditModeGetter = (): boolean => false;

  // === 内部状态 ===
  @State private isPressed: boolean = false;
  @State private centerX: number = 0;
  @State private centerY: number = 0;
  @State private stickOffsetX: number = 0;
  @State private stickOffsetY: number = 0;
  /** 当前方向位掩码 */
  @State private currentDir: number = 0;

  // 预计算尺寸
  private innerRadius: number = 15;
  private maxTravel: number = 45;

  // 死区
  private deadzone: number = 0.15;
  private static readonly DEADZONE_TIMEOUT_MS: number = 150;
  private touchDownTime: number = 0;
  private deadzoneActive: boolean = true;

  // 触摸追踪
  private trackingTouchId: number = -1;

  // 双击检测
  private lastTapTime: number = 0;
  private static readonly DOUBLE_TAP_MS: number = 300;

  aboutToAppear(): void {
    this.innerRadius = this.stickRadius * 0.25;
    this.maxTravel = this.stickRadius - this.innerRadius;
  }

  build() {
    Stack() {
      // 透明触摸区域
      Rect()
        .width('100%')
        .height('100%')
        .fill('#01000000')

      // 编辑模式下显示虚线边框
      if (this.isEditMode()) {
        Rect()
          .width('100%')
          .height('100%')
          .fill('transparent')
          .stroke(this.editBorderColor)
          .strokeWidth(1.5)
          .strokeDashArray([6, 4])
          .borderRadius(4)

        // 编辑模式下在中心画预览摇杆轮廓
        Circle()
          .width(this.stickRadius * 2)
          .height(this.stickRadius * 2)
          .fill('transparent')
          .stroke(this.ringColor)
          .strokeWidth(1)
          .strokeOpacity(0.3)
          .position({
            x: this.areaWidth / 2 - this.stickRadius,
            y: this.areaHeight / 2 - this.stickRadius
          })
      }

      // 按下时在触摸点显示摇杆
      if (this.isPressed) {
        // 外圆环
        Circle()
          .width(this.stickRadius * 2)
          .height(this.stickRadius * 2)
          .fill('transparent')
          .stroke(this.ringColor)
          .strokeWidth(1.5)
          .position({
            x: this.centerX - this.stickRadius,
            y: this.centerY - this.stickRadius
          })

        // 方向指示线（十字）
        // 上
        Rect()
          .width(1)
          .height(this.stickRadius * 0.3)
          .fill((this.currentDir & DPAD_UP) > 0 ? this.pressedColor : this.ringColor)
          .fillOpacity(0.5)
          .position({
            x: this.centerX - 0.5,
            y: this.centerY - this.stickRadius * 0.8
          })
        // 下
        Rect()
          .width(1)
          .height(this.stickRadius * 0.3)
          .fill((this.currentDir & DPAD_DOWN) > 0 ? this.pressedColor : this.ringColor)
          .fillOpacity(0.5)
          .position({
            x: this.centerX - 0.5,
            y: this.centerY + this.stickRadius * 0.5
          })
        // 左
        Rect()
          .width(this.stickRadius * 0.3)
          .height(1)
          .fill((this.currentDir & DPAD_LEFT) > 0 ? this.pressedColor : this.ringColor)
          .fillOpacity(0.5)
          .position({
            x: this.centerX - this.stickRadius * 0.8,
            y: this.centerY - 0.5
          })
        // 右
        Rect()
          .width(this.stickRadius * 0.3)
          .height(1)
          .fill((this.currentDir & DPAD_RIGHT) > 0 ? this.pressedColor : this.ringColor)
          .fillOpacity(0.5)
          .position({
            x: this.centerX + this.stickRadius * 0.5,
            y: this.centerY - 0.5
          })

        // 内摇杆头
        Circle()
          .width(this.innerRadius * 2)
          .height(this.innerRadius * 2)
          .fill(this.pressedColor)
          .stroke(this.pressedColor)
          .strokeWidth(1.5)
          .position({
            x: this.centerX - this.innerRadius + this.stickOffsetX,
            y: this.centerY - this.innerRadius + this.stickOffsetY
          })
      }
    }
    .width(this.areaWidth)
    .height(this.areaHeight)
    .clip(true)
    .opacity(this.opacity_ / 100)
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent): void => {
      if (this.isEditMode()) return;
      this.handleTouch(event);
    })
  }

  private handleTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      const changed: TouchObject[] = event.changedTouches;
      if (changed.length === 0) return;
      const touch: TouchObject = changed[0];

      if (this.trackingTouchId >= 0) return;

      this.trackingTouchId = touch.id;
      this.isPressed = true;

      // 触摸点成为摇杆圆心
      this.centerX = touch.x;
      this.centerY = touch.y;
      this.stickOffsetX = 0;
      this.stickOffsetY = 0;
      this.currentDir = 0;

      this.touchDownTime = Date.now();
      this.deadzoneActive = true;

      this.checkDoubleTap();
      return;
    }

    if (event.type === TouchType.Move) {
      if (this.trackingTouchId < 0) return;
      const touch: TouchObject | null = this.findTrackedTouch(event.touches);
      if (touch !== null) {
        this.updateStickPosition(touch.x - this.centerX, touch.y - this.centerY);
      }
      return;
    }

    // Up / Cancel
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const changed: TouchObject[] = event.changedTouches;
      let isOurFinger: boolean = false;
      for (let i = 0; i < changed.length; i++) {
        if (changed[i].id === this.trackingTouchId) {
          isOurFinger = true;
          break;
        }
      }
      if (isOurFinger) {
        this.trackingTouchId = -1;
        this.isPressed = false;
        this.stickOffsetX = 0;
        this.stickOffsetY = 0;
        this.currentDir = 0;
        this.onDirectionChange(0);
        this.onRevoke();
      }
    }
  }

  private findTrackedTouch(touches: TouchObject[]): TouchObject | null {
    for (let i = 0; i < touches.length; i++) {
      if (touches[i].id === this.trackingTouchId) {
        return touches[i];
      }
    }
    return null;
  }

  /**
   * 更新摇杆位置并发送方向事件
   * 参照 Android InvisibleDigitalStick: 将归一化坐标转化为上/下/左/右按键
   */
  private updateStickPosition(dx: number, dy: number): void {
    let distance: number = Math.sqrt(dx * dx + dy * dy);
    const angle: number = Math.atan2(dy, dx);

    if (distance > this.maxTravel) {
      distance = this.maxTravel;
    }

    // 视觉偏移
    this.stickOffsetX = distance * Math.cos(angle);
    this.stickOffsetY = distance * Math.sin(angle);

    // 归一化坐标
    const normalizedX: number = this.stickOffsetX / this.maxTravel;
    const normalizedY: number = this.stickOffsetY / this.maxTravel;
    const magnitude: number = Math.sqrt(normalizedX * normalizedX + normalizedY * normalizedY);

    // 死区超时检查
    if (this.deadzoneActive && Date.now() - this.touchDownTime > InvisibleDPad.DEADZONE_TIMEOUT_MS) {
      this.deadzoneActive = false;
    }
    if (magnitude > this.deadzone) {
      this.deadzoneActive = false;
    }

    // 计算方向位掩码
    let newDir: number = 0;
    if (!this.deadzoneActive || magnitude >= this.deadzone) {
      if (normalizedX < -this.directionThreshold) {
        newDir |= DPAD_LEFT;
      }
      if (normalizedX > this.directionThreshold) {
        newDir |= DPAD_RIGHT;
      }
      if (normalizedY < -this.directionThreshold) {
        newDir |= DPAD_UP;
      }
      if (normalizedY > this.directionThreshold) {
        newDir |= DPAD_DOWN;
      }
    }

    if (newDir !== this.currentDir) {
      this.currentDir = newDir;
      this.onDirectionChange(newDir);
    }
  }

  private checkDoubleTap(): void {
    const now: number = Date.now();
    if (now - this.lastTapTime < InvisibleDPad.DOUBLE_TAP_MS) {
      this.onDoubleClick();
      this.lastTapTime = 0;
    } else {
      this.onStickClick();
      this.lastTapTime = now;
    }
  }
}
