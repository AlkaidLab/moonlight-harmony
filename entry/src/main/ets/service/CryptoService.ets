/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * 备份加密服务
 *
 * v1 (旧格式): HUKS 设备绑定密钥 — 卸载重装后密钥丢失，旧备份不可恢复
 * v2 (新格式): PBKDF2 密码派生密钥 — 默认密码对用户透明，跨安装可恢复
 *
 * 加密数据格式 v2：
 *   [5 bytes]  文件头 "MLBK" + 版本号 0x02
 *   [16 bytes] PBKDF2 随机盐
 *   [12 bytes] GCM Nonce
 *   [N bytes]  AES-256-GCM 密文 + 16 字节认证标签
 *
 * 加密数据格式 v1 (仅解密兼容)：
 *   [5 bytes]  文件头 "MLBK" + 版本号 0x01
 *   [12 bytes] GCM Nonce
 *   [N bytes]  AES-256-GCM 密文 + 16 字节认证标签（HUKS 密钥）
 */

import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const TAG = '[CryptoService]';
const KEY_ALIAS = 'moonlight_backup_aes256';
const GCM_NONCE_SIZE = 12;
const GCM_TAG_SIZE = 16;
const PBKDF2_SALT_SIZE = 16;
const PBKDF2_ITERATIONS = 100000;

/** v1 魔数头 (HUKS) */
const MAGIC_V1 = new Uint8Array([0x4D, 0x4C, 0x42, 0x4B, 0x01]);
/** v2 魔数头 (PBKDF2) */
const MAGIC_V2 = new Uint8Array([0x4D, 0x4C, 0x42, 0x4B, 0x02]);
const MAGIC_SIZE = 5;

/** 默认密码 — 对用户透明，保证跨安装一致 */
const DEFAULT_PASSWORD = 'moonlight-harmony-backup-2025';

export class CryptoService {

  // ── v2: PBKDF2 密码派生（新格式，跨安装可用）──

  /**
   * 从密码 + 盐派生 AES-256 密钥
   */
  private static async deriveKey(password: string, salt: Uint8Array): Promise<cryptoFramework.SymKey> {
    const kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
    const encoder = new util.TextEncoder();
    const spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: encoder.encodeInto(password),
      salt: salt,
      iterations: PBKDF2_ITERATIONS,
      keySize: 32, // 256 bits
    };
    const secretBlob = await kdf.generateSecret(spec);

    // 将派生的原始密钥材料包装为 SymKey
    const generator = cryptoFramework.createSymKeyGenerator('AES256');
    return await generator.convertKey({ data: secretBlob.data });
  }

  /**
   * v2 加密：PBKDF2 派生密钥 + AES-256-GCM
   */
  static async encrypt(plaintext: string, password?: string): Promise<Uint8Array> {
    const pwd = password || DEFAULT_PASSWORD;

    // 生成随机盐和 Nonce
    const rand = cryptoFramework.createRandom();
    const salt = new Uint8Array(rand.generateRandomSync(PBKDF2_SALT_SIZE).data);
    const nonce = new Uint8Array(rand.generateRandomSync(GCM_NONCE_SIZE).data);

    const symKey = await CryptoService.deriveKey(pwd, salt);
    const encoder = new util.TextEncoder();
    const plainData = encoder.encodeInto(plaintext);

    // AES-256-GCM 加密
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const gcmParams: cryptoFramework.GcmParamsSpec = {
      iv: { data: nonce },
      aad: { data: new Uint8Array(0) },
      authTag: { data: new Uint8Array(GCM_TAG_SIZE) },
      algName: 'GcmParamsSpec',
    };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, gcmParams);

    const updateResult = await cipher.update({ data: plainData });
    const finalResult = await cipher.doFinal(null);

    // 收集密文（update + doFinal 输出）
    const cipherChunks: Uint8Array[] = [];
    let cipherLen = 0;
    if (updateResult) {
      const chunk = new Uint8Array(updateResult.data);
      cipherChunks.push(chunk);
      cipherLen += chunk.length;
    }
    if (finalResult) {
      const chunk = new Uint8Array(finalResult.data);
      cipherChunks.push(chunk);
      cipherLen += chunk.length;
    }

    // GCM authTag: 优先从 gcmParams 获取，fallback 从密文末尾提取
    let authTag: Uint8Array;
    if (gcmParams.authTag.data.length === GCM_TAG_SIZE &&
        gcmParams.authTag.data.some((v: number) => v !== 0)) {
      // framework 回写了 authTag
      authTag = new Uint8Array(gcmParams.authTag.data);
    } else {
      // authTag 追加在密文末尾
      const allCipher = new Uint8Array(cipherLen);
      let off = 0;
      for (const chunk of cipherChunks) {
        allCipher.set(chunk, off); off += chunk.length;
      }
      authTag = allCipher.slice(allCipher.length - GCM_TAG_SIZE);
      // 密文去掉末尾 tag
      cipherChunks.length = 0;
      cipherChunks.push(allCipher.slice(0, allCipher.length - GCM_TAG_SIZE));
      cipherLen = cipherChunks[0].length;
    }

    // 拼接：MAGIC_V2(5) + SALT(16) + NONCE(12) + CIPHER(N) + TAG(16)
    const totalLen = MAGIC_SIZE + PBKDF2_SALT_SIZE + GCM_NONCE_SIZE + cipherLen + GCM_TAG_SIZE;
    const result = new Uint8Array(totalLen);
    let pos = 0;
    result.set(MAGIC_V2, pos); pos += MAGIC_SIZE;
    result.set(salt, pos); pos += PBKDF2_SALT_SIZE;
    result.set(nonce, pos); pos += GCM_NONCE_SIZE;
    for (const chunk of cipherChunks) {
      result.set(chunk, pos); pos += chunk.length;
    }
    result.set(authTag, pos);

    console.info(`${TAG} v2 加密完成: ${plaintext.length} chars → ${result.length} bytes`);
    return result;
  }

  /**
   * v2 解密：PBKDF2 派生密钥 + AES-256-GCM
   */
  private static async decryptV2(data: Uint8Array, password?: string): Promise<string> {
    const minLen = MAGIC_SIZE + PBKDF2_SALT_SIZE + GCM_NONCE_SIZE + GCM_TAG_SIZE;
    if (data.length < minLen) {
      throw new Error('v2 加密数据太短');
    }

    const pwd = password || DEFAULT_PASSWORD;
    let pos = MAGIC_SIZE;
    const salt = data.slice(pos, pos + PBKDF2_SALT_SIZE); pos += PBKDF2_SALT_SIZE;
    const nonce = data.slice(pos, pos + GCM_NONCE_SIZE); pos += GCM_NONCE_SIZE;
    const payload = data.slice(pos); // cipher + tag
    const ciphertext = payload.slice(0, payload.length - GCM_TAG_SIZE);
    const authTag = payload.slice(payload.length - GCM_TAG_SIZE);

    const symKey = await CryptoService.deriveKey(pwd, salt);

    const decipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const gcmParams: cryptoFramework.GcmParamsSpec = {
      iv: { data: nonce },
      aad: { data: new Uint8Array(0) },
      authTag: { data: authTag },
      algName: 'GcmParamsSpec',
    };
    await decipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams);

    let plainChunks: Uint8Array[] = [];
    let plainLen = 0;
    if (ciphertext.length > 0) {
      const updateResult = await decipher.update({ data: ciphertext });
      if (updateResult) {
        const chunk = new Uint8Array(updateResult.data);
        plainChunks.push(chunk);
        plainLen += chunk.length;
      }
    }
    const finalResult = await decipher.doFinal(null);
    if (finalResult) {
      const chunk = new Uint8Array(finalResult.data);
      plainChunks.push(chunk);
      plainLen += chunk.length;
    }

    // 合并明文
    const plainData = new Uint8Array(plainLen);
    let offset = 0;
    for (const chunk of plainChunks) {
      plainData.set(chunk, offset);
      offset += chunk.length;
    }

    const decoder = new util.TextDecoder('utf-8');
    const plaintext = decoder.decodeToString(plainData);
    console.info(`${TAG} v2 解密完成: ${data.length} bytes → ${plaintext.length} chars`);
    return plaintext;
  }

  // ── v1: HUKS 兼容（仅解密旧文件）──

  /**
   * 确保 HUKS 中存在 AES-256 密钥
   */
  private static async ensureHuksKey(): Promise<void> {
    try {
      const exists = await huks.isKeyItemExist(KEY_ALIAS, { properties: [] });
      if (exists) return;
    } catch {
      // 密钥不存在
    }

    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      {
        tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT |
          huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
      },
    ];
    await huks.generateKeyItem(KEY_ALIAS, { properties });
  }

  /**
   * v1 解密（HUKS 设备绑定密钥）— 仅用于兼容旧格式
   */
  private static async decryptV1(data: Uint8Array): Promise<string> {
    const headerSize = MAGIC_SIZE + GCM_NONCE_SIZE; // 17
    if (data.length < headerSize + GCM_TAG_SIZE) {
      throw new Error('v1 加密数据太短');
    }

    await CryptoService.ensureHuksKey();

    const nonce = data.slice(MAGIC_SIZE, MAGIC_SIZE + GCM_NONCE_SIZE);
    const cipherWithTag = data.slice(headerSize);
    const ciphertext = cipherWithTag.slice(0, cipherWithTag.length - GCM_TAG_SIZE);
    const authTag = cipherWithTag.slice(cipherWithTag.length - GCM_TAG_SIZE);

    const decryptProps: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
      { tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: authTag },
    ];

    const initResult = await huks.initSession(KEY_ALIAS, { properties: decryptProps });
    const handle = initResult.handle;

    const CHUNK_SIZE = 60 * 1024;
    let offset = 0;
    while (offset + CHUNK_SIZE < ciphertext.length) {
      const chunk = ciphertext.slice(offset, offset + CHUNK_SIZE);
      await huks.updateSession(handle, { properties: decryptProps, inData: chunk });
      offset += CHUNK_SIZE;
    }

    const remaining = ciphertext.slice(offset);
    const finishOptions: huks.HuksOptions = { properties: decryptProps, inData: remaining };
    const finishResult = await huks.finishSession(handle, finishOptions);
    const plainData = finishResult.outData as Uint8Array;

    const decoder = new util.TextDecoder('utf-8');
    const plaintext = decoder.decodeToString(plainData);
    console.info(`${TAG} v1 解密完成: ${data.length} bytes → ${plaintext.length} chars`);
    return plaintext;
  }

  // ── 统一接口 ──

  /**
   * 解密：自动识别 v1/v2 格式
   * v1 → HUKS 解密（旧格式，可能因密钥丢失而失败）
   * v2 → PBKDF2 解密（新格式，跨安装可用）
   */
  static async decrypt(data: Uint8Array, password?: string): Promise<string> {
    const version = CryptoService.getVersion(data);
    if (version === 2) {
      return CryptoService.decryptV2(data, password);
    } else if (version === 1) {
      return CryptoService.decryptV1(data);
    }
    throw new Error('不支持的加密格式');
  }

  /**
   * 检查数据是否为加密格式（MLBK 魔数）
   */
  static isEncrypted(data: Uint8Array): boolean {
    return CryptoService.getVersion(data) > 0;
  }

  /**
   * 获取加密格式版本号，非加密数据返回 0
   */
  static getVersion(data: Uint8Array): number {
    if (data.length < MAGIC_SIZE) return 0;
    // 检查前 4 字节 "MLBK"
    if (data[0] !== 0x4D || data[1] !== 0x4C || data[2] !== 0x42 || data[3] !== 0x4B) return 0;
    return data[4]; // version byte
  }
}
