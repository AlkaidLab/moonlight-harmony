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
 * DualShock 4 控制器驱动
 * 
 * 参考 Android moonlight-android Dualshock4Controller
 */

import { usbManager } from '@kit.BasicServicesKit';
import { AbstractDualSenseController } from './AbstractDualSenseController';
import { UsbDriverListener } from './UsbDriverListener';
import { ButtonFlags, DualShock4, DPadDirection, UsbClass } from './ControllerConstants';

const TAG = '[USB-DS4]';

export class Dualshock4Controller extends AbstractDualSenseController {
  
  constructor(
    device: usbManager.USBDevice,
    pipe: usbManager.USBDevicePipe,
    deviceId: number,
    listener: UsbDriverListener
  ) {
    super(device, pipe, deviceId, listener);
    this.deviceName = 'DualShock 4 Controller';
  }
  
  /**
   * 检查是否可以驱动该设备
   */
  static canClaimDevice(device: usbManager.USBDevice): boolean {
    if (device.vendorId !== DualShock4.VID) {
      return false;
    }
    
    if (!DualShock4.PIDS.includes(device.productId)) {
      return false;
    }
    
    if (!device.configs || device.configs.length === 0) {
      return false;
    }
    
    const config = device.configs[0];
    if (!config.interfaces || config.interfaces.length === 0) {
      return false;
    }
    
    console.info(`${TAG} 检测到 DualShock 4 控制器: VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)}`);
    return true;
  }
  
  /**
   * 标准化摇杆轴值
   */
  private normalizeThumbStickAxis(value: number): number {
    return (2.0 * value / 255.0) - 1.0;
  }
  
  /**
   * 标准化扳机轴值
   */
  private normalizeTriggerAxis(value: number): number {
    return value / 255.0;
  }
  
  /**
   * 读取小端序 short
   */
  private readShortLE(buffer: Uint8Array, offset: number): number {
    const value = buffer[offset] | (buffer[offset + 1] << 8);
    return value > 32767 ? value - 65536 : value;
  }
  
  /**
   * 处理输入报告
   * https://www.psdevwiki.com/ps4/DS4-USB 参考
   */
  protected handleRead(buffer: Uint8Array): boolean {
    if (buffer.length < 64) {
      console.warn(`${TAG} 数据太短: ${buffer.length}`);
      return false;
    }
    
    // 检查报告 ID
    const reportId = buffer[0];
    if (reportId !== 0x01 && reportId !== 0x11) {
      console.debug(`${TAG} 未知报告 ID: 0x${reportId.toString(16)}`);
    }
    
    // D-Pad
    const dpad = buffer[5] & 0x0F;
    this.setButtonFlag(ButtonFlags.UP_FLAG, 
      (dpad === DPadDirection.UP || dpad === DPadDirection.UP_RIGHT || dpad === DPadDirection.UP_LEFT) ? 1 : 0);
    this.setButtonFlag(ButtonFlags.DOWN_FLAG, 
      (dpad === DPadDirection.DOWN || dpad === DPadDirection.DOWN_RIGHT || dpad === DPadDirection.DOWN_LEFT) ? 1 : 0);
    this.setButtonFlag(ButtonFlags.LEFT_FLAG, 
      (dpad === DPadDirection.LEFT || dpad === DPadDirection.UP_LEFT || dpad === DPadDirection.DOWN_LEFT) ? 1 : 0);
    this.setButtonFlag(ButtonFlags.RIGHT_FLAG, 
      (dpad === DPadDirection.RIGHT || dpad === DPadDirection.UP_RIGHT || dpad === DPadDirection.DOWN_RIGHT) ? 1 : 0);
    
    // 面板按钮 (byte 5)
    const b5 = buffer[5];
    this.setButtonFlag(ButtonFlags.X_FLAG, b5 & 0x10);  // Square
    this.setButtonFlag(ButtonFlags.A_FLAG, b5 & 0x20);  // Cross
    this.setButtonFlag(ButtonFlags.B_FLAG, b5 & 0x40);  // Circle
    this.setButtonFlag(ButtonFlags.Y_FLAG, b5 & 0x80);  // Triangle
    
    // 肩键和功能键 (byte 6)
    const b6 = buffer[6];
    this.setButtonFlag(ButtonFlags.LB_FLAG, b6 & 0x01);  // L1
    this.setButtonFlag(ButtonFlags.RB_FLAG, b6 & 0x02);  // R1
    this.setButtonFlag(ButtonFlags.BACK_FLAG, b6 & 0x10);   // Share
    this.setButtonFlag(ButtonFlags.PLAY_FLAG, b6 & 0x20);   // Options
    this.setButtonFlag(ButtonFlags.LS_CLK_FLAG, b6 & 0x40); // L3
    this.setButtonFlag(ButtonFlags.RS_CLK_FLAG, b6 & 0x80); // R3
    
    // PS 按钮和触摸板 (byte 7)
    const b7 = buffer[7];
    this.setButtonFlag(ButtonFlags.SPECIAL_BUTTON_FLAG, b7 & 0x01);  // PS
    this.setButtonFlag(ButtonFlags.TOUCHPAD_FLAG, b7 & 0x02);  // Touchpad click
    
    // 摇杆 (Y 轴需要反转，因为 HID 报告中向下为正)
    this.leftStickX = this.normalizeThumbStickAxis(buffer[1]);
    this.leftStickY = -this.normalizeThumbStickAxis(buffer[2]);  // 反转 Y 轴
    this.rightStickX = this.normalizeThumbStickAxis(buffer[3]);
    this.rightStickY = -this.normalizeThumbStickAxis(buffer[4]); // 反转 Y 轴
    
    // 扳机
    this.leftTrigger = this.normalizeTriggerAxis(buffer[8]);
    this.rightTrigger = this.normalizeTriggerAxis(buffer[9]);
    
    // IMU 数据
    if (buffer.length >= 24) {
      const GYRO_SCALE = 2000.0 / 32768.0;
      const ACCEL_SCALE = 4.0 / 32768.0;
      const G_TO_MS2 = 9.81;
      
      const gyrox = this.readShortLE(buffer, 13);
      const gyroy = this.readShortLE(buffer, 15);
      const gyroz = this.readShortLE(buffer, 17);
      
      const accelx = this.readShortLE(buffer, 19);
      const accely = this.readShortLE(buffer, 21);
      const accelz = this.readShortLE(buffer, 23);
      
      this.gyroX = gyrox * GYRO_SCALE;
      this.gyroY = gyroy * GYRO_SCALE;
      this.gyroZ = gyroz * GYRO_SCALE;
      
      this.accelX = accelx * ACCEL_SCALE * G_TO_MS2;
      this.accelY = accely * ACCEL_SCALE * G_TO_MS2;
      this.accelZ = accelz * ACCEL_SCALE * G_TO_MS2;
    }
    
    return true;
  }
  
  /**
   * 获取初始化数据
   */
  protected getInitData(): Uint8Array {
    // DualShock 4 不需要特殊初始化
    return new Uint8Array(0);
  }
  
  /**
   * 初始化
   */
  protected doInit(): boolean {
    console.info(`${TAG} 初始化 DualShock 4 控制器`);
    const initData = this.getInitData();
    if (initData.length > 0) {
      this.sendCommand(initData);
    }
    return true;
  }
  
  /**
   * 震动反馈
   */
  rumble(lowFreqMotor: number, highFreqMotor: number): void {
    // DualShock 4 震动命令
    const data = new Uint8Array(32);
    data[0] = 0x05;  // 报告 ID
    data[1] = 0xFF;  // 标志
    data[4] = (highFreqMotor >> 8) & 0xFF;  // 小马达
    data[5] = (lowFreqMotor >> 8) & 0xFF;   // 大马达
    // 灯光颜色 (可选)
    data[6] = 0x00;  // R
    data[7] = 0x00;  // G
    data[8] = 0xFF;  // B (蓝色)
    
    this.bulkWrite(data);
  }
  
  /**
   * 扳机震动（DualShock 4 不支持）
   */
  rumbleTriggers(_leftTrigger: number, _rightTrigger: number): void {
    // DualShock 4 不支持扳机震动
  }
}
