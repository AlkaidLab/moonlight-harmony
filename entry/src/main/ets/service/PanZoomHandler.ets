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
 * 双指缩放与平移处理器
 *
 * 移植自 Android PanZoomHandler.kt，通过双指捏合手势对视频画面进行
 * 缩放和平移。启用后触摸事件被完全消费，不发送给远端游戏。
 *
 * 渲染方式：通过 ArkUI 的 .scale() + .translate() 对视频容器变换，
 * 类似 Android 的 View.scaleX/Y + View.x/y。
 */

/**
 * 二维坐标点
 */
export interface PointXY {
  x: number;
  y: number;
}

/**
 * 缩放平移状态
 */
export interface PanZoomState {
  /** 当前缩放倍数 (1.0 ~ MAX_SCALE) */
  scale: number;
  /** 水平平移 (vp) */
  translateX: number;
  /** 垂直平移 (vp) */
  translateY: number;
}

export class PanZoomHandler {
  private static readonly MAX_SCALE: number = 10.0;
  private static readonly MIN_SCALE: number = 1.0;

  // 当前状态
  private scaleFactor: number = 1.0;
  private translateX: number = 0;
  private translateY: number = 0;

  // 容器尺寸（vp）
  private parentWidth: number = 0;
  private parentHeight: number = 0;

  // 手势追踪
  private initialPinchDistance: number = 0;
  private initialScaleFactor: number = 1.0;
  private pinchFocusX: number = 0;
  private pinchFocusY: number = 0;
  private initialTranslateX: number = 0;
  private initialTranslateY: number = 0;

  // 平移追踪（双指移动）
  private lastPanX: number = 0;
  private lastPanY: number = 0;

  // 触摸点追踪
  private pointers: Map<number, PointXY> = new Map();

  // 状态变更回调
  private onStateChanged: ((state: PanZoomState) => void) | null = null;

  /**
   * 设置容器尺寸
   */
  setParentSize(width: number, height: number): void {
    this.parentWidth = width;
    this.parentHeight = height;
  }

  /**
   * 设置状态变更回调
   */
  setOnStateChanged(callback: (state: PanZoomState) => void): void {
    this.onStateChanged = callback;
  }

  /**
   * 重置为原始大小
   */
  reset(): void {
    this.scaleFactor = 1.0;
    this.translateX = 0;
    this.translateY = 0;
    this.pointers.clear();
    this.notifyStateChanged();
  }

  /**
   * 获取当前状态
   */
  getState(): PanZoomState {
    const state: PanZoomState = {
      scale: this.scaleFactor,
      translateX: this.translateX,
      translateY: this.translateY
    };
    return state;
  }

  /**
   * 是否处于缩放状态（scale > 1）
   */
  isZoomed(): boolean {
    return this.scaleFactor > 1.01;
  }

  /**
   * 处理触摸事件
   * @returns true 表示事件已被消费
   */
  handleTouchEvent(event: TouchEvent): boolean {
    const touches = event.touches;
    const changedTouches = event.changedTouches;

    // 更新指针状态
    for (const touch of changedTouches) {
      if (touch.type === TouchType.Down) {
        const downPt: PointXY = { x: touch.x, y: touch.y };
        this.pointers.set(touch.id, downPt);
      } else if (touch.type === TouchType.Move) {
        const movePt: PointXY = { x: touch.x, y: touch.y };
        this.pointers.set(touch.id, movePt);
      } else if (touch.type === TouchType.Up || touch.type === TouchType.Cancel) {
        this.pointers.delete(touch.id);
      }
    }

    // 双指手势
    if (touches.length === 2) {
      const p1: PointXY = { x: touches[0].x, y: touches[0].y };
      const p2: PointXY = { x: touches[1].x, y: touches[1].y };
      const currentDistance = this.distance(p1.x, p1.y, p2.x, p2.y);
      const focusX = (p1.x + p2.x) / 2;
      const focusY = (p1.y + p2.y) / 2;

      if (changedTouches[0]?.type === TouchType.Down ||
          (this.initialPinchDistance === 0 && changedTouches[0]?.type === TouchType.Move)) {
        // 捏合开始
        this.initialPinchDistance = currentDistance;
        this.initialScaleFactor = this.scaleFactor;
        this.pinchFocusX = focusX;
        this.pinchFocusY = focusY;
        this.initialTranslateX = this.translateX;
        this.initialTranslateY = this.translateY;
        this.lastPanX = focusX;
        this.lastPanY = focusY;
      } else if (changedTouches[0]?.type === TouchType.Move && this.initialPinchDistance > 0) {
        // 缩放
        const scaleRatio = currentDistance / this.initialPinchDistance;
        let newScale = this.initialScaleFactor * scaleRatio;
        newScale = Math.max(PanZoomHandler.MIN_SCALE, Math.min(newScale, PanZoomHandler.MAX_SCALE));

        // 以双指焦点为中心进行缩放（对齐 Android PanZoomHandler.onScale）
        // 焦点在变换后的坐标系中保持不变
        const oldScale = this.scaleFactor;
        if (oldScale > 0) {
          const dPivotX = (this.translateX - focusX) / oldScale * newScale;
          const dPivotY = (this.translateY - focusY) / oldScale * newScale;
          this.translateX = focusX + dPivotX;
          this.translateY = focusY + dPivotY;
        }

        // 叠加双指平移
        const panDeltaX = focusX - this.lastPanX;
        const panDeltaY = focusY - this.lastPanY;
        this.translateX += panDeltaX;
        this.translateY += panDeltaY;

        this.scaleFactor = newScale;
        this.lastPanX = focusX;
        this.lastPanY = focusY;

        this.constrainToBounds();
        this.notifyStateChanged();
      }
    } else if (touches.length === 1 && this.isZoomed()) {
      // 单指平移（仅在已缩放时）
      const touch = touches[0];
      if (changedTouches[0]?.type === TouchType.Down) {
        this.lastPanX = touch.x;
        this.lastPanY = touch.y;
      } else if (changedTouches[0]?.type === TouchType.Move) {
        const dx = touch.x - this.lastPanX;
        const dy = touch.y - this.lastPanY;
        this.translateX += dx;
        this.translateY += dy;
        this.lastPanX = touch.x;
        this.lastPanY = touch.y;

        this.constrainToBounds();
        this.notifyStateChanged();
      }
    }

    // 手指全部抬起时重置 pinch 状态
    if (this.pointers.size === 0) {
      this.initialPinchDistance = 0;
      // 如果缩放接近 1.0，自动复位
      if (this.scaleFactor < 1.05) {
        this.reset();
      }
    }

    return true;
  }

  /**
   * 坐标逆变换：将屏幕触摸坐标转换为未缩放的 XComponent 坐标
   *
   * 对齐 Android Game.getStreamViewRelativeNormalizedXY()
   */
  inverseTransform(screenX: number, screenY: number): PointXY {
    const result: PointXY = {
      x: (screenX - this.translateX) / this.scaleFactor,
      y: (screenY - this.translateY) / this.scaleFactor
    };
    return result;
  }

  /**
   * 边界约束：确保缩放后的视频不会拖出可视区域
   *
   * 对齐 Android PanZoomHandler.constrainToBounds()
   */
  private constrainToBounds(): void {
    if (this.parentWidth <= 0 || this.parentHeight <= 0) return;

    const childWidth = this.parentWidth * this.scaleFactor;
    const childHeight = this.parentHeight * this.scaleFactor;

    if (this.parentWidth >= childWidth) {
      // 缩放后比容器小 → 居中
      this.translateX = (this.parentWidth - childWidth) / 2;
    } else {
      // 不允许拖出边界
      this.translateX = Math.max(this.parentWidth - childWidth, Math.min(this.translateX, 0));
    }

    if (this.parentHeight >= childHeight) {
      this.translateY = (this.parentHeight - childHeight) / 2;
    } else {
      this.translateY = Math.max(this.parentHeight - childHeight, Math.min(this.translateY, 0));
    }
  }

  /**
   * 计算两点间距离
   */
  private distance(x1: number, y1: number, x2: number, y2: number): number {
    const dx = x1 - x2;
    const dy = y1 - y2;
    return Math.sqrt(dx * dx + dy * dy);
  }

  /**
   * 通知状态变更
   */
  private notifyStateChanged(): void {
    if (this.onStateChanged) {
      this.onStateChanged(this.getState());
    }
  }
}
