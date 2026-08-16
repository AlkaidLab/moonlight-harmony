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
 * DualSense 控制器驱动
 * 
 * 参考 Android moonlight-android DualSenseController
 */

import { usbManager } from '@kit.BasicServicesKit';
import { AbstractDualSenseController } from './AbstractDualSenseController';
import { UsbDriverListener } from './UsbDriverListener';
import { ButtonFlags, DualSense, DPadDirection, ControllerCapabilities } from './ControllerConstants';
import { readShortLE, TRIGGER_MAX } from '../input/GamepadTypes';

const TAG = '[USB-DS5]';

const OUTPUT_REPORT_SIZE = 48;
const OUTPUT_REPORT_ID = 0x02;
const OUTPUT_WRITE_TIMEOUT_MS = 500;
const OUTPUT_STOP_RETRY_LIMIT = 1;
const VALID_COMPATIBLE_RUMBLE = 0x01;
const VALID_DISABLE_AUDIO_HAPTICS = 0x02;
const VALID_RIGHT_TRIGGER = 0x04;
const VALID_LEFT_TRIGGER = 0x08;
const TRIGGER_EFFECT_PAYLOAD_SIZE = 10;
// DualSense's USB clear-effect command (the 0x05 mode is not the same as a
// zero-valued payload with a zero mode).
const TRIGGER_EFFECT_OFF = 0x05;
const TRIGGER_EFFECT_FEEDBACK = 0x01;

const OFFSET_VALID_FLAG0 = 1;
const OFFSET_VALID_FLAG1 = 2;
const OFFSET_RUMBLE_RIGHT = 3;
const OFFSET_RUMBLE_LEFT = 4;
const OFFSET_RIGHT_TRIGGER_TYPE = 11;
const OFFSET_RIGHT_TRIGGER_PAYLOAD = 12;
const OFFSET_LEFT_TRIGGER_TYPE = 22;
const OFFSET_LEFT_TRIGGER_PAYLOAD = 23;

export class DualSenseController extends AbstractDualSenseController {
  // DualSense output fields share one HID report. Keep motor, legacy trigger,
  // and raw adaptive-trigger state separately, then merge them when the report
  // is built. A legacy trigger update must not overwrite a raw effect that is
  // currently active; once the raw effect is turned off, the last legacy state
  // becomes effective again.
  private rumbleLow: number = 0;
  private rumbleHigh: number = 0;
  private rightLegacyTriggerEffectType: number = TRIGGER_EFFECT_OFF;
  private leftLegacyTriggerEffectType: number = TRIGGER_EFFECT_OFF;
  private rightLegacyTriggerEffect: Uint8Array = new Uint8Array(TRIGGER_EFFECT_PAYLOAD_SIZE);
  private leftLegacyTriggerEffect: Uint8Array = new Uint8Array(TRIGGER_EFFECT_PAYLOAD_SIZE);
  private rightAdaptiveTriggerEffectType: number = TRIGGER_EFFECT_OFF;
  private leftAdaptiveTriggerEffectType: number = TRIGGER_EFFECT_OFF;
  private rightAdaptiveTriggerEffect: Uint8Array = new Uint8Array(TRIGGER_EFFECT_PAYLOAD_SIZE);
  private leftAdaptiveTriggerEffect: Uint8Array = new Uint8Array(TRIGGER_EFFECT_PAYLOAD_SIZE);
  private rightAdaptiveTriggerActive: boolean = false;
  private leftAdaptiveTriggerActive: boolean = false;

  // USB writes are asynchronous. Coalesce updates that arrive while a write is
  // active, then send the latest complete state after the active write finishes.
  private outputWritePending: boolean = false;
  private outputWriteInFlight: boolean = false;
  private outputDrainPromise: Promise<void> | null = null;
  private outputStopping: boolean = false;
  private outputStopRetriesRemaining: number = 0;
  
  constructor(
    device: usbManager.USBDevice,
    pipe: usbManager.USBDevicePipe,
    deviceId: number,
    listener: UsbDriverListener
  ) {
    super(device, pipe, deviceId, listener);
    // DualSense 支持扳机震动
    this.capabilities |= ControllerCapabilities.TRIGGER_RUMBLE;
    this.deviceName = 'DualSense Controller';
  }
  
  /**
   * 检查是否可以驱动该设备
   */
  static canClaimDevice(device: usbManager.USBDevice): boolean {
    if (device.vendorId !== DualSense.VID) {
      return false;
    }
    
    if (!DualSense.PIDS.includes(device.productId)) {
      return false;
    }
    
    if (!device.configs || device.configs.length === 0) {
      return false;
    }
    
    const config = device.configs[0];
    if (!config.interfaces || config.interfaces.length === 0) {
      return false;
    }
    
    console.info(`${TAG} 检测到 DualSense 控制器: VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)}`);
    return true;
  }
  
  /**
   * 标准化摇杆轴值
   */
  private normalizeThumbStickAxis(value: number): number {
    return (2.0 * value / TRIGGER_MAX) - 1.0;
  }
  
  /**
   * 标准化扳机轴值
   */
  private normalizeTriggerAxis(value: number): number {
    return value / TRIGGER_MAX;
  }
  
  /**
   * 处理输入报告
   */
  protected handleRead(buffer: Uint8Array): boolean {
    if (buffer.length < 10) {
      console.warn(`${TAG} 数据太短: ${buffer.length}`);
      return false;
    }
    
    // DualSense USB 报告格式
    // https://controllers.fandom.com/wiki/Sony_DualSense
    
    const reportId = buffer[0];
    let offset = 1;
    
    // USB 模式报告 ID 是 0x01
    if (reportId !== 0x01) {
      return false;
    }
    
    // 摇杆 (bytes 1-4) - 不要在这里反转 Y 轴，让 GamepadManager 统一处理
    this.leftStickX = this.normalizeThumbStickAxis(buffer[offset++]);
    this.leftStickY = this.normalizeThumbStickAxis(buffer[offset++]);
    this.rightStickX = this.normalizeThumbStickAxis(buffer[offset++]);
    this.rightStickY = this.normalizeThumbStickAxis(buffer[offset++]);
    
    // 扳机 (bytes 5-6)
    this.leftTrigger = this.normalizeTriggerAxis(buffer[offset++]);
    this.rightTrigger = this.normalizeTriggerAxis(buffer[offset++]);
    
    // 计数器 (byte 7) - 跳过
    offset++;
    
    // 按钮状态 (bytes 8-10)
    const b8 = buffer[offset++];  // byte 8
    const b9 = buffer[offset++];  // byte 9
    const b10 = buffer[offset++]; // byte 10
    
    // D-Pad (byte 8 低 4 位)
    const dpad = b8 & 0x0F;
    this.setButtonFlag(ButtonFlags.UP_FLAG, 
      (dpad === DPadDirection.UP || dpad === DPadDirection.UP_RIGHT || dpad === DPadDirection.UP_LEFT) ? 1 : 0);
    this.setButtonFlag(ButtonFlags.DOWN_FLAG, 
      (dpad === DPadDirection.DOWN || dpad === DPadDirection.DOWN_RIGHT || dpad === DPadDirection.DOWN_LEFT) ? 1 : 0);
    this.setButtonFlag(ButtonFlags.LEFT_FLAG, 
      (dpad === DPadDirection.LEFT || dpad === DPadDirection.UP_LEFT || dpad === DPadDirection.DOWN_LEFT) ? 1 : 0);
    this.setButtonFlag(ButtonFlags.RIGHT_FLAG, 
      (dpad === DPadDirection.RIGHT || dpad === DPadDirection.UP_RIGHT || dpad === DPadDirection.DOWN_RIGHT) ? 1 : 0);
    
    // 面板按钮 (byte 8 高 4 位)
    this.setButtonFlag(ButtonFlags.X_FLAG, b8 & 0x10);  // Square
    this.setButtonFlag(ButtonFlags.A_FLAG, b8 & 0x20);  // Cross
    this.setButtonFlag(ButtonFlags.B_FLAG, b8 & 0x40);  // Circle
    this.setButtonFlag(ButtonFlags.Y_FLAG, b8 & 0x80);  // Triangle
    
    // 肩键和功能键 (byte 9)
    this.setButtonFlag(ButtonFlags.LB_FLAG, b9 & 0x01);  // L1
    this.setButtonFlag(ButtonFlags.RB_FLAG, b9 & 0x02);  // R1
    // L2/R2 数字按钮 (0x04, 0x08) - 我们使用模拟值
    this.setButtonFlag(ButtonFlags.BACK_FLAG, b9 & 0x10);   // Create (Share)
    this.setButtonFlag(ButtonFlags.PLAY_FLAG, b9 & 0x20);   // Options
    this.setButtonFlag(ButtonFlags.LS_CLK_FLAG, b9 & 0x40); // L3
    this.setButtonFlag(ButtonFlags.RS_CLK_FLAG, b9 & 0x80); // R3
    
    // PS 按钮和触摸板 (byte 10)
    this.setButtonFlag(ButtonFlags.SPECIAL_BUTTON_FLAG, b10 & 0x01);  // PS
    this.setButtonFlag(ButtonFlags.TOUCHPAD_FLAG, b10 & 0x02);  // Touchpad click
    this.setButtonFlag(ButtonFlags.MISC_FLAG, b10 & 0x04);  // Mute
    
    // 触摸板数据 (bytes 33-36: touch point 0)
    // DualSense touchpad resolution: 1920 x 1080
    if (buffer.length >= 37) {
      const contactByte = buffer[33];
      const isActive = (contactByte & 0x80) === 0; // bit 7 = 0 表示有手指
      this.touchpadActive = isActive;
      if (isActive) {
        this.touchpadX = buffer[34] | ((buffer[35] & 0x0F) << 8);
        this.touchpadY = ((buffer[35] & 0xF0) >> 4) | (buffer[36] << 4);
      }
    }
    
    // IMU 数据 (从 offset 开始)
    if (buffer.length >= offset + 12) {
      const GYRO_SCALE = 2000.0 / 32768.0;
      const ACCEL_SCALE = 4.0 / 32768.0;
      const G_TO_MS2 = 9.81;
      
      // 跳过一些字节到 IMU 数据位置
      // DualSense IMU 数据在不同的偏移量
      const imuOffset = 16;  // 根据实际报告格式调整
      
      if (buffer.length >= imuOffset + 12) {
const gyrox = readShortLE(buffer, imuOffset);
        const gyroy = readShortLE(buffer, imuOffset + 2);
        const gyroz = readShortLE(buffer, imuOffset + 4);

        const accelx = readShortLE(buffer, imuOffset + 6);
        const accely = readShortLE(buffer, imuOffset + 8);
        const accelz = readShortLE(buffer, imuOffset + 10);
        
        this.gyroX = gyrox * GYRO_SCALE;
        this.gyroY = gyroy * GYRO_SCALE;
        this.gyroZ = gyroz * GYRO_SCALE;
        
        this.accelX = accelx * ACCEL_SCALE * G_TO_MS2;
        this.accelY = accely * ACCEL_SCALE * G_TO_MS2;
        this.accelZ = accelz * ACCEL_SCALE * G_TO_MS2;
      }
    }
    
    return true;
  }
  
  /**
   * 获取初始化数据
   */
  protected getInitData(): Uint8Array {
    // DualSense 不需要特殊初始化
    return new Uint8Array(0);
  }
  
  /**
   * 初始化
   */
  protected doInit(): boolean {
    console.info(`${TAG} 初始化 DualSense 控制器`);
    const initData = this.getInitData();
    if (initData.length > 0) {
      this.sendCommand(initData);
    }
    return true;
  }
  
  /**
   * 震动反馈 (去重: 跳过相同非零值, 零值始终发送)
   */
  rumble(lowFreqMotor: number, highFreqMotor: number): void {
    if (this.outputStopping) return;

    const nextLow = this.rumbleToByte(lowFreqMotor);
    const nextHigh = this.rumbleToByte(highFreqMotor);

    // 零值(停止振动)始终发送, 非零重复值跳过
    if (nextLow !== 0 || nextHigh !== 0) {
      if (nextLow === this.rumbleLow && nextHigh === this.rumbleHigh) {
        return;
      }
    }
    this.rumbleLow = nextLow;
    this.rumbleHigh = nextHigh;
    this.queueOutputReport();
  }
  
  /**
   * 扳机震动反馈
   */
  rumbleTriggers(leftTrigger: number, rightTrigger: number): void {
    if (this.outputStopping) return;

    this.setLegacyTriggerRumbleState(true, this.rumbleToByte(leftTrigger));
    this.setLegacyTriggerRumbleState(false, this.rumbleToByte(rightTrigger));
    this.queueOutputReport();
  }

  /** Apply the raw DualSense type + 10-byte effect supplied by Sunshine. */
  setAdaptiveTriggers(eventFlags: number,
    leftEffectType: number, rightEffectType: number,
    leftEffect: Uint8Array, rightEffect: Uint8Array): void {
    if (this.outputStopping) return;

    let updated = false;
    if ((eventFlags & VALID_RIGHT_TRIGGER) !== 0) {
      this.rightAdaptiveTriggerEffectType = this.clampByte(rightEffectType);
      this.copyTriggerEffect(this.rightAdaptiveTriggerEffect, rightEffect);
      this.rightAdaptiveTriggerActive =
        this.rightAdaptiveTriggerEffectType !== TRIGGER_EFFECT_OFF;
      updated = true;
    }
    if ((eventFlags & VALID_LEFT_TRIGGER) !== 0) {
      this.leftAdaptiveTriggerEffectType = this.clampByte(leftEffectType);
      this.copyTriggerEffect(this.leftAdaptiveTriggerEffect, leftEffect);
      this.leftAdaptiveTriggerActive =
        this.leftAdaptiveTriggerEffectType !== TRIGGER_EFFECT_OFF;
      updated = true;
    }
    if (updated) {
      this.queueOutputReport();
    }
  }

  /** Clear legacy and raw trigger sources in a single output-state update. */
  clearTriggerEffects(): void {
    if (this.outputStopping) return;

    this.resetTriggerEffects();
    this.queueOutputReport();
  }

  /** Stop both motor and trigger feedback with one coherent device report. */
  protected async stopFeedback(): Promise<void> {
    this.outputStopping = true;
    this.outputStopRetriesRemaining = OUTPUT_STOP_RETRY_LIMIT;
    this.rumbleLow = 0;
    this.rumbleHigh = 0;
    this.resetTriggerEffects();
    this.queueOutputReport();
    await this.waitForOutputDrain();
  }

  private resetTriggerEffects(): void {
    this.setLegacyTriggerRumbleState(true, 0);
    this.setLegacyTriggerRumbleState(false, 0);
    this.clearAdaptiveTriggerState(true);
    this.clearAdaptiveTriggerState(false);
  }

  private setLegacyTriggerRumbleState(left: boolean, strength: number): void {
    const effect = left ? this.leftLegacyTriggerEffect : this.rightLegacyTriggerEffect;
    effect.fill(0);
    const effectType = strength === 0 ? TRIGGER_EFFECT_OFF : TRIGGER_EFFECT_FEEDBACK;
    if (strength !== 0) {
      effect[0] = 0; // Start position
      effect[1] = strength;
    }
    if (left) {
      this.leftLegacyTriggerEffectType = effectType;
    } else {
      this.rightLegacyTriggerEffectType = effectType;
    }
  }

  private clearAdaptiveTriggerState(left: boolean): void {
    const effect = left ? this.leftAdaptiveTriggerEffect : this.rightAdaptiveTriggerEffect;
    effect.fill(0);
    if (left) {
      this.leftAdaptiveTriggerEffectType = TRIGGER_EFFECT_OFF;
      this.leftAdaptiveTriggerActive = false;
    } else {
      this.rightAdaptiveTriggerEffectType = TRIGGER_EFFECT_OFF;
      this.rightAdaptiveTriggerActive = false;
    }
  }

  private copyTriggerEffect(target: Uint8Array, source: Uint8Array): void {
    target.fill(0);
    const length = Math.min(TRIGGER_EFFECT_PAYLOAD_SIZE, source.length);
    for (let index = 0; index < length; index++) {
      target[index] = source[index];
    }
  }

  private clampByte(value: number): number {
    if (!Number.isFinite(value)) return 0;
    return Math.max(0, Math.min(0xFF, Math.floor(value)));
  }

  private rumbleToByte(value: number): number {
    if (!Number.isFinite(value)) return 0;
    const clamped = Math.max(0, Math.min(0xFFFF, Math.floor(value)));
    return (clamped >> 8) & 0xFF;
  }

  private buildOutputReport(): Uint8Array {
    const data = new Uint8Array(OUTPUT_REPORT_SIZE);
    data[0] = OUTPUT_REPORT_ID;
    data[OFFSET_VALID_FLAG0] = VALID_COMPATIBLE_RUMBLE |
      VALID_DISABLE_AUDIO_HAPTICS | VALID_RIGHT_TRIGGER | VALID_LEFT_TRIGGER;
    // Leave validFlag1 at zero so rumble/trigger updates do not modify LEDs,
    // power saving, microphone state, or audio controls.
    data[OFFSET_VALID_FLAG1] = 0;
    data[OFFSET_RUMBLE_RIGHT] = this.rumbleHigh;
    data[OFFSET_RUMBLE_LEFT] = this.rumbleLow;
    const rightType = this.rightAdaptiveTriggerActive
      ? this.rightAdaptiveTriggerEffectType
      : this.rightLegacyTriggerEffectType;
    const leftType = this.leftAdaptiveTriggerActive
      ? this.leftAdaptiveTriggerEffectType
      : this.leftLegacyTriggerEffectType;
    const rightEffect = this.rightAdaptiveTriggerActive
      ? this.rightAdaptiveTriggerEffect
      : this.rightLegacyTriggerEffect;
    const leftEffect = this.leftAdaptiveTriggerActive
      ? this.leftAdaptiveTriggerEffect
      : this.leftLegacyTriggerEffect;
    data[OFFSET_RIGHT_TRIGGER_TYPE] = rightType;
    data[OFFSET_LEFT_TRIGGER_TYPE] = leftType;
    for (let index = 0; index < TRIGGER_EFFECT_PAYLOAD_SIZE; index++) {
      data[OFFSET_RIGHT_TRIGGER_PAYLOAD + index] = rightEffect[index];
      data[OFFSET_LEFT_TRIGGER_PAYLOAD + index] = leftEffect[index];
    }
    return data;
  }

  private queueOutputReport(): void {
    this.outputWritePending = true;
    if (!this.outputWriteInFlight) {
      this.outputDrainPromise = this.drainOutputReports();
    }
  }

  private async waitForOutputDrain(): Promise<void> {
    while (this.outputDrainPromise !== null) {
      const drain = this.outputDrainPromise;
      await drain;
    }
  }

  private async drainOutputReports(): Promise<void> {
    if (this.outputWriteInFlight) return;
    this.outputWriteInFlight = true;
    try {
      while (this.outputWritePending) {
        this.outputWritePending = false;
        const report = this.buildOutputReport();
        const stoppingReport = this.outputStopping;
        let writeSucceeded = false;
        try {
          const result = await this.bulkWrite(report, OUTPUT_WRITE_TIMEOUT_MS);
          writeSucceeded = result === report.length;
          if (!writeSucceeded) {
            console.warn(TAG + ' output report failed: expected=' +
              report.length.toString() + ', actual=' + result.toString());
          }
        } catch (writeErr) {
          console.error(TAG + ' output report exception: ' + String(writeErr));
        }
        if (!writeSucceeded && stoppingReport &&
            this.outputStopRetriesRemaining > 0) {
          this.outputStopRetriesRemaining--;
          this.outputWritePending = true;
        }
      }
    } catch (err) {
      console.error(TAG + ' output report exception: ' + String(err));
    } finally {
      this.outputWriteInFlight = false;
      this.outputDrainPromise = null;
      if (this.outputWritePending) {
        this.queueOutputReport();
      }
    }
  }
}
