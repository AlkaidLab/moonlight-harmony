import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { CryptoUtil } from '../utils/CryptoUtil';

/**
 * 配对状态
 */
export enum PairState {
  NOT_PAIRED = 'NOT_PAIRED',
  PAIRED = 'PAIRED',
  PIN_WRONG = 'PIN_WRONG',
  FAILED = 'FAILED',
  ALREADY_IN_PROGRESS = 'ALREADY_IN_PROGRESS'
}

/**
 * 配对结果
 */
export interface PairResult {
  state: PairState;
  serverCert?: Uint8Array;
  pairName?: string;
}

/**
 * 配对管理器
 *
 * 实现与 NVIDIA GameStream / Sunshine 服务器的配对流程
 * 参考 Android PairingManager.java
 */
export class PairingManager {
  private baseUrl: string;
  private uniqueId: string;
  private clientName: string = 'Moonlight-HarmonyOS';

  // 客户端密钥对和证书
  private keyPair: cryptoFramework.KeyPair | null = null;
  private clientCertDer: Uint8Array | null = null;

  // 服务器证书
  private serverCertDer: Uint8Array | null = null;

  constructor(address: string, uniqueId: string) {
    this.baseUrl = `http://${address}:47989`;
    this.uniqueId = uniqueId;
  }

  /**
   * 初始化客户端密钥对
   */
  async initialize(): Promise<void> {
    if (!this.keyPair) {
      console.info('PairingManager: 生成 RSA 密钥对...');
      this.keyPair = await CryptoUtil.generateRsaKeyPair();
      this.clientCertDer = await CryptoUtil.generateSelfSignedCert(this.keyPair);
      console.info('PairingManager: 密钥对生成完成');
    }
  }

  /**
   * 获取客户端证书的十六进制表示
   */
  getClientCertHex(): string {
    if (!this.clientCertDer) {
      return '';
    }
    return CryptoUtil.bytesToHex(this.clientCertDer);
  }

  /**
   * 获取服务器证书
   */
  getServerCert(): Uint8Array | null {
    return this.serverCertDer;
  }

  /**
   * 执行 HTTP 请求
   */
  private async doRequest(url: string, timeout: number = 7000): Promise<string> {
    const httpRequest = http.createHttp();

    try {
      console.info(`PairingManager: 请求 ${url}`);

      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: timeout,
        header: {
          'Accept': '*/*'
        }
      });

      if (response.responseCode !== 200) {
        throw new Error(`HTTP ${response.responseCode}`);
      }

      return response.result as string;
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 构建配对请求 URL
   */
  private buildPairUrl(params: string): string {
    return `${this.baseUrl}/pair?uniqueid=${this.uniqueId}&clientname=${encodeURIComponent(this.clientName)}&${params}`;
  }

  /**
   * 从 XML 中提取值
   */
  private getXmlValue(xml: string, tag: string): string {
    const regex = new RegExp(`<${tag}>(.*?)</${tag}>`, 's');
    const match = xml.match(regex);
    return match ? match[1].trim() : '';
  }

  /**
   * 提取服务器证书
   */
  private extractServerCert(xml: string): Uint8Array | null {
    const certHex = this.getXmlValue(xml, 'plaincert');
    if (!certHex) {
      return null;
    }
    return CryptoUtil.hexToBytes(certHex);
  }

  /**
   * 确定使用的哈希算法
   * Gen 7+ 使用 SHA-256，之前使用 SHA-1
   */
  private async hashData(data: Uint8Array, useSha256: boolean): Promise<Uint8Array> {
    if (useSha256) {
      return await CryptoUtil.sha256(data);
    } else {
      return await CryptoUtil.sha1(data);
    }
  }

  /**
   * 获取哈希长度
   */
  private getHashLength(useSha256: boolean): number {
    return useSha256 ? 32 : 20;
  }

  /**
   * 执行配对流程
   *
   * @param pin 用户输入的 4 位 PIN 码
   * @param serverMajorVersion 服务器主版本号（7+ 使用 SHA-256）
   * @returns 配对结果
   */
  async pair(pin: string, serverMajorVersion: number = 7): Promise<PairResult> {
    await this.initialize();

    const useSha256 = serverMajorVersion >= 7;
    console.info(`PairingManager: 使用 ${useSha256 ? 'SHA-256' : 'SHA-1'} 哈希算法`);

    try {
      // ============ 步骤 1: 发送 salt 和客户端证书，获取服务器证书 ============
      console.info('PairingManager: 步骤1 - 发送 salt 和客户端证书');

      const salt = CryptoUtil.generateRandomBytes(16);
      const saltedPin = CryptoUtil.saltPin(salt, pin);
      const aesKey = CryptoUtil.generateAesKey(await this.hashData(saltedPin, useSha256));

      const step1Url = this.buildPairUrl(
        `devicename=${encodeURIComponent(this.clientName)}&updateState=1&phrase=getservercert` +
        `&salt=${CryptoUtil.bytesToHex(salt)}&clientcert=${this.getClientCertHex()}`
      );

      // 不设置读取超时，因为需要等待用户在主机上输入 PIN
      const step1Response = await this.doRequest(step1Url, 0);

      if (this.getXmlValue(step1Response, 'paired') !== '1') {
        return { state: PairState.FAILED };
      }

      const pairName = this.getXmlValue(step1Response, 'pairname');
      this.serverCertDer = this.extractServerCert(step1Response);

      if (!this.serverCertDer) {
        // 可能有其他设备正在配对
        await this.unpair();
        return { state: PairState.ALREADY_IN_PROGRESS, pairName };
      }

      // ============ 步骤 2: 发送加密的客户端挑战 ============
      console.info('PairingManager: 步骤2 - 发送客户端挑战');

      const randomChallenge = CryptoUtil.generateRandomBytes(16);
      const encryptedChallenge = await CryptoUtil.aesEncrypt(randomChallenge, aesKey);

      const step2Url = this.buildPairUrl(
        `devicename=${encodeURIComponent(this.clientName)}&updateState=1` +
        `&clientchallenge=${CryptoUtil.bytesToHex(encryptedChallenge)}`
      );

      const step2Response = await this.doRequest(step2Url);

      if (this.getXmlValue(step2Response, 'paired') !== '1') {
        await this.unpair();
        return { state: PairState.FAILED, pairName };
      }

      // 解密服务器响应
      const encServerChallengeResponse = CryptoUtil.hexToBytes(
        this.getXmlValue(step2Response, 'challengeresponse')
      );
      const decServerChallengeResponse = await CryptoUtil.aesDecrypt(encServerChallengeResponse, aesKey);

      const hashLength = this.getHashLength(useSha256);
      const serverResponse = decServerChallengeResponse.slice(0, hashLength);
      const serverChallenge = decServerChallengeResponse.slice(hashLength, hashLength + 16);

      // ============ 步骤 3: 发送服务器挑战响应 ============
      console.info('PairingManager: 步骤3 - 发送服务器挑战响应');

      const clientSecret = CryptoUtil.generateRandomBytes(16);

      // 计算挑战响应哈希: hash(serverChallenge + clientCertSignature + clientSecret)
      // 注意：这里需要客户端证书的签名，但我们简化实现使用证书 DER
      const challengeRespData = CryptoUtil.concatBytes(
        CryptoUtil.concatBytes(serverChallenge, this.clientCertDer!),
        clientSecret
      );
      const challengeRespHash = await this.hashData(challengeRespData, useSha256);
      const challengeRespEncrypted = await CryptoUtil.aesEncrypt(challengeRespHash, aesKey);

      const step3Url = this.buildPairUrl(
        `devicename=${encodeURIComponent(this.clientName)}&updateState=1` +
        `&serverchallengeresp=${CryptoUtil.bytesToHex(challengeRespEncrypted)}`
      );

      const step3Response = await this.doRequest(step3Url);

      if (this.getXmlValue(step3Response, 'paired') !== '1') {
        await this.unpair();
        return { state: PairState.FAILED, pairName };
      }

      // 获取服务器签名的 secret
      const serverSecretResp = CryptoUtil.hexToBytes(
        this.getXmlValue(step3Response, 'pairingsecret')
      );
      const serverSecret = serverSecretResp.slice(0, 16);
      const serverSignature = serverSecretResp.slice(16);

      // TODO: 验证服务器签名（需要解析服务器证书的公钥）

      // 验证 PIN 是否正确
      const expectedServerResponse = await this.hashData(
        CryptoUtil.concatBytes(
          CryptoUtil.concatBytes(randomChallenge, this.serverCertDer!),
          serverSecret
        ),
        useSha256
      );

      if (!this.arraysEqual(expectedServerResponse, serverResponse)) {
        await this.unpair();
        return { state: PairState.PIN_WRONG, pairName };
      }

      // ============ 步骤 4: 发送客户端签名的 secret ============
      console.info('PairingManager: 步骤4 - 发送客户端 secret');

      // 签名 clientSecret
      const clientSignature = await CryptoUtil.rsaSign(clientSecret, this.keyPair!.priKey);
      const clientPairingSecret = CryptoUtil.concatBytes(clientSecret, clientSignature);

      const step4Url = this.buildPairUrl(
        `devicename=${encodeURIComponent(this.clientName)}&updateState=1` +
        `&clientpairingsecret=${CryptoUtil.bytesToHex(clientPairingSecret)}`
      );

      const step4Response = await this.doRequest(step4Url);

      if (this.getXmlValue(step4Response, 'paired') !== '1') {
        await this.unpair();
        return { state: PairState.FAILED, pairName };
      }

      // ============ 步骤 5: 执行配对挑战（完成配对） ============
      console.info('PairingManager: 步骤5 - 完成配对');

      const step5Url = `https://${this.baseUrl.replace('http://', '').replace(':47989', ':47984')}/pair?` +
        `uniqueid=${this.uniqueId}&clientname=${encodeURIComponent(this.clientName)}` +
        `&devicename=${encodeURIComponent(this.clientName)}&updateState=1&phrase=pairchallenge`;

      const step5Response = await this.doRequest(step5Url);

      if (this.getXmlValue(step5Response, 'paired') !== '1') {
        await this.unpair();
        return { state: PairState.FAILED, pairName };
      }

      console.info('PairingManager: 配对成功!');
      return {
        state: PairState.PAIRED,
        serverCert: this.serverCertDer,
        pairName
      };

    } catch (err) {
      console.error('PairingManager: 配对失败', err);
      return { state: PairState.FAILED };
    }
  }

  /**
   * 取消配对
   */
  async unpair(): Promise<void> {
    try {
      const url = `${this.baseUrl}/unpair?uniqueid=${this.uniqueId}`;
      await this.doRequest(url);
    } catch (err) {
      console.warn('PairingManager: 取消配对失败', err);
    }
  }

  /**
   * 比较两个字节数组是否相等
   */
  private arraysEqual(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return false;
    }
    return true;
  }
}
