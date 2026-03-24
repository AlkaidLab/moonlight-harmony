/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * 开发者模式激活码验证器
 * 基于设备 uniqueId + 盐值的 SHA-256 哈希生成一机一码
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { DEV_KEY_SALT } from '../config/DevKeySecret';

export class DevKeyVerifier {
  /**
   * 获取设备 ID（从 uniqueId 文件读取，与 NvHttp 共用）
   * 返回前 8 位大写 hex 作为展示用 ID
   */
  static getDeviceId(context: common.Context): string {
    const uniqueIdPath = context.filesDir + '/unique_id.txt';
    try {
      if (fileIo.accessSync(uniqueIdPath)) {
        const file = fileIo.openSync(uniqueIdPath, fileIo.OpenMode.READ_ONLY);
        const stat = fileIo.statSync(uniqueIdPath);
        const buffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buffer);
        fileIo.closeSync(file);
        const textDecoder = util.TextDecoder.create('utf-8');
        return textDecoder.decodeToString(new Uint8Array(buffer)).trim();
      }
    } catch (err) {
      console.error(`DevKeyVerifier: 无法读取设备 ID: ${err}`);
    }
    return '';
  }

  /**
   * 验证激活码是否正确（同步）
   */
  static verify(deviceId: string, inputKey: string): boolean {
    if (!deviceId || !inputKey) {
      return false;
    }
    const expectedKey = DevKeyVerifier.computeKey(deviceId);
    return expectedKey === inputKey.toUpperCase().trim();
  }

  /**
   * 根据设备 ID 计算激活码（同步）
   * SHA-256(salt + deviceId) 取前 8 位大写 hex
   */
  static computeKey(deviceId: string): string {
    const payload = DEV_KEY_SALT + deviceId.toLowerCase();
    const encoder = new util.TextEncoder();
    const data = encoder.encodeInto(payload);
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data } as cryptoFramework.DataBlob);
    const digest = md.digestSync();
    const bytes = new Uint8Array(digest.data);
    // 取前 4 字节 = 8 位 hex
    let hex = '';
    for (let i = 0; i < 4; i++) {
      hex += (bytes[i] & 0xFF).toString(16).toUpperCase().padStart(2, '0');
    }
    return hex;
  }
}
