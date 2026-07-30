/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { vibrator } from '@kit.SensorServiceKit';
import { deviceInfo } from '@kit.BasicServicesKit';

/**
 * 统一协调所有机身马达写入。
 *
 * 按键触感只使用本机默认马达，并在脉冲期间临时独占执行器。游戏和音频仍可更新
 * 来源状态，脉冲结束后通过回调恢复最新的混合输出。
 */
export class DeviceVibrationCoordinator {
  private static instance: DeviceVibrationCoordinator;

  private hdHapticSupported: boolean | null = null;
  private sourceVibratorDeviceId: number | null = null;
  private sourceVibratorId: number = 0;

  private touchHapticTimer: number = -1;
  private touchHapticActive: boolean = false;
  private touchHapticEpoch: number = 0;
  private sourceEpoch: number = 0;
  private vibrationQueue: Promise<void> = Promise.resolve();
  private sourceResumeCallback: (() => void) | null = null;

  static getInstance(): DeviceVibrationCoordinator {
    if (!DeviceVibrationCoordinator.instance) {
      DeviceVibrationCoordinator.instance = new DeviceVibrationCoordinator();
    }
    return DeviceVibrationCoordinator.instance;
  }

  setSourceResumeCallback(callback: () => void): void {
    this.sourceResumeCallback = callback;
  }

  isHdHapticSupported(): boolean {
    this.ensureSourceVibrator();
    return this.hdHapticSupported ?? false;
  }

  isTouchHapticActive(): boolean {
    return this.touchHapticActive;
  }

  playTouchHaptic(durationMs: number): void {
    const duration = Math.max(1, Math.min(1000, Math.round(durationMs)));
    const touchEpoch = ++this.touchHapticEpoch;
    this.sourceEpoch++;
    this.touchHapticActive = true;

    if (this.touchHapticTimer !== -1) {
      clearTimeout(this.touchHapticTimer);
      this.touchHapticTimer = -1;
    }
    this.enqueueVibrationRequest((): Promise<void> =>
      this.executeTouchHaptic(duration, touchEpoch));
  }

  startSourceVibration(effect: vibrator.VibrateEffect, usage: vibrator.Usage,
    onRejected?: () => void): boolean {
    if (this.isTouchHapticActive()) return false;

    const sourceEpoch = ++this.sourceEpoch;
    this.enqueueVibrationRequest((): Promise<void> =>
      this.executeSourceVibration(effect, usage, sourceEpoch, onRejected));
    return true;
  }

  stopSourceVibration(): void {
    const sourceEpoch = ++this.sourceEpoch;
    this.enqueueVibrationRequest((): Promise<void> =>
      this.executeSourceStop(sourceEpoch));
  }

  stopAll(): void {
    this.sourceEpoch++;
    this.touchHapticEpoch++;
    this.touchHapticActive = false;
    if (this.touchHapticTimer !== -1) {
      clearTimeout(this.touchHapticTimer);
      this.touchHapticTimer = -1;
    }
    this.enqueueVibrationRequest((): Promise<void> => this.stopLocalVibration());
  }

  private finishTouchHaptic(touchEpoch: number): void {
    if (touchEpoch !== this.touchHapticEpoch || !this.touchHapticActive) return;
    if (this.touchHapticTimer !== -1) {
      clearTimeout(this.touchHapticTimer);
    }
    this.touchHapticTimer = -1;
    this.touchHapticActive = false;
    this.sourceResumeCallback?.();
  }

  private enqueueVibrationRequest(request: () => Promise<void>): void {
    this.vibrationQueue = this.vibrationQueue
      .then(request)
      .catch((error: Error): void => {
        console.warn('[VIBRATION] 机身振动队列异常: ' + error.message);
      });
  }

  private executeTouchHaptic(duration: number, touchEpoch: number): Promise<void> {
    if (touchEpoch !== this.touchHapticEpoch || !this.touchHapticActive) {
      return Promise.resolve();
    }

    return this.stopLocalVibration().then((): Promise<void> => {
      if (touchEpoch !== this.touchHapticEpoch || !this.touchHapticActive) {
        return Promise.resolve();
      }

      try {
        return vibrator.startVibration({
          type: 'time',
          duration: duration
        }, this.createTouchVibrateAttribute()).then((): void => {
          if (touchEpoch !== this.touchHapticEpoch || !this.touchHapticActive) return;
          this.touchHapticTimer = setTimeout((): void => {
            this.finishTouchHaptic(touchEpoch);
          }, duration);
        }).catch((error: Error): void => {
          if (touchEpoch !== this.touchHapticEpoch || !this.touchHapticActive) return;
          console.warn('[VIBRATION] 机身按键触感失败: ' + error.message);
          this.finishTouchHaptic(touchEpoch);
        });
      } catch (error) {
        console.warn('[VIBRATION] 机身按键触感异常:', error);
        this.finishTouchHaptic(touchEpoch);
        return Promise.resolve();
      }
    });
  }

  private executeSourceVibration(effect: vibrator.VibrateEffect, usage: vibrator.Usage,
    sourceEpoch: number, onRejected?: () => void): Promise<void> {
    if (sourceEpoch !== this.sourceEpoch || this.isTouchHapticActive()) {
      return Promise.resolve();
    }

    try {
      return vibrator.startVibration(
        effect,
        this.createSourceVibrateAttribute(usage)
      ).then((): void => {
        if (sourceEpoch !== this.sourceEpoch || this.isTouchHapticActive()) return;
      }).catch((error: Error): void => {
        if (sourceEpoch !== this.sourceEpoch || this.isTouchHapticActive()) return;
        console.warn('[VIBRATION] 机身振动失败: ' + error.message);
        if (onRejected !== undefined) onRejected();
      });
    } catch (error) {
      console.warn('[VIBRATION] 机身振动异常:', error);
      if (sourceEpoch === this.sourceEpoch &&
          !this.isTouchHapticActive() &&
          onRejected !== undefined) {
        onRejected();
      }
      return Promise.resolve();
    }
  }

  private executeSourceStop(sourceEpoch: number): Promise<void> {
    if (sourceEpoch !== this.sourceEpoch || this.isTouchHapticActive()) {
      return Promise.resolve();
    }
    return this.stopLocalVibration().then((): void => {
      if (sourceEpoch !== this.sourceEpoch || this.isTouchHapticActive()) return;
    });
  }

  private stopLocalVibration(): Promise<void> {
    try {
      vibrator.stopVibrationSync();
      return Promise.resolve();
    } catch (_) {
      try {
        return vibrator.stopVibration().catch((error: Error): void => {
          console.warn('[VIBRATION] 停止机身振动失败: ' + error.message);
        });
      } catch (error) {
        console.warn('[VIBRATION] 停止机身振动异常:', error);
        return Promise.resolve();
      }
    }
  }

  private createTouchVibrateAttribute(): vibrator.VibrateAttribute {
    // 不设置 deviceId 即表示本机；id 0 与 touch 保持原有按键触感语义。
    return {
      id: 0,
      usage: 'touch'
    };
  }

  private createSourceVibrateAttribute(usage: vibrator.Usage): vibrator.VibrateAttribute {
    this.ensureSourceVibrator();
    const attribute: vibrator.VibrateAttribute = {
      id: this.sourceVibratorId,
      usage: usage
    };
    if (deviceInfo.sdkApiVersion >= 19 && this.sourceVibratorDeviceId !== null) {
      attribute.deviceId = this.sourceVibratorDeviceId;
    }
    return attribute;
  }

  private ensureSourceVibrator(): void {
    if (this.hdHapticSupported !== null) return;
    if (deviceInfo.sdkApiVersion < 18) {
      this.hdHapticSupported = false;
      return;
    }

    try {
      this.hdHapticSupported = vibrator.isHdHapticSupported();
      if (deviceInfo.sdkApiVersion >= 19) {
        const localVibrators = vibrator.getVibratorInfoSync()
          .filter((info: vibrator.VibratorInfo): boolean => info.isLocalVibrator);
        const localVibrator = localVibrators
          .find((info: vibrator.VibratorInfo): boolean => info.isHdHapticSupported) ?? localVibrators[0];
        if (localVibrator !== undefined) {
          this.sourceVibratorDeviceId = localVibrator.deviceId;
          this.sourceVibratorId = localVibrator.vibratorId;
          this.hdHapticSupported = localVibrator.isHdHapticSupported;
        }
      }
      console.info('[VIBRATION] 本地高清振动支持: ' + this.hdHapticSupported);
    } catch (error) {
      console.warn('[VIBRATION] 查询本地马达失败:', error);
      this.hdHapticSupported = false;
    }
  }
}
