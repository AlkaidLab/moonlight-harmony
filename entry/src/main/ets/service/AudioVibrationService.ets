/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2026 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { vibrator } from '@kit.SensorServiceKit';
import { GamepadManager } from './input/GamepadManager';
import { RUMBLE_MAX } from './input/GamepadTypes';

export interface AudioHapticFrame {
  flags: number;
  timestampUs: number;
  continuousAmplitude: number;
  transientAmplitude: number;
  transientDurationMs: number;
  sharpness: number;
  lowBandRatio: number;
  stereoPan: number;
  confidence: number;
  activeScene: number;
  presentationDelayMs: number;
}

/**
 * Platform renderer for the portable audio-haptics SDK IR.
 *
 * DSP and scene authoring live in the SDK. This class owns only presentation,
 * device capability fallback, user strength and device/USB routing.
 */
export class AudioVibrationService {
  private static readonly FLAG_CONTINUOUS_CHANGED: number = 1 << 0;
  private static readonly FLAG_TRANSIENT: number = 1 << 1;
  private static readonly FLAG_STOP: number = 1 << 2;
  private static readonly SCENE_MUSIC: number = 1;
  private static readonly MINIMUM_INTENSITY: number = 4;
  private static readonly TRANSIENT_MINIMUM_INTERVAL_MS: number = 12;
  private static readonly CONTINUOUS_MINIMUM_INTERVAL_MS: number = 60;
  private static readonly GAME_CONTINUOUS_LEASE_MS: number = 1000;
  private static readonly MUSIC_CONTINUOUS_LEASE_MS: number = 240;

  private enabled: boolean = false;
  private strength: number = 100;
  private vibrationMode: string = '自动';
  private sceneMode: string = '游戏/电影';

  private hdHapticSupported: boolean | null = null;
  private isDeviceVibrating: boolean = false;
  private isUsbRumbling: boolean = false;

  private currentContinuousIntensity: number = 0;
  private currentLowBandRatio: number = 50;
  private currentStereoBalance: number = 50;
  private lastSubmitTimeMs: number = 0;
  private renderEpoch: number = 0;
  private usbEffectEpoch: number = 0;

  setSettings(enabled: boolean, strength: number, vibrationMode: string,
    sceneMode: string = '游戏/电影'): void {
    this.renderEpoch++;
    this.enabled = enabled;
    this.strength = Math.max(0, Math.min(100, strength));
    this.vibrationMode = vibrationMode;
    this.sceneMode = sceneMode;
    if (!enabled) {
      this.stopAll();
    }
  }

  /**
   * SDK ABI scene: GAME=0, MUSIC=1, AUTO=2.
   * ABI v1 currently resolves AUTO to the production GAME profile.
   */
  getSceneModeInt(): number {
    switch (this.sceneMode) {
      case '音乐/节奏': return 1;
      case '自动': return 2;
      case '游戏/电影':
      default: return 0;
    }
  }

  handleHapticFrame(frame: AudioHapticFrame): void {
    if (!this.enabled) return;

    const hasStop = (frame.flags & AudioVibrationService.FLAG_STOP) !== 0;
    const hasTransient =
      (frame.flags & AudioVibrationService.FLAG_TRANSIENT) !== 0;
    if (hasStop) {
      this.renderEpoch++;
      this.stopAll();
      if (!hasTransient) return;
    }

    const epoch = this.renderEpoch;
    const delayMs = Math.max(0, Math.min(50,
      Math.round(frame.presentationDelayMs)));
    if (delayMs > 1) {
      setTimeout((): void => {
        if (this.enabled && epoch === this.renderEpoch) {
          this.renderFrame(frame);
        }
      }, delayMs);
    } else {
      this.renderFrame(frame);
    }
  }

  stop(): void {
    this.renderEpoch++;
    this.stopAll();
  }

  private renderFrame(frame: AudioHapticFrame): void {
    if (!this.enabled) return;

    const hasTransient =
      (frame.flags & AudioVibrationService.FLAG_TRANSIENT) !== 0;
    const continuousChanged =
      (frame.flags & AudioVibrationService.FLAG_CONTINUOUS_CHANGED) !== 0;
    const hasStop = (frame.flags & AudioVibrationService.FLAG_STOP) !== 0;

    if (hasStop) {
      this.stopAll();
      if (!hasTransient) return;
    }

    const strengthScale = this.strength / 100;
    const continuous = this.toIntensity(
      frame.continuousAmplitude * strengthScale);
    const transient = this.toIntensity(
      frame.transientAmplitude * strengthScale);
    const lowBandRatio = Math.max(0, Math.min(100,
      Math.round(frame.lowBandRatio * 100)));
    const stereoBalance = Math.max(0, Math.min(100,
      Math.round((frame.stereoPan + 1) * 50)));

    if (continuousChanged || hasStop) {
      this.currentContinuousIntensity = continuous;
    }
    this.currentLowBandRatio = lowBandRatio;
    this.currentStereoBalance = stereoBalance;

    const selected = hasTransient
      ? Math.max(transient, continuous)
      : continuous;
    if (selected < AudioVibrationService.MINIMUM_INTENSITY) {
      if (continuousChanged || hasStop) this.stopAll();
      return;
    }

    const now = Date.now();
    const minimumInterval = hasTransient
      ? AudioVibrationService.TRANSIENT_MINIMUM_INTERVAL_MS
      : AudioVibrationService.CONTINUOUS_MINIMUM_INTERVAL_MS;
    if (now - this.lastSubmitTimeMs < minimumInterval) return;
    this.lastSubmitTimeMs = now;

    const shouldDevice = this.shouldVibrateDevice();
    const shouldUsb = this.shouldVibrateGamepad();
    if (shouldDevice) {
      this.renderDevice(
        continuous,
        transient,
        frame.transientDurationMs,
        frame.sharpness,
        hasTransient,
        frame.activeScene
      );
    } else if (this.isDeviceVibrating) {
      this.stopDeviceVibration();
    }

    if (shouldUsb) {
      this.renderUsb(
        continuous,
        transient,
        frame.transientDurationMs,
        hasTransient,
        lowBandRatio,
        stereoBalance
      );
    } else if (this.isUsbRumbling) {
      this.stopUsbRumble();
    }
  }

  private toIntensity(amplitude: number): number {
    return Math.max(0, Math.min(100, Math.round(amplitude * 100)));
  }

  private shouldVibrateDevice(): boolean {
    switch (this.vibrationMode) {
      case '仅手柄': return false;
      case '仅设备':
      case '同时': return true;
      case '自动':
      default:
        return !GamepadManager.getInstance().hasUsbControllers();
    }
  }

  private shouldVibrateGamepad(): boolean {
    switch (this.vibrationMode) {
      case '仅手柄':
      case '同时': return true;
      case '仅设备': return false;
      case '自动':
      default:
        return GamepadManager.getInstance().hasUsbControllers();
    }
  }

  private renderDevice(continuous: number, transient: number,
    transientDurationMs: number, sharpness: number, hasTransient: boolean,
    activeScene: number): void {
    if (this.hdHapticSupported === null) {
      try {
        this.hdHapticSupported = vibrator.isHdHapticSupported();
      } catch (_) {
        this.hdHapticSupported = false;
      }
    }

    try {
      if (this.hdHapticSupported) {
        this.renderHdPattern(
          continuous,
          transient,
          transientDurationMs,
          sharpness,
          hasTransient,
          activeScene
        );
      } else {
        this.renderTimeFallback(
          continuous,
          transient,
          transientDurationMs,
          hasTransient,
          activeScene
        );
      }
      this.isDeviceVibrating = true;
    } catch (_) {
      this.renderTimeFallback(
        continuous,
        transient,
        transientDurationMs,
        hasTransient,
        activeScene
      );
    }
  }

  private renderHdPattern(continuous: number, transient: number,
    transientDurationMs: number, sharpness: number, hasTransient: boolean,
    activeScene: number): void {
    const builder = new vibrator.VibratorPatternBuilder();
    const frequency = Math.round(30 + Math.max(0, Math.min(1, sharpness)) * 40);
    let hasEvent = false;

    if (hasTransient &&
        transient >= AudioVibrationService.MINIMUM_INTENSITY) {
      builder.addTransientEvent(0, {
        intensity: transient,
        frequency: frequency,
        index: 0
      });
      hasEvent = true;
    }

    if (continuous >= AudioVibrationService.MINIMUM_INTENSITY) {
      const startMs = hasTransient
        ? Math.max(8, Math.min(35, Math.round(transientDurationMs)))
        : 0;
      const leaseMs = activeScene === AudioVibrationService.SCENE_MUSIC
        ? AudioVibrationService.MUSIC_CONTINUOUS_LEASE_MS
        : AudioVibrationService.GAME_CONTINUOUS_LEASE_MS;
      builder.addContinuousEvent(startMs, leaseMs, {
        intensity: continuous,
        frequency: Math.max(25, frequency - 8),
        index: 0
      });
      hasEvent = true;
    }

    if (!hasEvent) {
      this.stopDeviceVibration();
      return;
    }

    vibrator.startVibration({
      type: 'pattern',
      pattern: builder.build()
    }, {
      id: 0,
      usage: 'physicalFeedback'
    }).catch((_: Error): void => {
      this.renderTimeFallback(
        continuous,
        transient,
        transientDurationMs,
        hasTransient,
        activeScene
      );
    });
  }

  private renderTimeFallback(continuous: number, transient: number,
    transientDurationMs: number, hasTransient: boolean,
    activeScene: number): void {
    const selected = hasTransient
      ? Math.max(transient, continuous)
      : continuous;
    if (selected < AudioVibrationService.MINIMUM_INTENSITY) return;

    let duration: number;
    if (hasTransient) {
      const authored = Math.max(18, Math.min(100,
        Math.round(transientDurationMs)));
      duration = Math.max(15, Math.round(authored * (0.65 + selected / 285)));
    } else {
      duration = activeScene === AudioVibrationService.SCENE_MUSIC
        ? AudioVibrationService.MUSIC_CONTINUOUS_LEASE_MS
        : 500;
    }

    vibrator.startVibration({
      type: 'time',
      duration: duration
    }, {
      id: 0,
      usage: 'physicalFeedback'
    }).catch((_: Error): void => { /* best-effort fallback */ });
    this.isDeviceVibrating = true;
  }

  private renderUsb(continuous: number, transient: number,
    transientDurationMs: number, hasTransient: boolean, lowBandRatio: number,
    stereoBalance: number): void {
    const selected = hasTransient
      ? Math.max(transient, continuous)
      : continuous;
    this.submitUsbRumble(selected, lowBandRatio, stereoBalance);

    if (hasTransient) {
      const effectEpoch = ++this.usbEffectEpoch;
      const restoreDelayMs = Math.max(18, Math.min(100,
        Math.round(transientDurationMs)));
      setTimeout((): void => {
        if (!this.enabled || effectEpoch !== this.usbEffectEpoch) return;
        if (this.currentContinuousIntensity >=
            AudioVibrationService.MINIMUM_INTENSITY) {
          this.submitUsbRumble(
            this.currentContinuousIntensity,
            this.currentLowBandRatio,
            this.currentStereoBalance
          );
        } else {
          this.stopUsbRumble();
        }
      }, restoreDelayMs);
    }
  }

  private submitUsbRumble(intensity: number, lowBandRatio: number,
    stereoBalance: number): void {
    const base = Math.floor(intensity * RUMBLE_MAX / 100);
    const lowWeight = Math.max(0.15, Math.min(0.85, lowBandRatio / 100));
    const highWeight = 1 - lowWeight;
    const spatialFactor = ((stereoBalance - 50) / 50) * 0.3;

    const low = Math.max(0, Math.min(RUMBLE_MAX,
      Math.floor(base * lowWeight * (1 - spatialFactor))));
    const high = Math.max(0, Math.min(RUMBLE_MAX,
      Math.floor(base * highWeight * (1 + spatialFactor))));
    GamepadManager.getInstance().rumbleUsbControllers(0, low, high);
    this.isUsbRumbling = true;
  }

  private stopAll(): void {
    this.usbEffectEpoch++;
    if (this.isDeviceVibrating) this.stopDeviceVibration();
    if (this.isUsbRumbling) this.stopUsbRumble();
    this.currentContinuousIntensity = 0;
    this.currentLowBandRatio = 50;
    this.currentStereoBalance = 50;
  }

  private stopDeviceVibration(): void {
    try {
      vibrator.stopVibrationSync();
    } catch (_) {
      try {
        vibrator.stopVibration();
      } catch (_) { /* best effort */ }
    }
    this.isDeviceVibrating = false;
  }

  private stopUsbRumble(): void {
    GamepadManager.getInstance().rumbleUsbControllers(0, 0, 0);
    this.isUsbRumbling = false;
  }
}
