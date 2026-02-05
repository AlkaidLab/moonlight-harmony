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
import { HttpClient } from '../utils/HttpClient';
import { XmlUtil } from '../utils/XmlUtil';
import { StringUtil } from '../utils/StringUtil';
import { CryptoUtil } from '../utils/CryptoUtil';

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

export class NvHttp {
  private address: string;
  private serverCert: string | null;
  private uniqueId: string;
  private clientName: string;
  private context: common.UIAbilityContext | null = null;
  private certFilePath: string = '';
  private keyFilePath: string = '';

  // 端口常量
  static readonly DEFAULT_HTTPS_PORT = 47984;
  static readonly DEFAULT_HTTP_PORT = 47989;
  // 缩短超时时间以加快离线主机的检测（从 5 秒减少到 3 秒）
  static readonly CONNECTION_TIMEOUT = 3000;
  static readonly LONG_CONNECTION_TIMEOUT = 5000;
  static readonly READ_TIMEOUT = 5000;

  // 缓存的 HTTPS 端口
  private httpsPort: number = 0;
  // 自定义的 HTTP 端口
  private httpPort: number = NvHttp.DEFAULT_HTTP_PORT;

  // 全局唯一 ID 缓存（应用生命周期内保持一致）
  private static cachedUniqueId: string | null = null;
  // 全局客户端名称缓存（使用设备名称）
  private static cachedClientName: string | null = null;

  constructor(address: string, serverCert: string | null, context?: common.UIAbilityContext, httpPort?: number) {
    // 解析地址中可能包含的端口号
    const parsedHost = this.parseAddressHost(address);
    const parsedPort = this.parseAddressPort(address);
    this.address = parsedHost;
    this.serverCert = serverCert;
    // 优先使用显式传入的端口，其次使用地址中解析的端口，最后使用默认端口
    this.httpPort = httpPort || parsedPort || NvHttp.DEFAULT_HTTP_PORT;
    if (context) {
      this.context = context;
      this.certFilePath = context.filesDir + '/client_cert.pem';
      this.keyFilePath = context.filesDir + '/client_key.pem';
    }
    this.uniqueId = this.getOrCreateUniqueId(context);
    this.clientName = this.getClientName();
  }
  
  /**
   * 从地址字符串中解析主机部分
   */
  private parseAddressHost(addressInput: string): string {
    const trimmed = addressInput.trim();
    
    // 检查是否为 IPv6 地址
    if (trimmed.startsWith('[')) {
      // 格式: [::1] 或 [::1]:47989
      const closeBracket = trimmed.indexOf(']');
      if (closeBracket > 0) {
        return trimmed.substring(1, closeBracket);
      }
    }
    
    // IPv4 或主机名
    const colonIndex = trimmed.indexOf(':');
    // 只有一个冒号，说明是端口分隔符（IPv6 有多个冒号）
    if (colonIndex > 0 && trimmed.indexOf(':', colonIndex + 1) === -1) {
      return trimmed.substring(0, colonIndex);
    }
    
    return trimmed;
  }
  
  /**
   * 从地址字符串中解析端口部分
   */
  private parseAddressPort(addressInput: string): number | undefined {
    const trimmed = addressInput.trim();
    
    // 检查是否为 IPv6 地址
    if (trimmed.startsWith('[')) {
      // 格式: [::1]:47989
      const closeBracket = trimmed.indexOf(']');
      if (closeBracket > 0 && closeBracket < trimmed.length - 1 && trimmed.charAt(closeBracket + 1) === ':') {
        const portStr = trimmed.substring(closeBracket + 2);
        const port = parseInt(portStr);
        if (port > 0 && port <= 65535) {
          return port;
        }
      }
      return undefined;
    }
    
    // IPv4 或主机名
    const colonIndex = trimmed.indexOf(':');
    // 只有一个冒号，说明是端口分隔符（IPv6 有多个冒号）
    if (colonIndex > 0 && trimmed.indexOf(':', colonIndex + 1) === -1) {
      const portStr = trimmed.substring(colonIndex + 1);
      const port = parseInt(portStr);
      if (port > 0 && port <= 65535) {
        return port;
      }
    }
    
    return undefined;
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
   * 获取格式化的地址（IPv6 需要加方括号）
   */
  private getFormattedAddress(): string {
    // 如果是 IPv6 地址且没有方括号，添加方括号
    if (this.address.includes(':') && !this.address.startsWith('[')) {
      return `[${this.address}]`;
    }
    return this.address;
  }

  /**
   * 获取 HTTP 基础 URL
   */
  private getHttpBaseUrl(): string {
    return `http://${this.getFormattedAddress()}:${this.httpPort}`;
  }

  /**
   * 获取 HTTPS 基础 URL
   * 端口优先级：
   * 1. 服务器返回的 httpsPort（serverInfo 中获取）
   * 2. 根据 httpPort 计算的端口（httpPort - 5）
   * 3. 默认端口 47984
   */
  private getHttpsBaseUrl(): string {
    let port: number;
    if (this.httpsPort > 0) {
      // 使用从服务器获取的 HTTPS 端口
      port = this.httpsPort;
    } else if (this.httpPort !== NvHttp.DEFAULT_HTTP_PORT) {
      // 自定义 HTTP 端口，计算 HTTPS 端口 (HTTP 端口 - 5)
      port = this.httpPort - 5;
      console.info(`NvHttp: 使用自定义 HTTPS 端口 ${port} (httpPort=${this.httpPort})`);
    } else {
      // 使用默认端口
      port = NvHttp.DEFAULT_HTTPS_PORT;
    }
    return `https://${this.getFormattedAddress()}:${port}`;
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
   * @param timeout 超时时间（毫秒）
   * @param useClientCert 是否使用客户端证书（HTTPS请求需要）
   */
  private async doRequest(url: string, timeout: number = NvHttp.READ_TIMEOUT, useClientCert: boolean = false): Promise<string> {
    console.info(`NvHttp: 请求 ${url}`);

    if (useClientCert && this.certFilePath && this.keyFilePath) {
      return HttpClient.getWithClientCert(url, this.certFilePath, this.keyFilePath, {
        connectTimeout: NvHttp.CONNECTION_TIMEOUT,
        transferTimeout: timeout
      });
    } else {
      return HttpClient.get(url, {
        connectTimeout: NvHttp.CONNECTION_TIMEOUT,
        transferTimeout: timeout
      });
    }
  }

  /**
   * 获取服务器信息
   * 优先使用 HTTPS（如果已配对），失败后尝试 HTTP
   */
  async getServerInfo(likelyOnline: boolean = true): Promise<ServerInfo> {
    let response: string;

    try {
      // 如果有服务器证书且客户端证书文件存在（已配对），尝试 HTTPS 并使用客户端证书
      if (this.serverCert && this.hasCertificateFiles()) {
        try {
          console.info(`NvHttp: getServerInfo 尝试 HTTPS + 客户端证书`);
          const url = this.buildUrl(this.getHttpsBaseUrl(), 'serverinfo');
          response = await this.doRequest(url, NvHttp.READ_TIMEOUT, true);
        } catch (err) {
          console.warn(`NvHttp: HTTPS serverinfo 失败: ${err}, 降级到 HTTP`);
          // 证书可能不匹配，降级到 HTTP
          const url = this.buildUrl(this.getHttpBaseUrl(), 'serverinfo');
          response = await this.doRequest(url);
        }
      } else {
        // 未配对，使用 HTTP
        console.info(`NvHttp: getServerInfo 使用 HTTP (serverCert=${!!this.serverCert}, hasCertFiles=${this.hasCertificateFiles()})`);
        const url = this.buildUrl(this.getHttpBaseUrl(), 'serverinfo');
        response = await this.doRequest(url);
      }
    } catch (err) {
      throw new Error(`获取服务器信息失败: ${err}`);
    }

    const serverInfo = this.parseServerInfo(response);
    console.info(`NvHttp: serverInfo - hostname=${serverInfo.hostname}, paired=${serverInfo.paired}, mac=${serverInfo.macAddress}`);

    // 缓存 HTTPS 端口
    if (serverInfo.httpsPort > 0) {
      this.httpsPort = serverInfo.httpsPort;
    }

    return serverInfo;
  }

  /**
   * 获取应用列表
   */
  async getAppList(): Promise<AppEntry[]> {
    const url = this.buildUrl(this.getHttpsBaseUrl(), 'applist');
    console.info(`NvHttp.getAppList: url=${url}, serverCert=${this.serverCert ? '有(长度' + this.serverCert.length + ')' : '无'}, hasCertFiles=${this.hasCertificateFiles()}`);

    try {
      // HTTPS 请求需要使用客户端证书
      const response = await this.doRequest(url, NvHttp.READ_TIMEOUT, true);
      console.info(`NvHttp.getAppList: HTTPS 请求成功`);
      return this.parseAppList(response);
    } catch (err) {
      console.warn(`NvHttp: HTTPS applist 失败，尝试 HTTP: ${err}`);
      // 如果 HTTPS 失败，尝试 HTTP（不需要证书）
      const httpUrl = this.buildUrl(this.getHttpBaseUrl(), 'applist');
      const response = await this.doRequest(httpUrl);
      return this.parseAppList(response);
    }
  }

  /**
   * 配对 - 需要用户在主机上输入 PIN 码
   */
  async pair(pin: string): Promise<void> {
    // 配对始终使用 HTTP（未配对状态）
    const baseUrl = this.getHttpBaseUrl();

    // 第一步：发送 salt 和 clientcert，获取服务器证书
    const salt = this.generateRandomHex(16);
    const clientCert = await this.getClientCertificate();

    const step1Url = this.buildUrl(baseUrl, 'pair',
      `devicename=${encodeURIComponent(this.clientName)}&updateState=1&phrase=getservercert&salt=${salt}&clientcert=${clientCert}`);

    console.info('NvHttp: 配对步骤1 - 获取服务器证书');
    const step1Response = await this.doRequest(step1Url);

    // 解析响应检查状态
    if (!this.checkPairStatus(step1Response)) {
      throw new Error('配对步骤1失败');
    }

    // TODO: 完成后续配对步骤（需要加密库支持）
    // 步骤2: 发送 clientchallenge
    // 步骤3: 发送 serverchallengeresp
    // 步骤4: 发送 clientpairingsecret

    console.warn('NvHttp: 配对功能尚未完全实现（需要加密库支持）');
  }

  /**
   * 检查配对状态
   */
  private checkPairStatus(xml: string): boolean {
    const paired = XmlUtil.getValue(xml, 'paired');
    return paired === '1';
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
    const url = this.buildUrl(this.getHttpsBaseUrl(), 'launch', query);

    // 启动可能需要较长时间，使用客户端证书
    const response = await this.doRequest(url, 60000, true);
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
    const url = this.buildUrl(this.getHttpsBaseUrl(), 'resume', query);

    console.info(`NvHttp: resumeApp URL: ${url}`);

    // 使用客户端证书
    const response = await this.doRequest(url, 60000, true);

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
    const url = this.buildUrl(this.getHttpsBaseUrl(), 'cancel');
    // 使用客户端证书
    const response = await this.doRequest(url, NvHttp.READ_TIMEOUT, true);

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
      const url = this.buildUrl(this.getHttpsBaseUrl(), 'bitrate', `bitrate=${bitrateKbps}`);
      // 使用客户端证书
      const response = await this.doRequest(url, NvHttp.READ_TIMEOUT, true);
      const result = XmlUtil.getValue(response, 'bitrate');
      return result !== '0';
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
      const url = this.buildUrl(this.getHttpsBaseUrl(), 'supercmd', `cmdId=${cmdId}`);
      const response = await this.doRequest(url, NvHttp.READ_TIMEOUT, true);
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
      const url = this.buildUrl(this.getHttpsBaseUrl(), 'pcsleep');
      // 使用客户端证书
      const response = await this.doRequest(url, NvHttp.READ_TIMEOUT, true);
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
      
      const url = this.buildUrl(this.getHttpsBaseUrl(), 'rotate-display', query);
      const response = await this.doRequest(url, NvHttp.READ_TIMEOUT, true);
      
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
    const url = this.buildUrl(this.getHttpsBaseUrl(), 'displays');
    // 使用客户端证书
    const response = await this.doRequest(url, NvHttp.LONG_CONNECTION_TIMEOUT, true);
    
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
    const url = this.buildUrl(this.getHttpsBaseUrl(), 'appasset',
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
   * 生成安全的随机十六进制字符串
   */
  private generateRandomHex(bytes: number): string {
    const randomBytes = CryptoUtil.generateRandomBytes(bytes);
    return CryptoUtil.bytesToHex(randomBytes);
  }

  private async getClientCertificate(): Promise<string> {
    // TODO: 使用 HarmonyOS 加密 API 生成客户端证书
    // 目前返回空字符串，配对功能需要完整实现
    return '';
  }
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
}
