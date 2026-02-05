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
import { util } from '@kit.ArkTS';

/**
 * 加密工具类
 *
 * 用于证书生成、加密通信等
 * 参考 Android PairingManager 实现
 */
export class CryptoUtil {
  /**
   * 生成随机字节数组（使用加密安全的随机数）
   */
  static generateRandomBytes(length: number): Uint8Array {
    const random = cryptoFramework.createRandom();
    const dataBlob = random.generateRandomSync(length);
    return new Uint8Array(dataBlob.data);
  }

  /**
   * 生成随机 32 位无符号整数（使用加密安全的随机数）
   */
  static generateRandomUint32(): number {
    const bytes = CryptoUtil.generateRandomBytes(4);
    return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) >>> 0;
  }

  /**
   * 字节数组转十六进制字符串（大写）
   */
  static bytesToHex(bytes: Uint8Array): string {
    let result = '';
    for (let i = 0; i < bytes.length; i++) {
      const v = bytes[i] & 0xFF;
      result += v.toString(16).toUpperCase().padStart(2, '0');
    }
    return result;
  }

  /**
   * 十六进制字符串转字节数组
   */
  static hexToBytes(hex: string): Uint8Array {
    if (hex.length % 2 !== 0) {
      throw new Error('Invalid hex string length');
    }
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < bytes.length; i++) {
      bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
    }
    return bytes;
  }

  /**
   * 合并两个字节数组
   */
  static concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
    const result = new Uint8Array(a.length + b.length);
    result.set(a, 0);
    result.set(b, a.length);
    return result;
  }

  /**
   * 创建 DataBlob 辅助方法
   */
  private static createDataBlob(data: Uint8Array): cryptoFramework.DataBlob {
    const blob: cryptoFramework.DataBlob = {
      data: data
    };
    return blob;
  }

  /**
   * SHA-256 哈希
   */
  static async sha256(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA256');
    const blob = CryptoUtil.createDataBlob(data);
    await md.update(blob);
    const result = await md.digest();
    return new Uint8Array(result.data);
  }

  /**
   * SHA-1 哈希（用于旧版本服务器）
   */
  static async sha1(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA1');
    const blob = CryptoUtil.createDataBlob(data);
    await md.update(blob);
    const result = await md.digest();
    return new Uint8Array(result.data);
  }

  /**
   * 生成 AES 密钥（从哈希数据中取前16字节）
   */
  static generateAesKeyFromHash(hashData: Uint8Array): Uint8Array {
    return hashData.slice(0, 16);
  }

  /**
   * 生成随机 AES 密钥（16字节）
   */
  static generateAesKey(): ArrayBuffer {
    const random = cryptoFramework.createRandom();
    const dataBlob = random.generateRandomSync(16);
    // dataBlob.data 是 Uint8Array，需要返回其底层的 ArrayBuffer
    // 使用 slice() 创建一个新的 ArrayBuffer 副本以确保数据完整性
    const uint8Array = new Uint8Array(dataBlob.data);
    return uint8Array.buffer.slice(uint8Array.byteOffset, uint8Array.byteOffset + uint8Array.byteLength);
  }

  /**
   * AES ECB 加密（无填充，输入需要是16字节的倍数）
   */
  static async aesEncrypt(plaintext: Uint8Array, key: Uint8Array): Promise<Uint8Array> {
    // 对齐到16字节
    const blockSize = 16;
    const paddedLength = Math.ceil(plaintext.length / blockSize) * blockSize;
    const paddedData = new Uint8Array(paddedLength);
    paddedData.set(plaintext);

    // 创建 AES 密钥
    const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    const keyBlob = CryptoUtil.createDataBlob(key);
    const symKey = await symKeyGenerator.convertKey(keyBlob);

    // 创建 Cipher（ECB 模式，无填充）
    const cipher = cryptoFramework.createCipher('AES128|ECB|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, null);

    const inputBlob = CryptoUtil.createDataBlob(paddedData);
    const result = await cipher.doFinal(inputBlob);
    return new Uint8Array(result.data);
  }

  /**
   * AES ECB 解密
   */
  static async aesDecrypt(ciphertext: Uint8Array, key: Uint8Array): Promise<Uint8Array> {
    // 创建 AES 密钥
    const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    const keyBlob = CryptoUtil.createDataBlob(key);
    const symKey = await symKeyGenerator.convertKey(keyBlob);

    // 创建 Cipher（ECB 模式，无填充）
    const cipher = cryptoFramework.createCipher('AES128|ECB|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, null);

    const inputBlob = CryptoUtil.createDataBlob(ciphertext);
    const result = await cipher.doFinal(inputBlob);
    return new Uint8Array(result.data);
  }

  /**
   * 生成 RSA 2048 密钥对
   */
  static async generateRsaKeyPair(): Promise<cryptoFramework.KeyPair> {
    const generator = cryptoFramework.createAsyKeyGenerator('RSA2048|PRIMES_2');
    return await generator.generateKeyPair();
  }

  /**
   * RSA SHA256 签名
   */
  static async rsaSign(data: Uint8Array, privateKey: cryptoFramework.PriKey): Promise<Uint8Array> {
    const signer = cryptoFramework.createSign('RSA2048|PKCS1|SHA256');
    await signer.init(privateKey);
    const dataBlob = CryptoUtil.createDataBlob(data);
    await signer.update(dataBlob);
    const signData = await signer.sign(null);
    return new Uint8Array(signData.data);
  }

  /**
   * RSA SHA256 验签
   */
  static async rsaVerify(data: Uint8Array, signature: Uint8Array, publicKey: cryptoFramework.PubKey): Promise<boolean> {
    const verifier = cryptoFramework.createVerify('RSA2048|PKCS1|SHA256');
    await verifier.init(publicKey);
    const dataBlob = CryptoUtil.createDataBlob(data);
    await verifier.update(dataBlob);
    const sigBlob = CryptoUtil.createDataBlob(signature);
    const result = await verifier.verify(dataBlob, sigBlob);
    return result;
  }

  /**
   * 导出公钥为 DER 格式
   */
  static async exportPublicKeyDer(publicKey: cryptoFramework.PubKey): Promise<Uint8Array> {
    const blob = publicKey.getEncoded();
    return new Uint8Array(blob.data);
  }

  /**
   * 生成自签名 X.509 证书
   * 由于 HarmonyOS 没有直接的 X.509 API，我们手动构造 DER 格式
   * 证书结构参考 RFC 5280
   */
  static async generateSelfSignedCert(keyPair: cryptoFramework.KeyPair): Promise<Uint8Array> {
    const pubKeyDer = await CryptoUtil.exportPublicKeyDer(keyPair.pubKey);

    // 构造简化的 X.509 v3 证书
    // 这是一个最小化的证书结构，包含：版本、序列号、签名算法、颁发者、有效期、主题、公钥、签名

    // 序列号（随机 8 字节）
    const serialNumber = CryptoUtil.generateRandomBytes(8);

    // 有效期：当前时间到 20 年后
    const now = new Date();
    const notBefore = CryptoUtil.dateToUtcTime(now);
    const expiry = new Date(now.getTime() + 20 * 365 * 24 * 60 * 60 * 1000);
    const notAfter = CryptoUtil.dateToUtcTime(expiry);

    // Common Name: "NVIDIA GameStream Client"
    const cn = 'NVIDIA GameStream Client';

    // 构造 TBS (To Be Signed) Certificate
    const tbsCert = CryptoUtil.buildTbsCertificate(
      serialNumber,
      notBefore,
      notAfter,
      cn,
      pubKeyDer
    );

    // 签名 TBS 证书
    const signature = await CryptoUtil.rsaSign(tbsCert, keyPair.priKey);

    // 构造完整证书
    const cert = CryptoUtil.buildCertificate(tbsCert, signature);

    return cert;
  }

  /**
   * 日期转换为 UTCTime 格式 (YYMMDDHHMMSSZ)
   */
  private static dateToUtcTime(date: Date): string {
    const year = date.getUTCFullYear() % 100;
    const month = (date.getUTCMonth() + 1).toString().padStart(2, '0');
    const day = date.getUTCDate().toString().padStart(2, '0');
    const hours = date.getUTCHours().toString().padStart(2, '0');
    const minutes = date.getUTCMinutes().toString().padStart(2, '0');
    const seconds = date.getUTCSeconds().toString().padStart(2, '0');
    return `${year.toString().padStart(2, '0')}${month}${day}${hours}${minutes}${seconds}Z`;
  }

  /**
   * 编码 ASN.1 长度
   */
  private static encodeAsn1Length(length: number): Uint8Array {
    if (length < 128) {
      return new Uint8Array([length]);
    } else if (length < 256) {
      return new Uint8Array([0x81, length]);
    } else if (length < 65536) {
      return new Uint8Array([0x82, (length >> 8) & 0xFF, length & 0xFF]);
    } else {
      return new Uint8Array([0x83, (length >> 16) & 0xFF, (length >> 8) & 0xFF, length & 0xFF]);
    }
  }

  /**
   * 构造 ASN.1 SEQUENCE
   */
  private static asn1Sequence(contents: Uint8Array): Uint8Array {
    const len = CryptoUtil.encodeAsn1Length(contents.length);
    const result = new Uint8Array(1 + len.length + contents.length);
    result[0] = 0x30; // SEQUENCE tag
    result.set(len, 1);
    result.set(contents, 1 + len.length);
    return result;
  }

  /**
   * 构造 ASN.1 INTEGER
   */
  private static asn1Integer(value: Uint8Array): Uint8Array {
    // 如果最高位是 1，需要添加前导 0
    let data = value;
    if (value.length > 0 && (value[0] & 0x80) !== 0) {
      data = new Uint8Array(value.length + 1);
      data[0] = 0;
      data.set(value, 1);
    }
    const len = CryptoUtil.encodeAsn1Length(data.length);
    const result = new Uint8Array(1 + len.length + data.length);
    result[0] = 0x02; // INTEGER tag
    result.set(len, 1);
    result.set(data, 1 + len.length);
    return result;
  }

  /**
   * 构造 ASN.1 BIT STRING
   */
  private static asn1BitString(data: Uint8Array): Uint8Array {
    const len = CryptoUtil.encodeAsn1Length(data.length + 1);
    const result = new Uint8Array(1 + len.length + 1 + data.length);
    result[0] = 0x03; // BIT STRING tag
    result.set(len, 1);
    result[1 + len.length] = 0; // unused bits
    result.set(data, 1 + len.length + 1);
    return result;
  }

  /**
   * 构造 ASN.1 UTCTime
   */
  private static asn1UtcTime(time: string): Uint8Array {
    const textEncoder = new util.TextEncoder();
    const timeBytes = textEncoder.encodeInto(time);
    const len = CryptoUtil.encodeAsn1Length(timeBytes.length);
    const result = new Uint8Array(1 + len.length + timeBytes.length);
    result[0] = 0x17; // UTCTime tag
    result.set(len, 1);
    result.set(timeBytes, 1 + len.length);
    return result;
  }

  /**
   * 构造 ASN.1 PrintableString
   */
  private static asn1PrintableString(str: string): Uint8Array {
    const textEncoder = new util.TextEncoder();
    const strBytes = textEncoder.encodeInto(str);
    const len = CryptoUtil.encodeAsn1Length(strBytes.length);
    const result = new Uint8Array(1 + len.length + strBytes.length);
    result[0] = 0x13; // PrintableString tag
    result.set(len, 1);
    result.set(strBytes, 1 + len.length);
    return result;
  }

  /**
   * 构造 X.500 Name (只包含 CN)
   */
  private static buildX500Name(cn: string): Uint8Array {
    // OID for CN (2.5.4.3)
    const cnOid = new Uint8Array([0x06, 0x03, 0x55, 0x04, 0x03]);
    const cnValue = CryptoUtil.asn1PrintableString(cn);

    // AttributeTypeAndValue
    const atv = CryptoUtil.asn1Sequence(CryptoUtil.concatBytes(cnOid, cnValue));

    // RelativeDistinguishedName (SET OF)
    const rdnLen = CryptoUtil.encodeAsn1Length(atv.length);
    const rdn = new Uint8Array(1 + rdnLen.length + atv.length);
    rdn[0] = 0x31; // SET tag
    rdn.set(rdnLen, 1);
    rdn.set(atv, 1 + rdnLen.length);

    // RDNSequence
    return CryptoUtil.asn1Sequence(rdn);
  }

  /**
   * SHA-256 with RSA 签名算法 OID
   */
  private static getSha256WithRsaAlgorithm(): Uint8Array {
    // AlgorithmIdentifier for sha256WithRSAEncryption (1.2.840.113549.1.1.11)
    const oid = new Uint8Array([
      0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B
    ]);
    const nullParam = new Uint8Array([0x05, 0x00]);
    return CryptoUtil.asn1Sequence(CryptoUtil.concatBytes(oid, nullParam));
  }

  /**
   * 构造 TBS Certificate
   */
  private static buildTbsCertificate(
    serialNumber: Uint8Array,
    notBefore: string,
    notAfter: string,
    cn: string,
    pubKeyDer: Uint8Array
  ): Uint8Array {
    // Version (v3 = 2)
    const versionInner = CryptoUtil.asn1Integer(new Uint8Array([2]));
    const version = new Uint8Array(1 + CryptoUtil.encodeAsn1Length(versionInner.length).length + versionInner.length);
    version[0] = 0xA0; // Context tag [0]
    const vLen = CryptoUtil.encodeAsn1Length(versionInner.length);
    version.set(vLen, 1);
    version.set(versionInner, 1 + vLen.length);

    // Serial Number
    const serial = CryptoUtil.asn1Integer(serialNumber);

    // Signature Algorithm
    const sigAlg = CryptoUtil.getSha256WithRsaAlgorithm();

    // Issuer
    const issuer = CryptoUtil.buildX500Name(cn);

    // Validity
    const validityContent = CryptoUtil.concatBytes(
      CryptoUtil.asn1UtcTime(notBefore),
      CryptoUtil.asn1UtcTime(notAfter)
    );
    const validity = CryptoUtil.asn1Sequence(validityContent);

    // Subject
    const subject = CryptoUtil.buildX500Name(cn);

    // SubjectPublicKeyInfo (直接使用 DER 编码的公钥)
    const pubKeyInfo = pubKeyDer;

    // 合并所有字段
    let tbsContent = CryptoUtil.concatBytes(version, serial);
    tbsContent = CryptoUtil.concatBytes(tbsContent, sigAlg);
    tbsContent = CryptoUtil.concatBytes(tbsContent, issuer);
    tbsContent = CryptoUtil.concatBytes(tbsContent, validity);
    tbsContent = CryptoUtil.concatBytes(tbsContent, subject);
    tbsContent = CryptoUtil.concatBytes(tbsContent, pubKeyInfo);

    return CryptoUtil.asn1Sequence(tbsContent);
  }

  /**
   * 构造完整的 X.509 证书
   */
  private static buildCertificate(tbsCert: Uint8Array, signature: Uint8Array): Uint8Array {
    const sigAlg = CryptoUtil.getSha256WithRsaAlgorithm();
    const sigBitString = CryptoUtil.asn1BitString(signature);

    let certContent = CryptoUtil.concatBytes(tbsCert, sigAlg);
    certContent = CryptoUtil.concatBytes(certContent, sigBitString);

    return CryptoUtil.asn1Sequence(certContent);
  }

  /**
   * 从 X.509 证书 DER 中提取签名值
   * 
   * X.509 证书结构:
   * SEQUENCE {
   *   SEQUENCE { ... } -- TBSCertificate
   *   SEQUENCE { ... } -- signatureAlgorithm
   *   BIT STRING       -- signatureValue (这就是我们要的)
   * }
   */
  static extractCertSignature(certDer: Uint8Array): Uint8Array {
    try {
      // 解析外层 SEQUENCE
      if (certDer[0] !== 0x30) {
        console.error('CryptoUtil: 证书不是以 SEQUENCE 开始');
        return certDer;
      }

      let pos = 1;
      
      // 解析外层 SEQUENCE 长度
      let outerLen: number;
      if ((certDer[pos] & 0x80) === 0) {
        outerLen = certDer[pos];
        pos++;
      } else {
        const lenBytes = certDer[pos] & 0x7F;
        pos++;
        outerLen = 0;
        for (let i = 0; i < lenBytes; i++) {
          outerLen = (outerLen << 8) | certDer[pos + i];
        }
        pos += lenBytes;
      }

      // 现在 pos 指向 SEQUENCE 内容的开始
      // 跳过 TBSCertificate (SEQUENCE)
      if (certDer[pos] !== 0x30) {
        console.error('CryptoUtil: TBSCertificate 不是 SEQUENCE');
        return certDer;
      }
      pos++; // 跳过 tag
      
      // 解析 TBS 长度并跳过
      let tbsLen: number;
      if ((certDer[pos] & 0x80) === 0) {
        tbsLen = certDer[pos];
        pos++;
      } else {
        const lenBytes = certDer[pos] & 0x7F;
        pos++;
        tbsLen = 0;
        for (let i = 0; i < lenBytes; i++) {
          tbsLen = (tbsLen << 8) | certDer[pos + i];
        }
        pos += lenBytes;
      }
      pos += tbsLen; // 跳过 TBS 内容

      // 跳过 signatureAlgorithm (SEQUENCE)
      if (certDer[pos] !== 0x30) {
        console.error('CryptoUtil: signatureAlgorithm 不是 SEQUENCE');
        return certDer;
      }
      pos++; // 跳过 tag
      
      // 解析 signatureAlgorithm 长度并跳过
      let sigAlgLen: number;
      if ((certDer[pos] & 0x80) === 0) {
        sigAlgLen = certDer[pos];
        pos++;
      } else {
        const lenBytes = certDer[pos] & 0x7F;
        pos++;
        sigAlgLen = 0;
        for (let i = 0; i < lenBytes; i++) {
          sigAlgLen = (sigAlgLen << 8) | certDer[pos + i];
        }
        pos += lenBytes;
      }
      pos += sigAlgLen; // 跳过 signatureAlgorithm 内容

      // 现在应该是 BIT STRING (signatureValue)
      if (certDer[pos] !== 0x03) {
        console.error('CryptoUtil: signatureValue 不是 BIT STRING');
        return certDer;
      }
      pos++; // 跳过 tag

      // 解析 BIT STRING 长度
      let bitStringLen: number;
      if ((certDer[pos] & 0x80) === 0) {
        bitStringLen = certDer[pos];
        pos++;
      } else {
        const lenBytes = certDer[pos] & 0x7F;
        pos++;
        bitStringLen = 0;
        for (let i = 0; i < lenBytes; i++) {
          bitStringLen = (bitStringLen << 8) | certDer[pos + i];
        }
        pos += lenBytes;
      }

      // 跳过 unused bits 字节
      pos++;
      bitStringLen--;

      // 提取签名
      const signature = certDer.slice(pos, pos + bitStringLen);
      console.info(`CryptoUtil: 提取签名成功，长度 = ${signature.length}`);
      return signature;
    } catch (err) {
      console.error('CryptoUtil: 提取签名失败', err);
      return certDer;
    }
  }

  /**
   * 将 DER 编码的证书转换为 PEM 格式
   */
  static derToPem(der: Uint8Array): string {
    const base64 = CryptoUtil.base64Encode(der);
    const lines: string[] = [];
    lines.push('-----BEGIN CERTIFICATE-----');
    for (let i = 0; i < base64.length; i += 64) {
      lines.push(base64.substring(i, Math.min(i + 64, base64.length)));
    }
    lines.push('-----END CERTIFICATE-----');
    return lines.join('\n');
  }

  /**
   * 将 PEM 格式证书转换为 DER
   */
  static pemToDer(pem: string): Uint8Array {
    // 移除 PEM 头尾和所有空白字符
    const lines = pem.split('\n');
    let base64 = '';
    
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.length === 0) continue;
      if (trimmed.startsWith('-----BEGIN')) continue;
      if (trimmed.startsWith('-----END')) continue;
      base64 += trimmed;
    }
    
    // Base64 解码得到 DER
    return CryptoUtil.base64Decode(base64);
  }

  /**
   * 获取 PEM 编码的证书字节（用于配对）
   */
  static getPemCertBytes(der: Uint8Array): Uint8Array {
    const pem = CryptoUtil.derToPem(der);
    const textEncoder = new util.TextEncoder();
    return textEncoder.encodeInto(pem);
  }

  /**
   * Base64 编码
   */
  static base64Encode(data: Uint8Array): string {
    const base64Helper = new util.Base64Helper();
    return base64Helper.encodeToStringSync(data);
  }

  /**
   * Base64 解码
   */
  static base64Decode(base64: string): Uint8Array {
    const base64Helper = new util.Base64Helper();
    return base64Helper.decodeSync(base64);
  }

  /**
   * 生成4位数字PIN码
   */
  static generatePin(): string {
    const bytes = CryptoUtil.generateRandomBytes(4);
    let pin = '';
    for (let i = 0; i < 4; i++) {
      pin += (bytes[i] % 10).toString();
    }
    return pin;
  }

  /**
   * Salt + PIN 合并
   */
  static saltPin(salt: Uint8Array, pin: string): Uint8Array {
    const textEncoder = new util.TextEncoder();
    const pinBytes = textEncoder.encodeInto(pin);
    return CryptoUtil.concatBytes(salt, pinBytes);
  }
}
