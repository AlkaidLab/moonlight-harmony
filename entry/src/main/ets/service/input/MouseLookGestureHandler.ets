/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2026 Moonlight/AlkaidLab
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/** 只接收移动输出回调：轻触、双击和长按均不能产生按键事件。 */
export class MouseLookGestureHandler {
  private pointerId: number = -1;
  private lastX: number = 0;
  private lastY: number = 0;
  private remainderX: number = 0;
  private remainderY: number = 0;

  reset(): void {
    this.pointerId = -1;
    this.remainderX = 0;
    this.remainderY = 0;
  }

  handleEvent(event: TouchEvent, sensitivity: number, invertY: boolean,
    onMovement: (deltaX: number, deltaY: number) => void): void {
    const tracked = event.touches.find((touch: TouchObject) => touch.id === this.pointerId);
    const lifted = event.changedTouches.some((touch: TouchObject) => touch.id === this.pointerId);
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      // 全局 Cancel 可能保留 touches、却没有 changedTouches，仍须清空手势。
      if (lifted || !tracked || (event.type === TouchType.Cancel && event.changedTouches.length === 0)) this.reset();
      return;
    }

    // 丢失 Up/Cancel 时也能收敛，不接续旧手势或产生跳变。
    if (this.pointerId >= 0 && !tracked) this.reset();
    if (event.type === TouchType.Down) {
      if (this.pointerId >= 0 || event.changedTouches.length === 0) return;
      const touch = event.changedTouches[0];
      this.pointerId = touch.id;
      this.lastX = touch.windowX;
      this.lastY = touch.windowY;
      return;
    }
    if (event.type !== TouchType.Move || this.pointerId < 0 || !tracked) return;

    const scale = Number.isFinite(sensitivity) ? Math.max(0.1, Math.min(5, sensitivity)) : 1.5;
    // 使用窗口坐标，手指滑出区域或组件位置改变时仍保持连续位移。
    this.remainderX += (tracked.windowX - this.lastX) * scale;
    this.remainderY += (tracked.windowY - this.lastY) * scale * (invertY ? -1 : 1);
    this.lastX = tracked.windowX;
    this.lastY = tracked.windowY;
    const dx = Math.trunc(this.remainderX);
    const dy = Math.trunc(this.remainderY);
    this.remainderX -= dx;
    this.remainderY -= dy;
    if (dx !== 0 || dy !== 0) onMovement(dx, dy);
  }
}
