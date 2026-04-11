/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import socket from '@ohos.net.socket';
import connection from '@ohos.net.connection';
import { NvHttp } from './NvHttp';

/**
 * Wake-on-LAN 魔术包发送器
 *
 * 对齐 Android WakeOnLanSender 实现：
 * - 每个地址独立尝试，广播失败不影响单播发送
 * - 支持 DNS 解析（域名/DDNS 地址）
 * - 广播和单播使用独立 socket，避免 broadcast 标志影响单播路由
 *
 * 魔术包格式: 6 字节 0xFF + 16 次目标 MAC 地址 = 102 字节
 */
export class WakeOnLan {
  private static readonly STATIC_PORTS: number[] = [
    9,      // 标准 WOL 端口
    47009,  // Moonlight Internet Hosting Tool 的 WOL 端口
  ];

  private static readonly DYNAMIC_PORT_BASES: number[] = [
    47998, 47999, 48000, 48002, 48010,
  ];

  private static readonly DEFAULT_HTTP_PORT = NvHttp.DEFAULT_HTTP_PORT;
  private static readonly MAGIC_PACKET_SIZE = 102;
  private static readonly MAC_BYTES = 6;
  private static readonly MAC_REPETITIONS = 16;
  private static readonly ZERO_MAC = '00:00:00:00:00:00';

  /**
   * 发送 WOL 魔术包唤醒目标设备（单地址版本）
   */
  static async sendWolPacket(macAddress: string, address: string, httpPort: number = WakeOnLan.DEFAULT_HTTP_PORT): Promise<void> {
    await WakeOnLan.sendWolToAddresses(macAddress, [address], httpPort);
  }

  /**
   * 批量发送 WOL 到多个地址（对齐 Android WakeOnLanSender.sendWolPacket）
   *
   * 策略：遍历每个地址，先尝试广播（失败忽略），再 DNS 解析后发送到实际 IP。
   * 任何一个地址发送成功即视为成功，全部失败才抛异常。
   */
  static async sendWolToAddresses(macAddress: string, addresses: string[], httpPort: number = WakeOnLan.DEFAULT_HTTP_PORT): Promise<void> {
    WakeOnLan.validateMacAddress(macAddress);

    const payload = WakeOnLan.createMagicPacket(macAddress);
    const allPorts = WakeOnLan.getAllPorts(httpPort);
    let sentWolPacket = false;
    let lastError: Error | null = null;

    // 去重
    const uniqueAddresses = Array.from(new Set(addresses.filter(a => !!a)));
    if (uniqueAddresses.length === 0) {
      uniqueAddresses.push('255.255.255.255');
    }

    console.info(`WOL: 开始发送魔术包 MAC=${macAddress} 地址列表=[${uniqueAddresses.join(', ')}] httpPort=${httpPort}`);

    for (const address of uniqueAddresses) {
      const isIPv6 = WakeOnLan.isIPv6Address(address);

      // 1) IPv4: 先用独立广播 socket 尝试发送 255.255.255.255（失败忽略）
      if (!isIPv6) {
        try {
          await WakeOnLan.sendBroadcast(payload, allPorts);
          sentWolPacket = true;
          console.info(`WOL: 广播发送成功 (255.255.255.255)`);
        } catch (e) {
          lastError = e instanceof Error ? e : new Error(String(e));
          console.info(`WOL: 广播发送失败（已忽略）: ${lastError.message}`);
        }
      }

      // 2) DNS 解析地址后发送到每个解析结果（单播，不设 broadcast 标志）
      try {
        const resolvedAddresses = await WakeOnLan.resolveAddress(address);
        console.info(`WOL: DNS 解析 ${address} → [${resolvedAddresses.join(', ')}]`);
        for (const resolved of resolvedAddresses) {
          try {
            const resolvedIsIPv6 = WakeOnLan.isIPv6Address(resolved);
            await WakeOnLan.sendUnicast(payload, resolved, allPorts, resolvedIsIPv6);
            sentWolPacket = true;
            console.info(`WOL: 单播发送成功 → ${resolved}`);
          } catch (e) {
            lastError = e instanceof Error ? e : new Error(String(e));
            console.info(`WOL: 单播发送失败 → ${resolved}: ${lastError.message}`);
          }
        }
      } catch (e) {
        // DNS 解析失败，尝试直接用原始地址发送
        lastError = e instanceof Error ? e : new Error(String(e));
        console.info(`WOL: DNS 解析失败 ${address}: ${lastError.message}，尝试直接发送`);
        try {
          await WakeOnLan.sendUnicast(payload, address, allPorts, isIPv6);
          sentWolPacket = true;
          console.info(`WOL: 直接发送成功 → ${address}`);
        } catch (e2) {
          lastError = e2 instanceof Error ? e2 : new Error(String(e2));
          console.info(`WOL: 直接发送失败 → ${address}: ${lastError.message}`);
        }
      }
    }

    console.info(`WOL: 发送完毕, 成功=${sentWolPacket}`);

    if (!sentWolPacket && lastError) {
      throw lastError;
    }
  }

  // ==================== 发送方法 ====================

  /**
   * 广播发送（独立 socket，设置 broadcast 标志）
   */
  private static async sendBroadcast(payload: ArrayBuffer, ports: number[]): Promise<void> {
    const udpSocket = socket.constructUDPSocketInstance();
    try {
      await udpSocket.bind({ address: '0.0.0.0', port: 0, family: 1 });
      await udpSocket.setExtraOptions({ broadcast: true });

      for (const port of ports) {
        try {
          await udpSocket.send({
            data: payload,
            address: { address: '255.255.255.255', port: port, family: 1 }
          });
        } catch {
          // 单个端口发送失败忽略
        }
      }
    } finally {
      udpSocket.close();
    }
  }

  /**
   * 单播发送（独立 socket，不设 broadcast 标志）
   */
  private static async sendUnicast(payload: ArrayBuffer, address: string, ports: number[], isIPv6: boolean): Promise<void> {
    const family = isIPv6 ? 2 : 1;
    const udpSocket = socket.constructUDPSocketInstance();
    try {
      await udpSocket.bind({ address: isIPv6 ? '::' : '0.0.0.0', port: 0, family: family });

      let sent = 0;
      for (const port of ports) {
        try {
          await udpSocket.send({
            data: payload,
            address: { address: address, port: port, family: family }
          });
          sent++;
        } catch {
          // 单个端口发送失败忽略
        }
      }
      if (sent === 0) {
        throw new Error(`WOL 发送失败: 所有端口均无法到达 ${address}`);
      }
    } finally {
      udpSocket.close();
    }
  }

  // ==================== DNS 解析 ====================

  /**
   * 解析地址为 IP 列表（类似 Java InetAddress.getAllByName）
   * 纯 IP 地址直接返回，域名通过系统 DNS 解析
   */
  private static async resolveAddress(address: string): Promise<string[]> {
    // 纯 IPv4 或 IPv6 地址直接返回
    if (WakeOnLan.isIPAddress(address)) {
      return [address];
    }
    // 域名 → DNS 解析（connection 模块级方法）
    const result: connection.NetAddress[] = await connection.getAddressesByName(address);
    const resolved: string[] = [];
    for (const addr of result) {
      if (addr.address) {
        resolved.push(addr.address);
      }
    }
    if (resolved.length === 0) {
      throw new Error(`DNS 解析 ${address} 返回空结果`);
    }
    return resolved;
  }

  private static isIPAddress(address: string): boolean {
    // IPv4: x.x.x.x
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(address)) return true;
    // IPv6: contains multiple colons
    if (WakeOnLan.isIPv6Address(address)) return true;
    return false;
  }

  // ==================== 工具方法 ====================

  private static validateMacAddress(macAddress: string): void {
    if (!macAddress || macAddress === WakeOnLan.ZERO_MAC) {
      throw new Error('MAC 地址无效，无法发送 WOL 包');
    }
  }

  private static isIPv6Address(address: string): boolean {
    return address.includes(':') && (address.split(':').length > 2 || address.startsWith('['));
  }

  private static getAllPorts(httpPort: number): number[] {
    const ports = [...WakeOnLan.STATIC_PORTS];
    const portOffset = httpPort - WakeOnLan.DEFAULT_HTTP_PORT;
    for (const basePort of WakeOnLan.DYNAMIC_PORT_BASES) {
      ports.push(basePort + portOffset);
    }
    return ports;
  }

  private static createMagicPacket(macAddress: string): ArrayBuffer {
    const macBytes = WakeOnLan.parseMacAddress(macAddress);
    const payload = new Uint8Array(WakeOnLan.MAGIC_PACKET_SIZE);
    payload.fill(0xFF, 0, WakeOnLan.MAC_BYTES);
    for (let i = 0; i < WakeOnLan.MAC_REPETITIONS; i++) {
      const offset = WakeOnLan.MAC_BYTES + i * WakeOnLan.MAC_BYTES;
      payload.set(macBytes, offset);
    }
    return payload.buffer;
  }

  private static parseMacAddress(macAddress: string): Uint8Array {
    const macBytes = new Uint8Array(WakeOnLan.MAC_BYTES);
    const parts = macAddress.split(/[:\-]/);
    for (let i = 0; i < WakeOnLan.MAC_BYTES && i < parts.length; i++) {
      const value = parseInt(parts[i], 16);
      macBytes[i] = isNaN(value) ? 0 : value;
    }
    return macBytes;
  }

  static isValidMacAddress(macAddress: string): boolean {
    return /^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$/.test(macAddress);
  }
}
