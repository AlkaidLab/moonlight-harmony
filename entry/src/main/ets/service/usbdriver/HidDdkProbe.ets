/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * HID DDK Probe - 验证 HID DDK 主进程可用性的 ArkTS 封装
 *
 * 只做被动探测（打开 hidraw → 读描述符 → 限时读报文 → 关闭），
 * 不接管输入、不干扰现有 USB 驱动流程，结果仅用于日志与后续决策。
 */

import nativeLib from 'libmoonlight_nativelib.so';
import { usbManager } from '@kit.BasicServicesKit';

const TAG = '[HID-DDK-Probe]';

interface HidProbeNativeInterface {
  isAvailable(): boolean;
  probe(deviceId: number, readMs: number, onResult: (result: HidProbeResult) => void): void;
}

interface NativeLibWithHidProbe {
  HidDdkProbe?: HidProbeNativeInterface;
}

export interface HidProbeResult {
  available: boolean;
  opened: boolean;
  initCode: number;
  openCode: number;
  descCode: number;
  initError?: string;
  openError?: string;
  interfaceIndex?: number;
  vid?: number;
  pid?: number;
  busType?: number;
  name?: string;
  descriptorLength?: number;
  descriptor?: Uint8Array;
  reportCount?: number;
  reportsPerSec?: number;
  sampleReports?: Uint8Array[];
}

const hidProbeNative = (nativeLib as NativeLibWithHidProbe).HidDdkProbe;

// 启动自检只跑一次
let probedStartup = false;

export class HidDdkProbe {

  /**
   * native 模块与 libhid.z.so 是否可用
   */
  static isAvailable(): boolean {
    if (!hidProbeNative) {
      return false;
    }
    try {
      return hidProbeNative.isAvailable();
    } catch (err) {
      console.error(`${TAG} isAvailable 异常:`, err);
      return false;
    }
  }

  /**
   * 异步探测指定 DDK deviceId
   */
  static probe(deviceId: number, readMs: number = 2000): Promise<HidProbeResult> {
    return new Promise<HidProbeResult>((resolve) => {
      if (!hidProbeNative) {
        resolve({ available: false, opened: false, initCode: -1, openCode: -1, descCode: -1 });
        return;
      }
      try {
        hidProbeNative.probe(deviceId, readMs, (result: HidProbeResult) => {
          resolve(result);
        });
      } catch (err) {
        console.error(`${TAG} probe 异常:`, err);
        resolve({ available: false, opened: false, initCode: -2, openCode: -2, descCode: -2 });
      }
    });
  }

  /**
   * 启动期环境自检（模拟器友好）
   *
   * 不依赖真实 USB 手柄：用无效 deviceId 跑一遍探测，
   * 核心结论是 OH_Hid_Init 的权限/服务检查（HID DDK 主进程可用性）。
   * Open 返回 DEVICE_NOT_FOUND 属预期。接入真手柄时走 probeOnceForDevice 全链路探测。
   */
  static async startupCheck(): Promise<void> {
    if (probedStartup) {
      return;
    }
    probedStartup = true;

    // 真机上若有 USB 设备接入，交给 handleUsbDevice 的全链路探测
    try {
      if (usbManager.getDevices().length > 0) {
        return;
      }
    } catch (err) {
      console.warn(`${TAG} 枚举 USB 设备异常，继续启动自检:`, err);
    }

    if (!HidDdkProbe.isAvailable()) {
      console.warn(`${TAG} 启动自检: libhid.z.so 不可用 (系统低于 API 18 或符号缺失)`);
      return;
    }

    console.info(`${TAG} 启动自检: 无 USB 设备，用哑 deviceId 验证 Init 权限`);
    const result = await HidDdkProbe.probe(1, 300);
    if (result.initCode === 0) {
      console.info(`${TAG} 启动自检结论: OH_Hid_Init=0 主进程可用` +
        `${result.openCode === 27300009 ? ' (Open=DEVICE_NOT_FOUND 属预期，无设备)' : ''}`);
    } else if (result.initCode === 201) {
      console.error(`${TAG} 启动自检结论: OH_Hid_Init=201 NO_PERM — 主进程使用 HID DDK 被拒，` +
        `检查签名 profile 是否含 ACCESS_DDK_HID；若仍被拒则 DriverExtensionAbility 限制为硬性`);
    } else {
      console.error(`${TAG} 启动自检结论: OH_Hid_Init=${result.initCode} (${result.initError})`);
    }
  }
}
