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
import { createUsbError, UsbError } from './UsbErrorCodes';
import { DdkUsbPoller } from './DdkUsbPoller';

const TAG = '[USB-XBOX]';

export abstract class AbstractXboxController extends AbstractController {
  protected device: usbManager.USBDevice;
  protected pipe: usbManager.USBDevicePipe | null = null;
  
  protected inEndpoint: usbManager.USBEndpoint | null = null;
  protected outEndpoint: usbManager.USBEndpoint | null = null;
  protected usbInterface: usbManager.USBInterface | null = null;
  
  private inputThread: boolean = false;
  private stopped: boolean = false;
  
  // DDK 高速轮询器 (绕过 usbManager IPC)
  private ddkPoller: DdkUsbPoller | null = null;
  private useDdkPolling: boolean = false;
  
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
    // DDK 路径: 通过 DDK 同步发送
    if (this.useDdkPolling && this.ddkPoller) {
      const ret = this.ddkPoller.sendOutput(data);
      if (ret < 0) {
        console.error(`${TAG} DDK sendOutput 失败: ret=${ret}, dataLen=${data.length}`);
      }
      return ret;
    }

    // usbManager 路径
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
   * 输入读取线程 (ArkTS 后备方案)
   */
  private async inputLoop(): Promise<void> {
    console.info(`${TAG} 输入循环启动`);
    
    // 初始化完成，标记就绪并通知
    this.notifyDeviceAdded();
    
    // 智能恢复状态
    let consecutiveErrors = 0;
    const MAX_RECOVERY_ERRORS = 50;  // ~10s (50 × 200ms max backoff)
    let recovering = false;
    
    while (!this.stopped) {
      try {
        // 使用较长的超时（与 Android 一致）
        // 有数据时会立即返回，不会影响实际轮询率
        const buffer = await this.bulkRead(1000);
        
        if (this.stopped) {
          break;
        }
        
        if (buffer && buffer.length > 0) {
          // 读取成功 — 如果正在恢复，重置状态
          if (recovering) {
            console.info(`${TAG} 设备已恢复，累计错误 ${consecutiveErrors} 次`);
            consecutiveErrors = 0;
            recovering = false;
          }
          if (this.handleRead(buffer)) {
            this.reportInput();
          }
        }
      } catch (err) {
        if (!this.stopped) {
          const usbErr = err instanceof UsbError ? err : null;
          const errorCode = usbErr ? usbErr.code : 0;
          
          // 超时错误 - 继续轮询（不计入恢复计数）
          if (errorCode === -8) {  // USB_ERROR_TIMEOUT
            continue;
          }
          
          // 非超时错误 — 智能恢复
          consecutiveErrors++;
          
          // 连续 3 次以上错误才归零输入（单次偶发错误静默重试，避免中断长按）
          if (consecutiveErrors >= 3 && !recovering) {
            recovering = true;
            console.warn(`${TAG} 连续 ${consecutiveErrors} 次设备错误 (code=${errorCode})，释放所有输入并尝试恢复: ${err}`);
            this.buttonFlags = 0;
            this.leftStickX = 0;
            this.leftStickY = 0;
            this.rightStickX = 0;
            this.rightStickY = 0;
            this.leftTrigger = 0;
            this.rightTrigger = 0;
            this.reportInput();
          }
          
          // 超过恢复上限 → 放弃
          if (consecutiveErrors >= MAX_RECOVERY_ERRORS) {
            console.error(`${TAG} 连续 ${consecutiveErrors} 次错误，恢复超时，停止控制器`);
            break;
          }
          
          // 指数退避：50ms → 100ms → 200ms (cap)
          const backoffMs = Math.min(50 * Math.pow(2, Math.min(consecutiveErrors - 1, 2)), 200);
          await this.sleep(backoffMs);
        }
      }
    }
    
    console.info(`${TAG} 输入循环结束`);
    
    // 根据错误类型决定是否通知设备移除
    if (!this.stopped) {
      console.warn(`${TAG} 由于设备断开/IO错误，自动停止控制器`);
      this.stop();
    }
  }
  
  /**
   * 启动控制器
   */
  start(): boolean {
    console.info(`${TAG} 启动控制器: VID=0x${this.vendorId.toString(16)}, PID=0x${this.productId.toString(16)}, DDK=${this.ddkPollingEnabled}`);
    this.markInitializing();

    // 查找端点
    if (!this.findEndpoints()) {
      console.error(`${TAG} 查找端点失败`);
      return false;
    }

    // ====== 优先尝试 DDK 路径 (绕过 usbManager IPC 瓶颈) ======
    console.info(`${TAG} DDK 条件: enabled=${this.ddkPollingEnabled}, available=${DdkUsbPoller.isAvailable()}, inEp=${this.inEndpoint !== null}`);
    if (this.ddkPollingEnabled && DdkUsbPoller.isAvailable() && this.inEndpoint) {
      const ddkStarted = this.tryDdkPath();
      if (ddkStarted) {
        return true;
      }
      console.warn(`${TAG} DDK 路径失败，回退到 usbManager 路径`);
    }

    // ====== 回退: usbManager 路径 ======

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

    // ArkTS async 轮询
    this.inputLoop();

    return true;
  }

  /**
   * 尝试通过 USB DDK 路径启动控制器
   * DDK 完全绕过 usbManager，需要在 claimInterface 之前调用
   *
   * @returns 是否成功
   */
  private tryDdkPath(): boolean {
    console.info(`${TAG} 尝试 DDK 路径...`);

    // Step 1: 初始化 DDK
    const initResult = DdkUsbPoller.init();
    if (initResult.code !== 0) {
      console.warn(`${TAG} DDK init 失败: ${initResult.error}`);
      return false;
    }

    // Step 2: 通过 DDK 查找设备
    let ddkDeviceId: number | undefined;

    // 方式 A: GetDevices + 匹配 VID/PID
    const findResult = DdkUsbPoller.findDevice(this.vendorId, this.productId);
    if (findResult.found && findResult.deviceId !== undefined) {
      ddkDeviceId = findResult.deviceId;
    } else {
      // 方式 B: 从 busNum/devAddress 构造 deviceId
      console.info(`${TAG} GetDevices 未找到设备，尝试 makeDeviceId...`);
      const makeResult = DdkUsbPoller.makeDeviceId(this.device.busNum, this.device.devAddress);
      if (makeResult.found && makeResult.deviceId !== undefined) {
        ddkDeviceId = makeResult.deviceId;
      }
    }

    if (ddkDeviceId === undefined) {
      console.warn(`${TAG} DDK 无法获取 deviceId`);
      return false;  // pipe 未关闭，无需恢复
    }
    const ifaceIndex = this.usbInterface?.id ?? 0;
    const inEp = this.inEndpoint!.address;
    const outEp = this.outEndpoint?.address ?? 0;
    const maxPkt = this.inEndpoint!.maxPacketSize || 64;

    console.info(`${TAG} DDK 设备已匹配: deviceId=${ddkDeviceId}, iface=${ifaceIndex}, inEp=0x${inEp.toString(16)}, outEp=0x${outEp.toString(16)}`);

    // Step 3: 关闭 usbManager 管道 (DDK 无法在 usbManager 已连接的设备上 ClaimInterface)
    if (this.pipe) {
      console.info(`${TAG} 关闭 usbManager 管道以释放设备给 DDK...`);
      try {
        usbManager.closePipe(this.pipe);
      } catch (err) {
        console.warn(`${TAG} closePipe 异常: ${err}`);
      }
      this.pipe = null;
    }

    // Step 4: 创建 DDK poller 并启动 (内部会 ClaimInterface + CreateMemMap + pthread)
    this.ddkPoller = new DdkUsbPoller();
    const started = this.ddkPoller.start(
      ddkDeviceId,
      ifaceIndex,
      inEp,
      outEp,
      maxPkt,
      (data: Uint8Array, _length: number) => {
        if (this.stopped) return;
        // data.length === length (NAPI 已按实际长度创建)，无需 slice 避免额外堆分配
        if (this.handleRead(data)) {
          this.reportInput();
        }
      },
      (errorCode: number) => {
        if (this.stopped) return;
        
        // 智能恢复协议：
        // -1 = 设备暂时丢失，原生层正在尝试恢复，释放所有输入防止角色一直跑
        // -2 = 设备已恢复，输入将自动恢复
        // 正值 = 致命错误（恢复超时或非 IO 错误），停止控制器
        if (errorCode === -1) {
          console.warn(`${TAG} DDK 设备暂时丢失，释放所有输入`);
          this.buttonFlags = 0;
          this.leftStickX = 0;
          this.leftStickY = 0;
          this.rightStickX = 0;
          this.rightStickY = 0;
          this.leftTrigger = 0;
          this.rightTrigger = 0;
          this.reportInput();
          return;
        }
        
        if (errorCode === -2) {
          console.info(`${TAG} DDK 设备已恢复，输入将自动恢复`);
          return;
        }
        
        console.error(`${TAG} DDK 轮询致命错误: ${errorCode}, 停止控制器`);
        this.stop();
      },
      100  // 100ms timeout per read
    );

    if (!started) {
      console.warn(`${TAG} DDK startPoller 失败`);
      this.ddkPoller = null;
      // 恢复 usbManager 管道 (DDK 失败后需要回退到 usbManager)
      this.reconnectPipe();
      return false;
    }

    // Step 4: 通过 DDK 执行初始化 (发送 init 包)
    this.stopped = false;
    this.useDdkPolling = true;
    this.ddkActive = true;

    if (!this.doInit()) {
      console.warn(`${TAG} DDK 路径下 doInit 失败`);
      // doInit 失败不一定要终止 — 某些控制器不需要 init
    }

    // DDK 已启动，标记就绪并通知
    this.notifyDeviceAdded();

    console.info(`${TAG} 控制器已启动 (DDK 高速轮询)`);
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
    this.markStopped();

    // 先发送振动停止命令（必须在 DDK 释放前，否则无法发送）
    this.rumble(0, 0);

    // 保存 DDK 状态，再停止 DDK 轮询器
    const wasDdkPolling = this.useDdkPolling;
    if (this.ddkPoller) {
      this.ddkPoller.stop();
      this.ddkPoller = null;
      this.useDdkPolling = false;
    }
    
    // 释放接口 (仅在 usbManager 路径下，DDK 路径由 stopPoller 内部释放)
    if (!wasDdkPolling && this.pipe && this.usbInterface) {
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
    return !this.stopped && (this.pipe !== null || this.useDdkPolling);
  }

  /**
   * 恢复 usbManager 管道 (DDK 失败后回退用)
   */
  private reconnectPipe(): void {
    if (this.pipe) return; // 已有管道
    try {
      console.info(`${TAG} 恢复 usbManager 管道...`);
      this.pipe = usbManager.connectDevice(this.device);
      console.info(`${TAG} usbManager 管道已恢复`);
    } catch (err) {
      console.error(`${TAG} 恢复管道失败: ${err}`);
    }
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
