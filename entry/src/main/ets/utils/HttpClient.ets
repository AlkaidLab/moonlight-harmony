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
   * 执行 GET 请求
   * @param url 请求 URL
   * @param config 配置选项
   * @returns 响应字符串
   */
  static async get(url: string, config?: HttpClientConfig): Promise<string> {
    const response = await HttpClient.request(url, config);
    return response.body;
  }

  /**
   * 执行 HTTP 请求
   * @param url 请求 URL
   * @param config 配置选项
   * @returns HTTP 响应
   */
  static async request(url: string, config?: HttpClientConfig): Promise<HttpResponse> {
    const connectTimeout = config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT;
    const transferTimeout = config?.transferTimeout ?? HttpClient.DEFAULT_TRANSFER_TIMEOUT;

    console.info(`HttpClient: 请求 ${url}`);
    console.info(`HttpClient: 超时设置 connect=${connectTimeout}ms, transfer=${transferTimeout}ms`);

    // 构建安全配置
    const securityConfig: rcp.SecurityConfiguration = {
      remoteValidation: config?.skipServerValidation !== false ? 'skip' : 'system'
    };

    // 如果提供了客户端证书
    if (config?.clientCertPath && config?.clientKeyPath) {
      securityConfig.certificate = {
        type: 'PEM',
        filePath: config.clientCertPath,
        key: config.clientKeyPath
      };
      console.info(`HttpClient: 使用客户端证书: ${config.clientCertPath}`);
    }

    // 创建 session 配置
    const sessionConfig: rcp.SessionConfiguration = {
      requestConfiguration: {
        security: securityConfig,
        transfer: {
          timeout: {
            connectMs: connectTimeout,
            transferMs: transferTimeout
          }
        }
      }
    };

    const session = rcp.createSession(sessionConfig);

    try {
      const response = await session.get(url);
      console.info(`HttpClient: 响应状态码 = ${response.statusCode}`);

      if (response.statusCode !== 200) {
        throw new Error(`HTTP ${response.statusCode}`);
      }

      if (!response.body) {
        throw new Error('响应体为空');
      }

      const body = StringUtil.arrayBufferToString(response.body);
      console.info(`HttpClient: 响应长度 = ${body.length}`);

      return {
        statusCode: response.statusCode,
        body: body
      };
    } catch (err) {
      const error = err as Error;
      console.error(`HttpClient: 请求失败 - ${error.message}`);
      throw new Error(`HTTP 请求失败: ${error.message}`);
    } finally {
      session.close();
    }
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
   * @param url 请求 URL
   * @param config 配置选项
   * @returns ArrayBuffer
   */
  static async getBinary(url: string, config?: HttpClientConfig): Promise<ArrayBuffer> {
    const connectTimeout = config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT;
    const transferTimeout = config?.transferTimeout ?? HttpClient.DEFAULT_TRANSFER_TIMEOUT;

    console.info(`HttpClient: 二进制请求 ${url}`);

    // 构建安全配置
    const securityConfig: rcp.SecurityConfiguration = {
      remoteValidation: config?.skipServerValidation !== false ? 'skip' : 'system'
    };

    // 如果提供了客户端证书
    if (config?.clientCertPath && config?.clientKeyPath) {
      securityConfig.certificate = {
        type: 'PEM',
        filePath: config.clientCertPath,
        key: config.clientKeyPath
      };
    }

    // 创建 session 配置
    const sessionConfig: rcp.SessionConfiguration = {
      requestConfiguration: {
        security: securityConfig,
        transfer: {
          timeout: {
            connectMs: connectTimeout,
            transferMs: transferTimeout
          }
        }
      }
    };

    const session = rcp.createSession(sessionConfig);

    try {
      const response = await session.get(url);

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
      console.error(`HttpClient: 二进制请求失败 - ${error.message}`);
      throw new Error(`HTTP 请求失败: ${error.message}`);
    } finally {
      session.close();
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
}
