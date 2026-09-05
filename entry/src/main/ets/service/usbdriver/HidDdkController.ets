/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * 本程序基于 GPL-3.0 发布，详见 LICENSE
 */

/**
 * 基于 HID DDK (hidraw) 的 USB 手柄控制器
 *
 * 与 usbManager bulkTransfer / USB DDK 轮询通道的区别：
 * - 不 open pipe、不 claim 接口、不 detach 内核 HID 驱动
 * - 输入：OH_Hid_ReadTimeout 阻塞读（内核中断驱动）
 * - 输出：OH_Hid_Write 输出报告（震动）
 * - 解析：与 NativeHidController 共享 HidReportParserUtil
 *
 * 前置条件：start() 前须已 setDeviceLocation()（用于 busNum/devAddress → DDK deviceId）
 */

import { usbManager } from '@kit.BasicServicesKit';
import { AbstractController } from './AbstractController';
import { UsbDriverListener } from './UsbDriverListener';
import { ButtonFlags, ControllerType, ControllerCapabilities } from './ControllerConstants';
import { NativeHidParserService, NativeGamepadType } from './NativeHidParserService';
import { HidReportParserUtil } from './HidReportParserUtil';
import { HidDdkReader, HidReaderStats } from './HidDdkReader';
import { DdkUsbPoller } from './DdkUsbPoller';

const TAG = '[USB-HidDdk]';

export class HidDdkController extends AbstractController {
  private device: usbManager.USBDevice;
  private reader: HidDdkReader = new HidDdkReader();
  private nativeParser: NativeHidParserService;
  private running: boolean = false;
  private forceProtocolType: number = 0;  // 0=自动
  private lastActivityTime: number = 0;

  constructor(
    device: usbManager.USBDevice,
    controllerId: number,
    listener: UsbDriverListener
  ) {
    super(controllerId, listener, device.vendorId, device.productId);
    this.device = device;
    this.nativeParser = NativeHidParserService.getInstance();
    this.nativeParser.init();

    const nativeType = this.nativeParser.getGamepadType(device.vendorId, device.productId);
    this.deviceName = this.nativeParser.getGamepadName(device.vendorId, device.productId);

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
        this.type = ControllerType.XBOX;
    }

    this.capabilities = ControllerCapabilities.ANALOG_TRIGGERS | ControllerCapabilities.RUMBLE;

    this.supportedButtonFlags =
      ButtonFlags.A_FLAG | ButtonFlags.B_FLAG | ButtonFlags.X_FLAG | ButtonFlags.Y_FLAG |
      ButtonFlags.UP_FLAG | ButtonFlags.DOWN_FLAG | ButtonFlags.LEFT_FLAG | ButtonFlags.RIGHT_FLAG |
      ButtonFlags.LB_FLAG | ButtonFlags.RB_FLAG |
      ButtonFlags.LS_CLK_FLAG | ButtonFlags.RS_CLK_FLAG |
      ButtonFlags.BACK_FLAG | ButtonFlags.PLAY_FLAG | ButtonFlags.SPECIAL_BUTTON_FLAG;

    console.info(`${TAG} 创建控制器: ${this.deviceName} (type=${nativeType})`);
  }

  setForceProtocolType(protocolType: number): void {
    this.forceProtocolType = protocolType;
    console.info(`${TAG} 设置强制协议类型: ${protocolType}`);
  }

  getForceProtocolType(): number {
    return this.forceProtocolType;
  }

  start(): boolean {
    if (this.running) {
      return true;
    }
    this.markInitializing();

    // 解析 DDK deviceId（与 DdkUsbPoller 相同的 busNum/devAddress 编码）
    const initResult = DdkUsbPoller.init();
    if (initResult.code !== 0) {
      console.error(`${TAG} USB DDK 初始化失败 (${initResult.error})，无法确定 deviceId`);
      return false;
    }
    const idResult = DdkUsbPoller.makeDeviceId(this.busNum, this.devAddress);
    if (!idResult.found || idResult.deviceId === undefined) {
      console.error(`${TAG} deviceId 解析失败 (${idResult.error})`);
      return false;
    }

    const ok = this.reader.start(
      idResult.deviceId,
      (data: Uint8Array) => this.processInputReport(data),
      (errorCode: number) => this.handleReadError(errorCode),
      100
    );

    if (!ok) {
      console.error(`${TAG} hidraw 通道启动失败: code=${this.reader.lastStartError}，上层将回退旧通道`);
      return false;
    }

    this.running = true;
    this.lastActivityTime = Date.now();
    this.notifyDeviceAdded();

    console.info(`${TAG} 控制器已启动 (hidraw): ${this.deviceName}`);
    return true;
  }

  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    this.markStopped();
    // 先停 reader（join 读线程），再通知移除——避免 tsfn 队列中的残留报文
    // 在设备已通知移除后仍触发 processInputReport 上报
    this.reader.stop();
    this.notifyDeviceRemoved();
    console.info(`${TAG} 控制器已停止: ${this.deviceName}`);
  }

  isConnected(): boolean {
    return this.running;
  }

  getLastActivityTime(): number {
    return this.lastActivityTime;
  }

  mayBeSilentlyDisconnected(inactivityThresholdMs: number = 30000): boolean {
    if (!this.running) {
      return true;
    }
    return (Date.now() - this.lastActivityTime) > inactivityThresholdMs;
  }

  rumble(lowFreqMotor: number, highFreqMotor: number): void {
    const clamp = (value: number): number => {
      if (!Number.isFinite(value)) return 0;
      return Math.max(0, Math.min(65535, Math.round(value)));
    };

    const cmd = this.nativeParser.createRumbleCommand(
      this.vendorId,
      this.productId,
      clamp(lowFreqMotor),
      clamp(highFreqMotor)
    );

    if (cmd) {
      const ret = this.reader.sendOutput(cmd);
      if (ret < 0) {
        console.warn(`${TAG} rumble 输出失败: ret=${ret}`);
      }
    }
  }

  rumbleTriggers(_leftTrigger: number, _rightTrigger: number): void {
    // 大多数手柄不支持扳机震动
  }

  /** 通道标识（供测试页/诊断展示） */
  getTransportInfo(): string {
    return 'HID-DDK';
  }

  getReaderStats(): HidReaderStats {
    return this.reader.getStats();
  }

  private processInputReport(data: Uint8Array): void {
    // stop() 后 tsfn 队列可能仍投递残留报文，直接丢弃
    if (!this.running) {
      return;
    }
    const state = HidReportParserUtil.parseToState(
      this.vendorId,
      this.productId,
      data,
      this.forceProtocolType
    );

    if (!state) {
      return;
    }

    this.lastActivityTime = Date.now();
    this.buttonFlags = state.buttonFlags;
    this.leftStickX = state.leftStickX;
    this.leftStickY = state.leftStickY;
    this.rightStickX = state.rightStickX;
    this.rightStickY = state.rightStickY;
    this.leftTrigger = state.leftTrigger;
    this.rightTrigger = state.rightTrigger;

    this.reportInput();
  }

  private handleReadError(errorCode: number): void {
    console.error(`${TAG} hidraw 读错误: code=${errorCode}，停止控制器`);
    // 归零输入，确保按键释放
    this.buttonFlags = 0;
    this.leftStickX = 0;
    this.leftStickY = 0;
    this.rightStickX = 0;
    this.rightStickY = 0;
    this.leftTrigger = 0;
    this.rightTrigger = 0;
    this.reportInput();
    this.stop();
  }
}
