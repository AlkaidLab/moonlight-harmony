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
import { StringUtil } from './StringUtil';

/**
 * HTTP 客户端配置
 */
export interface HttpClientConfig {
  /** 连接超时（毫秒） */
  connectTimeout?: number;
  /** 传输超时（毫秒） */
  transferTimeout?: number;
  /** 是否跳过服务器证书验证 */
  skipServerValidation?: boolean;
  /** 客户端证书文件路径（PEM 格式） */
  clientCertPath?: string;
  /** 客户端私钥文件路径（PEM 格式） */
  clientKeyPath?: string;
}

/**
 * HTTP 响应
 */
export interface HttpResponse {
  statusCode: number;
  body: string;
}

/**
 * Session 池条目
 */
interface SessionPoolEntry {
  session: rcp.Session;
  lastUsedAt: number;
}

/**
 * rcp.Session 池（按 origin + 客户端证书 缓存复用）
 *
 * 背景：HarmonyOS rcp 没有像 OkHttp ConnectionPool 一样的连接复用机制。
 * 之前每次请求都 createSession + close，导致每个 HTTP 请求都要重做 TCP+TLS handshake，
 * 在弱网/低端机上能多 0.5~2 秒延迟，远大于 5~7s 的 read timeout 阈值，
 * 所以"同样的 timeout 设定下安卓不出超时、HarmonyOS 经常超时"。
 *
 * 复用策略：
 * - 池容量上限 8（HarmonyOS rcp 错误码 1007900994 暗示有 sessions 上限）
 * - LRU 淘汰：通过 Map 重新插入维护访问顺序
 * - 同 origin + 同 cert 的请求共享一个 Session（rcp 内部 HTTP/2 multiplexing + TLS resumption）
 * - 超时不在 Session 创建时绑定，而是 Request 级 configuration 覆盖（见 buildRequestConfig）
 * - 出错时 invalidate 当前 Session（连接可能损坏，避免后续请求继续踩坑）
 */
class SessionPool {
  private static readonly MAX_SIZE = 8;
  private static readonly entries: Map<string, SessionPoolEntry> = new Map();

  /**
   * 取/建一个 Session
   * @param key 缓存键（origin + cert 组合）
   * @param skipServerValidation 是否跳过服务器证书验证
   * @param clientCertPath 客户端 PEM 证书路径
   * @param clientKeyPath 客户端 PEM 私钥路径
   */
  static acquire(
    key: string,
    skipServerValidation: boolean,
    clientCertPath?: string,
    clientKeyPath?: string
  ): rcp.Session {
    const cached = SessionPool.entries.get(key);
    if (cached) {
      cached.lastUsedAt = Date.now();
      // 重新插入维护 LRU 顺序（Map 保留插入顺序）
      SessionPool.entries.delete(key);
      SessionPool.entries.set(key, cached);
      return cached.session;
    }

    // 池满，淘汰最久未使用（Map 第一个 key，插入顺序即 LRU 顺序）
    if (SessionPool.entries.size >= SessionPool.MAX_SIZE) {
      let oldestKey: string | undefined;
      SessionPool.entries.forEach((_v, k) => {
        if (oldestKey === undefined) {
          oldestKey = k;
        }
      });
      if (oldestKey !== undefined) {
        const oldEntry = SessionPool.entries.get(oldestKey);
        SessionPool.entries.delete(oldestKey);
        if (oldEntry) {
          try {
            oldEntry.session.close();
          } catch (_e) {
            // 忽略关闭异常
          }
        }
        console.info(`SessionPool: LRU 淘汰 ${oldestKey}`);
      }
    }

    const securityConfig: rcp.SecurityConfiguration = {
      remoteValidation: skipServerValidation ? 'skip' : 'system'
    };
    if (clientCertPath && clientKeyPath) {
      securityConfig.certificate = {
        type: 'PEM',
        filePath: clientCertPath,
        key: clientKeyPath
      };
    }

    // session 创建时不绑定 timeout，让 request 级覆盖（同 session 可服务不同超时的请求）
    const sessionConfig: rcp.SessionConfiguration = {
      requestConfiguration: {
        security: securityConfig
      }
    };

    const session = rcp.createSession(sessionConfig);
    SessionPool.entries.set(key, { session, lastUsedAt: Date.now() });
    console.info(`SessionPool: 新建 session ${key} (size=${SessionPool.entries.size})`);
    return session;
  }

  /**
   * 标记 session 损坏（请求出错时调用），从池中移除并关闭
   * 下次同 key 请求会建新 session
   */
  static invalidate(key: string): void {
    const entry = SessionPool.entries.get(key);
    if (!entry) return;
    SessionPool.entries.delete(key);
    try {
      entry.session.close();
    } catch (_e) {
      // 忽略
    }
    console.warn(`SessionPool: invalidate ${key}`);
  }

  /**
   * 关闭所有 session（应用退出时调用）
   */
  static disposeAll(): void {
    SessionPool.entries.forEach((entry) => {
      try {
        entry.session.close();
      } catch (_e) {
        // 忽略
      }
    });
    SessionPool.entries.clear();
  }

  /**
   * 计算缓存键：origin + cert 路径
   * 同 origin 但不同 cert 的请求需要分开 session（cert 在 session 创建时绑定）
   */
  static keyFor(url: string, clientCertPath?: string): string {
    // 手动提取 origin：ArkTS 没有全局 URL 类
    // 格式：scheme://[user:pass@]host[:port]/path?query  → 我们只要 scheme://host[:port]
    let origin = url;
    const schemeEnd = url.indexOf('://');
    if (schemeEnd > 0) {
      const afterScheme = url.indexOf('/', schemeEnd + 3);
      origin = afterScheme > 0 ? url.substring(0, afterScheme) : url;
    }
    return `${origin}|${clientCertPath ?? 'no-cert'}`;
  }
}

/**
 * HTTP 客户端工具类
 * 
 * 统一处理 HTTP/HTTPS 请求，基于 RCP (RemoteCommunicationKit)
 */
export class HttpClient {
  /** 默认连接超时 */
  static readonly DEFAULT_CONNECT_TIMEOUT = 5000;
  /** 默认传输超时 */
  static readonly DEFAULT_TRANSFER_TIMEOUT = 7000;
  /** 长连接超时（用于等待用户操作的请求） */
  static readonly LONG_TRANSFER_TIMEOUT = 300000;

  /**
   * 关闭所有 session 池中的连接（应用退出时调用）
   */
  static disposeAllSessions(): void {
    SessionPool.disposeAll();
  }

  /**
   * 构造请求级 Configuration（覆盖 session 默认 timeout）
   * 这样同一个 session 可服务多个不同超时的请求
   */
  private static buildRequestConfig(connectMs: number, transferMs: number): rcp.Configuration {
    return {
      transfer: {
        timeout: {
          connectMs: connectMs,
          transferMs: transferMs
        }
      }
    };
  }

  /**
   * 通用 GET 执行器（文本响应）
   */
  private static async executeGet(url: string, config?: HttpClientConfig): Promise<HttpResponse> {
    const connectTimeout = config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT;
    const transferTimeout = config?.transferTimeout ?? HttpClient.DEFAULT_TRANSFER_TIMEOUT;
    const skipValidation = config?.skipServerValidation !== false;
    const key = SessionPool.keyFor(url, config?.clientCertPath);
    const session = SessionPool.acquire(key, skipValidation, config?.clientCertPath, config?.clientKeyPath);

    console.debug(`HttpClient: GET ${url} (connect=${connectTimeout}ms, transfer=${transferTimeout}ms, sessionKey=${key})`);

    const request = new rcp.Request(
      url,
      'GET',
      undefined,
      undefined,
      undefined,
      undefined,
      HttpClient.buildRequestConfig(connectTimeout, transferTimeout)
    );

    try {
      const response = await session.fetch(request);
      console.debug(`HttpClient: 响应状态码 = ${response.statusCode}`);

      if (response.statusCode !== 200) {
        throw new Error(`HTTP ${response.statusCode}`);
      }
      if (!response.body) {
        throw new Error('响应体为空');
      }

      const body = StringUtil.arrayBufferToString(response.body);
      return { statusCode: response.statusCode, body: body };
    } catch (err) {
      const error = err as Error;
      // 连接级错误时丢弃 session（损坏的连接复用只会继续失败）
      if (HttpClient.isConnectionError(error.message)) {
        SessionPool.invalidate(key);
      }
      const isTimeout = error.message?.includes('Timeout') || error.message?.includes('timeout');
      if (isTimeout) {
        console.warn(`HttpClient: 请求超时 - ${url}`);
      } else {
        console.error(`HttpClient: 请求失败 - ${error.message}`);
      }
      throw new Error(`HTTP 请求失败: ${error.message}`);
    }
  }

  /**
   * 判断是否连接级错误（应 invalidate session）
   * 协议级错误（401/4xx/5xx）不应丢 session，因为连接本身是好的
   */
  private static isConnectionError(msg: string): boolean {
    if (!msg) return false;
    const lower = msg.toLowerCase();
    return lower.includes('timeout') ||
      lower.includes('refused') ||
      lower.includes('reset') ||
      lower.includes('unreachable') ||
      lower.includes('ssl') ||
      lower.includes('handshake') ||
      lower.includes('1007900007') || // Couldn't connect
      lower.includes('1007900028') || // Timeout
      lower.includes('1007900035') || // SSL connection
      lower.includes('1007900016');   // HTTP2 framing
  }

  /**
   * 执行 GET 请求
   * @param url 请求 URL
   * @param config 配置选项
   * @returns 响应字符串
   */
  static async get(url: string, config?: HttpClientConfig): Promise<string> {
    const response = await HttpClient.executeGet(url, config);
    return response.body;
  }

  /**
   * 执行 HTTP 请求（GET，返回完整响应）
   */
  static async request(url: string, config?: HttpClientConfig): Promise<HttpResponse> {
    return HttpClient.executeGet(url, config);
  }

  /**
   * 执行带客户端证书的 HTTPS 请求
   * @param url 请求 URL
   * @param certPath 证书文件路径
   * @param keyPath 私钥文件路径
   * @param config 配置选项
   * @returns 响应字符串
   */
  static async getWithClientCert(
    url: string,
    certPath: string,
    keyPath: string,
    config?: HttpClientConfig
  ): Promise<string> {
    return HttpClient.get(url, {
      skipServerValidation: true,
      clientCertPath: certPath,
      clientKeyPath: keyPath,
      connectTimeout: config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT,
      transferTimeout: config?.transferTimeout ?? HttpClient.DEFAULT_TRANSFER_TIMEOUT
    });
  }

  /**
   * 执行 GET 请求并返回二进制数据
   */
  static async getBinary(url: string, config?: HttpClientConfig): Promise<ArrayBuffer> {
    const connectTimeout = config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT;
    const transferTimeout = config?.transferTimeout ?? HttpClient.DEFAULT_TRANSFER_TIMEOUT;
    const skipValidation = config?.skipServerValidation !== false;
    const key = SessionPool.keyFor(url, config?.clientCertPath);
    const session = SessionPool.acquire(key, skipValidation, config?.clientCertPath, config?.clientKeyPath);

    console.info(`HttpClient: 二进制 GET ${url} (sessionKey=${key})`);

    const request = new rcp.Request(
      url,
      'GET',
      undefined,
      undefined,
      undefined,
      undefined,
      HttpClient.buildRequestConfig(connectTimeout, transferTimeout)
    );

    try {
      const response = await session.fetch(request);
      if (response.statusCode !== 200) {
        throw new Error(`HTTP ${response.statusCode}`);
      }
      if (!response.body) {
        throw new Error('响应体为空');
      }
      console.info(`HttpClient: 二进制响应大小 = ${response.body.byteLength} 字节`);
      return response.body;
    } catch (err) {
      const error = err as Error;
      if (HttpClient.isConnectionError(error.message)) {
        SessionPool.invalidate(key);
      }
      console.error(`HttpClient: 二进制请求失败 - ${error.message}`);
      throw new Error(`HTTP 请求失败: ${error.message}`);
    }
  }

  /**
   * 执行带客户端证书的 HTTPS 请求并返回二进制数据
   * @param url 请求 URL
   * @param certPath 证书文件路径
   * @param keyPath 私钥文件路径
   * @param config 配置选项
   * @returns ArrayBuffer
   */
  static async getBinaryWithClientCert(
    url: string,
    certPath: string,
    keyPath: string,
    config?: HttpClientConfig
  ): Promise<ArrayBuffer> {
    return HttpClient.getBinary(url, {
      skipServerValidation: true,
      clientCertPath: certPath,
      clientKeyPath: keyPath,
      connectTimeout: config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT,
      transferTimeout: config?.transferTimeout ?? HttpClient.DEFAULT_TRANSFER_TIMEOUT
    });
  }

  /**
   * 执行 POST 请求（JSON body）
   */
  static async post(url: string, body: string, config?: HttpClientConfig): Promise<HttpResponse> {
    const connectTimeout = config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT;
    const transferTimeout = config?.transferTimeout ?? HttpClient.DEFAULT_TRANSFER_TIMEOUT;
    const skipValidation = config?.skipServerValidation !== false;
    const key = SessionPool.keyFor(url, config?.clientCertPath);
    const session = SessionPool.acquire(key, skipValidation, config?.clientCertPath, config?.clientKeyPath);

    console.debug(`HttpClient: POST ${url} (connect=${connectTimeout}ms, transfer=${transferTimeout}ms, sessionKey=${key})`);

    const request = new rcp.Request(
      url,
      'POST',
      undefined,
      body,
      undefined,
      undefined,
      HttpClient.buildRequestConfig(connectTimeout, transferTimeout)
    );

    try {
      const response = await session.fetch(request);
      console.debug(`HttpClient: POST 响应状态码 = ${response.statusCode}`);
      if (!response.body) {
        throw new Error('响应体为空');
      }
      const responseBody = StringUtil.arrayBufferToString(response.body);
      return { statusCode: response.statusCode ?? 0, body: responseBody };
    } catch (err) {
      const error = err as Error;
      if (HttpClient.isConnectionError(error.message)) {
        SessionPool.invalidate(key);
      }
      console.error(`HttpClient: POST 请求失败 - ${error.message}`);
      throw new Error(`HTTP POST 请求失败: ${error.message}`);
    }
  }

  /**
   * 执行带客户端证书的 POST 请求
   */
  static async postWithClientCert(
    url: string,
    body: string,
    certPath: string,
    keyPath: string,
    config?: HttpClientConfig
  ): Promise<HttpResponse> {
    return HttpClient.post(url, body, {
      skipServerValidation: true,
      clientCertPath: certPath,
      clientKeyPath: keyPath,
      connectTimeout: config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT,
      transferTimeout: config?.transferTimeout ?? 120000
    });
  }
}
