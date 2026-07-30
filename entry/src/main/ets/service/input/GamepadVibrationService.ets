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
import { UsbDriverService, AbstractController } from '../usbdriver/index';
import { AudioHapticFrameFlag } from '../AudioHapticFrame';
import { RUMBLE_MAX } from './GamepadTypes';
import { DeviceVibrationCoordinator } from './DeviceVibrationCoordinator';
import {
  GAME_VIBRATION_STRENGTH_DEFAULT,
  GAME_VIBRATION_STRENGTH_ORIGINAL,
  normalizeGameVibrationStrength
} from '../../model/StreamConfig';

interface MotorPair {
  low: number;
  high: number;
}

// ==================== 震动服务 ====================

export class GamepadVibrationService {
  private static readonly MINIMUM_DEVICE_INTENSITY = 5;
  private static readonly DEVICE_RUMBLE_UPDATE_THRESHOLD = 3000;
  private static readonly GAME_DEVICE_LEASE_MS = 500;
  private static readonly AUDIO_MUSIC_LEASE_MS = 240;
  private static readonly AUDIO_GAME_LEASE_MS = 1000;
  private static readonly AUDIO_GAME_FALLBACK_DURATION_MS = 500;
  private static readonly MUSIC_SCENE = 1;
  private static readonly MUSIC_RESTART_MINIMUM_INTENSITY = 58;
  private static readonly MUSIC_RHYTHM_MINIMUM_INTENSITY = 70;
  private static readonly MUSIC_TRANSIENT_MINIMUM_INTENSITY = 72;
  private usbDriverService: UsbDriverService;
  private deviceVibrationCoordinator: DeviceVibrationCoordinator;
  
  // 设置
  private vibrationFeedbackEnabled = true;
  private gameVibrationStrength = GAME_VIBRATION_STRENGTH_DEFAULT;
  private vibrationMode = '自动';
  
  // 槽位→设备键的查找函数（由 GamepadManager 提供）
  private deviceKeyToSlotLookup: Map<string, number>;
  
  // 上次震动参数缓存（用于检测变化）
  private lastLowFreq: number = 0;
  private lastHighFreq: number = 0;
  // 震动活跃标志
  private isVibrating: boolean = false;
  // USB 振动 watchdog: 防止 USB 传输失败导致振动卡死
  private rumbleWatchdogTimer: number = -1;
  private lastRumbleControllerNumber: number = 0;
  private static readonly RUMBLE_WATCHDOG_MS = 3000;
  // USB 停止确认: 延迟重发 stop(0,0) 防止 USB 传输丢失
  private stopConfirmTimer: number = -1;

  // 游戏与音频分别保存状态，只有本服务可以写最终执行器。
  // 两路幅度使用有界 headroom 混合，避免简单相加削顶。
  private gameUsbRumble = new Map<number, MotorPair>();
  private audioUsbRumble = new Map<number, MotorPair>();
  private gameDeviceLow: number = 0;
  private gameDeviceHigh: number = 0;
  private audioDeviceContinuous: number = 0;
  private audioDeviceContinuousUntilMs: number = 0;
  private audioDeviceTransient: number = 0;
  private audioDeviceTransientDurationMs: number = 0;
  private audioDeviceSharpness: number = 0.5;
  private audioDeviceScene: number = 0;
  private deviceRenderEpoch: number = 0;

  constructor(usbDriverService: UsbDriverService, deviceKeyToSlot: Map<string, number>) {
    this.usbDriverService = usbDriverService;
    this.deviceKeyToSlotLookup = deviceKeyToSlot;
    this.deviceVibrationCoordinator = DeviceVibrationCoordinator.getInstance();
    this.deviceVibrationCoordinator.setSourceResumeCallback((): void => {
      this.renderMixedDevice(false);
    });
  }

  // ==================== 设置 ====================

  /**
   * 更新震动设置
   */
  setSettings(
    enabled: boolean,
    strength: number,
    mode: string
  ): void {
    const wasEnabled = this.vibrationFeedbackEnabled;
    const previousStrength = this.gameVibrationStrength;
    this.vibrationFeedbackEnabled = enabled;
    this.gameVibrationStrength = normalizeGameVibrationStrength(strength);
    this.vibrationMode = mode;
    if ((wasEnabled && !enabled) || (previousStrength > 0 && this.gameVibrationStrength === 0)) {
      this.stopGameSource();
    }
  }

  // ==================== 公开 API ====================

  /**
   * 处理震动反馈
   */
  handleRumble(controllerNumber: number, lowFreqMotor: number, highFreqMotor: number): void {
    // Watchdog: 防止 USB 传输失败导致振动卡死 (3s 无新回调→强制停止)
    if (this.rumbleWatchdogTimer !== -1) {
      clearTimeout(this.rumbleWatchdogTimer);
      this.rumbleWatchdogTimer = -1;
    }
    // 取消旧的 stop 确认定时器 (新命令到达, 无论零/非零都以最新为准)
    if (this.stopConfirmTimer !== -1) {
      clearTimeout(this.stopConfirmTimer);
      this.stopConfirmTimer = -1;
    }
    if (!this.vibrationFeedbackEnabled) return;

    if (lowFreqMotor !== 0 || highFreqMotor !== 0) {
      this.lastRumbleControllerNumber = controllerNumber;
      this.rumbleWatchdogTimer = setTimeout(() => {
        this.rumbleWatchdogTimer = -1;
        console.warn('[Vibration] watchdog: 3s 无回调, 强制停止振动');
        this.handleRumble(this.lastRumbleControllerNumber, 0, 0);
      }, GamepadVibrationService.RUMBLE_WATCHDOG_MS);
    }

    const controllers = this.usbDriverService.getControllers();
    const hasUsbController = controllers.length > 0;

    switch (this.vibrationMode) {
      case '仅手柄':
        if (hasUsbController) {
          this.submitGameUsbRumble(
            controllers, controllerNumber, lowFreqMotor, highFreqMotor);
        }
        break;

      case '仅设备':
        this.submitGameDeviceRumble(lowFreqMotor, highFreqMotor);
        break;

      case '同时':
        if (hasUsbController) {
          this.submitGameUsbRumble(
            controllers, controllerNumber, lowFreqMotor, highFreqMotor);
        }
        this.submitGameDeviceRumble(lowFreqMotor, highFreqMotor);
        break;

      case '自动':
      default:
        if (hasUsbController) {
          this.submitGameUsbRumble(
            controllers, controllerNumber, lowFreqMotor, highFreqMotor);
        } else {
          this.submitGameDeviceRumble(lowFreqMotor, highFreqMotor);
        }
        break;
    }

    // USB 停止确认: 100ms 后重发 stop(0,0)，防止首次 USB 传输被覆盖或丢失
    if (lowFreqMotor === 0 && highFreqMotor === 0 && hasUsbController) {
      this.scheduleUsbStopConfirm(controllerNumber);
    }
  }

  /**
   * 处理扳机震动
   */
  handleRumbleTriggers(controllerNumber: number, leftTrigger: number, rightTrigger: number): void {
    if (!this.vibrationFeedbackEnabled) return;

    const controllers = this.usbDriverService.getControllers();
    const controller = this.findControllerBySlot(controllers, controllerNumber);
    controller?.rumbleTriggers(
      this.applyGameVibrationStrength(leftTrigger),
      this.applyGameVibrationStrength(rightTrigger)
    );
  }

  /** 更新音频来源的 USB 振动；最终输出会与游戏来源混合。 */
  submitAudioUsbRumble(controllerNumber: number,
    lowFreqMotor: number, highFreqMotor: number): void {
    this.audioUsbRumble.set(controllerNumber, {
      low: this.clampRumbleValue(lowFreqMotor),
      high: this.clampRumbleValue(highFreqMotor)
    });
    const controllers = this.usbDriverService.getControllers();
    if (controllers.length > 0) {
      this.renderMixedUsb(controllers, controllerNumber);
    }
  }

  /**
   * 更新音频来源的设备触觉。游戏与音频分别保存状态并有界混合；
   * 音频 stop 不会再停止仍活跃的游戏振动。
   */
  submitAudioDeviceHaptics(continuous: number, transient: number,
    transientDurationMs: number, sharpness: number, hasTransient: boolean,
    activeScene: number, frameFlags: AudioHapticFrameFlag): void {
    this.audioDeviceContinuous = this.clampIntensity(continuous);
    this.audioDeviceContinuousUntilMs =
      this.audioDeviceContinuous >= GamepadVibrationService.MINIMUM_DEVICE_INTENSITY
        ? Date.now() + this.getAudioContinuousLeaseMs(activeScene)
        : 0;
    this.audioDeviceTransient = hasTransient
      ? this.clampIntensity(transient)
      : 0;
    this.audioDeviceTransientDurationMs = Math.max(
      0, Math.min(100, Math.round(transientDurationMs)));
    this.audioDeviceSharpness = Math.max(0, Math.min(1, sharpness));
    this.audioDeviceScene = activeScene;
    if (hasTransient &&
        activeScene === GamepadVibrationService.MUSIC_SCENE) {
      this.applyMusicTransientPolicy(frameFlags);
    }
    this.renderMixedDevice(hasTransient);
    this.audioDeviceTransient = 0;
  }

  /** 只清理音频来源，保留游戏来源。 */
  clearAudioDeviceHaptics(): void {
    this.audioDeviceContinuous = 0;
    this.audioDeviceContinuousUntilMs = 0;
    this.audioDeviceTransient = 0;
    this.renderMixedDevice(false);
  }

  /**
   * 检查是否有 USB 控制器连接
   */
  hasUsbControllers(): boolean {
    return this.usbDriverService.getControllers().length > 0;
  }

  /**
   * 停止所有震动（设备马达 + USB 控制器马达）
   */
  stopAll(): void {
    this.clearGameTimers();
    this.gameUsbRumble.clear();
    this.audioUsbRumble.clear();
    this.gameDeviceLow = 0;
    this.gameDeviceHigh = 0;
    this.audioDeviceContinuous = 0;
    this.audioDeviceContinuousUntilMs = 0;
    this.audioDeviceTransient = 0;
    this.lastLowFreq = 0;
    this.lastHighFreq = 0;

    this.deviceVibrationCoordinator.stopAll();
    this.isVibrating = false;

    try {
      const controllers = this.usbDriverService.getControllers();
      for (const controller of controllers) {
        controller.rumble(0, 0);
        controller.rumbleTriggers(0, 0);
      }
      if (controllers.length > 0) {
        this.scheduleUsbStopConfirm(this.lastRumbleControllerNumber);
      }
    } catch (_) { /* ignore */ }
  }

  /** 只清理游戏来源；音频来源仍可继续输出。 */
  private stopGameSource(): void {
    this.clearGameTimers();
    const affectedSlots = new Set<number>();
    this.gameUsbRumble.forEach((_: MotorPair, slot: number): void => {
      affectedSlots.add(slot);
    });
    this.gameUsbRumble.clear();
    this.gameDeviceLow = 0;
    this.gameDeviceHigh = 0;
    this.lastLowFreq = 0;
    this.lastHighFreq = 0;

    const controllers = this.usbDriverService.getControllers();
    affectedSlots.forEach((slot: number): void => {
      this.renderMixedUsb(controllers, slot);
    });
    for (const controller of controllers) {
      controller.rumbleTriggers(0, 0);
    }
    this.renderMixedDevice(false);
  }

  private clearGameTimers(): void {
    if (this.rumbleWatchdogTimer !== -1) {
      clearTimeout(this.rumbleWatchdogTimer);
      this.rumbleWatchdogTimer = -1;
    }
    if (this.stopConfirmTimer !== -1) {
      clearTimeout(this.stopConfirmTimer);
      this.stopConfirmTimer = -1;
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

  private submitGameUsbRumble(
    controllers: AbstractController[],
    controllerNumber: number,
    lowFreqMotor: number,
    highFreqMotor: number
  ): void {
    this.gameUsbRumble.set(controllerNumber, {
      low: this.applyGameVibrationStrength(lowFreqMotor),
      high: this.applyGameVibrationStrength(highFreqMotor)
    });
    this.renderMixedUsb(controllers, controllerNumber);
  }

  private renderMixedUsb(controllers: AbstractController[],
    controllerNumber: number): void {
    const controller = this.findControllerBySlot(controllers, controllerNumber);
    if (!controller) return;

    const game = this.gameUsbRumble.get(controllerNumber) ??
      { low: 0, high: 0 };
    const audio = this.audioUsbRumble.get(controllerNumber) ??
      { low: 0, high: 0 };
    controller.rumble(
      this.mixWithHeadroom(game.low, audio.low, RUMBLE_MAX),
      this.mixWithHeadroom(game.high, audio.high, RUMBLE_MAX)
    );
  }

  private applyGameVibrationStrength(value: number): number {
    if (value <= 0) return 0;
    if (this.gameVibrationStrength === GAME_VIBRATION_STRENGTH_DEFAULT) {
      return this.clampRumbleValue(value);
    }
    const gained = Math.floor(value * this.gameVibrationStrength / GAME_VIBRATION_STRENGTH_ORIGINAL);
    return this.clampRumbleValue(gained);
  }

  private clampRumbleValue(value: number): number {
    if (!Number.isFinite(value)) return 0;
    return Math.max(0, Math.min(RUMBLE_MAX, Math.floor(value)));
  }

  private clampIntensity(value: number): number {
    if (!Number.isFinite(value)) return 0;
    return Math.max(0, Math.min(100, Math.round(value)));
  }

  /**
   * 有界概率和：a + b - a*b/max。
   * 该公式保留任一路单独输出，并避免两路叠加发生硬削顶。
   */
  private mixWithHeadroom(first: number, second: number,
    maximum: number): number {
    const safeFirst = Math.max(0, Math.min(maximum, first));
    const safeSecond = Math.max(0, Math.min(maximum, second));
    return Math.max(0, Math.min(maximum, Math.round(
      safeFirst + safeSecond * (maximum - safeFirst) / maximum)));
  }

  private scheduleUsbStopConfirm(controllerNumber: number): void {
    this.stopConfirmTimer = setTimeout(() => {
      this.stopConfirmTimer = -1;
      const controllers = this.usbDriverService.getControllers();
      this.renderMixedUsb(controllers, controllerNumber);
    }, 100);
  }

  /** 更新游戏来源的设备振动，并交给统一输出器混合。 */
  private submitGameDeviceRumble(lowFreqMotor: number, highFreqMotor: number): void {
    if (!this.vibrationFeedbackEnabled || this.gameVibrationStrength <= 0) return;

    if (lowFreqMotor === 0 && highFreqMotor === 0) {
      this.gameDeviceLow = 0;
      this.gameDeviceHigh = 0;
      this.lastLowFreq = 0;
      this.lastHighFreq = 0;
      this.renderMixedDevice(false);
      return;
    }

    const lowDelta = Math.abs(lowFreqMotor - this.lastLowFreq);
    const highDelta = Math.abs(highFreqMotor - this.lastHighFreq);
    const gameWasActive =
      this.gameDeviceLow > 0 || this.gameDeviceHigh > 0;
    if (gameWasActive &&
        lowDelta < GamepadVibrationService.DEVICE_RUMBLE_UPDATE_THRESHOLD &&
        highDelta < GamepadVibrationService.DEVICE_RUMBLE_UPDATE_THRESHOLD) {
      return;  // 变化太小，不更新
    }

    this.lastLowFreq = lowFreqMotor;
    this.lastHighFreq = highFreqMotor;
    this.gameDeviceLow = lowFreqMotor;
    this.gameDeviceHigh = highFreqMotor;
    this.renderMixedDevice(false);
  }

  private renderMixedDevice(hasAudioTransient: boolean): void {
    const renderEpoch = ++this.deviceRenderEpoch;
    const userStrength = Math.min(this.gameVibrationStrength, GAME_VIBRATION_STRENGTH_ORIGINAL) /
      GAME_VIBRATION_STRENGTH_ORIGINAL;
    const lowIntensity = this.clampIntensity(
      this.gameDeviceLow / RUMBLE_MAX * userStrength * 100);
    const highIntensity = this.clampIntensity(
      this.gameDeviceHigh / RUMBLE_MAX * userStrength * 100);
    const gameIntensity = Math.max(lowIntensity, highIntensity);
    const audioContinuous =
      Date.now() <= this.audioDeviceContinuousUntilMs
        ? this.audioDeviceContinuous
        : 0;
    const mixedContinuous = this.mixWithHeadroom(
      gameIntensity, audioContinuous, 100);
    const mixedTransient = hasAudioTransient
      ? this.mixWithHeadroom(
        gameIntensity, this.audioDeviceTransient, 100)
      : 0;

    if (this.deviceVibrationCoordinator.isTouchHapticActive()) return;

    const hdHapticSupported = this.deviceVibrationCoordinator.isHdHapticSupported();
    const minimumTransientIntensity = hdHapticSupported
      ? 1
      : GamepadVibrationService.MINIMUM_DEVICE_INTENSITY;
    if (mixedContinuous < GamepadVibrationService.MINIMUM_DEVICE_INTENSITY &&
        (!hasAudioTransient ||
         mixedTransient < minimumTransientIntensity)) {
      if (this.isVibrating) this.stopVibrationImmediate();
      return;
    }

    try {
      if (hdHapticSupported) {
        this.triggerMixedPattern(
          lowIntensity,
          highIntensity,
          mixedContinuous,
          mixedTransient,
          hasAudioTransient,
          renderEpoch
        );
      } else {
        this.triggerMixedTimeFallback(
          mixedContinuous, mixedTransient, hasAudioTransient, renderEpoch);
      }
      this.isVibrating = true;
    } catch (err) {
      console.warn(`[VIBRATION] 设备震动异常: ${err}`);
      this.triggerMixedTimeFallback(
        mixedContinuous, mixedTransient, hasAudioTransient, renderEpoch);
    }
  }

  /**
   * 立即停止震动（同步方式）
   */
  private stopVibrationImmediate(): void {
    this.deviceRenderEpoch++;
    this.deviceVibrationCoordinator.stopSourceVibration();
    this.isVibrating = false;
  }

  private triggerMixedPattern(lowIntensity: number, highIntensity: number,
    mixedContinuous: number, mixedTransient: number,
    hasAudioTransient: boolean, renderEpoch: number): void {
    const hasContinuous =
      mixedContinuous >= GamepadVibrationService.MINIMUM_DEVICE_INTENSITY;
    const hasTransient = hasAudioTransient &&
      mixedTransient > 0;

    const gameActive = Math.max(lowIntensity, highIntensity) > 0;
    const builder = new vibrator.VibratorPatternBuilder();
    const audioFrequency = Math.round(
      30 + this.audioDeviceSharpness * 40);
    if (hasTransient) {
      builder.addTransientEvent(0, {
        intensity: mixedTransient,
        frequency: audioFrequency,
        index: 0
      });
    }

    if (hasContinuous) {
      const gameFrequency = this.getGameDeviceFrequency(
        lowIntensity, highIntensity);
      const frequency = Math.max(25,
        Math.round(Math.max(lowIntensity, highIntensity) > 0
          ? gameFrequency
          : audioFrequency - 8));
      const startMs = hasTransient
        ? Math.max(8, Math.min(35, this.audioDeviceTransientDurationMs))
        : 0;
      const leaseMs = gameActive
        ? GamepadVibrationService.GAME_DEVICE_LEASE_MS
        : this.getAudioContinuousLeaseMs(this.audioDeviceScene);
      if (gameActive) {
        builder.addContinuousEvent(startMs, leaseMs, {
          intensity: mixedContinuous,
          frequency: frequency,
          index: 0
        });
      } else {
        builder.addContinuousEvent(startMs, leaseMs, {
          intensity: mixedContinuous,
          frequency: frequency,
          points: this.createAudioEnvelope(leaseMs, hasTransient),
          index: 0
        });
      }
    }

    this.deviceVibrationCoordinator.startSourceVibration({
      type: 'pattern',
      pattern: builder.build()
    }, gameActive ? 'physicalFeedback' : 'media', (): void => {
      this.triggerMixedTimeFallback(
        mixedContinuous, mixedTransient, hasAudioTransient, renderEpoch);
    });
  }

  private createAudioEnvelope(durationMs: number,
    followsTransient: boolean): vibrator.VibratorCurvePoint[] {
    const attackMs = Math.max(4, Math.min(12,
      Math.round(durationMs * 0.06)));
    const sustainMs = Math.max(attackMs + 1,
      Math.round(durationMs * 0.55));
    return [
      {
        time: 0,
        intensity: followsTransient ? 0.78 : 0.25,
        frequency: followsTransient ? -2 : -5
      },
      { time: attackMs, intensity: 1.0, frequency: 0 },
      { time: sustainMs, intensity: 0.68, frequency: -5 },
      { time: durationMs, intensity: 0, frequency: -12 }
    ];
  }

  private getGameDeviceFrequency(lowIntensity: number,
    highIntensity: number): number {
    if (lowIntensity > 0 && highIntensity > 0) {
      const ratio = highIntensity / (lowIntensity + highIntensity);
      return Math.floor(30 + ratio * 50);
    }
    return lowIntensity > 0 ? 35 : 70;
  }

  private triggerMixedTimeFallback(mixedContinuous: number,
    mixedTransient: number, hasAudioTransient: boolean,
    renderEpoch: number): void {
    if (renderEpoch !== this.deviceRenderEpoch) return;
    const selected = hasAudioTransient
      ? Math.max(mixedTransient, mixedContinuous)
      : mixedContinuous;
    let duration: number;
    if (hasAudioTransient) {
      const authored = Math.max(
        18, Math.min(100, this.audioDeviceTransientDurationMs));
      duration = Math.max(
        15, Math.round(authored * (0.65 + selected / 285)));
    } else if (this.gameDeviceLow > 0 || this.gameDeviceHigh > 0) {
      duration = GamepadVibrationService.GAME_DEVICE_LEASE_MS;
    } else {
      duration = this.audioDeviceScene === GamepadVibrationService.MUSIC_SCENE
        ? GamepadVibrationService.AUDIO_MUSIC_LEASE_MS
        : GamepadVibrationService.AUDIO_GAME_FALLBACK_DURATION_MS;
    }

    const gameActive = this.gameDeviceLow > 0 || this.gameDeviceHigh > 0;
    this.deviceVibrationCoordinator.startSourceVibration({
      type: 'time',
      duration: duration
    }, gameActive ? 'physicalFeedback' : 'media');
  }

  private getAudioContinuousLeaseMs(scene: number): number {
    return scene === GamepadVibrationService.MUSIC_SCENE
      ? GamepadVibrationService.AUDIO_MUSIC_LEASE_MS
      : GamepadVibrationService.AUDIO_GAME_LEASE_MS;
  }

  /**
   * 对齐 Android 渲染器的音乐瞬态策略。高清马达保留创作幅度并缩短事件；
   * 时长回退马达需要更高的幅度下限与稍长脉冲，才能稳定感知弱节拍。
   */
  private applyMusicTransientPolicy(frameFlags: AudioHapticFrameFlag): void {
    if (this.deviceVibrationCoordinator.isHdHapticSupported()) {
      this.audioDeviceTransientDurationMs = Math.round(Math.max(
        28, Math.min(34, this.audioDeviceTransientDurationMs * 0.58)));
      return;
    }

    const predicted =
      (frameFlags & AudioHapticFrameFlag.RHYTHM_PREDICTED) !== 0;
    const restart =
      (frameFlags & AudioHapticFrameFlag.MUSIC_RESTART) !== 0;
    const minimumIntensity = restart
      ? GamepadVibrationService.MUSIC_RESTART_MINIMUM_INTENSITY
      : (predicted
        ? GamepadVibrationService.MUSIC_RHYTHM_MINIMUM_INTENSITY
        : GamepadVibrationService.MUSIC_TRANSIENT_MINIMUM_INTENSITY);
    if (this.audioDeviceTransient > 0) {
      this.audioDeviceTransient = Math.max(
        this.audioDeviceTransient, minimumIntensity);
    }

    // Match the SDK Android device policy: restart lowers the amplitude floor;
    // rhythm prediction still owns duration when both flags are present.
    const durationScale = predicted ? 0.75 : 0.78;
    const minimumDurationMs = predicted ? 36 : 40;
    const maximumDurationMs = predicted ? 42 : 46;
    this.audioDeviceTransientDurationMs = Math.round(Math.max(
      minimumDurationMs,
      Math.min(maximumDurationMs,
        this.audioDeviceTransientDurationMs * durationScale)));
  }

}
