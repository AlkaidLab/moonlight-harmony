/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * HUKS 设备密钥加密服务
 *
 * 使用 HarmonyOS Universal Keystore (HUKS) 管理 AES-256-GCM 设备绑定密钥，
 * 对备份文件进行自动加密/解密。密钥存储在 TEE 中，卸载重装后仍然可用。
 *
 * 加密数据格式：
 *   [5 bytes] 文件头 "MLBK" + 版本号 0x01
 *   [12 bytes] GCM Nonce（每次加密随机生成）
 *   [N bytes]  AES-256-GCM 密文
 *   [16 bytes] GCM 认证标签（由 HUKS 追加在密文末尾）
 */

import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const TAG = '[CryptoService]';
const KEY_ALIAS = 'moonlight_backup_aes256';
const GCM_NONCE_SIZE = 12;
const GCM_TAG_SIZE = 16;

/** 加密文件魔数头：'M','L','B','K', version=1 */
const MAGIC = new Uint8Array([0x4D, 0x4C, 0x42, 0x4B, 0x01]);
const HEADER_SIZE = MAGIC.length + GCM_NONCE_SIZE; // 17 bytes

export class CryptoService {

  /**
   * 确保 HUKS 中存在 AES-256 密钥，不存在则生成
   */
  static async ensureKey(): Promise<void> {
    try {
      const exists = await huks.isKeyItemExist(KEY_ALIAS, { properties: [] });
      if (exists) return;
    } catch {
      // isKeyItemExist 不可用或密钥不存在
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
    console.info(`${TAG} 已在 HUKS 中生成 AES-256 密钥`);
  }

  /**
   * 加密明文字符串 → 二进制数据（MAGIC + NONCE + CIPHER + TAG）
   */
  static async encrypt(plaintext: string): Promise<Uint8Array> {
    await CryptoService.ensureKey();

    // 生成随机 12 字节 Nonce
    const rand = cryptoFramework.createRandom();
    const nonceBlob = rand.generateRandomSync(GCM_NONCE_SIZE);
    const nonce = new Uint8Array(nonceBlob.data);

    const encoder = new util.TextEncoder();
    const plainData = encoder.encodeInto(plaintext);

    const encryptProps: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
    ];

    const initResult = await huks.initSession(KEY_ALIAS, { properties: encryptProps });
    const handle = initResult.handle;

    // 对于较大数据，分块 update 后 finish
    const CHUNK_SIZE = 60 * 1024; // 60KB per chunk (HUKS limit ~64KB)
    let offset = 0;
    while (offset + CHUNK_SIZE < plainData.length) {
      const chunk = plainData.slice(offset, offset + CHUNK_SIZE);
      await huks.updateSession(handle, { properties: encryptProps, inData: chunk });
      offset += CHUNK_SIZE;
    }

    // finishSession 处理剩余数据
    const remaining = plainData.slice(offset);
    const finishOptions: huks.HuksOptions = { properties: encryptProps, inData: remaining };
    const finishResult = await huks.finishSession(handle, finishOptions);
    const cipherWithTag = finishResult.outData as Uint8Array;

    // 拼接输出：MAGIC(5) + NONCE(12) + CIPHER+TAG(N)
    const result = new Uint8Array(MAGIC.length + nonce.length + cipherWithTag.length);
    result.set(MAGIC, 0);
    result.set(nonce, MAGIC.length);
    result.set(cipherWithTag, MAGIC.length + nonce.length);

    console.info(`${TAG} 加密完成: ${plaintext.length} bytes → ${result.length} bytes`);
    return result;
  }

  /**
   * 解密二进制数据 → 明文字符串
   */
  static async decrypt(data: Uint8Array): Promise<string> {
    if (data.length < HEADER_SIZE + GCM_TAG_SIZE) {
      throw new Error('加密数据太短');
    }

    // 验证魔数头
    for (let i = 0; i < MAGIC.length; i++) {
      if (data[i] !== MAGIC[i]) {
        throw new Error('无效的加密文件格式');
      }
    }

    const nonce = data.slice(MAGIC.length, MAGIC.length + GCM_NONCE_SIZE);
    const cipherWithTag = data.slice(HEADER_SIZE);
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

    // 分块 update
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
    console.info(`${TAG} 解密完成: ${data.length} bytes → ${plaintext.length} chars`);
    return plaintext;
  }

  /**
   * 检查数据是否为加密格式（以 MLBK 魔数开头）
   */
  static isEncrypted(data: Uint8Array): boolean {
    if (data.length < MAGIC.length) return false;
    for (let i = 0; i < MAGIC.length; i++) {
      if (data[i] !== MAGIC[i]) return false;
    }
    return true;
  }
}
