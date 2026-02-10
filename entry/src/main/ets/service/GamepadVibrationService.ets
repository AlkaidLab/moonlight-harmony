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
 * 手柄震动处理服务
 * 
 * 从 GamepadManager 中解耦的独立模块，负责：
 * 1. USB 手柄震动（直接发送到控制器）
 * 2. 设备震动回退（使用设备马达模拟手柄震动）
 * 3. 振动模式管理（仅手柄/仅设备/同时/自动）
 */

import { vibrator } from '@kit.SensorServiceKit';
import { UsbDriverService, AbstractController } from './usbdriver/index';

// ==================== 震动服务 ====================

export class GamepadVibrationService {
  private usbDriverService: UsbDriverService;
  
  // 设置
  private deviceVibrateEnabled = false;
  private deviceVibrateStrength = 100;
  private vibrationMode = '自动';
  
  // 槽位→设备键的查找函数（由 GamepadManager 提供）
  private deviceKeyToSlotLookup: Map<string, number>;
  
  // 高清振动支持缓存
  private hdHapticSupported: boolean | null = null;
  // 上次震动参数缓存（用于检测变化）
  private lastLowFreq: number = 0;
  private lastHighFreq: number = 0;
  // 震动活跃标志
  private isVibrating: boolean = false;

  constructor(usbDriverService: UsbDriverService, deviceKeyToSlot: Map<string, number>) {
    this.usbDriverService = usbDriverService;
    this.deviceKeyToSlotLookup = deviceKeyToSlot;
  }

  // ==================== 设置 ====================

  /**
   * 更新震动设置
   */
  setSettings(enabled: boolean, strength: number, mode: string): void {
    this.deviceVibrateEnabled = enabled;
    this.deviceVibrateStrength = strength;
    this.vibrationMode = mode;
  }

  // ==================== 公开 API ====================

  /**
   * 处理震动反馈
   */
  handleRumble(controllerNumber: number, lowFreqMotor: number, highFreqMotor: number): void {
    const controllers = this.usbDriverService.getControllers();
    const hasUsbController = controllers.length > 0;

    switch (this.vibrationMode) {
      case '仅手柄':
        if (hasUsbController) {
          this.rumbleUsbControllers(controllers, controllerNumber, lowFreqMotor, highFreqMotor);
        }
        break;

      case '仅设备':
        this.triggerDeviceVibrate(lowFreqMotor, highFreqMotor);
        break;

      case '同时':
        if (hasUsbController) {
          this.rumbleUsbControllers(controllers, controllerNumber, lowFreqMotor, highFreqMotor);
        }
        this.triggerDeviceVibrate(lowFreqMotor, highFreqMotor);
        break;

      case '自动':
      default:
        if (hasUsbController) {
          this.rumbleUsbControllers(controllers, controllerNumber, lowFreqMotor, highFreqMotor);
        } else {
          this.triggerDeviceVibrate(lowFreqMotor, highFreqMotor);
        }
        break;
    }
  }

  /**
   * 处理扳机震动
   */
  handleRumbleTriggers(controllerNumber: number, leftTrigger: number, rightTrigger: number): void {
    const controllers = this.usbDriverService.getControllers();
    const controller = this.findControllerBySlot(controllers, controllerNumber);
    controller?.rumbleTriggers(leftTrigger, rightTrigger);
  }

  /**
   * 停止所有震动
   */
  stopAll(): void {
    if (this.isVibrating) {
      this.stopVibrationImmediate();
      this.lastLowFreq = 0;
      this.lastHighFreq = 0;
    }
  }

  // ==================== 内部实现 ====================

  /**
   * 根据槽位号查找控制器（带多级后备）
   */
  private findControllerBySlot(controllers: AbstractController[], slotNumber: number): AbstractController | null {
    if (controllers.length === 0) return null;

    // 优先：槽位精确匹配
    for (const controller of controllers) {
      if (this.deviceKeyToSlotLookup.get(controller.getDeviceKey()) === slotNumber) {
        return controller;
      }
    }

    // 后备：使用索引或第一个
    if (controllers.length === 1) return controllers[0];
    if (slotNumber < controllers.length) return controllers[slotNumber];
    return controllers[0];
  }

  /**
   * 向 USB 控制器发送震动
   */
  private rumbleUsbControllers(controllers: AbstractController[], controllerNumber: number, lowFreqMotor: number, highFreqMotor: number): void {
    const controller = this.findControllerBySlot(controllers, controllerNumber);
    controller?.rumble(lowFreqMotor, highFreqMotor);
  }

  /**
   * 触发设备震动（后备方案）
   *
   * 关键改进：
   * 1. 使用 continuous 长振（而非 transient 瞬态）实现持续震动
   * 2. 强度变化时立即停止旧震动再启动新震动
   * 3. 使用 stopVibrationSync 同步停止确保即时性
   */
  private triggerDeviceVibrate(lowFreqMotor: number, highFreqMotor: number): void {
    if (!this.deviceVibrateEnabled) return;

    // 停止震动
    if (lowFreqMotor === 0 && highFreqMotor === 0) {
      if (this.isVibrating) {
        this.stopVibrationImmediate();
        this.lastLowFreq = 0;
        this.lastHighFreq = 0;
      }
      return;
    }

    // 检查是否需要更新震动（强度变化超过阈值才更新，避免过于频繁）
    const lowDelta = Math.abs(lowFreqMotor - this.lastLowFreq);
    const highDelta = Math.abs(highFreqMotor - this.lastHighFreq);
    const threshold = 3000;  // 约 5% 的变化阈值

    if (this.isVibrating && lowDelta < threshold && highDelta < threshold) {
      return;  // 变化太小，不更新
    }

    this.lastLowFreq = lowFreqMotor;
    this.lastHighFreq = highFreqMotor;

    // 计算用户强度系数
    const userStrength = this.deviceVibrateStrength / 100;

    // 计算低频和高频马达的强度 (0-100)
    const lowIntensity = Math.floor((lowFreqMotor / 65535) * userStrength * 100);
    const highIntensity = Math.floor((highFreqMotor / 65535) * userStrength * 100);

    // 检查是否支持高清振动（首次检查后缓存）
    if (this.hdHapticSupported === null) {
      try {
        this.hdHapticSupported = vibrator.isHdHapticSupported();
        console.info(`[VIBRATION] 高清振动支持: ${this.hdHapticSupported}`);
      } catch (_) {
        this.hdHapticSupported = false;
      }
    }

    // 先停止当前震动（确保即时切换）
    if (this.isVibrating) {
      this.stopVibrationImmediate();
    }

    try {
      if (this.hdHapticSupported) {
        this.triggerContinuousVibration(lowIntensity, highIntensity);
      } else {
        this.triggerTimeVibration(lowIntensity, highIntensity);
      }
      this.isVibrating = true;
    } catch (err) {
      console.warn(`[VIBRATION] 设备震动异常: ${err}`);
      this.fallbackTimeVibration(Math.max(lowIntensity, highIntensity));
    }
  }

  /**
   * 立即停止震动（同步方式）
   */
  private stopVibrationImmediate(): void {
    try {
      // 优先使用同步停止 API (API 12+)
      vibrator.stopVibrationSync();
    } catch (_) {
      // 回退到异步停止
      try {
        vibrator.stopVibration();
      } catch (_) { /* ignore */ }
    }
    this.isVibrating = false;
  }

  /**
   * 使用 continuous 长振实现持续震动 (API 18+)
   */
  private triggerContinuousVibration(lowIntensity: number, highIntensity: number): void {
    try {
      const builder = new vibrator.VibratorPatternBuilder();

      const combinedIntensity = Math.min(100, Math.max(lowIntensity, highIntensity));
      if (combinedIntensity < 5) return;

      // 根据低频/高频比例计算频率
      let frequency: number;
      if (lowIntensity > 0 && highIntensity > 0) {
        const ratio = highIntensity / (lowIntensity + highIntensity);
        frequency = Math.floor(30 + ratio * 50);  // 30-80
      } else if (lowIntensity > 0) {
        frequency = 35;  // 低频：沉闷
      } else {
        frequency = 70;  // 高频：尖锐
      }

      builder.addContinuousEvent(0, 500, {
        intensity: combinedIntensity,
        frequency: frequency,
        index: 0
      });

      vibrator.startVibration({
        type: 'pattern',
        pattern: builder.build()
      }, {
        id: 0,
        usage: 'physicalFeedback'
      }).catch((err: Error) => {
        this.triggerTimeVibration(lowIntensity, highIntensity);
      });
    } catch (err) {
      this.triggerTimeVibration(lowIntensity, highIntensity);
    }
  }

  /**
   * 使用时长模式实现持续震动
   */
  private triggerTimeVibration(lowIntensity: number, highIntensity: number): void {
    const combinedIntensity = Math.max(lowIntensity, highIntensity);
    if (combinedIntensity < 5) return;

    vibrator.startVibration({
      type: 'time',
      duration: 500
    }, {
      id: 0,
      usage: 'physicalFeedback'
    }).catch((err: Error) => {
      console.warn(`[VIBRATION] 时长震动失败: ${err.message}`);
    });
  }

  /**
   * 回退的简单时长模式震动
   */
  private fallbackTimeVibration(intensity: number): void {
    if (intensity < 5) return;
    const duration = Math.floor(50 + intensity * 4.5);  // 50-500ms

    vibrator.startVibration({ type: 'time', duration }, { id: 0, usage: 'physicalFeedback' })
      .catch((err: Error) => console.warn(`[VIBRATION] 设备震动失败: ${err.message}`));
    this.isVibrating = true;
  }
}
