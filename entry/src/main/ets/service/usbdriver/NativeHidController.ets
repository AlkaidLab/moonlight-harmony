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
import { NativeHidParserService, NativeGamepadType } from './NativeHidParserService';
import { HidReportParserUtil } from './HidReportParserUtil';
import { createUsbError, UsbError } from './UsbErrorCodes';

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
  private interfaceId: number = 0;
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

        this.interfaceId = iface.id;

        try {
          const ret = usbManager.claimInterface(this.pipe, iface, true);
          if (ret === 0) {
            console.info(`${TAG} 成功声明 HID 接口 (id=${iface.id})`);
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

    this.markInitializing();
    this.running = true;
    this.lastActivityTime = Date.now();
    this.notifyDeviceAdded();

    // ArkTS async 轮询
    this.inputLoop();

    console.info(`${TAG} 控制器已启动 (ArkTS 轮询): ${this.deviceName}`);
    return true;
  }

  stop(): void {
    if (!this.running) {
      return;
    }

    this.running = false;
    this.markStopped();

    this.notifyDeviceRemoved();

    // 释放 USB 接口，确保系统 HID 驱动能重新接管设备
    if (this.pipe && this.device) {
      try {
        const config = this.device.configs[0];
        if (config && config.interfaces) {
          let released = false;
          for (let i = 0; i < config.interfaces.length; i++) {
            const iface = config.interfaces[i];
            if (iface.clazz === 3 /* USB_CLASS_HID */) {
              usbManager.releaseInterface(this.pipe, iface);
              console.info(`${TAG} 已释放 HID 接口 ${i}`);
              released = true;
              break;
            }
          }
          if (!released) {
            console.warn(`${TAG} 未找到 HID 接口（共 ${config.interfaces.length} 个接口）`);
          }
        }
      } catch (err) {
        console.error(`${TAG} 释放接口异常:`, err);
      }
    }

    try {
      usbManager.closePipe(this.pipe);
      console.info(`${TAG} closePipe 成功`);
    } catch (err) {
      console.error(`${TAG} closePipe 失败:`, err);
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

  /**
   * ArkTS 后备轮询循环（当 Native Poller 不可用时使用）
   */
  private async inputLoop(): Promise<void> {
    const buffer = new Uint8Array(this.inputMaxPacketSize);
    
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
    
    // 智能恢复状态
    let consecutiveErrors = 0;
    const MAX_RECOVERY_ERRORS = 50;  // ~10s
    let recovering = false;

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
          
          // 恢复成功
          if (recovering) {
            console.info(`${TAG} 设备已恢复，累计错误 ${consecutiveErrors} 次`);
            consecutiveErrors = 0;
            recovering = false;
          }
          
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
          const usbErr = err instanceof UsbError ? err : null;
          const errorCode = usbErr ? usbErr.code : 0;
          
          // 超时错误
          if (errorCode === -8) {  // USB_ERROR_TIMEOUT
            // 快速失败（真正的 I/O 错误伪装成超时）→ 按非超时错误处理
            if (elapsedTime < QUICK_FAIL_THRESHOLD) {
              // fall through to smart recovery below
            } else {
              // 正常超时 - 累计连续超时次数（用于检测雷蛇等静默断开的设备）
              this.consecutiveTimeouts++;
              if (this.consecutiveTimeouts >= NativeHidController.SILENT_DISCONNECT_TIMEOUT_COUNT) {
                console.warn(`${TAG} 检测到可能的静默断开: 连续 ${this.consecutiveTimeouts} 次超时无数据`);
                // 静默断开也走智能恢复而非直接 break
                // 如果设备只是暂时无数据，最终会恢复
              } else {
                continue;
              }
            }
          }
          
          // 非超时错误 / 快速失败 / 静默断开 — 智能恢复
          consecutiveErrors++;
          
          if (consecutiveErrors >= 3 && !recovering) {
            recovering = true;
            console.warn(`${TAG} 连续 ${consecutiveErrors} 次设备错误 (code=${errorCode}, elapsed=${elapsedTime}ms)，尝试恢复: ${err}`);
          }
          
          // 超过恢复上限 → 归零输入并放弃
          if (consecutiveErrors >= MAX_RECOVERY_ERRORS) {
            console.error(`${TAG} 连续 ${consecutiveErrors} 次错误，恢复超时，停止控制器`);
            this.buttonFlags = 0;
            this.leftStickX = 0;
            this.leftStickY = 0;
            this.rightStickX = 0;
            this.rightStickY = 0;
            this.leftTrigger = 0;
            this.rightTrigger = 0;
            this.reportInput();
            break;
          }
          
          // 指数退避：50ms → 100ms → 200ms (cap)
          const backoffMs = Math.min(50 * Math.pow(2, Math.min(consecutiveErrors - 1, 2)), 200);
          await this.sleep(backoffMs);
        }
      }
    }
    
    // 根据错误类型决定是否通知设备移除
    if (this.running) {
      console.warn(`${TAG} 由于设备断开/IO错误，自动停止控制器`);
      this.stop();
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
   * 使用原生层处理 HID 报告（解析逻辑在 HidReportParserUtil，与 HID DDK 通道共享）
   */
  private processInputReport(data: Uint8Array): void {
    const state = HidReportParserUtil.parseToState(
      this.vendorId,
      this.productId,
      data,
      this.forceProtocolType
    );

    if (!state) {
      return;
    }

    this.buttonFlags = state.buttonFlags;
    this.leftStickX = state.leftStickX;
    this.leftStickY = state.leftStickY;
    this.rightStickX = state.rightStickX;
    this.rightStickY = state.rightStickY;
    this.leftTrigger = state.leftTrigger;
    this.rightTrigger = state.rightTrigger;

    this.reportInput();
  }

  rumble(lowFreqMotor: number, highFreqMotor: number): void {
    if (this.outputEndpoint === 0) {
      return;
    }

    // Native parser expects Moonlight rumble values in the same 0..65535 range as AbstractController.
    const cmd = this.nativeParser.createRumbleCommand(
      this.vendorId,
      this.productId,
      this.clampRumbleValue(lowFreqMotor),
      this.clampRumbleValue(highFreqMotor)
    );

    if (cmd) {
      this.sendOutputReport(cmd);
    }
  }

  private clampRumbleValue(value: number): number {
    if (!Number.isFinite(value)) return 0;
    return Math.max(0, Math.min(65535, Math.round(value)));
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
