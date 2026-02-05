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
 * 抽象 Xbox 风格控制器基类
 * 
 * 参考 Android moonlight-android AbstractXboxController
 * 用于 Xbox 360 和 Xbox One 控制器
 */

import { usbManager } from '@kit.BasicServicesKit';
import { AbstractController } from './AbstractController';
import { UsbDriverListener } from './UsbDriverListener';
import { ControllerType, ControllerCapabilities, ButtonFlags, UsbDirection } from './ControllerConstants';
import { isHardwareError, createUsbError, UsbError } from './UsbErrorCodes';

const TAG = '[USB-XBOX]';

export abstract class AbstractXboxController extends AbstractController {
  protected device: usbManager.USBDevice;
  protected pipe: usbManager.USBDevicePipe | null = null;
  
  protected inEndpoint: usbManager.USBEndpoint | null = null;
  protected outEndpoint: usbManager.USBEndpoint | null = null;
  protected usbInterface: usbManager.USBInterface | null = null;
  
  private inputThread: boolean = false;
  private stopped: boolean = false;
  
  constructor(
    device: usbManager.USBDevice,
    pipe: usbManager.USBDevicePipe,
    deviceId: number,
    listener: UsbDriverListener
  ) {
    super(deviceId, listener, device.vendorId, device.productId);
    this.device = device;
    this.pipe = pipe;
    this.type = ControllerType.XBOX;
    this.capabilities = ControllerCapabilities.ANALOG_TRIGGERS | ControllerCapabilities.RUMBLE;
    
    // 支持的按钮
    this.supportedButtonFlags = 
      ButtonFlags.A_FLAG | ButtonFlags.B_FLAG | ButtonFlags.X_FLAG | ButtonFlags.Y_FLAG |
      ButtonFlags.UP_FLAG | ButtonFlags.DOWN_FLAG | ButtonFlags.LEFT_FLAG | ButtonFlags.RIGHT_FLAG |
      ButtonFlags.LB_FLAG | ButtonFlags.RB_FLAG |
      ButtonFlags.LS_CLK_FLAG | ButtonFlags.RS_CLK_FLAG |
      ButtonFlags.BACK_FLAG | ButtonFlags.PLAY_FLAG | ButtonFlags.SPECIAL_BUTTON_FLAG;
  }
  
  /**
   * 查找并设置端点
   */
  private findEndpoints(): boolean {
    if (!this.device.configs || this.device.configs.length === 0) {
      console.error(`${TAG} 设备没有配置`);
      return false;
    }
    
    const config = this.device.configs[0];
    if (!config.interfaces || config.interfaces.length === 0) {
      console.error(`${TAG} 配置没有接口`);
      return false;
    }
    
    // 查找第一个接口
    this.usbInterface = config.interfaces[0];
    
    if (!this.usbInterface.endpoints || this.usbInterface.endpoints.length === 0) {
      console.error(`${TAG} 接口没有端点`);
      return false;
    }
    
    // 查找输入和输出端点
    for (const endpoint of this.usbInterface.endpoints) {
      const direction = endpoint.direction;
      
      if (direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_FROM_DEVICE) {
        if (this.inEndpoint !== null) {
          console.warn(`${TAG} 发现重复的输入端点`);
          return false;
        }
        this.inEndpoint = endpoint;
        console.info(`${TAG} 找到输入端点: address=0x${endpoint.address.toString(16)}`);
      } else if (direction === usbManager.USBRequestDirection.USB_REQUEST_DIR_TO_DEVICE) {
        if (this.outEndpoint !== null) {
          console.warn(`${TAG} 发现重复的输出端点`);
          return false;
        }
        this.outEndpoint = endpoint;
        console.info(`${TAG} 找到输出端点: address=0x${endpoint.address.toString(16)}`);
      }
    }
    
    // 确保找到了必要的端点
    if (this.inEndpoint === null || this.outEndpoint === null) {
      console.warn(`${TAG} 缺少必要的端点: in=${this.inEndpoint !== null}, out=${this.outEndpoint !== null}`);
      return false;
    }
    
    return true;
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
      if (result !== 0) {
        console.error(`${TAG} 声明接口失败: ${result}`);
        return false;
      }
      console.info(`${TAG} 成功声明接口`);
      return true;
    } catch (err) {
      console.error(`${TAG} 声明接口异常:`, err);
      return false;
    }
  }
  
  /**
   * 批量传输读取
   */
  protected async bulkRead(timeout: number = 3000): Promise<Uint8Array | null> {
    if (!this.pipe || !this.inEndpoint) {
      throw new Error('USB 管道或端点未初始化');
    }
    
    // 创建读取缓冲区
    const buffer = new Uint8Array(64);
    const result = await usbManager.bulkTransfer(this.pipe, this.inEndpoint, buffer, timeout);
    
    // 负数表示错误
    if (result < 0) {
      throw createUsbError(result);
    }
    
    if (result > 0) {
      return buffer.slice(0, result);
    }
    return null;
  }
  
  /**
   * 批量传输写入
   */
  protected async bulkWrite(data: Uint8Array, timeout: number = 3000): Promise<number> {
    if (!this.pipe || !this.outEndpoint) {
      return -1;
    }
    
    try {
      // HarmonyOS bulkTransfer 返回传输的字节数
      const result = await usbManager.bulkTransfer(this.pipe, this.outEndpoint, data, timeout);
      return typeof result === 'number' ? result : data.length;
    } catch (err) {
      console.error(`${TAG} 批量写入失败:`, err);
      return -1;
    }
  }
  
  /**
   * 输入读取线程
   */
  private async inputLoop(): Promise<void> {
    console.info(`${TAG} 输入循环启动`);
    
    // 延迟一下再通知设备添加
    await new Promise<void>((resolve: Function) => setTimeout(resolve, 500));
    
    // 通知设备已添加
    this.notifyDeviceAdded();
    
    let detectedHardwareError = false;
    
    while (!this.stopped) {
      try {
        // 使用较长的超时（与 Android 一致）
        // 有数据时会立即返回，不会影响实际轮询率
        const buffer = await this.bulkRead(1000);
        
        if (this.stopped) {
          break;
        }
        
        if (buffer && buffer.length > 0) {
          if (this.handleRead(buffer)) {
            this.reportInput();
          }
        }
      } catch (err) {
        if (!this.stopped) {
          // 检查错误类型
          const usbErr = err instanceof UsbError ? err : null;
          const errorCode = usbErr ? usbErr.code : 0;
          const retryable = usbErr ? usbErr.retryable : true;  // 默认可重试
          
          // 超时错误 - 继续轮询
          if (errorCode === -8) {  // USB_ERROR_TIMEOUT
            continue;
          } else if (errorCode === -4) {  // USB_ERROR_NO_DEVICE
            // 如果设置了忽略断开信号，继续轮询
            if (this.ignoreDisconnect) {
              console.warn(`${TAG} 设备不可达但忽略断开信号已启用，继续轮询: ${err}`);
              continue;
            }
            console.warn(`${TAG} 设备不可达: ${err}`);
            break;
          } else if (isHardwareError(errorCode)) {
            // 如果设置了忽略断开信号，继续轮询
            if (this.ignoreDisconnect) {
              console.warn(`${TAG} 检测到硬件错误但忽略断开信号已启用，继续轮询: ${err}`);
              continue;
            }
            console.error(`${TAG} 检测到硬件错误: ${err}`);
            detectedHardwareError = true;
            break;
          } else {
            console.error(`${TAG} 输入读取错误: ${err}`);
            // 其他错误 - 如果标记为可重试则继续，否则停止
            if (!retryable) {
              // 如果设置了忽略断开信号，也继续轮询
              if (this.ignoreDisconnect) {
                console.warn(`${TAG} 不可重试错误但忽略断开信号已启用，继续轮询: ${err}`);
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
      } else {
        // 设备断开或其他错误
        console.warn(`${TAG} 由于设备断开/IO错误，自动停止控制器`);
        this.stop();
      }
    }
  }
  
  /**
   * 启动控制器
   */
  start(): boolean {
    console.info(`${TAG} 启动控制器: VID=0x${this.vendorId.toString(16)}, PID=0x${this.productId.toString(16)}`);
    
    // 查找端点
    if (!this.findEndpoints()) {
      console.error(`${TAG} 查找端点失败`);
      return false;
    }
    
    // 声明接口
    if (!this.claimInterface()) {
      console.error(`${TAG} 声明接口失败`);
      return false;
    }
    
    // 执行初始化
    if (!this.doInit()) {
      console.error(`${TAG} 初始化失败`);
      return false;
    }
    
    // 启动输入循环
    this.stopped = false;
    this.inputThread = true;
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
    
    // 取消震动
    this.rumble(0, 0);
    
    // 释放接口
    if (this.pipe && this.usbInterface) {
      try {
        usbManager.releaseInterface(this.pipe, this.usbInterface);
      } catch (err) {
        console.error(`${TAG} 释放接口失败:`, err);
      }
    }
    
    // 关闭管道
    if (this.pipe) {
      try {
        usbManager.closePipe(this.pipe);
      } catch (err) {
        console.error(`${TAG} 关闭管道失败:`, err);
      }
      this.pipe = null;
    }
    
    // 通知设备已移除
    this.notifyDeviceRemoved();
  }
  
  /**
   * 检查控制器是否已连接
   */
  isConnected(): boolean {
    return !this.stopped && this.pipe !== null;
  }
  
  /**
   * 处理读取的数据
   * @param buffer 读取的数据缓冲区
   * @returns 是否应该发送输入报告
   */
  protected abstract handleRead(buffer: Uint8Array): boolean;
  
  /**
   * 执行设备初始化
   * @returns 是否初始化成功
   */
  protected abstract doInit(): boolean;
}
