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
 * 使用原生层解析的通用 HID 手柄控制器
 * 
 * 这个版本使用 C++ 原生层来解析 HID 报告
 * 支持更多手柄类型，解析更准确
 */

import { usbManager } from '@kit.BasicServicesKit';
import { AbstractController } from './AbstractController';
import { UsbDriverListener } from './UsbDriverListener';
import { ButtonFlags, UsbClass, ControllerType, ControllerCapabilities } from './ControllerConstants';
import { NativeHidParserService, NativeGamepadState, NativeGamepadType, NativeButtonFlags } from './NativeHidParserService';
import { isHardwareError, createUsbError, UsbError } from './UsbErrorCodes';

const TAG = '[USB-NativeHID]';

/**
 * 使用原生解析器的通用 HID 手柄控制器
 */
export class NativeHidController extends AbstractController {
  private device: usbManager.USBDevice;
  private pipe: usbManager.USBDevicePipe;
  private running: boolean = false;
  private inputEndpoint: number = 0;
  private outputEndpoint: number = 0;
  private inputMaxPacketSize: number = 64;
  private nativeParser: NativeHidParserService;
  private forceProtocolType: number = 0;  // 0=自动, 1=Xbox, 2=DS4, 3=Switch, 5=DualSense
  
  // 最后活动时间跟踪（用于检测雷蛇等静默断开的设备）
  private lastActivityTime: number = 0;
  private consecutiveTimeouts: number = 0;
  // 连续超时阈值：如果连续超过这个次数超时且没有数据，可能已断开
  private static readonly SILENT_DISCONNECT_TIMEOUT_COUNT = 10;  // 10次超时 = 30秒（每次3秒）

  /**
   * 协议类型常量
   */
  static readonly PROTOCOL_AUTO = 0;
  static readonly PROTOCOL_XBOX = 1;
  static readonly PROTOCOL_DS4 = 2;
  static readonly PROTOCOL_SWITCH = 3;
  static readonly PROTOCOL_GENERIC = 4;
  static readonly PROTOCOL_DUALSENSE = 5;

  constructor(
    device: usbManager.USBDevice,
    pipe: usbManager.USBDevicePipe,
    deviceId: number,
    listener: UsbDriverListener
  ) {
    super(deviceId, listener, device.vendorId, device.productId);
    this.device = device;
    this.pipe = pipe;
    this.nativeParser = NativeHidParserService.getInstance();

    // 初始化原生解析器
    this.nativeParser.init();

    // 获取手柄类型和名称
    const nativeType = this.nativeParser.getGamepadType(device.vendorId, device.productId);
    this.deviceName = this.nativeParser.getGamepadName(device.vendorId, device.productId);

    // 转换类型
    switch (nativeType) {
      case NativeGamepadType.XBOX:
        this.type = ControllerType.XBOX;
        break;
      case NativeGamepadType.PLAYSTATION:
        this.type = ControllerType.PS;
        break;
      case NativeGamepadType.SWITCH:
        this.type = ControllerType.NINTENDO;
        break;
      default:
        this.type = ControllerType.XBOX; // 默认模拟 Xbox
    }

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

    console.info(`${TAG} 创建控制器: ${this.deviceName} (type=${nativeType})`);
  }

  /**
   * 设置强制协议类型
   * 用于手柄有多种模式（如 DS4 模拟模式）时强制使用特定协议
   * @param protocolType 协议类型 (0=自动, 1=Xbox, 2=DS4, 3=Switch, 4=Generic, 5=DualSense)
   */
  setForceProtocolType(protocolType: number): void {
    this.forceProtocolType = protocolType;
    console.info(`${TAG} 设置强制协议类型: ${protocolType}`);
  }

  /**
   * 获取当前强制协议类型
   */
  getForceProtocolType(): number {
    return this.forceProtocolType;
  }

  /**
   * HID 子类常量
   * HID 协议定义：
   * - 子类 1: Boot Interface
   * - 协议 1: 键盘
   * - 协议 2: 鼠标
   */
  private static readonly HID_SUBCLASS_BOOT = 1;
  private static readonly HID_PROTOCOL_KEYBOARD = 1;
  private static readonly HID_PROTOCOL_MOUSE = 2;

  /**
   * 检查是否可以驱动该设备
   */
  static canClaimDevice(device: usbManager.USBDevice): boolean {
    const parser = NativeHidParserService.getInstance();
    parser.init();

    // 检查原生层是否支持
    if (parser.isSupportedGamepad(device.vendorId, device.productId)) {
      console.info(`${TAG} 原生支持的手柄: VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)}`);
      return true;
    }

    // 检查是否有 HID 接口（作为后备）
    if (!device.configs || device.configs.length === 0) {
      return false;
    }

    const config = device.configs[0];
    if (!config.interfaces || config.interfaces.length === 0) {
      return false;
    }

    for (let i = 0; i < config.interfaces.length; i++) {
      const iface = config.interfaces[i];
      if (iface.clazz === UsbClass.USB_CLASS_HID) {
        // 检查是否是键盘或鼠标 (Boot Interface 子类)
        // HID Boot Interface 使用 subClass=1, protocol 指示设备类型
        // protocol=1 表示键盘，protocol=2 表示鼠标
        if (iface.subClass === NativeHidController.HID_SUBCLASS_BOOT) {
          if (iface.protocol === NativeHidController.HID_PROTOCOL_KEYBOARD) {
            console.info(`${TAG} 跳过键盘设备: VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)}`);
            return false;
          }
          if (iface.protocol === NativeHidController.HID_PROTOCOL_MOUSE) {
            console.info(`${TAG} 跳过鼠标设备: VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)}`);
            return false;
          }
        }
        
        // 额外检查设备名称排除键盘/鼠标
        const nameLower = device.name.toLowerCase();
        if (nameLower.includes('keyboard') || nameLower.includes('键盘')) {
          console.info(`${TAG} 通过名称跳过键盘: ${device.name}`);
          return false;
        }
        if (nameLower.includes('mouse') || nameLower.includes('鼠标')) {
          console.info(`${TAG} 通过名称跳过鼠标: ${device.name}`);
          return false;
        }
        
        console.info(`${TAG} 检测到 HID 接口设备: VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)}, subClass=${iface.subClass}, protocol=${iface.protocol}`);
        return true;
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

    for (let i = 0; i < config.interfaces.length; i++) {
      const iface = config.interfaces[i];
      if (iface.clazz === UsbClass.USB_CLASS_HID && iface.endpoints) {
        for (let j = 0; j < iface.endpoints.length; j++) {
          const ep = iface.endpoints[j];
          // 记录端点详情，包括 interval
          console.info(`${TAG} 端点[${j}]: addr=0x${ep.address.toString(16)}, dir=${(ep.direction & 0x80) ? 'IN' : 'OUT'}, type=${ep.attributes}, maxPkt=${ep.maxPacketSize}, interval=${ep.interval}ms`);
          
          if ((ep.direction & 0x80) !== 0) {
            this.inputEndpoint = ep.address;
            this.inputMaxPacketSize = ep.maxPacketSize;
          } else {
            this.outputEndpoint = ep.address;
          }
        }

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

    console.info(`${TAG} 端点配置: IN=0x${this.inputEndpoint.toString(16)}, OUT=0x${this.outputEndpoint.toString(16)}`);
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

    try {
      usbManager.closePipe(this.pipe);
    } catch (err) {
      console.error(`${TAG} 关闭管道失败:`, err);
    }

    console.info(`${TAG} 控制器已停止: ${this.deviceName}`);
  }
  
  /**
   * 检查控制器是否已连接
   */
  isConnected(): boolean {
    return this.running;
  }

  /**
   * 获取最后活动时间
   * 用于检测静默断开
   */
  getLastActivityTime(): number {
    return this.lastActivityTime;
  }

  /**
   * 检查控制器是否可能已静默断开
   * @param inactivityThresholdMs 不活动阈值（毫秒）
   * @returns true 表示可能已断开
   */
  mayBeSilentlyDisconnected(inactivityThresholdMs: number = 30000): boolean {
    if (!this.running) {
      return true;
    }
    const now = Date.now();
    return (now - this.lastActivityTime) > inactivityThresholdMs;
  }

  private async inputLoop(): Promise<void> {
    const buffer = new Uint8Array(this.inputMaxPacketSize);
    let isSleepMode = false;
    let hardwareError = false;
    
    // USB 读取超时时间（与 Android 一致为 3000ms）
    // 用于判断错误是超时还是真正的 I/O 错误
    const BULK_READ_TIMEOUT = 3000;
    // 快速失败阈值：如果读取在超时之前就失败（耗时 < 1秒），认为是 I/O 错误
    const QUICK_FAIL_THRESHOLD = 1000;
    
    // 轮询率统计
    let pollCount = 0;
    let lastStatTime = Date.now();
    const STAT_INTERVAL_MS = 5000;  // 每 5 秒输出一次统计
    
    // 初始化最后活动时间
    this.lastActivityTime = Date.now();
    this.consecutiveTimeouts = 0;

    while (this.running) {
      // 记录读取开始时间（用于检测真正的 I/O 错误 vs 超时）
      const startTime = Date.now();
      
      try {
        const result = await this.bulkRead(buffer);
        if (result > 0) {
          pollCount++;
          // 重置超时计数器
          this.consecutiveTimeouts = 0;
          this.lastActivityTime = Date.now();
          
          this.processInputReport(buffer.slice(0, result));
          
          // 统计轮询率
          const now = Date.now();
          if (now - lastStatTime >= STAT_INTERVAL_MS) {
            const pollRate = (pollCount * 1000) / (now - lastStatTime);
            console.info(`${TAG} 轮询率: ${pollRate.toFixed(1)} Hz (${pollCount} 次/${((now - lastStatTime) / 1000).toFixed(1)}秒)`);
            pollCount = 0;
            lastStatTime = now;
          }
        }
      } catch (err) {
        if (this.running) {
          const elapsedTime = Date.now() - startTime;
          
          // 检查错误类型
          const usbErr = err instanceof UsbError ? err : null;
          const errorCode = usbErr ? usbErr.code : 0;
          const retryable = usbErr ? usbErr.retryable : true;  // 默认可重试
          
          // 采用 Android 的策略：通过读取耗时来判断是超时还是真正的 I/O 错误
          // 参考: Android AbstractXboxController.java
          // - 如果 bulkTransfer 返回错误，且耗时 < 1秒，说明是真正的设备 I/O 错误
          // - 如果耗时接近超时时间（3秒），说明只是正常超时，设备仍然连接
          
          if (errorCode === -8) {  // USB_ERROR_TIMEOUT
            // 检查是否是快速失败（真正的 I/O 错误伪装成超时）
            if (elapsedTime < QUICK_FAIL_THRESHOLD) {
              console.warn(`${TAG} 检测到设备 I/O 错误（快速失败：${elapsedTime}ms < ${QUICK_FAIL_THRESHOLD}ms）`);
              // 检查是否应该忽略断开信号
              if (this.ignoreDisconnect) {
                console.info(`${TAG} 忽略快速失败错误（用户已启用忽略断开设置）`);
                await this.sleep(50);
                continue;
              }
              hardwareError = true;
              break;
            }
            
            // 正常超时 - 累计连续超时次数（用于检测雷蛇等静默断开的设备）
            this.consecutiveTimeouts++;
            if (this.consecutiveTimeouts >= NativeHidController.SILENT_DISCONNECT_TIMEOUT_COUNT) {
              console.warn(`${TAG} 检测到可能的静默断开: 连续 ${this.consecutiveTimeouts} 次超时无数据`);
              // 检查是否应该忽略断开信号
              if (this.ignoreDisconnect) {
                console.info(`${TAG} 忽略静默断开检测（用户已启用忽略断开设置）`);
                this.consecutiveTimeouts = 0;  // 重置计数器
                continue;
              }
              isSleepMode = true;
              break;
            }
            
            // 继续轮询（手柄可能暂时没有输入变化）
            continue;
          } else if (errorCode === -4) {  // USB_ERROR_NO_DEVICE
            console.warn(`${TAG} 设备不可达: ${err}`);
            // 检查是否应该忽略断开信号
            if (this.ignoreDisconnect) {
              console.info(`${TAG} 忽略设备不可达错误（用户已启用忽略断开设置）`);
              await this.sleep(50);
              continue;
            }
            isSleepMode = true;
            break;
          } else if (isHardwareError(errorCode)) {
            console.error(`${TAG} 检测到硬件错误: ${err}`);
            // 检查是否应该忽略断开信号
            if (this.ignoreDisconnect) {
              console.info(`${TAG} 忽略硬件错误（用户已启用忽略断开设置）`);
              await this.sleep(50);
              continue;
            }
            hardwareError = true;
            // 硬件错误 - 立即停止
            break;
          } else {
            // 其他错误 - 也检查是否快速失败
            if (elapsedTime < QUICK_FAIL_THRESHOLD) {
              console.warn(`${TAG} 检测到设备 I/O 错误（错误码: ${errorCode}, 耗时: ${elapsedTime}ms）`);
              // 检查是否应该忽略断开信号
              if (this.ignoreDisconnect) {
                console.info(`${TAG} 忽略快速失败错误（用户已启用忽略断开设置）`);
                await this.sleep(50);
                continue;
              }
              hardwareError = true;
              break;
            }
            console.error(`${TAG} 输入读取错误: ${err}`);
            // 其他错误 - 如果标记为可重试则继续，否则停止
            if (!retryable) {
              // 检查是否应该忽略断开信号
              if (this.ignoreDisconnect) {
                console.info(`${TAG} 忽略不可重试错误（用户已启用忽略断开设置）`);
                await this.sleep(50);
                continue;
              }
              break;
            }
            await this.sleep(50);  // 增加延迟到 50ms
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
    // 使用较长的超时（与 Android AbstractXboxController 一致为 3000ms）
    // 这不会影响轮询率，因为有数据时会立即返回
    // 较长超时可以减少无数据时的空循环开销
    // 同时用于判断是超时还是真正的 I/O 错误（参见 inputLoop 中的 QUICK_FAIL_THRESHOLD）
    const timeout: number = 3000;

    try {
      const endpoint: usbManager.USBEndpoint = {
        address: this.inputEndpoint,
        attributes: 3,
        interval: 1,
        maxPacketSize: this.inputMaxPacketSize,
        direction: 0x80 as usbManager.USBRequestDirection,
        interfaceId: 0,
        number: this.inputEndpoint,
        type: 3
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
   * 使用原生层处理 HID 报告
   */
  private processInputReport(data: Uint8Array): void {
    // 调用原生解析器，传入强制协议类型
    const state = this.nativeParser.parseHidReport(
      this.vendorId,
      this.productId,
      data,
      this.forceProtocolType
    );

    if (!state) {
      // 原生解析失败，使用 TypeScript 后备解析器
      const hexStr = Array.from(data.slice(0, Math.min(data.length, 16)))
        .map(b => b.toString(16).padStart(2, '0')).join(' ');
      this.fallbackParseHidReport(data, hexStr);
      return;
    }

    // 转换原生按钮标志到 Moonlight 格式
    this.buttonFlags = this.convertNativeButtons(state.buttons);

    // 转换摇杆值（原生层返回 -32768 到 32767，需要转换为 -1.0 到 1.0）
    this.leftStickX = state.leftStickX / 32767.0;
    this.leftStickY = state.leftStickY / 32767.0;
    this.rightStickX = state.rightStickX / 32767.0;
    this.rightStickY = state.rightStickY / 32767.0;

    // 转换扳机值（原生层返回 0-255，需要转换为 0.0 到 1.0）
    this.leftTrigger = state.leftTrigger / 255.0;
    this.rightTrigger = state.rightTrigger / 255.0;

    // 报告输入
    this.reportInput();
  }

  /**
   * TypeScript 后备 HID 解析器
   * 用于原生解析器不可用时的通用 HID 手柄解析
   *
   * 通用手柄格式 (10字节):
   * [0] = Report ID (通常是 0x01)
   * [1] = Left Stick X (0x00-0xFF, 0x80 = center)
   * [2] = Left Stick Y (0x00-0xFF, 0x80 = center)
   * [3] = Right Stick X (0x00-0xFF, 0x80 = center)
   * [4] = Right Stick Y (0x00-0xFF, 0x80 = center)
   * [5] = Triggers/misc (varies)
   * [6] = HAT/D-Pad (0x0F = center, 0-7 = directions)
   * [7] = Buttons byte 1 (function buttons: Start, Select, LS, RS, etc.)
   * [8] = Buttons byte 2 (face buttons: A, B, X, Y, LB, RB)
   * [9] = Reserved
   */
  private fallbackParseHidReport(data: Uint8Array, hexStr: string): void {
    if (data.length < 9) {
      console.warn(`${TAG} HID 数据太短: ${data.length}`);
      return;
    }

    // 解析摇杆 (字节 1-4, 0x00-0xFF, 0x80=中心)
    // 转换为 -1.0 到 1.0
    this.leftStickX = (data[1] - 128) / 127.0;
    this.leftStickY = (data[2] - 128) / 127.0;
    this.rightStickX = (data[3] - 128) / 127.0;
    this.rightStickY = (data[4] - 128) / 127.0;

    // 限制范围
    this.leftStickX = Math.max(-1.0, Math.min(1.0, this.leftStickX));
    this.leftStickY = Math.max(-1.0, Math.min(1.0, this.leftStickY));
    this.rightStickX = Math.max(-1.0, Math.min(1.0, this.rightStickX));
    this.rightStickY = Math.max(-1.0, Math.min(1.0, this.rightStickY));

    // 解析 HAT/D-Pad (字节 6)
    // HAT 值: 0=Up, 1=UpRight, 2=Right, 3=DownRight, 4=Down, 5=DownLeft, 6=Left, 7=UpLeft, 0x0F=Center
    let flags = 0;
    const hat = data[6] & 0x0F;
    switch (hat) {
      case 0: // Up
        flags |= ButtonFlags.UP_FLAG;
        break;
      case 1: // Up-Right
        flags |= ButtonFlags.UP_FLAG | ButtonFlags.RIGHT_FLAG;
        break;
      case 2: // Right
        flags |= ButtonFlags.RIGHT_FLAG;
        break;
      case 3: // Down-Right
        flags |= ButtonFlags.DOWN_FLAG | ButtonFlags.RIGHT_FLAG;
        break;
      case 4: // Down
        flags |= ButtonFlags.DOWN_FLAG;
        break;
      case 5: // Down-Left
        flags |= ButtonFlags.DOWN_FLAG | ButtonFlags.LEFT_FLAG;
        break;
      case 6: // Left
        flags |= ButtonFlags.LEFT_FLAG;
        break;
      case 7: // Up-Left
        flags |= ButtonFlags.UP_FLAG | ButtonFlags.LEFT_FLAG;
        break;
      default: // 0x0F = center, no direction
        break;
    }

    // 解析按钮字节
    const btn1 = data[7]; // 功能按钮
    const btn2 = data[8]; // 面板按钮

    // VID 0x413D 手柄的按钮映射 (通用 HID 手柄格式):
    // 字节 7 (功能按钮):
    //   bit 0 = Select/Back
    //   bit 1 = Start
    //   bit 2 = Home/Guide
    //   bit 3 = Left Stick Click
    //   bit 4 = Right Stick Click
    //   bit 5 = LB
    //   bit 6 = RB
    //   bit 7 = LT (digital)
    //
    // 字节 8 (面板按钮):
    //   bit 0 = A
    //   bit 1 = B
    //   bit 2 = X
    //   bit 3 = Y

    // 功能按钮 (字节 7)
    if (btn1 & 0x01) flags |= ButtonFlags.BACK_FLAG;      // Select/Back
    if (btn1 & 0x02) flags |= ButtonFlags.PLAY_FLAG;      // Start
    if (btn1 & 0x04) flags |= ButtonFlags.SPECIAL_BUTTON_FLAG; // Home/Guide
    if (btn1 & 0x08) flags |= ButtonFlags.LS_CLK_FLAG;    // Left Stick Click
    if (btn1 & 0x10) flags |= ButtonFlags.RS_CLK_FLAG;    // Right Stick Click
    if (btn1 & 0x20) flags |= ButtonFlags.LB_FLAG;        // LB
    if (btn1 & 0x40) flags |= ButtonFlags.RB_FLAG;        // RB

    // 面板按钮 (字节 8)
    if (btn2 & 0x01) flags |= ButtonFlags.A_FLAG;   // A
    if (btn2 & 0x02) flags |= ButtonFlags.B_FLAG;   // B
    if (btn2 & 0x04) flags |= ButtonFlags.X_FLAG;   // X
    if (btn2 & 0x08) flags |= ButtonFlags.Y_FLAG;   // Y

    // 更新按钮标志
    this.buttonFlags = flags;

    // 报告输入
    this.reportInput();
  }

  /**
   * 转换原生按钮标志到 Moonlight 格式
   */
  private convertNativeButtons(nativeButtons: number): number {
    let flags = 0;

    // 方向键
    if (nativeButtons & NativeButtonFlags.UP) flags |= ButtonFlags.UP_FLAG;
    if (nativeButtons & NativeButtonFlags.DOWN) flags |= ButtonFlags.DOWN_FLAG;
    if (nativeButtons & NativeButtonFlags.LEFT) flags |= ButtonFlags.LEFT_FLAG;
    if (nativeButtons & NativeButtonFlags.RIGHT) flags |= ButtonFlags.RIGHT_FLAG;

    // 功能键
    if (nativeButtons & NativeButtonFlags.START) flags |= ButtonFlags.PLAY_FLAG;
    if (nativeButtons & NativeButtonFlags.BACK) flags |= ButtonFlags.BACK_FLAG;
    if (nativeButtons & NativeButtonFlags.LS_CLK) flags |= ButtonFlags.LS_CLK_FLAG;
    if (nativeButtons & NativeButtonFlags.RS_CLK) flags |= ButtonFlags.RS_CLK_FLAG;

    // 肩键
    if (nativeButtons & NativeButtonFlags.LB) flags |= ButtonFlags.LB_FLAG;
    if (nativeButtons & NativeButtonFlags.RB) flags |= ButtonFlags.RB_FLAG;

    // 面板按钮
    if (nativeButtons & NativeButtonFlags.A) flags |= ButtonFlags.A_FLAG;
    if (nativeButtons & NativeButtonFlags.B) flags |= ButtonFlags.B_FLAG;
    if (nativeButtons & NativeButtonFlags.X) flags |= ButtonFlags.X_FLAG;
    if (nativeButtons & NativeButtonFlags.Y) flags |= ButtonFlags.Y_FLAG;

    // 特殊按钮
    if (nativeButtons & NativeButtonFlags.HOME) flags |= ButtonFlags.SPECIAL_BUTTON_FLAG;

    return flags;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), ms);
    });
  }

  rumble(lowFreqMotor: number, highFreqMotor: number): void {
    if (this.outputEndpoint === 0) {
      return;
    }

    // 获取震动命令
    const cmd = this.nativeParser.createRumbleCommand(
      this.vendorId,
      this.productId,
      Math.round(lowFreqMotor * 65535),
      Math.round(highFreqMotor * 65535)
    );

    if (cmd) {
      this.sendOutputReport(cmd);
    }
  }

  private async sendOutputReport(data: Uint8Array): Promise<void> {
    if (this.outputEndpoint === 0) {
      return;
    }

    try {
      const endpoint: usbManager.USBEndpoint = {
        address: this.outputEndpoint,
        attributes: 3,
        interval: 1,
        maxPacketSize: 64,
        direction: 0x00 as usbManager.USBRequestDirection,
        interfaceId: 0,
        number: this.outputEndpoint,
        type: 3
      };

      await usbManager.bulkTransfer(this.pipe, endpoint, data, 100);
    } catch (err) {
      console.error(`${TAG} 发送输出报告失败:`, err);
    }
  }

  rumbleTriggers(leftTrigger: number, rightTrigger: number): void {
    // 大多数手柄不支持扳机震动
  }
}
