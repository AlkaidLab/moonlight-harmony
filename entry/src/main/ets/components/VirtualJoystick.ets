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
 * 自定义按键用虚拟摇杆组件
 *
 * 参照 AnalogStick.ets（虚拟控制器摇杆）的设计和实现方式，提供完整的 2D 模拟输入。
 * 关键行为与 AnalogStick.ets 保持一致：
 * - 立即响应触摸，通过死区连续重映射（而非二态激活）
 * - 双击触发 L3/R3 短按+自动释放
 * - 手指追踪（trackingTouchId）避免多指冲突
 * - 输出归一化 x/y (-1.0 ~ 1.0)
 */

/**
 * 摇杆移动回调
 * @param x 水平轴 -1.0(左) ~ 0 ~ 1.0(右)
 * @param y 垂直轴 -1.0(上) ~ 0 ~ 1.0(下)（屏幕坐标系）
 */
export type JoystickMovementCallback = (x: number, y: number) => void;

/** 摇杆双击回调（L3/R3 短按触发） */
export type JoystickClickCallback = () => void;

/** 摇杆释放回调（手指抬起，摇杆归零） */
export type JoystickRevokeCallback = () => void;

/** 是否处于编辑模式（编辑模式下禁用摇杆输入） */
export type EditModeGetter = () => boolean;

@Component
export struct VirtualJoystick {
  /** 摇杆尺寸 (vp)，外圆直径（避免与 CustomComponent.size 冲突） */
  @Prop joystickSize: number = 120;
  /** 外圆颜色 */
  @Prop ringColor: string = '#6050C080';
  /** 内摇杆颜色 */
  @Prop stickColor: string = '#A050C080';
  /** 按下时颜色 */
  @Prop pressedColor: string = '#C070E090';
  /** 透明度 0-100 */
  @Prop opacity_: number = 80;

  // 回调
  onMovement: JoystickMovementCallback = (_x: number, _y: number): void => {};
  onStickClick: JoystickClickCallback = (): void => {};
  onDoubleClick: JoystickClickCallback = (): void => {};
  onRevoke: JoystickRevokeCallback = (): void => {};
  isEditMode: EditModeGetter = (): boolean => false;

  // === 内部状态 ===
  @State private stickX: number = 0;   // 视觉归一化偏移 -1~1
  @State private stickY: number = 0;
  @State private isPressed: boolean = false;

  // 预计算的尺寸值（在 aboutToAppear 中初始化，避免 private get 在 struct 中不可靠）
  private stickOuterRadius: number = 60;
  private stickInnerRadius: number = 15;
  private stickMaxTravel: number = 45;

  // 死区比例（归一化空间）
  private deadzone: number = 0.15;

  // 触摸追踪（与 AnalogStick.ets 一致）
  private trackingTouchId: number = -1;

  // 双击检测
  private lastTapTime: number = 0;
  private static readonly DOUBLE_TAP_MS: number = 300;

  aboutToAppear(): void {
    this.stickOuterRadius = this.joystickSize / 2;
    this.stickInnerRadius = this.stickOuterRadius * 0.25;
    this.stickMaxTravel = this.stickOuterRadius - this.stickInnerRadius;
  }

  build() {
    Stack() {
      // 外圆环
      Circle()
        .width(this.stickOuterRadius * 2)
        .height(this.stickOuterRadius * 2)
        .fill('#01000000')
        .stroke(this.isPressed ? this.pressedColor : this.ringColor)
        .strokeWidth(1.5)

      // 内摇杆头
      Circle()
        .width(this.stickInnerRadius * 2)
        .height(this.stickInnerRadius * 2)
        .fill(this.isPressed ? this.pressedColor : this.stickColor)
        .stroke(this.isPressed ? this.pressedColor : this.ringColor)
        .strokeWidth(1)
        .translate({
          x: this.stickX * this.stickMaxTravel,
          y: this.stickY * this.stickMaxTravel
        })
    }
    .width(this.stickOuterRadius * 2)
    .height(this.stickOuterRadius * 2)
    .alignContent(Alignment.Center)
    .opacity(this.opacity_ / 100)
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent): void => {
      if (this.isEditMode()) return;
      this.handleTouch(event);
    })
  }

  private handleTouch(event: TouchEvent): void {
    const centerX: number = this.stickOuterRadius;
    const centerY: number = this.stickOuterRadius;

    if (event.type === TouchType.Down) {
      // 使用 changedTouches 获取按下的手指（与 AnalogStick 一致）
      const changed: TouchObject[] = event.changedTouches;
      if (changed.length === 0) return;
      const touch: TouchObject = changed[0];

      // 如果已有追踪手指，则忽略—只追踪一个
      if (this.trackingTouchId >= 0) return;

      this.trackingTouchId = touch.id;
      this.isPressed = true;
      this.updateStickPosition(touch.x - centerX, touch.y - centerY);
      this.checkDoubleTap();
      return;
    }

    if (event.type === TouchType.Move) {
      if (this.trackingTouchId < 0) return;
      const touch: TouchObject | null = this.findTrackedTouch(event.touches);
      if (touch !== null) {
        this.updateStickPosition(touch.x - centerX, touch.y - centerY);
      }
      return;
    }

    // Up / Cancel
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      // 检查释放的是否为我们追踪的手指
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
        this.resetStick();
      }
    }
  }

  /**
   * 在触摸列表中查找我们正在跟踪的手指（与 AnalogStick.ets 一致）
   */
  private findTrackedTouch(touches: TouchObject[]): TouchObject | null {
    for (let i = 0; i < touches.length; i++) {
      if (touches[i].id === this.trackingTouchId) {
        return touches[i];
      }
    }
    return null;
  }

  /**
   * 更新摇杆位置 + 发送移动事件
   * 使用与 AnalogStick.ets 相同的死区重映射算法
   */
  private updateStickPosition(dx: number, dy: number): void {
    const maxDistance: number = this.stickMaxTravel;

    // 极坐标
    let distance: number = Math.sqrt(dx * dx + dy * dy);
    const angle: number = Math.atan2(dy, dx);

    // 限制在可移动范围内
    if (distance > maxDistance) {
      distance = maxDistance;
    }

    // 视觉偏移（归一化到 -1~1，不应用死区，保证滑动视觉流畅）
    const visualNorm: number = distance / maxDistance;
    this.stickX = visualNorm * Math.cos(angle);
    this.stickY = visualNorm * Math.sin(angle);

    // 归一化坐标
    let normalizedX: number = this.stickX;
    let normalizedY: number = this.stickY;

    // 连续死区重映射（与 AnalogStick.ets 一致）
    const magnitude: number = Math.sqrt(normalizedX * normalizedX + normalizedY * normalizedY);
    if (magnitude < this.deadzone) {
      normalizedX = 0;
      normalizedY = 0;
    } else {
      const remapScale: number = (magnitude - this.deadzone) / (1 - this.deadzone);
      const factor: number = remapScale / magnitude;
      normalizedX = normalizedX * factor;
      normalizedY = normalizedY * factor;
    }

    this.onMovement(normalizedX, normalizedY);
  }

  /**
   * 重置摇杆到中心位置 + 通知归零
   */
  private resetStick(): void {
    this.stickX = 0;
    this.stickY = 0;
    this.onMovement(0, 0);
    this.onRevoke();
  }

  /**
   * 双击检测（与 AnalogStick.ets 一致的 300ms 阈值）
   */
  private checkDoubleTap(): void {
    const now: number = Date.now();
    if (now - this.lastTapTime < VirtualJoystick.DOUBLE_TAP_MS) {
      this.onDoubleClick();
      this.lastTapTime = 0;
    } else {
      this.lastTapTime = now;
    }
  }
}
