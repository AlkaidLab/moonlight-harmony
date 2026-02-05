/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { ComputerInfo, ComputerState, PairState, ComputerInfoBuilder } from '../model/ComputerInfo';
import { NvHttp, ServerInfo } from './NvHttp';
import { MdnsDiscovery, DiscoveredComputer } from './MdnsDiscovery';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { CryptoUtil } from '../utils/CryptoUtil';
import { WakeOnLan } from './WakeOnLan';
import { common } from '@kit.AbilityKit';

/**
 * 地址解析结果
 */
class AddressParseResult {
  host: string = '';
  port: number | undefined = undefined;
}

/**
 * 轮询结果接口
 */
interface PollResult {
  address: string;
  serverInfo: ServerInfo | null;
}

/**
 * 轮询常量 - 参照 Android ComputerManagerService
 */
const SERVERINFO_POLLING_PERIOD_MS = 5000; // 每5秒轮询一次服务器状态（从3秒增加到5秒以减少CPU负载）

/**
 * 电脑管理器 - 管理所有已发现和手动添加的电脑
 */
export class ComputerManager {
  private static instance: ComputerManager;
  private computers: Map<string, ComputerInfo> = new Map();
  private mdnsDiscovery: MdnsDiscovery | null = null;
  private context: common.UIAbilityContext | null = null;
  private onComputerListChanged: (() => void) | null = null;
  private isInitialized: boolean = false;
  private pollingTimerId: number = -1;
  private isPollingActive: boolean = false;

  private constructor() {
    // mdnsDiscovery 需要在 init 时使用 context 初始化
  }

  static getInstance(): ComputerManager {
    if (!ComputerManager.instance) {
      ComputerManager.instance = new ComputerManager();
    }
    return ComputerManager.instance;
  }

  /**
   * 初始化，需要传入 Context
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    // 避免重复初始化
    if (this.isInitialized) {
      console.info('ComputerManager: 已初始化，跳过');
      return;
    }
    
    this.context = context;
    this.mdnsDiscovery = new MdnsDiscovery(context);
    
    // 初始化 PreferencesUtil
    PreferencesUtil.init(context);

    // 设置 mDNS 发现回调
    this.mdnsDiscovery.setOnComputerFoundListener((discovered: DiscoveredComputer) => {
      this.handleDiscoveredComputer(discovered);
    });

    // 加载已保存的电脑（等待完成）
    await this.loadComputers();
    
    this.isInitialized = true;
    console.info('ComputerManager: 初始化完成');

    // 注意：不在这里触发刷新，让调用者设置好回调后再调用 refreshAllComputers()
  }

  /**
   * 设置电脑列表变化回调
   */
  setOnComputerListChangedListener(callback: () => void): void {
    this.onComputerListChanged = callback;
  }

  /**
   * 处理 mDNS 发现的电脑
   */
  private async handleDiscoveredComputer(discovered: DiscoveredComputer): Promise<void> {
    console.info(`ComputerManager: 处理发现的电脑 ${discovered.name} @ ${discovered.address}:${discovered.port}`);

    // 检查是否已存在（按任意地址匹配，包括 manualAddress）
    const existing = Array.from(this.computers.values())
      .find(c => 
        c.address === discovered.address || 
        c.localAddress === discovered.address ||
        c.remoteAddress === discovered.address ||
        c.manualAddress === discovered.address
      );

    if (existing) {
      // 已存在：只更新本地地址，不覆盖 address 和 manualAddress
      // mDNS 发现的地址是本地地址
      if (existing.localAddress !== discovered.address) {
        existing.localAddress = discovered.address;
        console.info(`ComputerManager: 更新 ${existing.name} 的本地地址为 ${discovered.address}`);
      }
      
      // 更新端口（如果 mDNS 提供了非默认端口）
      if (discovered.port && discovered.port !== 47989) {
        existing.httpPort = discovered.port;
        console.info(`ComputerManager: 更新 ${existing.name} 的端口为 ${discovered.port}`);
      }

      // 尝试通过新发现的地址连接
      try {
        const nvHttp = new NvHttp(discovered.address, existing.serverCert, this.context || undefined, existing.httpPort);
        const serverInfo = await nvHttp.getServerInfo();
        existing.state = ComputerState.ONLINE;
        // 注意：不再覆盖 address，只更新 localAddress（已在上面更新）
        // 如果原 address 为空，才设置为发现的地址
        if (!existing.address) {
          existing.address = discovered.address;
        }
        existing.runningGameId = serverInfo.currentGame;
        console.info(`ComputerManager: 已验证电脑在线 ${existing.name}`);
      } catch (err) {
        // mDNS 发现但无法通过该地址连接，尝试其他已知地址
        console.warn(`ComputerManager: mDNS 地址无法连接 ${existing.name}: ${err}，尝试其他地址`);
        await this.pollComputer(existing);
      }
    } else {
      // 尝试连接并添加新电脑，传入 mDNS 发现的端口
      try {
        await this.addComputerInternal(discovered.address, discovered.name, discovered.port);
      } catch (err) {
        console.error(`ComputerManager: 无法添加电脑 ${discovered.name}: ${err}`);
      }
    }

    // 通知列表变化
    if (this.onComputerListChanged) {
      this.onComputerListChanged();
    }
  }

  /**
   * 获取所有电脑列表
   * 返回深拷贝的对象，确保 ArkTS @State 能检测到变化
   */
  async getComputers(): Promise<ComputerInfo[]> {
    return Array.from(this.computers.values()).map(computer => this.cloneComputer(computer));
  }

  /**
   * 深拷贝电脑对象
   */
  private cloneComputer(computer: ComputerInfo): ComputerInfo {
    return {
      uuid: computer.uuid,
      name: computer.name,
      address: computer.address,
      localAddress: computer.localAddress,
      remoteAddress: computer.remoteAddress,
      manualAddress: computer.manualAddress,
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

  /**
   * 根据 UUID 获取电脑
   */
  getComputer(uuid: string): ComputerInfo | undefined {
    const computer = this.computers.get(uuid);
    return computer ? this.cloneComputer(computer) : undefined;
  }

  /**
   * 更新电脑信息（用于配对成功后更新 serverCert 等）
   * @param uuid 电脑 UUID
   * @param updates 要更新的字段
   */
  async updateComputer(uuid: string, updates: Partial<ComputerInfo>): Promise<void> {
    const computer = this.computers.get(uuid);
    if (!computer) {
      console.warn(`ComputerManager: updateComputer 未找到电脑 ${uuid}`);
      return;
    }
    
    // 更新指定字段
    if (updates.pairState !== undefined) {
      computer.pairState = updates.pairState;
    }
    if (updates.serverCert !== undefined) {
      computer.serverCert = updates.serverCert;
    }
    if (updates.pairName !== undefined) {
      computer.pairName = updates.pairName;
    }
    if (updates.address !== undefined) {
      computer.address = updates.address;
    }
    if (updates.state !== undefined) {
      computer.state = updates.state;
    }
    
    console.info(`ComputerManager: 更新电脑 ${computer.name} - pairState=${computer.pairState}, serverCert=${computer.serverCert ? '有' : '无'}`);
    
    // 保存到持久化存储
    await this.saveComputers();
  }

  /**
   * 手动添加电脑
   * @param addressInput 用户输入的地址，支持以下格式：
   *   - "192.168.1.100" - IPv4 地址，使用默认端口
   *   - "192.168.1.100:47989" - IPv4 地址 + 自定义端口
   *   - "::1" 或 "[::1]" - IPv6 地址，使用默认端口
   *   - "[::1]:47989" - IPv6 地址 + 自定义端口
   *   - "mydomain.com" - 域名，会被保存为 manualAddress
   */
  async addComputer(addressInput: string): Promise<ComputerInfo> {
    const parsed = this.parseAddressInput(addressInput);
    const result = await this.addComputerInternal(parsed.host, undefined, parsed.port);
    
    // 保存用户手动输入的地址（可能是域名或 IP）
    // 这个地址永不会被自动发现覆盖
    result.manualAddress = addressInput.trim();
    
    // 保存更新后的电脑信息
    this.computers.set(result.uuid, result);
    await this.saveComputers();
    
    // 通知列表变化
    if (this.onComputerListChanged) {
      this.onComputerListChanged();
    }
    
    return result;
  }

  /**
   * 解析用户输入的地址，提取主机和端口
   */
  private parseAddressInput(input: string): AddressParseResult {
    const trimmed = input.trim();
    const result = new AddressParseResult();
    
    // 检查是否为 IPv6 地址（包含多个冒号）
    let colonCount = 0;
    for (let i = 0; i < trimmed.length; i++) {
      if (trimmed.charAt(i) === ':') {
        colonCount++;
      }
    }
    const isLikelyIPv6 = colonCount >= 2;
    
    if (isLikelyIPv6) {
      // IPv6 地址处理
      if (trimmed.startsWith('[')) {
        // 格式: [::1] 或 [::1]:47989
        const closeBracket = trimmed.indexOf(']');
        if (closeBracket > 0) {
          result.host = trimmed.substring(1, closeBracket);
          if (closeBracket < trimmed.length - 1 && trimmed.charAt(closeBracket + 1) === ':') {
            const portStr = trimmed.substring(closeBracket + 2);
            const port = parseInt(portStr);
            if (port > 0 && port <= 65535) {
              result.port = port;
            }
          }
          return result;
        }
      } else {
        // 格式: ::1 或 ::1:47989（需要智能判断最后部分是否为端口）
        const lastColonIndex = trimmed.lastIndexOf(':');
        if (lastColonIndex > 0 && lastColonIndex < trimmed.length - 1) {
          const possiblePort = trimmed.substring(lastColonIndex + 1);
          const port = parseInt(possiblePort);
          // 如果最后部分是有效端口号
          if (!isNaN(port) && port > 0 && port <= 65535) {
            result.host = trimmed.substring(0, lastColonIndex);
            result.port = port;
            return result;
          }
        }
        // 纯 IPv6 地址
        result.host = trimmed;
        return result;
      }
    } else {
      // IPv4 或主机名
      const colonIndex = trimmed.indexOf(':');
      if (colonIndex > 0) {
        // 格式: 192.168.1.100:47989
        const host = trimmed.substring(0, colonIndex);
        const portStr = trimmed.substring(colonIndex + 1);
        const port = parseInt(portStr);
        if (port > 0 && port <= 65535) {
          result.host = host;
          result.port = port;
          return result;
        }
      }
    }
    
    // 默认：没有端口
    result.host = trimmed;
    return result;
  }

  /**
   * 内部添加电脑方法
   */
  private async addComputerInternal(address: string, discoveredName?: string, httpPort?: number): Promise<ComputerInfo> {
    const nvHttp = new NvHttp(address, null, this.context || undefined, httpPort);

    try {
      // 获取服务器信息
      const serverInfo = await nvHttp.getServerInfo();

      // 使用服务器返回的本地地址，如果没有则使用连接地址
      const localAddr = serverInfo.localAddress || address;
      const remoteAddr = serverInfo.externalAddress || '';

      const computer = new ComputerInfoBuilder()
        .setUuid(serverInfo.uniqueId)
        .setName(serverInfo.hostname || discoveredName || address)
        .setAddress(address) // 保持原始连接地址
        .setLocalAddress(localAddr) // 服务器返回的本地地址
        .setRemoteAddress(remoteAddr) // 服务器返回的外部地址
        .setMacAddress(serverInfo.macAddress || '')
        .setState(ComputerState.ONLINE)
        .setPairState(serverInfo.paired ? PairState.PAIRED : PairState.NOT_PAIRED)
        .setRunningGameId(serverInfo.currentGame || 0)
        .setHttpPort(httpPort) // 保存自定义端口
        .build();

      this.computers.set(computer.uuid, computer);
      await this.saveComputers();

      console.info(`ComputerManager: 成功添加电脑 ${computer.name} (${computer.uuid}), localAddr=${localAddr}, remoteAddr=${remoteAddr}`);
      return computer;
    } catch (err) {
      // 如果无法获取服务器信息，仍然添加但标记为离线
      if (discoveredName) {
        const computer = new ComputerInfoBuilder()
          .setUuid(`discovered-${Date.now()}`)
          .setName(discoveredName)
          .setAddress(address)
          .setLocalAddress(address)
          .setState(ComputerState.UNKNOWN)
          .setPairState(PairState.NOT_PAIRED)
          .build();

        this.computers.set(computer.uuid, computer);
        console.info(`ComputerManager: 添加未确认电脑 ${computer.name}`);
        return computer;
      }
      throw new Error(`无法连接到 ${address}: ${err}`);
    }
  }

  /**
   * 删除电脑
   */
  async removeComputer(uuid: string): Promise<void> {
    this.computers.delete(uuid);
    await this.saveComputers();
  }

  /**
   * 刷新所有电脑状态
   * 并行尝试多个地址（本地地址、远程地址等），任何一个成功即为在线
   * 优化：每台电脑刷新完成后立即通知 UI，不需要等待所有电脑
   */
  async refreshAllComputers(): Promise<void> {
    try {
      const refreshPromises = Array.from(this.computers.values()).map(async (computer) => {
        try {
          const stateChanged = await this.pollComputer(computer);
          // 每台电脑完成后立即通知 UI 更新
          if (this.onComputerListChanged) {
            this.onComputerListChanged();
          }
        } catch (err) {
          // 刷新失败时设为离线状态
          computer.state = ComputerState.OFFLINE;
          // 也通知 UI 更新
          if (this.onComputerListChanged) {
            this.onComputerListChanged();
          }
        }
      });

      await Promise.all(refreshPromises);
    } catch (err) {
      console.error('ComputerManager: refreshAllComputers 异常:', err);
      // 如果整体刷新失败，将所有 UNKNOWN 状态设为 OFFLINE
      this.computers.forEach(computer => {
        if (computer.state === ComputerState.UNKNOWN) {
          computer.state = ComputerState.OFFLINE;
        }
      });
      
      // 即使失败也通知UI刷新
      if (this.onComputerListChanged) {
        this.onComputerListChanged();
      }
    }
  }

  /**
   * 启动状态轮询定时器
   * 类似 Android 的 pollingThread
   */
  startPolling(): void {
    if (this.isPollingActive) {
      return;
    }
    
    this.isPollingActive = true;
    console.info('ComputerManager: 启动状态轮询');
    
    // 立即执行一次刷新，然后定时轮询
    this.refreshAllComputers().catch((err: Error) => {
      console.warn('ComputerManager: 初始刷新失败', err);
    });
    
    this.pollingTimerId = setInterval(async () => {
      if (!this.isPollingActive) {
        return;
      }
      
      await this.refreshAllComputers();
    }, SERVERINFO_POLLING_PERIOD_MS);
  }
  
  /**
   * 停止状态轮询定时器
   */
  stopPolling(): void {
    if (this.pollingTimerId !== -1) {
      console.info('ComputerManager: 停止状态轮询');
      clearInterval(this.pollingTimerId);
      this.pollingTimerId = -1;
    }
    this.isPollingActive = false;
  }

  /**
   * 轮询单台电脑，并行尝试所有已知地址
   * 使用"任一成功即返回"策略，不需要等待所有地址超时
   */
  async pollComputer(computer: ComputerInfo): Promise<boolean> {
    // 收集所有可能的地址（去重）
    // 优先级：manualAddress > address > localAddress > remoteAddress
    const addressSet = new Set<string>();
    if (computer.manualAddress) addressSet.add(computer.manualAddress);  // 手动输入的地址优先
    if (computer.address) addressSet.add(computer.address);
    if (computer.localAddress) addressSet.add(computer.localAddress);
    if (computer.remoteAddress) addressSet.add(computer.remoteAddress);

    const addresses = Array.from(addressSet);
    console.info(`ComputerManager: 正在轮询 ${computer.name}，地址列表: ${addresses.join(', ')}`);

    if (addresses.length === 0) {
      console.warn(`ComputerManager: ${computer.name} 没有可用地址`);
      computer.state = ComputerState.OFFLINE;
      return false;
    }

    // 辅助函数：尝试连接单个地址
    const tryAddress = async (address: string): Promise<PollResult> => {
      try {
        const nvHttp = new NvHttp(address, computer.serverCert, this.context || undefined, computer.httpPort);
        const serverInfo = await nvHttp.getServerInfo();
        return { address, serverInfo };
      } catch (err) {
        console.info(`ComputerManager: ${computer.name} @ ${address} 无法连接: ${err}`);
        return { address, serverInfo: null };
      }
    };

    // 并行尝试所有地址，使用 Promise.race 风格
    // 将每个地址的尝试包装成一个 Promise
    const addressPromises = addresses.map(address => tryAddress(address));
    
    // 创建一个"任一成功即 resolve"的 Promise
    const firstSuccessPromise = new Promise<PollResult | null>((resolve) => {
      let completedCount = 0;
      let hasResolved = false;
      
      for (const p of addressPromises) {
        p.then((result: PollResult) => {
          if (result.serverInfo !== null && !hasResolved) {
            hasResolved = true;
            resolve(result);
          }
          completedCount++;
          // 所有地址都尝试完毕且没有成功
          if (completedCount === addresses.length && !hasResolved) {
            resolve(null);
          }
        }).catch(() => {
          completedCount++;
          if (completedCount === addresses.length && !hasResolved) {
            resolve(null);
          }
        });
      }
    });

    const successResult = await firstSuccessPromise;

    if (successResult && successResult.serverInfo) {
      computer.state = ComputerState.ONLINE;
      // 更新 address 为可用的地址，但不覆盖 manualAddress
      // 如果成功的地址是 manualAddress，则不改变 address
      if (successResult.address !== computer.manualAddress) {
        computer.address = successResult.address;
      }
      computer.runningGameId = successResult.serverInfo.currentGame;
      
      // 更新 MAC 地址（如果服务器返回了有效的 MAC 地址）
      const serverMac = successResult.serverInfo.macAddress;
      if (serverMac && serverMac !== '00:00:00:00:00:00' && serverMac !== '') {
        computer.macAddress = serverMac;
        console.info(`ComputerManager: ${computer.name} 更新 MAC 地址: ${serverMac}`);
      }
      
      // 更新本地/远程地址（如果服务器返回了有效地址）
      // 注意：这里只更新 localAddress 和 remoteAddress，不影响 manualAddress
      if (successResult.serverInfo.localAddress) {
        computer.localAddress = successResult.serverInfo.localAddress;
      }
      if (successResult.serverInfo.externalAddress) {
        computer.remoteAddress = successResult.serverInfo.externalAddress;
      }
      
      // 更新配对状态的逻辑（与 Android 一致）：
      // 注意：HTTP 请求总是返回 paired=false（服务器无法通过 HTTP 验证客户端身份）
      // 只有 HTTPS + 客户端证书 才能返回正确的配对状态
      // 因此：如果本地有 serverCert，应该信任本地配对状态，而不是清除它
      if (successResult.serverInfo.paired) {
        computer.pairState = PairState.PAIRED;
      } else {
        // 服务器返回未配对状态
        // 重要：不要因为服务器返回 paired=false 就清除 serverCert！
        // HTTP 请求总是返回 paired=false，这不代表配对真的失效了
        // 只有在用户主动取消配对时才应该清除 serverCert
        if (computer.serverCert) {
          // 本地有 serverCert，可能是 HTTP 响应（总是返回 paired=false）
          // 保持 PAIRED 状态，让用户可以正常连接
          // 如果配对真的失效了，连接时会失败并提示用户重新配对
          console.info(`ComputerManager: ${computer.name} 服务器返回未配对（可能是 HTTP 响应），但本地有 serverCert，保持配对状态`);
          computer.pairState = PairState.PAIRED;
        } else {
          computer.pairState = PairState.NOT_PAIRED;
        }
      }
      
      console.info(`ComputerManager: ${computer.name} 在线 (通过 ${successResult.address})，当前游戏: ${successResult.serverInfo.currentGame}，配对状态: ${computer.pairState}, serverCert: ${computer.serverCert ? '有' : '无'}, MAC: ${computer.macAddress || '(空)'}, boxArtUrl: ${computer.boxArtUrl || '(空)'}`);

      // 保存更新后的电脑信息（包括 MAC 地址等）
      this.saveComputers();

      // 如果已配对且没有 boxArt（或 boxArt 是远程 URL 而非本地缓存），尝试获取第一个应用的缩略图作为主机头像
      const needsBoxArt = computer.pairState === PairState.PAIRED && 
        (!computer.boxArtUrl || computer.boxArtUrl.startsWith('http'));
      if (needsBoxArt) {
        console.info(`ComputerManager: ${computer.name} 需要加载 boxArt`);
        this.loadFirstAppBoxArt(computer, successResult.address);
      }

      return true;
    } else {
      computer.state = ComputerState.OFFLINE;
      console.info(`ComputerManager: ${computer.name} 所有地址均无法连接，标记为离线`);
      return false;
    }
  }

  /**
   * 加载第一个应用的 boxArt 作为主机头像（异步，不阻塞主流程）
   */
  private async loadFirstAppBoxArt(computer: ComputerInfo, address: string): Promise<void> {
    try {
      // 使用保存的自定义端口（如果有）
      const nvHttp = new NvHttp(address, computer.serverCert, this.context || undefined, computer.httpPort);
      const apps = await nvHttp.getAppList();
      if (apps.length > 0) {
        // 下载并缓存第一个应用的 boxArt，使用本地文件路径
        const cachedPath = await nvHttp.getAppAssetCached(apps[0].id);
        if (cachedPath) {
          computer.boxArtUrl = cachedPath;
          console.info(`ComputerManager: ${computer.name} 已设置 boxArt 本地路径: ${cachedPath}`);
          // 保存更新并通知 UI
          await this.saveComputers();
          if (this.onComputerListChanged) {
            this.onComputerListChanged();
          }
        } else {
          console.warn(`ComputerManager: ${computer.name} 无法缓存 boxArt`);
        }
      }
    } catch (err) {
      console.warn(`ComputerManager: 无法获取 ${computer.name} 的 boxArt: ${err}`);
    }
  }

  /**
   * 扫描网络发现电脑
   */
  async scanNetwork(): Promise<void> {
    if (!this.mdnsDiscovery) {
      console.error('ComputerManager: mDNS 发现服务未初始化');
      return;
    }

    console.info('ComputerManager: 开始扫描网络...');

    try {
      const discovered = await this.mdnsDiscovery.discover(5000);
      console.info(`ComputerManager: 发现 ${discovered.length} 台电脑`);

      for (const computer of discovered) {
        // handleDiscoveredComputer 会在 mDNS 回调中被调用
        // 这里只是确保超时后也处理完毕
      }
    } catch (err) {
      console.error('ComputerManager: 网络扫描失败', err);
    }
  }

  /**
   * 开始持续扫描（后台）
   */
  startBackgroundScan(): void {
    if (!this.mdnsDiscovery) {
      return;
    }

    this.mdnsDiscovery.startDiscovery().catch((err: Error) => {
      console.error('ComputerManager: 后台扫描启动失败', err);
    });
  }

  /**
   * 停止后台扫描
   */
  stopBackgroundScan(): void {
    if (this.mdnsDiscovery) {
      this.mdnsDiscovery.stopDiscovery();
    }
  }

  /**
   * 与电脑配对
   */
  async pairComputer(uuid: string): Promise<string> {
    const computer = this.computers.get(uuid);
    if (!computer) {
      throw new Error('电脑不存在');
    }

    const nvHttp = new NvHttp(computer.address, null, this.context || undefined, computer.httpPort);
    const pin = this.generatePin();
    
    computer.pairState = PairState.NOT_PAIRED;
    
    try {
      await nvHttp.pair(pin);
      computer.pairState = PairState.PAIRED;
      computer.serverCert = nvHttp.getServerCert();
      await this.saveComputers();
      return pin;
    } catch (err) {
      computer.pairState = PairState.FAILED;
      throw new Error(`配对失败: ${(err as Error).message}`);
    }
  }

  /**
   * 取消配对
   */
  async unpairComputer(uuid: string): Promise<void> {
    const computer = this.computers.get(uuid);
    if (!computer) {
      throw new Error('电脑不存在');
    }

    const nvHttp = new NvHttp(computer.address, computer.serverCert, this.context || undefined, computer.httpPort);
    await nvHttp.unpair();
    
    computer.pairState = PairState.NOT_PAIRED;
    computer.serverCert = '';
    await this.saveComputers();
  }

  /**
   * 网络唤醒 (Wake-on-LAN)
   */
  async wakeComputer(uuid: string): Promise<void> {
    const computer = this.computers.get(uuid);
    if (!computer || !computer.macAddress) {
      throw new Error('无法唤醒：缺少 MAC 地址');
    }

    // 收集所有已知地址（去重）
    const addressSet = new Set<string>();
    if (computer.address) {
      addressSet.add(computer.address);
    }
    if (computer.localAddress) {
      addressSet.add(computer.localAddress);
    }
    if (computer.remoteAddress) {
      addressSet.add(computer.remoteAddress);
    }
    if (computer.ipv6Address) {
      addressSet.add(computer.ipv6Address);
    }
    
    const addresses = Array.from(addressSet);
    
    // 使用批量发送 API
    await WakeOnLan.sendWolToAddresses(
      computer.macAddress,
      addresses,
      computer.httpPort || 47989
    );
  }

  /**
   * 生成配对 PIN 码（使用加密安全的随机数）
   */
  private generatePin(): string {
    // 使用 CryptoUtil 生成安全随机数
    const randomBytes = CryptoUtil.generateRandomBytes(4);
    let pin = '';
    for (let i = 0; i < 4; i++) {
      pin += (randomBytes[i] % 10).toString();
    }
    return pin;
  }

  /**
   * 保存电脑列表到持久化存储
   */
  async saveComputers(): Promise<void> {
    try {
      interface SavedComputerData {
        uuid: string;
        name: string;
        address: string;
        localAddress: string;
        remoteAddress: string;
        manualAddress?: string;  // 用户手动输入的地址
        macAddress: string;
        serverCert: string;
        pairState: string;
        runningGameId: number;
        boxArtUrl?: string;
        httpPort?: number;
      }
      
      const computerList: SavedComputerData[] = [];
      this.computers.forEach((computer) => {
        // 将枚举值转为字符串名称
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
          manualAddress: computer.manualAddress,  // 保存手动输入的地址
          macAddress: computer.macAddress,
          serverCert: computer.serverCert,
          pairState: pairStateStr,
          runningGameId: computer.runningGameId,
          boxArtUrl: computer.boxArtUrl || '',
          httpPort: computer.httpPort
        };
        computerList.push(savedData);
      });
      
      await PreferencesUtil.put('saved_computers', JSON.stringify(computerList));
      console.info(`ComputerManager: 保存 ${computerList.length} 台电脑, 详情: ${computerList.map(c => `${c.name}(pairState=${c.pairState}, serverCert长度=${c.serverCert?.length || 0})`).join(', ')}`);
    } catch (err) {
      console.error('ComputerManager: 保存电脑列表失败', err);
    }
  }

  /**
   * 从持久化存储加载电脑列表
   */
  private async loadComputers(): Promise<void> {
    try {
      console.info('ComputerManager: 开始加载电脑列表...');
      const savedJson = await PreferencesUtil.get<string>('saved_computers', '');
      console.info(`ComputerManager: 读取到的 JSON = ${savedJson ? savedJson.substring(0, 100) + '...' : '(空)'}`);
      
      if (!savedJson) {
        console.info('ComputerManager: 没有保存的电脑');
        return;
      }
      
      interface SavedComputer {
        uuid: string;
        name: string;
        address: string;
        localAddress: string;
        remoteAddress: string;
        manualAddress?: string;  // 用户手动输入的地址
        macAddress: string;
        serverCert: string;
        pairState: string;
        runningGameId: number;
        boxArtUrl?: string;
        httpPort?: number;
      }
      
      const computerList = JSON.parse(savedJson) as SavedComputer[];
      console.info(`ComputerManager: 解析到 ${computerList.length} 台电脑`);
      
      for (const saved of computerList) {
        // 兼容旧格式（数字字符串 "1"）和新格式（名称字符串 "PAIRED"）
        let pairState: PairState = PairState.NOT_PAIRED;
        if (saved.pairState === 'PAIRED' || saved.pairState === '1') {
          pairState = PairState.PAIRED;
        } else if (saved.pairState === 'FAILED' || saved.pairState === '3') {
          pairState = PairState.FAILED;
        } else if (saved.pairState === 'PIN_WRONG' || saved.pairState === '2') {
          pairState = PairState.PIN_WRONG;
        }
        
        // 兼容旧数据：如果 httpPort 为空但地址中包含端口，则提取端口
        let httpPort = saved.httpPort;
        let addressHost = saved.address;
        if (!httpPort && saved.address) {
          const colonIndex = saved.address.indexOf(':');
          // 只有一个冒号，说明是端口分隔符（IPv6 有多个冒号）
          if (colonIndex > 0 && saved.address.indexOf(':', colonIndex + 1) === -1) {
            const portStr = saved.address.substring(colonIndex + 1);
            const port = parseInt(portStr);
            if (port > 0 && port <= 65535 && port !== 47989) {
              httpPort = port;
              addressHost = saved.address.substring(0, colonIndex);
              console.info(`ComputerManager: 迁移旧数据 - 从地址中提取端口 ${saved.address} -> host=${addressHost}, port=${httpPort}`);
            }
          }
        }
        
        console.info(`ComputerManager: 加载 ${saved.name} pairState=${saved.pairState} -> ${pairState}, httpPort=${httpPort}, serverCert长度=${saved.serverCert?.length || 0}, boxArtUrl="${saved.boxArtUrl || '(空)'}"`);
        
        const computer = new ComputerInfoBuilder()
          .setUuid(saved.uuid)
          .setName(saved.name)
          .setAddress(addressHost)
          .setLocalAddress(saved.localAddress || addressHost)
          .setRemoteAddress(saved.remoteAddress || '')
          .setManualAddress(saved.manualAddress)  // 加载手动输入的地址
          .setMacAddress(saved.macAddress || '')
          .setServerCert(saved.serverCert || '')
          .setState(ComputerState.UNKNOWN)
          .setPairState(pairState)
          .setRunningGameId(saved.runningGameId || 0)
          .setBoxArtUrl(saved.boxArtUrl || '')
          .setHttpPort(httpPort)
          .build();
        
        this.computers.set(computer.uuid, computer);
        console.info(`ComputerManager: 加载电脑 ${computer.name} (${computer.uuid})`);
      }
      
      console.info(`ComputerManager: 加载完成，共 ${this.computers.size} 台电脑`);
      
      // 注意：状态刷新在 init() 方法中异步执行
    } catch (err) {
      console.error('ComputerManager: 加载电脑列表失败', err);
    }
  }
}
