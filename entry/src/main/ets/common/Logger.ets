/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

/** 应用日志域，'ML' 的十六进制，用于 hilog 过滤本应用日志 */
const DOMAIN = 0x4D4C;

/**
 * 统一日志封装（基于 hilog）。
 *
 * 全局 console.* 无级别/域名控制，且官方废弃清单要求迁移到 hilog。
 * 各文件以文件名为 tag 调用，便于 hilog 按模块过滤：
 *   Logger.info('StreamViewModel', 'load done', computerId);
 */
export class Logger {
  /** 与 console.debug 等价。debug 级别默认不输出，需开发者在设备上开启 hilog debug */
  static debug(tag: string, ...args: (Object | undefined)[]): void {
    hilog.debug(DOMAIN, tag, '%{public}s', Logger.join(args));
  }

  static info(tag: string, ...args: (Object | undefined)[]): void {
    hilog.info(DOMAIN, tag, '%{public}s', Logger.join(args));
  }

  static warn(tag: string, ...args: (Object | undefined)[]): void {
    hilog.warn(DOMAIN, tag, '%{public}s', Logger.join(args));
  }

  static error(tag: string, ...args: (Object | undefined)[]): void {
    hilog.error(DOMAIN, tag, '%{public}s', Logger.join(args));
  }

  /** 将 console 风格的多参数拼接为单条消息（空格分隔），undefined 原样输出 */
  private static join(args: (Object | undefined)[]): string {
    let msg = '';
    for (const a of args) {
      msg += (msg.length > 0 ? ' ' : '') + (a === undefined ? 'undefined' : String(a));
    }
    return msg;
  }
}
