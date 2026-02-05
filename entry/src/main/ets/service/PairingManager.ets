/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { CryptoUtil } from '../utils/CryptoUtil';
import { common } from '@kit.AbilityKit';
import { HttpClient } from '../utils/HttpClient';
import { XmlUtil } from '../utils/XmlUtil';

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
  private httpsUrl: string;
  private address: string;
  private uniqueId: string;
  private clientName: string;

  // 客户端密钥对和证书
  private keyPair: cryptoFramework.KeyPair | null = null;
  private clientCertDer: Uint8Array | null = null;
  private clientCertPem: Uint8Array | null = null;

  // 服务器证书
  private serverCertDer: Uint8Array | null = null;

  // 证书文件路径
  private certFilePath: string = '';
  private keyFilePath: string = '';
  private context: common.Context | null = null;

  // 默认端口
  static readonly DEFAULT_HTTP_PORT = 47989;
  static readonly DEFAULT_HTTPS_PORT = 47984;

  // 全局客户端名称缓存（使用设备名称）
  private static cachedClientName: string | null = null;

  constructor(address: string, uniqueId: string, context?: common.Context, httpPort?: number) {
    // 解析地址中可能包含的端口号
    const parsedHost = this.parseAddressHost(address);
    const parsedPort = this.parseAddressPort(address);
    this.address = parsedHost;
    const port = httpPort || parsedPort || PairingManager.DEFAULT_HTTP_PORT;
    // HTTPS 端口 = HTTP 端口 - 5 (47989 -> 47984)
    const httpsPort = port - 5;
    this.baseUrl = `http://${this.address}:${port}`;
    this.httpsUrl = `https://${this.address}:${httpsPort}`;
    this.uniqueId = uniqueId;
    this.clientName = this.getClientName();
    if (context) {
      this.context = context;
      // 设置证书文件路径（使用应用沙箱目录）
      const filesDir = context.filesDir;
      this.certFilePath = `${filesDir}/client_cert.pem`;
      this.keyFilePath = `${filesDir}/client_key.pem`;
    }
  }

  /**
   * 获取客户端名称（使用设备名称）
   */
  private getClientName(): string {
    if (PairingManager.cachedClientName) {
      return PairingManager.cachedClientName;
    }

    try {
      const name = deviceInfo.marketName || deviceInfo.productModel || 'Moonlight-HarmonyOS';
      PairingManager.cachedClientName = name;
      return name;
    } catch (err) {
      console.warn(`PairingManager: 无法获取设备名称: ${err}`);
      PairingManager.cachedClientName = 'Moonlight-HarmonyOS';
      return 'Moonlight-HarmonyOS';
    }
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
   * 初始化客户端密钥对
   * 如果证书文件已存在，则从文件加载；否则生成新的密钥对和证书
   * 重要：必须保持同一个客户端证书用于所有服务器，否则之前配对的服务器会失效
   */
  async initialize(): Promise<void> {
    if (this.keyPair) {
      // 已初始化
      return;
    }

    // 尝试从文件加载已存在的密钥对和证书
    if (this.certFilePath && this.keyFilePath) {
      try {
        const certExists = fileIo.accessSync(this.certFilePath);
        const keyExists = fileIo.accessSync(this.keyFilePath);
        
        if (certExists && keyExists) {
          console.info('PairingManager: 发现已存在的证书文件，尝试加载...');
          
          // 读取私钥文件
          const keyFile = await fileIo.open(this.keyFilePath, fileIo.OpenMode.READ_ONLY);
          const keyStats = await fileIo.stat(this.keyFilePath);
          const keyBuffer = new ArrayBuffer(keyStats.size);
          await fileIo.read(keyFile.fd, keyBuffer);
          await fileIo.close(keyFile);
          
          const keyContent = new Uint8Array(keyBuffer);
          const textDecoder = util.TextDecoder.create('utf-8');
          const keyPem = textDecoder.decodeToString(keyContent);
          
          // 从 PEM 格式加载私钥
          const generator = cryptoFramework.createAsyKeyGenerator('RSA2048');
          const keyPairResult = await generator.convertPemKey(null, keyPem);
          this.keyPair = keyPairResult;
          
          // 读取证书文件
          const certFile = await fileIo.open(this.certFilePath, fileIo.OpenMode.READ_ONLY);
          const certStats = await fileIo.stat(this.certFilePath);
          const certBuffer = new ArrayBuffer(certStats.size);
          await fileIo.read(certFile.fd, certBuffer);
          await fileIo.close(certFile);
          
          this.clientCertPem = new Uint8Array(certBuffer);
          
          // 从 PEM 转换为 DER（去掉 header 和 footer，base64 解码）
          const certPemStr = textDecoder.decodeToString(this.clientCertPem);
          const certBase64 = certPemStr
            .replace('-----BEGIN CERTIFICATE-----', '')
            .replace('-----END CERTIFICATE-----', '')
            .replace(/\s/g, '');
          const textEncoder = new util.TextEncoder();
          const base64Helper = new util.Base64Helper();
          this.clientCertDer = base64Helper.decodeSync(certBase64);
          
          console.info(`PairingManager: 成功加载已存在的证书，PEM长度=${this.clientCertPem.length}, DER长度=${this.clientCertDer.length}`);
          return;
        }
      } catch (err) {
        console.warn(`PairingManager: 加载已存在证书失败: ${err}, 将生成新的密钥对`);
        // 继续生成新的密钥对
      }
    }

    // 生成新的密钥对和证书
    console.info('PairingManager: 生成新的 RSA 密钥对...');
    this.keyPair = await CryptoUtil.generateRsaKeyPair();
    console.info('PairingManager: RSA 密钥对生成完成');
    
    this.clientCertDer = await CryptoUtil.generateSelfSignedCert(this.keyPair);
    console.info(`PairingManager: 证书 DER 生成完成，长度 = ${this.clientCertDer.length}`);
    
    this.clientCertPem = CryptoUtil.getPemCertBytes(this.clientCertDer);
    console.info(`PairingManager: 证书 PEM 生成完成，长度 = ${this.clientCertPem.length}`);
    
    // 保存证书和私钥到文件（供 HTTPS 请求使用）
    await this.saveCertificatesToFile();
    
    console.info('PairingManager: 密钥对和证书生成完成');
  }

  /**
   * 保存证书和私钥到文件
   */
  private async saveCertificatesToFile(): Promise<void> {
    if (!this.certFilePath || !this.keyFilePath || !this.keyPair || !this.clientCertPem) {
      console.warn('PairingManager: 无法保存证书（路径或数据不完整）');
      return;
    }

    try {
      // 保存证书（clientCertPem 已是 Uint8Array，直接转为字符串）
      const textDecoder = util.TextDecoder.create('utf-8');
      const certContent = textDecoder.decodeToString(this.clientCertPem);
      const certFile = await fileIo.open(this.certFilePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      await fileIo.write(certFile.fd, certContent);
      await fileIo.close(certFile);
      console.info(`PairingManager: 证书已保存到 ${this.certFilePath}`);

      // 保存私钥
      const priKeyBlob = this.keyPair.priKey.getEncodedPem('PKCS8');
      const keyFile = await fileIo.open(this.keyFilePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      await fileIo.write(keyFile.fd, priKeyBlob);
      await fileIo.close(keyFile);
      console.info(`PairingManager: 私钥已保存到 ${this.keyFilePath}`);
    } catch (err) {
      console.error(`PairingManager: 保存证书失败: ${err}`);
    }
  }

  /**
   * 获取客户端证书的十六进制表示（PEM 格式）
   * Android 使用 PEM 格式的证书
   */
  getClientCertHex(): string {
    if (!this.clientCertPem) {
      return '';
    }
    return CryptoUtil.bytesToHex(this.clientCertPem);
  }

  /**
   * 获取客户端证书签名
   */
  getClientCertSignature(): Uint8Array {
    if (!this.clientCertDer) {
      return new Uint8Array(0);
    }
    return CryptoUtil.extractCertSignature(this.clientCertDer);
  }

  /**
   * 获取服务器证书
   */
  getServerCert(): Uint8Array | null {
    return this.serverCertDer;
  }

  /**
   * 使用 HttpClient 执行 HTTP 请求
   * @param url 请求 URL
   * @param timeout 超时时间（毫秒）
   * @param useClientCert 是否使用客户端证书（HTTPS 请求需要）
   */
  private async doRequest(url: string, timeout: number = 7000, useClientCert: boolean = false): Promise<string> {
    console.info(`PairingManager: 请求 ${url}`);
    console.info(`PairingManager: 超时设置 = ${timeout > 0 ? timeout : '无限制'}, 使用客户端证书 = ${useClientCert}`);

    if (useClientCert && this.certFilePath && this.keyFilePath) {
      return HttpClient.getWithClientCert(url, this.certFilePath, this.keyFilePath, {
        connectTimeout: 30000,
        transferTimeout: timeout > 0 ? timeout : 300000
      });
    } else {
      return HttpClient.get(url, {
        connectTimeout: 30000,
        transferTimeout: timeout > 0 ? timeout : 300000
      });
    }
  }

  /**
   * 构建配对请求 URL
   */
  private buildPairUrl(params: string): string {
    return `${this.baseUrl}/pair?uniqueid=${this.uniqueId}&clientname=${encodeURIComponent(this.clientName)}&${params}`;
  }

  /**
   * 提取服务器证书
   * 注意：服务器返回的是 PEM 格式证书的十六进制编码
   */
  private extractServerCert(xml: string): Uint8Array | null {
    const certHex = XmlUtil.getValue(xml, 'plaincert');
    if (!certHex) {
      return null;
    }
    
    // 十六进制解码得到 PEM 字符串的字节
    const pemBytes = CryptoUtil.hexToBytes(certHex);
    
    // 将字节转换为字符串
    let pemString = '';
    for (let i = 0; i < pemBytes.length; i++) {
      pemString += String.fromCharCode(pemBytes[i]);
    }
    
    console.info(`PairingManager: 服务器证书 PEM 前80字符 = ${pemString.substring(0, 80)}`);
    
    // 从 PEM 提取 DER
    const derBytes = CryptoUtil.pemToDer(pemString);
    console.info(`PairingManager: 服务器证书 DER 长度 = ${derBytes.length}`);
    
    return derBytes;
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
      console.info(`PairingManager: PIN = ${pin}`);

      const salt = CryptoUtil.generateRandomBytes(16);
      const saltedPin = CryptoUtil.saltPin(salt, pin);
      const saltedPinHash = await this.hashData(saltedPin, useSha256);
      const aesKey = CryptoUtil.generateAesKeyFromHash(saltedPinHash);

      console.info(`PairingManager: salt = ${CryptoUtil.bytesToHex(salt)}`);
      console.info(`PairingManager: clientCert长度 = ${this.getClientCertHex().length}`);

      const step1Url = this.buildPairUrl(
        `devicename=roth&updateState=1&phrase=getservercert` +
        `&salt=${CryptoUtil.bytesToHex(salt)}&clientcert=${this.getClientCertHex()}`
      );

      console.info('PairingManager: 等待服务器响应（用户需要在服务器上输入 PIN）...');

      // 使用 rcp 发送请求，设置 5 分钟超时（等待用户在主机上输入 PIN）
      const step1Response = await this.doRequest(step1Url, 300000);

      console.info(`PairingManager: 步骤1响应 = ${step1Response.substring(0, 200)}...`);

      if (XmlUtil.getValue(step1Response, 'paired') !== '1') {
        console.error('PairingManager: 步骤1失败 - paired != 1');
        return { state: PairState.FAILED };
      }

      const pairName = XmlUtil.getValue(step1Response, 'pairname');
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
        `devicename=roth&updateState=1` +
        `&clientchallenge=${CryptoUtil.bytesToHex(encryptedChallenge)}`
      );

      const step2Response = await this.doRequest(step2Url);

      if (XmlUtil.getValue(step2Response, 'paired') !== '1') {
        await this.unpair();
        return { state: PairState.FAILED, pairName };
      }

      // 解密服务器响应
      const encServerChallengeResponse = CryptoUtil.hexToBytes(
        XmlUtil.getValue(step2Response, 'challengeresponse')
      );
      const decServerChallengeResponse = await CryptoUtil.aesDecrypt(encServerChallengeResponse, aesKey);

      const hashLength = this.getHashLength(useSha256);
      const serverResponse = decServerChallengeResponse.slice(0, hashLength);
      const serverChallenge = decServerChallengeResponse.slice(hashLength, hashLength + 16);

      // ============ 步骤 3: 发送服务器挑战响应 ============
      console.info('PairingManager: 步骤3 - 发送服务器挑战响应');

      const clientSecret = CryptoUtil.generateRandomBytes(16);

      // 计算挑战响应哈希: hash(serverChallenge + clientCertSignature + clientSecret)
      // 使用客户端证书的签名（参考 Android 实现：cert.getSignature()）
      const clientCertSignature = this.getClientCertSignature();
      const challengeRespData = CryptoUtil.concatBytes(
        CryptoUtil.concatBytes(serverChallenge, clientCertSignature),
        clientSecret
      );
      const challengeRespHash = await this.hashData(challengeRespData, useSha256);
      const challengeRespEncrypted = await CryptoUtil.aesEncrypt(challengeRespHash, aesKey);

      const step3Url = this.buildPairUrl(
        `devicename=roth&updateState=1` +
        `&serverchallengeresp=${CryptoUtil.bytesToHex(challengeRespEncrypted)}`
      );

      const step3Response = await this.doRequest(step3Url);

      if (XmlUtil.getValue(step3Response, 'paired') !== '1') {
        await this.unpair();
        return { state: PairState.FAILED, pairName };
      }

      // 获取服务器签名的 secret
      const serverSecretResp = CryptoUtil.hexToBytes(
        XmlUtil.getValue(step3Response, 'pairingsecret')
      );
      const serverSecret = serverSecretResp.slice(0, 16);
      const serverSignature = serverSecretResp.slice(16);

      // TODO: 验证服务器签名（需要解析服务器证书的公钥）

      // 验证 PIN 是否正确
      // 使用服务器证书签名（参考 Android 实现：serverCert.getSignature()）
      const serverCertSignature = CryptoUtil.extractCertSignature(this.serverCertDer!);
      const expectedServerResponse = await this.hashData(
        CryptoUtil.concatBytes(
          CryptoUtil.concatBytes(randomChallenge, serverCertSignature),
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
      console.info(`PairingManager: clientSecret 长度 = ${clientSecret.length}`);
      const clientSignature = await CryptoUtil.rsaSign(clientSecret, this.keyPair!.priKey);
      console.info(`PairingManager: clientSignature 长度 = ${clientSignature.length}`);
      const clientPairingSecret = CryptoUtil.concatBytes(clientSecret, clientSignature);
      console.info(`PairingManager: clientPairingSecret 长度 = ${clientPairingSecret.length}`);

      const step4Url = this.buildPairUrl(
        `devicename=roth&updateState=1` +
        `&clientpairingsecret=${CryptoUtil.bytesToHex(clientPairingSecret)}`
      );

      const step4Response = await this.doRequest(step4Url);

      if (XmlUtil.getValue(step4Response, 'paired') !== '1') {
        await this.unpair();
        return { state: PairState.FAILED, pairName };
      }

      // ============ 步骤 5: 执行配对挑战（完成配对） ============
      console.info('PairingManager: 步骤5 - 完成配对');

      // 使用 HTTPS 端口 47984 发送 pairchallenge（需要客户端证书）
      const step5Url = `${this.httpsUrl}/pair?` +
        `uniqueid=${this.uniqueId}&devicename=roth&updateState=1&phrase=pairchallenge`;

      // 步骤5 需要使用客户端证书进行 HTTPS 请求
      const step5Response = await this.doRequest(step5Url, 7000, true);

      if (XmlUtil.getValue(step5Response, 'paired') !== '1') {
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

  /**
   * 生成4位数字PIN码
   */
  static generatePin(): string {
    return CryptoUtil.generatePin();
  }
}
