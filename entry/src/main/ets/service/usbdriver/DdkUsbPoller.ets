/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * DDK USB Poller - 基于 USB DDK 的高速轮询器 ArkTS 封装
 *
 * 使用 HarmonyOS USB DDK (OH_Usb_SendPipeRequest) 实现同步原生轮询，
 * 完全绕过 usbManager IPC 瓶颈。
 *
 * 使用方式:
 *   1. DdkUsbPoller.init() — 全局初始化 (只需一次)
 *   2. DdkUsbPoller.findDevice(vid, pid) — 查找设备获取 DDK deviceId
 *   3. poller = new DdkUsbPoller()
 *   4. poller.start(deviceId, ...) — 声明接口 + 启动轮询
 *   5. poller.sendOutput(data) — 发送输出 (init/rumble)
 *   6. poller.stop() — 停止 + 释放
 */

import nativeLib from 'libmoonlight_nativelib.so';

const TAG = '[DdkUsbPoller]';

// ============================================================
// Native 接口类型
// ============================================================

interface DdkPollerNativeInterface {
  init(): DdkInitResult;
  findDevice(vid: number, pid: number): DdkFindResult;
  makeDeviceId(busNum: number, devAddress: number): DdkMakeDeviceIdResult;
  startPoller(deviceId: number, ifaceIndex: number, inEndpoint: number,
    outEndpoint: number, maxPacketSize: number,
    onData: (pollerId: number, data: Uint8Array, length: number) => void,
    onError: (pollerId: number, errorCode: number) => void,
    timeoutMs: number): number;
  stopPoller(pollerId: number): void;
  sendOutput(pollerId: number, endpoint: number, data: Uint8Array): number;
  getStats(pollerId: number): DdkPollerStats;
  setIgnoreDisconnect(pollerId: number, ignore: boolean): void;
  release(): void;
}

interface NativeLibWithDdkPoller {
  UsbDdkPoller?: DdkPollerNativeInterface;
}

export interface DdkInitResult {
  code: number;
  status?: string;
  error?: string;
  hasGetDevices?: boolean;
  hasGetDeviceDescriptor?: boolean;
}

export interface DdkFindResult {
  found: boolean;
  deviceId?: number;
  deviceCount?: number;
  error?: string;
  ddkError?: number;
}

export interface DdkMakeDeviceIdResult {
  found: boolean;
  deviceId?: number;
  encoding?: string;
  vid?: number;
  pid?: number;
  error?: string;
}

export interface DdkPollerStats {
  totalReads: number;
  totalBytes: number;
}

// ============================================================
// 全局状态
// ============================================================

const ddkNative = (nativeLib as NativeLibWithDdkPoller).UsbDdkPoller;

let ddkInitialized = false;
let ddkAvailable: boolean | null = null;  // null = 未检测

// ============================================================
// DdkUsbPoller 类
// ============================================================

export class DdkUsbPoller {

  private pollerId: number = -1;
  private outEndpointAddr: number = 0;
  private _running: boolean = false;

  // ========== 静态方法 ==========

  /**
   * 检查 DDK Poller 是否可用
   */
  static isAvailable(): boolean {
    if (ddkAvailable !== null) return ddkAvailable;

    if (!ddkNative) {
      console.warn(`${TAG} DDK Poller native 模块不可用`);
      ddkAvailable = false;
      return false;
    }

    ddkAvailable = true;
    return true;
  }

  /**
   * 全局初始化 DDK (只需调用一次)
   *
   * @returns 初始化结果
   */
  static init(): DdkInitResult {
    if (!DdkUsbPoller.isAvailable()) {
      return { code: -1, error: 'DDK native module not available' };
    }

    if (ddkInitialized) {
      return { code: 0, status: 'already initialized' };
    }

    try {
      const result = ddkNative!.init();
      if (result.code === 0) {
        ddkInitialized = true;
        console.info(`${TAG} DDK 初始化成功 (GetDevices=${result.hasGetDevices}, GetDesc=${result.hasGetDeviceDescriptor})`);
      } else {
        console.error(`${TAG} DDK 初始化失败: code=${result.code}, error=${result.error}`);
      }
      return result;
    } catch (err) {
      console.error(`${TAG} DDK init 异常:`, err);
      return { code: -2, error: String(err) };
    }
  }

  /**
   * 查找指定 VID/PID 的 USB 设备
   *
   * @returns 查找结果，包含 DDK deviceId
   */
  static findDevice(vid: number, pid: number): DdkFindResult {
    if (!ddkInitialized) {
      const initResult = DdkUsbPoller.init();
      if (initResult.code !== 0) {
        return { found: false, error: `DDK init failed: ${initResult.error}` };
      }
    }

    try {
      const result = ddkNative!.findDevice(vid, pid);
      if (result.found) {
        console.info(`${TAG} 找到设备: VID=0x${vid.toString(16)} PID=0x${pid.toString(16)} deviceId=${result.deviceId}`);
      } else {
        console.warn(`${TAG} 未找到设备: VID=0x${vid.toString(16)} PID=0x${pid.toString(16)} (${result.deviceCount ?? 0} 个设备可见)`);
      }
      return result;
    } catch (err) {
      console.error(`${TAG} findDevice 异常:`, err);
      return { found: false, error: String(err) };
    }
  }

  /**
   * 通过 busNum/devAddress 构造 DDK deviceId
   * 当 findDevice 返回 0 设备时使用此方法
   *
   * @param busNum     USB 总线号 (来自 usbManager device.busNum)
   * @param devAddress USB 设备地址 (来自 usbManager device.devAddress)
   * @returns 成功时包含 deviceId
   */
  static makeDeviceId(busNum: number, devAddress: number): DdkMakeDeviceIdResult {
    if (!ddkInitialized) {
      const initResult = DdkUsbPoller.init();
      if (initResult.code !== 0) {
        return { found: false, error: `DDK init failed: ${initResult.error}` };
      }
    }

    try {
      const result = ddkNative!.makeDeviceId(busNum, devAddress);
      if (result.found) {
        console.info(`${TAG} deviceId 构造成功: busNum=${busNum} devAddr=${devAddress} → deviceId=${result.deviceId} (${result.encoding})`);
      } else {
        console.warn(`${TAG} deviceId 构造失败: busNum=${busNum} devAddr=${devAddress} — ${result.error}`);
      }
      return result;
    } catch (err) {
      console.error(`${TAG} makeDeviceId 异常:`, err);
      return { found: false, error: String(err) };
    }
  }

  /**
   * 全局释放 DDK
   */
  static release(): void {
    if (ddkInitialized && ddkNative) {
      try {
        ddkNative.release();
        ddkInitialized = false;
        console.info(`${TAG} DDK 已释放`);
      } catch (err) {
        console.error(`${TAG} DDK release 异常:`, err);
      }
    }
  }

  // ========== 实例方法 ==========

  get running(): boolean {
    return this._running;
  }

  /**
   * 启动 DDK 轮询
   *
   * @param deviceId       DDK 设备 ID (来自 findDevice)
   * @param ifaceIndex     USB 接口编号
   * @param inEndpoint     输入端点地址
   * @param outEndpoint    输出端点地址 (0=无输出)
   * @param maxPacketSize  最大包大小
   * @param onData         数据回调
   * @param onError        错误回调
   * @param timeoutMs      单次读取超时 (默认 100ms)
   * @returns 是否启动成功
   */
  start(
    deviceId: number,
    ifaceIndex: number,
    inEndpoint: number,
    outEndpoint: number,
    maxPacketSize: number,
    onData: (data: Uint8Array, length: number) => void,
    onError: (errorCode: number) => void,
    timeoutMs: number = 100
  ): boolean {
    if (!ddkInitialized || !ddkNative) {
      console.error(`${TAG} DDK 未初始化`);
      return false;
    }

    if (this._running) {
      console.warn(`${TAG} Poller 已在运行`);
      return false;
    }

    try {
      this.outEndpointAddr = outEndpoint;

      const pollerId = ddkNative.startPoller(
        deviceId, ifaceIndex, inEndpoint, outEndpoint, maxPacketSize,
        (_pollerId: number, data: Uint8Array, length: number) => {
          onData(data, length);
        },
        (_pollerId: number, errorCode: number) => {
          onError(errorCode);
        },
        timeoutMs
      );

      if (pollerId < 0) {
        console.error(`${TAG} startPoller 失败: pollerId=${pollerId}`);
        return false;
      }

      this.pollerId = pollerId;
      this._running = true;
      console.info(`${TAG} 轮询已启动: pollerId=${pollerId}`);
      return true;
    } catch (err) {
      console.error(`${TAG} start 异常:`, err);
      return false;
    }
  }

  /**
   * 停止轮询并释放资源
   */
  stop(): void {
    if (!this._running || this.pollerId < 0) return;

    try {
      ddkNative!.stopPoller(this.pollerId);
      console.info(`${TAG} 轮询已停止: pollerId=${this.pollerId}`);
    } catch (err) {
      console.error(`${TAG} stop 异常:`, err);
    }

    this._running = false;
    this.pollerId = -1;
  }

  /**
   * 发送输出数据 (init/rumble) — 同步操作
   *
   * @param data         要发送的数据
   * @param endpoint     输出端点地址 (默认使用 start 时指定的)
   * @returns 发送的字节数，负数表示错误
   */
  sendOutput(data: Uint8Array, endpoint?: number): number {
    if (!this._running || this.pollerId < 0 || !ddkNative) {
      return -1;
    }

    const ep = endpoint ?? this.outEndpointAddr;
    if (ep === 0) {
      console.warn(`${TAG} 无输出端点`);
      return -1;
    }

    try {
      return ddkNative.sendOutput(this.pollerId, ep, data);
    } catch (err) {
      console.error(`${TAG} sendOutput 异常:`, err);
      return -1;
    }
  }

  /**
   * 获取统计信息
   */
  getStats(): DdkPollerStats {
    if (this.pollerId < 0 || !ddkNative) {
      return { totalReads: 0, totalBytes: 0 };
    }
    try {
      return ddkNative.getStats(this.pollerId);
    } catch {
      return { totalReads: 0, totalBytes: 0 };
    }
  }

  /**
   * 设置是否忽略断开信号 (对应用户设置 "忽略手柄断开")
   * 启用后，DDK 原生轮询线程遇到致命 IO 错误不会退出，而是 sleep 后继续
   */
  setIgnoreDisconnect(ignore: boolean): void {
    if (this.pollerId < 0 || !ddkNative) return;
    try {
      ddkNative.setIgnoreDisconnect(this.pollerId, ignore);
      console.info(`${TAG} pollerId=${this.pollerId} ignoreDisconnect=${ignore}`);
    } catch (err) {
      console.error(`${TAG} setIgnoreDisconnect 异常:`, err);
    }
  }
}
