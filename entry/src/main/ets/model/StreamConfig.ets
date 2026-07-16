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
 * 串流配置模型
 *
 * 参考 Android 版本 StreamConfiguration.java
 */
export const GAME_VIBRATION_STRENGTH_MIN = 0;
export const GAME_VIBRATION_STRENGTH_MAX = 200;
export const GAME_VIBRATION_STRENGTH_ORIGINAL = 100;
export const GAME_VIBRATION_STRENGTH_DEFAULT = GAME_VIBRATION_STRENGTH_ORIGINAL;
export const GAME_VIBRATION_STRENGTH_STEP = 5;

export function normalizeGameVibrationStrength(value: number): number {
  if (!Number.isFinite(value)) {
    return GAME_VIBRATION_STRENGTH_DEFAULT;
  }
  const roundedValue = Math.round(value);
  return Math.max(GAME_VIBRATION_STRENGTH_MIN, Math.min(GAME_VIBRATION_STRENGTH_MAX, roundedValue));
}

export interface StreamConfig {
  // 视频设置
  width: number;
  height: number;
  fps: number;
  clientRefreshRateX100: number;  // 客户端刷新率 x 100，用于 NTSC 帧率支持 (如 11988 = 119.88 Hz)
  bitrate: number;  // Kbps
  codec: 'H.264' | 'HEVC';  // HarmonyOS 不支持 AV1
  hdr: boolean;
  hdrMode: HdrMode;         // HDR 模式: SDR=0, HDR10=1, HLG=2
  hdrHighBrightness: boolean;
  hdrBrightnessOverride: boolean; // 手动覆盖上报给 Sunshine 的 HDR 亮度范围
  hdrPeakBrightnessNits: number;  // 手动 HDR 峰值亮度 (300-4000 nits)
  stretchVideo: boolean;

  // 音频设置
  audioEnabled: boolean;
  controlOnly: boolean;  // 仅控制模式：不建立音视频流
  microphoneEnabled: boolean;
  micBitrate: number;  // Kbps
  audioConfig: AudioConfiguration;
  enableSpatializer: boolean;
  audioCompatMode: boolean;

  // 主机设置
  sops: boolean;  // 优化游戏设置
  playLocalAudio: boolean;  // 同时在主机播放音频
  screenCombinationMode: ScreenCombinationMode;
  lockScreenAfterDisconnect: boolean;

  // 输入设置
  multiController: boolean;
  attachedGamepadMask: number;
  enableVibration: boolean;
  vibrationMode: string;  // 震动模式：自动/仅手柄/仅设备/同时
  gameVibrationStrength: number;  // 串流游戏震动强度百分比（100=原始强度，100 以上为 app 侧放大）
  enableAudioVibration: boolean;  // 音频振动（低频驱动）
  audioVibrationStrength: number;  // 音频振动强度 (0-100)
  audioVibrationSceneMode: string;  // 音频振动场景模式: 游戏/电影, 音乐/节奏, 自动
  deadzone: number;
  flipFaceButtons: boolean;

  // 鼠标/触控设置
  showLocalCursor: boolean;
  touchscreenTrackpad: boolean;
  lowLatencyTouch: boolean;
  enableDoubleClickDrag: boolean;
  doubleTapTimeThreshold: number;

  // 增强触控设置
  enableEnhancedTouch: boolean;
  enhancedTouchOnRight: boolean;
  enhancedTouchZoneDivider: number;
  pointerVelocityFactor: number;
  longPressFlatRegion: number;

  // 高级选项
  packetSize: number;
  encryptionFlags: number;
  colorRange: ColorRange;
  decoderBufferCount: number; // 解码队列深度 (0=自动=2；始终用于解码器缓冲请求，同步模式下也限制软件队列)
  enableSyncDecode: boolean;  // 同步解码模式（API 20+，主动轮询 + 仅渲染最新输出帧，低延迟优先）
  enableVrr: boolean;         // VRR 可变刷新率模式（动态调整屏幕刷新率，可能丢帧）
  enableVsync: boolean;       // VSync 渲染模式（按时间戳精确呈现，更平滑但可能增加延迟）
  enableTwoStepPreciseSync: boolean; // 二步精确同步（host 节奏去抖 + 本地 VSync 对齐）
  enablePostProcess: boolean; // 后处理滤镜（HDR 暗区抖动补偿，适用于 OLED 面板）
  upscaleMode: number;        // 超分辨率模式 (0=OFF, 1=XENGINE, 2=FSR1, 3=AUTO)
  upscaleSharpness: number;   // 超分锐度 (0.0 - 1.0)
  sdrToHdrMode: number;       // HDR 增强模式 (0=关闭, 1=自研shader, 2=AIHDR)
  sdrToHdr: boolean;          // SDR→HDR 反向色调映射（派生自 sdrToHdrMode===1）
  sdrToHdrPeakNits: number;   // SDR→HDR 峰值亮度 (200-1000)
  sdrToHdrSaturation: number; // SDR→HDR 色彩饱和度 (0.5-2.0)
  sdrToHdrContrast: number;   // SDR→HDR 对比度 (0.5-2.0)
  enableStun: boolean;
  performanceMode: boolean;   // 性能模式（优化线程优先级和系统资源）

  // 运行时选项
  remote: RemoteConfig;

  // 显示选项
  showPerfOverlay: boolean;
  perfOverlayOrientation: PerfOverlayOrientation;
  perfOverlayPosition: PerfOverlayPosition;
  showOnscreenControls: boolean;
  onscreenControlsOpacity: number;
  enableEscMenu: boolean;
}

/**
 * 音频配置
 * 值使用 moonlight-common-c 的 MAKE_AUDIO_CONFIGURATION 格式:
 * (channelMask << 16) | (channelCount << 8) | 0xCA
 */
export enum AudioConfiguration {
  STEREO = 0x000302CA,           // 立体声 (2声道, mask=0x3)
  SURROUND_51 = 0x003F06CA,      // 5.1 环绕声 (6声道, mask=0x3F)
  SURROUND_71 = 0x063F08CA       // 7.1 环绕声 (8声道, mask=0x63F)
}

/**
 * 从 AudioConfiguration 计算 surroundAudioInfo
 * 格式: channelMask << 16 | channelCount
 * @param audioConfig AudioConfiguration 枚举值
 * @returns surroundAudioInfo 数值
 */
export function getSurroundAudioInfo(audioConfig: AudioConfiguration): number {
  const channelCount = (audioConfig >> 8) & 0xFF;
  const channelMask = (audioConfig >> 16) & 0xFFFF;
  return (channelMask << 16) | channelCount;
}

/**
 * 颜色范围
 */
export enum ColorRange {
  LIMITED = 0,          // 受限范围 (16-235)
  FULL = 1              // 全范围 (0-255)
}

/**
 * HDR 模式
 * 与 Sunshine dynamicRange 参数对应:
 * - SDR = 0
 * - HDR10/PQ = 1 (SMPTE ST 2084)
 * - HLG = 2 (ARIB STD-B67, Hybrid Log-Gamma)
 */
export enum HdrMode {
  SDR = 0,              // 标准动态范围
  HDR10 = 1,            // HDR10 (PQ 传输函数)
  HLG = 2               // HLG (Hybrid Log-Gamma, ARIB STD-B67)
}

/**
 * 远程/本地配置
 */
export enum RemoteConfig {
  LOCAL = 0,
  REMOTE = 1,
  AUTO = 2
}

/**
 * 屏幕组合模式
 */
export enum ScreenCombinationMode {
  /** 使用 Sunshine 主机端配置（默认） */
  HOST_DEFAULT = -1,
  /** 不修改屏幕组合配置 */
  NO_OPERATION = 0,
  /** 确保串流屏幕已开启 */
  ENSURE_ACTIVE = 1,
  /** 确保串流屏幕为主屏幕 */
  ENSURE_PRIMARY = 2,
  /** 仅启用串流屏幕（关闭其他） */
  ENSURE_ONLY_DISPLAY = 3,
}

/**
 * 性能覆盖层方向
 */
export enum PerfOverlayOrientation {
  HORIZONTAL = 0,
  VERTICAL = 1
}

/**
 * 性能覆盖层位置
 */
export enum PerfOverlayPosition {
  TOP = 0,
  BOTTOM = 1,
  TOP_LEFT = 2,
  TOP_RIGHT = 3,
  BOTTOM_LEFT = 4,
  BOTTOM_RIGHT = 5
}

export interface ResolutionPreset {
  name: string;
  width: number;
  height: number;
}

export function getDefaultStreamConfig(): StreamConfig {
  // 计算 1080p@60fps 的推荐码率
  const defaultBitrate = getRecommendedBitrate(1920, 1080, 60);
  
  return {
    // 视频设置
    width: 1920,
    height: 1080,
    fps: 60,
    clientRefreshRateX100: 6000,  // 60.00 Hz
    bitrate: defaultBitrate,  // 使用推荐码率
    codec: 'H.264',  // 默认使用 H.264，因为某些设备不支持 HEVC
    hdr: false,
    hdrMode: HdrMode.SDR,  // 默认 SDR，启用 HDR 时根据用户选择使用 HDR10 或 HLG
    hdrHighBrightness: false,
    hdrBrightnessOverride: false,
    hdrPeakBrightnessNits: 1000,
    stretchVideo: false,

    // 音频设置
    audioEnabled: true,
    controlOnly: false,
    microphoneEnabled: false,
    micBitrate: 64,
    audioConfig: AudioConfiguration.STEREO,
    enableSpatializer: false,
    audioCompatMode: false,

    // 主机设置
    sops: true,
    playLocalAudio: false,
    screenCombinationMode: ScreenCombinationMode.HOST_DEFAULT,
    lockScreenAfterDisconnect: false,

    // 输入设置
    multiController: true,
    attachedGamepadMask: 0,
    enableVibration: true,
    vibrationMode: '自动',
    gameVibrationStrength: GAME_VIBRATION_STRENGTH_DEFAULT,
    enableAudioVibration: false,
    audioVibrationStrength: 60,
    audioVibrationSceneMode: '游戏/电影',
    deadzone: 7,
    flipFaceButtons: false,

    // 鼠标/触控设置
    showLocalCursor: false,
    touchscreenTrackpad: false,
    lowLatencyTouch: false,
    enableDoubleClickDrag: false,
    doubleTapTimeThreshold: 125,

    // 增强触控设置
    enableEnhancedTouch: true,
    enhancedTouchOnRight: false,
    enhancedTouchZoneDivider: 50,
    pointerVelocityFactor: 100,
    longPressFlatRegion: 0,

    // 高级选项
    packetSize: 1024,
    encryptionFlags: 0,
    colorRange: ColorRange.LIMITED,
    decoderBufferCount: 0,  // 0 = 自动 (= 2)
    enableSyncDecode: false, // 默认禁用同步解码（需要 API 20+；启用后低延迟优先）
    enableVrr: false,       // 默认禁用 VRR（可能丢帧）
    enableVsync: false,     // 默认关闭（低延迟优先；开启后更平滑但可能增加 1 帧左右延迟）
    enableTwoStepPreciseSync: false, // 默认关闭，便于与原 VSync 路径做 A/B 对比
    enablePostProcess: false, // 默认禁用后处理滤镜
    upscaleMode: 0,           // 默认不超分
    upscaleSharpness: 0.5,    // 默认锐度 50%
    sdrToHdrMode: 0,           // 默认关闭 HDR 增强
    sdrToHdr: false,           // 默认禁用 SDR→HDR
    sdrToHdrPeakNits: 500,     // 默认峰值亮度 500 nits
    sdrToHdrSaturation: 1.3,   // 默认饱和度 1.3x
    sdrToHdrContrast: 1.0,     // 默认对比度 1.0x
    enableStun: false,
    performanceMode: false, // 默认禁用性能模式

    // 运行时选项
    remote: RemoteConfig.AUTO,

    // 显示选项
    showPerfOverlay: false,
    perfOverlayOrientation: PerfOverlayOrientation.VERTICAL,  // 默认竖向
    perfOverlayPosition: PerfOverlayPosition.TOP,
    showOnscreenControls: false,
    onscreenControlsOpacity: 90,
    enableEscMenu: true
  };
}

export function getResolutionPresets(): ResolutionPreset[] {
  const presets: ResolutionPreset[] = [
    { name: '720p', width: 1280, height: 720 } as ResolutionPreset,
    { name: '1080p', width: 1920, height: 1080 } as ResolutionPreset,
    { name: '1440p', width: 2560, height: 1440 } as ResolutionPreset,
    { name: '4K', width: 3840, height: 2160 } as ResolutionPreset
  ];
  return presets;
}

/**
 * 计算推荐的码率（基于分辨率和帧率）
 * 参考 Android 版本 PreferenceConfiguration.getDefaultBitrate()
 */
export function getRecommendedBitrate(width: number, height: number, fps: number): number {
  // 帧率因子
  const frameRateFactor = (fps <= 60 ? fps : (Math.sqrt(fps / 60) * 60)) / 30;

  // 像素数
  const pixels = width * height;

  // 分辨率因子表
  const pixelVals = [
    640 * 360,
    854 * 480,
    1280 * 720,
    1920 * 1080,
    2560 * 1440,
    3840 * 2160,
    -1
  ];
  const factorVals = [1, 2, 5, 10, 20, 40, -1];

  // 计算分辨率因子
  let resolutionFactor = factorVals[0];
  for (let i = 0; i < pixelVals.length; i++) {
    if (pixels === pixelVals[i]) {
      resolutionFactor = factorVals[i];
      break;
    } else if (pixels < pixelVals[i]) {
      if (i === 0) {
        resolutionFactor = factorVals[i];
      } else {
        // 线性插值
        resolutionFactor =
          ((pixels - pixelVals[i - 1]) / (pixelVals[i] - pixelVals[i - 1])) *
          (factorVals[i] - factorVals[i - 1]) + factorVals[i - 1];
      }
      break;
    } else if (pixelVals[i] === -1) {
      resolutionFactor = factorVals[i - 1];
      break;
    }
  }

  return Math.round(resolutionFactor * frameRateFactor) * 1000;
}
