/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * 网络地址分析工具类
 *
 * 移植自 Android Moonlight 的 NetHelper.java / ComputerDetails.java / MdnsDiscoveryAgent.java，
 * 提供 IP 地址类型判断（LAN / WAN / VPN / link-local）能力。
 */

/**
 * 地址类型枚举
 */
export enum AddressType {
  /** RFC 1918 私有 IPv4 (10.x / 172.16-31.x / 192.168.x) 或 IPv4 loopback */
  LAN_IPV4 = 'LAN_IPV4',
  /** IPv6 link-local (fe80::/10) */
  IPV6_LINK_LOCAL = 'IPV6_LINK_LOCAL',
  /** IPv6 site-local / ULA (fc00::/7 即 fc/fd 前缀) */
  IPV6_ULA = 'IPV6_ULA',
  /** IPv6 全局单播地址 (排除 6to4 / Teredo) */
  IPV6_GLOBAL = 'IPV6_GLOBAL',
  /** IPv6 6to4 (2002::/16) 或 Teredo (2001:0000::/32) — 性能差 */
  IPV6_TUNNEL = 'IPV6_TUNNEL',
  /** 公网 IPv4 地址 */
  WAN = 'WAN',
  /** 环回地址 (127.x 或 ::1) */
  LOOPBACK = 'LOOPBACK',
  /** 无法识别 */
  UNKNOWN = 'UNKNOWN',
}

// ─────────────────────── IPv4 工具 ───────────────────────

/**
 * 将点分十进制的 IPv4 地址字符串解析为 4 字节数组。
 * 返回 null 表示格式无效。
 */
function parseIPv4(address: string): number[] | null {
  const parts = address.split('.');
  if (parts.length !== 4) {
    return null;
  }
  const bytes: number[] = [];
  for (const part of parts) {
    const n = parseInt(part, 10);
    if (isNaN(n) || n < 0 || n > 255 || part !== n.toString()) {
      return null;
    }
    bytes.push(n);
  }
  return bytes;
}

/**
 * 判断是否为 IPv4 私有地址 (RFC 1918)
 *
 * - 10.0.0.0/8
 * - 172.16.0.0/12  (172.16.0.0 – 172.31.255.255)
 * - 192.168.0.0/16
 *
 * 对应 Android NetHelper.isPrivateAddress()
 */
export function isPrivateIPv4(address: string): boolean {
  const bytes = parseIPv4(address);
  if (!bytes) {
    return false;
  }
  // 10.0.0.0/8
  if (bytes[0] === 10) {
    return true;
  }
  // 172.16.0.0/12
  if (bytes[0] === 172 && bytes[1] >= 16 && bytes[1] <= 31) {
    return true;
  }
  // 192.168.0.0/16
  if (bytes[0] === 192 && bytes[1] === 168) {
    return true;
  }
  return false;
}

/**
 * 判断是否为 IPv4 环回地址 (127.0.0.0/8)
 */
export function isLoopbackIPv4(address: string): boolean {
  const bytes = parseIPv4(address);
  return bytes !== null && bytes[0] === 127;
}

/**
 * 判断是否为 IPv4 link-local 地址 (169.254.0.0/16)
 */
export function isLinkLocalIPv4(address: string): boolean {
  const bytes = parseIPv4(address);
  return bytes !== null && bytes[0] === 169 && bytes[1] === 254;
}

/**
 * 判断地址字符串是否为合法的 IPv4 格式
 */
export function isIPv4Address(address: string): boolean {
  return parseIPv4(address) !== null;
}

// ─────────────────────── IPv6 工具 ───────────────────────

/**
 * 标准化 IPv6 地址：去除可能的 [] 包裹和 %scopeId 后缀
 */
function normalizeIPv6(address: string): string {
  let addr = address;
  // 去 []
  if (addr.startsWith('[') && addr.includes(']')) {
    addr = addr.substring(1, addr.indexOf(']'));
  }
  // 去 %scopeId
  const pctIdx = addr.indexOf('%');
  if (pctIdx !== -1) {
    addr = addr.substring(0, pctIdx);
  }
  return addr.toLowerCase();
}

/**
 * 判断地址字符串是否为 IPv6 格式（包含至少 2 个冒号）
 */
export function isIPv6Address(address: string): boolean {
  if (!address) {
    return false;
  }
  let colonCount = 0;
  for (const c of address) {
    if (c === ':') {
      colonCount++;
    }
  }
  return colonCount >= 2;
}

/**
 * 判断是否为 IPv6 link-local 地址 (fe80::/10)
 *
 * 对应 Android InetAddress.isLinkLocalAddress()
 */
export function isIPv6LinkLocal(address: string): boolean {
  if (!isIPv6Address(address)) {
    return false;
  }
  const addr = normalizeIPv6(address);
  return addr.startsWith('fe80:') || addr.startsWith('fe80%') || addr === 'fe80' ||
    addr.startsWith('fe9') || addr.startsWith('fea') || addr.startsWith('feb');
}

/**
 * 判断是否为 IPv6 ULA 地址 (fc00::/7，即 fc 或 fd 开头)
 */
export function isIPv6ULA(address: string): boolean {
  if (!isIPv6Address(address)) {
    return false;
  }
  const addr = normalizeIPv6(address);
  return addr.startsWith('fc') || addr.startsWith('fd');
}

/**
 * 判断是否为 IPv6 site-local 地址 (fec0::/10，已弃用但仍需识别)
 *
 * 对应 Android InetAddress.isSiteLocalAddress()
 */
export function isIPv6SiteLocal(address: string): boolean {
  if (!isIPv6Address(address)) {
    return false;
  }
  const addr = normalizeIPv6(address);
  return addr.startsWith('fec') || addr.startsWith('fed') || addr.startsWith('fee') || addr.startsWith('fef');
}

/**
 * 判断是否为 IPv6 6to4 隧道地址 (2002::/16) — 性能差
 */
export function isIPv6_6to4(address: string): boolean {
  if (!isIPv6Address(address)) {
    return false;
  }
  const addr = normalizeIPv6(address);
  return addr.startsWith('2002:');
}

/**
 * 判断是否为 IPv6 Teredo 隧道地址 (2001:0000::/32) — 性能差
 */
export function isIPv6Teredo(address: string): boolean {
  if (!isIPv6Address(address)) {
    return false;
  }
  const addr = normalizeIPv6(address);
  // 2001:0000: 或 2001:0:
  return addr.startsWith('2001:0000:') || addr.startsWith('2001:0:');
}

/**
 * 判断是否为 IPv6 环回地址 (::1)
 */
export function isIPv6Loopback(address: string): boolean {
  if (!isIPv6Address(address)) {
    return false;
  }
  const addr = normalizeIPv6(address);
  return addr === '::1' || addr === '0000:0000:0000:0000:0000:0000:0000:0001';
}

// ─────────────────────── 综合判断 ───────────────────────

/**
 * 判断地址是否为 LAN 地址（私有 IPv4 / loopback / link-local IPv4）
 *
 * 等价于 Android NetHelper.isLanAddress():
 *   addr.isSiteLocalAddress() || addr.isLoopbackAddress() || isPrivateAddress(addr)
 */
export function isLanAddress(addressStr: string | undefined | null): boolean {
  if (!addressStr) {
    return false;
  }

  // 去掉端口号
  const address = stripPort(addressStr);

  if (isIPv4Address(address)) {
    return isPrivateIPv4(address) || isLoopbackIPv4(address) || isLinkLocalIPv4(address);
  }

  // IPv6: link-local / ULA / site-local 都视为 LAN
  if (isIPv6Address(address)) {
    return isIPv6LinkLocal(address) || isIPv6ULA(address) || isIPv6SiteLocal(address) || isIPv6Loopback(address);
  }

  return false;
}

/**
 * 判断地址是否为公网地址
 *
 * 等价于 Android ComputerDetails.isPublicAddress()
 */
export function isPublicAddress(addressStr: string | undefined | null): boolean {
  if (!addressStr) {
    return false;
  }
  const address = stripPort(addressStr);

  if (isIPv4Address(address)) {
    return !isPrivateIPv4(address) && !isLoopbackIPv4(address) && !isLinkLocalIPv4(address);
  }

  // 非 LAN 类型的 IPv6 全局地址（排除隧道）
  if (isIPv6Address(address)) {
    return !isIPv6LinkLocal(address) && !isIPv6ULA(address) && !isIPv6SiteLocal(address) &&
      !isIPv6Loopback(address) && !isIPv6_6to4(address) && !isIPv6Teredo(address);
  }

  return false;
}

/**
 * 判断 IPv4 地址是否为 LAN IPv4 地址
 *
 * 等价于 Android ComputerDetails.isLanIpv4Address()
 */
export function isLanIPv4Address(addressStr: string | undefined | null): boolean {
  if (!addressStr) {
    return false;
  }
  const address = stripPort(addressStr);
  if (!isIPv4Address(address)) {
    return false;
  }
  return isPrivateIPv4(address) || isLoopbackIPv4(address) || isLinkLocalIPv4(address);
}

/**
 * 检测地址类型
 */
export function detectAddressType(addressStr: string | undefined | null): AddressType {
  if (!addressStr) {
    return AddressType.UNKNOWN;
  }
  const address = stripPort(addressStr);

  // IPv4
  if (isIPv4Address(address)) {
    if (isLoopbackIPv4(address)) {
      return AddressType.LOOPBACK;
    }
    if (isPrivateIPv4(address) || isLinkLocalIPv4(address)) {
      return AddressType.LAN_IPV4;
    }
    return AddressType.WAN;
  }

  // IPv6
  if (isIPv6Address(address)) {
    if (isIPv6Loopback(address)) {
      return AddressType.LOOPBACK;
    }
    if (isIPv6LinkLocal(address)) {
      return AddressType.IPV6_LINK_LOCAL;
    }
    if (isIPv6ULA(address) || isIPv6SiteLocal(address)) {
      return AddressType.IPV6_ULA;
    }
    if (isIPv6_6to4(address) || isIPv6Teredo(address)) {
      return AddressType.IPV6_TUNNEL;
    }
    return AddressType.IPV6_GLOBAL;
  }

  return AddressType.UNKNOWN;
}

/**
 * 获取地址类型的中文描述（用于 UI 显示）
 */
export function getAddressTypeLabel(addressStr: string | undefined | null): string {
  const type = detectAddressType(addressStr);
  switch (type) {
    case AddressType.LAN_IPV4:
      return '局域网';
    case AddressType.IPV6_LINK_LOCAL:
      return 'IPv6 链路本地';
    case AddressType.IPV6_ULA:
      return 'IPv6 局域网';
    case AddressType.IPV6_GLOBAL:
      return 'IPv6 公网';
    case AddressType.IPV6_TUNNEL:
      return 'IPv6 隧道';
    case AddressType.WAN:
      return '远程网络';
    case AddressType.LOOPBACK:
      return '本机环回';
    default:
      return '未知';
  }
}

// ─────────────────────── 内部工具 ───────────────────────

/**
 * 从地址字符串中去除端口号
 * 支持: "192.168.1.1:47989" -> "192.168.1.1"
 *       "[fe80::1]:47989"   -> "fe80::1"
 *       "fe80::1%eth0"      -> "fe80::1"
 */
function stripPort(addressStr: string): string {
  let addr = addressStr.trim();

  // [IPv6]:port 格式
  if (addr.startsWith('[')) {
    const closeBracket = addr.indexOf(']');
    if (closeBracket !== -1) {
      addr = addr.substring(1, closeBracket);
    }
  } else if (isIPv6Address(addr)) {
    // 纯 IPv6 无端口，直接返回
    return normalizeIPv6(addr);
  } else {
    // IPv4:port 或纯 IPv4
    const colonIdx = addr.lastIndexOf(':');
    if (colonIdx !== -1) {
      const possiblePort = addr.substring(colonIdx + 1);
      const portNum = parseInt(possiblePort, 10);
      if (!isNaN(portNum) && portNum > 0 && portNum <= 65535 && possiblePort === portNum.toString()) {
        addr = addr.substring(0, colonIdx);
      }
    }
  }

  // 去 %scopeId
  const pctIdx = addr.indexOf('%');
  if (pctIdx !== -1) {
    addr = addr.substring(0, pctIdx);
  }

  return addr;
}
