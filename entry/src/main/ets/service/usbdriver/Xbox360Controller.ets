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
 * Xbox 360 控制器驱动
 * 
 * 参考 Android moonlight-android Xbox360Controller
 */

import { usbManager } from '@kit.BasicServicesKit';
import { AbstractXboxController } from './AbstractXboxController';
import { UsbDriverListener } from './UsbDriverListener';
import { ButtonFlags, Xbox360, UsbClass } from './ControllerConstants';

const TAG = '[USB-X360]';

export class Xbox360Controller extends AbstractXboxController {
  
  constructor(
    device: usbManager.USBDevice,
    pipe: usbManager.USBDevicePipe,
    deviceId: number,
    listener: UsbDriverListener
  ) {
    super(device, pipe, deviceId, listener);
    this.deviceName = 'Xbox 360 Controller';
  }
  
  /**
   * 检查是否可以驱动该设备
   */
  static canClaimDevice(device: usbManager.USBDevice): boolean {
    // 检查厂商 ID
    if (!Xbox360.SUPPORTED_VENDORS.includes(device.vendorId)) {
      return false;
    }
    
    // 检查接口
    if (!device.configs || device.configs.length === 0) {
      return false;
    }
    
    const config = device.configs[0];
    if (!config.interfaces || config.interfaces.length === 0) {
      return false;
    }
    
    const iface = config.interfaces[0];
    
    // 检查接口类、子类、协议
    const isXbox360 = 
      iface.clazz === UsbClass.USB_CLASS_VENDOR_SPEC &&
      iface.subClass === Xbox360.IFACE_SUBCLASS &&
      iface.protocol === Xbox360.IFACE_PROTOCOL;
    
    if (isXbox360) {
      console.info(`${TAG} 检测到 Xbox 360 控制器: VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)}`);
    }
    
    return isXbox360;
  }
  
  /**
   * 无符号字节转换
   */
  private unsignByte(b: number): number {
    return b & 0xFF;
  }
  
  /**
   * 读取小端序 short
   */
  private readShortLE(buffer: Uint8Array, offset: number): number {
    const value = buffer[offset] | (buffer[offset + 1] << 8);
    // 转换为有符号 short
    return value > 32767 ? value - 65536 : value;
  }
  
  /**
   * 处理输入报告
   */
  protected handleRead(buffer: Uint8Array): boolean {
    if (buffer.length < 14) {
      console.warn(`${TAG} 读取数据太短: ${buffer.length}`);
      return false;
    }
    
    // 跳过前两个字节（报告 ID 和长度）
    let offset = 2;
    
    // D-Pad 和 Start/Select
    const b = buffer[offset++];
    this.setButtonFlag(ButtonFlags.LEFT_FLAG, b & 0x04);
    this.setButtonFlag(ButtonFlags.RIGHT_FLAG, b & 0x08);
    this.setButtonFlag(ButtonFlags.UP_FLAG, b & 0x01);
    this.setButtonFlag(ButtonFlags.DOWN_FLAG, b & 0x02);
    this.setButtonFlag(ButtonFlags.PLAY_FLAG, b & 0x10);
    this.setButtonFlag(ButtonFlags.BACK_FLAG, b & 0x20);
    this.setButtonFlag(ButtonFlags.LS_CLK_FLAG, b & 0x40);
    this.setButtonFlag(ButtonFlags.RS_CLK_FLAG, b & 0x80);
    
    // ABXY 和 LB/RB
    const b2 = buffer[offset++];
    this.setButtonFlag(ButtonFlags.A_FLAG, b2 & 0x10);
    this.setButtonFlag(ButtonFlags.B_FLAG, b2 & 0x20);
    this.setButtonFlag(ButtonFlags.X_FLAG, b2 & 0x40);
    this.setButtonFlag(ButtonFlags.Y_FLAG, b2 & 0x80);
    this.setButtonFlag(ButtonFlags.LB_FLAG, b2 & 0x01);
    this.setButtonFlag(ButtonFlags.RB_FLAG, b2 & 0x02);
    this.setButtonFlag(ButtonFlags.SPECIAL_BUTTON_FLAG, b2 & 0x04);
    
    // 扳机 (0-255 -> 0.0-1.0)
    this.leftTrigger = this.unsignByte(buffer[offset++]) / 255.0;
    this.rightTrigger = this.unsignByte(buffer[offset++]) / 255.0;
    
    // 左摇杆 (-32768 到 32767 -> -1.0 到 1.0)
    // Y 轴使用 -value 来反转 (不使用 ~ 因为 JavaScript 的 ~ 作用于 32 位整数)
    this.leftStickX = this.readShortLE(buffer, offset) / 32767.0;
    offset += 2;
    this.leftStickY = -this.readShortLE(buffer, offset) / 32767.0;
    offset += 2;
    
    // 右摇杆
    this.rightStickX = this.readShortLE(buffer, offset) / 32767.0;
    offset += 2;
    this.rightStickY = -this.readShortLE(buffer, offset) / 32767.0;
    
    return true;
  }
  
  /**
   * 发送 LED 命令
   */
  private async sendLedCommand(command: number): Promise<boolean> {
    const commandBuffer = new Uint8Array([0x01, 0x03, command]);
    
    const res = await this.bulkWrite(commandBuffer);
    if (res !== commandBuffer.length) {
      console.warn(`${TAG} LED 设置失败: ${res}`);
      return false;
    }
    
    return true;
  }
  
  /**
   * 初始化
   */
  protected doInit(): boolean {
    // 设置 LED 显示控制器编号
    this.sendLedCommand(2 + (this.getControllerId() % 4));
    
    // LED 命令失败不影响初始化
    return true;
  }
  
  /**
   * 震动反馈
   */
  rumble(lowFreqMotor: number, highFreqMotor: number): void {
    const data = new Uint8Array([
      0x00, 0x08, 0x00,
      (lowFreqMotor >> 8) & 0xFF,   // 低频马达 (大马达)
      (highFreqMotor >> 8) & 0xFF,  // 高频马达 (小马达)
      0x00, 0x00, 0x00
    ]);
    
    this.bulkWrite(data);
  }
  
  /**
   * 扳机震动（Xbox 360 不支持）
   */
  rumbleTriggers(_leftTrigger: number, _rightTrigger: number): void {
    // Xbox 360 控制器不支持扳机震动
  }
}
