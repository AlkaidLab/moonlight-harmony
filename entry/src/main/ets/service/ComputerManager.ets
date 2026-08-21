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
import { NvHttp, ServerInfo } from './streaming/NvHttp';
import { PairingManager, PairState as PMPairState } from './network/PairingManager';
import { MdnsDiscovery, DiscoveredComputer } from './network/MdnsDiscovery';
import { ComputerPersistence } from './ComputerPersistence';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { CryptoUtil } from '../utils/CryptoUtil';
import { WakeOnLan } from './network/WakeOnLan';
import { isLanAddress, getBestIpv6Address, isIPv4Address, isIPv6Address, isLoopbackIPv4, parseAddressAndPort } from '../utils/NetHelper';
import {
  classifyServerIdentity,
  collectKnownAddresses,
  ServerIdentityDisposition
} from './network/ComputerNetworkPolicy';
import { connection } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';

/**
 * 地址解析结果
 */

/**
 * 轮询结果
 */
interface PollResult {
  address: string;
  serverInfo: ServerInfo | null;
}

interface AddComputerInternalOptions {
  discoveredName?: string;
  httpPort?: number;
  discoveredIpv6?: string;
  robustServerInfo?: boolean;
}

/** 轮询间隔（毫秒），参照 Android ComputerManagerService */
const SERVERINFO_POLLING_PERIOD_MS = 5000;

/**
 * ServerInfo 缓存有效期（毫秒）。
 *
 * 用于在 ComputerManager 轮询 / AppListPage 刷新拿到的 ServerInfo 之上，
 * 让后续"进入串流"链路可以跳过一次 HTTPS round-trip。仅复用与连接无关的字段
 * （hostname/uniqueId/serverCodecModeSupport/currentGame 等），不会影响诊断准确性。
 */
const SERVER_INFO_CACHE_TTL_MS = 30_000;

/**
 * ServerInfo 缓存项
 */
interface CachedServerInfo {
  info: ServerInfo;
  timestamp: number;
}

/** ETS AAAA 查询缓存项。undefined 表示本次查询没有可用的全局 IPv6。 */
interface CachedAaaaResult {
  ipv6Address?: string;
  expiresAt: number;
}

/**
 * DNS 缓存仅用于绕过部分鸿蒙版本对 AAAA-only 域名的不稳定解析。
 * 正结果定期刷新以适配 DDNS，负结果短暂缓存以避免 5 秒轮询持续打 DNS。
 */
const DNS_POSITIVE_CACHE_TTL_MS = 5 * 60_000;
const DNS_NEGATIVE_CACHE_TTL_MS = 60_000;

/** 全 0 MAC：远程响应或 HTTP 未配对响应中的占位值，不能用它覆盖已发现的真实 MAC */
const ZERO_MAC = '00:00:00:00:00:00';

/**
 * 标记 OFFLINE 前允许的连续失败次数（对齐 Android ComputerManagerService）
 * - 状态为 UNKNOWN 时（首次轮询）：失败 2 次后标 OFFLINE
 * - 已经 ONLINE 的 PC：失败 3 次后才标 OFFLINE，避免短暂网络抖动 / Sunshine 重启时的误报
 */
const INITIAL_POLL_TRIES = 2;
const OFFLINE_POLL_TRIES = 3;

/** 手动添加主机时允许一次快速重试，兜住 RCP/网络偶发超时但不显著拖慢失败反馈 */
const MANUAL_ADD_SERVERINFO_ATTEMPTS = 2;
const MANUAL_ADD_RETRY_DELAY_MS = 500;

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
  /** 离线轮询计数：连续失败次数，达到 INITIAL_POLL_TRIES/OFFLINE_POLL_TRIES 阈值后才标 OFFLINE */
  private offlineCount: Map<string, number> = new Map();

  /**
   * ServerInfo 缓存（key=computer uuid）。
   * 由轮询 / 刷新链路写入；StreamingSession.fetchServerInfo 命中即复用，省一次 HTTPS。
   */
  private serverInfoCache: Map<string, CachedServerInfo> = new Map();
  /** hostname -> ETS AAAA 查询结果；网络切换时整体失效 */
  private aaaaCache: Map<string, CachedAaaaResult> = new Map();
  /** hostname -> 正在执行的查询；合并 mDNS、轮询和手动刷新产生的并发请求 */
  private aaaaLookupFlights: Map<string, Promise<string | undefined>> = new Map();
  /** 防止网络切换前启动的查询把旧网络结果写回新网络缓存 */
  private dnsCacheEpoch: number = 0;

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
    this.computers = await ComputerPersistence.loadComputers();
    
    // 注册网络变化监听（类似 Android 的 registerDefaultNetworkCallback）
    this.registerNetworkListener();
    
    this.isInitialized = true;
    console.info('ComputerManager: 初始化完成');

    // 注意：不在这里触发刷新，让调用者设置好回调后再调用 refreshAllComputers()
  }

  /**
   * 从持久化存储重新加载电脑列表到内存。
   * 备份恢复后调用，确保使用恢复的配对数据而非轮询覆盖的旧数据。
   */
  async reloadFromPersistence(): Promise<void> {
    this.computers = await ComputerPersistence.loadComputers();
    console.info(`ComputerManager: 从持久化存储重新加载 ${this.computers.size} 台电脑`);
    this.notifyListChanged();
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
        await this.addComputerInternal(discovered.address, {
          discoveredName: discovered.name,
          httpPort: discovered.port,
          discoveredIpv6: discovered.ipv6Address
        });
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
        c.manualAddress === address ||
        c.ipv6Address === address
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
    if (discovered.port && discovered.port !== NvHttp.DEFAULT_HTTP_PORT) {
      existing.httpPort = discovered.port;
    }
  }

  /**
   * 尝试通过 mDNS 地址验证电脑在线，失败则回退到全地址轮询
   */
  private async verifyOrPollComputer(computer: ComputerInfo, address: string): Promise<void> {
    try {
      const nvHttp = NvHttp.fromAddress(address, computer, this.context || undefined);
      const serverInfo = await nvHttp.getServerInfo();

      // 网络请求返回时条目可能已被用户删除；成功路径不能把它重新插入。
      if (this.computers.get(computer.uuid) !== computer) {
        return;
      }
      const target = this.resolveComputerIdentity(computer, serverInfo.uniqueId, 'mDNS 验证');
      if (!target) {
        throw new Error('mDNS 验证返回无效的主机身份');
      }

      // 走单一合并入口，保证与轮询/添加路径使用同一套守卫规则
      this.mergeServerInfo(target, serverInfo, address);

      // 如果仍缺少 IPv6 全局地址，异步补充（包含用户输入的 DDNS 域名）
      if (!target.ipv6Address) {
        this.lookupAndSetIpv6(target, serverInfo.hostname, target.manualAddress);
      }

      this.saveComputers();
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
    // 临时 UUID 上可能已累积了轮询失败计数（如 mDNS 后 verifyOrPollComputer 首次失败），
    // 需要随 UUID 一起迁移，避免独立计数孤在旧 UUID 上、新 UUID 从 0 重新起算
    const carriedCount = this.offlineCount.get(computer.uuid);
    this.offlineCount.delete(computer.uuid);

    if (existingReal) {
      // 真实 UUID 条目已存在 → 合并到已有条目，删除临时条目
      console.info(`ComputerManager: 合并临时条目 ${computer.uuid} → 已有条目 ${realUuid}`);
      this.computers.delete(computer.uuid);
      if (computer.manualAddress && !existingReal.manualAddress) {
        existingReal.manualAddress = computer.manualAddress;
      }
      // 两边计数取较大值：任一条目达到阈值就该被视为离线
      if (carriedCount !== undefined) {
        const realCount = this.offlineCount.get(realUuid) ?? 0;
        this.offlineCount.set(realUuid, Math.max(realCount, carriedCount));
      }
      return existingReal;
    }

    // 真实 UUID 不存在 → 重新映射
    console.info(`ComputerManager: 临时条目 ${computer.uuid} 获得真实 UUID ${realUuid}`);
    this.computers.delete(computer.uuid);
    computer.uuid = realUuid;
    this.computers.set(realUuid, computer);
    if (carriedCount !== undefined) {
      this.offlineCount.set(realUuid, carriedCount);
    }
    return computer;
  }

  /** 在进入合并路径前统一验证身份，并只为 discovered-* 条目执行 UUID 归一。 */
  private resolveComputerIdentity(
    computer: ComputerInfo,
    serverUniqueId: string | undefined,
    source: string
  ): ComputerInfo | null {
    const disposition = classifyServerIdentity(computer.uuid, serverUniqueId);
    if (disposition === ServerIdentityDisposition.MATCH) {
      return computer;
    }
    if (disposition === ServerIdentityDisposition.RECONCILE_DISCOVERED) {
      return this.reconcileUuid(computer, serverUniqueId!);
    }
    if (disposition === ServerIdentityDisposition.MISSING) {
      console.warn(`ComputerManager: ${source}响应缺少主机 UUID`);
    } else {
      console.warn(`ComputerManager: ${source}返回其他主机 expected=${computer.uuid}, actual=${serverUniqueId}`);
    }
    return null;
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
  // 合并入口（mergeServerInfo）
  // ═══════════════════════════════════════════════════════════

  /**
   * 把 ServerInfo 合并到一个已存在的 ComputerInfo 中。
   *
   * 这是**唯一**的服务器信息合并入口，对齐 Android `ComputerDetails.update()`：
   * - mDNS 发现已存在 PC（addComputerInternal 已有分支）
   * - mDNS 快速验证（verifyOrPollComputer）
   * - 周期性轮询（updateComputerFromPoll）
   *
   * 所有"新值什么时候才能覆盖旧值"的守卫规则都集中在这里，避免三处实现各写各的、漏掉一处就出 bug
   * （历史 bug：addComputerInternal 漏了 ZERO_MAC 守卫导致 WAN 连接抹掉真实 MAC）。
   *
   * 调用方负责：UUID 归一、saveComputers、IPv6 异步补充、boxArt 加载等副作用。
   */
  private mergeServerInfo(
    target: ComputerInfo,
    info: ServerInfo,
    address: string,
    httpPort?: number,
    discoveredIpv6?: string
  ): void {
    // 名称：仅在新值非空时覆盖
    if (info.hostname) {
      target.name = info.hostname;
    }

    // 当前活动地址：始终更新为本次成功连接的地址
    target.address = address;

    // 本地地址：过滤 127.x 回环（对齐 Android GS IPv6 Forwarder 保护）
    if (info.localAddress && !isLoopbackIPv4(info.localAddress)) {
      target.localAddress = info.localAddress;
    } else if (target.localAddress && isLoopbackIPv4(target.localAddress)) {
      // 清理历史遗留的 127.x 回环地址，回退到本次连接的地址
      target.localAddress = address;
    }

    // 远程地址：仅在服务器返回时覆盖
    if (info.externalAddress) {
      target.remoteAddress = info.externalAddress;
    }

    // IPv6 地址：连接地址本身是 IPv6，或调用方传入了 mDNS 发现的 IPv6
    if (isIPv6Address(address)) {
      target.ipv6Address = address;
    } else if (discoveredIpv6) {
      target.ipv6Address = discoveredIpv6;
    }

    // MAC 地址：拒绝零 MAC（远程/WAN/HTTP 未配对响应中常为 00:00:00:00:00:00），
    // 否则会抹掉之前局域网发现的真实 MAC，导致 WOL 失效
    if (info.macAddress && info.macAddress !== ZERO_MAC) {
      target.macAddress = info.macAddress;
    }

    // 自定义 HTTP 端口
    if (httpPort) {
      target.httpPort = httpPort;
    }

    // HTTPS 端口
    if (info.httpsPort > 0) {
      target.httpsPort = info.httpsPort;
    }

    // 当前运行的游戏 ID
    target.runningGameId = info.currentGame || 0;

    // 配对状态：HTTP 请求总是返回 paired=false，只有 HTTPS + 客户端证书才能拿到正确状态。
    // 所以本地有 serverCert 时信任本地配对状态，避免被 HTTP 响应误判为未配对。
    if (info.paired) {
      target.pairState = PairState.PAIRED;
    } else if (target.serverCert) {
      target.pairState = PairState.PAIRED;
    } else {
      target.pairState = PairState.NOT_PAIRED;
    }

    // 本函数只在成功获取 ServerInfo 后被调用（3 处调用点都走成功路径），故直接置 ONLINE；
    // 失败路径由 handlePollFailure 按阈值决定是否转 OFFLINE，不会进入此处
    target.state = ComputerState.ONLINE;
    // 在线了→必然清 offlineCount：统一集中在合并入口清，避免各调用点遗漏
    // （历史 bug：verifyOrPollComputer/addComputerInternal 成功路径曾漏清计数）
    this.offlineCount.delete(target.uuid);
  }

  // ═══════════════════════════════════════════════════════════
  // CRUD 操作
  // ═══════════════════════════════════════════════════════════

  /**
   * 获取所有电脑列表
   * 返回深拷贝的对象，确保 ArkTS @State 能检测到变化
   */
  async getComputers(): Promise<ComputerInfo[]> {
    return Array.from(this.computers.values()).map(computer => ComputerPersistence.cloneComputer(computer));
  }

  /**
   * 根据 UUID 获取电脑
   */
  getComputer(uuid: string): ComputerInfo | undefined {
    const computer = this.computers.get(uuid);
    return computer ? ComputerPersistence.cloneComputer(computer) : undefined;
  }

  /**
   * 缓存最新的 ServerInfo（轮询 / AppList 刷新成功时调用）
   * 用于让"进入串流"链路跳过一次 HTTPS /serverinfo 请求。
   */
  cacheServerInfo(uuid: string, info: ServerInfo): void {
    if (!uuid) return;
    this.serverInfoCache.set(uuid, { info, timestamp: Date.now() });
  }

  /**
   * 获取最近 ${SERVER_INFO_CACHE_TTL_MS}ms 内缓存的 ServerInfo，过期/缺失返回 null。
   */
  getCachedServerInfo(uuid: string): ServerInfo | null {
    if (!uuid) return null;
    const entry = this.serverInfoCache.get(uuid);
    if (!entry) return null;
    if (Date.now() - entry.timestamp > SERVER_INFO_CACHE_TTL_MS) {
      this.serverInfoCache.delete(uuid);
      return null;
    }
    return entry.info;
  }

  /**
   * 主动让某台电脑的 ServerInfo 缓存失效（例如配对/解配后状态可能改变时）
   */
  invalidateServerInfoCache(uuid: string): void {
    this.serverInfoCache.delete(uuid);
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
    // preferredAddress: 空字符串表示清除锁定
    if (updates.preferredAddress !== undefined) {
      computer.preferredAddress = updates.preferredAddress || undefined;
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
   *
   * 对 AAAA-only 域名的兜底：用户反馈"手输 IPv6 字面量可连接、用域名超时"
   * 推测鸿蒙 RCK / native getaddrinfo 对纯 AAAA 域名解析不稳定。
   * 添加流程：先尝试用原域名连接 → 失败时通过 ETS 层 connection.getAddressesByName
   * 解析出 IPv6 字面量再重试，确保首次添加能成功且后续会持久化 ipv6Address。
   */
  async addComputer(addressInput: string): Promise<ComputerInfo> {
    const parsed = parseAddressAndPort(addressInput);
    const isLiteralIp = isIPv4Address(parsed.host) || isIPv6Address(parsed.host);
    const manualAddOptions: AddComputerInternalOptions = {
      httpPort: parsed.port,
      robustServerInfo: true
    };

    let result: ComputerInfo;
    let resolvedIpv6: string | undefined;
    try {
      result = await this.addComputerInternal(parsed.host, manualAddOptions);
    } catch (firstErr) {
      // 域名直连失败 → 尝试在 ETS 层解析 AAAA 再用裸 IPv6 重试
      if (isLiteralIp) {
        throw firstErr as Error;
      }
      // 用户主动重试时绕过短期负缓存，但仍复用已有正缓存并写回最新查询结果。
      const ipv6 = await this.resolveAaaaLiteral(parsed.host, true);
      if (!ipv6) {
        // AAAA 解析也无果，把原错误抛出（含网络/超时信息）
        throw firstErr as Error;
      }
      console.info(`ComputerManager: 域名 ${parsed.host} 直连失败，已解析 AAAA → ${ipv6}，用裸 IPv6 重试添加`);
      result = await this.addComputerInternal(ipv6, manualAddOptions);
      resolvedIpv6 = ipv6;
    }

    // 保存用户手动输入的地址（仅主机部分，端口已存储在 httpPort 中）
    // 这个地址永不会被自动发现覆盖，轮询时最优先尝试
    result.manualAddress = parsed.host;

    // 域名场景：把解析出的 IPv6 字面量持久化，让后续轮询并行尝试时 IPv6 字面量直连可用
    if (resolvedIpv6) {
      result.ipv6Address = resolvedIpv6;
    }

    // 保存更新后的电脑信息
    this.computers.set(result.uuid, result);
    await this.saveComputers();

    this.notifyListChanged();
    return result;
  }

  /**
   * ETS 层主动解析 AAAA，返回最佳 IPv6 全局地址（无则 undefined）。
   * 用于：
   *   - addComputer 域名直连失败时的回退
   *   - lookupAndSetIpv6 持久化 IPv6 字面量到 computer.ipv6Address
   */
  private async resolveAaaaLiteral(
    host: string,
    bypassNegativeCache: boolean = false
  ): Promise<string | undefined> {
    const normalizedHost = host.trim();
    const cacheKey = normalizedHost.toLowerCase();
    if (!cacheKey) return undefined;

    const cached = this.aaaaCache.get(cacheKey);
    if (cached) {
      if (cached.expiresAt > Date.now()) {
        if (!bypassNegativeCache || cached.ipv6Address) {
          return cached.ipv6Address;
        }
      } else {
        this.aaaaCache.delete(cacheKey);
      }
    }

    const activeLookup = this.aaaaLookupFlights.get(cacheKey);
    if (activeLookup) {
      return await activeLookup;
    }

    const lookupEpoch = this.dnsCacheEpoch;
    const lookup = this.queryAndCacheAaaaLiteral(normalizedHost, cacheKey, lookupEpoch);
    this.aaaaLookupFlights.set(cacheKey, lookup);
    try {
      return await lookup;
    } finally {
      if (this.aaaaLookupFlights.get(cacheKey) === lookup) {
        this.aaaaLookupFlights.delete(cacheKey);
      }
    }
  }

  private async queryAndCacheAaaaLiteral(
    host: string,
    cacheKey: string,
    lookupEpoch: number
  ): Promise<string | undefined> {
    let ipv6Address: string | undefined;
    try {
      const addresses = await connection.getAddressesByName(host);
      const ipv6List: string[] = [];
      for (const addr of addresses) {
        if (addr.family === 2 && addr.address) {
          ipv6List.push(addr.address);
        }
      }
      ipv6Address = getBestIpv6Address(ipv6List);
    } catch (err) {
      console.info(`ComputerManager: resolveAaaaLiteral('${host}') 失败: ${err}`);
    }

    // 网络已经切换：丢弃旧网络结果，调用方也不能把它写入 ComputerInfo。
    if (lookupEpoch !== this.dnsCacheEpoch) {
      return undefined;
    }

    const ttl = ipv6Address ? DNS_POSITIVE_CACHE_TTL_MS : DNS_NEGATIVE_CACHE_TTL_MS;
    this.aaaaCache.set(cacheKey, {
      ipv6Address: ipv6Address,
      expiresAt: Date.now() + ttl
    });
    return ipv6Address;
  }

  private invalidateDnsCache(): void {
    this.dnsCacheEpoch++;
    this.aaaaCache.clear();
    this.aaaaLookupFlights.clear();
  }

  /**
   * 内部添加电脑方法
   * 如果该 UUID 的电脑已存在，合并更新而非替换，保留 serverCert 等配对信息
   */
  private async addComputerInternal(address: string, options?: AddComputerInternalOptions): Promise<ComputerInfo> {
    const discoveredName = options?.discoveredName;
    const httpPort = options?.httpPort;
    const discoveredIpv6 = options?.discoveredIpv6;
    const robustServerInfo = options?.robustServerInfo === true;
    const nvHttp = new NvHttp(address, null, this.context || undefined, httpPort);

    try {
      // 获取服务器信息
      const serverInfo = robustServerInfo
        ? await nvHttp.getServerInfoRobust({
          maxAttempts: MANUAL_ADD_SERVERINFO_ATTEMPTS,
          delayMs: MANUAL_ADD_RETRY_DELAY_MS
        })
        : await nvHttp.getServerInfo(false);
      if (!serverInfo.uniqueId) {
        throw new Error('服务器响应缺少主机 UUID');
      }

      // 检查是否已存在相同 UUID 的电脑
      const existing = this.computers.get(serverInfo.uniqueId);
      if (existing) {
        // 合并更新：保留已有的配对信息，更新地址和状态
        // 所有合并守卫（ZERO_MAC、127.x、HTTP paired 等）集中在 mergeServerInfo
        this.mergeServerInfo(existing, serverInfo, address, httpPort, discoveredIpv6);

        console.info(`ComputerManager: 合并更新已有电脑 ${existing.name} (${existing.uuid}), 保留配对信息`);
        this.computers.set(existing.uuid, existing);
        await this.saveComputers();

        // 如果仍缺少 IPv6 全局地址，异步补充（包含用户输入的 DDNS 域名）
        if (!existing.ipv6Address) {
          this.lookupAndSetIpv6(existing, serverInfo.hostname, existing.manualAddress);
        }

        return existing;
      }

      // 全新电脑，创建新条目（先建空壳，再走统一合并入口填充字段，避免守卫规则分裂）
      const isIPv6 = isIPv6Address(address);
      const ipv6Addr = isIPv6 ? address : (discoveredIpv6 || '');
      const computer = new ComputerInfoBuilder()
        .setUuid(serverInfo.uniqueId)
        .setName(discoveredName || address) // 兜底名称，mergeServerInfo 会用 hostname 覆盖
        .setAddress(address)
        .setLocalAddress(address) // 兜底，mergeServerInfo 会按守卫规则覆盖
        .setIpv6Address(ipv6Addr)
        .setState(ComputerState.UNKNOWN)
        .setPairState(PairState.NOT_PAIRED)
        .setHttpPort(httpPort)
        .build();

      this.mergeServerInfo(computer, serverInfo, address, httpPort, discoveredIpv6);

      this.computers.set(computer.uuid, computer);
      await this.saveComputers();

      // 如果仍缺少 IPv6 全局地址，异步补充（包含用户输入的 DDNS 域名）
      if (!computer.ipv6Address) {
        this.lookupAndSetIpv6(computer, serverInfo.hostname, computer.manualAddress);
      }

      console.info(`ComputerManager: 成功添加电脑 ${computer.name} (${computer.uuid}), localAddr=${computer.localAddress}, remoteAddr=${computer.remoteAddress}`);
      return computer;
    } catch (err) {
      // 如果无法获取服务器信息，仍然添加但标记为未确认
      if (discoveredName) {
        // 临时 UUID 按 discoveredName 派生：同一发现名重复发现（如 IP 变化）会复用同一条目，
        // 避免堆积多个“发现了但连不上”的残留条目，然后被后续 saveComputers 一起持久化
        const tempUuid = `discovered-${discoveredName}`;
        const reused = this.computers.get(tempUuid);
        if (reused) {
          reused.address = address;
          if (!isLoopbackIPv4(address)) {
            reused.localAddress = address;
          }
          if (httpPort) {
            reused.httpPort = httpPort;
          }
          if (discoveredIpv6) {
            reused.ipv6Address = discoveredIpv6;
          }
          console.info(`ComputerManager: 复用未确认条目 ${reused.name} (${tempUuid})`);
          return reused;
        }
        const computer = new ComputerInfoBuilder()
          .setUuid(tempUuid)
          .setName(discoveredName)
          .setAddress(address)
          .setLocalAddress(address)
          .setState(ComputerState.UNKNOWN)
          .setPairState(PairState.NOT_PAIRED)
          .setHttpPort(httpPort)
          .setIpv6Address(discoveredIpv6 || '')
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
    this.offlineCount.delete(uuid);
    await this.saveComputers();
  }

  // ═══════════════════════════════════════════════════════════
  // 轮询 & 网络监听
  // ═══════════════════════════════════════════════════════════

  /**
   * 刷新所有电脑状态
   * 并行轮询，每台完成后立即通知 UI
   *
   * 对齐 Android ComputerManagerService.createPollingJob：
   * 每个轮询周期都对所有 PC 执行 pollComputer，不跳过；
   * `pollComputer` 内部根据 offlineCount 决定是否真的把状态标 OFFLINE，
   * 这样网络抖动 / Sunshine 重启时 PC 不会立刻闪到"离线"。
   */
  async refreshAllComputers(): Promise<void> {
    try {
      await Promise.all(
        Array.from(this.computers.values()).map(async (computer) => {
          try {
            await this.pollComputer(computer);
          } catch (err) {
            // pollComputer 内部已处理网络错误；意外异常仍按一次失败计数
            console.warn(`ComputerManager: ${computer.name} 轮询异常:`, err);
            this.handlePollFailure(computer);
          }
          this.notifyListChanged();
        })
      );
    } catch (err) {
      console.error('ComputerManager: refreshAllComputers 异常:', err);
      // 如果 Promise.all 外层走了 catch（实际几乎不会跳到这里，内层已兑了一层），
      // 走 handlePollFailure 走阈值，避免绕过 INITIAL_POLL_TRIES 让所有 UNKNOWN 闪 OFFLINE
      this.computers.forEach(computer => {
        if (computer.state === ComputerState.UNKNOWN) {
          this.handlePollFailure(computer);
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

    // 重置离线计数：重新进入页面（如串流退出后）重新累计，
    // 避免历史计数让已恢复的 PC 仍被当作临近阈值、下一次失败立刻闪到离线
    this.offlineCount.clear();

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
        this.invalidateDnsCache();
        this.computers.forEach(c => { c.state = ComputerState.UNKNOWN; });
        this.offlineCount.clear(); // 网络恢复，清空失败计数

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
        this.invalidateDnsCache();
        this.computers.forEach(c => { c.state = ComputerState.OFFLINE; });
        // 已强制 OFFLINE，计数不再被读取；同时避免网络恢复后“旧数”干扰阈值判定
        this.offlineCount.clear();
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
   *
   * 失败时不会立刻把状态标 OFFLINE：根据 offlineCount 累计达到阈值
   * （UNKNOWN→INITIAL_POLL_TRIES，其他→OFFLINE_POLL_TRIES）后才转 OFFLINE，
   * 期间保留原状态，避免短暂网络抖动 / Sunshine 重启时的误报闪烁。
   */
  async pollComputer(computer: ComputerInfo): Promise<boolean> {
    const addresses = collectKnownAddresses(computer);
    if (addresses.length === 0) {
      // 没有任何地址可试，直接认定离线；强制 OFFLINE 后计数不再被读取，清除即可
      computer.state = ComputerState.OFFLINE;
      this.offlineCount.delete(computer.uuid);
      return false;
    }

    console.info(`ComputerManager: 轮询 ${computer.name}，地址: ${addresses.join(', ')}`);

    // 并行尝试所有地址，取第一个成功的结果
    const successResult = await this.raceForFirstSuccess(
      addresses.map(addr => this.tryPollAddress(addr, computer))
    );

    if (successResult?.serverInfo) {
      this.updateComputerFromPoll(computer, successResult);
      // offlineCount 由 mergeServerInfo 统一清除，这里不重复
      return true;
    }

    this.handlePollFailure(computer);
    return false;
  }

  /**
   * 处理一次轮询失败：累计失败次数，达到阈值后才标 OFFLINE
   */
  private handlePollFailure(computer: ComputerInfo): void {
    // 避免在轮询 in-flight 期间 PC 被 removeComputer 删掉后，这里又把计数写回 offlineCount
    // （孤儿条目会一直留到下次 startPolling 才被清理）
    if (!this.computers.has(computer.uuid)) {
      this.offlineCount.delete(computer.uuid);
      return;
    }
    const next = (this.offlineCount.get(computer.uuid) ?? 0) + 1;
    this.offlineCount.set(computer.uuid, next);

    const threshold = computer.state === ComputerState.UNKNOWN
      ? INITIAL_POLL_TRIES
      : OFFLINE_POLL_TRIES;

    if (next >= threshold) {
      computer.state = ComputerState.OFFLINE;
      console.info(`ComputerManager: ${computer.name} 连续失败 ${next} 次，标记 OFFLINE`);
    } else {
      console.info(`ComputerManager: ${computer.name} 失败 ${next}/${threshold} 次，保留原状态 ${computer.state}`);
    }
  }

  /**
   * 尝试通过单个地址轮询
   */
  private async tryPollAddress(address: string, computer: ComputerInfo): Promise<PollResult> {
    try {
      const nvHttp = NvHttp.fromAddress(address, computer, this.context || undefined);
      const likelyOnline = computer.state === ComputerState.ONLINE && address === computer.address;
      const serverInfo = await nvHttp.getServerInfo(likelyOnline);
      const identity = classifyServerIdentity(computer.uuid, serverInfo.uniqueId);
      if (identity === ServerIdentityDisposition.MISSING) {
        console.warn(`ComputerManager: 轮询 ${address} 的响应缺少主机 UUID`);
        return { address, serverInfo: null };
      }
      if (identity === ServerIdentityDisposition.MISMATCH) {
        console.warn(`ComputerManager: 轮询 ${address} 返回其他主机 expected=${computer.uuid}, actual=${serverInfo.uniqueId}`);
        return { address, serverInfo: null };
      }
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

    // 丢弃删除/替换条目后才完成的陈旧请求，避免 reconcileUuid 将其复活。
    if (this.computers.get(computer.uuid) !== computer) {
      return;
    }
    const target = this.resolveComputerIdentity(computer, info.uniqueId, `轮询 ${result.address}`);
    if (!target) {
      return;
    }

    // 合并服务器信息（所有字段守卫规则集中在 mergeServerInfo）
    this.mergeServerInfo(target, info, result.address);

    // 缓存最新 ServerInfo，让"进入串流"链路省一次 HTTPS round-trip
    this.cacheServerInfo(target.uuid, info);

    // 异步刷新 DNS 派生的 IPv6 地址（缓存命中不触发真实 DNS，不阻塞轮询流程）
    // 轮询链路即使已有 IPv6 也会进入这里，由 TTL 控制真实 DNS 频率，
    // 以便 DDNS 的 AAAA 变化后能够更新持久化的 IPv6；添加/mDNS 路径只负责首次补充。
    // 候选源（按外网可达性排序）：
    //   - manualAddress：用户输入的 DDNS / 公网域名，外网最可能解析到 AAAA
    //   - info.hostname：服务器自报主机名，通常仅 LAN 可解析
    //   - hostname.local：mDNS fallback
    // 不限制 isIPv6Address(manualAddress)，DDNS 域名 ≠ IPv6 字面量但解析后是 IPv6
    this.lookupAndSetIpv6(target, info.hostname, target.manualAddress);

    console.info(`ComputerManager: ${target.name} 在线 (${result.address}), game=${info.currentGame}, paired=${target.pairState}`);
    this.saveComputers();

    // 如果已配对且需要 boxArt，异步加载
    if (target.pairState === PairState.PAIRED &&
        (!target.boxArtUrl || target.boxArtUrl.startsWith('http'))) {
      this.loadFirstAppBoxArt(target, result.address);
    }
  }

  /**
   * 异步查询主机的 IPv6 全局地址并更新到 ComputerInfo
   *
   * 通过 DNS 解析多个候选主机名获取 AAAA 记录，选出最佳 IPv6 全局地址。
   *
   * 候选源（按外网可达性排序）：
   *   1. manualAddress：用户输入的 DDNS / 公网域名（外网最优）
   *   2. hostname：服务器自报（通常仅 LAN 可解析）
   *   3. hostname.local：mDNS fallback
   *
   * 必要性：用户反馈"手输 IPv6 字面量可连接、用 AAAA-only 域名超时"。
   * 推断 RCK / native getaddrinfo 对 AAAA-only 域名解析行为有问题。
   * 通过 ETS 层 `connection.getAddressesByName` 主动解析出裸 IPv6 字面量后，
   * 写入 `computer.ipv6Address`，后续轮询会把它并入候选地址并行 race；
   * IPv6 字面量绕过底层 DNS 直连，胜出后即成为 `computer.address`。
   */
  private lookupAndSetIpv6(computer: ComputerInfo, hostname: string | undefined, manualAddress?: string): void {
    // 不解析已经是 IPv6 字面量的 manualAddress；纯 IPv4 字面量也跳过
    const lookupSources: string[] = [];
    if (manualAddress && !isIPv6Address(manualAddress) && !isIPv4Address(manualAddress)) {
      lookupSources.push(manualAddress);
    }
    // Sunshine 自报 hostname/.local 通常只在 LAN 有意义，禁止从公网轮询链路泄漏查询。
    // 手动输入的 DDNS 始终保留，因为它代表用户明确配置的公网身份。
    // 只看本次成功连接的地址；localAddress 在公网连接时仍可能是 Sunshine 自报的内网地址。
    const activeAddress = computer.address;
    const normalizedHostname = hostname?.trim().replace(/\.$/, '');
    if (normalizedHostname && isLanAddress(activeAddress)) {
      lookupSources.push(normalizedHostname);
      if (!normalizedHostname.toLowerCase().endsWith('.local')) {
        lookupSources.push(`${normalizedHostname}.local`);
      }
    }
    if (lookupSources.length === 0) return;

    const uniqueLookupSources = Array.from(new Set<string>(lookupSources));

    // 顺序尝试，第一个拿到 IPv6 全局地址即停止
    const lookupChain = async (): Promise<void> => {
      for (const host of uniqueLookupSources) {
        const ipv6 = await this.resolveAaaaLiteral(host);
        if (ipv6) {
          if (computer.ipv6Address !== ipv6) {
            computer.ipv6Address = ipv6;
            console.info(`ComputerManager: 为 ${computer.name} 更新 IPv6 地址: ${ipv6} (源: ${host})`);
            this.saveComputers();
            this.notifyListChanged();
          }
          return;
        }
      }
    };

    lookupChain().catch(() => {
      // 静默忽略
    });
  }

  /**
   * 加载第一个应用的 boxArt 作为主机头像（异步，不阻塞主流程）
   */
  private async loadFirstAppBoxArt(computer: ComputerInfo, address: string): Promise<void> {
    try {
      // 使用保存的自定义端口（如果有）
      const nvHttp = NvHttp.fromAddress(address, computer, this.context || undefined);
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
   * 与电脑配对（使用完整的 PairingManager，匹配 Android 配对流程）
   */
  async pairComputer(uuid: string): Promise<string> {
    const computer = this.computers.get(uuid);
    if (!computer) {
      throw new Error('电脑不存在');
    }

    const pin = this.generatePin();
    computer.pairState = PairState.NOT_PAIRED;

    try {
      const pairingManager = new PairingManager(
        selectBestAddress(computer), computer.uuid, this.context || undefined, computer.httpPort
      );
      const result = await pairingManager.pair(pin);

      if (result.state === PMPairState.PAIRED) {
        computer.pairState = PairState.PAIRED;
        if (result.serverCert) {
          const buf = buffer.from(result.serverCert);
          computer.serverCert = buf.toString('base64');
        }
        computer.pairName = result.pairName || '';
        await this.saveComputers();
        return pin;
      } else if (result.state === PMPairState.PIN_WRONG) {
        computer.pairState = PairState.FAILED;
        throw new Error('PIN 码错误');
      } else if (result.state === PMPairState.ALREADY_IN_PROGRESS) {
        computer.pairState = PairState.FAILED;
        throw new Error('另一个设备正在配对中');
      } else {
        computer.pairState = PairState.FAILED;
        throw new Error(`配对失败: ${result.state}`);
      }
    } catch (err) {
      if (computer.pairState !== PairState.FAILED) {
        computer.pairState = PairState.FAILED;
      }
      if (err instanceof Error) {
        throw err;
      }
      throw new Error(`配对失败: ${err}`);
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

    const nvHttp = NvHttp.fromComputer(computer, this.context || undefined);
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
      collectKnownAddresses(computer),
      computer.httpPort || NvHttp.DEFAULT_HTTP_PORT
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
  // 持久化（委托给 ComputerPersistence）
  // ═══════════════════════════════════════════════════════════

  /**
   * 保存电脑列表到持久化存储
   */
  async saveComputers(): Promise<void> {
    await ComputerPersistence.saveComputers(this.computers);
  }
}
