import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

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

export class NvHttp {
  private address: string;
  private serverCert: string | null;
  private uniqueId: string;
  private clientName: string = 'Moonlight-HarmonyOS';

  // 端口常量
  static readonly DEFAULT_HTTPS_PORT = 47984;
  static readonly DEFAULT_HTTP_PORT = 47989;
  static readonly CONNECTION_TIMEOUT = 5000;
  static readonly LONG_CONNECTION_TIMEOUT = 5000;
  static readonly READ_TIMEOUT = 7000;

  // 缓存的 HTTPS 端口
  private httpsPort: number = 0;

  constructor(address: string, serverCert: string | null) {
    this.address = address;
    this.serverCert = serverCert;
    this.uniqueId = this.getOrCreateUniqueId();
  }

  /**
   * 获取或创建设备唯一标识
   */
  private getOrCreateUniqueId(): string {
    // TODO: 从持久化存储获取，如果没有则生成新的
    const chars = '0123456789abcdef';
    let result = '';
    for (let i = 0; i < 16; i++) {
      result += chars[Math.floor(Math.random() * 16)];
    }
    return result;
  }

  /**
   * 获取 HTTP 基础 URL
   */
  private getHttpBaseUrl(): string {
    return `http://${this.address}:${NvHttp.DEFAULT_HTTP_PORT}`;
  }

  /**
   * 获取 HTTPS 基础 URL
   */
  private getHttpsBaseUrl(): string {
    const port = this.httpsPort || NvHttp.DEFAULT_HTTPS_PORT;
    return `https://${this.address}:${port}`;
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
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }

  /**
   * 执行 HTTP 请求
   */
  private async doRequest(url: string, timeout: number = NvHttp.READ_TIMEOUT): Promise<string> {
    const httpRequest = http.createHttp();

    try {
      console.info(`NvHttp: 请求 ${url}`);

      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: NvHttp.CONNECTION_TIMEOUT,
        readTimeout: timeout,
        header: {
          'Accept': '*/*'
        }
      });

      if (response.responseCode !== 200) {
        throw new Error(`HTTP ${response.responseCode}`);
      }

      const result = response.result as string;
      console.info(`NvHttp: 响应长度 ${result.length}`);
      return result;
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 获取服务器信息
   * 优先使用 HTTPS（如果已配对），失败后尝试 HTTP
   */
  async getServerInfo(likelyOnline: boolean = true): Promise<ServerInfo> {
    let response: string;

    try {
      // 如果有服务器证书（已配对），尝试 HTTPS
      if (this.serverCert) {
        try {
          const url = this.buildUrl(this.getHttpsBaseUrl(), 'serverinfo');
          response = await this.doRequest(url);
        } catch (err) {
          console.warn('NvHttp: HTTPS 请求失败，尝试 HTTP', err);
          // 证书可能不匹配，降级到 HTTP
          const url = this.buildUrl(this.getHttpBaseUrl(), 'serverinfo');
          response = await this.doRequest(url);
        }
      } else {
        // 未配对，使用 HTTP
        const url = this.buildUrl(this.getHttpBaseUrl(), 'serverinfo');
        response = await this.doRequest(url);
      }
    } catch (err) {
      throw new Error(`获取服务器信息失败: ${err}`);
    }

    const serverInfo = this.parseServerInfo(response);

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

    try {
      const response = await this.doRequest(url);
      return this.parseAppList(response);
    } catch (err) {
      // 如果 HTTPS 失败，尝试 HTTP
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
    const paired = this.getXmlValue(xml, 'paired');
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
    const query = this.buildLaunchQuery(appId, config, 'launch');
    const url = this.buildUrl(this.getHttpsBaseUrl(), 'launch', query);

    // 启动可能需要较长时间
    const response = await this.doRequest(url, 60000);

    // 检查是否成功
    const gamesession = this.getXmlValue(response, 'gamesession');
    if (gamesession === '0') {
      throw new Error('启动应用失败');
    }

    return this.getXmlValue(response, 'sessionUrl0') || '';
  }

  /**
   * 恢复会话
   */
  async resumeApp(config: LaunchConfig): Promise<string> {
    const query = `rikey=${config.riKey}&rikeyid=${config.riKeyId}`;
    const url = this.buildUrl(this.getHttpsBaseUrl(), 'resume', query);

    const response = await this.doRequest(url, 60000);

    const resume = this.getXmlValue(response, 'resume');
    if (resume === '0') {
      throw new Error('恢复会话失败');
    }

    return this.getXmlValue(response, 'sessionUrl0') || '';
  }

  /**
   * 退出应用
   */
  async quitApp(): Promise<boolean> {
    const url = this.buildUrl(this.getHttpsBaseUrl(), 'cancel');
    const response = await this.doRequest(url);

    const cancel = this.getXmlValue(response, 'cancel');
    return cancel !== '0';
  }

  /**
   * 获取应用图标
   */
  async getAppAsset(appId: number): Promise<ArrayBuffer | null> {
    const url = this.buildUrl(this.getHttpsBaseUrl(), 'appasset',
      `appid=${appId}&AssetType=2&AssetIdx=0`);

    try {
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: NvHttp.CONNECTION_TIMEOUT,
        readTimeout: NvHttp.READ_TIMEOUT,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      httpRequest.destroy();

      if (response.responseCode === 200) {
        return response.result as ArrayBuffer;
      }
    } catch (err) {
      console.warn(`NvHttp: 获取应用图标失败 appId=${appId}`, err);
    }
    return null;
  }

  /**
   * 构建启动查询参数
   */
  private buildLaunchQuery(appId: number, config: LaunchConfig, verb: string): string {
    const params: string[] = [
      `appid=${appId}`,
      `mode=${config.width}x${config.height}x${config.fps}`,
      `additionalStates=1`,
      `sops=${config.sops ? 1 : 0}`,
      `rikey=${config.riKey}`,
      `rikeyid=${config.riKeyId}`,
      `localAudioPlayMode=${config.localAudio ? 1 : 0}`,
      `surroundAudioInfo=${config.audioConfig}`,
      `remoteControllersBitmap=0`,
      `gcmap=0`
    ];

    if (config.enableHdr) {
      params.push('hdrMode=1');
      params.push('clientHdrCapVersion=0');
      params.push('clientHdrCapSupportedFlagsInUint32=0');
      params.push('clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1');
      params.push('clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0');
    }

    return params.join('&');
  }

  getServerCert(): string {
    return this.serverCert || '';
  }

  /**
   * 获取 XML 标签值
   */
  private getXmlValue(xml: string, tag: string): string {
    const regex = new RegExp(`<${tag}>(.*?)</${tag}>`, 's');
    const match = xml.match(regex);
    return match ? match[1].trim() : '';
  }

  private parseServerInfo(xml: string): ServerInfo {
    return {
      hostname: this.getXmlValue(xml, 'hostname') || 'UNKNOWN',
      uniqueId: this.getXmlValue(xml, 'uniqueid'),
      macAddress: this.getXmlValue(xml, 'mac'),
      paired: this.getXmlValue(xml, 'PairStatus') === '1',
      currentGame: parseInt(this.getXmlValue(xml, 'currentgame')) || 0,
      serverCodecModeSupport: parseInt(this.getXmlValue(xml, 'ServerCodecModeSupport')) || 0,
      gpuType: this.getXmlValue(xml, 'gputype'),
      gfeVersion: this.getXmlValue(xml, 'GfeVersion'),
      appVersion: this.getXmlValue(xml, 'appversion'),
      maxLumaPixelsHEVC: parseInt(this.getXmlValue(xml, 'MaxLumaPixelsHEVC')) || 0,
      serverCapabilities: this.getXmlValue(xml, 'ServerCapabilities'),
      httpsPort: parseInt(this.getXmlValue(xml, 'HttpsPort')) || NvHttp.DEFAULT_HTTPS_PORT,
      externalPort: parseInt(this.getXmlValue(xml, 'ExternalPort')) || NvHttp.DEFAULT_HTTP_PORT,
      localAddress: this.getXmlValue(xml, 'LocalIP'),
      externalAddress: this.getXmlValue(xml, 'ExternalIP')
    };
  }

  private parseAppList(xml: string): AppEntry[] {
    const apps: AppEntry[] = [];
    const appRegex = /<App>([\s\S]*?)<\/App>/g;
    let match;

    while ((match = appRegex.exec(xml)) !== null) {
      const appXml = match[1];

      apps.push({
        id: parseInt(this.getXmlValueFromString(appXml, 'ID')) || 0,
        name: this.getXmlValueFromString(appXml, 'AppTitle'),
        isRunning: this.getXmlValueFromString(appXml, 'IsRunning') === '1',
        isHdrSupported: this.getXmlValueFromString(appXml, 'IsHdrSupported') === '1'
      });
    }

    return apps;
  }

  private getXmlValueFromString(xml: string, tag: string): string {
    const regex = new RegExp(`<${tag}>(.*?)</${tag}>`, 's');
    const match = xml.match(regex);
    return match ? match[1].trim() : '';
  }

  /**
   * 生成随机十六进制字符串
   */
  private generateRandomHex(bytes: number): string {
    const array = new Uint8Array(bytes);
    for (let i = 0; i < bytes; i++) {
      array[i] = Math.floor(Math.random() * 256);
    }
    return Array.from(array).map(b => b.toString(16).padStart(2, '0')).join('');
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
}

export interface LaunchConfig {
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
}
