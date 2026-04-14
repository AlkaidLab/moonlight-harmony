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
 * 虚拟轮盘菜单 (WheelPad) 组件
 *
 * 参照 Android WheelPad.java 的设计：
 * - 圆形放射状菜单，N 个分区从12点方向顺时针排列
 * - 触摸后按角度判定激活分区，滑动切换时自动释放旧 + 按下新
 * - 中心内圈为死区，不触发任何动作
 * - 使用 Canvas 绘制扇形分区 + 分割线 + 文字标签
 */

import { KeyAction, WheelPadSegment } from '../../service/CustomKeyTypes';

/** 分区动作回调 */
export type WheelSegmentActionCallback = (action: KeyAction, isDown: boolean) => void;

/** 编辑模式查询 */
export type WheelEditModeGetter = () => boolean;

@Component
export struct VirtualWheelPad {
  /** 轮盘尺寸 (vp) */
  @Prop wheelSize: number = 150;
  /** 常态边框颜色 */
  @Prop normalColor: string = '#6050C080';
  /** 按下高亮颜色 */
  @Prop pressedColor: string = '#C070E090';
  /** 分区背景色 */
  @Prop bgColor: string = '#3050C080';
  /** 文字颜色 */
  @Prop textColor: string = '#E0FFFFFF';
  /** 透明度 0-100 */
  @Prop opacity_: number = 80;

  /** 分区配置列表 */
  segments: WheelPadSegment[] = [];
  /** 分区动作回调（按下/释放） */
  onSegmentAction: WheelSegmentActionCallback = (_a: KeyAction, _d: boolean): void => {};
  /** 编辑模式查询 */
  isEditMode: WheelEditModeGetter = (): boolean => false;

  // === 内部状态 ===
  @State @Watch('onActiveChanged') private activeIndex: number = -1;

  private trackingTouchId: number = -1;

  // Canvas
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasReady: boolean = false;

  // 预计算
  private wheelRadius: number = 75;
  private innerRadius: number = 22;

  aboutToAppear(): void {
    this.wheelRadius = this.wheelSize / 2;
    this.innerRadius = this.wheelRadius * 0.30;
  }

  build() {
    Stack() {
      Canvas(this.ctx)
        .width(this.wheelSize)
        .height(this.wheelSize)
        .backgroundColor('#01000000')
        .onReady(() => {
          this.canvasReady = true;
          this.drawWheel();
        })
    }
    .width(this.wheelSize)
    .height(this.wheelSize)
    .opacity(this.opacity_ / 100)
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent): void => {
      if (this.isEditMode()) return;
      event.stopPropagation();
      this.handleTouch(event);
    })
  }

  private onActiveChanged(): void {
    if (this.canvasReady) {
      this.drawWheel();
    }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // Canvas 绘制
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private drawWheel(): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    const cx: number = this.wheelRadius;
    const cy: number = this.wheelRadius;
    const outerR: number = this.wheelRadius - 2;
    const innerR: number = this.innerRadius;
    const N: number = this.segments.length;
    if (N === 0) return;

    const sweepRad: number = (2 * Math.PI) / N;

    // 清空画布
    ctx.clearRect(0, 0, this.wheelSize, this.wheelSize);

    // 绘制各分区扇形
    for (let i = 0; i < N; i++) {
      const startAngle: number = i * sweepRad - Math.PI / 2 - sweepRad / 2;
      const endAngle: number = startAngle + sweepRad;

      // 扇形填充（从内圈到外圈的环形区域）
      ctx.beginPath();
      ctx.arc(cx, cy, outerR, startAngle, endAngle, false);
      ctx.arc(cx, cy, innerR, endAngle, startAngle, true);
      ctx.closePath();
      ctx.fillStyle = (i === this.activeIndex) ? this.pressedColor : this.bgColor;
      ctx.fill();

      // 分割线
      const lineStartX: number = cx + innerR * Math.cos(startAngle);
      const lineStartY: number = cy + innerR * Math.sin(startAngle);
      const lineEndX: number = cx + outerR * Math.cos(startAngle);
      const lineEndY: number = cy + outerR * Math.sin(startAngle);
      ctx.beginPath();
      ctx.moveTo(lineStartX, lineStartY);
      ctx.lineTo(lineEndX, lineEndY);
      ctx.strokeStyle = this.normalColor;
      ctx.lineWidth = 1.5;
      ctx.stroke();
    }

    // 外圈边框
    ctx.beginPath();
    ctx.arc(cx, cy, outerR, 0, 2 * Math.PI, false);
    ctx.strokeStyle = this.normalColor;
    ctx.lineWidth = 1.5;
    ctx.stroke();

    // 内圈死区
    ctx.beginPath();
    ctx.arc(cx, cy, innerR, 0, 2 * Math.PI, false);
    ctx.fillStyle = '#CC1A1A2E';
    ctx.fill();
    ctx.strokeStyle = this.normalColor;
    ctx.lineWidth = 1.5;
    ctx.stroke();

    // 文字标签
    const textR: number = innerR + (outerR - innerR) * 0.55;
    const fontSize: number = Math.max(8, (outerR - innerR) * 0.28);
    ctx.font = `bold ${fontSize}px sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';

    for (let i = 0; i < N; i++) {
      // 分区中心角度（12点方向开始，顺时针）
      const midAngle: number = i * sweepRad - Math.PI / 2;
      const tx: number = cx + textR * Math.cos(midAngle);
      const ty: number = cy + textR * Math.sin(midAngle);

      ctx.fillStyle = (i === this.activeIndex) ? '#FFFFFFFF' : this.textColor;
      ctx.fillText(this.segments[i].label, tx, ty);
    }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 触摸处理
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private handleTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      const changed: TouchObject[] = event.changedTouches;
      if (changed.length === 0) return;
      if (this.trackingTouchId >= 0) return;

      this.trackingTouchId = changed[0].id;
      this.updateActiveSegment(changed[0].x, changed[0].y);
      return;
    }

    if (event.type === TouchType.Move) {
      if (this.trackingTouchId < 0) return;
      const touch: TouchObject | null = this.findTrackedTouch(event.touches);
      if (touch !== null) {
        this.updateActiveSegment(touch.x, touch.y);
      }
      return;
    }

    // Up / Cancel
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const changed: TouchObject[] = event.changedTouches;
      let isOurs: boolean = false;
      for (let i = 0; i < changed.length; i++) {
        if (changed[i].id === this.trackingTouchId) {
          isOurs = true;
          break;
        }
      }
      if (isOurs) {
        // 释放当前激活的分区
        if (this.activeIndex >= 0 && this.activeIndex < this.segments.length) {
          this.onSegmentAction(this.segments[this.activeIndex].action, false);
        }
        this.trackingTouchId = -1;
        this.activeIndex = -1;
      }
    }
  }

  /**
   * 根据触摸坐标计算激活的分区索引
   * 角度从12点方向顺时针计算，与分区排列一致
   */
  private updateActiveSegment(x: number, y: number): void {
    const cx: number = this.wheelRadius;
    const cy: number = this.wheelRadius;
    const dx: number = x - cx;
    const dy: number = y - cy;
    const dist: number = Math.sqrt(dx * dx + dy * dy);

    // 死区检测
    if (dist < this.innerRadius) {
      if (this.activeIndex >= 0 && this.activeIndex < this.segments.length) {
        this.onSegmentAction(this.segments[this.activeIndex].action, false);
      }
      this.activeIndex = -1;
      return;
    }

    const N: number = this.segments.length;
    if (N === 0) return;

    const sweepRad: number = (2 * Math.PI) / N;

    // 计算从12点方向顺时针角度 [0, 2π)
    // atan2(dy, dx) 从3点方向逆时针 → 加 π/2 旋转到12点方向
    // 再加 sweepRad/2 使分区边界对齐（分区0的中心在12点方向）
    let angle: number = Math.atan2(dy, dx) + Math.PI / 2 + sweepRad / 2;
    if (angle < 0) angle += 2 * Math.PI;
    if (angle >= 2 * Math.PI) angle -= 2 * Math.PI;

    let newIndex: number = Math.floor(angle / sweepRad);
    if (newIndex >= N) newIndex = N - 1;

    if (newIndex !== this.activeIndex) {
      // 释放旧分区
      if (this.activeIndex >= 0 && this.activeIndex < this.segments.length) {
        this.onSegmentAction(this.segments[this.activeIndex].action, false);
      }
      // 按下新分区
      this.activeIndex = newIndex;
      if (this.activeIndex >= 0 && this.activeIndex < this.segments.length) {
        this.onSegmentAction(this.segments[this.activeIndex].action, true);
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
}
