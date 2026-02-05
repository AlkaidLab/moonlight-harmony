/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { socket } from '@kit.NetworkKit';

/**
 * 发送结果统计
 */
interface SendResult {
  sent: number;
  errors: number;
}

/**
 * Wake-on-LAN 魔术包发送器
 * 
 * 通过发送特殊的 UDP 数据包唤醒休眠的电脑
 * 魔术包格式: 6 字节 0xFF + 16 次目标 MAC 地址 = 102 字节
 */
export class WakeOnLan {
  /** 标准 WOL 端口 */
  private static readonly STATIC_PORTS: number[] = [
    9,      // 标准 WOL 端口 (特权端口)
    47009,  // Moonlight Internet Hosting Tool 的 WOL 端口
  ];

  /** 动态端口基础值 (相对于 HTTP 端口 47989 的偏移量) */
  private static readonly DYNAMIC_PORT_BASES: number[] = [
    47998, 47999, 48000, 48002, 48010,  // GFE 打开的端口
  ];
  
  private static readonly DEFAULT_HTTP_PORT = 47989;
  private static readonly MAGIC_PACKET_SIZE = 102;  // 6 + 16 * 6
  private static readonly MAC_BYTES = 6;
  private static readonly MAC_REPETITIONS = 16;
  private static readonly ZERO_MAC = '00:00:00:00:00:00';

  /**
   * 发送 WOL 魔术包唤醒目标设备
   * 
   * @param macAddress MAC 地址 (格式: XX:XX:XX:XX:XX:XX 或 XX-XX-XX-XX-XX-XX)
   * @param address 目标地址 (IPv4/IPv6)
   * @param httpPort HTTP 端口用于计算动态端口 (默认 47989)
   */
  static async sendWolPacket(macAddress: string, address: string, httpPort: number = WakeOnLan.DEFAULT_HTTP_PORT): Promise<void> {
    WakeOnLan.validateMacAddress(macAddress);
    
    const payload = WakeOnLan.createMagicPacket(macAddress);
    const isIPv6 = WakeOnLan.isIPv6Address(address);
    
    const udpSocket = socket.constructUDPSocketInstance();
    try {
      await WakeOnLan.bindSocket(udpSocket, isIPv6);
      
      // IPv4 时先发送广播
      if (!isIPv6) {
        await WakeOnLan.enableBroadcast(udpSocket);
        await WakeOnLan.sendToAllPorts(udpSocket, '255.255.255.255', httpPort, payload, false);
      }
      
      // 发送到目标地址
      await WakeOnLan.sendToAllPorts(udpSocket, address, httpPort, payload, isIPv6);
    } finally {
      udpSocket.close();
    }
  }

  /**
   * 批量发送 WOL 到多个地址
   * 发送到: 全局广播 + 子网广播 + 目标地址
   * 
   * @param macAddress MAC 地址
   * @param addresses 目标地址列表
   * @param httpPort HTTP 端口用于计算动态端口
   */
  static async sendWolToAddresses(macAddress: string, addresses: string[], httpPort: number = WakeOnLan.DEFAULT_HTTP_PORT): Promise<void> {
    WakeOnLan.validateMacAddress(macAddress);
    
    if (addresses.length === 0) {
      addresses = ['255.255.255.255'];
    }
    
    const payload = WakeOnLan.createMagicPacket(macAddress);
    
    // 构建完整的目标地址列表（包括子网广播地址）
    const allAddresses = new Set<string>();
    allAddresses.add('255.255.255.255');  // 全局广播
    
    for (const addr of addresses) {
      if (!WakeOnLan.isIPv6Address(addr)) {
        allAddresses.add(addr);
        // 计算子网广播地址 (假设 /24 子网)
        const subnetBroadcast = WakeOnLan.getSubnetBroadcast(addr);
        if (subnetBroadcast) {
          allAddresses.add(subnetBroadcast);
        }
      } else {
        allAddresses.add(addr);
      }
    }
    
    // 按地址类型分组
    const addressArray = Array.from(allAddresses);
    const ipv4Addresses = addressArray.filter(addr => !WakeOnLan.isIPv6Address(addr));
    const ipv6Addresses = addressArray.filter(addr => WakeOnLan.isIPv6Address(addr));
    
    // 发送 IPv4
    if (ipv4Addresses.length > 0) {
      const udpSocket = socket.constructUDPSocketInstance();
      try {
        await WakeOnLan.bindSocket(udpSocket, false);
        await WakeOnLan.enableBroadcast(udpSocket);
        
        for (const addr of ipv4Addresses) {
          await WakeOnLan.sendToAllPorts(udpSocket, addr, httpPort, payload, false);
        }
      } finally {
        udpSocket.close();
      }
    }
    
    // 发送 IPv6
    if (ipv6Addresses.length > 0) {
      const udpSocket = socket.constructUDPSocketInstance();
      try {
        await WakeOnLan.bindSocket(udpSocket, true);
        
        for (const addr of ipv6Addresses) {
          await WakeOnLan.sendToAllPorts(udpSocket, addr, httpPort, payload, true);
        }
      } finally {
        udpSocket.close();
      }
    }
  }
  
  /**
   * 从 IPv4 地址计算子网广播地址 (假设 /24 子网)
   */
  private static getSubnetBroadcast(ipv4Address: string): string | null {
    const parts = ipv4Address.split('.');
    if (parts.length !== 4) {
      return null;
    }
    parts[3] = '255';
    return parts.join('.');
  }

  // ==================== 私有方法 ====================

  private static validateMacAddress(macAddress: string): void {
    if (!macAddress || macAddress === WakeOnLan.ZERO_MAC) {
      throw new Error('MAC 地址无效，无法发送 WOL 包');
    }
  }

  private static isIPv6Address(address: string): boolean {
    return address.includes(':') && (address.split(':').length > 2 || address.startsWith('['));
  }

  private static getSocketFamily(isIPv6: boolean): number {
    return isIPv6 ? 2 : 1;  // IPv4=1, IPv6=2
  }

  private static async bindSocket(udpSocket: socket.UDPSocket, isIPv6: boolean): Promise<void> {
    await udpSocket.bind({
      address: isIPv6 ? '::' : '0.0.0.0',
      port: 0,
      family: WakeOnLan.getSocketFamily(isIPv6)
    });
  }

  private static async enableBroadcast(udpSocket: socket.UDPSocket): Promise<void> {
    try {
      await udpSocket.setExtraOptions({ broadcast: true });
    } catch {
      // 广播选项可能不被支持，忽略错误
    }
  }

  private static async sendToAllPorts(
    udpSocket: socket.UDPSocket,
    address: string,
    httpPort: number,
    payload: ArrayBuffer,
    isIPv6: boolean
  ): Promise<SendResult> {
    const family = WakeOnLan.getSocketFamily(isIPv6);
    const allPorts = WakeOnLan.getAllPorts(httpPort);
    let sent = 0;
    let errors = 0;
    
    for (const port of allPorts) {
      try {
        const destAddr: socket.NetAddress = {
          address: address,
          port: port,
          family: family
        };
        await udpSocket.send({
          data: payload,
          address: destAddr
        });
        sent++;
      } catch {
        errors++;
      }
    }
    
    const result: SendResult = { sent: sent, errors: errors };
    return result;
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
    
    // 填充 6 字节 0xFF 前导
    payload.fill(0xFF, 0, WakeOnLan.MAC_BYTES);
    
    // 填充 16 次 MAC 地址
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

  /**
   * 验证 MAC 地址格式是否正确
   */
  static isValidMacAddress(macAddress: string): boolean {
    return /^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$/.test(macAddress);
  }
}
