/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import {
  DS5_HAPTICS_IR_FLAG_SILENT,
  DS5_HAPTICS_IR_FLAG_STREAM_END,
  Ds5HapticsIrV2Frame
} from '../streaming/MoonBridge';
import { TouchMode } from '../../viewmodel/StreamViewModel';

/**
 * Session-scoped automatic touch mode policy.
 *
 * IR v2 has an explicit end flag but no start flag. A short run of non-silent
 * frames is therefore used as the start confirmation. The caller owns the
 * actual mode switch so this class remains deterministic and testable.
 */
export class TouchModeAutoSwitch {
  static readonly ENTER_CONFIRM_FRAMES: number = 3;
  static readonly EXIT_DELAY_MS: number = 1500;
  static readonly SWITCH_COOLDOWN_MS: number = 2500;

  private enabled: boolean = false;
  private manualLocked: boolean = false;
  private confirmedActive: boolean = false;
  private candidateFrames: number = 0;
  private returnMode: TouchMode = TouchMode.MOUSE;
  private lastSwitchAt: number = 0;
  private exitTimer: number = -1;
  private onSwitch: ((mode: TouchMode) => void) | null = null;

  setSwitchCallback(callback: ((mode: TouchMode) => void) | null): void {
    this.onSwitch = callback;
  }

  configure(enabled: boolean): void {
    this.enabled = enabled;
    this.reset();
  }

  setReturnMode(mode: TouchMode): void {
    if (mode === TouchMode.MOUSE || mode === TouchMode.TRACKPAD || mode === TouchMode.DIRECT) {
      this.returnMode = mode;
    }
  }

  noteManualOverride(): void {
    if (!this.enabled) return;
    this.manualLocked = true;
    this.cancelExitTimer();
    this.candidateFrames = 0;
  }

  reset(): void {
    this.cancelExitTimer();
    this.manualLocked = false;
    this.confirmedActive = false;
    this.candidateFrames = 0;
    this.lastSwitchAt = 0;
  }

  disableForSession(): void {
    this.enabled = false;
    this.reset();
  }

  handleFrame(frame: Ds5HapticsIrV2Frame): void {
    if (!this.enabled || this.manualLocked || frame.controllerNumber !== 0) return;

    const now = Date.now();
    if ((frame.flags & DS5_HAPTICS_IR_FLAG_STREAM_END) !== 0) {
      this.candidateFrames = 0;
      this.scheduleExit(now);
      return;
    }

    // SILENT is an explicit idle boundary. Keep an already scheduled exit so
    // a stream-end followed by silent keep-alive frames still restores input.
    if ((frame.flags & DS5_HAPTICS_IR_FLAG_SILENT) !== 0) {
      this.candidateFrames = 0;
      return;
    }
    this.cancelExitTimer();
    if (this.confirmedActive) return;

    this.candidateFrames++;
    if (this.candidateFrames < TouchModeAutoSwitch.ENTER_CONFIRM_FRAMES) return;
    if (now - this.lastSwitchAt < TouchModeAutoSwitch.SWITCH_COOLDOWN_MS) return;

    this.confirmedActive = true;
    this.lastSwitchAt = now;
    this.emitSwitch(TouchMode.DS5_TOUCHPAD_ZONE);
  }

  private scheduleExit(now: number): void {
    if (!this.confirmedActive || this.manualLocked) return;
    this.cancelExitTimer();
    const cooldownRemaining = Math.max(
      0,
      this.lastSwitchAt + TouchModeAutoSwitch.SWITCH_COOLDOWN_MS - now
    );
    const delay = Math.max(TouchModeAutoSwitch.EXIT_DELAY_MS, cooldownRemaining);
    this.exitTimer = setTimeout(() => {
      this.exitTimer = -1;
      if (!this.confirmedActive || this.manualLocked) return;
      this.confirmedActive = false;
      this.candidateFrames = 0;
      this.lastSwitchAt = Date.now();
      this.emitSwitch(this.returnMode);
    }, delay);
  }

  private emitSwitch(mode: TouchMode): void {
    if (this.onSwitch) this.onSwitch(mode);
  }

  private cancelExitTimer(): void {
    if (this.exitTimer !== -1) {
      clearTimeout(this.exitTimer);
      this.exitTimer = -1;
    }
  }
}
