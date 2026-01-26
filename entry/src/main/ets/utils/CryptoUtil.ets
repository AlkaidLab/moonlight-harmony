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
   * 字节数组转十六进制字符串（大写）
   */
  static bytesToHex(bytes: Uint8Array): string {
    const hexArray = '0123456789ABCDEF';
    let result = '';
    for (let i = 0; i < bytes.length; i++) {
      const v = bytes[i] & 0xFF;
      result += hexArray[v >>> 4];
      result += hexArray[v & 0x0F];
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
   * SHA-256 哈希
   */
  static async sha256(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: data });
    const result = await md.digest();
    return new Uint8Array(result.data);
  }

  /**
   * SHA-1 哈希（用于旧版本服务器）
   */
  static async sha1(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA1');
    await md.update({ data: data });
    const result = await md.digest();
    return new Uint8Array(result.data);
  }

  /**
   * 生成 AES 密钥（从哈希数据中取前16字节）
   */
  static generateAesKey(hashData: Uint8Array): Uint8Array {
    return hashData.slice(0, 16);
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
    const keyBlob: cryptoFramework.DataBlob = { data: key };
    const symKey = await symKeyGenerator.convertKey(keyBlob);

    // 创建 Cipher（ECB 模式，无填充）
    const cipher = cryptoFramework.createCipher('AES128|ECB|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, null);

    const result = await cipher.doFinal({ data: paddedData });
    return new Uint8Array(result.data);
  }

  /**
   * AES ECB 解密
   */
  static async aesDecrypt(ciphertext: Uint8Array, key: Uint8Array): Promise<Uint8Array> {
    // 创建 AES 密钥
    const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    const keyBlob: cryptoFramework.DataBlob = { data: key };
    const symKey = await symKeyGenerator.convertKey(keyBlob);

    // 创建 Cipher（ECB 模式，无填充）
    const cipher = cryptoFramework.createCipher('AES128|ECB|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, null);

    const result = await cipher.doFinal({ data: ciphertext });
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
    await signer.update({ data: data });
    const signData = await signer.sign(null);
    return new Uint8Array(signData.data);
  }

  /**
   * RSA SHA256 验签
   */
  static async rsaVerify(data: Uint8Array, signature: Uint8Array, publicKey: cryptoFramework.PubKey): Promise<boolean> {
    const verifier = cryptoFramework.createVerify('RSA2048|PKCS1|SHA256');
    await verifier.init(publicKey);
    await verifier.update({ data: data });
    return await verifier.verify({ data: signature });
  }

  /**
   * 导出公钥为 DER 格式
   */
  static async exportPublicKeyDer(publicKey: cryptoFramework.PubKey): Promise<Uint8Array> {
    const blob = publicKey.getEncoded();
    return new Uint8Array(blob.data);
  }

  /**
   * 生成自签名 X.509 证书（简化版本）
   * 注意：HarmonyOS 目前没有直接的 X.509 证书生成 API，
   * 这里返回公钥的 DER 编码作为替代
   */
  static async generateSelfSignedCert(keyPair: cryptoFramework.KeyPair): Promise<Uint8Array> {
    // TODO: 使用完整的 X.509 证书格式
    // 目前暂时返回公钥 DER 编码
    return await CryptoUtil.exportPublicKeyDer(keyPair.pubKey);
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
    const pinBytes = new TextEncoder().encode(pin);
    return CryptoUtil.concatBytes(salt, pinBytes);
  }
}
