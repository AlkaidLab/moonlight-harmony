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
 * 电脑数据持久化模块
 *
 * 负责电脑列表的序列化/反序列化、深拷贝、以及旧数据格式兼容处理。
 * 从 ComputerManager 中提取，遵循单一职责原则。
 */
import { ComputerInfo, ComputerState, PairState, ComputerInfoBuilder } from '../model/ComputerInfo';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { NvHttp } from './NvHttp';
import { MAX_PORT } from '../common/NetworkConstants';

// =============================================================================
// 类型定义
// =============================================================================

/**
 * 持久化存储的电脑数据格式
 */
interface SavedComputerData {
  uuid: string;
  name: string;
  address: string;
  localAddress: string;
  remoteAddress: string;
  manualAddress?: string;
  ipv6Address?: string;
  macAddress: string;
  serverCert: string;
  pairState: string;
  runningGameId: number;
  boxArtUrl?: string;
  httpPort?: number;
}

/**
 * 地址端口提取结果
 */
interface ExtractedHostPort {
  host: string;
  port: number;
}

/** 持久化存储键名 */
const STORAGE_KEY = 'saved_computers';

// =============================================================================
// ComputerPersistence
// =============================================================================

/**
 * 电脑数据持久化工具类
 *
 * 提供纯静态方法，无内部状态：
 * - 深拷贝 ComputerInfo
 * - 保存 / 加载电脑列表（Preferences）
 * - 兼容旧版数据格式（配对状态字符串、地址中嵌入端口等）
 */
export class ComputerPersistence {

  // ---------------------------------------------------------------------------
  // 深拷贝
  // ---------------------------------------------------------------------------

  /**
   * 深拷贝电脑对象，确保 ArkUI @State 能检测到变化
   */
  static cloneComputer(computer: ComputerInfo): ComputerInfo {
    return {
      uuid: computer.uuid,
      name: computer.name,
      address: computer.address,
      localAddress: computer.localAddress,
      remoteAddress: computer.remoteAddress,
      manualAddress: computer.manualAddress,
      ipv6Address: computer.ipv6Address,
      macAddress: computer.macAddress,
      state: computer.state,
      pairState: computer.pairState,
      runningGameId: computer.runningGameId,
      serverCert: computer.serverCert,
      pairName: computer.pairName,
      gpuType: computer.gpuType,
      maxSupportedResolution: {
        width: computer.maxSupportedResolution.width,
        height: computer.maxSupportedResolution.height
      },
      isNvidiaSoftware: computer.isNvidiaSoftware,
      boxArtUrl: computer.boxArtUrl,
      httpPort: computer.httpPort
    };
  }

  // ---------------------------------------------------------------------------
  // 保存
  // ---------------------------------------------------------------------------

  /**
   * 保存电脑列表到持久化存储
   */
  static async saveComputers(computers: Map<string, ComputerInfo>): Promise<void> {
    try {
      const computerList: SavedComputerData[] = [];
      computers.forEach((computer) => {
        let pairStateStr: string = 'NOT_PAIRED';
        if (computer.pairState === PairState.PAIRED) {
          pairStateStr = 'PAIRED';
        } else if (computer.pairState === PairState.PIN_WRONG) {
          pairStateStr = 'PIN_WRONG';
        } else if (computer.pairState === PairState.FAILED) {
          pairStateStr = 'FAILED';
        }

        const savedData: SavedComputerData = {
          uuid: computer.uuid,
          name: computer.name,
          address: computer.address,
          localAddress: computer.localAddress,
          remoteAddress: computer.remoteAddress,
          manualAddress: computer.manualAddress,
          ipv6Address: computer.ipv6Address,
          macAddress: computer.macAddress,
          serverCert: computer.serverCert,
          pairState: pairStateStr,
          runningGameId: computer.runningGameId,
          boxArtUrl: computer.boxArtUrl || '',
          httpPort: computer.httpPort
        };
        computerList.push(savedData);
      });

      await PreferencesUtil.put(STORAGE_KEY, JSON.stringify(computerList));
      console.info(`ComputerPersistence: 保存 ${computerList.length} 台电脑`);
    } catch (err) {
      console.error('ComputerPersistence: 保存电脑列表失败', err);
    }
  }

  // ---------------------------------------------------------------------------
  // 加载
  // ---------------------------------------------------------------------------

  /**
   * 从持久化存储加载电脑列表
   */
  static async loadComputers(): Promise<Map<string, ComputerInfo>> {
    const computers = new Map<string, ComputerInfo>();

    try {
      const savedJson = await PreferencesUtil.get<string>(STORAGE_KEY, '');
      if (!savedJson) {
        console.info('ComputerPersistence: 没有保存的电脑');
        return computers;
      }

      const computerList = JSON.parse(savedJson) as SavedComputerData[];
      console.info(`ComputerPersistence: 解析到 ${computerList.length} 台电脑`);

      for (const saved of computerList) {
        // 解析配对状态（兼容旧格式数字字符串 "1" 和新格式 "PAIRED"）
        const pairState = ComputerPersistence.parsePairState(saved.pairState);

        // 兼容旧数据：从地址中提取端口
        let httpPort = saved.httpPort;
        let addressHost = saved.address;
        if (!httpPort && saved.address) {
          const extracted = ComputerPersistence.extractPortFromAddress(saved.address);
          if (extracted) {
            httpPort = extracted.port;
            addressHost = extracted.host;
          }
        }

        console.info(`ComputerPersistence: 加载 ${saved.name} (pairState=${pairState}, httpPort=${httpPort}, cert=${saved.serverCert ? '有' : '无'})`);

        const computer = new ComputerInfoBuilder()
          .setUuid(saved.uuid)
          .setName(saved.name)
          .setAddress(addressHost)
          .setLocalAddress(saved.localAddress || addressHost)
          .setRemoteAddress(saved.remoteAddress || '')
          .setManualAddress(saved.manualAddress)
          .setIpv6Address(saved.ipv6Address)
          .setMacAddress(saved.macAddress || '')
          .setServerCert(saved.serverCert || '')
          .setState(ComputerState.UNKNOWN)
          .setPairState(pairState)
          .setRunningGameId(saved.runningGameId || 0)
          .setBoxArtUrl(saved.boxArtUrl || '')
          .setHttpPort(httpPort)
          .build();

        computers.set(computer.uuid, computer);
      }

      console.info(`ComputerPersistence: 加载完成，共 ${computers.size} 台电脑`);
    } catch (err) {
      console.error('ComputerPersistence: 加载电脑列表失败', err);
    }

    return computers;
  }

  // ---------------------------------------------------------------------------
  // 兼容性工具
  // ---------------------------------------------------------------------------

  /**
   * 解析配对状态字符串（兼容旧版数字格式和新版字符串格式）
   */
  static parsePairState(stateStr: string): PairState {
    if (stateStr === 'PAIRED' || stateStr === '1') return PairState.PAIRED;
    if (stateStr === 'FAILED' || stateStr === '3') return PairState.FAILED;
    if (stateStr === 'PIN_WRONG' || stateStr === '2') return PairState.PIN_WRONG;
    return PairState.NOT_PAIRED;
  }

  /**
   * 从旧格式地址中提取端口（兼容迁移）
   * 例如 "192.168.1.100:48000" → { host: "192.168.1.100", port: 48000 }
   */
  static extractPortFromAddress(address: string): ExtractedHostPort | null {
    const colonIndex = address.indexOf(':');
    if (colonIndex > 0 && address.indexOf(':', colonIndex + 1) === -1) {
      const portStr = address.substring(colonIndex + 1);
      const port = parseInt(portStr);
      if (port > 0 && port <= MAX_PORT && port !== NvHttp.DEFAULT_HTTP_PORT) {
        const result: ExtractedHostPort = { host: address.substring(0, colonIndex), port: port };
        return result;
      }
    }
    return null;
  }
}
