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
 * 手柄鼠标模拟服务
 * 
 * 对齐 Android: GenericControllerContext.toggleMouseEmulation()
 * - 左摇杆控制鼠标移动
 * - 右摇杆控制滚轮
 * - A = 左键, B = 右键
 * - D-Pad ↑↓ = 垂直滚轮, D-Pad ←→ = 水平滚轮
 * - 所有手柄输入发送全零（不影响游戏）
 */

import { GamepadState, MoonlightButton } from './GamepadTypes';

// ==================== 类型定义 ====================

/** 鼠标模拟报告间隔 (ms)，与 Android 一致 */
const MOUSE_EMULATION_REPORT_PERIOD = 50;

/**
 * 鼠标模拟事件回调接口
 * 由 StreamPage 设置，用于发送鼠标事件到主机
 */
export interface MouseEmulationCallback {
  sendMouseMove(deltaX: number, deltaY: number): void;
  sendMouseButtonDown(button: number): void;
  sendMouseButtonUp(button: number): void;
  sendMouseHighResScroll(scrollAmount: number): void;
  sendMouseHighResHScroll(scrollAmount: number): void;
}

/** 摇杆→像素移动量结果 */
class StickMovement {
  x: number = 0;
  y: number = 0;
  mag: number = 0;

  constructor(x: number, y: number, mag: number) {
    this.x = x;
    this.y = y;
    this.mag = mag;
  }
}

// ==================== 鼠标模拟服务 ====================

/**
 * 手柄鼠标模拟服务
 * 
 * 从 GamepadManager 中解耦的独立模块，负责：
 * 1. 管理鼠标模拟状态（开启/关闭）
 * 2. 摇杆值→鼠标移动转换（50ms 定时器轮询）
 * 3. 按键→鼠标按键/滚轮映射
 * 4. 拦截手柄输入，发送全零手柄包
 */
export class MouseEmulationService {
  /** 鼠标模拟是否激活 */
  private active = false;
  /** 鼠标事件回调 */
  private callback: MouseEmulationCallback | null = null;
  /** 定时器 ID */
  private timerId: number = -1;
  /** 上一次的按键状态，用于检测变化 */
  private lastButtons: number = 0;
  /** 左摇杆值 */
  private leftStickX: number = 0;
  private leftStickY: number = 0;
  /** 右摇杆值 */
  private rightStickX: number = 0;
  private rightStickY: number = 0;

  constructor() {
  }

  // ==================== 公开 API ====================

  /**
   * 设置鼠标模拟回调（由 StreamPage 调用）
   */
  setCallback(callback: MouseEmulationCallback | null): void {
    this.callback = callback;
  }

  /**
   * 切换鼠标模拟模式
   */
  toggle(): void {
    if (this.active) {
      this.stop();
    } else {
      this.start();
    }
  }

  /**
   * 当前是否处于鼠标模拟模式
   */
  isActive(): boolean {
    return this.active;
  }

  /**
   * 手柄状态拦截：鼠标模拟时的统一入口
   * 更新摇杆值 + 处理按键变化 + 通过 onSendZeroState 发送全零手柄包
   * 
   * @param state 当前手柄状态
   * @param onSendZeroState 发送全零手柄状态的回调（由调用方提供 slot + listener）
   * @returns true 表示已拦截（鼠标模拟模式），false 表示正常手柄处理
   */
  intercept(state: GamepadState, onSendZeroState: () => void): boolean {
    if (!this.active) {
      return false;
    }

    // 更新摇杆值（供定时器使用）
    this.leftStickX = state.leftStickX;
    this.leftStickY = state.leftStickY;
    this.rightStickX = state.rightStickX;
    this.rightStickY = state.rightStickY;

    // 按键变化 → 鼠标按键/滚轮
    this.handleButtons(state.buttons);

    // 发送全零手柄包（不影响游戏输入）
    onSendZeroState();

    return true;
  }

  /**
   * 停止模拟并清理资源
   */
  cleanup(): void {
    this.stop();
    this.callback = null;
  }

  // ==================== 内部实现 ====================

  private start(): void {
    this.active = true;
    this.lastButtons = 0;
    this.leftStickX = 0;
    this.leftStickY = 0;
    this.rightStickX = 0;
    this.rightStickY = 0;

    // 启动定时器，每 50ms 轮询摇杆值发送鼠标移动
    this.timerId = setInterval(() => {
      this.tick();
    }, MOUSE_EMULATION_REPORT_PERIOD);

    console.info('[MOUSE-EMU] 鼠标模拟模式已启动');
  }

  private stop(): void {
    this.active = false;
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.lastButtons = 0;
    console.info('[MOUSE-EMU] 鼠标模拟模式已停止');
  }

  /**
   * 摇杆值→像素移动量转换
   * 对齐 Android: convertRawStickAxisToPixelMovement()
   *   normalize → ×4 → magnitude² 加速曲线
   */
  private convertStickToPixelMovement(stickX: number, stickY: number): StickMovement {
    // 归一化到 -1 ~ 1
    let nx = stickX / 32766.0;
    let ny = stickY / 32766.0;
    // 基础倍率
    nx *= 4;
    ny *= 4;
    const mag = Math.sqrt(nx * nx + ny * ny);
    if (mag > 0) {
      // 二次方加速：越推越快
      const accel = mag * mag;
      const scale = accel / mag;
      nx *= scale;
      ny *= scale;
    }
    return new StickMovement(nx, ny, mag);
  }

  /**
   * 定时器回调：发送鼠标移动 + 滚轮
   * 对齐 Android: mouseEmulationRunnable
   */
  private tick(): void {
    if (!this.active || !this.callback) {
      return;
    }

    // 左摇杆 → 鼠标移动
    const move = this.convertStickToPixelMovement(this.leftStickX, this.leftStickY);
    if (move.mag >= 1) {
      this.callback.sendMouseMove(
        Math.round(move.x), Math.round(-move.y)  // Y轴取反（屏幕坐标 vs 摇杆坐标）
      );
    }

    // 右摇杆 → 滚轮
    const scroll = this.convertStickToPixelMovement(this.rightStickX, this.rightStickY);
    if (scroll.mag >= 1) {
      this.callback.sendMouseHighResScroll(Math.round(scroll.y));
      this.callback.sendMouseHighResHScroll(Math.round(scroll.x));
    }
  }

  /**
   * 处理鼠标模拟下的按键变化
   * 对齐 Android: sendControllerInputPacket() mouseEmulationActive 分支
   * A → 左键, B → 右键, D-Pad ↑↓ → 垂直滚轮, D-Pad ←→ → 水平滚轮
   */
  private handleButtons(buttons: number): void {
    if (!this.callback) return;

    const changed = buttons ^ this.lastButtons;
    this.lastButtons = buttons;

    // A 键 → 鼠标左键
    if (changed & MoonlightButton.A) {
      if (buttons & MoonlightButton.A) {
        this.callback.sendMouseButtonDown(0x01); // BUTTON_LEFT
      } else {
        this.callback.sendMouseButtonUp(0x01);
      }
    }

    // B 键 → 鼠标右键
    if (changed & MoonlightButton.B) {
      if (buttons & MoonlightButton.B) {
        this.callback.sendMouseButtonDown(0x03); // BUTTON_RIGHT
      } else {
        this.callback.sendMouseButtonUp(0x03);
      }
    }

    // D-Pad ↑ → 滚轮上
    if ((changed & MoonlightButton.UP) && (buttons & MoonlightButton.UP)) {
      this.callback.sendMouseHighResScroll(1);
    }
    // D-Pad ↓ → 滚轮下
    if ((changed & MoonlightButton.DOWN) && (buttons & MoonlightButton.DOWN)) {
      this.callback.sendMouseHighResScroll(-1);
    }
    // D-Pad → → 水平滚轮右
    if ((changed & MoonlightButton.RIGHT) && (buttons & MoonlightButton.RIGHT)) {
      this.callback.sendMouseHighResHScroll(1);
    }
    // D-Pad ← → 水平滚轮左
    if ((changed & MoonlightButton.LEFT) && (buttons & MoonlightButton.LEFT)) {
      this.callback.sendMouseHighResHScroll(-1);
    }
  }
}
