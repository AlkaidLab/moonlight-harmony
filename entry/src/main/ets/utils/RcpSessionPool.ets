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

/**
 * Session 池条目
 */
interface SessionPoolEntry {
  session: rcp.Session;
  lastUsedAt: number;
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
 * - LRU 容量 8（rcp 错误码 1007900994 暗示 sessions 有系统级上限）
 * - 同 origin 但不同 cert 必须分开 session（cert 在 session 创建时绑定）
 * - timeout 不在 session 创建时绑定，由调用方 Request.configuration 覆盖，
 *   这样同一 session 可服务多个不同超时的请求
 * - 出错时调用方主动 invalidate（连接可能损坏，避免持续踩坑）
 *
 * 参考：
 * - https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/remote-communication-cpo
 * - https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/remote-communication-cache-shared
 */
export class RcpSessionPool {
  /** 最大同时持有的 Session 数量（防止触发 rcp 系统上限 1007900994） */
  private static readonly MAX_SIZE = 8;

  /** 每个 Session 内部的连接池配置（用我们实际并发量定制） */
  private static readonly MAX_CONN_PER_HOST = 4;
  private static readonly MAX_TOTAL_CONN = 16;

  private static readonly entries: Map<string, SessionPoolEntry> = new Map();

  /**
   * 取/建一个 Session（按 cacheKey 缓存）
   */
  static acquire(cacheKey: string, options: SessionAcquireOptions): rcp.Session {
    const cached = RcpSessionPool.entries.get(cacheKey);
    if (cached) {
      cached.lastUsedAt = Date.now();
      // 重新插入维护 LRU 顺序（Map 保留插入顺序）
      RcpSessionPool.entries.delete(cacheKey);
      RcpSessionPool.entries.set(cacheKey, cached);
      return cached.session;
    }

    // 池满，淘汰最久未使用（Map 第一个 key 即最早插入 / 最久未访问）
    if (RcpSessionPool.entries.size >= RcpSessionPool.MAX_SIZE) {
      let oldestKey: string | undefined;
      RcpSessionPool.entries.forEach((_v, k) => {
        if (oldestKey === undefined) {
          oldestKey = k;
        }
      });
      if (oldestKey !== undefined) {
        const oldEntry = RcpSessionPool.entries.get(oldestKey);
        RcpSessionPool.entries.delete(oldestKey);
        if (oldEntry) {
          try {
            oldEntry.session.close();
          } catch (_e) {
            // 忽略关闭异常
          }
        }
        console.info(`RcpSessionPool: LRU 淘汰 ${oldestKey}`);
      }
    }

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

    // session 配置：
    // - security 必须在 session 创建时绑定（含客户端证书）
    // - timeout 不绑定，留给 Request.configuration 覆盖（共享 session 的关键）
    // - connectionConfiguration 显式指定（按我们实际并发量定制，比默认 6/64 更紧凑）
    const sessionConfig: rcp.SessionConfiguration = {
      requestConfiguration: {
        security: securityConfig
      },
      connectionConfiguration: {
        maxConnectionsPerHost: RcpSessionPool.MAX_CONN_PER_HOST,
        maxTotalConnections: RcpSessionPool.MAX_TOTAL_CONN
      }
    };

    const session = rcp.createSession(sessionConfig);
    RcpSessionPool.entries.set(cacheKey, { session, lastUsedAt: Date.now() });
    console.info(`RcpSessionPool: 新建 session ${cacheKey} (size=${RcpSessionPool.entries.size})`);
    return session;
  }

  /**
   * 标记 session 损坏（请求出错时调用），从池中移除并关闭
   * 下次同 cacheKey 请求会重建 session
   */
  static invalidate(cacheKey: string): void {
    const entry = RcpSessionPool.entries.get(cacheKey);
    if (!entry) return;
    RcpSessionPool.entries.delete(cacheKey);
    try {
      entry.session.close();
    } catch (_e) {
      // 忽略
    }
    console.warn(`RcpSessionPool: invalidate ${cacheKey}`);
  }

  /**
   * 关闭所有 session（应用退出时调用）
   */
  static disposeAll(): void {
    RcpSessionPool.entries.forEach((entry) => {
      try {
        entry.session.close();
      } catch (_e) {
        // 忽略
      }
    });
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

  /**
   * 当前池中 session 数量（仅用于调试/测试）
   */
  static size(): number {
    return RcpSessionPool.entries.size;
  }
}
