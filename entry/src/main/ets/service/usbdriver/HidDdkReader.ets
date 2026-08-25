/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * HID DDK Reader - hidraw 输入通道 ArkTS 封装
 *
 * 内核中断驱动的 OH_Hid_ReadTimeout 阻塞读，无需 claim USB 接口。
 * 对应 native exports.HidDdk 命名空间（hid_ddk_probe.cpp）。
 */

import nativeLib from 'libmoonlight_nativelib.so';

const TAG = '[HID-DDK-Reader]';

interface HidDdkNativeInterface {
  isAvailable(): boolean;
  startReader(deviceId: number, readTimeoutMs: number,
    onReport: (readerId: number, data: Uint8Array, length: number) => void,
    onError: (readerId: number, errorCode: number) => void): number;
  stopReader(readerId: number): void;
  writeOutput(readerId: number, data: Uint8Array): number;
  getReaderStats(readerId: number): HidReaderStats;
}

interface NativeLibWithHidDdk {
  HidDdk?: HidDdkNativeInterface;
}

export interface HidReaderStats {
  iface: number;
  descriptorLength: number;
  totalReports: number;
  totalBytes: number;
  lastError: number;
  reportsPerSec: number;
  running: boolean;
}

const hidDdkNative = (nativeLib as NativeLibWithHidDdk).HidDdk;

export class HidDdkReader {

  private readerId: number = -1;
  private _running: boolean = false;
  // 最近一次 start 失败的 HID_DDK 错误码（0=无错误），供上层日志/回退决策
  private _lastStartError: number = 0;

  static isAvailable(): boolean {
    if (!hidDdkNative) {
      return false;
    }
    try {
      return hidDdkNative.isAvailable();
    } catch (err) {
      console.error(`${TAG} isAvailable 异常:`, err);
      return false;
    }
  }

  get running(): boolean {
    return this._running;
  }

  get lastStartError(): number {
    return this._lastStartError;
  }

  /**
   * 启动 hidraw 读通道（native 侧同步打开，失败同步返回 false）
   *
   * @param deviceId  DDK 设备 ID（busNum<<32|devAddress，来自 DdkUsbPoller.makeDeviceId）
   * @param onReport  每个输入报文回调
   * @param onError   读线程 IO 错误（设备拔出等），通道已终止
   * @param readTimeoutMs 单次读超时（当前 native 固定 100ms，参数预留）
   */
  start(
    deviceId: number,
    onReport: (data: Uint8Array) => void,
    onError: (errorCode: number) => void,
    readTimeoutMs: number = 100
  ): boolean {
    if (!HidDdkReader.isAvailable()) {
      console.warn(`${TAG} native 不可用 (系统低于 API 18 或符号缺失)`);
      return false;
    }
    if (this._running) {
      console.warn(`${TAG} Reader 已在运行`);
      return false;
    }

    try {
      const readerId = hidDdkNative!.startReader(
        deviceId, readTimeoutMs,
        (_readerId: number, data: Uint8Array, length: number) => {
          if (length > 0) {
            onReport(data);
          }
        },
        (_readerId: number, errorCode: number) => {
          this._running = false;
          onError(errorCode);
        }
      );

      if (readerId < 0) {
        // 同步打开失败：readerId 为 -(HID_DDK 错误码)
        this._lastStartError = -readerId;
        console.error(`${TAG} startReader 失败: code=${-readerId}`);
        return false;
      }

      this._lastStartError = 0;
      this.readerId = readerId;
      this._running = true;
      console.info(`${TAG} Reader 已启动: readerId=${readerId}`);
      return true;
    } catch (err) {
      console.error(`${TAG} start 异常:`, err);
      return false;
    }
  }

  stop(): void {
    if (!this._running && this.readerId < 0) {
      return;
    }
    try {
      hidDdkNative!.stopReader(this.readerId);
      console.info(`${TAG} Reader 已停止: readerId=${this.readerId}`);
    } catch (err) {
      console.error(`${TAG} stop 异常:`, err);
    }
    this._running = false;
    this.readerId = -1;
  }

  /**
   * 发送输出报告（震动/LED），返回写入字节数，负数为错误码
   */
  sendOutput(data: Uint8Array): number {
    if (this.readerId < 0 || !hidDdkNative) {
      return -1;
    }
    try {
      return hidDdkNative.writeOutput(this.readerId, data);
    } catch (err) {
      console.error(`${TAG} sendOutput 异常:`, err);
      return -1;
    }
  }

  getStats(): HidReaderStats {
    if (this.readerId < 0 || !hidDdkNative) {
      return {
        iface: 0, descriptorLength: 0, totalReports: 0, totalBytes: 0,
        lastError: 0, reportsPerSec: 0, running: false
      };
    }
    try {
      return hidDdkNative.getReaderStats(this.readerId);
    } catch (err) {
      console.error(`${TAG} getStats 异常:`, err);
      return {
        iface: 0, descriptorLength: 0, totalReports: 0, totalBytes: 0,
        lastError: 0, reportsPerSec: 0, running: false
      };
    }
  }
}
