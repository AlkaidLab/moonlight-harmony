/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { ComputerInfo, ComputerState, PairState, ComputerInfoBuilder, selectBestAddress } from '../model/ComputerInfo';
import { NvHttp, ServerInfo } from './NvHttp';
import { MdnsDiscovery, DiscoveredComputer } from './MdnsDiscovery';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { CryptoUtil } from '../utils/CryptoUtil';
import { WakeOnLan } from './WakeOnLan';
import { isLanAddress } from '../utils/NetHelper';
import { connection } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';

/**
 * 地址解析结果
 */
class AddressParseResult {
  host: string = '';
  port: number | undefined = undefined;
}

/**
 * 地址端口提取结果
 */
interface ExtractedHostPort {
  host: string;
  port: number;
}

/**
 * 轮询结果
 */
interface PollResult {
  address: string;
  serverInfo: ServerInfo | null;
}

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

/** 轮询间隔（毫秒），参照 Android ComputerManagerService */
const SERVERINFO_POLLING_PERIOD_MS = 5000;

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
  private netConnection: connection.NetConnection | null = null;

  // ═══════════════════════════════════════════════════════════
  // 初始化 & 单例
  // ═══════════════════════════════════════════════════════════

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
    
    // 注册网络变化监听（类似 Android 的 registerDefaultNetworkCallback）
    this.registerNetworkListener();
    
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

  // ═══════════════════════════════════════════════════════════
  // mDNS 发现
  // ═══════════════════════════════════════════════════════════

  /**
   * 处理 mDNS 发现的电脑
   */
  private async handleDiscoveredComputer(discovered: DiscoveredComputer): Promise<void> {
    console.info(`ComputerManager: mDNS 发现 ${discovered.name} @ ${discovered.address}:${discovered.port}`);

    const existing = this.findComputerByAddress(discovered.address);

    if (existing) {
      this.mergeDiscoveredInfo(existing, discovered);
      await this.verifyOrPollComputer(existing, discovered.address);
    } else {
      try {
        await this.addComputerInternal(discovered.address, discovered.name, discovered.port);
      } catch (err) {
        console.error(`ComputerManager: 无法添加电脑 ${discovered.name}: ${err}`);
      }
    }

    this.notifyListChanged();
  }

  /**
   * 按地址查找已存在的电脑（匹配所有地址字段）
   */
  private findComputerByAddress(address: string): ComputerInfo | undefined {
    return Array.from(this.computers.values())
      .find(c =>
        c.address === address ||
        c.localAddress === address ||
        c.remoteAddress === address ||
        c.manualAddress === address
      );
  }

  /**
   * 将 mDNS 发现的信息合并到已有电脑
   */
  private mergeDiscoveredInfo(existing: ComputerInfo, discovered: DiscoveredComputer): void {
    if (existing.localAddress !== discovered.address) {
      existing.localAddress = discovered.address;
    }
    if (discovered.ipv6Address && existing.ipv6Address !== discovered.ipv6Address) {
      existing.ipv6Address = discovered.ipv6Address;
    }
    if (discovered.port && discovered.port !== 47989) {
      existing.httpPort = discovered.port;
    }
  }

  /**
   * 尝试通过 mDNS 地址验证电脑在线，失败则回退到全地址轮询
   */
  private async verifyOrPollComputer(computer: ComputerInfo, address: string): Promise<void> {
    try {
      const nvHttp = new NvHttp(address, computer.serverCert, this.context || undefined, computer.httpPort);
      const serverInfo = await nvHttp.getServerInfo();

      // 处理 UUID 归一：discovered-* 临时条目获得真实 UUID
      if (serverInfo.uniqueId && computer.uuid !== serverInfo.uniqueId) {
        this.reconcileUuid(computer, serverInfo.uniqueId);
      }

      computer.state = ComputerState.ONLINE;
      if (!computer.address) computer.address = address;
      computer.runningGameId = serverInfo.currentGame;
      if (serverInfo.hostname) computer.name = serverInfo.hostname;
    } catch (err) {
      console.warn(`ComputerManager: mDNS 地址无法连接 ${computer.name}，回退轮询`);
      await this.pollComputer(computer);
    }
  }

  /**
   * UUID 归一：当轮询/验证返回的真实 UUID 与条目的临时 UUID 不同时
   * 合并到已有真实条目，或重新映射 UUID
   * @returns 应继续更新的目标条目（可能是合并后的已有条目）
   */
  private reconcileUuid(computer: ComputerInfo, realUuid: string): ComputerInfo {
    const existingReal = this.computers.get(realUuid);

    if (existingReal) {
      // 真实 UUID 条目已存在 → 合并到已有条目，删除临时条目
      console.info(`ComputerManager: 合并临时条目 ${computer.uuid} → 已有条目 ${realUuid}`);
      this.computers.delete(computer.uuid);
      if (computer.manualAddress && !existingReal.manualAddress) {
        existingReal.manualAddress = computer.manualAddress;
      }
      return existingReal;
    }

    // 真实 UUID 不存在 → 重新映射
    console.info(`ComputerManager: 临时条目 ${computer.uuid} 获得真实 UUID ${realUuid}`);
    this.computers.delete(computer.uuid);
    computer.uuid = realUuid;
    this.computers.set(realUuid, computer);
    return computer;
  }

  /**
   * 通知电脑列表变化
   */
  private notifyListChanged(): void {
    if (this.onComputerListChanged) {
      this.onComputerListChanged();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // CRUD 操作
  // ═══════════════════════════════════════════════════════════

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
    
    // 保存用户手动输入的地址（仅主机部分，端口已存储在 httpPort 中）
    // 这个地址永不会被自动发现覆盖，轮询时最优先尝试
    result.manualAddress = parsed.host;
    
    // 保存更新后的电脑信息
    this.computers.set(result.uuid, result);
    await this.saveComputers();
    
    this.notifyListChanged();
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
        // 裸 IPv6 地址（无方括号），如 ::1 或 fe80::1
        // 注意：裸 IPv6 地址无法无歧义地分离端口（地址本身就包含冒号）
        // 只有 [addr]:port 格式才能指定 IPv6 + 端口
        // 因此直接将整个字符串作为主机名
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
   * 如果该 UUID 的电脑已存在，合并更新而非替换，保留 serverCert 等配对信息
   */
  private async addComputerInternal(address: string, discoveredName?: string, httpPort?: number): Promise<ComputerInfo> {
    const nvHttp = new NvHttp(address, null, this.context || undefined, httpPort);

    try {
      // 获取服务器信息
      const serverInfo = await nvHttp.getServerInfo();

      // 使用服务器返回的本地地址，如果没有则使用连接地址
      const localAddr = serverInfo.localAddress || address;
      const remoteAddr = serverInfo.externalAddress || '';
      
      // 检测连接地址是否为 IPv6（包含至少2个冒号）
      const isIPv6 = address.includes(':') && address.split(':').length > 2;

      // 检查是否已存在相同 UUID 的电脑
      const existing = this.computers.get(serverInfo.uniqueId);
      if (existing) {
        // 合并更新：保留已有的配对信息，更新地址和状态
        existing.name = serverInfo.hostname || existing.name;
        existing.address = address;
        existing.localAddress = localAddr;
        if (remoteAddr) {
          existing.remoteAddress = remoteAddr;
        }
        if (isIPv6) {
          existing.ipv6Address = address;
        }
        if (serverInfo.macAddress) {
          existing.macAddress = serverInfo.macAddress;
        }
        existing.state = ComputerState.ONLINE;
        existing.runningGameId = serverInfo.currentGame || 0;
        if (httpPort) {
          existing.httpPort = httpPort;
        }
        // 关键：保留 serverCert 和 pairState（如已配对）
        // 只有服务器明确返回 paired=true 时才更新配对状态
        if (serverInfo.paired) {
          existing.pairState = PairState.PAIRED;
        }
        // 如果 existing.serverCert 已有值，不覆盖
        // serverCert 只能通过配对流程获取

        console.info(`ComputerManager: 合并更新已有电脑 ${existing.name} (${existing.uuid}), 保留配对信息`);
        this.computers.set(existing.uuid, existing);
        await this.saveComputers();
        return existing;
      }

      // 全新电脑，创建新条目
      const computer = new ComputerInfoBuilder()
        .setUuid(serverInfo.uniqueId)
        .setName(serverInfo.hostname || discoveredName || address)
        .setAddress(address) // 保持原始连接地址
        .setLocalAddress(localAddr) // 服务器返回的本地地址
        .setRemoteAddress(remoteAddr) // 服务器返回的外部地址
        .setIpv6Address(isIPv6 ? address : undefined) // 如果连接地址是 IPv6，存储之
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

  // ═══════════════════════════════════════════════════════════
  // 轮询 & 网络监听
  // ═══════════════════════════════════════════════════════════

  /**
   * 刷新所有电脑状态
   * 并行轮询，每台完成后立即通知 UI
   */
  async refreshAllComputers(): Promise<void> {
    try {
      await Promise.all(
        Array.from(this.computers.values()).map(async (computer) => {
          try {
            await this.pollComputer(computer);
          } catch {
            computer.state = ComputerState.OFFLINE;
          }
          this.notifyListChanged();
        })
      );
    } catch (err) {
      console.error('ComputerManager: refreshAllComputers 异常:', err);
      this.computers.forEach(computer => {
        if (computer.state === ComputerState.UNKNOWN) {
          computer.state = ComputerState.OFFLINE;
        }
      });
      this.notifyListChanged();
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
   * 注册网络变化监听（类似 Android 的 registerDefaultNetworkCallback）
   * 当网络切换（WiFi ↔ 蜂窝、切换 WiFi 等）时自动触发重新轮询
   */
  private registerNetworkListener(): void {
    try {
      // 创建默认网络连接监听（不指定 netSpecifier 表示监控默认网络）
      this.netConnection = connection.createNetConnection();

      // 网络可用（WiFi 连接、蜂窝恢复等）→ 重置所有 PC 状态并立即重新轮询
      this.netConnection.on('netAvailable', () => {
        console.info('ComputerManager: 网络变为可用，重置并重新轮询');
        this.computers.forEach(c => { c.state = ComputerState.UNKNOWN; });

        if (this.isPollingActive) {
          this.refreshAllComputers().catch((err: Error) => {
            console.warn('ComputerManager: 网络恢复后刷新失败', err);
          });
        }
        this.notifyListChanged();
      });

      // 网络丢失 → 标记所有 PC 为离线
      this.netConnection.on('netLost', () => {
        console.info('ComputerManager: 网络丢失，标记所有 PC 为离线');
        this.computers.forEach(c => { c.state = ComputerState.OFFLINE; });
        this.notifyListChanged();
      });

      // 注册监听（开始接收回调）
      this.netConnection.register((err) => {
        if (err) {
          console.error(`ComputerManager: 注册网络监听失败: ${JSON.stringify(err)}`);
        } else {
          console.info('ComputerManager: 网络变化监听已注册');
        }
      });
    } catch (err) {
      console.error('ComputerManager: 注册网络监听异常', err);
    }
  }

  /**
   * 取消注册网络变化监听
   */
  private unregisterNetworkListener(): void {
    if (this.netConnection) {
      try {
        this.netConnection.unregister((err) => {
          if (err) {
            console.error(`ComputerManager: 取消网络监听失败: ${JSON.stringify(err)}`);
          } else {
            console.info('ComputerManager: 网络变化监听已取消');
          }
        });
      } catch (err) {
        console.error('ComputerManager: 取消网络监听异常', err);
      }
      this.netConnection = null;
    }
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
   * 任一地址成功即标记在线，无需等待所有地址超时
   */
  async pollComputer(computer: ComputerInfo): Promise<boolean> {
    const addresses = this.collectAddresses(computer);
    if (addresses.length === 0) {
      computer.state = ComputerState.OFFLINE;
      return false;
    }

    console.info(`ComputerManager: 轮询 ${computer.name}，地址: ${addresses.join(', ')}`);

    // 并行尝试所有地址，取第一个成功的结果
    const successResult = await this.raceForFirstSuccess(
      addresses.map(addr => this.tryPollAddress(addr, computer))
    );

    if (successResult?.serverInfo) {
      this.updateComputerFromPoll(computer, successResult);
      return true;
    }

    computer.state = ComputerState.OFFLINE;
    console.info(`ComputerManager: ${computer.name} 所有地址均无法连接`);
    return false;
  }

  /**
   * 收集电脑的所有可用地址（去重，按优先级排序）
   */
  private collectAddresses(computer: ComputerInfo): string[] {
    const addressSet = new Set<string>();
    if (computer.manualAddress) addressSet.add(computer.manualAddress);
    if (computer.address) addressSet.add(computer.address);
    if (computer.localAddress) addressSet.add(computer.localAddress);
    if (computer.remoteAddress) addressSet.add(computer.remoteAddress);
    if (computer.ipv6Address) addressSet.add(computer.ipv6Address);
    return Array.from(addressSet);
  }

  /**
   * 尝试通过单个地址轮询
   */
  private async tryPollAddress(address: string, computer: ComputerInfo): Promise<PollResult> {
    try {
      const nvHttp = new NvHttp(address, computer.serverCert, this.context || undefined, computer.httpPort);
      const serverInfo = await nvHttp.getServerInfo();
      return { address, serverInfo };
    } catch (err) {
      return { address, serverInfo: null };
    }
  }

  /**
   * 从多个 Promise 中返回最佳成功结果，优先选择 LAN 地址
   *
   * 策略（对齐 Android parallelPollPc 的 availableAddresses + COLLECTION_TIMEOUT_MS）：
   *   - 第一个成功结果如果是 LAN 地址 → 立即返回（最优）
   *   - 第一个成功结果是非 LAN（域名/公网IP）→ 继续等待最多 LAN_WAIT_MS，
   *     期间如果有 LAN 地址也成功 → 返回 LAN 地址
   *   - 等待超时或所有 Promise 完成 → 返回第一个成功结果
   *   - 全部失败 → 返回 null
   */
  private raceForFirstSuccess(promises: Promise<PollResult>[]): Promise<PollResult | null> {
    const LAN_WAIT_MS = 300;

    return new Promise<PollResult | null>((resolve) => {
      let completedCount = 0;
      let hasResolved = false;
      let firstSuccessResult: PollResult | null = null;
      let lanWaitTimerId: number = -1;

      const tryResolve = (result: PollResult) => {
        if (hasResolved) return;
        hasResolved = true;
        if (lanWaitTimerId !== -1) {
          clearTimeout(lanWaitTimerId);
          lanWaitTimerId = -1;
        }
        resolve(result);
      };

      const checkAllDone = () => {
        if (completedCount === promises.length && !hasResolved) {
          hasResolved = true;
          if (lanWaitTimerId !== -1) {
            clearTimeout(lanWaitTimerId);
            lanWaitTimerId = -1;
          }
          resolve(firstSuccessResult); // 可能为 null（全部失败）
        }
      };

      for (const p of promises) {
        p.then((result: PollResult) => {
          if (result.serverInfo !== null && !hasResolved) {
            if (isLanAddress(result.address)) {
              // LAN 地址成功 → 最优，立即返回
              tryResolve(result);
              return;
            }
            if (!firstSuccessResult) {
              // 第一个非 LAN 成功 → 暂存，等待 LAN 地址
              firstSuccessResult = result;
              lanWaitTimerId = setTimeout(() => {
                // 等待超时，使用第一个非 LAN 结果
                if (!hasResolved && firstSuccessResult) {
                  tryResolve(firstSuccessResult);
                }
              }, LAN_WAIT_MS);
            }
          }
          completedCount++;
          checkAllDone();
        }).catch(() => {
          completedCount++;
          checkAllDone();
        });
      }
    });
  }

  /**
   * 根据轮询结果更新电脑信息
   * 如果电脑的 UUID 是临时的 discovered-*，用服务器返回的真实 UUID 重新映射
   */
  private updateComputerFromPoll(computer: ComputerInfo, result: PollResult): void {
    const info = result.serverInfo!;

    // 处理 UUID 归一：discovered-* 临时条目获得真实 UUID
    let target = computer;
    if (info.uniqueId && computer.uuid !== info.uniqueId) {
      target = this.reconcileUuid(computer, info.uniqueId);
    }

    // 更新名称
    if (info.hostname) {
      target.name = info.hostname;
    }

    target.state = ComputerState.ONLINE;
    target.address = result.address;
    target.runningGameId = info.currentGame;
    
    // 更新 MAC 地址
    if (info.macAddress && info.macAddress !== '00:00:00:00:00:00') {
      target.macAddress = info.macAddress;
    }
    
    // 更新本地/远程地址
    if (info.localAddress) target.localAddress = info.localAddress;
    if (info.externalAddress) target.remoteAddress = info.externalAddress;
    
    // 更新配对状态：
    // HTTP 请求总是返回 paired=false，只有 HTTPS + 客户端证书 才返回正确状态
    // 如果本地有 serverCert，信任本地配对状态
    if (info.paired) {
      target.pairState = PairState.PAIRED;
    } else if (target.serverCert) {
      // 可能是 HTTP 响应，保持已配对状态
      target.pairState = PairState.PAIRED;
    } else {
      target.pairState = PairState.NOT_PAIRED;
    }
    
    console.info(`ComputerManager: ${target.name} 在线 (${result.address}), game=${info.currentGame}, paired=${target.pairState}`);
    this.saveComputers();

    // 如果已配对且需要 boxArt，异步加载
    if (target.pairState === PairState.PAIRED && 
        (!target.boxArtUrl || target.boxArtUrl.startsWith('http'))) {
      this.loadFirstAppBoxArt(target, result.address);
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
          this.notifyListChanged();
        } else {
          console.warn(`ComputerManager: ${computer.name} 无法缓存 boxArt`);
        }
      }
    } catch (err) {
      console.warn(`ComputerManager: 无法获取 ${computer.name} 的 boxArt: ${err}`);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 扫描 & 配对
  // ═══════════════════════════════════════════════════════════

  /**
   * 扫描网络发现电脑（mDNS 回调会自动处理发现的主机）
   */
  async scanNetwork(): Promise<void> {
    if (!this.mdnsDiscovery) {
      console.error('ComputerManager: mDNS 发现服务未初始化');
      return;
    }

    try {
      const discovered = await this.mdnsDiscovery.discover(5000);
      console.info(`ComputerManager: mDNS 扫描完成，发现 ${discovered.length} 台电脑`);
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

    const nvHttp = new NvHttp(selectBestAddress(computer), null, this.context || undefined, computer.httpPort);
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

    const nvHttp = new NvHttp(selectBestAddress(computer), computer.serverCert, this.context || undefined, computer.httpPort);
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

    await WakeOnLan.sendWolToAddresses(
      computer.macAddress,
      this.collectAddresses(computer),
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

  // ═══════════════════════════════════════════════════════════
  // 持久化
  // ═══════════════════════════════════════════════════════════

  /**
   * 保存电脑列表到持久化存储
   */
  async saveComputers(): Promise<void> {
    try {
      const computerList: SavedComputerData[] = [];
      this.computers.forEach((computer) => {
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
      
      await PreferencesUtil.put('saved_computers', JSON.stringify(computerList));
      console.info(`ComputerManager: 保存 ${computerList.length} 台电脑`);
    } catch (err) {
      console.error('ComputerManager: 保存电脑列表失败', err);
    }
  }

  /**
   * 从持久化存储加载电脑列表
   */
  private async loadComputers(): Promise<void> {
    try {
      const savedJson = await PreferencesUtil.get<string>('saved_computers', '');
      if (!savedJson) {
        console.info('ComputerManager: 没有保存的电脑');
        return;
      }
      
      const computerList = JSON.parse(savedJson) as SavedComputerData[];
      console.info(`ComputerManager: 解析到 ${computerList.length} 台电脑`);
      
      for (const saved of computerList) {
        // 解析配对状态（兼容旧格式数字字符串 "1" 和新格式 "PAIRED"）
        const pairState = this.parsePairState(saved.pairState);
        
        // 兼容旧数据：从地址中提取端口
        let httpPort = saved.httpPort;
        let addressHost = saved.address;
        if (!httpPort && saved.address) {
          const extracted = this.extractPortFromAddress(saved.address);
          if (extracted) {
            httpPort = extracted.port;
            addressHost = extracted.host;
          }
        }
        
        console.info(`ComputerManager: 加载 ${saved.name} (pairState=${pairState}, httpPort=${httpPort}, cert=${saved.serverCert ? '有' : '无'})`);
        
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
        
        this.computers.set(computer.uuid, computer);
      }
      
      console.info(`ComputerManager: 加载完成，共 ${this.computers.size} 台电脑`);
    } catch (err) {
      console.error('ComputerManager: 加载电脑列表失败', err);
    }
  }

  /**
   * 解析配对状态字符串
   */
  private parsePairState(stateStr: string): PairState {
    if (stateStr === 'PAIRED' || stateStr === '1') return PairState.PAIRED;
    if (stateStr === 'FAILED' || stateStr === '3') return PairState.FAILED;
    if (stateStr === 'PIN_WRONG' || stateStr === '2') return PairState.PIN_WRONG;
    return PairState.NOT_PAIRED;
  }

  /**
   * 从旧格式地址中提取端口（兼容迁移）
   */
  private extractPortFromAddress(address: string): ExtractedHostPort | null {
    const colonIndex = address.indexOf(':');
    if (colonIndex > 0 && address.indexOf(':', colonIndex + 1) === -1) {
      const portStr = address.substring(colonIndex + 1);
      const port = parseInt(portStr);
      if (port > 0 && port <= 65535 && port !== 47989) {
        const result: ExtractedHostPort = { host: address.substring(0, colonIndex), port: port };
        return result;
      }
    }
    return null;
  }
}
