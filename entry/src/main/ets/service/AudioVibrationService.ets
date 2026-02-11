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
 * 音频振动服务
 *
 * 基于游戏音频的低频能量分析驱动振动反馈，增强沉浸感。
 * 例如：爆炸、枪声、引擎轰鸣等低音场景会触发振动。
 *
 * 架构:
 * C++ (BassEnergyAnalyzer) → TSFN → ArkTS (本服务) → 分路由
 *
 * 分路由策略（遵循 vibrationMode 振动模式设置）：
 * - 设备振动：直接调用 @ohos.vibrator HD Haptic API（保持最高精度）
 *   · 频率 30-50Hz 低沉触感，与低频音频能量匹配
 *   · 支持 intensity + frequency 精确控制
 * - USB 手柄：通过 GamepadManager 直接发送 USB HID 报告
 *   · 绕过 GamepadVibrationService 的防抖和参数变换
 *   · 保留完整的 16-bit 马达值精度
 */

import { vibrator } from '@kit.SensorServiceKit';
import { GamepadManager } from './GamepadManager';

export class AudioVibrationService {
  private enabled: boolean = false;
  private strength: number = 100; // 振动强度 (0-100)
  private vibrationMode: string = '自动'; // 振动模式

  // 状态
  private lastIntensity: number = 0;

  // 设备振动状态
  private hdHapticSupported: boolean | null = null;
  private isDeviceVibrating: boolean = false;

  // USB 手柄振动状态
  private isUsbRumbling: boolean = false;

  // 防抖：避免过于频繁的振动 API 调用
  private lastVibrationTime: number = 0;
  private static readonly MIN_VIBRATION_INTERVAL_MS = 40; // 最短间隔 40ms

  /**
   * 更新设置
   */
  setSettings(enabled: boolean, strength: number, vibrationMode: string): void {
    this.enabled = enabled;
    this.strength = strength;
    this.vibrationMode = vibrationMode;

    if (!enabled) {
      this.stopAll();
    }
  }

  /**
   * 处理 C++ 层传来的低频能量值
   * @param intensity 低频能量强度 (0-100)
   */
  handleBassEnergy(intensity: number): void {
    if (!this.enabled) return;

    // 强度为 0 → 停止振动
    if (intensity === 0) {
      if (this.isDeviceVibrating || this.isUsbRumbling) {
        this.stopAll();
      }
      return;
    }

    // 应用用户强度系数
    const effectiveIntensity = Math.floor(intensity * this.strength / 100);
    if (effectiveIntensity < 5) {
      if (this.isDeviceVibrating || this.isUsbRumbling) {
        this.stopAll();
      }
      return;
    }

    // 防抖检查
    const now = Date.now();
    if (now - this.lastVibrationTime < AudioVibrationService.MIN_VIBRATION_INTERVAL_MS) {
      return;
    }

    // 强度变化不大，跳过
    if ((this.isDeviceVibrating || this.isUsbRumbling) &&
        Math.abs(effectiveIntensity - this.lastIntensity) < 8) {
      return;
    }

    this.lastIntensity = effectiveIntensity;
    this.lastVibrationTime = now;

    // 根据振动模式分路由
    const shouldDevice = this.shouldVibrateDevice();
    const shouldUsb = this.shouldVibrateGamepad();

    if (shouldDevice) {
      this.triggerDeviceHdVibration(effectiveIntensity);
    } else if (this.isDeviceVibrating) {
      this.stopDeviceVibration();
    }

    if (shouldUsb) {
      this.triggerUsbRumble(effectiveIntensity);
    } else if (this.isUsbRumbling) {
      this.stopUsbRumble();
    }
  }

  /**
   * 停止所有振动
   */
  stop(): void {
    this.stopAll();
  }

  // ==================== 路由判断 ====================

  private shouldVibrateDevice(): boolean {
    switch (this.vibrationMode) {
      case '仅手柄': return false;
      case '仅设备': return true;
      case '同时': return true;
      case '自动':
      default:
        return !GamepadManager.getInstance().hasUsbControllers();
    }
  }

  private shouldVibrateGamepad(): boolean {
    switch (this.vibrationMode) {
      case '仅手柄': return true;
      case '仅设备': return false;
      case '同时': return true;
      case '自动':
      default:
        return GamepadManager.getInstance().hasUsbControllers();
    }
  }

  // ==================== 设备 HD Haptic 振动（最高精度路径） ====================

  /**
   * 直接使用 @ohos.vibrator HD Haptic API
   * - 频率 30-50Hz：匹配低频音频能量的低沉触感
   * - 强度跟随音频实时变化
   * - 持续 300ms 短脉冲，快速响应能量变化
   */
  private triggerDeviceHdVibration(intensity: number): void {
    // 检查 HD Haptic 支持（首次缓存）
    if (this.hdHapticSupported === null) {
      try {
        this.hdHapticSupported = vibrator.isHdHapticSupported();
      } catch (_) {
        this.hdHapticSupported = false;
      }
    }

    // 先停止当前振动
    if (this.isDeviceVibrating) {
      this.stopVibrationSync();
    }

    try {
      if (this.hdHapticSupported) {
        this.triggerHdHaptic(intensity);
      } else {
        this.triggerTimeVibration(intensity);
      }
      this.isDeviceVibrating = true;
    } catch (_) {
      this.triggerTimeVibration(intensity);
    }
  }

  /**
   * HD Haptic continuous 振动 (API 18+)
   * 频率 30-50Hz 对应低频音频的低沉触感
   */
  private triggerHdHaptic(intensity: number): void {
    try {
      const builder = new vibrator.VibratorPatternBuilder();
      const frequency = Math.floor(30 + (intensity / 100) * 20); // 30-50Hz

      builder.addContinuousEvent(0, 300, {
        intensity: Math.min(100, intensity),
        frequency: frequency,
        index: 0
      });

      vibrator.startVibration({
        type: 'pattern',
        pattern: builder.build()
      }, {
        id: 0,
        usage: 'physicalFeedback'
      }).catch((_: Error) => {
        this.triggerTimeVibration(intensity);
      });
    } catch (_) {
      this.triggerTimeVibration(intensity);
    }
  }

  /**
   * 时长模式振动（兼容所有设备）
   */
  private triggerTimeVibration(intensity: number): void {
    if (intensity < 5) return;
    const duration = Math.floor(50 + intensity * 2.5); // 50-300ms

    vibrator.startVibration({
      type: 'time',
      duration: duration
    }, {
      id: 0,
      usage: 'physicalFeedback'
    }).catch((_: Error) => { /* 忽略 */ });
    this.isDeviceVibrating = true;
  }

  // ==================== USB 手柄振动（直达路径） ====================

  /**
   * 直接通过 GamepadManager 发送 USB HID 报告
   * 绕过 GamepadVibrationService 的防抖和模式路由
   * lowFreq 为主（低沉触感），highFreq 给 25% 增加质感
   */
  private triggerUsbRumble(intensity: number): void {
    const lowFreq = Math.floor(intensity * 65535 / 100);
    const highFreq = Math.floor(lowFreq * 0.25);
    GamepadManager.getInstance().rumbleUsbControllers(0, lowFreq, highFreq);
    this.isUsbRumbling = true;
  }

  private stopUsbRumble(): void {
    GamepadManager.getInstance().rumbleUsbControllers(0, 0, 0);
    this.isUsbRumbling = false;
  }

  // ==================== 停止 ====================

  private stopAll(): void {
    if (this.isDeviceVibrating) {
      this.stopDeviceVibration();
    }
    if (this.isUsbRumbling) {
      this.stopUsbRumble();
    }
    this.lastIntensity = 0;
  }

  private stopDeviceVibration(): void {
    this.stopVibrationSync();
    this.isDeviceVibrating = false;
  }

  private stopVibrationSync(): void {
    try {
      vibrator.stopVibrationSync();
    } catch (_) {
      try {
        vibrator.stopVibration();
      } catch (_) { /* 忽略 */ }
    }
  }
}
