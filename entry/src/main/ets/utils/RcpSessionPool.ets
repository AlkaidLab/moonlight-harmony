/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { rcp } from '@kit.RemoteCommunicationKit';
import { Logger } from '../common/Logger';

/**
 * Session 池条目
 */
interface SessionPoolEntry {
  /** 所属缓存键（origin + cert），淘汰日志与 invalidate 定位用 */
  cacheKey: string;
  session: rcp.Session;
  lastUsedAt: number;
  /** 在途请求数：acquire +1，release -1 */
  inFlight: number;
  /** 已被淘汰：不再复用，等 inFlight 归零后关闭 */
  retired: boolean;
}

/**
 * Session 池获取参数
 */
export interface SessionAcquireOptions {
  /** 是否跳过服务器证书验证（私有 PC/Sunshine 自签证书需开启） */
  skipServerValidation: boolean;
  /** 客户端 PEM 证书路径（已配对的 PC 必填） */
  clientCertPath?: string;
  /** 客户端 PEM 私钥路径 */
  clientKeyPath?: string;
}

/**
 * rcp.Session 池
 *
 * 为什么需要这一层：
 * 官方 RCK 的连接池（ConnectionConfiguration.maxConnectionsPerHost 默认 6）
 * 是 per-Session 的，文档明文规定「Session 中的资源互相独立、互不影响」。
 * 如果应用每次请求都 createSession + close，TCP/TLS 连接池跟着 Session 销毁，
 * 等于完全禁用了 RCK 自带的连接复用。
 *
 * 本类把 Session 按 (origin + cert) 缓存为长生命周期对象，让 RCK 内置的
 * 连接池真正能跨请求复用 → 同主机的第二次起请求省去 TCP+TLS handshake，
 * HTTP/2 multiplexing 生效。
 *
 * 设计要点：
 * - 复用缓存（entries）上限 MAX_SIZE，守住 rcp 系统级 session 上限
 *   （错误码 1007900994 暗示其存在）。缓存满且全部在途时不强制关闭
 *   任何 session（立即 close 会级联取消在途请求，且有 Sunshine HTTPS
 *   listener wedged 的前科），改为发放一次性溢出 session：retired 生而
 *   即标记、不入复用缓存、release 归零即关闭——用「多付一次 TCP+TLS」
 *   替代「取消在途 / 拒绝请求 / 等待容量」三难，溢出数量由应用实际
 *   并发自约束（每主机轮询串行）
 * - 同 origin 但不同 cert 必须分开 session（cert 在 session 创建时绑定）
 * - timeout 不在 session 创建时绑定，由调用方 Request.configuration 覆盖，
 *   这样同一 session 可服务多个不同超时的请求
 * - 连接级错误 / 超时由调用方 invalidate（传发生错误的 session 实例）：
 *   session 可能持有过期 DNS 或损坏连接，只有换新 session 才能恢复
 *   （尤其 DDNS 域名换 IP 的场景）。按实例确认，同 key 的旧 session
 *   迟到错误不会误伤已重建的新 session
 * - invalidate 只把条目移出池子并标记 retired，等该 session 上在途请求
 *   （acquire/release 计数）自然结束才真正 close——立即 close 会级联取消
 *   其他 in-flight 请求（HTTP/2 RST_STREAM 雪崩），且可能触发 Sunshine
 *   Simple-Web-Server 的 SSL state machine 异常导致 HTTPS listener wedged。
 *   新的 acquire 拿到的已是全新 session，因此淘汰立即生效
 *
 * 参考：
 * - https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/remote-communication-cpo
 * - https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/remote-communication-cache-shared
 */
export class RcpSessionPool {
  /** 复用缓存（entries）的上限（防止触发 rcp 系统上限 1007900994） */
  private static readonly MAX_SIZE = 8;

  /** 每个 Session 内部的连接池配置（用我们实际并发量定制） */
  private static readonly MAX_CONN_PER_HOST = 4;
  private static readonly MAX_TOTAL_CONN = 16;

  /** 存活（可复用）的 session，按 cacheKey 索引；retired 条目会立即移出 */
  private static readonly entries: Map<string, SessionPoolEntry> = new Map();
  /** session → 条目反查表：release/invalidate 只拿得到 session 对象；关闭前一直保留 */
  private static readonly live: Map<rcp.Session, SessionPoolEntry> = new Map();

  private static createSession(options: SessionAcquireOptions): rcp.Session {
    const securityConfig: rcp.SecurityConfiguration = {
      remoteValidation: options.skipServerValidation ? 'skip' : 'system'
    };
    if (options.clientCertPath && options.clientKeyPath) {
      securityConfig.certificate = {
        type: 'PEM',
        filePath: options.clientCertPath,
        key: options.clientKeyPath
      };
    }

    const sessionConfig: rcp.SessionConfiguration = {
      requestConfiguration: {
        security: securityConfig
      },
      connectionConfiguration: {
        maxConnectionsPerHost: RcpSessionPool.MAX_CONN_PER_HOST,
        maxTotalConnections: RcpSessionPool.MAX_TOTAL_CONN
      }
    };
    return rcp.createSession(sessionConfig);
  }

  /**
   * 取/建一个 Session（按 cacheKey 缓存）。
   * 每次 acquire 必须对应一次 release（请求结束后的 finally 里调用）。
   * 缓存满且全部在途时发放一次性溢出 session（见类注释），调用方无感。
   */
  static acquire(cacheKey: string, options: SessionAcquireOptions): rcp.Session {
    const cached = RcpSessionPool.entries.get(cacheKey);
    if (cached) {
      cached.lastUsedAt = Date.now();
      cached.inFlight++;
      // 重新插入维护 LRU 顺序（Map 保留插入顺序）
      RcpSessionPool.entries.delete(cacheKey);
      RcpSessionPool.entries.set(cacheKey, cached);
      return cached.session;
    }

    let overflow = false;
    if (RcpSessionPool.entries.size >= RcpSessionPool.MAX_SIZE) {
      // 只关空闲条目腾位；全忙时绝不强制关闭在途 session
      let idle: SessionPoolEntry | undefined;
      RcpSessionPool.entries.forEach((e) => {
        if (idle === undefined && e.inFlight === 0) {
          idle = e;
        }
      });
      if (idle !== undefined) {
        RcpSessionPool.entries.delete(idle.cacheKey);
        RcpSessionPool.closeEntry(idle);
        Logger.info('RcpSessionPool', `RcpSessionPool: 腾位淘汰空闲 ${idle.cacheKey}`);
      } else {
        overflow = true;
      }
    }

    const session = RcpSessionPool.createSession(options);
    const entry: SessionPoolEntry = {
      cacheKey: cacheKey,
      session: session,
      lastUsedAt: Date.now(),
      inFlight: 1,
      // 溢出 session 生而即退役：不入复用缓存，release 归零即关闭
      retired: overflow
    };
    if (!overflow) {
      RcpSessionPool.entries.set(cacheKey, entry);
    }
    RcpSessionPool.live.set(session, entry);
    Logger.info('RcpSessionPool', `RcpSessionPool: ${overflow ? '溢出' : '新建'} session ${cacheKey} (live=${RcpSessionPool.live.size})`);
    return session;
  }

  /**
   * 创建不加入共享池的 Session。
   * 调用方可通过 close() 只取消自己的请求，不影响共享 Session 上的并发流量。
   */
  static createIsolated(options: SessionAcquireOptions): rcp.Session {
    return RcpSessionPool.createSession(options);
  }

  /**
   * 请求结束（成功或失败）后归还。
   * retired 条目在 inFlight 归零时真正 close；存活条目留在池中继续复用。
   */
  static release(session: rcp.Session): void {
    const entry = RcpSessionPool.live.get(session);
    if (!entry) {
      return;
    }
    if (entry.inFlight > 0) {
      entry.inFlight--;
    }
    if (entry.retired && entry.inFlight === 0) {
      RcpSessionPool.closeEntry(entry);
    }
  }

  /**
   * 淘汰发生错误的 session（连接级错误 / 超时时调用）：下次同 cacheKey
   * 请求会重建全新 session。
   * 按实例确认：并发下同 key 可能已重建出新 session（旧 session 的迟到
   * 错误不应误伤新 session）；传入的 session 已淘汰过或已关闭则忽略。
   * 不立即 close，等在途请求结束后再关（见类注释）。
   */
  static invalidate(session: rcp.Session): void {
    const entry = RcpSessionPool.live.get(session);
    if (!entry || entry.retired) {
      return;
    }
    RcpSessionPool.retire(entry, 'invalidate');
  }

  /**
   * 关闭所有 session（应用退出时调用）
   */
  static disposeAll(): void {
    RcpSessionPool.live.forEach((entry) => {
      try {
        entry.session.close();
      } catch (_e) {
        // 忽略
      }
    });
    RcpSessionPool.live.clear();
    RcpSessionPool.entries.clear();
  }

  /**
   * 计算缓存键：origin + cert 路径
   * 同 origin 但不同 cert 的请求需要分开 session（cert 绑定在 session 创建时）
   */
  static keyFor(url: string, clientCertPath?: string): string {
    // 手动提取 origin：ArkTS 没有全局 URL 类
    // 格式：scheme://[user:pass@]host[:port]/path?query  → 取 scheme://host[:port]
    let origin = url;
    const schemeEnd = url.indexOf('://');
    if (schemeEnd > 0) {
      const afterScheme = url.indexOf('/', schemeEnd + 3);
      origin = afterScheme > 0 ? url.substring(0, afterScheme) : url;
    }
    return `${origin}|${clientCertPath ?? 'no-cert'}`;
  }

  private static retire(entry: SessionPoolEntry, reason: string): void {
    // 调用方（invalidate/makeRoom）已保证 entry 是存活条目
    RcpSessionPool.entries.delete(entry.cacheKey);
    entry.retired = true;
    if (entry.inFlight <= 0) {
      RcpSessionPool.closeEntry(entry);
      Logger.warn('RcpSessionPool', `RcpSessionPool: ${reason} → 关闭 ${entry.cacheKey}`);
    } else {
      Logger.warn('RcpSessionPool', `RcpSessionPool: ${reason} → ${entry.cacheKey} 标记待关闭（${entry.inFlight} 个在途请求结束后关闭）`);
    }
  }

  private static closeEntry(entry: SessionPoolEntry): void {
    RcpSessionPool.live.delete(entry.session);
    try {
      entry.session.close();
    } catch (_e) {
      // 忽略
    }
  }
}
