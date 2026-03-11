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
 * 虚拟十字键盘 (D-Pad) 组件
 *
 * 参照 Android DigitalPad.java 的设计：
 * - 一个控件涵盖上/下/左/右 4 个方向，并支持对角线组合（8-way）
 * - 触摸区域按 3×3 九宫格划分：外围为方向区域，中心为无操作区域
 * - 视觉上绘制十字形 4 个方向矩形 + 4 条对角连接线
 * - 输出方向位掩码（与 GamepadButton.UP/DOWN/LEFT/RIGHT 一致）
 */

/** D-Pad 方向位掩码（与 GamepadButton.UP/DOWN/LEFT/RIGHT 值一致） */
export const DPAD_LEFT: number = 0x0004;
export const DPAD_UP: number = 0x0001;
export const DPAD_RIGHT: number = 0x0008;
export const DPAD_DOWN: number = 0x0002;

/** 方向变化回调，参数为方向位掩码组合（0 = 无方向） */
export type DPadDirectionCallback = (direction: number) => void;

/** 是否处于编辑模式 */
export type DPadEditModeGetter = () => boolean;

@Component
export struct VirtualDPad {
  /** D-Pad 尺寸 (vp)，正方形边长 */
  @Prop dpadSize: number = 120;
  /** 常态颜色 */
  @Prop normalColor: string = '#6050C080';
  /** 按下时颜色 */
  @Prop pressedColor: string = '#C070E090';
  /** 背景色 */
  @Prop bgColor: string = '#3050C080';
  /** 透明度 0-100 */
  @Prop opacity_: number = 80;

  // 回调
  onDirectionChange: DPadDirectionCallback = (_dir: number): void => {};
  isEditMode: DPadEditModeGetter = (): boolean => false;

  // === 内部状态 ===
  /** 当前方向位掩码（避免与 CustomComponent.direction 冲突） */
  @State private currentDir: number = 0;

  // 触摸追踪
  private trackingTouchId: number = -1;

  // 预计算（padSize 避免与 CustomComponent.size 冲突）
  private padSize: number = 120;
  /** 方向区域分界线：<33% =左/上, >66% =右/下 */
  private threshold33: number = 40;
  private threshold66: number = 80;
  /** 方向矩形厚度 (33%) */
  private bandWidth: number = 40;

  aboutToAppear(): void {
    this.padSize = this.dpadSize;
    this.threshold33 = this.padSize * 0.33;
    this.threshold66 = this.padSize * 0.66;
    this.bandWidth = this.padSize * 0.33;
  }

  build() {
    Stack() {
      // 背景填充（用于命中测试，与 VirtualJoystick 同 #01000000 策略）
      Rect()
        .width(this.padSize)
        .height(this.padSize)
        .fill('#01000000')
        .borderRadius(8)

      // 中心方块（无方向指示器）
      if (this.currentDir === 0) {
        Rect()
          .width(this.bandWidth)
          .height(this.bandWidth)
          .fill('transparent')
          .stroke(this.normalColor)
          .strokeWidth(1.5)
          .borderRadius(4)
      }

      // 上方区域
      Rect()
        .width(this.bandWidth)
        .height(this.threshold33)
        .fill('transparent')
        .stroke((this.currentDir & DPAD_UP) > 0 ? this.pressedColor : this.normalColor)
        .strokeWidth(1.5)
        .borderRadius(4)
        .position({ x: this.threshold33, y: 0 })

      // 下方区域
      Rect()
        .width(this.bandWidth)
        .height(this.threshold33)
        .fill('transparent')
        .stroke((this.currentDir & DPAD_DOWN) > 0 ? this.pressedColor : this.normalColor)
        .strokeWidth(1.5)
        .borderRadius(4)
        .position({ x: this.threshold33, y: this.threshold66 })

      // 左方区域
      Rect()
        .width(this.threshold33)
        .height(this.bandWidth)
        .fill('transparent')
        .stroke((this.currentDir & DPAD_LEFT) > 0 ? this.pressedColor : this.normalColor)
        .strokeWidth(1.5)
        .borderRadius(4)
        .position({ x: 0, y: this.threshold33 })

      // 右方区域
      Rect()
        .width(this.threshold33)
        .height(this.bandWidth)
        .fill('transparent')
        .stroke((this.currentDir & DPAD_RIGHT) > 0 ? this.pressedColor : this.normalColor)
        .strokeWidth(1.5)
        .borderRadius(4)
        .position({ x: this.threshold66, y: this.threshold33 })

      // 方向箭头符号
      Text('▲')
        .fontSize(this.padSize * 0.12)
        .fontColor((this.currentDir & DPAD_UP) > 0 ? this.pressedColor : this.normalColor)
        .position({ x: this.padSize / 2 - this.padSize * 0.06, y: this.threshold33 * 0.25 })
      Text('▼')
        .fontSize(this.padSize * 0.12)
        .fontColor((this.currentDir & DPAD_DOWN) > 0 ? this.pressedColor : this.normalColor)
        .position({ x: this.padSize / 2 - this.padSize * 0.06, y: this.threshold66 + this.threshold33 * 0.25 })
      Text('◀')
        .fontSize(this.padSize * 0.12)
        .fontColor((this.currentDir & DPAD_LEFT) > 0 ? this.pressedColor : this.normalColor)
        .position({ x: this.threshold33 * 0.2, y: this.padSize / 2 - this.padSize * 0.07 })
      Text('▶')
        .fontSize(this.padSize * 0.12)
        .fontColor((this.currentDir & DPAD_RIGHT) > 0 ? this.pressedColor : this.normalColor)
        .position({ x: this.threshold66 + this.threshold33 * 0.2, y: this.padSize / 2 - this.padSize * 0.07 })
    }
    .width(this.padSize)
    .height(this.padSize)
    .opacity(this.opacity_ / 100)
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent): void => {
      if (this.isEditMode()) return;
      event.stopPropagation();
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

      this.updateDirection(touch.x, touch.y);
      return;
    }

    if (event.type === TouchType.Move) {
      if (this.trackingTouchId < 0) return;
      const touch: TouchObject | null = this.findTrackedTouch(event.touches);
      if (touch !== null) {
        this.updateDirection(touch.x, touch.y);
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
        this.currentDir = 0;
        this.onDirectionChange(0);
      }
    }
  }

  /**
   * 根据触摸坐标计算方向位掩码
   * 参照 Android DigitalPad.java 的 3×3 九宫格算法：
   * - X < 33% → LEFT,  X > 66% → RIGHT
   * - Y < 33% → UP,    Y > 66% → DOWN
   * - 可同时触发两个方向（对角线）
   */
  private updateDirection(x: number, y: number): void {
    let newDir: number = 0;

    if (x < this.threshold33) {
      newDir |= DPAD_LEFT;
    }
    if (x > this.threshold66) {
      newDir |= DPAD_RIGHT;
    }
    if (y < this.threshold33) {
      newDir |= DPAD_UP;
    }
    if (y > this.threshold66) {
      newDir |= DPAD_DOWN;
    }

    if (newDir !== this.currentDir) {
      this.currentDir = newDir;
      this.onDirectionChange(newDir);
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
}
