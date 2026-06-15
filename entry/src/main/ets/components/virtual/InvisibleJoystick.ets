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
 * 隐藏式虚拟摇杆组件（Invisible Joystick）
 *
 * 参照 Android InvisibleAnalogStick.java 的设计：
 * - 不触摸时完全透明（仅编辑模式显示虚线边框）
 * - 手指触摸时，触摸点成为摇杆圆心，摇杆在该位置出现
 * - 手指滑动产生相对于触摸点的模拟输入
 * - 手指抬起后摇杆消失，输入归零
 *
 * 提供 JoystickMovementCallback 输出归一化 x/y (-1.0 ~ 1.0)
 */

/**
 * 摇杆移动回调
 * @param x 水平轴 -1.0(左) ~ 0 ~ 1.0(右)
 * @param y 垂直轴 -1.0(上) ~ 0 ~ 1.0(下)（屏幕坐标系）
 */
export type InvisibleJoystickMovementCallback = (x: number, y: number) => void;

/** 摇杆双击回调（L3/R3 短按触发） */
export type InvisibleJoystickClickCallback = () => void;

/** 摇杆释放回调（手指抬起，摇杆归零） */
export type InvisibleJoystickRevokeCallback = () => void;

/** 是否处于编辑模式（编辑模式下禁用摇杆输入，但显示边框） */
export type InvisibleEditModeGetter = () => boolean;

@Component
export struct InvisibleJoystick {
  /** 触摸区域宽度 (vp) */
  @Prop areaWidth: number = 200;
  /** 触摸区域高度 (vp) */
  @Prop areaHeight: number = 200;
  /** 摇杆可视半径 (vp)，触摸后出现的圆的半径 */
  @Prop stickRadius: number = 60;
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
  onMovement: InvisibleJoystickMovementCallback = (_x: number, _y: number): void => {};
  onStickClick: InvisibleJoystickClickCallback = (): void => {};
  onDoubleClick: InvisibleJoystickClickCallback = (): void => {};
  onRevoke: InvisibleJoystickRevokeCallback = (): void => {};
  isEditMode: InvisibleEditModeGetter = (): boolean => false;

  // === 内部状态 ===
  /** 是否有手指按下 */
  @State private isPressed: boolean = false;
  /** 摇杆圆心 X（相对于触摸区域，动态等于 ACTION_DOWN 坐标） */
  @State private centerX: number = 0;
  /** 摇杆圆心 Y */
  @State private centerY: number = 0;
  /** 内摇杆头视觉偏移 X（相对于圆心，px 单位，用于 translate） */
  @State private stickOffsetX: number = 0;
  /** 内摇杆头视觉偏移 Y */
  @State private stickOffsetY: number = 0;

  // 预计算的尺寸值
  private innerRadius: number = 15;
  private maxTravel: number = 45;

  // 死区比例
  private deadzone: number = 0.15;

  // 死区超时（150ms 后自动解除死区，允许精细操作）
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
      // 透明触摸区域（始终存在用于命中测试）
      Rect()
        .width('100%')
        .height('100%')
        .fill('#01000000')

      // 编辑模式下显示虚线边框提示触摸区域
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
        Ellipse()
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
        Ellipse()
          .width(this.stickRadius * 2)
          .height(this.stickRadius * 2)
          .fill('transparent')
          .stroke(this.ringColor)
          .strokeWidth(1.5)
          .position({
            x: this.centerX - this.stickRadius,
            y: this.centerY - this.stickRadius
          })

        // 死区圆
        Ellipse()
          .width(this.stickRadius * 2 * this.deadzone)
          .height(this.stickRadius * 2 * this.deadzone)
          .fill('transparent')
          .stroke(this.ringColor)
          .strokeWidth(0.5)
          .strokeOpacity(0.3)
          .position({
            x: this.centerX - this.stickRadius * this.deadzone,
            y: this.centerY - this.stickRadius * this.deadzone
          })

        // 内摇杆头
        Ellipse()
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

      // 只追踪一个手指
      if (this.trackingTouchId >= 0) return;

      this.trackingTouchId = touch.id;
      this.isPressed = true;

      // ★ 核心：触摸点成为摇杆圆心
      this.centerX = touch.x;
      this.centerY = touch.y;
      this.stickOffsetX = 0;
      this.stickOffsetY = 0;

      // 记录按下时间用于死区超时
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
        this.onMovement(0, 0);
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
   * 更新摇杆位置并发送移动事件
   * 参照 Android InvisibleAnalogStick.updatePosition + 死区超时机制
   */
  private updateStickPosition(dx: number, dy: number): void {
    // 极坐标
    let distance: number = Math.sqrt(dx * dx + dy * dy);
    const angle: number = Math.atan2(dy, dx);

    // 限制在可移动范围内
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

    // 死区超时检查（150ms 后自动解除死区，与 Android 一致）
    if (this.deadzoneActive && Date.now() - this.touchDownTime > InvisibleJoystick.DEADZONE_TIMEOUT_MS) {
      this.deadzoneActive = false;
    }
    // 一旦超出死区范围也永久解除
    if (magnitude > this.deadzone) {
      this.deadzoneActive = false;
    }

    let outX: number = 0;
    let outY: number = 0;

    if (this.deadzoneActive && magnitude < this.deadzone) {
      // 在死区内且未超时，不发送移动
      outX = 0;
      outY = 0;
    } else {
      // 死区已解除，连续重映射
      if (magnitude > 0) {
        const effectiveDeadzone: number = this.deadzoneActive ? this.deadzone : 0;
        if (magnitude > effectiveDeadzone) {
          const remapScale: number = effectiveDeadzone > 0
            ? (magnitude - effectiveDeadzone) / (1 - effectiveDeadzone)
            : magnitude;
          const factor: number = remapScale / magnitude;
          outX = normalizedX * factor;
          outY = normalizedY * factor;
        }
      }
    }

    this.onMovement(outX, outY);
  }

  /**
   * 双击检测（与 VirtualJoystick 一致的 300ms 阈值）
   */
  private checkDoubleTap(): void {
    const now: number = Date.now();
    if (now - this.lastTapTime < InvisibleJoystick.DOUBLE_TAP_MS) {
      this.onDoubleClick();
      this.lastTapTime = 0;
    } else {
      this.onStickClick();
      this.lastTapTime = now;
    }
  }
}
