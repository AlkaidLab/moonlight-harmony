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
 * Nintendo Switch Pro Controller 驱动
 * 
 * 参考 Android moonlight-android SwitchProController
 */

import { usbManager } from '@kit.BasicServicesKit';
import { AbstractController } from './AbstractController';
import { UsbDriverListener } from './UsbDriverListener';
import { ButtonFlags, SwitchPro, UsbClass, ControllerType, ControllerCapabilities, MotionType } from './ControllerConstants';
import { isHardwareError, UsbError } from './UsbErrorCodes';

const TAG = '[USB-SWITCH]';
const PACKET_SIZE = 64;
const COMMAND_RETRIES = 10;

// SPI Flash 偏移量
const FACTORY_LS_CALIBRATION_OFFSET = 0x603D;
const FACTORY_RS_CALIBRATION_OFFSET = 0x6046;
const USER_LS_MAGIC_OFFSET = 0x8010;
const USER_LS_CALIBRATION_OFFSET = 0x8012;
const USER_RS_MAGIC_OFFSET = 0x801B;
const USER_RS_CALIBRATION_OFFSET = 0x801D;
const STICK_CALIBRATION_LENGTH = 9;

export class SwitchProController extends AbstractController {
  private device: usbManager.USBDevice;
  private pipe: usbManager.USBDevicePipe | null = null;
  
  private inEndpoint: usbManager.USBEndpoint | null = null;
  private outEndpoint: usbManager.USBEndpoint | null = null;
  private usbInterface: usbManager.USBInterface | null = null;
  
  private stopped: boolean = false;
  private sendPacketCount: number = 0;
  
  // IMU 数据
  private gyroX: number = 0;
  private gyroY: number = 0;
  private gyroZ: number = 0;
  private accelX: number = 0;
  private accelY: number = 0;
  private accelZ: number = 0;
  
  // 摇杆校准数据: [stick][axis][min, center, max]
  private stickCalibration: number[][][] = [
    [[0, 0x800, 0xFFF], [0, 0x800, 0xFFF]],
    [[0, 0x800, 0xFFF], [0, 0x800, 0xFFF]]
  ];
  // 预计算的轴范围: [stick][axis][negative, positive]
  private stickExtends: number[][][] = [
    [[-0x700, 0x700], [-0x700, 0x700]],
    [[-0x700, 0x700], [-0x700, 0x700]]
  ];
  
  constructor(
    device: usbManager.USBDevice,
    pipe: usbManager.USBDevicePipe,
    deviceId: number,
    listener: UsbDriverListener
  ) {
    super(deviceId, listener, device.vendorId, device.productId);
    this.device = device;
    this.pipe = pipe;
    this.type = ControllerType.NINTENDO;
    this.capabilities = ControllerCapabilities.GYRO | ControllerCapabilities.ACCEL | ControllerCapabilities.RUMBLE;
    this.deviceName = 'Switch Pro Controller';
    
    // 支持的按钮
    this.supportedButtonFlags = 
      ButtonFlags.A_FLAG | ButtonFlags.B_FLAG | ButtonFlags.X_FLAG | ButtonFlags.Y_FLAG |
      ButtonFlags.UP_FLAG | ButtonFlags.DOWN_FLAG | ButtonFlags.LEFT_FLAG | ButtonFlags.RIGHT_FLAG |
      ButtonFlags.LB_FLAG | ButtonFlags.RB_FLAG |
      ButtonFlags.LS_CLK_FLAG | ButtonFlags.RS_CLK_FLAG |
      ButtonFlags.BACK_FLAG | ButtonFlags.PLAY_FLAG | ButtonFlags.SPECIAL_BUTTON_FLAG | ButtonFlags.MISC_FLAG;
  }
  
  /**
   * 检查是否可以驱动该设备
   */
  static canClaimDevice(device: usbManager.USBDevice): boolean {
    if (device.vendorId !== SwitchPro.VID) {
      return false;
    }
    
    const pid = device.productId;
    if (pid !== SwitchPro.PRO_PID && 
        pid !== SwitchPro.JOYCON_LEFT_PID && 
        pid !== SwitchPro.JOYCON_RIGHT_PID && 
        pid !== SwitchPro.JOYCON_PAIR_PID) {
      return false;
    }
    
    if (!device.configs || device.configs.length === 0) {
      return false;
    }
    
    const config = device.configs[0];
    if (!config.interfaces || config.interfaces.length === 0) {
      return false;
    }
    
    const iface = config.interfaces[0];
    if (iface.clazz !== UsbClass.USB_CLASS_HID) {
      return false;
    }
    
    console.info(`${TAG} 检测到 Switch 控制器: VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)}`);
    return true;
  }
  
  /**
   * 是否是 Joy-Con
   */
  private isJoyCon(): boolean {
    const pid = this.device.productId;
    return pid === SwitchPro.JOYCON_LEFT_PID || 
           pid === SwitchPro.JOYCON_RIGHT_PID || 
           pid === SwitchPro.JOYCON_PAIR_PID;
  }
  
  /**
   * 查找端点
   */
  private findEndpoints(): boolean {
    if (!this.device.configs || this.device.configs.length === 0) {
      return false;
    }
    
    const config = this.device.configs[0];
    if (!config.interfaces || config.interfaces.length === 0) {
      return false;
    }
    
    this.usbInterface = config.interfaces[0];
    
    if (!this.usbInterface.endpoints || this.usbInterface.endpoints.length === 0) {
      return false;
    }
    
    for (const endpoint of this.usbInterface.endpoints) {
      if (endpoint.direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_FROM_DEVICE) {
        if (!this.inEndpoint) {
          this.inEndpoint = endpoint;
        }
      } else if (endpoint.direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_TO_DEVICE) {
        if (!this.outEndpoint) {
          this.outEndpoint = endpoint;
        }
      }
    }
    
    return this.inEndpoint !== null && this.outEndpoint !== null;
  }
  
  /**
   * 声明接口
   */
  private claimInterface(): boolean {
    if (!this.pipe || !this.usbInterface) {
      return false;
    }
    
    try {
      const result = usbManager.claimInterface(this.pipe, this.usbInterface, true);
      return result === 0;
    } catch (err) {
      console.error(`${TAG} 声明接口失败:`, err);
      return false;
    }
  }
  
  /**
   * 发送数据
   */
  private async sendData(data: Uint8Array): Promise<boolean> {
    if (!this.pipe || !this.outEndpoint) {
      return false;
    }
    
    try {
      const result = await usbManager.bulkTransfer(this.pipe, this.outEndpoint, data, 100);
      return typeof result === 'number' ? result === data.length : true;
    } catch (err) {
      return false;
    }
  }
  
  /**
   * 读取数据
   */
  private async readData(timeout: number = 100, throwOnError: boolean = false): Promise<Uint8Array | null> {
    if (!this.pipe || !this.inEndpoint) {
      if (throwOnError) {
        throw new Error('USB 管道或端点未初始化');
      }
      return null;
    }
    
    try {
      const buffer = new Uint8Array(64);
      const result = await usbManager.bulkTransfer(this.pipe, this.inEndpoint, buffer, timeout);
      
      // 负数表示错误
      if (result < 0) {
        if (throwOnError) {
          throw new Error(`USB 读取失败，错误码: ${result}`);
        }
        return null;
      }
      
      if (result > 0) {
        return buffer.slice(0, result);
      }
      return null;
    } catch (err) {
      if (throwOnError) {
        throw new Error(`USB 读取异常: ${err}`);
      }
      return null;
    }
  }
  
  /**
   * 发送命令
   */
  private async sendCommand(id: number, waitReply: boolean): Promise<boolean> {
    const data = new Uint8Array([0x80, id]);
    
    for (let i = 0; i < COMMAND_RETRIES; i++) {
      if (!await this.sendData(data)) {
        continue;
      }
      
      if (!waitReply) {
        return true;
      }
      
      let retries = 0;
      while (retries < 20 && !this.stopped) {
        const buffer = await this.readData(100);
        if (buffer && buffer.length > 1 && buffer[0] === 0x81 && buffer[1] === id) {
          return true;
        }
        retries++;
      }
    }
    
    return false;
  }
  
  /**
   * 发送子命令
   */
  private async sendSubcommand(subcommand: number, payload: Uint8Array): Promise<Uint8Array | null> {
    const data = new Uint8Array(11 + payload.length);
    data[0] = 0x01;  // Rumble + subcommand
    data[1] = this.sendPacketCount++;
    if (this.sendPacketCount > 0xF) {
      this.sendPacketCount = 0;
    }
    data[10] = subcommand;
    data.set(payload, 11);
    
    for (let i = 0; i < COMMAND_RETRIES; i++) {
      if (!await this.sendData(data)) {
        continue;
      }
      
      let retries = 0;
      while (retries < 20 && !this.stopped) {
        const buffer = await this.readData(100);
        if (buffer && buffer.length >= 15 && buffer[0] === 0x21 && buffer[14] === subcommand) {
          return buffer;
        }
        retries++;
      }
    }
    
    return null;
  }
  
  /**
   * 握手
   */
  private async handshake(): Promise<boolean> {
    return await this.sendCommand(0x02, true);
  }
  
  /**
   * 高速模式
   */
  private async highSpeed(): Promise<boolean> {
    return await this.sendCommand(0x03, true);
  }
  
  /**
   * 强制 USB 模式
   */
  private async forceUSB(): Promise<boolean> {
    return await this.sendCommand(0x04, true);
  }
  
  /**
   * 设置输入报告模式
   */
  private async setInputReportMode(mode: number): Promise<boolean> {
    const result = await this.sendSubcommand(0x03, new Uint8Array([mode]));
    return result !== null;
  }
  
  /**
   * 设置玩家 LED
   */
  private async setPlayerLED(id: number): Promise<boolean> {
    const result = await this.sendSubcommand(0x30, new Uint8Array([id & 0b1111]));
    return result !== null;
  }
  
  /**
   * 启用 IMU
   */
  private async enableIMU(enable: boolean): Promise<boolean> {
    const result = await this.sendSubcommand(0x40, new Uint8Array([enable ? 0x01 : 0x00]));
    return result !== null;
  }
  
  /**
   * 启用震动
   */
  private async enableVibration(enable: boolean): Promise<boolean> {
    const result = await this.sendSubcommand(0x48, new Uint8Array([enable ? 0x01 : 0x00]));
    return result !== null;
  }
  
  /**
   * 应用默认校准
   */
  private applyDefaultCalibration(stick: number): void {
    for (let axis = 0; axis < 2; axis++) {
      this.stickCalibration[stick][axis][0] = 0x000;
      this.stickCalibration[stick][axis][1] = 0x800;
      this.stickCalibration[stick][axis][2] = 0xFFF;
      this.stickExtends[stick][axis][0] = -0x700;
      this.stickExtends[stick][axis][1] = 0x700;
    }
  }
  
  /**
   * 应用摇杆校准
   */
  private applyStickCalibration(value: number, stick: number, axis: number): number {
    const center = this.stickCalibration[stick][axis][1];
    
    if (value < 0) {
      value += 0x1000;
    }
    
    value -= center;
    
    if (value < this.stickExtends[stick][axis][0]) {
      this.stickExtends[stick][axis][0] = value;
      return -1;
    } else if (value > this.stickExtends[stick][axis][1]) {
      this.stickExtends[stick][axis][1] = value;
      return 1;
    }
    
    if (value > 0) {
      const divisor = this.stickExtends[stick][axis][1];
      if (Math.abs(divisor) < 0.0001) {
        return 0;
      }
      return value / divisor;
    } else if (value < 0) {
      const divisor = this.stickExtends[stick][axis][0];
      if (Math.abs(divisor) < 0.0001) {
        return 0;
      }
      return -value / divisor;
    }
    return 0;
  }
  
  /**
   * 处理输入报告
   */
  private handleRead(buffer: Uint8Array): boolean {
    if (buffer.length < PACKET_SIZE) {
      return false;
    }
    
    // 检查报告 ID
    if (buffer[0] !== 0x30) {
      return false;
    }
    
    this.buttonFlags = 0;
    
    // Nintendo 布局与 Xbox 相反
    const b3 = buffer[3];
    const b4 = buffer[4];
    const b5 = buffer[5];
    
    this.setButtonFlag(ButtonFlags.B_FLAG, b3 & 0x08);
    this.setButtonFlag(ButtonFlags.A_FLAG, b3 & 0x04);
    this.setButtonFlag(ButtonFlags.Y_FLAG, b3 & 0x02);
    this.setButtonFlag(ButtonFlags.X_FLAG, b3 & 0x01);
    this.setButtonFlag(ButtonFlags.UP_FLAG, b5 & 0x02);
    this.setButtonFlag(ButtonFlags.DOWN_FLAG, b5 & 0x01);
    this.setButtonFlag(ButtonFlags.LEFT_FLAG, b5 & 0x08);
    this.setButtonFlag(ButtonFlags.RIGHT_FLAG, b5 & 0x04);
    this.setButtonFlag(ButtonFlags.BACK_FLAG, b4 & 0x01);
    this.setButtonFlag(ButtonFlags.PLAY_FLAG, b4 & 0x02);
    this.setButtonFlag(ButtonFlags.MISC_FLAG, b4 & 0x20);  // Screenshot
    this.setButtonFlag(ButtonFlags.SPECIAL_BUTTON_FLAG, b4 & 0x10);  // Home
    this.setButtonFlag(ButtonFlags.LB_FLAG, b5 & 0x40);
    this.setButtonFlag(ButtonFlags.RB_FLAG, b3 & 0x40);
    this.setButtonFlag(ButtonFlags.LS_CLK_FLAG, b4 & 0x08);
    this.setButtonFlag(ButtonFlags.RS_CLK_FLAG, b4 & 0x04);
    
    // 扳机 (数字 ZL/ZR)
    this.leftTrigger = (b5 & 0x80) !== 0 ? 1.0 : 0.0;
    this.rightTrigger = (b3 & 0x80) !== 0 ? 1.0 : 0.0;
    
    // 摇杆: 每轴 12 位
    const lsx = buffer[6] | ((buffer[7] & 0x0F) << 8);
    const lsy = ((buffer[7] & 0xF0) >> 4) | (buffer[8] << 4);
    const rsx = buffer[9] | ((buffer[10] & 0x0F) << 8);
    const rsy = ((buffer[10] & 0xF0) >> 4) | (buffer[11] << 4);
    
    this.leftStickX = this.applyStickCalibration(lsx, 0, 0);
    this.leftStickY = -this.applyStickCalibration(lsy, 0, 1);
    this.rightStickX = this.applyStickCalibration(rsx, 1, 0);
    this.rightStickY = -this.applyStickCalibration(rsy, 1, 1);
    
    // IMU 数据 (从偏移 13 开始)
    if (buffer.length >= 25) {
      const GYRO_SCALE = 0.06103;  // deg/s per LSB
      const ACCEL_SCALE = 0.000244;  // g per LSB
      
      // 读取 IMU 数据
      this.accelX = this.readShortLE(buffer, 13) * ACCEL_SCALE;
      this.accelY = this.readShortLE(buffer, 15) * ACCEL_SCALE;
      this.accelZ = this.readShortLE(buffer, 17) * ACCEL_SCALE;
      this.gyroX = this.readShortLE(buffer, 19) * GYRO_SCALE;
      this.gyroY = this.readShortLE(buffer, 21) * GYRO_SCALE;
      this.gyroZ = this.readShortLE(buffer, 23) * GYRO_SCALE;
    }
    
    return true;
  }
  
  /**
   * 读取小端序 short
   */
  private readShortLE(buffer: Uint8Array, offset: number): number {
    const value = buffer[offset] | (buffer[offset + 1] << 8);
    return value > 32767 ? value - 65536 : value;
  }
  
  /**
   * 报告运动数据
   */
  private reportMotion(): void {
    this.notifyControllerMotion(MotionType.GYRO, this.gyroX, this.gyroY, this.gyroZ);
    this.notifyControllerMotion(MotionType.ACCEL, this.accelX * 9.81, this.accelY * 9.81, this.accelZ * 9.81);
  }
  
  /**
   * 输入循环
   */
  private async inputLoop(): Promise<void> {
    console.info(`${TAG} 开始初始化...`);
    
    // 初始化序列
    const handshakeSuccess = await this.handshake();
    if (!handshakeSuccess) {
      console.error(`${TAG} 握手失败`);
      this.stop();
      return;
    }
    
    const deviceType = this.isJoyCon() ? "Joy-Con" : "Switch Pro";
    console.info(`${TAG} ${deviceType}: handshake ${handshakeSuccess}`);
    console.info(`${TAG} ${deviceType}: highSpeed ${await this.highSpeed()}`);
    console.info(`${TAG} ${deviceType}: handshake ${await this.handshake()}`);
    
    // 应用默认校准
    this.applyDefaultCalibration(0);
    this.applyDefaultCalibration(1);
    
    console.info(`${TAG} ${deviceType}: setInputReportMode ${await this.setInputReportMode(0x30)}`);
    console.info(`${TAG} ${deviceType}: forceUSB ${await this.forceUSB()}`);
    console.info(`${TAG} ${deviceType}: enableVibration ${await this.enableVibration(true)}`);
    console.info(`${TAG} ${deviceType}: setPlayerLED ${await this.setPlayerLED(this.getControllerId() + 1)}`);
    console.info(`${TAG} ${deviceType}: enableIMU ${await this.enableIMU(true)}`);
    
    console.info(`${TAG} ${deviceType}: 初始化完成!`);
    
    // 通知设备已添加
    this.notifyDeviceAdded();
    
    let isSleepMode = false;
    let detectedHardwareError = false;
    let consecutiveTimeouts = 0;  // 连续超时计数
    const MAX_CONSECUTIVE_TIMEOUTS = 10;  // 1秒超时，10次 = 10秒
    
    // 输入循环
    while (!this.stopped) {
      try {
        // 使用较长的超时（与 Android 一致）
        // 有数据时会立即返回，不会影响实际轮询率
        // 输入循环中使用 throwOnError: true 以便正确检测设备断开
        const buffer = await this.readData(1000, true);
        
        if (this.stopped) {
          break;
        }
        
        if (buffer && this.handleRead(buffer)) {
          consecutiveTimeouts = 0;  // 收到数据，重置超时计数
          this.reportInput();
          this.reportMotion();
        }
      } catch (err) {
        if (!this.stopped) {
          // 检查错误类型
          const usbErr = err instanceof UsbError ? err : null;
          const errorCode = usbErr ? usbErr.code : 0;
          const retryable = usbErr ? usbErr.retryable : true;  // 默认可重试
          
          // 超时错误特殊处理：需要连续多次才认为是省电模式
          if (errorCode === -8) {  // USB_ERROR_TIMEOUT
            consecutiveTimeouts++;
            if (consecutiveTimeouts >= MAX_CONSECUTIVE_TIMEOUTS) {
              console.warn(`${TAG} 连续 ${consecutiveTimeouts} 次超时，设备可能进入省电模式`);
              isSleepMode = true;
              break;
            }
            // 单次超时不做处理，继续轮询
            continue;
          } else if (errorCode === -4) {  // USB_ERROR_NO_DEVICE
            console.warn(`${TAG} 设备不可达: ${err}`);
            // 检查是否应该忽略断开信号
            if (this.ignoreDisconnect) {
              console.info(`${TAG} 忽略设备不可达错误（用户已启用忽略断开设置）`);
              continue;
            }
            isSleepMode = true;
            break;
          } else if (isHardwareError(errorCode)) {
            console.error(`${TAG} 检测到硬件错误: ${err}`);
            // 检查是否应该忽略断开信号
            if (this.ignoreDisconnect) {
              console.info(`${TAG} 忽略硬件错误（用户已启用忽略断开设置）`);
              continue;
            }
            detectedHardwareError = true;
            // 硬件错误 - 立即停止
            break;
          } else {
            console.error(`${TAG} 输入读取错误: ${err}`);
            // 其他错误 - 如果标记为可重试则继续，否则停止
            if (!retryable) {
              // 检查是否应该忽略断开信号
              if (this.ignoreDisconnect) {
                console.info(`${TAG} 忽略不可重试错误（用户已启用忽略断开设置）`);
                continue;
              }
              break;
            }
          }
        }
      }
    }
    
    console.info(`${TAG} 输入循环结束`);
    
    // 根据错误类型决定是否通知设备移除
    if (!this.stopped) {
      if (detectedHardwareError) {
        console.error(`${TAG} 由于硬件错误，自动停止控制器`);
        this.stop();
      } else if (isSleepMode) {
        console.info(`${TAG} 设备进入省电模式，等待自动重连...`);
        // 省电模式：只停止 I/O 循环但不立即移除，让 UsbDriverService 定时器处理重连
        this.notifyDeviceRemoved();
      } else {
        // 其他错误
        console.warn(`${TAG} 由于 IO 错误，自动停止控制器`);
        this.stop();
      }
    }
  }
  
  /**
   * 启动控制器
   */
  start(): boolean {
    console.info(`${TAG} 启动控制器`);
    
    if (!this.findEndpoints()) {
      console.error(`${TAG} 查找端点失败`);
      return false;
    }
    
    if (!this.claimInterface()) {
      console.error(`${TAG} 声明接口失败`);
      return false;
    }
    
    this.stopped = false;
    this.inputLoop();
    
    return true;
  }
  
  /**
   * 停止控制器
   */
  stop(): void {
    if (this.stopped) {
      return;
    }
    
    console.info(`${TAG} 停止控制器`);
    this.stopped = true;
    
    this.rumble(0, 0);
    
    if (this.pipe && this.usbInterface) {
      try {
        usbManager.releaseInterface(this.pipe, this.usbInterface);
      } catch (err) {
        console.error(`${TAG} 释放接口失败:`, err);
      }
    }
    
    if (this.pipe) {
      try {
        usbManager.closePipe(this.pipe);
      } catch (err) {
        console.error(`${TAG} 关闭管道失败:`, err);
      }
      this.pipe = null;
    }
    
    this.notifyDeviceRemoved();
  }
  
  /**
   * 检查控制器是否已连接
   */
  isConnected(): boolean {
    return !this.stopped && this.pipe !== null;
  }
  
  /**
   * 震动反馈
   */
  rumble(lowFreqMotor: number, highFreqMotor: number): void {
    const data = new Uint8Array(10);
    data[0] = 0x10;
    data[1] = this.sendPacketCount++;
    if (this.sendPacketCount > 0xF) {
      this.sendPacketCount = 0;
    }
    
    if (lowFreqMotor !== 0) {
      data[4] = data[8] = 0x50 - ((lowFreqMotor & 0xFFFF) >> 12);
      data[5] = data[9] = (((lowFreqMotor & 0xFFFF) >> 8) / 5) + 0x40;
    }
    if (highFreqMotor !== 0) {
      data[6] = (0x70 - ((highFreqMotor & 0xFFFF) >> 10)) & 0xFC;
      data[7] = ((highFreqMotor & 0xFFFF) >> 8) * 0xC8 / 0xFF;
    }
    
    data[2] |= 0x00;
    data[3] |= 0x01;
    data[5] |= 0x40;
    data[6] |= 0x00;
    data[7] |= 0x01;
    data[9] |= 0x40;
    
    this.sendData(data);
  }
  
  /**
   * 扳机震动（Switch Pro 不支持）
   */
  rumbleTriggers(_leftTrigger: number, _rightTrigger: number): void {
    // Switch Pro 不支持扳机震动
  }
}
