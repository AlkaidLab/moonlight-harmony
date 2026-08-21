/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { AddressHolder } from '../../model/ComputerInfo';
import { isLoopbackIPv4 } from '../../utils/NetHelper';

export enum ServerIdentityDisposition {
  MATCH = 0,
  RECONCILE_DISCOVERED = 1,
  MISSING = 2,
  MISMATCH = 3
}

export interface AddressCollectionOptions {
  includePreferred?: boolean;
  excludeLoopbackIPv4?: boolean;
}

/** 对服务器返回的 UUID 做无副作用分类。 */
export function classifyServerIdentity(
  computerUuid: string,
  serverUniqueId: string | undefined | null
): ServerIdentityDisposition {
  if (!serverUniqueId) {
    return ServerIdentityDisposition.MISSING;
  }
  if (computerUuid === serverUniqueId) {
    return ServerIdentityDisposition.MATCH;
  }
  if (computerUuid.startsWith('discovered-')) {
    return ServerIdentityDisposition.RECONCILE_DISCOVERED;
  }
  return ServerIdentityDisposition.MISMATCH;
}

/**
 * 收集电脑的已知地址并保持稳定顺序。
 * 状态轮询使用默认选项；诊断可额外包含锁定地址并过滤回环 IPv4。
 */
export function collectKnownAddresses(
  computer: AddressHolder,
  options?: AddressCollectionOptions
): string[] {
  const addresses = new Set<string>();
  const add = (address: string | undefined): void => {
    if (!address) return;
    if (options?.excludeLoopbackIPv4 && isLoopbackIPv4(address)) return;
    addresses.add(address);
  };

  if (options?.includePreferred) {
    add(computer.preferredAddress);
  }
  add(computer.manualAddress);
  add(computer.address);
  add(computer.localAddress);
  add(computer.remoteAddress);
  add(computer.ipv6Address);
  return Array.from(addresses);
}
