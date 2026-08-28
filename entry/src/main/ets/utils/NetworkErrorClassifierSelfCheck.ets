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
import { WakeOnLan } from '../service/network/WakeOnLan';
import {
  AddressType,
  detectAddressType,
  formatAddressForUrl,
  getBestIpv6Address,
  isIPv4Address,
  isIPv6Global,
  isLanAddress,
  isPrivateIPv4,
  isPublicAddress,
  parseAddressAndPort,
  parseRtspSessionHost,
} from './NetHelper';
import { formatDisplayAddress, selectBestAddress } from '../model/ComputerInfo';
import { ConnectionPath, ConnectionPathService } from '../service/network/ConnectionPathService';

const TAG = 'NetworkSelfCheck';
const DOMAIN = 0x0000;

/**
 * 网络契约自检
 *
 * 鸿蒙工程没有引入 ohosTest 框架，无法跑传统单元测试。
 * 本文件作为「启动期自检」替代方案，对网络层的纯函数契约做断言，
 * 挂表立即在日志看到。
 *
 * 覆盖范围：
 * - NvHttp.isTransientNetworkError：robust retry 是否触发
 * - NetHelper：地址分类、端口解析、URL 格式化
 * - WakeOnLan.isValidMacAddress：WOL 输入格式校验
 * - selectBestAddress：连接地址优先级模型
 *
 * 为什么优先测这些：
 * - 它直接决定 ServerInfo 等关键路径是否进入 robust retry 兜底
 * - 地址分类/选择错误会导致 LAN/WAN/IPv6 连接走错目标
 * - WOL MAC 格式错误会生成无效魔术包
 * - 漏判 → 用户看到偶发失败；误判 → 浪费 retry 配额（可接受）
 * - 所有用例均为纯函数，不触发真实 DNS/UDP/HTTP 请求
 *
 * 任何修改网络错误关键词、地址分类规则、地址优先级的人都应同步更新本文件，
 * 否则启动 hilog 会报告契约破坏。
 */
interface ClassifierCase {
  msg: string;
  expected: boolean;
  reason: string;
}

type Comparable = string | number | boolean | undefined;

interface BooleanCase {
  name: string;
  actual: boolean;
  expected: boolean;
  reason: string;
}

interface StringCase {
  name: string;
  actual: string | undefined;
  expected: string | undefined;
  reason: string;
}

interface AddressParseCase {
  input: string;
  expectedHost: string;
  expectedPort?: number;
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
    failed += NetworkErrorClassifierSelfCheck.runTransientErrorCases();
    failed += NetworkErrorClassifierSelfCheck.runNetHelperCases();
    failed += NetworkErrorClassifierSelfCheck.runConnectionPathCases();
    failed += NetworkErrorClassifierSelfCheck.runWakeOnLanCases();
    failed += NetworkErrorClassifierSelfCheck.runAddressSelectionCases();
    failed += NetworkErrorClassifierSelfCheck.runDisplayAddressCases();

    if (failed === 0) {
      hilog.info(DOMAIN, TAG, 'network self-check passed');
    } else {
      hilog.error(DOMAIN, TAG, 'network self-check FAILED: %{public}d cases broken', failed);
    }
    return failed;
  }

  private static runTransientErrorCases(): number {
    let failed = 0;
    for (const c of TRANSIENT_CASES) {
      failed += NetworkErrorClassifierSelfCheck.expectEqual(
        'NvHttp.isTransientNetworkError',
        `message=${c.msg}`,
        NvHttp.isTransientNetworkError(c.msg),
        c.expected,
        c.reason);
    }
    for (const c of KNOWN_AMBIGUOUS_CASES) {
      const actual = NvHttp.isTransientNetworkError(c.msg);
      if (actual !== c.expected) {
        hilog.warn(DOMAIN, TAG,
          'AMBIGUOUS CASE CHANGED: isTransientNetworkError(%{public}s) = %{public}s, was %{public}s — review needed',
          c.msg, String(actual), String(c.expected));
      }
    }
    const errCase = new Error('Connection timeout');
    failed += NetworkErrorClassifierSelfCheck.expectEqual(
      'NvHttp.isTransientNetworkError',
      'Error vs string equivalence',
      NvHttp.isTransientNetworkError(errCase),
      NvHttp.isTransientNetworkError(errCase.message),
      '同一错误负载用 Error 或 string 传入应分类一致');

    if (failed === 0) {
      hilog.info(DOMAIN, TAG, 'transient error classifier self-check passed (%{public}d cases + equivalence)',
        TRANSIENT_CASES.length);
    } else {
      hilog.error(DOMAIN, TAG, 'transient error classifier self-check FAILED: %{public}d cases broken', failed);
    }
    return failed;
  }

  private static runNetHelperCases(): number {
    let failed = 0;

    const boolCases: BooleanCase[] = [
      { name: 'isIPv4Address 192.168.1.10', actual: isIPv4Address('192.168.1.10'), expected: true, reason: '标准 IPv4' },
      { name: 'isIPv4Address 256.1.1.1', actual: isIPv4Address('256.1.1.1'), expected: false, reason: 'IPv4 字节不能超过 255' },
      { name: 'isIPv4Address 01.2.3.4', actual: isIPv4Address('01.2.3.4'), expected: false, reason: '拒绝带前导零的歧义 IPv4' },
      { name: 'isPrivateIPv4 10/8', actual: isPrivateIPv4('10.2.3.4'), expected: true, reason: 'RFC1918 10/8' },
      { name: 'isPrivateIPv4 172.16/12 lower', actual: isPrivateIPv4('172.16.0.1'), expected: true, reason: 'RFC1918 172.16 起点' },
      { name: 'isPrivateIPv4 172.31/12 upper', actual: isPrivateIPv4('172.31.255.254'), expected: true, reason: 'RFC1918 172.31 终点' },
      { name: 'isPrivateIPv4 172.32 outside', actual: isPrivateIPv4('172.32.0.1'), expected: false, reason: '172.32 已是公网段' },
      { name: 'isPrivateIPv4 192.168/16', actual: isPrivateIPv4('192.168.50.2'), expected: true, reason: 'RFC1918 192.168/16' },
      { name: 'isLanAddress IPv4 with port', actual: isLanAddress('192.168.1.10:47989'), expected: true, reason: '解析 IPv4:port 后识别 LAN' },
      { name: 'isLanAddress IPv4 link-local', actual: isLanAddress('169.254.1.10'), expected: true, reason: 'IPv4 link-local 视为 LAN' },
      { name: 'isLanAddress bracket IPv6 link-local', actual: isLanAddress('[fe80::1%wlan0]:47989'), expected: true, reason: 'IPv6 link-local 带 scope/port' },
      { name: 'isLanAddress IPv6 ULA', actual: isLanAddress('fd00::1234'), expected: true, reason: 'IPv6 ULA 视为 LAN' },
      { name: 'isPublicAddress IPv4 WAN', actual: isPublicAddress('8.8.8.8'), expected: true, reason: '公网 IPv4' },
      { name: 'isPublicAddress private IPv4', actual: isPublicAddress('192.168.1.10'), expected: false, reason: '私网 IPv4 不应算 WAN' },
      { name: 'isPublicAddress IPv6 global', actual: isPublicAddress('2001:4860:4860::8888'), expected: true, reason: 'IPv6 全局单播' },
      { name: 'isPublicAddress IPv6 6to4 tunnel', actual: isPublicAddress('2002:c000:0201::1'), expected: false, reason: '6to4 隧道不作为优选公网 IPv6' },
      { name: 'isPublicAddress IPv6 Teredo tunnel', actual: isPublicAddress('2001:0:4136:e378:8000:63bf:3fff:fdd2'), expected: false, reason: 'Teredo 隧道不作为优选公网 IPv6' },
      { name: 'isIPv6Global global', actual: isIPv6Global('240e:1234::1'), expected: true, reason: '普通 IPv6 全局单播' },
      { name: 'isIPv6Global ULA', actual: isIPv6Global('fc00::1'), expected: false, reason: 'ULA 不是全局地址' },
    ];

    for (const c of boolCases) {
      failed += NetworkErrorClassifierSelfCheck.expectEqual('NetHelper', c.name, c.actual, c.expected, c.reason);
    }

    const typeCases: StringCase[] = [
      { name: 'detectAddressType loopback IPv4', actual: detectAddressType('127.0.0.1'), expected: AddressType.LOOPBACK, reason: 'IPv4 loopback' },
      { name: 'detectAddressType LAN IPv4', actual: detectAddressType('10.0.0.5'), expected: AddressType.LAN_IPV4, reason: '私网 IPv4' },
      { name: 'detectAddressType WAN IPv4', actual: detectAddressType('1.1.1.1'), expected: AddressType.WAN, reason: '公网 IPv4' },
      { name: 'detectAddressType IPv6 loopback', actual: detectAddressType('::1'), expected: AddressType.LOOPBACK, reason: 'IPv6 loopback' },
      { name: 'detectAddressType IPv6 link-local', actual: detectAddressType('fe80::abcd'), expected: AddressType.IPV6_LINK_LOCAL, reason: 'IPv6 link-local' },
      { name: 'detectAddressType IPv6 ULA', actual: detectAddressType('fd12::1'), expected: AddressType.IPV6_ULA, reason: 'IPv6 ULA' },
      { name: 'detectAddressType IPv6 tunnel', actual: detectAddressType('2002:c000:0201::1'), expected: AddressType.IPV6_TUNNEL, reason: 'IPv6 6to4 隧道' },
      { name: 'detectAddressType IPv6 global', actual: detectAddressType('240e:1234::1'), expected: AddressType.IPV6_GLOBAL, reason: 'IPv6 全局地址' },
      { name: 'detectAddressType hostname', actual: detectAddressType('moonlight.example.com'), expected: AddressType.UNKNOWN, reason: '域名无法静态分类' },
      { name: 'getBestIpv6Address skips tunnels', actual: getBestIpv6Address(['fe80::1', '2002:c000:0201::1', '240e:1234::1']), expected: '240e:1234::1', reason: '优选全局 IPv6，跳过 link-local/tunnel' },
      { name: 'formatAddressForUrl IPv4', actual: formatAddressForUrl('192.168.1.10'), expected: '192.168.1.10', reason: 'IPv4 不加方括号' },
      { name: 'formatAddressForUrl IPv6', actual: formatAddressForUrl('fe80::1'), expected: '[fe80::1]', reason: 'URL 中 IPv6 必须加方括号' },
      { name: 'formatAddressForUrl bracket IPv6', actual: formatAddressForUrl('[::1]'), expected: '[::1]', reason: '已有方括号不重复添加' },
      { name: 'parseRtspSessionHost IPv4', actual: parseRtspSessionHost('rtsp://192.168.1.10:48010'), expected: '192.168.1.10', reason: '提取 Sunshine 返回的 IPv4 RTSP 主机' },
      { name: 'parseRtspSessionHost IPv6', actual: parseRtspSessionHost('rtspenc://[240e:1234::10]:48010'), expected: '240e:1234::10', reason: '提取 Sunshine 返回的带方括号 IPv6 RTSP 主机' },
      { name: 'parseRtspSessionHost rejects HTTP', actual: parseRtspSessionHost('https://sunshine.example.com:47984'), expected: '', reason: '只接受 RTSP 会话 URL' },
    ];

    for (const c of typeCases) {
      failed += NetworkErrorClassifierSelfCheck.expectEqual('NetHelper', c.name, c.actual, c.expected, c.reason);
    }

    const parseCases: AddressParseCase[] = [
      { input: '192.168.1.10', expectedHost: '192.168.1.10', reason: '纯 IPv4' },
      { input: '192.168.1.10:47989', expectedHost: '192.168.1.10', expectedPort: 47989, reason: 'IPv4:port' },
      { input: 'sunshine.local:47989', expectedHost: 'sunshine.local', expectedPort: 47989, reason: 'hostname:port' },
      { input: '[::1]:47989', expectedHost: '::1', expectedPort: 47989, reason: '[IPv6]:port' },
      { input: '::1', expectedHost: '::1', reason: '裸 IPv6 不拆端口' },
      { input: 'sunshine.local:99999', expectedHost: 'sunshine.local:99999', reason: '非法端口保留为 host 原文' },
    ];

    for (const c of parseCases) {
      const actual = parseAddressAndPort(c.input);
      failed += NetworkErrorClassifierSelfCheck.expectEqual('NetHelper.parseAddressAndPort', `${c.input} host`, actual.host, c.expectedHost, c.reason);
      failed += NetworkErrorClassifierSelfCheck.expectEqual('NetHelper.parseAddressAndPort', `${c.input} port`, actual.port, c.expectedPort, c.reason);
    }

    NetworkErrorClassifierSelfCheck.logGroupResult('NetHelper', failed);
    return failed;
  }

  private static runWakeOnLanCases(): number {
    let failed = 0;
    const cases: BooleanCase[] = [
      { name: 'colon lowercase MAC', actual: WakeOnLan.isValidMacAddress('aa:bb:cc:dd:ee:ff'), expected: true, reason: '标准冒号分隔 MAC' },
      { name: 'hyphen uppercase MAC', actual: WakeOnLan.isValidMacAddress('AA-BB-CC-DD-EE-FF'), expected: true, reason: 'Windows 常见连字符格式' },
      { name: 'missing octet MAC', actual: WakeOnLan.isValidMacAddress('AA:BB:CC:DD:EE'), expected: false, reason: '必须 6 个字节' },
      { name: 'non-hex MAC', actual: WakeOnLan.isValidMacAddress('GG:BB:CC:DD:EE:FF'), expected: false, reason: '必须是十六进制' },
      { name: 'compact MAC unsupported', actual: WakeOnLan.isValidMacAddress('AABBCCDDEEFF'), expected: false, reason: '当前 UI/发送器要求显式分隔符' },
    ];
    for (const c of cases) {
      failed += NetworkErrorClassifierSelfCheck.expectEqual('WakeOnLan.isValidMacAddress', c.name, c.actual, c.expected, c.reason);
    }
    NetworkErrorClassifierSelfCheck.logGroupResult('WakeOnLan', failed);
    return failed;
  }

  private static runConnectionPathCases(): number {
    let failed = 0;
    const cases: StringCase[] = [
      {
        name: 'VPN takes precedence over private target',
        actual: ConnectionPathService.classify(['192.168.50.10'], true),
        expected: ConnectionPath.VPN,
        reason: '组网 VPN 常使用私网地址，不能误判为物理 LAN'
      },
      {
        name: 'private target is LAN',
        actual: ConnectionPathService.classify(['10.0.0.8'], false),
        expected: ConnectionPath.LAN,
        reason: '无 VPN 时 RFC1918 地址使用局域网档位'
      },
      {
        name: 'public target is WAN',
        actual: ConnectionPathService.classify(['203.0.113.8'], false),
        expected: ConnectionPath.WAN,
        reason: '公网目标使用远程档位'
      },
      {
        name: 'mixed DNS targets are UNKNOWN',
        actual: ConnectionPathService.classify(['192.168.1.8', '203.0.113.8'], false),
        expected: ConnectionPath.UNKNOWN,
        reason: '无法确认实际选中地址时不能冒进使用 LAN 高码率档位'
      },
      {
        name: 'private target over cellular is UNKNOWN',
        actual: ConnectionPathService.classify(['10.0.0.8'], false, true),
        expected: ConnectionPath.UNKNOWN,
        reason: '蜂窝网络中的私网地址不能证明与 Sunshine 位于同一物理 LAN'
      },
      {
        name: 'unresolved target is UNKNOWN',
        actual: ConnectionPathService.classify([], false),
        expected: ConnectionPath.UNKNOWN,
        reason: '无法解析时交由调用方保守回退到 WAN 配置'
      }
    ];
    for (const c of cases) {
      failed += NetworkErrorClassifierSelfCheck.expectEqual(
        'ConnectionPathService', c.name, c.actual, c.expected, c.reason);
    }
    NetworkErrorClassifierSelfCheck.logGroupResult('ConnectionPathService', failed);
    return failed;
  }

  private static runAddressSelectionCases(): number {
    let failed = 0;
    const cases: StringCase[] = [
      {
        name: 'preferred address wins',
        actual: selectBestAddress({
          preferredAddress: 'preferred.example.com',
          address: 'active.example.com',
          localAddress: '192.168.1.20',
          remoteAddress: '203.0.113.20',
          manualAddress: 'manual.example.com',
          ipv6Address: 'fd00::20',
        }),
        expected: 'preferred.example.com',
        reason: '用户锁定地址应跳过竞速结果',
      },
      {
        name: 'active address wins',
        actual: selectBestAddress({
          address: 'active.example.com',
          localAddress: '192.168.1.20',
          remoteAddress: '203.0.113.20',
          manualAddress: 'manual.example.com',
          ipv6Address: 'fd00::20',
        }),
        expected: 'active.example.com',
        reason: '最近验证可达地址优先',
      },
      {
        name: 'manual fallback wins before LAN',
        actual: selectBestAddress({
          address: '',
          localAddress: '192.168.1.20',
          remoteAddress: '203.0.113.20',
          manualAddress: 'manual.example.com',
          ipv6Address: 'fd00::20',
        }),
        expected: 'manual.example.com',
        reason: '无活跃地址时尊重用户手动输入',
      },
      {
        name: 'LAN IPv4 before IPv6 and WAN',
        actual: selectBestAddress({
          address: '',
          localAddress: '192.168.1.20',
          remoteAddress: '203.0.113.20',
          ipv6Address: '240e:1234::20',
        }),
        expected: '192.168.1.20',
        reason: '首次添加/离线恢复优先 LAN IPv4',
      },
      {
        name: 'LAN IPv6 before non-LAN local',
        actual: selectBestAddress({
          address: '',
          localAddress: '203.0.113.20',
          remoteAddress: '198.51.100.20',
          ipv6Address: 'fd00::20',
        }),
        expected: 'fd00::20',
        reason: '非 LAN localAddress 不应压过局域网 IPv6',
      },
      {
        name: 'remote fallback',
        actual: selectBestAddress({
          address: '',
          localAddress: '',
          remoteAddress: '198.51.100.20',
        }),
        expected: '198.51.100.20',
        reason: '只剩 WAN 地址时返回 WAN',
      },
      {
        name: 'empty fallback',
        actual: selectBestAddress({
          address: '',
          localAddress: '',
          remoteAddress: '',
        }),
        expected: '',
        reason: '无任何地址时返回空字符串',
      },
    ];

    for (const c of cases) {
      failed += NetworkErrorClassifierSelfCheck.expectEqual('selectBestAddress', c.name, c.actual, c.expected, c.reason);
    }
    NetworkErrorClassifierSelfCheck.logGroupResult('selectBestAddress', failed);
    return failed;
  }

  private static runDisplayAddressCases(): number {
    let failed = 0;
    const cases: StringCase[] = [
      {
        name: 'custom port appended to manual address',
        actual: formatDisplayAddress({
          address: '192.168.1.5',
          localAddress: '',
          remoteAddress: '',
          manualAddress: 'ddns.example.com',
          serverCert: '',
          httpPort: 47990,
        }),
        expected: 'ddns.example.com:47990',
        reason: '自定义端口必须可见，否则用户以为端口没生效',
      },
      {
        name: 'custom port appended to active address',
        actual: formatDisplayAddress({
          address: '192.168.1.5',
          localAddress: '',
          remoteAddress: '',
          manualAddress: '',
          serverCert: '',
          httpPort: 30000,
        }),
        expected: '192.168.1.5:30000',
        reason: '无手动地址时回落到活跃地址仍要带端口',
      },
      {
        name: 'default port omitted',
        actual: formatDisplayAddress({
          address: '192.168.1.5',
          localAddress: '',
          remoteAddress: '',
          manualAddress: '',
          serverCert: '',
          httpPort: 47989,
        }),
        expected: '192.168.1.5',
        reason: '默认端口不显示，避免噪音',
      },
      {
        name: 'no port',
        actual: formatDisplayAddress({
          address: 'sunshine.local',
          localAddress: '',
          remoteAddress: '',
          manualAddress: '',
          serverCert: '',
        }),
        expected: 'sunshine.local',
        reason: '自动发现的主机没有自定义端口',
      },
      {
        name: 'empty fallback',
        actual: formatDisplayAddress({
          address: '',
          localAddress: '',
          remoteAddress: '',
          manualAddress: '',
          serverCert: '',
        }),
        expected: '',
        reason: '无任何地址时返回空字符串',
      },
    ];

    for (const c of cases) {
      failed += NetworkErrorClassifierSelfCheck.expectEqual('formatDisplayAddress', c.name, c.actual, c.expected, c.reason);
    }
    NetworkErrorClassifierSelfCheck.logGroupResult('formatDisplayAddress', failed);
    return failed;
  }

  private static expectEqual(scope: string, name: string, actual: Comparable, expected: Comparable, reason: string): number {
    if (actual === expected) {
      return 0;
    }
    hilog.error(DOMAIN, TAG,
      'CONTRACT BROKEN [%{public}s] %{public}s = %{public}s, expected %{public}s — %{public}s',
      scope, name, String(actual), String(expected), reason);
    return 1;
  }

  private static logGroupResult(group: string, failed: number): void {
    if (failed === 0) {
      hilog.info(DOMAIN, TAG, '%{public}s self-check passed', group);
    } else {
      hilog.error(DOMAIN, TAG, '%{public}s self-check FAILED: %{public}d cases broken', group, failed);
    }
  }
}
