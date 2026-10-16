/*
 * Moonlight for HarmonyOS
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

export type CustomKeyTouchMode = 'momentary' | 'toggle' | 'tap';

/** 每个按钮只归属一个触点；其他手指的 Down/Up/Cancel 不改变它的状态。 */
export class CustomKeyTouchHandler {
  pressed: boolean = false;
  toggled: boolean = false;
  private pointerId: number = -1;
  private startX: number = 0;
  private startY: number = 0;
  private tapCancelled: boolean = false;
  private releasePress: (() => void) | null = null;
  private releaseToggle: (() => void) | null = null;

  reset(): void {
    const press = this.releasePress;
    const toggle = this.releaseToggle;
    this.pointerId = -1;
    this.pressed = false;
    this.toggled = false;
    this.releasePress = null;
    this.releaseToggle = null;
    if (press) press();
    if (toggle) toggle();
  }

  /** 返回 true 表示本次触摸确实激活了按钮，可据此触发一次振动。 */
  handleEvent(event: TouchEvent, mode: CustomKeyTouchMode,
    contains: (x: number, y: number) => boolean,
    onAction: (isDown: boolean) => void, onTap: () => void): boolean {
    const tracked = event.touches.find((touch: TouchObject) => touch.id === this.pointerId);
    const changed = event.changedTouches.find((touch: TouchObject) => touch.id === this.pointerId);
    if (event.type === TouchType.Cancel) {
      if (event.changedTouches.length === 0 || (this.pointerId >= 0 && (changed || !tracked))) this.reset();
      return false;
    }
    if (event.type === TouchType.Up) {
      if (!changed) {
        if (this.pointerId >= 0 && !tracked) this.reset();
        return false;
      }
      this.pointerId = -1;
      this.pressed = false;
      const release = this.releasePress;
      this.releasePress = null;
      if (release) release();
      if (mode === 'tap' && !this.tapCancelled && contains(changed.x, changed.y) &&
        Math.hypot(changed.windowX - this.startX, changed.windowY - this.startY) <= 8) {
        onTap();
        return true;
      }
      return false;
    }
    if (this.pointerId >= 0 && !tracked) this.reset();
    if (event.type === TouchType.Down) {
      if (this.pointerId >= 0) return false;
      const touch = event.changedTouches.find((item: TouchObject) => contains(item.x, item.y));
      if (!touch) return false;
      this.pointerId = touch.id;
      this.startX = touch.windowX;
      this.startY = touch.windowY;
      this.tapCancelled = false;
      if (mode === 'toggle') {
        this.toggled = !this.toggled;
        if (this.toggled) {
          this.releaseToggle = (): void => onAction(false);
          onAction(true);
        } else {
          const release = this.releaseToggle;
          this.releaseToggle = null;
          if (release) release();
        }
        return true;
      }
      this.pressed = true;
      if (mode === 'momentary') {
        this.releasePress = (): void => onAction(false);
        onAction(true);
        return true;
      }
    } else if (event.type === TouchType.Move && tracked && mode === 'tap') {
      if (!contains(tracked.x, tracked.y) ||
        Math.hypot(tracked.windowX - this.startX, tracked.windowY - this.startY) > 8) this.tapCancelled = true;
    }
    return false;
  }
}
