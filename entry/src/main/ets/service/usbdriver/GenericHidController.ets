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
 * 通用 HID 手柄控制器驱动
 * 
 * 支持标准 USB HID 游戏手柄
 * 这个驱动尝试解析通用的 HID 报告格式
 */

import { usbManager } from '@kit.BasicServicesKit';
import { AbstractController } from './AbstractController';
import { UsbDriverListener } from './UsbDriverListener';
import { ButtonFlags, UsbClass, ControllerType, ControllerCapabilities } from './ControllerConstants';
import { isHardwareError, createUsbError, UsbError } from './UsbErrorCodes';

const TAG = '[USB-HID]';

// 已知支持的通用 HID 手柄厂商
export class GenericHidVendors {
  static readonly SUPPORTED_VENDORS: number[] = [
    0x413d,  // 通用游戏手柄（PXN 等）
    0x0079,  // DragonRise
    0x11c0,  // Generic
    0x2563,  // ShenZhen ShanWan
    0x20bc,  // ShenZhen Sailtel
    0x11c1,  // Generic gamepad
    0x1345,  // Generic
    0x1949,  // Lab126 (Amazon Luna)
    0x0583,  // Generic gamepad
    0x2dc8,  // 8BitDo (一些通用模式)
    0x2f24,  // GameSir
  ];
}

export class GenericHidController extends AbstractController {
  private device: usbManager.USBDevice;
  private pipe: usbManager.USBDevicePipe;
  private running: boolean = false;
  private inputEndpoint: number = 0;
  private outputEndpoint: number = 0;
  private inputMaxPacketSize: number = 64;
  
  // 报告格式检测
  private reportOffset: number = 0;  // 有些设备在报告前有报告ID
  private lastHexReport: string = '';  // 用于去重日志
  
  constructor(
    device: usbManager.USBDevice,
    pipe: usbManager.USBDevicePipe,
    deviceId: number,
    listener: UsbDriverListener
  ) {
    super(deviceId, listener, device.vendorId, device.productId);
    this.device = device;
    this.pipe = pipe;
    this.type = ControllerType.XBOX;  // 模拟 Xbox 布局
    this.deviceName = `Generic HID Controller (${device.name || 'Unknown'})`;
    this.capabilities = ControllerCapabilities.ANALOG_TRIGGERS | ControllerCapabilities.RUMBLE;
    
    // 支持的按钮
    this.supportedButtonFlags = 
      ButtonFlags.A_FLAG | ButtonFlags.B_FLAG | ButtonFlags.X_FLAG | ButtonFlags.Y_FLAG |
      ButtonFlags.UP_FLAG | ButtonFlags.DOWN_FLAG | ButtonFlags.LEFT_FLAG | ButtonFlags.RIGHT_FLAG |
      ButtonFlags.LB_FLAG | ButtonFlags.RB_FLAG |
      ButtonFlags.LS_CLK_FLAG | ButtonFlags.RS_CLK_FLAG |
      ButtonFlags.BACK_FLAG | ButtonFlags.PLAY_FLAG | ButtonFlags.SPECIAL_BUTTON_FLAG;
    
    // 查找端点
    this.findEndpoints();
  }
  
  /**
   * 检查是否可以驱动该设备
   */
  static canClaimDevice(device: usbManager.USBDevice): boolean {
    // 检查是否是已知的通用 HID 厂商
    if (GenericHidVendors.SUPPORTED_VENDORS.includes(device.vendorId)) {
      console.info(`${TAG} 检测到通用 HID 手柄: VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)}`);
      return true;
    }
    
    // 检查是否有 HID 接口
    if (!device.configs || device.configs.length === 0) {
      return false;
    }
    
    const config = device.configs[0];
    if (!config.interfaces || config.interfaces.length === 0) {
      return false;
    }
    
    // 查找 HID 接口
    for (let i = 0; i < config.interfaces.length; i++) {
      const iface = config.interfaces[i];
      if (iface.clazz === UsbClass.USB_CLASS_HID) {
        console.info(`${TAG} 检测到 HID 接口的设备: VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)}`);
        // 返回 false，让其他更具体的驱动先尝试
        // 只有在明确知道厂商时才返回 true
        return false;
      }
    }
    
    return false;
  }
  
  private findEndpoints(): void {
    if (!this.device.configs || this.device.configs.length === 0) {
      return;
    }
    
    const config = this.device.configs[0];
    if (!config.interfaces || config.interfaces.length === 0) {
      return;
    }
    
    // 查找 HID 接口的端点
    for (let i = 0; i < config.interfaces.length; i++) {
      const iface = config.interfaces[i];
      if (iface.clazz === UsbClass.USB_CLASS_HID && iface.endpoints) {
        for (let j = 0; j < iface.endpoints.length; j++) {
          const ep = iface.endpoints[j];
          if ((ep.direction & 0x80) !== 0) {
            // IN 端点
            this.inputEndpoint = ep.address;
            this.inputMaxPacketSize = ep.maxPacketSize;
          } else {
            // OUT 端点
            this.outputEndpoint = ep.address;
          }
        }
        
        // 声明接口
        try {
          const ret = usbManager.claimInterface(this.pipe, iface, true);
          if (ret === 0) {
            console.info(`${TAG} 成功声明 HID 接口`);
          }
        } catch (err) {
          console.error(`${TAG} 声明接口失败:`, err);
        }
        
        break;
      }
    }
    
    console.info(`${TAG} 端点配置: IN=0x${this.inputEndpoint.toString(16)}, OUT=0x${this.outputEndpoint.toString(16)}, MaxPacket=${this.inputMaxPacketSize}`);
  }
  
  start(): boolean {
    if (this.running) {
      return true;
    }
    
    if (this.inputEndpoint === 0) {
      console.error(`${TAG} 无法启动: 未找到输入端点`);
      return false;
    }
    
    this.running = true;
    this.notifyDeviceAdded();
    
    // 开始轮询输入
    this.inputLoop();
    
    console.info(`${TAG} 控制器已启动: ${this.deviceName}`);
    return true;
  }
  
  stop(): void {
    if (!this.running) {
      return;
    }
    
    this.running = false;
    this.notifyDeviceRemoved();
    
    // 关闭 USB 连接
    try {
      usbManager.closePipe(this.pipe);
    } catch (err) {
      console.error(`${TAG} 关闭管道失败:`, err);
    }
    
    console.info(`${TAG} 控制器已停止: ${this.deviceName}`);
  }
  
  private async inputLoop(): Promise<void> {
    const buffer = new Uint8Array(this.inputMaxPacketSize);
    let isSleepMode = false;
    let hardwareError = false;
    let consecutiveTimeouts = 0;  // 连续超时计数
    const MAX_CONSECUTIVE_TIMEOUTS = 100;  // GenericHid 使用 100ms 超时，10秒 = 100次
    
    while (this.running) {
      try {
        const result = await this.bulkRead(buffer);
        if (result > 0) {
          consecutiveTimeouts = 0;  // 收到数据，重置超时计数
          this.processInputReport(buffer, result);
        }
      } catch (err) {
        if (this.running) {
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
            isSleepMode = true;
            break;
          } else if (isHardwareError(errorCode)) {
            console.error(`${TAG} 检测到硬件错误: ${err}`);
            hardwareError = true;
            // 硬件错误 - 立即停止
            break;
          } else {
            console.error(`${TAG} 输入读取错误: ${err}`);
            // 其他错误 - 如果标记为可重试则继续，否则停止
            if (!retryable) {
              break;
            }
            // 短暂等待后重试
            await this.sleep(10);
          }
        }
      }
    }
    
    // 根据错误类型决定是否通知设备移除
    if (this.running) {
      if (hardwareError) {
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
  
  private async bulkRead(buffer: Uint8Array): Promise<number> {
    const timeout: number = 100;  // 100ms 超时
    
    try {
      // 构造端点对象
      const endpoint: usbManager.USBEndpoint = {
        address: this.inputEndpoint,
        attributes: 3,  // Interrupt
        interval: 1,
        maxPacketSize: this.inputMaxPacketSize,
        direction: 0x80 as usbManager.USBRequestDirection,  // IN
        interfaceId: 0,
        number: this.inputEndpoint,
        type: 3  // Interrupt type
      };
      
      const ret: number = await usbManager.bulkTransfer(this.pipe, endpoint, buffer, timeout);
      
      // 负数表示错误
      if (ret < 0) {
        throw createUsbError(ret);
      }
      
      return ret;
    } catch (err) {
      throw err as Error;
    }
  }
  
  /**
   * 处理通用 HID 输入报告
   * 尝试解析标准的 USB HID 游戏手柄格式
   * 
   * 针对 VID 0x413D 等通用手柄的格式：
   * [0] = Report ID (0x01)
   * [1] = 左摇杆 X (0x00-0xFF, 0x80=中心)
   * [2] = 左摇杆 Y
   * [3] = 右摇杆 X
   * [4] = 右摇杆 Y
   * [5] = 扳机或其他数据
   * [6] = HAT 方向键 (0-8, 8或15=中心)
   * [7] = 按钮字节 1
   * [8] = 按钮字节 2
   */
  private processInputReport(data: Uint8Array, length: number): void {
    if (length < 8) {
      return;
    }
    
    // 检测是否有报告ID（第一字节是否看起来像报告ID）
    let offset = 0;
    if (data[0] === 0x01 || data[0] === 0x07 || data[0] === 0x20) {
      offset = 1;
    }
    
    // 打印完整的原始数据以调试按钮映射
    const hexStr = Array.from(data.slice(0, Math.min(length, 16)))
      .map(b => b.toString(16).padStart(2, '0')).join(' ');
    
    // 只有当数据与上次不同时才打印
    const currentHex = hexStr;
    if (this.lastHexReport !== currentHex) {
      console.info(`${TAG} 原始报告: ${currentHex}`);
      
      // 详细打印每个字节的含义
      if (length >= 10) {
        console.info(`${TAG} 解析: LX=${data[1]} LY=${data[2]} RX=${data[3]} RY=${data[4]} ` +
          `B5=0x${data[5].toString(16)} B6=0x${data[6].toString(16)} ` +
          `B7=0x${data[7].toString(16)} B8=0x${data[8].toString(16)} B9=0x${data[9].toString(16)}`);
      }
      this.lastHexReport = currentHex;
    }
    
    // 尝试解析为8位摇杆值（0-255，128为中心）
    if (length >= offset + 8) {
      // 格式: [LX, LY, RX, RY, data, HAT, buttons1, buttons2]
      const lx = data[offset];
      const ly = data[offset + 1];
      const rx = data[offset + 2];
      const ry = data[offset + 3];
      
      // 转换为 -32768 到 32767
      this.leftStickX = this.convertAxis(lx);
      this.leftStickY = -this.convertAxis(ly);  // Y 轴反转
      this.rightStickX = this.convertAxis(rx);
      this.rightStickY = -this.convertAxis(ry);
      
      // byte[5] (B5) = 0x0F 为空闲，变小可能表示扳机
      // 暂时不处理扳机
      
      // byte[6] (B6) = HAT 方向键
      // 0=上, 1=上右, 2=右, 3=下右, 4=下, 5=下左, 6=左, 7=上左, 8/15=中心
      if (length >= offset + 6) {
        const hatByte = data[offset + 5];
        // 只取低4位作为 HAT，高4位可能是其他按钮
        const hat = hatByte & 0x0F;
        
        // 检查是否有高位按钮（如 0x10 = L3/R3）
        const highButtons = hatByte & 0xF0;
        
        this.processHat(hat);
        
        // 处理高位按钮
        if ((highButtons & 0x10) !== 0) {
          this.buttonFlags |= ButtonFlags.LS_CLK_FLAG;  // 可能是 L3
        }
        if ((highButtons & 0x20) !== 0) {
          this.buttonFlags |= ButtonFlags.RS_CLK_FLAG;  // 可能是 R3
        }
      }
      
      // byte[7] (B7) 和 byte[8] (B8) = 按钮
      if (length >= offset + 8) {
        const buttons1 = data[offset + 6];  // B7 - 功能按钮
        const buttons2 = data[offset + 7];  // B8 - ABXY 按钮
        
        // 调试：打印按钮字节和处理前后的标志
        const beforeFlags = this.buttonFlags;
        this.processButtonsGeneric(buttons1, buttons2);
        
        // 调试：打印最终的按钮标志
        if (this.buttonFlags !== 0 || buttons1 !== 0 || buttons2 !== 0) {
          console.info(`${TAG} B7=0x${buttons1.toString(16)} B8=0x${buttons2.toString(16)} ` +
            `flags: 0x${beforeFlags.toString(16)} -> 0x${this.buttonFlags.toString(16)}`);
        }
      }
    }
    
    this.reportInput();
  }
  
  /**
   * 转换8位轴值到 -1.0 到 1.0 的浮点数
   * UsbDriverListener 接口要求摇杆值在 -1.0 到 1.0 范围
   */
  private convertAxis(value: number): number {
    // 0-255 -> -1.0 to 1.0
    // 128 -> 0 (中心)
    const normalized = value - 128;
    return normalized / 127;  // -1.0 到 1.0
  }
  
  /**
   * 处理 HAT 开关 (D-Pad)
   * 
   * 对于这款手柄 (VID 0x413D):
   * - 空闲时 B6=0x00，所以 HAT=0 不是"上"
   * - 需要检测实际的 HAT 编码格式
   * 
   * 常见格式1 (数值): 0=N, 1=NE, 2=E, 3=SE, 4=S, 5=SW, 6=W, 7=NW, 8+=neutral
   * 常见格式2 (位域): bit0=上, bit1=下, bit2=左, bit3=右
   * 
   * 从日志看这款手柄可能用格式1，但空闲值也是0...
   * 让我们尝试格式1，把 0x00 和 0x0F 都当作中心
   */
  private processHat(hat: number): void {
    // 清除方向键标志
    this.buttonFlags &= ~(ButtonFlags.UP_FLAG | ButtonFlags.DOWN_FLAG | 
                          ButtonFlags.LEFT_FLAG | ButtonFlags.RIGHT_FLAG);
    
    // 空闲值检测: 0x00 或大于 7 都是中心
    // 注意：某些手柄用 0x00 作为空闲，某些用 0x08 或 0x0F
    if (hat === 0 || hat > 7) {
      return;
    }
    
    switch (hat) {
      case 1:  // 上
        this.buttonFlags |= ButtonFlags.UP_FLAG;
        break;
      case 2:  // 上右
        this.buttonFlags |= ButtonFlags.UP_FLAG | ButtonFlags.RIGHT_FLAG;
        break;
      case 3:  // 右
        this.buttonFlags |= ButtonFlags.RIGHT_FLAG;
        break;
      case 4:  // 下右
        this.buttonFlags |= ButtonFlags.DOWN_FLAG | ButtonFlags.RIGHT_FLAG;
        break;
      case 5:  // 下
        this.buttonFlags |= ButtonFlags.DOWN_FLAG;
        break;
      case 6:  // 下左
        this.buttonFlags |= ButtonFlags.DOWN_FLAG | ButtonFlags.LEFT_FLAG;
        break;
      case 7:  // 左
        this.buttonFlags |= ButtonFlags.LEFT_FLAG;
        break;
      // 注意：这个手柄没有上左方向？或者编码不同
    }
  }

  /**
   * 处理按钮 - 通用格式
   * 
   * 根据实测数据 (VID 0x413D 手柄):
   * - B7 (offset+6): 功能按钮
   *   注意: B7=0x02 在空闲状态下也出现，不是 Start 按钮
   *   需要检查其他位是否变化
   *   - bit0 = Back/Select (0x01)
   *   - bit1 = 固定值，忽略
   *   - bit2 = Start (0x04)
   *   - bit3 = Guide (0x08)
   * 
   * - B8 (offset+7): ABXY 按钮
   *   - bit0 = A (0x01)
   *   - bit1 = B (0x02)
   *   - bit2 = X (0x04)  
   *   - bit3 = Y (0x08)
   *   - bit4 = LB (0x10)
   *   - bit5 = RB (0x20)
   *   - bit6 = LT (0x40)
   *   - bit7 = RT (0x80)
   */
  private processButtonsGeneric(byte1: number, byte2: number): void {
    // 清除按钮标志（保留方向键和 L3/R3）
    const preserveFlags = ButtonFlags.UP_FLAG | ButtonFlags.DOWN_FLAG | 
                         ButtonFlags.LEFT_FLAG | ButtonFlags.RIGHT_FLAG |
                         ButtonFlags.LS_CLK_FLAG | ButtonFlags.RS_CLK_FLAG;
    this.buttonFlags &= preserveFlags;
    
    // 从 B7 (byte1) 解析功能按钮
    // 注意: bit1 (0x02) 是固定值，忽略它
    if ((byte1 & 0x01) !== 0) this.buttonFlags |= ButtonFlags.BACK_FLAG;     // bit0 = Back/Select
    // bit1 (0x02) 忽略 - 这是空闲状态的固定值
    if ((byte1 & 0x04) !== 0) this.buttonFlags |= ButtonFlags.PLAY_FLAG;     // bit2 = Start
    if ((byte1 & 0x08) !== 0) this.buttonFlags |= ButtonFlags.SPECIAL_BUTTON_FLAG; // bit3 = Guide
    
    // 从 B8 (byte2) 解析 ABXY 和肩键
    if ((byte2 & 0x01) !== 0) this.buttonFlags |= ButtonFlags.A_FLAG;        // bit0 = A
    if ((byte2 & 0x02) !== 0) this.buttonFlags |= ButtonFlags.B_FLAG;        // bit1 = B
    if ((byte2 & 0x04) !== 0) this.buttonFlags |= ButtonFlags.X_FLAG;        // bit2 = X
    if ((byte2 & 0x08) !== 0) this.buttonFlags |= ButtonFlags.Y_FLAG;        // bit3 = Y
    if ((byte2 & 0x10) !== 0) this.buttonFlags |= ButtonFlags.LB_FLAG;       // bit4 = LB
    if ((byte2 & 0x20) !== 0) this.buttonFlags |= ButtonFlags.RB_FLAG;       // bit5 = RB
    
    // 数字扳机 (作为模拟扳机值)
    if ((byte2 & 0x40) !== 0) {
      this.leftTrigger = 1.0;
    } else {
      this.leftTrigger = 0.0;
    }
    if ((byte2 & 0x80) !== 0) {
      this.rightTrigger = 1.0;
    } else {
      this.rightTrigger = 0.0;
    }
  }
  
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), ms);
    });
  }
  
  rumble(lowFreqMotor: number, highFreqMotor: number): void {
    // 通用 HID 手柄通常不支持标准震动
    // 但某些手柄可能支持
    if (this.outputEndpoint === 0) {
      return;
    }
    
    // 尝试发送通用震动命令
    // 这里使用常见的格式，但可能不适用于所有手柄
  }
  
  rumbleTriggers(leftTrigger: number, rightTrigger: number): void {
    // 通用 HID 手柄不支持扳机震动
  }
}
