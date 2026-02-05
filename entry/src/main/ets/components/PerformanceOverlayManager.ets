/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * 性能覆盖层管理器
 * 与 Android 版本对齐，支持：
 * - 可拖动（8个预设位置吸附）
 * - 可点击（显示项目详情）
 * - 双击切换布局
 * - 项目可选
 * - 锁定模式
 */

import { promptAction } from '@kit.ArkUI';

// 性能项目图标常量类 - 统一管理所有 emoji 图标
export class PerfIcons {
  static readonly RESOLUTION: string = '📱';      // 分辨率
  static readonly DECODER: string = '🎬';         // 解码器
  static readonly FPS: string = '🎮';             // 帧率（不再使用，保留兼容）
  static readonly PACKET_LOSS: string = '📶';     // 丢包率/网络信号
  static readonly BITRATE: string = '⏳';         // 带宽/传输
  static readonly NETWORK: string = '🌐';         // 网络延迟
  static readonly DECODE_NORMAL: string = '⏱️';   // 解码延迟（正常）
  static readonly DECODE_HOT: string = '🥵';      // 解码延迟（过热）
  static readonly HOST: string = '🖥️';            // 主机延迟
  static readonly BATTERY: string = '🔋';         // 电池
  static readonly CHARGING: string = '⚡';        // 充电中
}

// 性能项目名称常量类 - 统一管理所有显示名称
export class PerfLabels {
  static readonly RESOLUTION: string = '分辨率';
  static readonly DECODER: string = '解码器';
  static readonly FPS: string = '帧率';
  static readonly PACKET_LOSS: string = '丢包率';
  static readonly BITRATE: string = '带宽';
  static readonly NETWORK: string = '网络状态';
  static readonly DECODE: string = '解码延迟';
  static readonly HOST: string = '主机延迟';
  static readonly BATTERY: string = '电池';
}

// 性能项目枚举
export enum PerformanceItem {
  RESOLUTION = 'resolution',
  DECODER = 'decoder',
  RENDER_FPS = 'render_fps',
  PACKET_LOSS = 'packet_loss',
  BITRATE = 'bitrate',          // 码率
  NETWORK_LATENCY = 'network_latency',  // 网络延迟（RTT）
  DECODE_LATENCY = 'decode_latency',
  HOST_LATENCY = 'host_latency',
  BATTERY = 'battery'
}

// 吸附位置枚举
export enum SnapPosition {
  TOP_LEFT = 'top_left',
  TOP_CENTER = 'top_center',
  TOP_RIGHT = 'top_right',
  CENTER_LEFT = 'center_left',
  CENTER_RIGHT = 'center_right',
  BOTTOM_LEFT = 'bottom_left',
  BOTTOM_CENTER = 'bottom_center',
  BOTTOM_RIGHT = 'bottom_right'
}

// 性能数据类
export class PerformanceData {
  streamWidth: number = 0;
  streamHeight: number = 0;
  targetFps: number = 0;
  receivedFps: number = 0;
  renderedFps: number = 0;
  codec: string = '';
  isHdr: boolean = false;
  packetLoss: number = 0;
  bitrate: number = 0;
  decodeLatency: number = 0;
  networkLatency: number = 0;
  hostLatency: number = 0;
  batteryLevel: number = 100;
  isCharging: boolean = false;
}

// 覆盖层配置类
export class OverlayConfig {
  isVertical: boolean = true;          // 是否垂直布局
  isLocked: boolean = false;           // 是否锁定（不可拖动）
  position: SnapPosition = SnapPosition.TOP_RIGHT;  // 当前位置（默认右上角）
  enabledItems: Set<string> = new Set<string>();   // 启用的项目（使用 string 类型）
  customX: number = 0;                 // 自定义X坐标
  customY: number = 0;                 // 自定义Y坐标
}

// 性能项目信息类
export class PerformanceItemInfo {
  title: string;
  description: string;
  
  constructor(title: string, description: string) {
    this.title = title;
    this.description = description;
  }
}

// 坐标类
export class Position {
  x: number;
  y: number;
  
  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

// 默认配置
export function getDefaultOverlayConfig(): OverlayConfig {
  const config = new OverlayConfig();
  config.isVertical = true;   // 默认竖向布局
  config.isLocked = false;
  config.position = SnapPosition.TOP_RIGHT;  // 默认右上角
  config.enabledItems = new Set<string>([
    PerformanceItem.RESOLUTION,
    PerformanceItem.DECODER,
    PerformanceItem.RENDER_FPS,
    PerformanceItem.PACKET_LOSS,
    PerformanceItem.BITRATE,
    PerformanceItem.NETWORK_LATENCY,
    PerformanceItem.DECODE_LATENCY
  ]);
  return config;
}

// 获取性能项目信息
export function getPerformanceItemInfo(item: PerformanceItem): PerformanceItemInfo {
  switch (item) {
    case PerformanceItem.RESOLUTION:
      return new PerformanceItemInfo(
        `${PerfIcons.RESOLUTION} 分辨率`,
        '显示当前串流的分辨率和帧率。客户端分辨率是从服务器接收的视频分辨率，这可能与主机端设置的分辨率不同。'
      );
    case PerformanceItem.DECODER:
      return new PerformanceItemInfo(
        `${PerfIcons.DECODER} 解码器`,
        '显示当前使用的视频编解码器。HEVC比AVC提供更好的压缩效率，在相同码率下能获得更好的画质。HDR表示正在使用高动态范围，能显示更丰富的色彩和对比度。'
      );
    case PerformanceItem.RENDER_FPS:
      return new PerformanceItemInfo(
        `📊 帧率`,
        'Rx为从服务器接收的帧率，Rd为实际渲染到屏幕的帧率。如果渲染帧率低于接收帧率，可能是解码或显示瓶颈。'
      );
    case PerformanceItem.PACKET_LOSS:
      return new PerformanceItemInfo(
        `${PerfIcons.PACKET_LOSS} 丢包率`,
        '显示网络传输过程中丢失的数据包百分比。低于1%是优秀，1-5%是可接受，高于5%可能导致画面卡顿或花屏。'
      );
    case PerformanceItem.BITRATE:
      return new PerformanceItemInfo(
        `${PerfIcons.BITRATE} 码率`,
        '当前视频流的下载带宽。带宽越高，画质越好，但也需要更快的网络连接。建议根据网络带宽调整码率设置。'
      );
    case PerformanceItem.NETWORK_LATENCY:
      return new PerformanceItemInfo(
        `${PerfIcons.NETWORK} 网络延迟`,
        '网络往返延迟(RTT)，即数据包从客户端到服务器再返回的时间。低于20ms是优秀，20-50ms是良好，高于100ms可能感受到明显延迟。'
      );
    case PerformanceItem.DECODE_LATENCY:
      return new PerformanceItemInfo(
        `${PerfIcons.DECODE_NORMAL} 解码延迟`,
        '视频帧解码所需的时间。低于10ms是优秀，10-20ms是正常，高于20ms可能需要降低分辨率或使用硬件解码器。'
      );
    case PerformanceItem.HOST_LATENCY:
      return new PerformanceItemInfo(
        `${PerfIcons.HOST} 主机延迟`,
        '服务器端渲染和编码游戏画面所需的时间。这取决于服务器的硬件性能和当前运行的游戏。较新的显卡通常有更低的编码延迟。'
      );
    case PerformanceItem.BATTERY:
      return new PerformanceItemInfo(
        `${PerfIcons.BATTERY} 电池`,
        '显示当前设备的电池电量。串流游戏会消耗较多电量，建议在电量充足时或连接充电器时进行长时间串流。'
      );
    default:
      return new PerformanceItemInfo('未知', '');
  }
}

/**
 * 获取月相图标
 */
export function getMoonPhaseIcon(): string {
  const date = new Date();
  const year = date.getFullYear();
  const month = date.getMonth() + 1;
  const day = date.getDate();
  
  // 简化的月相计算（基于朔望月周期 29.53 天）
  const lp = 2551443; // 月相周期（秒）
  const newMoon = new Date(1970, 0, 7, 20, 35, 0); // 已知新月时间
  const phase = ((date.getTime() - newMoon.getTime()) / 1000) % lp;
  const phaseIndex = Math.floor(phase / (lp / 8));
  
  const icons = ['🌑', '🌒', '🌓', '🌔', '🌕', '🌖', '🌗', '🌘'];
  return icons[phaseIndex] || '🌙';
}

/**
 * 格式化码率显示
 */
export function formatBitrate(bps: number): string {
  if (bps >= 1000000) {
    return `${(bps / 1000000).toFixed(1)} Mbps`;
  } else if (bps >= 1000) {
    return `${(bps / 1000).toFixed(0)} Kbps`;
  }
  return `${bps} bps`;
}

/**
 * 格式化数据流量显示（从码率 bps 转换为每秒数据量）
 * 码率 (bps) 转换为字节/秒 需要除以 8
 */
export function formatDataRate(bps: number): string {
  const bytesPerSec = bps / 8;  // 从 bits 转换为 bytes
  
  if (bytesPerSec >= 1024 * 1024) {
    return `${(bytesPerSec / (1024 * 1024)).toFixed(1)} MB/s`;
  } else if (bytesPerSec >= 1024) {
    return `${(bytesPerSec / 1024).toFixed(0)} KB/s`;
  }
  return `${bytesPerSec.toFixed(0)} B/s`;
}

/**
 * 格式化延迟显示
 */
export function formatLatency(ms: number): string {
  return `${ms.toFixed(1)} ms`;
}

/**
 * 获取解码器显示字符串
 */
export function getDecoderString(codec: string, isHdr: boolean): string {
  let result = codec.toUpperCase();
  if (result.includes('HEVC') || result.includes('H265')) {
    result = 'HEVC';
  } else if (result.includes('AVC') || result.includes('H264')) {
    result = 'AVC';
  } else if (result.includes('AV1')) {
    result = 'AV1';
  }
  if (isHdr) {
    result += ' HDR';
  }
  return result;
}

/**
 * 获取丢包率颜色
 */
export function getPacketLossColor(loss: number): string {
  if (loss < 1.0) return '#7D9D7D';  // 绿色 - 优秀
  if (loss < 5.0) return '#D4A574';  // 橙色 - 可接受
  return '#B57D7D';  // 红色 - 差
}

/**
 * 获取延迟颜色
 */
export function getLatencyColor(ms: number): string {
  if (ms < 10) return '#7D9D7D';   // 绿色 - 优秀
  if (ms < 20) return '#D597E3';   // 紫色 - 正常
  return '#B57D7D';  // 红色 - 差
}

/**
 * 获取电池颜色
 */
export function getBatteryColor(level: number): string {
  if (level > 50) return '#90EE90';  // 浅绿色 - 充足
  if (level > 20) return '#FFA500';  // 橙色 - 偏低
  return '#FF6B6B';  // 红色 - 不足
}

/**
 * 显示性能项目详情对话框
 */
export function showItemInfoDialog(item: PerformanceItem, data: PerformanceData | null): void {
  const info = getPerformanceItemInfo(item);
  if (!info) return;
  
  let message = info.description;
  
  // 添加当前数值
  if (data !== null) {
    switch (item) {
      case PerformanceItem.RESOLUTION:
        message = `${data.streamWidth}×${data.streamHeight} @ ${data.renderedFps}/${data.targetFps} FPS\n\n${info.description}`;
        break;
      case PerformanceItem.DECODER:
        message = `${data.codec}${data.isHdr ? ' HDR' : ''}\n\n${info.description}`;
        break;
      case PerformanceItem.RENDER_FPS:
        message = `Rx: ${data.receivedFps}  Rd: ${data.renderedFps}\n\n${info.description}`;
        break;
      case PerformanceItem.PACKET_LOSS:
        message = `${data.packetLoss.toFixed(2)}%\n\n${info.description}`;
        break;
      case PerformanceItem.BITRATE:
        message = `${formatBitrate(data.bitrate)}\n\n${info.description}`;
        break;
      case PerformanceItem.NETWORK_LATENCY:
        message = `${data.networkLatency} ms\n\n${info.description}`;
        break;
      case PerformanceItem.DECODE_LATENCY:
        message = `${data.decodeLatency.toFixed(1)} ms\n\n${info.description}`;
        break;
      case PerformanceItem.HOST_LATENCY:
        message = `${data.hostLatency.toFixed(1)} ms\n\n${info.description}`;
        break;
      case PerformanceItem.BATTERY:
        message = `${data.batteryLevel}%${data.isCharging ? ' 🔌充电中' : ''}\n\n${info.description}`;
        break;
    }
  }
  
  const dialogButton: promptAction.Button = { text: '确定', color: '#0A59F7' };
  promptAction.showDialog({
    title: info.title,
    message: message,
    buttons: [dialogButton]
  });
}

/**
 * 计算吸附位置坐标
 */
export function calculateSnapPosition(
  position: SnapPosition,
  screenWidth: number,
  screenHeight: number,
  overlayWidth: number,
  overlayHeight: number,
  safeAreaTop: number = 8,
  safeAreaBottom: number = 0
): Position {
  const padding = 8;  // 左右安全区也设为8
  
  let x: number;
  let y: number;
  
  switch (position) {
    case SnapPosition.TOP_LEFT:
      x = padding;
      y = safeAreaTop;
      break;
    case SnapPosition.TOP_CENTER:
      x = (screenWidth - overlayWidth) / 2;
      y = safeAreaTop;
      break;
    case SnapPosition.TOP_RIGHT:
      x = screenWidth - overlayWidth - padding;
      y = safeAreaTop;
      break;
    case SnapPosition.CENTER_LEFT:
      x = padding;
      y = (screenHeight - overlayHeight) / 2;
      break;
    case SnapPosition.CENTER_RIGHT:
      x = screenWidth - overlayWidth - padding;
      y = (screenHeight - overlayHeight) / 2;
      break;
    case SnapPosition.BOTTOM_LEFT:
      x = padding;
      y = screenHeight - overlayHeight - safeAreaBottom;
      break;
    case SnapPosition.BOTTOM_CENTER:
      x = (screenWidth - overlayWidth) / 2;
      y = screenHeight - overlayHeight - safeAreaBottom;
      break;
    case SnapPosition.BOTTOM_RIGHT:
      x = screenWidth - overlayWidth - padding;
      y = screenHeight - overlayHeight - safeAreaBottom;
      break;
    default:
      x = padding;
      y = safeAreaTop;
  }
  
  return new Position(x, y);
}

// 所有吸附位置列表
const ALL_SNAP_POSITIONS: SnapPosition[] = [
  SnapPosition.TOP_LEFT,
  SnapPosition.TOP_CENTER,
  SnapPosition.TOP_RIGHT,
  SnapPosition.CENTER_LEFT,
  SnapPosition.CENTER_RIGHT,
  SnapPosition.BOTTOM_LEFT,
  SnapPosition.BOTTOM_CENTER,
  SnapPosition.BOTTOM_RIGHT
];

/**
 * 找到最近的吸附位置
 */
export function findNearestSnapPosition(
  currentX: number,
  currentY: number,
  screenWidth: number,
  screenHeight: number,
  overlayWidth: number,
  overlayHeight: number
): SnapPosition {
  let nearestPosition = SnapPosition.TOP_LEFT;
  let minDistance = Infinity;
  
  for (let i = 0; i < ALL_SNAP_POSITIONS.length; i++) {
    const pos = ALL_SNAP_POSITIONS[i];
    const snapPos = calculateSnapPosition(pos, screenWidth, screenHeight, overlayWidth, overlayHeight);
    const distance = Math.sqrt(Math.pow(currentX - snapPos.x, 2) + Math.pow(currentY - snapPos.y, 2));
    
    if (distance < minDistance) {
      minDistance = distance;
      nearestPosition = pos;
    }
  }
  
  return nearestPosition;
}
