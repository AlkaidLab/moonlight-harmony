/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * USB/IP 反向隧道转发服务
 *
 * 把通过 OTG 连接的 USB 手柄经 USB/IP 协议反向隧道直通到 Sunshine 主机：
 *   1. 本地 native usbip::Server 在 127.0.0.1 导出设备（USB DDK 实现）
 *   2. GET /api/v1/usb-forwarding（配对客户端证书）拿到隧道端口与一次性令牌
 *   3. usbip::Tunnel 连接 Sunshine TLS 端点（47996），
 *      发送 {"op":"forward","token":...,"busid":...}，之后透传 USB/IP 字节流
 *   4. 主机侧 Sunshine 通过 usbip-win2/vhci 把手柄挂载为原生 USB 设备
 *
 * 与 moonlight-qt UsbForwarding / moonlight-android usbip-backend 同源契约。
 *
 * 被转发的设备由 UsbDriverService 排除（setForwardedDeviceKeys），
 * 避免本地驱动抢占 DDK 接口与主机侧双重输入。
 */

import { usbManager } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ComputerInfo } from '../../model/ComputerInfo';
import { SettingsService, SettingsKeys } from '../SettingsService';
import { UsbDriverService } from './UsbDriverService';
import { NvHttp } from '../streaming/NvHttp';
import { ToastQueue } from '../../utils/ToastQueue';
import { PreferencesUtil } from '../../utils/PreferencesUtil';
import nativeLib from 'libmoonlight_nativelib.so';
import { Logger } from '../../common/Logger';

/**
 * USB 转发对外状态（串流菜单展示用，同步可查）
 * phase:
 *   disabled  设置开关未启用
 *   no-device 开关已启用但没有可转发的 OTG 手柄
 *   starting  设备已选定，隧道建立中
 *   ready     隧道已建立，主机端手柄已挂载
 *   error     失败（message 携带原因）
 *   idle      停止/未转发状态
 */
export interface UsbForwardingStatus {
  phase: string;
  deviceName: string;
  message: string;
}

// ==================== native UsbIp 接口 ====================

interface NativeUsbIpStartServerResult {
  code: number;
  port?: number;
  error?: string;
}

interface NativeUsbIpAddDeviceResult {
  code: number;
  busId?: string;
  vendorId?: number;
  productId?: number;
  interfaces?: number;
  hasIsochronous?: number;
  error?: string;
}

interface NativeUsbIpTunnelConfig {
  host: string;
  port: number;
  token: string;
  busId: string;
  clientCertPem: string;
  clientKeyPem: string;
  serverCertPem: string;
}

interface NativeUsbIpResult {
  code: number;
  error?: string;
}

interface NativeTunnelStateResult {
  state: string;
  message: string;
}

interface NativeUsbIp {
  startServer(): NativeUsbIpStartServerResult;
  stopServer(): NativeUsbIpResult;
  addDevice(busNum: number, devAddress: number, name: string): NativeUsbIpAddDeviceResult;
  removeDevice(busId: string): NativeUsbIpResult;
  startTunnel(config: NativeUsbIpTunnelConfig, onState: (state: string, message: string) => void): NativeUsbIpResult;
  stopTunnel(): NativeUsbIpResult;
  tunnelState(): NativeTunnelStateResult;
}

interface NativeLibWithUsbIp {
  UsbIp?: NativeUsbIp;
}

const usbIp = (nativeLib as NativeLibWithUsbIp).UsbIp;

const TAG = '[USB-FORWARD]';

/**
 * USB/IP 反向隧道转发服务（单例）
 * 串流会话启动时调用 beginStreamForwarding()，结束时调用 endStreamForwarding()
 */
export class UsbForwardingService {
  private static instance: UsbForwardingService;

  /** 生命周期代数：begin/end 递增使旧的异步流程失效 */
  private generation: number = 0;
  private active: boolean = false;
  private activeBusId: string = '';
  private activeDeviceKey: string = '';
  private heldPipe: usbManager.USBDevicePipe | null = null;
  private lastMessage: string = '';
  /** 状态机与展示信息 */
  private phase: string = 'idle';
  private deviceName: string = '';
  private settingEnabled: boolean = false;
  /** 菜单重试所需上下文（仅当前串流会话内有效） */
  private lastComputer: ComputerInfo | null = null;
  private lastHost: string = '';
  private lastNvHttp: NvHttp | null = null;
  private lastContext: common.UIAbilityContext | null = null;

  private constructor() {
  }

  static getInstance(): UsbForwardingService {
    if (!UsbForwardingService.instance) {
      UsbForwardingService.instance = new UsbForwardingService();
    }
    return UsbForwardingService.instance;
  }

  isActive(): boolean {
    return this.active;
  }

  getLastMessage(): string {
    return this.lastMessage;
  }

  /** 隧道当前状态（idle/connecting/ready/closed/error） */
  getTunnelState(): string {
    if (!usbIp || !this.active) {
      return 'idle';
    }
    try {
      return usbIp.tunnelState().state;
    } catch (err) {
      return 'idle';
    }
  }

  /**
   * 串流会话开始：挑选一个 OTG 手柄转发到主机（v1 单设备）
   * 不抛异常、不阻塞会话启动；失败时回退为本地驱动处理。
   */
  async beginStreamForwarding(
    computer: ComputerInfo,
    host: string,
    nvHttp: NvHttp,
    context?: common.UIAbilityContext
  ): Promise<void> {
    const gen = ++this.generation;
    this.active = false;
    this.lastMessage = '';
    this.phase = 'idle';
    // 缓存重试上下文（菜单「重试/开启」按最近一次会话参数重新发起）
    this.lastComputer = computer;
    this.lastHost = host;
    this.lastNvHttp = nvHttp;
    this.lastContext = context ?? null;

    try {
      const settings = await SettingsService.getInstance().getInputSettings();
      if (gen !== this.generation) {
        return;
      }
      this.settingEnabled = settings.usbForwardingEnabled;
      if (!settings.usbForwardingEnabled) {
        this.phase = 'disabled';
        return;
      }
      if (!usbIp) {
        Logger.warn('UsbForwardingService', `${TAG} native UsbIp 模块不可用，跳过 USB 转发`);
        this.phase = 'error';
        this.lastMessage = 'native UsbIp 模块不可用';
        return;
      }
      if (!context) {
        Logger.warn('UsbForwardingService', `${TAG} 缺少 UIAbilityContext，跳过 USB 转发`);
        return;
      }
      if (!host) {
        Logger.warn('UsbForwardingService', `${TAG} 缺少主机地址，跳过 USB 转发`);
        return;
      }

      // 入口统一回收上一轮资源：上一轮 begin 可能仍停在 await（权限弹窗、
      // capability 查询），其代数守卫返回时不会自行 teardown，这里补齐，
      // 避免旧 USBDevicePipe/native server 泄漏或被新一轮覆盖。
      if (this.active || this.activeDeviceKey !== '' || this.heldPipe !== null) {
        this.teardown(false);
      }

      // 挑选转发目标：第一个未被本地驱动占用的已知手柄
      const activeKeys = UsbDriverService.getInstance().getActiveDeviceKeys();
      let target: usbManager.USBDevice | null = null;
      let devices: Array<usbManager.USBDevice> = [];
      try {
        devices = usbManager.getDevices() ?? [];
      } catch (err) {
        Logger.warn('UsbForwardingService', `${TAG} usbManager.getDevices 失败: ${err}`);
      }
      for (let i = 0; i < devices.length; i++) {
        const device = devices[i];
        const key = `${device.vendorId}:${device.productId}:${device.busNum}:${device.devAddress}`;
        if (activeKeys.has(key)) {
          continue;
        }
        if (UsbDriverService.identifyKnownGamepad(device) !== null) {
          target = device;
          break;
        }
      }
      if (!target) {
        Logger.info('UsbForwardingService', `${TAG} 没有可转发的 OTG 手柄`);
        this.phase = 'no-device';
        return;
      }
      const deviceKey = `${target.vendorId}:${target.productId}:${target.busNum}:${target.devAddress}`;
      const deviceName = UsbDriverService.identifyKnownGamepad(target) ?? target.name ?? 'USB 设备';
      this.deviceName = deviceName;
      this.phase = 'starting';

      // 标记排除必须先于任何 await：本地驱动的枚举/重扫描不得抢占该设备
      UsbDriverService.getInstance().setForwardedDeviceKeys(new Set<string>([deviceKey]));
      this.activeDeviceKey = deviceKey;
      Logger.info('UsbForwardingService', `${TAG} 转发目标: ${deviceName} (${deviceKey})`);

      // 启动 native USB/IP 服务
      const started = usbIp.startServer();
      if (started.code !== 0) {
        this.failForwarding(gen, `USB/IP 服务启动失败: ${started.error ?? '未知错误'}`, true);
        return;
      }

      // USB 权限（首次使用弹系统授权框）
      if (!usbManager.hasRight(target.name)) {
        Logger.info('UsbForwardingService', `${TAG} 请求 USB 设备权限: ${target.name}`);
        const granted = await usbManager.requestRight(target.name);
        if (gen !== this.generation) {
          return;
        }
        if (!granted) {
          this.failForwarding(gen, 'USB 设备权限被拒绝', true);
          return;
        }
      }

      // 占住 usbManager 管道（同时使内核 HID 驱动让出接口），DDK 才能声明
      try {
        this.heldPipe = usbManager.connectDevice(target);
      } catch (err) {
        this.failForwarding(gen, `连接 USB 设备失败: ${err}`, true);
        return;
      }

      // 注册到 native 服务（读描述符、生成 busid）
      const added = usbIp.addDevice(target.busNum, target.devAddress, deviceName);
      if (added.code !== 0) {
        this.failForwarding(gen, `注册设备到 USB/IP 服务失败: ${added.error ?? '未知错误'}`, true);
        return;
      }
      this.activeBusId = added.busId ?? '';
      if ((added.hasIsochronous ?? 0) !== 0) {
        Logger.warn('UsbForwardingService', `${TAG} 设备含同步端点（如音频），主机侧该部分功能不可用`);
      }
      this.active = true;

      // 查询主机能力（需要已配对）
      const capability = await nvHttp.getUsbForwardingCapability();
      if (gen !== this.generation) {
        return;
      }
      if (!capability.available) {
        const reason = capability.reason || '主机未启用 USB 转发或驱动未安装';
        this.failForwarding(gen, `主机 USB 转发不可用: ${reason}`, true);
        return;
      }

      // 配对证书：客户端证书/私钥是 PEM 文件，服务器证书是 base64 DER
      const certDir = context.filesDir;
      const clientCertPem = await UsbForwardingService.readTextFile(`${certDir}/client_cert.pem`);
      const clientKeyPem = await UsbForwardingService.readTextFile(`${certDir}/client_key.pem`);
      if (gen !== this.generation) {
        return;
      }
      if (!clientCertPem || !clientKeyPem || !computer.serverCert) {
        this.failForwarding(gen, '配对证书缺失，请先与主机完成配对', true);
        return;
      }
      const serverCertPem = UsbForwardingService.base64DerToPem(computer.serverCert);

      // 建立反向隧道
      const tunnelResult = usbIp.startTunnel({
        host: host,
        port: capability.port,
        token: capability.token,
        busId: this.activeBusId,
        clientCertPem: clientCertPem,
        clientKeyPem: clientKeyPem,
        serverCertPem: serverCertPem
      }, (state: string, message: string): void => {
        this.onTunnelState(gen, state, message);
      });
      if (tunnelResult.code !== 0) {
        this.failForwarding(gen, `反向隧道启动失败: ${tunnelResult.error ?? '未知错误'}`, true);
        return;
      }
      Logger.info('UsbForwardingService', `${TAG} 隧道建立中: ${host}:${capability.port} busid=${this.activeBusId}`);
    } catch (err) {
      // 含 capability 查询抛出的网络/解析错误
      const message = err instanceof Error ? err.message : String(err);
      this.failForwarding(gen, `USB 转发失败: ${message}`, this.activeDeviceKey !== '');
    }
  }

  /** 串流会话结束：释放隧道、设备与排除标记 */
  endStreamForwarding(): void {
    this.generation++;
    if (!this.active && this.activeDeviceKey === '' && this.heldPipe === null) {
      return;
    }
    Logger.info('UsbForwardingService', `${TAG} 结束 USB 转发`);
    this.teardown(false);
    this.phase = 'idle';
  }

  // ==================== 串流菜单接口 ====================

  /** 当前转发状态（同步，菜单展示用） */
  getStatus(): UsbForwardingStatus {
    return {
      phase: this.phase,
      deviceName: this.deviceName,
      message: this.lastMessage
    };
  }

  /**
   * 菜单「停止」：断开隧道并把设备交还本地手柄驱动
   */
  stopForwardingFromMenu(): void {
    this.generation++;
    this.teardown(true);
    this.phase = 'idle';
  }

  /**
   * 菜单「重试/开启」：按最近一次会话参数重新发起转发
   * @param enableSetting 为 true 时先持久化打开设置开关（从「未启用」状态点进来的场景）
   */
  async startForwardingFromMenu(enableSetting: boolean): Promise<void> {
    if (!this.lastComputer || !this.lastNvHttp || !this.lastHost) {
      ToastQueue.show({ message: '串流会话信息不足，无法转发', duration: 2500 });
      return;
    }
    if (enableSetting) {
      try {
        await PreferencesUtil.put(SettingsKeys.USB_FORWARDING_ENABLED, true);
        this.settingEnabled = true;
      } catch (err) {
        Logger.warn('UsbForwardingService', `${TAG} 保存设置失败: ${err}`);
      }
    }
    // 若上一轮仍在活动中（例如重试），先回收避免 DDK 接口冲突
    if (this.active || this.activeDeviceKey !== '') {
      this.teardown(false);
    }
    await this.beginStreamForwarding(
      this.lastComputer, this.lastHost, this.lastNvHttp,
      this.lastContext ?? undefined
    );
  }

  // ==================== 内部 ====================

  private onTunnelState(gen: number, state: string, message: string): void {
    if (gen !== this.generation) {
      return;
    }
    if (state === 'ready') {
      this.lastMessage = '';
      this.phase = 'ready';
      Logger.info('UsbForwardingService', `${TAG} USB 直通已建立，主机端手柄已挂载`);
      ToastQueue.show({ message: 'USB 手柄已直通主机', duration: 2500 });
    } else if (state === 'error') {
      this.failForwarding(gen, message || 'USB 隧道中断', true);
    } else if (state === 'closed') {
      // 主机主动结束（游戏退出/设备移除）：静默回收，允许本地驱动接管
      this.teardown(true);
      this.phase = 'idle';
    }
  }

  private failForwarding(gen: number, message: string, releaseToLocalDriver: boolean): void {
    if (gen !== this.generation) {
      return;
    }
    Logger.error('UsbForwardingService', `${TAG} ${message}`);
    this.lastMessage = message;
    this.phase = 'error';
    this.teardown(releaseToLocalDriver);
    ToastQueue.show({ message: message, duration: 3500 });
  }

  private teardown(releaseToLocalDriver: boolean): void {
    if (usbIp) {
      try {
        usbIp.stopTunnel();
      } catch (err) {
        Logger.warn('UsbForwardingService', `${TAG} stopTunnel 异常: ${err}`);
      }
      if (this.activeBusId) {
        try {
          usbIp.removeDevice(this.activeBusId);
        } catch (err) {
          Logger.warn('UsbForwardingService', `${TAG} removeDevice 异常: ${err}`);
        }
      }
      try {
        usbIp.stopServer();
      } catch (err) {
        Logger.warn('UsbForwardingService', `${TAG} stopServer 异常: ${err}`);
      }
    }
    this.activeBusId = '';
    this.active = false;

    if (this.heldPipe !== null) {
      try {
        usbManager.closePipe(this.heldPipe);
      } catch (err) {
        Logger.warn('UsbForwardingService', `${TAG} closePipe 异常: ${err}`);
      }
      this.heldPipe = null;
    }

    if (this.activeDeviceKey !== '') {
      UsbDriverService.getInstance().setForwardedDeviceKeys(new Set<string>());
      if (releaseToLocalDriver) {
        // 释放回本地驱动（失败回退场景）；串流结束时保持设备闲置
        UsbDriverService.getInstance().refreshDevices();
      }
      this.activeDeviceKey = '';
    }
  }

  private static async readTextFile(path: string): Promise<string> {
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      try {
        const stat = await fileIo.stat(path);
        const buffer = new ArrayBuffer(stat.size);
        await fileIo.read(file.fd, buffer);
        const decoder = util.TextDecoder.create('utf-8');
        return decoder.decodeToString(new Uint8Array(buffer));
      } finally {
        await fileIo.close(file);
      }
    } catch (err) {
      Logger.warn('UsbForwardingService', `${TAG} 读取 ${path} 失败: ${err}`);
      return '';
    }
  }

  /** base64 DER 证书 → PEM 文本（native 隧道按 PEM 解析） */
  private static base64DerToPem(base64Der: string): string {
    const clean = base64Der.replace(/\s/g, '');
    const lines: string[] = [];
    for (let i = 0; i < clean.length; i += 64) {
      lines.push(clean.substring(i, i + 64));
    }
    return `-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----\n`;
  }
}
