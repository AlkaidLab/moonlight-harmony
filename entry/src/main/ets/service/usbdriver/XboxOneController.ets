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
 * Xbox One 控制器驱动
 * 
 * 参考 Android moonlight-android XboxOneController
 */

import { usbManager } from '@kit.BasicServicesKit';
import { AbstractXboxController } from './AbstractXboxController';
import { UsbDriverListener } from './UsbDriverListener';
import { ButtonFlags, XboxOne, UsbClass, ControllerCapabilities } from './ControllerConstants';

const TAG = '[USB-XONE]';

// 初始化数据包
const FW2015_INIT = new Uint8Array([0x05, 0x20, 0x00, 0x01, 0x00]);
const ONE_S_INIT = new Uint8Array([0x05, 0x20, 0x00, 0x0f, 0x06]);
const SERIES_S_INIT = new Uint8Array([0x05, 0x20, 0x00, 0x0f, 0x06]);
const HORI_INIT = new Uint8Array([
  0x01, 0x20, 0x00, 0x09, 0x00, 0x04, 0x20, 0x3a,
  0x00, 0x00, 0x00, 0x80, 0x00
]);
const PDP_INIT1 = new Uint8Array([0x0a, 0x20, 0x00, 0x03, 0x00, 0x01, 0x14]);
const PDP_INIT2 = new Uint8Array([0x06, 0x20, 0x00, 0x02, 0x01, 0x00]);
const RUMBLE_INIT1 = new Uint8Array([
  0x09, 0x00, 0x00, 0x09, 0x00, 0x0F, 0x00, 0x00,
  0x1D, 0x1D, 0xFF, 0x00, 0x00
]);
const RUMBLE_INIT2 = new Uint8Array([
  0x09, 0x00, 0x00, 0x09, 0x00, 0x0F, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00
]);

interface InitPacket {
  vid: number;
  pid: number;
  data: Uint8Array;
}

const INIT_PKTS: InitPacket[] = [
  { vid: 0x0e6f, pid: 0x0165, data: HORI_INIT },
  { vid: 0x0f0d, pid: 0x0067, data: HORI_INIT },
  { vid: 0x0000, pid: 0x0000, data: FW2015_INIT },
  { vid: 0x045e, pid: 0x02ea, data: ONE_S_INIT },
  { vid: 0x045e, pid: 0x0b00, data: ONE_S_INIT },
  { vid: 0x045e, pid: 0x0b05, data: SERIES_S_INIT },
  { vid: 0x045e, pid: 0x0b12, data: SERIES_S_INIT },
  { vid: 0x045e, pid: 0x0b13, data: SERIES_S_INIT },
  { vid: 0x0e6f, pid: 0x0000, data: PDP_INIT1 },
  { vid: 0x0e6f, pid: 0x0000, data: PDP_INIT2 },
  { vid: 0x24c6, pid: 0x541a, data: RUMBLE_INIT1 },
  { vid: 0x24c6, pid: 0x542a, data: RUMBLE_INIT1 },
  { vid: 0x24c6, pid: 0x543a, data: RUMBLE_INIT1 },
  { vid: 0x24c6, pid: 0x541a, data: RUMBLE_INIT2 },
  { vid: 0x24c6, pid: 0x542a, data: RUMBLE_INIT2 },
  { vid: 0x24c6, pid: 0x543a, data: RUMBLE_INIT2 },
];

export class XboxOneController extends AbstractXboxController {
  private seqNum: number = 0;
  private lowFreqMotor: number = 0;
  private highFreqMotor: number = 0;
  private leftTriggerMotor: number = 0;
  private rightTriggerMotor: number = 0;
  
  constructor(
    device: usbManager.USBDevice,
    pipe: usbManager.USBDevicePipe,
    deviceId: number,
    listener: UsbDriverListener
  ) {
    super(device, pipe, deviceId, listener);
    this.capabilities |= ControllerCapabilities.TRIGGER_RUMBLE;
    this.deviceName = 'Xbox One Controller';
  }
  
  /**
   * 检查是否可以驱动该设备
   */
  static canClaimDevice(device: usbManager.USBDevice): boolean {
    // 检查厂商 ID
    if (!XboxOne.SUPPORTED_VENDORS.includes(device.vendorId)) {
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
    const isXboxOne = 
      iface.clazz === UsbClass.USB_CLASS_VENDOR_SPEC &&
      iface.subClass === XboxOne.IFACE_SUBCLASS &&
      iface.protocol === XboxOne.IFACE_PROTOCOL;
    
    if (isXboxOne) {
      console.info(`${TAG} 检测到 Xbox One 控制器: VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)}`);
    }
    
    return isXboxOne;
  }
  
  /**
   * 读取小端序 short
   */
  private readShortLE(buffer: Uint8Array, offset: number): number {
    const value = buffer[offset] | (buffer[offset + 1] << 8);
    return value > 32767 ? value - 65536 : value;
  }
  
  /**
   * 处理按钮数据
   */
  private processButtons(buffer: Uint8Array, offset: number): void {
    let b = buffer[offset++];
    
    this.setButtonFlag(ButtonFlags.PLAY_FLAG, b & 0x04);
    this.setButtonFlag(ButtonFlags.BACK_FLAG, b & 0x08);
    this.setButtonFlag(ButtonFlags.A_FLAG, b & 0x10);
    this.setButtonFlag(ButtonFlags.B_FLAG, b & 0x20);
    this.setButtonFlag(ButtonFlags.X_FLAG, b & 0x40);
    this.setButtonFlag(ButtonFlags.Y_FLAG, b & 0x80);
    
    b = buffer[offset++];
    this.setButtonFlag(ButtonFlags.LEFT_FLAG, b & 0x04);
    this.setButtonFlag(ButtonFlags.RIGHT_FLAG, b & 0x08);
    this.setButtonFlag(ButtonFlags.UP_FLAG, b & 0x01);
    this.setButtonFlag(ButtonFlags.DOWN_FLAG, b & 0x02);
    this.setButtonFlag(ButtonFlags.LB_FLAG, b & 0x10);
    this.setButtonFlag(ButtonFlags.RB_FLAG, b & 0x20);
    this.setButtonFlag(ButtonFlags.LS_CLK_FLAG, b & 0x40);
    this.setButtonFlag(ButtonFlags.RS_CLK_FLAG, b & 0x80);
    
    // 扳机 (0-1023 -> 0.0-1.0)
    this.leftTrigger = this.readShortLE(buffer, offset) / 1023.0;
    offset += 2;
    this.rightTrigger = this.readShortLE(buffer, offset) / 1023.0;
    offset += 2;
    
    // 摇杆 (Y 轴需要取反，使用 -value 而不是 ~value 避免 JavaScript 32位整数问题)
    this.leftStickX = this.readShortLE(buffer, offset) / 32767.0;
    offset += 2;
    this.leftStickY = -this.readShortLE(buffer, offset) / 32767.0;
    offset += 2;
    
    this.rightStickX = this.readShortLE(buffer, offset) / 32767.0;
    offset += 2;
    this.rightStickY = -this.readShortLE(buffer, offset) / 32767.0;
  }
  
  /**
   * 确认模式报告
   */
  private async ackModeReport(seqNum: number): Promise<void> {
    const payload = new Uint8Array([
      0x01, 0x20, seqNum, 0x09, 0x00, 0x07, 0x20, 0x02,
      0x00, 0x00, 0x00, 0x00, 0x00
    ]);
    await this.bulkWrite(payload);
  }
  
  /**
   * 处理输入报告
   */
  protected handleRead(buffer: Uint8Array): boolean {
    if (buffer.length === 0) {
      return false;
    }
    
    switch (buffer[0]) {
      case 0x20: // 按钮/轴报告
        if (buffer.length < 18) {
          console.warn(`${TAG} 按钮/轴报告太短: ${buffer.length}`);
          return false;
        }
        this.processButtons(buffer, 4);
        return true;
        
      case 0x07: // 模式报告
        if (buffer.length < 5) {
          console.warn(`${TAG} 模式报告太短: ${buffer.length}`);
          return false;
        }
        // Xbox One S 控制器需要确认模式报告
        if (buffer[1] === 0x30) {
          this.ackModeReport(buffer[2]);
        }
        this.setButtonFlag(ButtonFlags.SPECIAL_BUTTON_FLAG, buffer[4] & 0x01);
        return true;
    }
    
    return false;
  }
  
  /**
   * 初始化
   */
  protected doInit(): boolean {
    console.info(`${TAG} 初始化 Xbox One 控制器`);
    
    // 发送初始化数据包
    for (const initPkt of INIT_PKTS) {
      // 匹配 VID/PID (0x0000 表示通配符)
      if ((initPkt.vid === 0 || initPkt.vid === this.vendorId) &&
          (initPkt.pid === 0 || initPkt.pid === this.productId)) {
        this.bulkWrite(initPkt.data);
      }
    }
    
    return true;
  }
  
  /**
   * 震动反馈
   */
  rumble(lowFreqMotor: number, highFreqMotor: number): void {
    this.lowFreqMotor = lowFreqMotor;
    this.highFreqMotor = highFreqMotor;
    this.sendRumble();
  }
  
  /**
   * 扳机震动反馈
   */
  rumbleTriggers(leftTrigger: number, rightTrigger: number): void {
    this.leftTriggerMotor = leftTrigger;
    this.rightTriggerMotor = rightTrigger;
    this.sendRumble();
  }
  
  /**
   * 发送震动命令
   */
  private sendRumble(): void {
    const data = new Uint8Array([
      0x09, 0x00, this.seqNum++, 0x09, 0x00, 0x0f,
      (this.leftTriggerMotor >> 9) & 0xFF,
      (this.rightTriggerMotor >> 9) & 0xFF,
      (this.lowFreqMotor >> 8) & 0xFF,
      (this.highFreqMotor >> 8) & 0xFF,
      0xff, 0x00, 0x00
    ]);
    
    if (this.seqNum > 0xFF) {
      this.seqNum = 0;
    }
    
    this.bulkWrite(data);
  }
}
