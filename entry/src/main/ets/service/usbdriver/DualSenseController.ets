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

const TAG = '[USB-DS5]';

export class DualSenseController extends AbstractDualSenseController {
  
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
    
    // 打印原始数据以调试
    const hexStr = Array.from(buffer.slice(0, Math.min(20, buffer.length)))
      .map(b => b.toString(16).padStart(2, '0')).join(' ');
    console.info(`${TAG} 收到数据 [${buffer.length}]: ${hexStr}`);
    
    // USB 模式报告 ID 是 0x01
    if (reportId !== 0x01) {
      console.info(`${TAG} 跳过非输入报告: reportId=0x${reportId.toString(16)}`);
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
    
    // IMU 数据 (从 offset 开始)
    if (buffer.length >= offset + 12) {
      const GYRO_SCALE = 2000.0 / 32768.0;
      const ACCEL_SCALE = 4.0 / 32768.0;
      const G_TO_MS2 = 9.81;
      
      // 跳过一些字节到 IMU 数据位置
      // DualSense IMU 数据在不同的偏移量
      const imuOffset = 16;  // 根据实际报告格式调整
      
      if (buffer.length >= imuOffset + 12) {
        const gyrox = this.readShortLE(buffer, imuOffset);
        const gyroy = this.readShortLE(buffer, imuOffset + 2);
        const gyroz = this.readShortLE(buffer, imuOffset + 4);
        
        const accelx = this.readShortLE(buffer, imuOffset + 6);
        const accely = this.readShortLE(buffer, imuOffset + 8);
        const accelz = this.readShortLE(buffer, imuOffset + 10);
        
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
   * 震动反馈
   */
  rumble(lowFreqMotor: number, highFreqMotor: number): void {
    // DualSense 震动命令 (USB 模式)
    const data = new Uint8Array(48);
    data[0] = 0x02;  // 报告 ID
    data[1] = 0xFF;  // 有效字段标志
    data[2] = 0xF7;  // 有效字段标志 2
    
    // 震动强度
    data[3] = (highFreqMotor >> 8) & 0xFF;  // 右马达 (高频)
    data[4] = (lowFreqMotor >> 8) & 0xFF;   // 左马达 (低频)
    
    // 扳机效果（可选，设为默认）
    data[11] = 0x00;  // 右扳机模式
    data[22] = 0x00;  // 左扳机模式
    
    // 灯光（可选）
    data[45] = 0x02;  // 玩家指示灯
    data[46] = 0x00;  // R
    data[47] = 0x00;  // G
    // data[48] = 0xFF;  // B - 超出数组范围，移除
    
    this.bulkWrite(data);
  }
  
  /**
   * 扳机震动反馈
   */
  rumbleTriggers(leftTrigger: number, rightTrigger: number): void {
    // DualSense 支持自适应扳机效果
    // 这里简化为震动模式
    const data = new Uint8Array(48);
    data[0] = 0x02;
    data[1] = 0x04;  // 只更新扳机
    data[2] = 0x00;
    
    // 右扳机效果
    data[11] = 0x01;  // 连续阻力模式
    data[12] = 0x00;  // 起始位置
    data[13] = (rightTrigger >> 8) & 0xFF;  // 强度
    
    // 左扳机效果
    data[22] = 0x01;
    data[23] = 0x00;
    data[24] = (leftTrigger >> 8) & 0xFF;
    
    this.bulkWrite(data);
  }
}
