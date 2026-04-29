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
import { NvHttp } from '../service/streaming/NvHttp';

const TAG = 'NetErrorClassifierCheck';
const DOMAIN = 0x0000;

/**
 * 网络错误分类契约自检
 *
 * 鸿蒙工程没有引入 ohosTest 框架，无法跑传统单元测试。
 * 本文件作为「启动期自检」替代方案，对 NvHttp.isTransientNetworkError
 * 这种纯函数契约做断言，挂表立即在日志看到。
 *
 * 为什么只测 isTransientNetworkError：
 * - 它直接决定 ServerInfo 等关键路径是否进入 robust retry 兜底
 * - 漏判 → 用户看到偶发失败；误判 → 浪费 retry 配额（可接受）
 * - HttpClient.isConnectionError 私有，且漏判后果较轻（最多多重连一次 session）
 *
 * 任何修改 isTransientNetworkError 关键词集合的人都应同步更新本文件，
 * 否则启动 hilog 会报告契约破坏。
 */
interface ClassifierCase {
  msg: string;
  expected: boolean;
  reason: string;
}

const TRANSIENT_CASES: ClassifierCase[] = [
  // 必须算瞬时（应 retry）
  { msg: 'Connection timeout', expected: true, reason: 'timeout 是典型瞬时错误' },
  { msg: 'request timed out', expected: true, reason: 'timeout 变体' },
  { msg: 'Error code: 1007900028', expected: true, reason: 'rcp Timeout 错误码' },
  { msg: 'Connection refused', expected: true, reason: 'TCP refused 是连接级瞬时' },
  { msg: 'Network unreachable', expected: true, reason: '网络层不可达' },
  { msg: 'Could not resolve host: example.com', expected: true, reason: 'DNS 失败' },
  { msg: 'getaddrinfo ENOTFOUND', expected: true, reason: 'DNS 失败变体' },
  { msg: 'connect failed', expected: true, reason: 'rcp connect 失败' },
  { msg: 'Connection reset by peer', expected: true, reason: 'TCP RST 应走 retry 自愈' },
  { msg: 'ECONNRESET', expected: true, reason: 'TCP RST 变体' },
  { msg: 'Request was canceled', expected: true, reason: '被 session.close() 级联取消' },
  { msg: 'Operation cancelled', expected: true, reason: '英式拼写变体' },
  { msg: 'Error code: 1007900003', expected: true, reason: 'rcp Canceled 错误码' },
  // 大小写边界
  { msg: 'TIMEOUT', expected: true, reason: '全大写应被 lowercase 后匹配' },

  // 必须不算瞬时（不应 retry，是真实业务错误）
  { msg: 'HTTP 401 Unauthorized', expected: false, reason: '认证失败不应静默重试' },
  { msg: 'HTTP 404 Not Found', expected: false, reason: '资源不存在' },
  { msg: 'HTTP 500 Internal Server Error', expected: false, reason: '服务端真实错误' },
  { msg: 'Certificate verification failed', expected: false, reason: '证书错误必须暴露' },
  { msg: 'Invalid response format', expected: false, reason: '协议层错误' },
  // 边界：空消息不应被算瞬时（避免无消息时疯狂重试）
  { msg: '', expected: false, reason: '空字符串不匹配任何关键词' },
];

/**
 * 已知的"子串歧义"用例：理论上业务消息含 timeout 等关键词会被误判瞬时。
 * 实际 Sunshine 错误消息把 HTTP 状态码独立返回，不会出现这类拼接，
 * 所以这里只断言"如果将来出现这种歧义消息，行为是被算作瞬时（重试 N 次后失败）"。
 * 用于显式记录 trade-off，避免未来误以为是 bug。
 */
const KNOWN_AMBIGUOUS_CASES: ClassifierCase[] = [
  { msg: '401 Auth token timeout', expected: true, reason: '子串歧义：timeout 触发瞬时（trade-off 接受）' },
];

export class NetworkErrorClassifierSelfCheck {
  /**
   * 启动时调用一次。失败仅日志告警，不阻断应用启动。
   * @returns 失败用例数（0 表示全部通过）
   */
  static run(): number {
    let failed = 0;
    // 1. 关键词集合契约
    for (const c of TRANSIENT_CASES) {
      const actual = NvHttp.isTransientNetworkError(c.msg);
      if (actual !== c.expected) {
        failed++;
        hilog.error(DOMAIN, TAG,
          'CONTRACT BROKEN: isTransientNetworkError(%{public}s) = %{public}s, expected %{public}s — %{public}s',
          c.msg, String(actual), String(c.expected), c.reason);
      }
    }
    // 2. 子串歧义已知 trade-off（行为变化时也提醒一下）
    for (const c of KNOWN_AMBIGUOUS_CASES) {
      const actual = NvHttp.isTransientNetworkError(c.msg);
      if (actual !== c.expected) {
        hilog.warn(DOMAIN, TAG,
          'AMBIGUOUS CASE CHANGED: isTransientNetworkError(%{public}s) = %{public}s, was %{public}s — review needed',
          c.msg, String(actual), String(c.expected));
      }
    }
    // 3. Error 对象与 string 等价性（实现里 typeof err === 'string' 分支）
    const errCase = new Error('Connection timeout');
    if (NvHttp.isTransientNetworkError(errCase) !== NvHttp.isTransientNetworkError(errCase.message)) {
      failed++;
      hilog.error(DOMAIN, TAG, 'Error vs string disagreement: same payload should classify identically');
    }

    if (failed === 0) {
      hilog.info(DOMAIN, TAG, 'self-check passed (%{public}d cases + Error/string equivalence)', TRANSIENT_CASES.length);
    } else {
      hilog.error(DOMAIN, TAG, 'self-check FAILED: %{public}d cases broken', failed);
    }
    return failed;
  }
}
