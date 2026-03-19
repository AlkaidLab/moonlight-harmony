/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { mdns } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NvHttp } from './NvHttp';
import { getBestIpv6Address } from '../utils/NetHelper';

/**
 * 发现的计算机信息
 */
export interface DiscoveredComputer {
  name: string;           // 主机名
  address: string;        // IP 地址
  port: number;           // 服务端口
  ipv6Address?: string;   // IPv6 地址（可选）
}

/**
 * mDNS 服务发现
 *
 * 用于在局域网内发现运行 NVIDIA GameStream / Sunshine 的主机
 * 参考 Android 版本的 NsdManagerDiscoveryAgent 实现
 */
export class MdnsDiscovery {
  private static readonly SERVICE_TYPE = '_nvstream._tcp';
  private static readonly DISCOVERY_TIMEOUT = 5000;  // 5秒超时

  private discoveryService: mdns.DiscoveryService | null = null;
  private discoveredComputers: Map<string, DiscoveredComputer> = new Map();
  private isDiscovering: boolean = false;
  private context: common.Context;
  private onComputerFound: ((computer: DiscoveredComputer) => void) | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  /**
   * 设置计算机发现回调
   */
  setOnComputerFoundListener(callback: (computer: DiscoveredComputer) => void): void {
    this.onComputerFound = callback;
  }

  /**
   * 开始发现局域网内的主机
   */
  async startDiscovery(): Promise<void> {
    if (this.isDiscovering) {
      console.info('MdnsDiscovery: 已经在发现中');
      return;
    }

    this.isDiscovering = true;
    this.discoveredComputers.clear();

    console.info(`MdnsDiscovery: 开始发现服务类型 ${MdnsDiscovery.SERVICE_TYPE}`);

    try {
      // 创建 mDNS 发现服务
      this.discoveryService = mdns.createDiscoveryService(
        this.context,
        MdnsDiscovery.SERVICE_TYPE
      );
      console.info('MdnsDiscovery: 发现服务已创建');

      // 监听服务发现事件（参考 moonlight-ohos 使用 async 回调）
      this.discoveryService.on('serviceFound', async (serviceInfo: mdns.LocalServiceInfo) => {
        console.info(`MdnsDiscovery: [serviceFound] 原始信息: ${JSON.stringify(serviceInfo)}`);
        try {
          // 解析服务以获取完整信息（参考 moonlight-ohos）
          const resolvedInfo = await mdns.resolveLocalService(this.context, serviceInfo);
          console.info(`MdnsDiscovery: [serviceFound] 解析后: ${JSON.stringify(resolvedInfo)}`);
          await this.handleResolvedService(resolvedInfo);
        } catch (err) {
          console.error(`MdnsDiscovery: [serviceFound] 解析失败: ${err}`);
        }
      });

      // 监听服务丢失事件
      this.discoveryService.on('serviceLost', async (serviceInfo: mdns.LocalServiceInfo) => {
        console.info(`MdnsDiscovery: [serviceLost] ${serviceInfo.serviceName}`);
        try {
          const resolvedInfo = await mdns.resolveLocalService(this.context, serviceInfo);
          this.discoveredComputers.delete(resolvedInfo.serviceName);
        } catch (err) {
          // 服务丢失时可能无法解析，直接使用原始名称
          this.discoveredComputers.delete(serviceInfo.serviceName);
        }
      });

      // 监听 discoveryStart 事件
      this.discoveryService.on('discoveryStart', (info: mdns.DiscoveryEventInfo) => {
        console.info(`MdnsDiscovery: 发现已开始 - ${JSON.stringify(info)}`);
        // 检查是否有错误码（参考 moonlight-ohos 实现）
        if (info.errorCode !== undefined && info.errorCode !== 0) {
          console.error(`MdnsDiscovery: 发现启动失败，错误码: ${info.errorCode}`);
          this.isDiscovering = false;
          this.discoveryService?.stopSearchingMDNS();
        }
      });

      // 监听 discoveryStop 事件
      this.discoveryService.on('discoveryStop', (info: mdns.DiscoveryEventInfo) => {
        console.info(`MdnsDiscovery: 发现已停止 - ${JSON.stringify(info)}`);
      });

      // 开始搜索
      console.info('MdnsDiscovery: 调用 startSearchingMDNS()');
      this.discoveryService.startSearchingMDNS();
      console.info('MdnsDiscovery: startSearchingMDNS() 已调用');

    } catch (err) {
      const error = err as BusinessError;
      console.error(`MdnsDiscovery: 启动发现失败 - ${error.code}: ${error.message}`);
      this.isDiscovering = false;
      throw new Error(`Failed to start mDNS discovery: ${error.message}`);
    }
  }

  /**
   * 处理已解析的服务（参考 moonlight-ohos 的 localServiceInfoToExternalAddr）
   */
  private async handleResolvedService(resolvedInfo: mdns.LocalServiceInfo): Promise<void> {
    if (!resolvedInfo.host) {
      console.warn('MdnsDiscovery: 解析的服务没有 host 信息');
      return;
    }

    const host = resolvedInfo.host;
    const port = host.port ?? NvHttp.DEFAULT_HTTP_PORT;

    console.info(`MdnsDiscovery: 发现服务器 ${resolvedInfo.serviceName} @ ${host.address} (family=${host.family})`);

    // mDNS 返回的主地址
    let primaryAddress = host.address;
    let ipv6Address: string | undefined = host.family === 2 ? host.address : undefined;

    // 如果 mDNS 只返回了 IPv4，主动查询主机的 IPv6 全局地址
    // 对齐 Android MdnsDiscoveryAgent.getBestIpv6Address() 的行为
    if (host.family === 1) {
      ipv6Address = await this.lookupIpv6ForHost(resolvedInfo.serviceName);
    }

    const computer: DiscoveredComputer = {
      name: resolvedInfo.serviceName,
      address: primaryAddress,
      port: port,
      ipv6Address: ipv6Address
    };

    this.discoveredComputers.set(computer.name, computer);

    if (this.onComputerFound) {
      this.onComputerFound(computer);
    }
  }

  /**
   * 通过 DNS 查询获取主机的 IPv6 全局地址
   *
   * 尝试解析 "<hostname>.local" 的 AAAA 记录，
   * 从返回的地址中选出最佳的 IPv6 全局单播地址。
   *
   * @param hostname mDNS 服务名称（即主机名）
   * @returns IPv6 全局地址，无则返回 undefined
   */
  private async lookupIpv6ForHost(hostname: string): Promise<string | undefined> {
    try {
      const addresses = await connection.getAddressesByName(hostname);
      const ipv6List: string[] = [];
      for (const addr of addresses) {
        if (addr.family === 2 && addr.address) {
          ipv6List.push(addr.address);
        }
      }
      if (ipv6List.length > 0) {
        const best = getBestIpv6Address(ipv6List);
        if (best) {
          console.info(`MdnsDiscovery: 为 ${hostname} 找到 IPv6 全局地址: ${best}`);
          return best;
        }
      }
    } catch (_err) {
      // hostname 可能无法被系统 DNS 解析（.local 域名需要 mDNS 支持）
      // 这不是错误，静默忽略
    }

    // 回退：尝试 hostname.local
    try {
      const addresses = await connection.getAddressesByName(`${hostname}.local`);
      const ipv6List: string[] = [];
      for (const addr of addresses) {
        if (addr.family === 2 && addr.address) {
          ipv6List.push(addr.address);
        }
      }
      if (ipv6List.length > 0) {
        const best = getBestIpv6Address(ipv6List);
        if (best) {
          console.info(`MdnsDiscovery: 为 ${hostname}.local 找到 IPv6 全局地址: ${best}`);
          return best;
        }
      }
    } catch (_err) {
      // 静默忽略
    }

    console.info(`MdnsDiscovery: 未能为 ${hostname} 获取 IPv6 地址`);
    return undefined;
  }

  /**
   * 解析服务获取详细信息（旧方法，保留兼容）
   */
  private async resolveService(serviceInfo: mdns.LocalServiceInfo): Promise<void> {
    try {
      const resolvedService = await mdns.resolveLocalService(this.context, serviceInfo);

      console.info(`MdnsDiscovery: 解析服务 ${resolvedService.serviceName}`);
      console.info(`  - 主机地址: ${resolvedService.host?.address}`);
      console.info(`  - 主机端口: ${resolvedService.host?.port}`);
      console.info(`  - 服务端口: ${resolvedService.port}`);
      console.info(`  - 完整信息: ${JSON.stringify(resolvedService)}`);

      if (resolvedService.host?.address) {
        // 优先使用 host.port（参考 moonlight-ohos 实现）
        const port = resolvedService.host?.port || resolvedService.port || NvHttp.DEFAULT_HTTP_PORT;
        
        const computer: DiscoveredComputer = {
          name: resolvedService.serviceName,
          address: resolvedService.host.address,
          port: port
        };

        // 检查是否是 IPv6 地址
        if (resolvedService.host.address.includes(':')) {
          computer.ipv6Address = resolvedService.host.address;
          // IPv6 地址，尝试获取 IPv4
          // HarmonyOS API 可能只返回一个地址，暂时使用 IPv6
        }

        console.info(`MdnsDiscovery: 发现电脑 ${computer.name} @ ${computer.address}:${computer.port}`);
        this.discoveredComputers.set(computer.name, computer);

        // 通知回调
        if (this.onComputerFound) {
          this.onComputerFound(computer);
        }
      }
    } catch (err) {
      const error = err as BusinessError;
      console.error(`MdnsDiscovery: 解析服务失败 - ${error.code}: ${error.message}`);
    }
  }

  /**
   * 停止发现
   */
  stopDiscovery(): void {
    if (!this.isDiscovering || !this.discoveryService) {
      return;
    }

    console.info('MdnsDiscovery: 停止发现');

    try {
      this.discoveryService.stopSearchingMDNS();
      this.discoveryService.off('serviceFound');
      this.discoveryService.off('serviceLost');
    } catch (err) {
      console.error('MdnsDiscovery: 停止发现失败', err);
    }

    this.discoveryService = null;
    this.isDiscovering = false;
  }

  /**
   * 发现一段时间后返回结果
   */
  async discover(timeout: number = MdnsDiscovery.DISCOVERY_TIMEOUT): Promise<DiscoveredComputer[]> {
    await this.startDiscovery();

    // 等待发现超时
    await new Promise<void>((resolve: Function) => setTimeout(resolve, timeout));

    this.stopDiscovery();

    return Array.from(this.discoveredComputers.values());
  }

  /**
   * 获取已发现的计算机列表
   */
  getDiscoveredComputers(): DiscoveredComputer[] {
    return Array.from(this.discoveredComputers.values());
  }

  /**
   * 是否正在发现
   */
  isSearching(): boolean {
    return this.isDiscovering;
  }
}
