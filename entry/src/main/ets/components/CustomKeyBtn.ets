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
 * 独立按键组件
 *
 * 参照 VirtualController / AnalogStick 的经验设计：
 *   - 独立 @Component 保证触摸处理器稳定
 *   - 每个按钮使用 HitTestMode.Block + event.stopPropagation()
 *   - 编辑模式拖拽通过内部 @State 实现，不触发父级重渲染
 */

import {
  CustomKeyDef,
  KeyAction,
  createDefaultKeyDef,
} from '../service/customkey/CustomKeyTypes';
import { OV_TEXT_WHITE } from '../common/OverlayConstants';
import {
  EDIT_BORDER_COLOR,
  SELECT_BORDER_COLOR,
  DRAG_THRESHOLD,
  SnapResult,
  doKeyHaptic,
  getButtonIconResource,
} from './CustomKeyConstants';

function resolveCustomKeyForegroundColor(isActive: boolean, textColor: string): ResourceColor {
  return isActive ? OV_TEXT_WHITE : textColor;
}

@Component
export struct CustomKeyBtn {
  // ── 配置属性 ──
  keyDef: CustomKeyDef = createDefaultKeyDef();
  @Prop editMode: boolean = false;
  @Prop isSelected: boolean = false;

  // ── 回调 ──
  onAction: (action: KeyAction, isDown: boolean) => void = () => {};
  /** 拖拽完成回调，参数为 vp 偏移量 (deltaX, deltaY) */
  onDragFinish: (keyId: string, deltaX: number, deltaY: number) => void = () => {};
  /** 拖拽实时移动回调，参数为 vp 偏移量 */
  onGroupDragMove: (keyId: string, deltaX: number, deltaY: number) => void = () => {};
  onSelect: (keyId: string) => void = () => {};
  onLongPress: (keyId: string) => void = () => {};

  /**
   * 吸附计算回调：传入按键 ID 和原始 vp 偏移，返回吸附后的 vp 偏移
   * 返回 null 表示不吸附
   */
  snapCalculator: (keyId: string, rawDx: number, rawDy: number) => SnapResult | null = () => null;

  // ── 内部状态（独立 @State —— 触摸时变化只触发自身重渲染） ──
  @State private isPressed: boolean = false;
  @State private isToggled: boolean = false;
  /** 拖拽偏移（视觉 translate） */
  @State private dragOffsetX: number = 0;
  @State private dragOffsetY: number = 0;

  // 拖拽追踪（非 @State）
  private dragging: boolean = false;
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private longPressTimer: number = -1;

  build() {
    if (this.keyDef.shape === 'hexagon') {
      this.HexagonBtn()
    } else {
      this.NormalBtn()
    }
  }

  /** 获取 SVG 图标资源（缓存友好：仅在有 icon 时查找） */
  private getIconRes(): Resource | undefined {
    return this.keyDef.icon ? getButtonIconResource(this.keyDef.icon) : undefined;
  }

  private getForegroundColor(): ResourceColor {
    return resolveCustomKeyForegroundColor(
      this.isPressed || this.isToggled,
      this.keyDef.textColor);
  }

  @Builder
  KeyFace() {
    if (this.getIconRes()) {
      Image(this.getIconRes()!)
        .width(this.keyDef.fontSize + 6)
        .height(this.keyDef.fontSize + 6)
        .fillColor(this.getForegroundColor())
        .objectFit(ImageFit.Contain)
    } else {
      Text(this.keyDef.label)
        .fontSize(this.keyDef.fontSize)
        .fontColor(this.getForegroundColor())
        .fontWeight(FontWeight.Bold)
        .textAlign(TextAlign.Center)
    }
  }

  @Builder
  NormalBtn() {
    Stack() {
      this.KeyFace()
    }
    .width(this.keyDef.width)
    .height(this.keyDef.height)
    .borderRadius(this.keyDef.shape === 'circle'
      ? this.keyDef.width / 2
      : this.keyDef.borderRadius)
    .backgroundColor(this.isPressed || this.isToggled
      ? this.keyDef.pressedColor
      : this.keyDef.bgColor)
    .border({
      width: this.editMode ? 2 : (this.keyDef.borderWidth ?? 1),
      color: this.editMode
        ? (this.isSelected ? SELECT_BORDER_COLOR : EDIT_BORDER_COLOR)
        : (this.isPressed || this.isToggled
            ? this.keyDef.pressedColor
            : this.keyDef.normalColor),
      style: this.editMode ? BorderStyle.Dashed : BorderStyle.Solid,
    })
    .shadow({
      radius: this.isPressed || this.isToggled ? 8 : 3,
      color: this.isPressed || this.isToggled ? '#40A8D8EA' : '#20000000',
      offsetY: 1,
    })
    .opacity(this.keyDef.opacity / 100)
    .translate({ x: this.dragOffsetX, y: this.dragOffsetY })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => {
      event.stopPropagation();
      if (this.editMode) {
        this.handleEditTouch(event);
      } else {
        this.handlePlayTouch(event);
      }
    })
  }

  /** 六边形按键（flat-top 平顶六边形） */
  @Builder
  HexagonBtn() {
    Stack() {
      // 六边形背景 + 边框
      Polygon()
        .points(this.hexPoints(this.keyDef.width, this.keyDef.height))
        .fill(this.isPressed || this.isToggled
          ? this.keyDef.pressedColor
          : this.keyDef.bgColor)
        .stroke(this.editMode
          ? (this.isSelected ? SELECT_BORDER_COLOR : EDIT_BORDER_COLOR)
          : (this.isPressed || this.isToggled
              ? this.keyDef.pressedColor
              : this.keyDef.normalColor))
        .strokeWidth(this.editMode ? 2 : (this.keyDef.borderWidth ?? 1))
        .strokeDashArray(this.editMode ? [4, 3] : [])
        .antiAlias(true)
        .width(this.keyDef.width)
        .height(this.keyDef.height)

      // 标签/图标
      this.KeyFace()
    }
    .width(this.keyDef.width)
    .height(this.keyDef.height)
    .backgroundColor(Color.Transparent)
    .opacity(this.keyDef.opacity / 100)
    .translate({ x: this.dragOffsetX, y: this.dragOffsetY })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => {
      event.stopPropagation();
      // 游戏模式下只响应六边形内部的触摸
      if (!this.editMode) {
        const t = event.touches[0];
        if (t && !this.isInsideHexagon(t.x, t.y)) return;
      }
      if (this.editMode) {
        this.handleEditTouch(event);
      } else {
        this.handlePlayTouch(event);
      }
    })
  }

  /** 判断组件局部坐标 (x, y) 是否在六边形内部（射线法） */
  private isInsideHexagon(x: number, y: number): boolean {
    const pts = this.hexPoints(this.keyDef.width, this.keyDef.height);
    const n = pts.length;
    let inside = false;
    for (let i = 0, j = n - 1; i < n; j = i++) {
      const xi = pts[i][0], yi = pts[i][1];
      const xj = pts[j][0], yj = pts[j][1];
      if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }
  private hexPoints(w: number, h: number): Array<[number, number]> {
    const cx = w / 2;
    const cy = h / 2;
    const rx = w / 2;  // 水平半径
    const ry = h / 2;  // 垂直半径
    // 平顶六边形顶点（从右侧开始, 顺时针）
    return [
      [cx + rx, cy],           // 右
      [cx + rx / 2, cy + ry],  // 右下
      [cx - rx / 2, cy + ry],  // 左下
      [cx - rx, cy],           // 左
      [cx - rx / 2, cy - ry],  // 左上
      [cx + rx / 2, cy - ry],  // 右上
    ];
  }

  // ── 普通模式触摸处理 ──

  private handlePlayTouch(event: TouchEvent): void {
    if (this.keyDef.behavior === 'toggle') {
      if (event.type === TouchType.Down) {
        this.isToggled = !this.isToggled;
        this.onAction(this.keyDef.action, this.isToggled);
        this.doHaptic();
      }
      return;
    }
    // 点触模式
    if (event.type === TouchType.Down) {
      this.isPressed = true;
      this.onAction(this.keyDef.action, true);
      this.doHaptic();
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.isPressed = false;
      this.onAction(this.keyDef.action, false);
    }
  }

  // ── 编辑模式触摸处理（拖拽 + 长按 + 选中） ──

  private handleEditTouch(event: TouchEvent): void {
    const touch = event.touches[0];
    if (!touch) return;

    switch (event.type) {
      case TouchType.Down:
        this.dragStartX = touch.windowX;
        this.dragStartY = touch.windowY;
        this.dragOffsetX = 0;
        this.dragOffsetY = 0;
        this.dragging = false;

        this.cancelLongPress();
        this.longPressTimer = setTimeout(() => {
          if (!this.dragging) {
            this.onLongPress(this.keyDef.id);
            this.doHaptic();
          }
          this.longPressTimer = -1;
        }, 500) as number;
        break;

      case TouchType.Move: {
        const dx = touch.windowX - this.dragStartX;
        const dy = touch.windowY - this.dragStartY;
        if (!this.dragging && Math.abs(dx) + Math.abs(dy) > DRAG_THRESHOLD) {
          this.dragging = true;
          this.cancelLongPress();
        }
        if (this.dragging) {
          const snapResult = this.snapCalculator(this.keyDef.id, dx, dy);
          if (snapResult) {
            this.dragOffsetX = snapResult.dx;
            this.dragOffsetY = snapResult.dy;
          } else {
            this.dragOffsetX = dx;
            this.dragOffsetY = dy;
          }
          this.onGroupDragMove(this.keyDef.id, this.dragOffsetX, this.dragOffsetY);
        }
        break;
      }

      case TouchType.Up:
      case TouchType.Cancel:
        this.cancelLongPress();
        if (this.dragging) {
          this.onGroupDragMove(this.keyDef.id, 0, 0); // 清除组拖拽视觉偏移
          // 传递 vp 偏移量（不是新坐标），由父层转换为百分比
          this.onDragFinish(this.keyDef.id,
            this.dragOffsetX,
            this.dragOffsetY);
        } else {
          this.onSelect(this.keyDef.id);
        }
        this.dragging = false;
        break;
    }
  }

  private cancelLongPress(): void {
    if (this.longPressTimer !== -1) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  private doHaptic(): void {
    doKeyHaptic(this.keyDef.haptic ?? 'light');
  }
}
