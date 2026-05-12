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
 *
 * 场景模式:
 * - 游戏/电影 (sceneMode='游戏/电影'): 持续低频驱动，爆炸/枪声/引擎等
 *   · 频率 30-50Hz，持续 300ms，强度跟随音频实时变化
 * - 音乐/节奏 (sceneMode='音乐/节奏'): C++ onset 检测 → 短脉冲振动
 *   · 50ms 尖锐脉冲，节拍感强，频率 40-60Hz 更有弹性
 * - 自动 (sceneMode='自动'): C++ 层自动分析音频特征切换策略
 *
 * 架构:
 * C++ (BassEnergyAnalyzer) → TSFN → ArkTS (本服务) → 分路由
 *
 * 分路由策略（遵循 vibrationMode 振动模式设置）：
 * - 设备振动：直接调用 @ohos.vibrator HD Haptic API（保持最高精度）
 * - USB 手柄：通过 GamepadManager 直接发送 USB HID 报告
 */

import { vibrator } from '@kit.SensorServiceKit';
import { GamepadManager } from './input/GamepadManager';
import { RUMBLE_MAX } from './input/GamepadTypes';

export class AudioVibrationService {
  private enabled: boolean = false;
  private strength: number = 100; // 振动强度 (0-100)
  private vibrationMode: string = '自动'; // 振动路由模式
  private sceneMode: string = '游戏/电影'; // 场景模式

  // 状态
  private lastIntensity: number = 0;
  private lastLowFreqRatio: number = 50; // 低频占比 (0-100)
  private lastStereoBalance: number = 50; // 立体声平衡 (0-100, 50=居中)

  // 设备振动状态
  private hdHapticSupported: boolean | null = null;
  private isDeviceVibrating: boolean = false;

  // USB 手柄振动状态
  private isUsbRumbling: boolean = false;

  // 防抖：避免过于频繁的振动 API 调用
  private lastVibrationTime: number = 0;
  private static readonly MIN_VIBRATION_INTERVAL_MS = 20; // 游戏模式最短间隔 20ms (~50次/秒)
  private static readonly MIN_VIBRATION_INTERVAL_MUSIC_MS = 15; // 音乐模式最短间隔 15ms (~66次/秒)

  /**
   * 更新设置
   */
  setSettings(enabled: boolean, strength: number, vibrationMode: string, sceneMode: string = '游戏/电影'): void {
    this.enabled = enabled;
    this.strength = strength;
    this.vibrationMode = vibrationMode;
    this.sceneMode = sceneMode;

    if (!enabled) {
      this.stopAll();
    }
  }

  /**
   * 获取当前场景模式对应的 C++ sceneMode 整数值
   * 游戏/电影=0, 音乐/节奏=1, 自动=2
   */
  getSceneModeInt(): number {
    switch (this.sceneMode) {
      case '音乐/节奏': return 1;
      case '自动': return 2;
      case '游戏/电影':
      default: return 0;
    }
  }

  /**
   * 处理 C++ 层传来的低频能量值
   * @param intensity 低频能量强度 (0-100)
   * @param lowFreqRatio 低频占比 (0-100)，用于精确分配 low/high motor
   * @param stereoBalance 立体声平衡 (0-100)，50=居中，0=全左，100=全右
   */
  handleBassEnergy(intensity: number, lowFreqRatio: number = 50, stereoBalance: number = 50): void {
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
    const minInterval = this.isMusicScene()
      ? AudioVibrationService.MIN_VIBRATION_INTERVAL_MUSIC_MS
      : AudioVibrationService.MIN_VIBRATION_INTERVAL_MS;
    if (now - this.lastVibrationTime < minInterval) {
      return;
    }

    // 强度变化阈值（音乐模式更灵敏）
    const changeTolerance = this.isMusicScene() ? 2 : 4;
    if ((this.isDeviceVibrating || this.isUsbRumbling) &&
        Math.abs(effectiveIntensity - this.lastIntensity) < changeTolerance) {
      return;
    }

    this.lastIntensity = effectiveIntensity;
    this.lastLowFreqRatio = lowFreqRatio;
    this.lastStereoBalance = stereoBalance;
    this.lastVibrationTime = now;

    // 根据振动模式分路由
    const shouldDevice = this.shouldVibrateDevice();
    const shouldUsb = this.shouldVibrateGamepad();

    if (shouldDevice) {
      this.triggerDeviceVibration(effectiveIntensity);
    } else if (this.isDeviceVibrating) {
      this.stopDeviceVibration();
    }

    if (shouldUsb) {
      this.triggerUsbRumble(effectiveIntensity, lowFreqRatio);
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

  // ==================== 场景判断 ====================

  private isMusicScene(): boolean {
    return this.sceneMode === '音乐/节奏' || this.sceneMode === '自动';
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

  // ==================== 设备振动（场景感知） ====================

  /**
   * 根据场景模式选择不同的振动策略
   */
  private triggerDeviceVibration(intensity: number): void {
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
        if (this.sceneMode === '音乐/节奏') {
          this.triggerMusicHdHaptic(intensity);
        } else {
          this.triggerGameHdHaptic(intensity);
        }
      } else {
        if (this.sceneMode === '音乐/节奏') {
          this.triggerMusicTimeVibration(intensity);
        } else {
          this.triggerGameTimeVibration(intensity);
        }
      }
      this.isDeviceVibrating = true;
    } catch (_) {
      if (this.sceneMode === '音乐/节奏') {
        this.triggerMusicTimeVibration(intensity);
      } else {
        this.triggerGameTimeVibration(intensity);
      }
    }
  }

  // ==================== 游戏/电影模式振动 ====================

  /**
   * 游戏模式 HD Haptic: 持续低沉振动
   * 频率 30-50Hz, 持续 300ms, 强度跟随音频
   */
  private triggerGameHdHaptic(intensity: number): void {
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
        this.triggerGameTimeVibration(intensity);
      });
    } catch (_) {
      this.triggerGameTimeVibration(intensity);
    }
  }

  /**
   * 游戏模式时长振动（兼容）: 50-300ms 持续
   */
  private triggerGameTimeVibration(intensity: number): void {
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

  // ==================== 音乐/节奏模式振动 ====================

  /**
   * 音乐模式 HD Haptic: 短脉冲节拍振动
   * 频率 40-60Hz 更有弹性, 持续 60ms 尖锐脉冲, 模拟鼓点触感
   */
  private triggerMusicHdHaptic(intensity: number): void {
    try {
      const builder = new vibrator.VibratorPatternBuilder();
      // 音乐模式频率更高 (40-60Hz)，触感更有弹性/敲击感
      const frequency = Math.floor(40 + (intensity / 100) * 20); // 40-60Hz

      builder.addContinuousEvent(0, 60, {
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
        this.triggerMusicTimeVibration(intensity);
      });
    } catch (_) {
      this.triggerMusicTimeVibration(intensity);
    }
  }

  /**
   * 音乐模式时长振动（兼容）: 30-80ms 短脉冲
   */
  private triggerMusicTimeVibration(intensity: number): void {
    if (intensity < 5) return;
    // 音乐模式: 短脉冲 30-80ms，模拟鼓点
    const duration = Math.floor(30 + intensity * 0.5); // 30-80ms

    vibrator.startVibration({
      type: 'time',
      duration: duration
    }, {
      id: 0,
      usage: 'physicalFeedback'
    }).catch((_: Error) => { /* 忽略 */ });
    this.isDeviceVibrating = true;
  }

  // ==================== USB 手柄振动（场景感知） ====================

  /**
   * USB 手柄振动 — 根据实际音频频段和立体声位置分配 low/high motor
   *
   * lowFreqRatio 由 C++ 层实时计算，反映低频在总能量中的真实占比
   * stereoBalance 反映声源的左右位置:
   *   - 低频马达 (heavy) 模拟左侧，高频马达 (light) 模拟右侧
   *   - 声源偏左时增强低频马达，偏右时增强高频马达
   *   - 与 lowFreqRatio 叠加: 先按频段分配基础强度，再按空间位置微调
   */
  private triggerUsbRumble(intensity: number, lowFreqRatio: number = 50): void {
    const base = Math.floor(intensity * RUMBLE_MAX / 100);
    // 将 C++ 的低频占比 (0-100) 映射为 motor 分配比例
    // ratio=100 → 全部低频, ratio=0 → 全部高频
    // 加权平滑: 避免极端分配，至少保留 15% 给另一个 motor
    const lowWeight = Math.max(0.15, Math.min(0.85, lowFreqRatio / 100));
    const highWeight = 1.0 - lowWeight;

    let lowFreq = Math.floor(base * lowWeight);
    let highFreq = Math.floor(base * highWeight);

    // 立体声空间增强: 低频马达=左, 高频马达=右
    // balance: 0=全左, 50=居中, 100=全右
    // 偏离中心越多，空间效果越明显 (最大 ±30% 调制)
    const balance = this.lastStereoBalance;
    const deviation = (balance - 50) / 50;  // -1 ~ +1
    const spatialFactor = deviation * 0.3;  // ±30% 调制幅度
    lowFreq = Math.floor(lowFreq * (1.0 - spatialFactor));   // 左偏 → 增强
    highFreq = Math.floor(highFreq * (1.0 + spatialFactor)); // 右偏 → 增强

    // 钳位
    lowFreq = Math.max(0, Math.min(RUMBLE_MAX, lowFreq));
    highFreq = Math.max(0, Math.min(RUMBLE_MAX, highFreq));

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
    this.lastStereoBalance = 50;
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
