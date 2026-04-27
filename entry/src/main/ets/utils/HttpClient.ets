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
import { RcpSessionPool } from './RcpSessionPool';

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
 * HTTP 客户端工具类
 *
 * 统一处理 HTTP/HTTPS 请求，基于 RCK (RemoteCommunicationKit)。
 * 通过 {@link RcpSessionPool} 复用 rcp.Session，让 RCK 内置的
 * 连接池真正能跨请求复用（避免每次 TCP+TLS handshake）。
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
    RcpSessionPool.disposeAll();
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
    const key = RcpSessionPool.keyFor(url, config?.clientCertPath);
    const session = RcpSessionPool.acquire(key, { skipServerValidation: skipValidation, clientCertPath: config?.clientCertPath, clientKeyPath: config?.clientKeyPath });

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
        RcpSessionPool.invalidate(key);
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
    const key = RcpSessionPool.keyFor(url, config?.clientCertPath);
    const session = RcpSessionPool.acquire(key, { skipServerValidation: skipValidation, clientCertPath: config?.clientCertPath, clientKeyPath: config?.clientKeyPath });

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
        RcpSessionPool.invalidate(key);
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
    const key = RcpSessionPool.keyFor(url, config?.clientCertPath);
    const session = RcpSessionPool.acquire(key, { skipServerValidation: skipValidation, clientCertPath: config?.clientCertPath, clientKeyPath: config?.clientKeyPath });

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
        RcpSessionPool.invalidate(key);
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
