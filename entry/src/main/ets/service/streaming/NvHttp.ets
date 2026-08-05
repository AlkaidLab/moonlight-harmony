/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { BinaryHttpSession, HttpClient } from '../../utils/HttpClient';
import { XmlUtil } from '../../utils/XmlUtil';
import { StringUtil } from '../../utils/StringUtil';
import { CryptoUtil } from '../../utils/CryptoUtil';
import { DEFAULT_HTTP_PORT, DEFAULT_HTTPS_PORT } from '../../common/NetworkConstants';
import { parseAddressAndPort, formatAddressForUrl } from '../../utils/NetHelper';
import { selectBestAddress, NvHttpHost } from '../../model/ComputerInfo';

// HarmonyOS BrightnessInfo exposes peak/headroom but not the panel black level.
// Match Sunshine's unknown-display fallback instead of inventing a raised black floor.
export const DEFAULT_HDR_MIN_BRIGHTNESS_NITS: number = 0.001;

/**
 * NvHTTP - 与 NVIDIA GameStream / Sunshine 服务器通信
 *
 * 这是 Android 版本 NvHTTP.java 的 HarmonyOS 移植
 */

export interface ServerInfo {
  hostname: string;
  uniqueId: string;
  macAddress: string;
  paired: boolean;
  currentGame: number;
  serverCodecModeSupport: number;
  gpuType: string;
  gfeVersion: string;
  appVersion: string;
  maxLumaPixelsHEVC: number;
  serverCapabilities: string;
  httpsPort: number;
  externalPort: number;
  localAddress: string;
  externalAddress: string;
}

/**
 * 显示器信息 (Sunshine 功能)
 */
export interface DisplayInfo {
  index: number;      // 显示器索引
  name: string;       // 友好名称，用于 UI 显示
  guid: string;       // GUID，用于传递给服务端
}

/**
 * Sunshine 显示器 API 响应
 */
interface DisplaysResponse {
  status_code: number;
  status_message?: string;
  displays?: DisplayItem[];
}

interface DisplayItem {
  friendly_name?: string;
  display_name?: string;
  device_id?: string;
}

/**
 * Sunshine 旋转显示 API 响应
 */
interface RotateDisplayResponse {
  status_code?: number;
  status_message?: string;
  success?: boolean;
}

interface ClipboardBlobUploadResponse {
  id?: string;
  mime?: string;
  size?: number | string;
}

/**
 * Sunshine /api/v1/clipboard/blob 上传响应的扣准结构。
 * 这个类型为 NvHttp 内部使用，定义等价于加了 "id 是必选" 约束的
 * `Required<Pick<ClipboardBlobUploadResponse, 'id'>> & { ... }`。调用方
 * （SunshineClipboardBlobTransport）负责包装为业务层的 ClipboardBlobRef，
 * 这样 NvHttp 不反向依赖 clipboard 模块。
 */
export interface ClipboardBlobUploadResult {
  id: string;
  mime: string;
  size: number;
}

/**
 * getServerInfoRobust 选项
 */
export interface GetServerInfoRobustOptions {
  /** 最大尝试次数（含首次），默认 3 */
  maxAttempts?: number;
  /** 重试间隔（毫秒），默认 1500 */
  delayMs?: number;
  /** 取消检查回调；返回 true 时立即抛出最近一次错误 */
  isCancelled?: () => boolean;
  /** 每次重试触发的回调（可用于上报进度/UI 文案） */
  onRetry?: (attempt: number, maxAttempts: number, err: Error) => void;
}

/** 取消错误：name='CanceledError'，便于调用方与真实网络错误区分 */
export interface CanceledError extends Error {
  isCanceled: boolean;
}

interface NvHttpRequestOptions {
  /** 传输超时（毫秒），默认 READ_TIMEOUT */
  transferTimeout?: number;
  /** 连接超时（毫秒），默认 CONNECTION_TIMEOUT */
  connectTimeout?: number;
  /** 是否使用客户端证书（HTTPS 请求需要） */
  useClientCert?: boolean;
}

interface NvHttpPathRequestOptions {
  query?: string;
  transferTimeout?: number;
  connectTimeout?: number;
}

interface NetworkProbeCapabilitiesResponse {
  version: number;
  features: string[];
  bandwidthProbe?: NetworkProbeCapabilities;
}

export interface NetworkProbeCapabilities {
  version: number;
  endpoint: string;
  minBytes: number;
  maxBytes: number;
  cooldownMs: number;
}

/** 独占的 Sunshine 带宽探测传输；close() 只取消本轮探测。 */
export class NetworkProbeSession {
  private httpSession: BinaryHttpSession | null;
  private urlPrefix: string;

  constructor(urlPrefix: string, certFilePath: string, keyFilePath: string) {
    this.urlPrefix = urlPrefix;
    this.httpSession = new BinaryHttpSession({
      skipServerValidation: true,
      clientCertPath: certFilePath,
      clientKeyPath: keyFilePath
    });
  }

  async download(bytes: number, nonce: string, timeoutMs: number): Promise<ArrayBuffer> {
    const httpSession = this.httpSession;
    if (!httpSession) {
      throw NvHttp.makeCanceledError();
    }
    const headers: Record<string, string> = {
      'Accept': 'application/octet-stream',
      'Accept-Encoding': 'identity',
      'Cache-Control': 'no-store'
    };
    const url = this.urlPrefix + '&bytes=' + bytes.toString() + '&nonce=' + encodeURIComponent(nonce);
    return await httpSession.get(url, {
      headers: headers,
      connectTimeout: Math.min(NvHttp.LONG_CONNECTION_TIMEOUT, timeoutMs),
      transferTimeout: timeoutMs
    });
  }

  close(): void {
    const httpSession = this.httpSession;
    this.httpSession = null;
    if (httpSession) {
      httpSession.close();
    }
  }
}

export class NvHttp {
  private address: string;
  private serverCert: string | null;
  private uniqueId: string;
  private clientName: string;
  private context: common.UIAbilityContext | null = null;
  private certFilePath: string = '';
  private keyFilePath: string = '';

  // 端口常量（来源于 NetworkConstants）
  static readonly DEFAULT_HTTPS_PORT = DEFAULT_HTTPS_PORT;
  static readonly DEFAULT_HTTP_PORT = DEFAULT_HTTP_PORT;
  // 超时时间（对齐 Android 版 NvHTTP 的 SHORT_CONNECTION_TIMEOUT/LONG_CONNECTION_TIMEOUT/READ_TIMEOUT）
  // 注意：HarmonyOS rcp 当前没有连接复用（每次 createSession+close），每次请求都要走完整 TCP+TLS handshake
  // 所以 connect 阶段比 Android OkHttp 慢 1.5~3 RTT，这里给的 timeout 已经考虑此差异
  static readonly CONNECTION_TIMEOUT = 3000;
  static readonly LONG_CONNECTION_TIMEOUT = 5000;
  static readonly READ_TIMEOUT = 7000;
  static readonly CLIPBOARD_BLOB_TIMEOUT = 30000;
  static readonly CLIPBOARD_BLOB_CONNECT_TIMEOUT = 10000;
  static readonly CLIPBOARD_BLOB_MAX_ATTEMPTS = 2;
  static readonly CLIPBOARD_BLOB_RETRY_DELAY_MS = 1200;
  static readonly NETWORK_PROBE_TIMEOUT = 1500;

  // getServerInfoRobust 默认参数（启动链路使用）
  static readonly DEFAULT_ROBUST_MAX_ATTEMPTS = 3;
  static readonly DEFAULT_ROBUST_DELAY_MS = 1500;

  // 缓存的 HTTPS 端口
  private httpsPort: number = 0;
  // 自定义的 HTTP 端口
  private httpPort: number = NvHttp.DEFAULT_HTTP_PORT;

  // 全局唯一 ID 缓存（应用生命周期内保持一致）
  private static cachedUniqueId: string | null = null;
  // 全局客户端名称缓存（使用设备名称）
  private static cachedClientName: string | null = null;

  /**
   * 清除 uniqueId 静态缓存，下次请求从文件重新读取。
   * 备份恢复后调用，确保使用恢复的 uniqueId 而非启动时生成的新值。
   */
  static clearCachedUniqueId(): void {
    NvHttp.cachedUniqueId = null;
  }

  /**
   * 从电脑信息创建 NvHttp（自动选择最佳地址）
   * 替代重复的 new NvHttp(selectBestAddress(c), c.serverCert, ctx, c.httpPort, c.httpsPort)
   */
  static fromComputer(computer: NvHttpHost, context?: common.UIAbilityContext): NvHttp {
    return new NvHttp(selectBestAddress(computer), computer.serverCert || null, context, computer.httpPort, computer.httpsPort);
  }

  /**
   * 从指定地址 + 电脑信息创建 NvHttp（用于轮询/测试指定地址）
   *
   * 对齐 Android `tryPollIp` 的 `portMatchesActiveAddress` 逻辑：
   * 仅当指定 address 的端口与 computer.address 缓存端口一致时，才复用缓存的 httpsPort；
   * 否则置 0，让 NvHttp 在 HTTPS 请求时通过 HTTP serverinfo 重新探测。
   *
   * 这避免了切换网络（如 LAN→公网/frp）时使用 stale 的 httpsPort 导致 getAppList 超时。
   */
  static fromAddress(address: string, computer: NvHttpHost, context?: common.UIAbilityContext): NvHttp {
    const httpFallback = computer.httpPort || NvHttp.DEFAULT_HTTP_PORT;
    const targetPort = NvHttp.resolveHttpPort(address, httpFallback);
    const activePort = computer.address ? NvHttp.resolveHttpPort(computer.address, httpFallback) : 0;
    const portMatches = activePort > 0 && activePort === targetPort;
    const reusedHttpsPort = portMatches ? computer.httpsPort : undefined;
    // 构造函数已优先 address 中解析的端口，传 computer.httpPort 仅作为 address 无端口时的回退
    return new NvHttp(address, computer.serverCert || null, context, computer.httpPort, reusedHttpsPort);
  }

  /** 解析地址中的端口，缺省时回退 fallback */
  private static resolveHttpPort(address: string, fallback: number): number {
    return parseAddressAndPort(address).port || fallback;
  }

  constructor(address: string, serverCert: string | null, context?: common.UIAbilityContext, httpPort?: number, httpsPort?: number) {
    // 解析地址中可能包含的端口号
    const parsed = parseAddressAndPort(address);
    this.address = parsed.host;
    this.serverCert = serverCert;
    // 端口优先级：address 中显式端口 > 显式传入 httpPort > 默认
    // address 端口优先：避免 fromComputer(computer) 中 selectBestAddress 返回 'host:30000'
    //   被陈旧的 computer.httpPort（如 LAN 47989）覆盖的 bug
    this.httpPort = parsed.port || httpPort || NvHttp.DEFAULT_HTTP_PORT;
    // 使用缓存的 HTTPS 端口（轮询阶段从 serverinfo 获取）
    this.httpsPort = httpsPort || 0;
    if (context) {
      this.context = context;
      this.certFilePath = context.filesDir + '/client_cert.pem';
      this.keyFilePath = context.filesDir + '/client_key.pem';
    }
    this.uniqueId = this.getOrCreateUniqueId(context);
    this.clientName = this.getClientName();
  }
  
  /**
   * 检查客户端证书文件是否存在
   */
  private hasCertificateFiles(): boolean {
    if (!this.certFilePath || !this.keyFilePath) {
      return false;
    }
    try {
      return fileIo.accessSync(this.certFilePath) && fileIo.accessSync(this.keyFilePath);
    } catch (err) {
      return false;
    }
  }

  /**
   * 获取或创建设备唯一标识
   * 优先使用缓存，其次从文件读取，最后生成新的并保存
   */
  private getOrCreateUniqueId(context?: common.UIAbilityContext): string {
    // 1. 如果已缓存，直接返回
    if (NvHttp.cachedUniqueId) {
      return NvHttp.cachedUniqueId;
    }

    // 2. 尝试从文件读取
    if (context) {
      const uniqueIdPath = context.filesDir + '/unique_id.txt';
      try {
        if (fileIo.accessSync(uniqueIdPath)) {
          const file = fileIo.openSync(uniqueIdPath, fileIo.OpenMode.READ_ONLY);
          const stat = fileIo.statSync(uniqueIdPath);
          const buffer = new ArrayBuffer(stat.size);
          fileIo.readSync(file.fd, buffer);
          fileIo.closeSync(file);
          const textDecoder = util.TextDecoder.create('utf-8');
          const savedId = textDecoder.decodeToString(new Uint8Array(buffer)).trim();
          if (savedId.length === 16) {
            NvHttp.cachedUniqueId = savedId;
            console.info(`NvHttp: 从文件加载 uniqueId: ${savedId}`);
            return savedId;
          }
        }
      } catch (err) {
        console.warn(`NvHttp: 无法读取 uniqueId 文件: ${err}`);
      }
    }

    // 3. 生成新的 uniqueId（使用加密安全的随机数）
    const randomBytes = CryptoUtil.generateRandomBytes(8);
    const result = CryptoUtil.bytesToHex(randomBytes).toLowerCase();
    NvHttp.cachedUniqueId = result;
    console.info(`NvHttp: 生成新 uniqueId: ${result}`);

    // 4. 保存到文件
    if (context) {
      const uniqueIdPath = context.filesDir + '/unique_id.txt';
      try {
        const file = fileIo.openSync(uniqueIdPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        const textEncoder = new util.TextEncoder();
        const encoded = textEncoder.encodeInto(result);
        fileIo.writeSync(file.fd, encoded.buffer);
        fileIo.closeSync(file);
        console.info(`NvHttp: uniqueId 已保存到文件`);
      } catch (err) {
        console.error(`NvHttp: 无法保存 uniqueId: ${err}`);
      }
    }

    return result;
  }

  /**
   * 获取客户端名称（使用设备名称）
   * 参考 Android: Settings.Global.getString(getContentResolver(), "device_name")
   */
  private getClientName(): string {
    // 1. 如果已缓存，直接返回
    if (NvHttp.cachedClientName) {
      return NvHttp.cachedClientName;
    }

    // 2. 尝试获取设备名称
    try {
      // 优先使用 marketName（如 "HUAWEI Mate 60 Pro"）
      // 如果没有，则使用 productModel（如 "ALN-AL00"）
      const name = deviceInfo.marketName || deviceInfo.productModel || 'Moonlight-HarmonyOS';
      NvHttp.cachedClientName = name;
      console.info(`NvHttp: 客户端名称: ${name}`);
      return name;
    } catch (err) {
      console.warn(`NvHttp: 无法获取设备名称: ${err}`);
      NvHttp.cachedClientName = 'Moonlight-HarmonyOS';
      return 'Moonlight-HarmonyOS';
    }
  }

  /**
   * 获取 HTTP 基础 URL
   */
  private getHttpBaseUrl(): string {
    return `http://${formatAddressForUrl(this.address)}:${this.httpPort}`;
  }

  /**
   * 获取 HTTPS 基础 URL（懒加载模式，匹配 Android 的 getHttpsUrl 行为）
   * 当 httpsPort 未知时，自动通过 HTTP 调用 serverinfo 获取真实 HTTPS 端口
   * 端口优先级：
   * 1. 已缓存的 httpsPort（来自 serverInfo 或自动解析）
   * 2. 自动通过 HTTP serverinfo 获取（懒加载）
   * 3. 根据 httpPort 计算的端口（httpPort - 5）作为最终兜底
   */
  private async getHttpsBaseUrl(connectTimeout: number = NvHttp.CONNECTION_TIMEOUT): Promise<string> {
    // 已缓存 → 直接使用
    if (this.httpsPort > 0) {
      return `https://${formatAddressForUrl(this.address)}:${this.httpsPort}`;
    }

    // 自定义端口（frp / 端口转发）→ Sunshine 规则直接推算，跳过 HTTP 探测避免 3s 超时
    if (this.httpPort !== NvHttp.DEFAULT_HTTP_PORT) {
      const port = this.httpPort - 5;
      console.info(`NvHttp: 自定义端口场景，推算 HTTPS 端口 ${port} (httpPort=${this.httpPort} - 5)`);
      return `https://${formatAddressForUrl(this.address)}:${port}`;
    }

    // 默认端口 + 未缓存 → 通过 HTTP serverinfo 获取（和 Android 一致）
    try {
      const url = this.buildUrl(this.getHttpBaseUrl(), 'serverinfo');
      const response = await this.doRequest(url, { connectTimeout: connectTimeout });
      const port = XmlUtil.getIntValue(response, 'HttpsPort', 0);
      if (port > 0) {
        this.httpsPort = port;
        console.info(`NvHttp: 自动解析 HTTPS 端口: ${port}`);
        return `https://${formatAddressForUrl(this.address)}:${port}`;
      }
    } catch (err) {
      console.warn(`NvHttp: 自动解析 HTTPS 端口失败: ${err}`);
    }

    // 最终兜底：默认 HTTPS 端口
    console.info(`NvHttp: 使用默认 HTTPS 端口 ${NvHttp.DEFAULT_HTTPS_PORT}`);
    return `https://${formatAddressForUrl(this.address)}:${NvHttp.DEFAULT_HTTPS_PORT}`;
  }

  /**
   * 构建完整 URL
   */
  private buildUrl(baseUrl: string, path: string, query?: string): string {
    let url = `${baseUrl}/${path}?uniqueid=${this.uniqueId}&clientname=${encodeURIComponent(this.clientName)}&uuid=${this.generateUUID()}`;
    if (query) {
      url += `&${query}`;
    }
    return url;
  }

  /**
   * 生成 UUID
   */
  private generateUUID(): string {
    return StringUtil.generateUUID();
  }

  /**
   * 执行 HTTP 请求
   * @param url 请求URL
   * @param options 请求超时和证书选项
   */
  private async doRequest(url: string, options?: NvHttpRequestOptions): Promise<string> {
    const transferTimeout = options?.transferTimeout ?? NvHttp.READ_TIMEOUT;
    const connectTimeout = options?.connectTimeout ?? NvHttp.CONNECTION_TIMEOUT;
    const useClientCert = options?.useClientCert ?? false;
    console.debug(`NvHttp: 请求 ${url}`);

    if (useClientCert && this.certFilePath && this.keyFilePath) {
      return HttpClient.getWithClientCert(url, this.certFilePath, this.keyFilePath, {
        connectTimeout: connectTimeout,
        transferTimeout: transferTimeout
      });
    } else {
      return HttpClient.get(url, {
        connectTimeout: connectTimeout,
        transferTimeout: transferTimeout
      });
    }
  }

  /**
   * 判断错误是否为超时错误
   */
  private isTimeoutError(errMsg: string): boolean {
    return NvHttp.isTimeoutError(errMsg);
  }

  /**
   * 判断错误是否为超时错误（静态，供外部复用）
   */
  static isTimeoutError(errMsg: string): boolean {
    const lower = errMsg.toLowerCase();
    return lower.includes('timeout') || lower.includes('timed out');
  }

  /**
   * 判断错误是否属于「可重试的矬时网络错误」
   * 覆盖：超时 / 连接拒绝 / 不可达 / DNS 解析失败 / TCP RST
   * 不覆盖：证书错误 / 401 / 4xx / 其它协议类错误（避免掩盖真实问题）
   *
   * 实现上 HarmonyOS 错误消息始终为英文（即使中文设备），
   * 不需担心本地化误判
   */
  static isTransientNetworkError(err: Error | string): boolean {
    const lower = (typeof err === 'string' ? err : err.message).toLowerCase();
    return NvHttp.isTimeoutError(lower) ||
      lower.includes('refused') ||
      lower.includes('unreachable') ||
      lower.includes('dns') ||
      lower.includes('getaddrinfo') ||
      lower.includes('connect failed') ||
      lower.includes('connection reset') ||
      lower.includes('econnreset') ||
      lower.includes('reset by peer') ||
      // 被 session.close() 级联取消的 in-flight 请求（并发超时场景常见）
      lower.includes('canceled') ||
      lower.includes('cancelled') ||
      lower.includes('1007900003');
  }

  /**
   * 构造取消错误：name='CanceledError'，调用方可用 err.name === 'CanceledError'
   * 或 (err as { isCanceled?: boolean }).isCanceled 区分用户取消与真实网络错误
   */
  static makeCanceledError(cause?: Error): Error {
    const msg = cause ? `操作已取消: ${cause.message}` : '操作已取消';
    const e: CanceledError = new Error(msg) as CanceledError;
    e.name = 'CanceledError';
    e.isCanceled = true;
    return e;
  }

  /**
   * 执行 HTTPS 请求，超时且使用自定义端口时按 Sunshine 规则（httpPort - 5）重试
   *
   * 适用场景：frp/端口转发下，缓存的 httpsPort 是服务端本地端口，与外部转发端口不同
   * 应用范围：getAppList / launchApp / resumeApp / quitApp 等仅 HTTPS 的请求
   *
   * @param path API 路径（如 'applist', 'launch'）
   * @param options 可选查询参数和超时配置
   */
  private async doHttpsRequestWithFrpRetry(path: string, options?: NvHttpPathRequestOptions): Promise<string> {
    const transferTimeout = options?.transferTimeout ?? NvHttp.READ_TIMEOUT;
    const connectTimeout = options?.connectTimeout ?? NvHttp.CONNECTION_TIMEOUT;
    return this.doHttpsWithFrpRetry(path, options?.query, (url: string): Promise<string> => {
      return this.doRequest(url, {
        transferTimeout: transferTimeout,
        useClientCert: true,
        connectTimeout: connectTimeout
      });
    }, connectTimeout);
  }

  private async doHttpsWithFrpRetry<T>(
    path: string,
    query: string | undefined,
    request: (url: string) => Promise<T>,
    connectTimeout: number = NvHttp.CONNECTION_TIMEOUT
  ): Promise<T> {
    const baseUrl = await this.getHttpsBaseUrl(connectTimeout);
    const url = this.buildUrl(baseUrl, path, query);
    try {
      return await request(url);
    } catch (err) {
      const errMsg = String(err);
      if (!this.isTimeoutError(errMsg) || this.httpPort === NvHttp.DEFAULT_HTTP_PORT) {
        throw err instanceof Error ? err : new Error(errMsg);
      }

      const guessedPort = this.httpPort - 5;
      if (guessedPort <= 0 || guessedPort === this.httpsPort) {
        throw err instanceof Error ? err : new Error(errMsg);
      }

      const usedPort = parseAddressAndPort(baseUrl.replace(/^https?:\/\//, '')).port;
      if (usedPort === guessedPort) {
        throw err instanceof Error ? err : new Error(errMsg);
      }

      console.info(`NvHttp: ${path} HTTPS 超时，尝试推算端口 ${guessedPort} (httpPort=${this.httpPort} - 5)`);
      const retryBaseUrl = `https://${formatAddressForUrl(this.address)}:${guessedPort}`;
      const retryUrl = this.buildUrl(retryBaseUrl, path, query);
      const response = await request(retryUrl);
      this.httpsPort = guessedPort;
      console.info(`NvHttp: ${path} 推算 HTTPS 端口 ${guessedPort} 连接成功，已缓存`);
      return response;
    }
  }

  private async doBinaryHttpsRequestWithFrpRetry(path: string, query?: string, timeout: number = NvHttp.CLIPBOARD_BLOB_TIMEOUT): Promise<ArrayBuffer> {
    if (!this.hasCertificateFiles()) {
      throw new Error('客户端证书缺失，无法下载剪贴板 blob');
    }

    return this.doClipboardBlobRequestWithRetry(`download ${path}`, (): Promise<ArrayBuffer> => {
      return this.doHttpsWithFrpRetry(path, query, (url: string): Promise<ArrayBuffer> => {
        return HttpClient.getBinaryWithClientCert(
          url,
          this.certFilePath,
          this.keyFilePath,
          {
            connectTimeout: NvHttp.CLIPBOARD_BLOB_CONNECT_TIMEOUT,
            transferTimeout: timeout
          }
        );
      });
    });
  }

  /**
   * 查询 Sunshine 启动前网络探测能力。旧服务端或任何探测专属错误均视为不支持。
   */
  async getNetworkProbeCapabilities(): Promise<NetworkProbeCapabilities | null> {
    if (!this.hasCertificateFiles()) {
      return null;
    }
    try {
      const response = await this.doHttpsRequestWithFrpRetry('api/network/capabilities', {
        connectTimeout: NvHttp.LONG_CONNECTION_TIMEOUT,
        transferTimeout: NvHttp.READ_TIMEOUT
      });
      const parsed: NetworkProbeCapabilitiesResponse = JSON.parse(response);
      if (parsed.version < 1 || !parsed.features ||
        parsed.features.indexOf('bandwidth-probe-v1') < 0 || !parsed.bandwidthProbe) {
        return null;
      }
      const probe = parsed.bandwidthProbe;
      if (probe.version !== 1 || !probe.endpoint || !probe.endpoint.startsWith('/') ||
        probe.endpoint.includes('://') || probe.endpoint.includes('?') || probe.endpoint.includes('#') ||
        probe.minBytes < 1 || probe.maxBytes < probe.minBytes || probe.cooldownMs < 0) {
        console.warn('NvHttp: Sunshine 返回了无效的 bandwidth probe capability');
        return null;
      }
      return probe;
    } catch (err) {
      console.info('NvHttp: Sunshine 不支持启动前带宽探测: ' + String(err));
      return null;
    }
  }

  /** 创建与共享请求池隔离的渐进探测会话。 */
  async createNetworkProbeSession(capabilities: NetworkProbeCapabilities): Promise<NetworkProbeSession> {
    if (!this.hasCertificateFiles()) {
      throw new Error('客户端证书缺失，无法执行带宽探测');
    }
    if (!capabilities.endpoint.startsWith('/') || capabilities.endpoint.includes('://') ||
      capabilities.endpoint.includes('?') || capabilities.endpoint.includes('#')) {
      throw new Error('Sunshine 带宽探测 endpoint 无效');
    }
    const baseUrl = await this.getHttpsBaseUrl(NvHttp.LONG_CONNECTION_TIMEOUT);
    const path = capabilities.endpoint.substring(1);
    const urlPrefix = this.buildUrl(baseUrl, path);
    return new NetworkProbeSession(urlPrefix, this.certFilePath, this.keyFilePath);
  }

  private async doBinaryHttpsPostWithFrpRetry(
    path: string,
    data: Uint8Array,
    query?: string,
    timeout: number = NvHttp.CLIPBOARD_BLOB_TIMEOUT,
    headers?: Record<string, string>
  ): Promise<string> {
    if (!this.hasCertificateFiles()) {
      throw new Error('客户端证书缺失，无法上传剪贴板 blob');
    }

    return this.doClipboardBlobRequestWithRetry(`upload ${path}`, (): Promise<string> => {
      return this.doHttpsWithFrpRetry(path, query, async (url: string): Promise<string> => {
        const response = await HttpClient.postBinaryWithClientCert(
          url,
          data,
          this.certFilePath,
          this.keyFilePath,
          {
            headers: headers,
            connectTimeout: NvHttp.CLIPBOARD_BLOB_CONNECT_TIMEOUT,
            transferTimeout: timeout
          }
        );
        return response.body;
      });
    });
  }

  private async doClipboardBlobRequestWithRetry<T>(label: string, request: () => Promise<T>): Promise<T> {
    let lastErr: Error | null = null;

    for (let attempt = 1; attempt <= NvHttp.CLIPBOARD_BLOB_MAX_ATTEMPTS; attempt++) {
      try {
        const result = await request();
        if (attempt > 1) {
          console.info(`NvHttp: clipboard blob ${label} 第 ${attempt} 次尝试成功`);
        }
        return result;
      } catch (err) {
        lastErr = err instanceof Error ? err : new Error(String(err));
        if (!NvHttp.isTransientNetworkError(lastErr) || attempt === NvHttp.CLIPBOARD_BLOB_MAX_ATTEMPTS) {
          throw lastErr;
        }

        console.warn(`NvHttp: clipboard blob ${label} 第 ${attempt}/${NvHttp.CLIPBOARD_BLOB_MAX_ATTEMPTS} 次失败，${NvHttp.CLIPBOARD_BLOB_RETRY_DELAY_MS}ms 后重试: ${lastErr.message}`);
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, NvHttp.CLIPBOARD_BLOB_RETRY_DELAY_MS);
        });
      }
    }

    throw lastErr ?? new Error(`clipboard blob ${label} 失败`);
  }

  /**
   * 上传剪贴板大 payload。返回扫描后的 id/mime/size，包装成 KIND_REF 由
   * 调用方负责。与 Sunshine 对接，路径固定为 /api/v1/clipboard/blob。
   */
  async uploadClipboardBlob(mime: string, data: Uint8Array): Promise<ClipboardBlobUploadResult> {
    const headers: Record<string, string> = {
      'X-Clipboard-Mime': mime
    }
    const response = await this.doBinaryHttpsPostWithFrpRetry(
      'api/v1/clipboard/blob', data, undefined, NvHttp.CLIPBOARD_BLOB_TIMEOUT, headers)
    return this.parseClipboardBlobUploadResponse(response, mime, data.length)
  }

  /**
   * 下载剪贴板 blob。Sunshine 使用 REST 风格 /api/v1/clipboard/blob/{id}。
   */
  async downloadClipboardBlob(id: string): Promise<Uint8Array> {
    const encodedId = encodeURIComponent(id);
    const data = await this.doBinaryHttpsRequestWithFrpRetry(
      `api/v1/clipboard/blob/${encodedId}`, undefined, NvHttp.CLIPBOARD_BLOB_TIMEOUT)
    return new Uint8Array(data)
  }

  private parseClipboardBlobUploadResponse(response: string, fallbackMime: string, fallbackSize: number): ClipboardBlobUploadResult {
    const trimmed = response.trim();
    if (!trimmed) {
      throw new Error('上传剪贴板 blob 返回空响应');
    }

    let parsed: ClipboardBlobUploadResponse;
    try {
      parsed = JSON.parse(trimmed) as ClipboardBlobUploadResponse;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      throw new Error(`上传剪贴板 blob 响应非 JSON: ${message}`);
    }

    const id = (parsed.id ?? '').trim();
    if (!id) {
      throw new Error('上传剪贴板 blob 响应缺少 id');
    }
    const size = Number(parsed.size);
    return {
      id: id,
      mime: parsed.mime || fallbackMime,
      size: Number.isFinite(size) && size >= 0 ? Math.floor(size) : fallbackSize
    };
  }

  /**
   * 获取服务器信息
   * 优先使用 HTTPS（如果已配对），失败后尝试 HTTP
   */
  async getServerInfo(likelyOnline: boolean = true): Promise<ServerInfo> {
    let response: string;
    const connectTimeout = likelyOnline ? NvHttp.LONG_CONNECTION_TIMEOUT : NvHttp.CONNECTION_TIMEOUT;

    try {
      // 如果有服务器证书且客户端证书文件存在（已配对），尝试 HTTPS 并使用客户端证书
      if (this.serverCert && this.hasCertificateFiles()) {
        try {
          console.debug(`NvHttp: getServerInfo 尝试 HTTPS + 客户端证书（含 frp 重试）`);
          // 复用通用 helper：超时 + 自定义端口会按 Sunshine 规则 (httpPort - 5) 重试
          response = await this.doHttpsRequestWithFrpRetry('serverinfo', { connectTimeout: connectTimeout });
        } catch (err) {
          const errMsg = String(err).toLowerCase();
          // 存在 cert 错误才降级 HTTP（超时/拒绝/DNS 等矬时错误不降级，避免错误决策）
          const isCertError = !NvHttp.isTransientNetworkError(errMsg) && (
            errMsg.includes('401') ||
            errMsg.includes('certificate') ||
            errMsg.includes('handshake') ||
            errMsg.includes('ssl') ||
            errMsg.includes('tls') ||
            /\bcode[=: ]+2305/.test(errMsg));  // HarmonyOS TLS 证书错误码系列

          if (isCertError) {
            console.warn(`NvHttp: HTTPS serverinfo 证书错误: ${err}, 降级到 HTTP`);
            const url = this.buildUrl(this.getHttpBaseUrl(), 'serverinfo');
            response = await this.doRequest(url, { connectTimeout: connectTimeout });
          } else {
            console.warn(`NvHttp: HTTPS serverinfo 失败 (非证书错误，不降级): ${err}`);
            throw new Error(`HTTPS serverinfo 失败: ${err}`);
          }
        }
      } else {
        // 未配对，使用 HTTP
        console.debug(`NvHttp: getServerInfo 使用 HTTP (serverCert=${!!this.serverCert}, hasCertFiles=${this.hasCertificateFiles()})`);
        const url = this.buildUrl(this.getHttpBaseUrl(), 'serverinfo');
        response = await this.doRequest(url, { connectTimeout: connectTimeout });
      }
    } catch (err) {
      throw new Error(`获取服务器信息失败: ${err}`);
    }

    const serverInfo = this.parseServerInfo(response);
    console.debug(`NvHttp: serverInfo - hostname=${serverInfo.hostname}, paired=${serverInfo.paired}, mac=${serverInfo.macAddress}`);

    // 缓存 HTTPS 端口
    if (serverInfo.httpsPort > 0) {
      this.httpsPort = serverInfo.httpsPort;
    }

    return serverInfo;
  }

  /**
   * 获取服务器信息（带瞬时错误重试）
   *
   * 使用场景：串流启动等"对单次失败容忍度低"的链路。
   * 普通轮询（ComputerManager polling）不应使用此方法，否则会拖延状态判定。
   *
   * 重试策略：
   * - 仅对瞬时网络错误（NvHttp.isTransientNetworkError）重试
   * - 硬错误（cert/401/协议错误）立即抛出，避免掩盖真实问题
   * - 每次重试前/sleep 后检查 isCancelled，及时响应取消
   *
   * @param opts.maxAttempts 最大尝试次数，默认 3
   * @param opts.delayMs 重试间隔（ms），默认 1500
   * @param opts.isCancelled 取消检查回调，返回 true 时立即抛出 lastErr
   * @param opts.onRetry (attempt, maxAttempts, err) → 业务层可上报进度/UI 文案
   */
  async getServerInfoRobust(opts?: GetServerInfoRobustOptions): Promise<ServerInfo> {
    const maxAttempts = opts?.maxAttempts ?? NvHttp.DEFAULT_ROBUST_MAX_ATTEMPTS;
    const delayMs = opts?.delayMs ?? NvHttp.DEFAULT_ROBUST_DELAY_MS;
    const isCancelled = opts?.isCancelled ?? ((): boolean => false);
    const onRetry = opts?.onRetry;

    let lastErr: Error | null = null;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        const result = await this.getServerInfo();
        if (attempt > 1) {
          console.info(`NvHttp.getServerInfoRobust: 第 ${attempt} 次尝试成功`);
        }
        return result;
      } catch (err) {
        lastErr = err instanceof Error ? err : new Error(String(err));
        const transient = NvHttp.isTransientNetworkError(lastErr);
        // 用户取消 → 抛出独立的取消错误，调用方可与网络错误区分
        if (isCancelled()) {
          throw NvHttp.makeCanceledError(lastErr);
        }
        // 硬错误 / 已达上限 → 抛出原错误
        if (!transient || attempt === maxAttempts) {
          throw lastErr;
        }
        console.warn(`NvHttp.getServerInfoRobust: 第 ${attempt}/${maxAttempts} 次失败（瞬时错误），${delayMs}ms 后重试: ${lastErr.message}`);
        if (onRetry) {
          onRetry(attempt, maxAttempts, lastErr);
        }
        await new Promise<void>(resolve => setTimeout(resolve, delayMs));
        // sleep 期间被取消的常见情况
        if (isCancelled()) {
          throw NvHttp.makeCanceledError(lastErr);
        }
      }
    }
    // 不可达：循环要么 return 要么 throw，但保留作为类型守卫
    throw lastErr ?? new Error('获取服务器信息失败');
  }

  /**
   * 获取应用列表（仅 HTTPS，匹配 Android 行为）
   * HTTPS 端口通过 getHttpsBaseUrl() 自动解析；超时时按 frp 规则重试
   */
  async getAppList(): Promise<AppEntry[]> {
    console.info(`NvHttp.getAppList: serverCert=${this.serverCert ? '有(长度' + this.serverCert.length + ')' : '无'}, hasCertFiles=${this.hasCertificateFiles()}`);
    // 与 Android 一致：只使用 HTTPS + 客户端证书，不 fallback 到 HTTP
    const response = await this.doHttpsRequestWithFrpRetry('applist');
    console.info(`NvHttp.getAppList: HTTPS 请求成功`);
    return this.parseAppList(response);
  }

  /**
   * 取消配对
   */
  async unpair(): Promise<void> {
    const url = this.buildUrl(this.getHttpBaseUrl(), 'unpair');
    await this.doRequest(url);
  }

  /**
   * 启动应用/游戏
   */
  async launchApp(appId: number, config: LaunchConfig): Promise<string> {
    // 确保 appId 一致
    const effectiveAppId = config.appId || appId;
    const query = this.buildLaunchQuery(effectiveAppId, config, 'launch');
    const url = this.buildUrl(await this.getHttpsBaseUrl(), 'launch', query);

    // 启动可能需要较长时间，使用客户端证书
    const response = await this.doRequest(url, { transferTimeout: 60000, useClientCert: true });
    console.info(`NvHttp: launchApp 响应: ${response}`);

    // 检查是否成功
    const gamesession = XmlUtil.getValue(response, 'gamesession');
    if (gamesession === '0') {
      throw new Error('启动应用失败');
    }

    const sessionUrl = XmlUtil.getValue(response, 'sessionUrl0') || '';
    console.info(`NvHttp: launchApp gamesession=${gamesession}, sessionUrl0=${sessionUrl}`);
    return sessionUrl;
  }

  /**
   * 恢复会话
   * 注意：resume 与 launch 使用相同的完整参数列表，只是 verb 不同
   */
  async resumeApp(config: LaunchConfig): Promise<string> {
    // 使用与 launch 相同的完整参数列表
    const query = this.buildLaunchQuery(config.appId, config, 'resume');
    const url = this.buildUrl(await this.getHttpsBaseUrl(), 'resume', query);

    console.info(`NvHttp: resumeApp URL: ${url}`);

    // 使用客户端证书
    const response = await this.doRequest(url, { transferTimeout: 60000, useClientCert: true });

    const resume = XmlUtil.getValue(response, 'resume');
    if (resume === '0') {
      throw new Error('恢复会话失败');
    }

    return XmlUtil.getValue(response, 'sessionUrl0') || '';
  }

  /**
   * 退出应用
   */
  async quitApp(): Promise<boolean> {
    const url = this.buildUrl(await this.getHttpsBaseUrl(), 'cancel');
    // 服务端处理 /cancel 需要等待应用进程退出（默认5秒超时），使用较长超时避免客户端提前放弃
    const response = await this.doRequest(url, { transferTimeout: 60000, useClientCert: true });

    const cancel = XmlUtil.getValue(response, 'cancel');
    return cancel !== '0';
  }

  /**
   * 动态调整码率
   * @param bitrateKbps 目标码率（kbps）
   * @returns 是否成功
   */
  async setBitrate(bitrateKbps: number): Promise<boolean> {
    try {
      const url = this.buildUrl(await this.getHttpsBaseUrl(), 'bitrate', `bitrate=${bitrateKbps}`);
      // 使用客户端证书
      const response = await this.doRequest(url, { useClientCert: true });
      const result = XmlUtil.getValue(response, 'bitrate');
      return result === '1';
    } catch (err) {
      return false;
    }
  }

  /**
   * 发送超级指令 (Sunshine 功能)
   * @param cmdId 指令 ID
   * @returns 是否成功
   */
  async sendSuperCmd(cmdId: string): Promise<boolean> {
    try {
      const url = this.buildUrl(await this.getHttpsBaseUrl(), 'supercmd', `cmdId=${cmdId}`);
      const response = await this.doRequest(url, { useClientCert: true });
      const result = XmlUtil.getValue(response, 'supercmd');
      return result !== '0';
    } catch (err) {
      return false;
    }
  }

  /**
   * 休眠主机
   */
  async pcSleep(): Promise<boolean> {
    try {
      const url = this.buildUrl(await this.getHttpsBaseUrl(), 'pcsleep');
      // 使用客户端证书
      const response = await this.doRequest(url, { useClientCert: true });
      const result = XmlUtil.getValue(response, 'pcsleep');
      return result !== '0';
    } catch (err) {
      console.warn('NvHttp: 休眠主机失败', err);
      return false;
    }
  }

  /**
   * 旋转显示器方向 (Sunshine 功能)
   * 
   * 通知服务端同步修改分辨率方向，用于屏幕旋转同步
   * 
   * @param angle 旋转角度：0 表示横屏，90 表示竖屏
   * @param displayName 可选的显示器名称
   * @returns 是否成功
   */
  async rotateDisplay(angle: number, displayName?: string): Promise<boolean> {
    try {
      let query = `angle=${angle}`;
      if (displayName) {
        query += `&display_name=${encodeURIComponent(displayName)}`;
      }
      
      const url = this.buildUrl(await this.getHttpsBaseUrl(), 'rotate-display', query);
      const response = await this.doRequest(url, { useClientCert: true });
      
      // 解析 JSON 响应
      const json = JSON.parse(response) as RotateDisplayResponse;
      
      const statusCode = json.status_code ?? 0;
      const success = json.success ?? false;
      
      if (statusCode !== 200 || !success) {
        const errorMsg = json.status_message ?? '未知错误';
        console.warn(`NvHttp: 旋转显示失败: ${errorMsg}`);
        return false;
      }
      
      console.info(`NvHttp: 显示旋转成功，角度=${angle}`);
      return true;
    } catch (err) {
      console.warn(`NvHttp: 旋转显示请求失败: ${err}`);
      return false;
    }
  }

  /**
   * 获取服务器可用的显示器列表 (Sunshine 专用功能)
   * @returns 显示器信息列表
   */
  async getDisplays(): Promise<DisplayInfo[]> {
    const url = this.buildUrl(await this.getHttpsBaseUrl(), 'displays');
    // 使用客户端证书
    const response = await this.doRequest(url, {
      transferTimeout: NvHttp.LONG_CONNECTION_TIMEOUT,
      useClientCert: true
    });
    
    // 解析 JSON 响应
    const json = JSON.parse(response) as DisplaysResponse;
    
    if (json.status_code !== 200) {
      throw new Error(`获取显示器列表失败: ${json.status_message || '未知错误'}`);
    }
    
    const displays: DisplayInfo[] = [];
    if (json.displays && Array.isArray(json.displays)) {
      for (let i = 0; i < json.displays.length; i++) {
        const displayObj = json.displays[i];
        const friendlyName = displayObj.friendly_name || displayObj.display_name || `显示器 ${i + 1}`;
        const guid = displayObj.device_id || '';
        displays.push({ index: i, name: friendlyName, guid: guid });
      }
    }
    
    console.info(`NvHttp: 获取到 ${displays.length} 个显示器`);
    return displays;
  }

  /**
   * 获取应用图标
   * 使用 HttpClient 支持 HTTPS 和自签名证书
   */
  async getAppAsset(appId: number): Promise<ArrayBuffer | null> {
    const url = this.buildUrl(await this.getHttpsBaseUrl(), 'appasset',
      `appid=${appId}&AssetType=2&AssetIdx=0`);

    try {
      console.info(`NvHttp: 获取应用图标 appId=${appId}, url=${url}`);
      let data: ArrayBuffer;

      if (this.hasCertificateFiles()) {
        // 使用客户端证书
        data = await HttpClient.getBinaryWithClientCert(
          url,
          this.certFilePath,
          this.keyFilePath,
          {
            connectTimeout: NvHttp.CONNECTION_TIMEOUT,
            transferTimeout: NvHttp.READ_TIMEOUT
          }
        );
      } else {
        // 不使用客户端证书，但跳过服务器证书验证
        data = await HttpClient.getBinary(url, {
          skipServerValidation: true,
          connectTimeout: NvHttp.CONNECTION_TIMEOUT,
          transferTimeout: NvHttp.READ_TIMEOUT
        });
      }

      console.info(`NvHttp: 获取应用图标成功 appId=${appId}, 大小=${data.byteLength} 字节`);
      return data;
    } catch (err) {
      console.warn(`NvHttp: 获取应用图标失败 appId=${appId}`, err);
    }
    return null;
  }

  /**
   * 获取应用图标并缓存到本地文件
   * @param appId 应用 ID
   * @returns 本地文件路径，如果失败返回 null
   */
  async getAppAssetCached(appId: number): Promise<string | null> {
    if (!this.context) {
      console.warn('NvHttp: 无法缓存图标，context 未设置');
      return null;
    }

    // 缓存目录
    const cacheDir = this.context.cacheDir + '/app_icons';
    // 将地址中的特殊字符替换为下划线，避免文件名无效（如 IPv6 地址中的冒号）
    const safeAddress = this.address.replace(/[:\[\]\/\\]/g, '_');
    const cachedPath = `${cacheDir}/${safeAddress}_${appId}.png`;

    // 检查是否已缓存
    try {
      if (fileIo.accessSync(cachedPath)) {
        console.info(`NvHttp: 使用缓存的图标 ${cachedPath}`);
        return cachedPath;
      }
    } catch (err) {
      // 文件不存在，继续下载
    }

    // 下载图标
    const data = await this.getAppAsset(appId);
    if (!data || data.byteLength < 100) {
      console.warn(`NvHttp: 图标数据无效 appId=${appId}, size=${data?.byteLength}`);
      return null;
    }

    // 确保缓存目录存在
    try {
      if (!fileIo.accessSync(cacheDir)) {
        fileIo.mkdirSync(cacheDir);
      }
    } catch (err) {
      try {
        fileIo.mkdirSync(cacheDir);
      } catch (mkdirErr) {
        console.warn(`NvHttp: 创建缓存目录失败`, mkdirErr);
      }
    }

    // 写入文件
    try {
      const file = fileIo.openSync(cachedPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, data);
      fileIo.closeSync(file);
      console.info(`NvHttp: 图标已缓存到 ${cachedPath}`);
      return cachedPath;
    } catch (err) {
      console.error(`NvHttp: 缓存图标失败`, err);
      return null;
    }
  }

  /**
   * 获取应用图标 URL（用于 Image 组件直接加载）
   * 使用 HTTP 端口，因为 Image 组件无法处理自签名 HTTPS 证书
   * @param appId 应用 ID
   * @returns 图标 URL
   */
  getBoxArtUrl(appId: number): string {
    return this.buildUrl(this.getHttpBaseUrl(), 'appasset',
      `appid=${appId}&AssetType=2&AssetIdx=0`);
  }

  /**
   * 构建启动查询参数
   */
  private buildLaunchQuery(appId: number, config: LaunchConfig, verb: string): string {
    // 处理 FPS：NVIDIA 服务器软件在 FPS > 60 时需要设为 0 以避免 SOPS 默认到 720p60
    // 但 Sunshine 不需要这个处理，我们检测 appVersion 是否包含 "-1" 来判断是否是 Sunshine
    let fps = config.fps;

    const params: string[] = [
      `appid=${appId}`,
      `mode=${config.width}x${config.height}x${fps}`,
      `additionalStates=1`,
      `sops=${config.sops ? 1 : 0}`,
      `resolutionScale=100`,  // 服务端分辨率缩放，100 表示不缩放
      `rikey=${config.riKey}`,
      `rikeyid=${config.riKeyId}`,
      `localAudioPlayMode=${config.localAudio ? 1 : 0}`,
      `surroundAudioInfo=${config.audioConfig}`,
      `remoteControllersBitmap=0`,
      `gcmap=0`,
      `gcpersist=0`,          // 断开连接后不保留手柄状态
    ];

    // 添加 Sunshine 显示器选择参数
    if (config.displayGuid && config.displayGuid.length > 0) {
      params.push(`display_name=${encodeURIComponent(config.displayGuid)}`);
      console.info(`NvHttp: 使用指定显示器: ${config.displayGuid}`);
    }

    if (config.enableHdr) {
      // hdrMode: 0=SDR, 1=HDR10(PQ), 2=HLG
      // 对应 Sunshine 的 dynamicRange 参数
      const hdrModeValue = config.hdrMode ?? 1;  // 默认 HDR10
      params.push(`hdrMode=${hdrModeValue}`);
      params.push('clientHdrCapVersion=0');
      params.push('clientHdrCapSupportedFlagsInUint32=0');
      // HLG 模式不需要静态元数据，但为了兼容性仍然发送
      params.push('clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1');
      params.push('clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0');
    }

    // 客户端屏幕亮度范围（用于服务端 HDR tone mapping）
    const minBrightness = config.minBrightness ?? DEFAULT_HDR_MIN_BRIGHTNESS_NITS;
    const maxBrightness = config.maxBrightness ?? 500;
    const maxAvgBrightness = config.maxAverageBrightness ?? 200;
    params.push(`minBrightness=${minBrightness}`);
    params.push(`maxBrightness=${maxBrightness}`);
    params.push(`maxAverageBrightness=${maxAvgBrightness}`);

    // 屏幕组合模式（Sunshine 多显示器管理）
    if (config.screenCombinationMode !== undefined && config.screenCombinationMode !== -1) {
      params.push(`customScreenMode=${config.screenCombinationMode}`);
    }

    console.info(`NvHttp: buildLaunchQuery: ${params.join('&')}`);
    return params.join('&');
  }

  getServerCert(): string {
    return this.serverCert || '';
  }

  private parseServerInfo(xml: string): ServerInfo {
    return {
      hostname: XmlUtil.getValue(xml, 'hostname') || 'UNKNOWN',
      uniqueId: XmlUtil.getValue(xml, 'uniqueid'),
      macAddress: XmlUtil.getValue(xml, 'mac'),
      paired: XmlUtil.getValue(xml, 'PairStatus') === '1',
      currentGame: XmlUtil.getIntValue(xml, 'currentgame', 0),
      serverCodecModeSupport: XmlUtil.getIntValue(xml, 'ServerCodecModeSupport', 0),
      gpuType: XmlUtil.getValue(xml, 'gputype'),
      gfeVersion: XmlUtil.getValue(xml, 'GfeVersion'),
      appVersion: XmlUtil.getValue(xml, 'appversion'),
      maxLumaPixelsHEVC: XmlUtil.getIntValue(xml, 'MaxLumaPixelsHEVC', 0),
      serverCapabilities: XmlUtil.getValue(xml, 'ServerCapabilities'),
      httpsPort: XmlUtil.getIntValue(xml, 'HttpsPort', NvHttp.DEFAULT_HTTPS_PORT),
      externalPort: XmlUtil.getIntValue(xml, 'ExternalPort', NvHttp.DEFAULT_HTTP_PORT),
      localAddress: XmlUtil.getValue(xml, 'LocalIP'),
      externalAddress: XmlUtil.getValue(xml, 'ExternalIP')
    };
  }

  private parseAppList(xml: string): AppEntry[] {
    const apps: AppEntry[] = [];
    const appRegex = /<App>([\s\S]*?)<\/App>/g;
    let match: RegExpExecArray | null = null;

    while ((match = appRegex.exec(xml)) !== null) {
      const appXml: string = match[1];

      const id = XmlUtil.getIntValue(appXml, 'ID', 0);
      const name = XmlUtil.getValue(appXml, 'AppTitle');
      const isRunningStr = XmlUtil.getValue(appXml, 'IsRunning');
      const isRunning = isRunningStr === '1';
      const isHdrSupported = XmlUtil.getValue(appXml, 'IsHdrSupported') === '1';

      // 解析超级指令列表 (Sunshine 功能)
      let superCmdsStr = XmlUtil.getValue(appXml, 'SuperCmds');
      let cmdList: SuperCmd[] | undefined = undefined;
      if (superCmdsStr && superCmdsStr !== 'null') {
        try {
          // 解码 HTML 实体（服务器返回的 JSON 中引号被编码为 &quot;）
          superCmdsStr = NvHttp.decodeHtmlEntities(superCmdsStr);
          cmdList = JSON.parse(superCmdsStr) as SuperCmd[];
        } catch {
          // 解析失败，忽略
        }
      }

      const entry: AppEntry = {
        id: id,
        name: name,
        isRunning: isRunning,
        isHdrSupported: isHdrSupported,
        cmdList: cmdList
      };
      apps.push(entry);
    }

    return apps;
  }

  /**
   * 解码 HTML 实体
   */
  private static decodeHtmlEntities(text: string): string {
    let result = text
      .replace(/&quot;/g, '"')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&apos;/g, "'");
    
    // 解码数字实体 &#xxx;
    const numericEntityRegex = /&#(\d+);/g;
    let match: RegExpExecArray | null = null;
    while ((match = numericEntityRegex.exec(text)) !== null) {
      const code = parseInt(match[1]);
      result = result.replace(match[0], String.fromCharCode(code));
    }
    
    return result;
  }

  /**
   * POST /ai/completions — 调用 Sunshine LLM 代理端点（OpenAI 兼容）
   * @param messages OpenAI 格式的消息数组
   * @param maxTokens 最大生成 token 数
   * @returns 助手回复文本
   */
  async aiCompletion(messages: AiMessage[], maxTokens: number = 4096): Promise<string> {
    const baseUrl = await this.getHttpsBaseUrl();
    const url = `${baseUrl}/ai/completions`;

    const body = JSON.stringify({
      messages: messages,
      max_tokens: maxTokens,
    });

    if (!this.certFilePath || !this.keyFilePath) {
      throw new Error('客户端证书不可用，无法调用 AI 端点');
    }

    const response = await HttpClient.postWithClientCert(url, body, this.certFilePath, this.keyFilePath, {
      transferTimeout: 120000
    });

    if (response.statusCode === 403) {
      throw new Error('AI 代理未启用，请在 Sunshine 设置中配置 LLM API');
    }
    if (response.statusCode === 404) {
      throw new Error('当前 Sunshine 版本不支持 AI 功能，请升级到基地阳光最新版');
    }
    if (response.statusCode !== 200) {
      throw new Error(`AI 服务异常 (HTTP ${response.statusCode})，请检查 Sunshine 的 LLM 配置`);
    }

    // 解析 OpenAI 兼容响应
    const result = JSON.parse(response.body) as AiCompletionResponse;
    if (result.choices && result.choices.length > 0) {
      return result.choices[0].message?.content ?? '';
    }
    if (result.error) {
      throw new Error(`AI 错误: ${result.error.message ?? JSON.stringify(result.error)}`);
    }
    return '';
  }

  /**
   * 轻量级检测 AI 代理是否可用（不消耗 token）
   * 发送一个空 messages 请求，仅检查 HTTP 状态码
   */
  async checkAiAvailable(): Promise<boolean> {
    const baseUrl = await this.getHttpsBaseUrl();
    const url = `${baseUrl}/ai/completions`;
    const body = JSON.stringify({ messages: [], max_tokens: 1 });

    if (!this.certFilePath || !this.keyFilePath) {
      return false;
    }

    try {
      const response = await HttpClient.postWithClientCert(url, body, this.certFilePath, this.keyFilePath, {
        transferTimeout: 5000
      });
      // 403 = AI 未启用, 404 = 版本不支持
      // 200 或其他非 403/404 状态码说明 AI 代理已启用（即使 LLM 端可能报错）
      return response.statusCode !== 403 && response.statusCode !== 404;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 智能码率 (ABR) API
  // ---------------------------------------------------------------------------

  /**
   * 查询服务端 ABR 能力
   */
  async getAbrCapabilities(): Promise<AbrCapabilities> {
    try {
      const baseUrl = await this.getHttpsBaseUrl();
      const url = `${baseUrl}/api/abr/capabilities`;
      const response = await this.doRequest(url, { useClientCert: true });
      return JSON.parse(response) as AbrCapabilities;
    } catch {
      return { supported: false, version: 0, features: [] };
    }
  }

  /**
   * 通知服务端启用/关闭智能码率
   */
  async setAbrMode(config: AbrConfig): Promise<boolean> {
    try {
      const baseUrl = await this.getHttpsBaseUrl();
      const url = `${baseUrl}/api/abr`;

      if (!this.certFilePath || !this.keyFilePath) return false;

      const response = await HttpClient.postWithClientCert(
        url,
        JSON.stringify(config),
        this.certFilePath,
        this.keyFilePath,
        { transferTimeout: 5000 }
      );
      return response.statusCode === 200;
    } catch {
      return false;
    }
  }

  /**
   * 上报客户端网络指标（每秒调用）
   */
  async reportNetworkFeedback(feedback: NetworkFeedback): Promise<AbrAction | null> {
    try {
      const baseUrl = await this.getHttpsBaseUrl();
      const url = `${baseUrl}/api/abr/feedback`;

      if (!this.certFilePath || !this.keyFilePath) return null;

      const response = await HttpClient.postWithClientCert(
        url,
        JSON.stringify(feedback),
        this.certFilePath,
        this.keyFilePath,
        { transferTimeout: 3000 }
      );
      if (response.statusCode === 200) {
        return JSON.parse(response.body) as AbrAction;
      }
      return null;
    } catch {
      return null;
    }
  }

}

// ---------------------------------------------------------------------------
// ABR 类型定义
// ---------------------------------------------------------------------------

export interface AbrCapabilities {
  supported: boolean;
  version: number;
  features: string[];
}

export interface AbrConfig {
  enabled: boolean;
  minBitrate: number;
  maxBitrate: number;
  mode: string;  // 'quality' | 'balanced' | 'lowLatency'
}

export interface NetworkFeedback {
  packetLoss: number;
  rttMs: number;
  decodeFps: number;
  droppedFrames: number;
  currentBitrate: number;
  systemRttMs?: number;
  systemUpBufferDelayMs?: number;
  systemUpBufferCongestionPercent?: number;
  systemUpBandwidthBps?: number;
  systemDownBandwidthBps?: number;
  systemNetworkScene?: string;
  systemRecommendedAction?: string;
  weakSignalStartSec?: number;
  weakSignalDurationSec?: number;
}

export interface AbrAction {
  newBitrate?: number;
  bitrateApplied?: boolean;
  bitrateApplyError?: string;
  reason?: string;
}

export interface AppEntry {
  id: number;
  name: string;
  isRunning: boolean;
  isHdrSupported: boolean;
  cmdList?: SuperCmd[];  // 超级指令列表 (Sunshine 功能)
}

/**
 * 超级指令 (Sunshine 功能)
 */
export interface SuperCmd {
  id: string;
  name: string;
}

export interface LaunchConfig {
  appId: number;
  width: number;
  height: number;
  fps: number;
  bitrate: number;
  sops: boolean;
  localAudio: boolean;
  riKey: string;
  riKeyId: number;
  audioConfig: string;
  enableHdr?: boolean;
  hdrMode?: number;  // 0=SDR, 1=HDR10(PQ), 2=HLG
  displayGuid?: string;  // Sunshine 显示器 GUID
  minBrightness?: number;       // 客户端屏幕最小亮度 (nits)
  maxBrightness?: number;       // 客户端屏幕最大亮度 (nits)
  maxAverageBrightness?: number; // 客户端屏幕最大平均亮度 (nits)
  screenCombinationMode?: number; // 屏幕组合模式 (-1=主机默认, 0=不修改, 1=确保开启, 2=主屏, 3=仅此屏)
}

/** OpenAI 兼容消息格式 */
export interface AiMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

interface AiCompletionChoice {
  message?: AiMessage;
  finish_reason?: string;
}

interface AiCompletionError {
  message?: string;
  type?: string;
}

interface AiCompletionResponse {
  choices?: AiCompletionChoice[];
  error?: AiCompletionError;
}
