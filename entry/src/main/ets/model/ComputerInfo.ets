/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { isLanIPv4Address, isLanAddress, isIPv6Address, isPublicAddress, detectAddressType, AddressType, getAddressTypeLabel } from '../utils/NetHelper';

/**
 * 电脑信息模型
 */
export enum ComputerState {
  UNKNOWN = 0,
  ONLINE = 1,
  OFFLINE = 2,
  PAIRING = 3
}

export enum PairState {
  NOT_PAIRED = 0,
  PAIRED = 1,
  PIN_WRONG = 2,
  FAILED = 3
}

export interface Resolution {
  width: number;
  height: number;
}

/**
 * selectBestAddress 所需的最小地址字段集
 * ComputerInfo 和 ObservableComputer 均满足此接口
 */
export interface AddressHolder {
  address: string;
  localAddress: string;
  remoteAddress: string;
  manualAddress?: string;
  ipv6Address?: string;
}

export interface ComputerInfo extends AddressHolder {
  uuid: string;
  name: string;
  macAddress: string;
  state: ComputerState;
  pairState: PairState;
  runningGameId: number;
  serverCert: string;
  pairName: string;  // 配对时服务器返回的名称
  gpuType: string;
  maxSupportedResolution: Resolution;
  isNvidiaSoftware: boolean;
  // 主机头像 - 第一个应用的 boxArt URL
  boxArtUrl?: string;
  // 自定义 HTTP 端口（默认 47989）
  httpPort?: number;
}

/**
 * 选择最佳连接地址
 *
 * 核心原则：**已验证可达的地址 > 未验证的地址**
 *
 * `address` 字段由轮询竞速胜出者设置（raceForFirstSuccess），
 * 代表最近一次成功连接的地址，因此是已验证可达的。
 *
 * 旧逻辑无条件优先返回 localAddress（服务器自报的 LAN IP），即使用户
 * 在外网也会返回不可达的内网地址 → 导致 WAN 配对/连接失败。
 *
 * 修正后的优先级:
 *   1. 活跃地址（轮询胜出，已验证可达）
 *   2. 回退链（无活跃地址时，如首次添加/离线）
 */
export function selectBestAddress(computer: AddressHolder): string {
  // 1. 活跃地址存在 → 直接返回（已被最近一次轮询验证为可达）
  //    - LAN IP 胜出：低延迟 + 可达 ✓
  //    - 域名/WAN IP 胜出：可达 ✓（不假设 localAddress 也可达）
  if (computer.address) {
    return computer.address;
  }

  // — 以下为无活跃地址时的回退（首次添加后未轮询、离线恢复等） —

  // 2. 用户手动输入的地址（域名/IP，用户意图明确）
  if (computer.manualAddress) return computer.manualAddress;

  // 3. LAN IPv4（服务器自报，可能可达可能不可达）
  if (computer.localAddress && isLanIPv4Address(computer.localAddress)) {
    return computer.localAddress;
  }

  // 4. IPv6 LAN 地址
  if (computer.ipv6Address && isLanAddress(computer.ipv6Address)) {
    return computer.ipv6Address;
  }

  // 5. localAddress（非 LAN 类型）
  if (computer.localAddress) return computer.localAddress;

  // 6. IPv6 全局单播
  if (computer.ipv6Address) return computer.ipv6Address;

  // 7. WAN 外网地址
  if (computer.remoteAddress) return computer.remoteAddress;

  return '';
}

/**
 * 获取地址的网络类型描述
 */
export function getAddressNetworkLabel(address: string | undefined): string {
  return getAddressTypeLabel(address);
}

/**
 * 判断计算机是否有可用的 LAN 地址
 */
export function hasLanAddress(computer: ComputerInfo): boolean {
  return isLanAddress(computer.localAddress) ||
    isLanAddress(computer.address) ||
    isLanAddress(computer.manualAddress);
}

export class ComputerInfoBuilder {
  private info: ComputerInfo;

  constructor() {
    this.info = {
      uuid: '',
      name: '',
      address: '',
      localAddress: '',
      remoteAddress: '',
      manualAddress: undefined,
      ipv6Address: undefined,
      macAddress: '',
      state: ComputerState.UNKNOWN,
      pairState: PairState.NOT_PAIRED,
      runningGameId: 0,
      serverCert: '',
      pairName: '',
      gpuType: '',
      maxSupportedResolution: { width: 1920, height: 1080 },
      isNvidiaSoftware: false,
      boxArtUrl: '',
      httpPort: undefined
    };
  }

  setUuid(uuid: string): ComputerInfoBuilder {
    this.info.uuid = uuid;
    return this;
  }

  setName(name: string): ComputerInfoBuilder {
    this.info.name = name;
    return this;
  }

  setAddress(address: string): ComputerInfoBuilder {
    this.info.address = address;
    return this;
  }

  setLocalAddress(localAddress: string): ComputerInfoBuilder {
    this.info.localAddress = localAddress;
    return this;
  }

  setRemoteAddress(remoteAddress: string): ComputerInfoBuilder {
    this.info.remoteAddress = remoteAddress;
    return this;
  }

  setManualAddress(manualAddress: string | undefined): ComputerInfoBuilder {
    this.info.manualAddress = manualAddress;
    return this;
  }

  setIpv6Address(ipv6Address: string | undefined): ComputerInfoBuilder {
    this.info.ipv6Address = ipv6Address;
    return this;
  }

  setMacAddress(macAddress: string): ComputerInfoBuilder {
    this.info.macAddress = macAddress;
    return this;
  }

  setState(state: ComputerState): ComputerInfoBuilder {
    this.info.state = state;
    return this;
  }

  setPairState(pairState: PairState): ComputerInfoBuilder {
    this.info.pairState = pairState;
    return this;
  }

  setRunningGameId(gameId: number): ComputerInfoBuilder {
    this.info.runningGameId = gameId;
    return this;
  }

  setServerCert(cert: string): ComputerInfoBuilder {
    this.info.serverCert = cert;
    return this;
  }

  setPairName(pairName: string): ComputerInfoBuilder {
    this.info.pairName = pairName;
    return this;
  }

  setGpuType(gpuType: string): ComputerInfoBuilder {
    this.info.gpuType = gpuType;
    return this;
  }

  setMaxSupportedResolution(res: Resolution): ComputerInfoBuilder {
    this.info.maxSupportedResolution = res;
    return this;
  }

  setIsNvidiaSoftware(isNvidia: boolean): ComputerInfoBuilder {
    this.info.isNvidiaSoftware = isNvidia;
    return this;
  }

  setBoxArtUrl(url: string): ComputerInfoBuilder {
    this.info.boxArtUrl = url;
    return this;
  }

  setHttpPort(port: number | undefined): ComputerInfoBuilder {
    this.info.httpPort = port;
    return this;
  }

  build(): ComputerInfo {
    const result: ComputerInfo = {
      uuid: this.info.uuid,
      name: this.info.name,
      address: this.info.address,
      localAddress: this.info.localAddress,
      remoteAddress: this.info.remoteAddress,
      manualAddress: this.info.manualAddress,
      ipv6Address: this.info.ipv6Address,
      macAddress: this.info.macAddress,
      state: this.info.state,
      pairState: this.info.pairState,
      runningGameId: this.info.runningGameId,
      serverCert: this.info.serverCert,
      pairName: this.info.pairName,
      gpuType: this.info.gpuType,
      maxSupportedResolution: {
        width: this.info.maxSupportedResolution.width,
        height: this.info.maxSupportedResolution.height
      },
      isNvidiaSoftware: this.info.isNvidiaSoftware,
      boxArtUrl: this.info.boxArtUrl,
      httpPort: this.info.httpPort
    };
    return result;
  }
}
