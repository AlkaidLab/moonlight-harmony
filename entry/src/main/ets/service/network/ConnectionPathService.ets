/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { connection } from '@kit.NetworkKit';
import { isIPv4Address, isIPv6Address, isLanAddress, isPublicAddress, parseAddressAndPort } from '../../utils/NetHelper';

export enum ConnectionPath {
  LAN = 'LAN',
  WAN = 'WAN',
  VPN = 'VPN',
  UNKNOWN = 'UNKNOWN'
}

export class ConnectionPathInfo {
  path: ConnectionPath;
  targetHost: string;
  targetAddress: string;
  netId: number;
  bearerKey: string;
  isVpn: boolean;
  isCellular: boolean;
  isMetered: boolean;
  localNetworkKey: string;

  constructor(path: ConnectionPath, targetHost: string, targetAddress: string, netId: number,
    bearerKey: string, isVpn: boolean, isCellular: boolean, isMetered: boolean, localNetworkKey: string) {
    this.path = path;
    this.targetHost = targetHost;
    this.targetAddress = targetAddress;
    this.netId = netId;
    this.bearerKey = bearerKey;
    this.isVpn = isVpn;
    this.isCellular = isCellular;
    this.isMetered = isMetered;
    this.localNetworkKey = localNetworkKey;
  }

  cacheKey(hostId: string): string {
    return hostId + '|' + this.targetHost + '|' + this.targetAddress + '|' + this.netId.toString() + '|' +
      this.localNetworkKey + '|' + this.bearerKey + '|' + (this.isVpn ? 'vpn' : 'direct') + '|' +
      (this.isMetered ? 'metered' : 'unmetered');
  }
}

export class ConnectionPathService {
  static classify(targetAddresses: string[], isVpn: boolean, isCellular: boolean = false): ConnectionPath {
    if (isVpn) {
      return ConnectionPath.VPN;
    }
    let hasLanAddress = false;
    let hasPublicAddress = false;
    for (let i = 0; i < targetAddresses.length; i++) {
      if (isLanAddress(targetAddresses[i])) {
        hasLanAddress = true;
      }
      if (isPublicAddress(targetAddresses[i])) {
        hasPublicAddress = true;
      }
    }
    if (hasLanAddress && !hasPublicAddress && !isCellular) {
      return ConnectionPath.LAN;
    }
    if (hasPublicAddress && !hasLanAddress) {
      return ConnectionPath.WAN;
    }
    return ConnectionPath.UNKNOWN;
  }

  static async inspect(endpoint: string): Promise<ConnectionPathInfo> {
    const targetHost = parseAddressAndPort(endpoint).host;
    let netId = 0;
    let bearerKey = 'unknown';
    let isVpn = false;
    let isCellular = false;
    let isMetered = true;
    let localNetworkKey = 'unknown';
    let netHandle: connection.NetHandle | null = null;

    try {
      netHandle = await connection.getDefaultNet();
      netId = netHandle.netId;
      const capabilities = await connection.getNetCapabilities(netHandle);
      const bearerValues: string[] = [];
      for (let i = 0; i < capabilities.bearerTypes.length; i++) {
        const bearer = capabilities.bearerTypes[i];
        bearerValues.push(bearer.toString());
        if (bearer === connection.NetBearType.BEARER_VPN) {
          isVpn = true;
        }
        if (bearer === connection.NetBearType.BEARER_CELLULAR) {
          isCellular = true;
        }
      }
      bearerValues.sort();
      bearerKey = bearerValues.length > 0 ? bearerValues.join(',') : 'unknown';
      if (capabilities.networkCap) {
        isMetered = capabilities.networkCap.indexOf(connection.NetCap.NET_CAPABILITY_NOT_METERED) < 0;
        if (capabilities.networkCap.indexOf(connection.NetCap.NET_CAPABILITY_NOT_VPN) < 0) {
          isVpn = true;
        }
      }
    } catch (err) {
      console.warn('ConnectionPathService: 读取默认网络能力失败: ' + String(err));
    }

    if (netHandle) {
      try {
        const properties = await connection.getConnectionProperties(netHandle);
        const localParts: string[] = [];
        for (let i = 0; i < properties.linkAddresses.length; i++) {
          const linkAddress = properties.linkAddresses[i];
          localParts.push(linkAddress.address.address + '/' + linkAddress.prefixLength.toString());
        }
        localParts.sort();
        localNetworkKey = properties.interfaceName + ':' + localParts.join(',');
      } catch (err) {
        console.warn('ConnectionPathService: 读取本地链路属性失败: ' + String(err));
      }
    }

    const resolvedAddresses: string[] = [];
    if (isIPv4Address(targetHost) || isIPv6Address(targetHost)) {
      resolvedAddresses.push(targetHost);
    } else if (netHandle && targetHost.length > 0) {
      try {
        const addresses = await netHandle.getAddressesByName(targetHost);
        for (let i = 0; i < addresses.length; i++) {
          if (addresses[i].address.length > 0) {
            resolvedAddresses.push(addresses[i].address);
          }
        }
      } catch (err) {
        console.warn('ConnectionPathService: 目标域名解析失败: ' + String(err));
      }
    }

    const path = ConnectionPathService.classify(resolvedAddresses, isVpn, isCellular);
    const targetAddress = ConnectionPathService.pickTargetAddress(resolvedAddresses, path);
    return new ConnectionPathInfo(path, targetHost, targetAddress, netId, bearerKey,
      isVpn, isCellular, isMetered, localNetworkKey);
  }

  private static pickTargetAddress(addresses: string[], path: ConnectionPath): string {
    for (let i = 0; i < addresses.length; i++) {
      if (path === ConnectionPath.LAN && isLanAddress(addresses[i])) {
        return addresses[i];
      }
      if (path === ConnectionPath.WAN && isPublicAddress(addresses[i])) {
        return addresses[i];
      }
    }
    return addresses.length > 0 ? addresses[0] : 'unresolved';
  }
}
