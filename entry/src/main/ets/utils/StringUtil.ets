/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { util } from '@kit.ArkTS';
import { CryptoUtil } from './CryptoUtil';

/**
 * 字符串工具类
 * 
 * 统一处理字符串转换操作
 */
export class StringUtil {
  private static textDecoder: util.TextDecoder | null = null;
  private static textEncoder: util.TextEncoder | null = null;

  /**
   * 获取 TextDecoder 实例（单例）
   */
  private static getTextDecoder(): util.TextDecoder {
    if (!StringUtil.textDecoder) {
      StringUtil.textDecoder = util.TextDecoder.create('utf-8');
    }
    return StringUtil.textDecoder;
  }

  /**
   * 获取 TextEncoder 实例（单例）
   */
  private static getTextEncoder(): util.TextEncoder {
    if (!StringUtil.textEncoder) {
      StringUtil.textEncoder = new util.TextEncoder();
    }
    return StringUtil.textEncoder;
  }

  /**
   * 将 ArrayBuffer 转换为字符串
   * @param buffer ArrayBuffer
   * @returns UTF-8 字符串
   */
  static arrayBufferToString(buffer: ArrayBuffer): string {
    return StringUtil.getTextDecoder().decodeToString(new Uint8Array(buffer));
  }

  /**
   * 将 Uint8Array 转换为字符串
   * @param array Uint8Array
   * @returns UTF-8 字符串
   */
  static uint8ArrayToString(array: Uint8Array): string {
    return StringUtil.getTextDecoder().decodeToString(array);
  }

  /**
   * 将字符串转换为 Uint8Array
   * @param str 字符串
   * @returns UTF-8 编码的 Uint8Array
   */
  static stringToUint8Array(str: string): Uint8Array {
    return StringUtil.getTextEncoder().encodeInto(str);
  }

  /**
   * 生成 UUID（使用加密安全的随机数）
   * @returns UUID 字符串
   */
  static generateUUID(): string {
    // 使用加密安全的随机数生成 16 字节
    const randomBytes = CryptoUtil.generateRandomBytes(16);
    
    // 设置版本号 (4) 和变体位
    randomBytes[6] = (randomBytes[6] & 0x0f) | 0x40;  // version 4
    randomBytes[8] = (randomBytes[8] & 0x3f) | 0x80;  // variant 1
    
    // 转换为 UUID 格式
    const hex = CryptoUtil.bytesToHex(randomBytes).toLowerCase();
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
  }
}
