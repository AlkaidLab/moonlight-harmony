/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { StreamConfig, HdrMode, getSurroundAudioInfo } from '../../model/StreamConfig';
import { InputEvent, InputType, ControllerButtonEvent, ControllerAxisEvent, ControllerButton } from '../../model/InputEvent';
import { ComputerManager } from '../ComputerManager';
import { ComputerInfo, selectBestAddress } from '../../model/ComputerInfo';
import {
  NvHttp,
  LaunchConfig,
  DEFAULT_HDR_MIN_BRIGHTNESS_NITS,
  DEFAULT_HDR_MAX_BRIGHTNESS_NITS,
  DEFAULT_HDR_MAX_FULL_FRAME_BRIGHTNESS_NITS
} from './NvHttp';
import { CryptoUtil } from '../../utils/CryptoUtil';
import { parseAddressAndPort, parseRtspSessionHost } from '../../utils/NetHelper';
import { common, abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { GamepadManager } from '../input/GamepadManager';
import { MoonlightButton } from '../input/GamepadTypes';
import { MicrophoneStream } from '../microphone/MicrophoneStream';
import { AudioHapticFrame } from '../AudioHapticFrame';
import { AudioVibrationService } from '../AudioVibrationService';
import { AdaptiveBitrateService } from './AdaptiveBitrateService';
import { NetworkBoostService } from '../network/NetworkBoostService';
import { BandwidthProbeService } from '../network/BandwidthProbeService';
import { Ds5TouchpadInputSink } from '../input/Ds5TouchpadGestureHandler';
import { MoonBridge as ClipboardNativeBridge } from '../jni/ClipboardBridge';
import { sampleDisplayBrightness, MeasuredBrightnessProfile } from './BrightnessSampler';
import {
  MoonBridge,
  CONTROLLER_TYPE_UNKNOWN,
  CONTROLLER_TYPE_XBOX,
  CONTROLLER_TYPE_PS,
  LI_CCAP_ANALOG_TRIGGERS,
  LI_CCAP_RUMBLE,
  LI_CCAP_TOUCHPAD,
  LI_CCAP_BATTERY_STATE,
  LI_CCAP_ACCEL,
  LI_CCAP_GYRO,
  LI_FF_CONTROLLER_TOUCH_EVENTS,
  LI_FF_DYNAMIC_SDR_WHITE,
  LI_ERR_UNSUPPORTED,
  TOUCHPAD_FLAG,
  MODIFIER_SHIFT,
  MODIFIER_CTRL,
  MODIFIER_ALT,
  MODIFIER_META,
  VK_SHIFT,
  VK_CONTROL,
  VK_MENU,
  VK_LWIN,
  KEY_ACTION_DOWN,
  KEY_ACTION_UP,
  STAGE_NAME_RESOLUTION,
  Ds5HapticsIrV2Frame,
  AdaptiveTriggersFrame
} from './MoonBridge';
import nativeLib from 'libmoonlight_nativelib.so';

// =============================================================================
// 类型定义
// =============================================================================

/**
 * 串流性能统计
 */
export interface StreamStats {
  fps: number;             // 接收帧率 (Rx)
  codecOutputFps: number;  // 解码器输出帧率
  renderedFps: number;     // 渲染帧率 (Rd)
  bitrate: number;         // Kbps
  latency: number;         // 解码延迟 ms (EMA 瞬时值)
  hostLatency: number;     // 最近 1 秒主机处理延迟（编码时间）ms
  networkLatency: number;  // 网络延迟（RTT）ms
  packetLoss: number;      // %
  networkFrameLossPercent: number; // common-c 网络重组层确认的帧丢失率（不含客户端丢帧）
  decodedFrames: number;
  codecOutputFrames: number;
  droppedFrames: number;
  hdrVivid: boolean;       // 码流中检测到 CUVA HDR Vivid 动态元数据
  hostMaxLuminance: number;    // 宿主上报的虚拟屏峰值亮度 (nits, 0=未知)
  hostMaxFullFrame: number;    // 宿主上报的满帧亮度 (nits, 0=未知)
  hdrMode: number;             // 0=SDR, 1=HDR10/PQ, 2=HLG
  hdrBrightnessSource: string; // measured/manual-override/static
  hdrBrightnessOverride: boolean;
  measuredSdrNits: number;
  measuredPeakNits: number;
  measuredFullFrameNits: number;
  sentSdrWhiteNits: number;
  sentPeakNits: number;
  sentFullFrameNits: number;
  framesLost: number;
  totalFrames: number;
  globalAvgDecodeLatency: number;  // 全局平均解码延迟 ms
  globalAvgHostLatency: number;    // 全局平均主机延迟 ms
  globalAvgFps: number;            // 全局平均帧率
  // 分级丢帧统计
  droppedByL1: number;     // L1: sync drain-to-latest
  droppedByL2: number;     // L2: async 延迟过高跳帧
  droppedByL3: number;     // L3: 临界延迟 IDR 恢复
  droppedByL4: number;     // L4: 网络突发检测
  droppedByL5: number;     // L5: async 渲染跳帧
  droppedByQueueOverflow: number;
  droppedByTimeout: number;
  syncDrainEvents: number;
  syncDrainFrames: number;
  syncDecode: boolean;
  hostPacedPresentationActive: boolean;
  presentationPrepared: number;
  presentationScheduled: number;
  presentationExpired: number;
  presentationMissing: number;
  presentationFuture: number;
  presentationNonMonotonicDrops: number;
  presentationRenderFallbacks: number;
  presentationLeadUnder1Ms: number;
  presentationLead1To2Ms: number;
  presentationLead2To4Ms: number;
  presentationLead4To8Ms: number;
  presentationLeadAtLeast8Ms: number;
  presentationPendingHighWater: number;
}

/**
 * 解码器能力信息
 */
export interface DecoderCapabilities {
  supportsH264: boolean;
  supportsHEVC: boolean;
  supportsAV1: boolean;
  maxWidth: number;
  maxHeight: number;
  maxFps: number;
  supportsLowLatency: boolean;
  supports4K60: boolean;
  supports4K120: boolean;
  supports1080p120: boolean;
  maxInstances: number;
}

/** HDR 状态变化回调 */
export type HdrStateCallback = (isHdr: boolean) => void;

/** 宿主通过 SS_HDR_METADATA 下发的 HDR 显示/内容元数据(单位 nits,minDisplayLuminance 为 1/10000 nit) */
export interface HostHdrMetadata {
  maxDisplayLuminance: number;
  minDisplayLuminance: number;
  maxContentLightLevel: number;
  maxFrameAverageLightLevel: number;
  maxFullFrameLuminance: number;
}

/** 编解码器状态变化回调 */
export type CodecStateCallback = (codec: string) => void;

/** 分辨率变化回调 */
export type ResolutionChangedCallback = (width: number, height: number) => void;

// =============================================================================
// Native 模块接口
// =============================================================================

interface NativeModule {
  init(callbacks: StreamCallbacks): void;
  startConnection(
    address: string, appVersion: string, gfeVersion: string, rtspSessionUrl: string,
    serverCodecModeSupportFlags: number, width: number, height: number, fps: number,
    bitrate: number, packetSize: number, streamingRemotely: number,
    audioConfiguration: number, supportedVideoFormats: number, clientRefreshRateX100: number,
    riAesKey: ArrayBuffer, riAesIv: ArrayBuffer, videoCapabilities: number,
    colorSpace: number, colorRange: number, hdrMode: number,
    enableMic: boolean, controlOnly: boolean
  ): number;
  startConnectionAsync(
    address: string, appVersion: string, gfeVersion: string, rtspSessionUrl: string,
    serverCodecModeSupportFlags: number, width: number, height: number, fps: number,
    bitrate: number, packetSize: number, streamingRemotely: number,
    audioConfiguration: number, supportedVideoFormats: number, clientRefreshRateX100: number,
    riAesKey: ArrayBuffer, riAesIv: ArrayBuffer, videoCapabilities: number,
    colorSpace: number, colorRange: number, hdrMode: number,
    enableMic: boolean, controlOnly: boolean
  ): Promise<number>;
  stopConnection(): void;
  interruptConnection(): void;
  resumeDecoder(): void;
  setVideoSurface(surfaceId: string): boolean;
  releaseVideoSurface(): void;
  getVideoStats(): VideoStats;
  getDecoderCapabilities(): DecoderCapabilities;
  setDecoderBufferCount(count: number): void;
  setDecoderSyncMode(enabled: boolean): void;
  isDecoderSyncMode(): boolean;
  setVsyncEnabled(enabled: boolean): void;
  isVsyncEnabled(): boolean;
  setHostPacedPresentationEnabled(enabled: boolean): void;
  setVrrEnabled(enabled: boolean): void;
  setPostProcessEnabled(enabled: boolean): void;
  setUpscaleMode(mode: number, sharpness: number): void;
  getActiveUpscaleMode(): number;
  setSdrToHdr(enabled: boolean, peakNits: number, saturation: number, contrast: number): void;
  setSpatialAudioEnabled(enabled: boolean): void;
  isSpatialAudioEnabled(): boolean;
  setAudioCompatMode(enabled: boolean): void;
  setAudioVolume(volume: number): boolean;
  setPerformanceModeEnabled(enabled: boolean): void;
  getPerformanceModeEnabled(): boolean;
  setAudioHapticsConfig(enabled: boolean, sensitivity: number, sceneMode?: number): void;
  getEstimatedRttInfo(): number;
  sendMouseMove(deltaX: number, deltaY: number): void;
  sendMouseButton(buttonEvent: number, mouseButton: number): void;
  sendKeyboardInput(keyCode: number, keyAction: number, modifiers: number, flags: number): void;
  sendUtf8Text(text: string): void;
  sendMultiControllerInput(
    controllerNumber: number, activeGamepadMask: number, buttonFlags: number,
    leftTrigger: number, rightTrigger: number, leftStickX: number, leftStickY: number,
    rightStickX: number, rightStickY: number
  ): void;
  sendControllerArrivalEvent(
    controllerNumber: number, activeGamepadMask: number, type: number,
    supportedButtonFlags: number, capabilities: number
  ): number;
  sendControllerTouchEvent(
    controllerNumber: number, eventType: number, pointerId: number,
    x: number, y: number, pressure: number
  ): number;
  getHostFeatureFlags(): number;
  sendClientSdrWhiteNits(nits: number): number;
  sendControllerMotionEvent(
    controllerNumber: number, motionType: number, x: number, y: number, z: number
  ): number;
  sendControllerBatteryEvent(
    controllerNumber: number, batteryState: number, batteryPercentage: number
  ): number;
}

interface StreamCallbacks {
  drSetup?: (videoFormat: number, width: number, height: number, redrawRate: number) => void;
  drStart?: () => void;
  drStop?: () => void;
  drCleanup?: () => void;
  drSubmitDecodeUnit?: (data: ArrayBuffer, frameNumber: number, frameType: number) => void;
  arInit?: (audioConfiguration: number, sampleRate: number, samplesPerFrame: number) => void;
  arStart?: () => void;
  arStop?: () => void;
  arCleanup?: () => void;
  arPlaySample?: (samples: Int16Array) => void;
  stageStarting?: (stage: number) => void;
  stageComplete?: (stage: number) => void;
  stageFailed?: (stage: number, errorCode: number) => void;
  connectionStarted?: () => void;
  connectionTerminated?: (errorCode: number) => void;
  connectionStatusUpdate?: (connectionStatus: number) => void;
  /** native 侧按位置传 7 参:enabled + hasMetadata + 五个亮度值(见 callbacks.cpp CallJs_SetHdrMode) */
  setHdrMode?: (enabled: boolean, hasMetadata: boolean, maxDisplayLuminance: number,
    minDisplayLuminance: number, maxContentLightLevel: number, maxFrameAverageLightLevel: number,
    maxFullFrameLuminance: number) => void;
  rumble?: (controllerNumber: number, lowFreqMotor: number, highFreqMotor: number) => void;
  ds5HapticsIrV2?: (frame: Ds5HapticsIrV2Frame) => void;
  setAdaptiveTriggers?: (frame: AdaptiveTriggersFrame) => void;
  rumbleTriggers?: (controllerNumber: number, leftTrigger: number, rightTrigger: number) => void;
  setMotionEventState?: (controllerNumber: number, motionType: number, reportRateHz: number) => void;
  setControllerLED?: (controllerNumber: number, r: number, g: number, b: number) => void;
  resolutionChanged?: (width: number, height: number) => void;
  clipboardData?: (kind: number, token: number, payload: Uint8Array) => void;
  audioHapticFrame?: (frame: AudioHapticFrame) => void;
}

interface VideoStats {
  framesDecoded: number;
  codecOutputFrames: number;
  framesDropped: number;
  avgDecodeTimeMs: number;
  fps: number;
  codecOutputFps: number;
  renderedFps: number;
  bitrate: number;
  hostLatency: number;
  networkFrameLossPercent: number;
  totalDecodeTimeMs: number;
  validDecodeFrames: number;
  totalHostLatencyMs: number;
  framesWithHostLatency: number;
  globalAvgFps: number;
  hdrVivid: boolean;
  // 网络丢帧统计
  framesLost: number;
  totalFrames: number;
  // 分级丢帧统计
  droppedByL1: number;
  droppedByL2: number;
  droppedByL3: number;
  droppedByL4: number;
  droppedByL5: number;
  droppedByQueueOverflow: number;
  droppedByTimeout: number;
  syncDrainEvents: number;
  syncDrainFrames: number;
  syncDecode: boolean;
  hostPacedPresentationActive: boolean;
  presentationPrepared: number;
  presentationScheduled: number;
  presentationExpired: number;
  presentationMissing: number;
  presentationFuture: number;
  presentationNonMonotonicDrops: number;
  presentationRenderFallbacks: number;
  presentationLeadUnder1Ms: number;
  presentationLead1To2Ms: number;
  presentationLead2To4Ms: number;
  presentationLead4To8Ms: number;
  presentationLeadAtLeast8Ms: number;
  presentationPendingHighWater: number;
}

interface ControllerState {
  buttonFlags: number;
  leftTrigger: number;
  rightTrigger: number;
  leftStickX: number;
  leftStickY: number;
  rightStickX: number;
  rightStickY: number;
}

// =============================================================================
// 常量
// =============================================================================

/** Native 模块引用（供静态方法使用） */
const nativeModuleRef = nativeLib as NativeModule;

/** VIDEO_FORMAT 位掩码常量 */
const VIDEO_FORMAT_MASK_10BIT = 0xAA00;
const VIDEO_FORMAT_MASK_H264 = 0x000F;
const VIDEO_FORMAT_MASK_H265 = 0x0F00;
const VIDEO_FORMAT_MASK_AV1 = 0xF000;

/** 连接阶段名称映射 */
const STAGE_NAMES: Record<number, string> = {
  1: '正在初始化平台...',
  2: '正在解析服务器地址...',
  3: '正在建立 RTSP 连接...',
  4: '正在初始化控制通道...',
  5: '正在初始化视频通道...',
  6: '正在初始化音频通道...',
  7: '正在初始化输入通道...',
  8: '正在启动控制流...',
  9: '正在启动视频流...',
  10: '正在启动音频流...',
  11: '正在启动输入流...'
};

/** 标准 Xbox 手柄支持的按钮集合 */
const STANDARD_BUTTON_FLAGS =
  MoonlightButton.A | MoonlightButton.B | MoonlightButton.X | MoonlightButton.Y |
  MoonlightButton.UP | MoonlightButton.DOWN | MoonlightButton.LEFT | MoonlightButton.RIGHT |
  MoonlightButton.LB | MoonlightButton.RB |
  MoonlightButton.LS | MoonlightButton.RS |
  MoonlightButton.START | MoonlightButton.BACK | MoonlightButton.SPECIAL;

/** 亮度事件防抖和 SDR white 发送迟滞，避免拖动亮度条时刷控制包。 */
const SDR_WHITE_DEBOUNCE_MS = 500;
const SDR_WHITE_MIN_NITS = 50;
const SDR_WHITE_MAX_NITS = 1000;
const SDR_WHITE_MIN_DELTA_NITS = 10;
const SDR_WHITE_MIN_DELTA_RATIO = 0.05;

// =============================================================================
// StreamingSession
// =============================================================================

/**
 * 串流会话管理
 *
 * 负责管理与服务器的串流连接，包括：
 * - 视频解码与渲染
 * - 音频解码与播放
 * - 输入事件发送（键盘、手柄、鼠标）
 * - 麦克风采集与传输
 * - 性能统计
 */
export class StreamingSession implements Ds5TouchpadInputSink {

  // ---------------------------------------------------------------------------
  // 静态方法
  // ---------------------------------------------------------------------------

  /**
   * 获取解码器能力信息
   */
  static getDecoderCapabilities(): DecoderCapabilities {
    return nativeModuleRef.getDecoderCapabilities();
  }

  /**
   * 解析上报给 Sunshine 的 HDR 亮度范围。
   * 优先级:手动滑条覆盖(仅峰值/满帧)> 窗口采样实测 > 静态 profile。
   * sdrNits 与滑条正交:只要实测有效就上报。
   * @returns [minBrightness, maxBrightness, maxAverageBrightness] (nits)
   */
  private async resolveBrightnessRange(effectiveHdr: boolean): Promise<number[]> {
    const staticProfile = [
      DEFAULT_HDR_MIN_BRIGHTNESS_NITS,
      DEFAULT_HDR_MAX_BRIGHTNESS_NITS,
      DEFAULT_HDR_MAX_FULL_FRAME_BRIGHTNESS_NITS
    ];

    if (!effectiveHdr) {
      console.info('[Brightness] 非 HDR 会话,使用静态 profile: ' +
        `min=${staticProfile[0]}, max=${staticProfile[1]}, avg=${staticProfile[2]} nits`);
      return staticProfile;
    }

    // HDR 会话统一等待采样(在 start() 已提前发起,与网络请求重叠;此处兜底 2s)
    this.lastMeasuredSdrNits = 0;
    this.lastMeasuredPeakNits = 0;
    this.lastMeasuredFullFrameNits = 0;
    this.brightnessSource = 'static';
    let measured: MeasuredBrightnessProfile | null = null;
    if (this.brightnessSamplePromise) {
      measured = await Promise.race([
        this.brightnessSamplePromise,
        new Promise<MeasuredBrightnessProfile | null>(resolve => setTimeout(() => resolve(null), 2000))
      ]);
      if (measured) {
        this.lastMeasuredSdrNits = measured.sdrNits;
        this.lastMeasuredPeakNits = measured.maxBrightness;
        this.lastMeasuredFullFrameNits = measured.maxAverageBrightness;
        this.brightnessSource = 'measured';
      }
    } else {
      console.warn('[Brightness] 无采样结果');
    }

    if (this.config?.hdrBrightnessOverride) {
      this.brightnessSource = 'manual-override';
      const overridden = StreamingSession.applyBrightnessOverride(staticProfile, this.config.hdrPeakBrightnessNits);
      console.info('[Brightness] HDR 手动覆盖: min=' + overridden[0].toString() +
        ', max=' + overridden[1].toString() +
        ', avg=' + overridden[2].toString() +
        ', sdr=' + this.lastMeasuredSdrNits.toString() + ' nits');
      return overridden;
    }

    if (measured) {
      console.info('[Brightness] 实测 profile: sdr=' + measured.sdrNits.toString() +
        ', max=' + measured.maxBrightness.toString() +
        ', avg=' + measured.maxAverageBrightness.toString() + ' nits');
      return [DEFAULT_HDR_MIN_BRIGHTNESS_NITS, measured.maxBrightness, measured.maxAverageBrightness];
    }
    console.warn('[Brightness] 采样超时或未通过校验,回退静态 profile');
    return staticProfile;
  }

  private static applyBrightnessOverride(range: number[], peakBrightnessNits: number): number[] {
    const rawMinBrightness = range.length > 0 ? range[0] : DEFAULT_HDR_MIN_BRIGHTNESS_NITS;
    const minBrightness = Number.isFinite(rawMinBrightness) && rawMinBrightness > 0
      ? rawMinBrightness
      : DEFAULT_HDR_MIN_BRIGHTNESS_NITS;
    const peakBrightness = Math.max(minBrightness + 1, Math.max(300, Math.min(4000, Math.round(peakBrightnessNits))));
    const maxAverageBrightness = Math.max(minBrightness, Math.max(100, Math.min(1000, Math.round(peakBrightness * 0.2))));
    return [minBrightness, peakBrightness, maxAverageBrightness];
  }

  // ---------------------------------------------------------------------------
  // 成员变量 — 连接与配置
  // ---------------------------------------------------------------------------

  private nativeModule: NativeModule;
  private computerId: string = '';
  private appId: number = 0;
  private config: StreamConfig | null = null;
  private userBitrateLimitKbps: number = 0;
  private surfaceId: string = '';
  private isRunning: boolean = false;
  /** 用户主动发起的停止（菜单断开/退出游戏），抑制 connectionTerminated 回调弹窗 */
  private userInitiatedStop: boolean = false;
  private isStartingConnection: boolean = false;
  /** 回调代次:native 各回调走独立 TSFN,无跨队列顺序;init() 重注册时递增,用于丢弃旧代次迟到回调 */
  private static callbackGeneration: number = 0;
  private connectionStartPromise: Promise<number> | null = null;
  private lastFailedStage: number = 0;
  private computer: ComputerInfo | null = null;
  /** 本次串流最终选中的连接地址（手动/锁定/轮询胜出地址），保证 HTTP 与原生串流阶段一致 */
  private connectionAddress: string = '';
  private selectedAddress: string = '';
  private nvHttp: NvHttp | null = null;
  private riKey: ArrayBuffer | null = null;
  private riKeyId: number = 0;
  private displayGuid: string = '';
  private useVdd: boolean = false;
  /** 启动时提前发起的亮度采样(与网络等待重叠),永不 reject */
  private brightnessSamplePromise: Promise<MeasuredBrightnessProfile | null> | null = null;
  /** 实测 SDR 参考白 (nits,0=未测量/不可靠),用于 sdrBrightness 上报 */
  private lastMeasuredSdrNits: number = 0;
  private lastMeasuredPeakNits: number = 0;
  private lastMeasuredFullFrameNits: number = 0;
  private brightnessSource: string = 'static';
  /** brightnessInfoChange 监听器；事件只作失效信号，实际值由窗口重采样获得。 */
  private brightnessProbeHandler: ((displayId: number, info: display.BrightnessInfo) => void) | null = null;
  private brightnessUpdateTimer: number = -1;
  private brightnessSampleInFlight: boolean = false;
  private brightnessSamplePending: boolean = false;
  private brightnessUpdateGeneration: number = 0;
  private lastSentSdrWhiteNits: number = 0;

  // 服务器信息
  private serverAppVersion: string = '';
  private serverGfeVersion: string = '';
  private serverCodecModeSupport: number = 0;
  private cachedCurrentGame: number = 0;
  private rtspSessionUrl: string = '';

  // ---------------------------------------------------------------------------
  // 成员变量 — 回调
  // ---------------------------------------------------------------------------

  private hdrStateCallback: HdrStateCallback | null = null;
  private codecStateCallback: CodecStateCallback | null = null;
  private connectionTerminatedCallback: ((errorCode: number) => void) | null = null;
  private resolutionChangedCallback: ResolutionChangedCallback | null = null;
  private stageProgressCallback: ((stage: number, stageName: string) => void) | null = null;
  private connectionStatusCallback: ((connectionStatus: number) => void) | null = null;
  /** 视频解码器启动回调（drStart）：在 LiStartConnection 内部触发，早于 start() resolve */
  private decoderStartedCallback: (() => void) | null = null;

  // ---------------------------------------------------------------------------
  // 成员变量 — 手柄状态
  // ---------------------------------------------------------------------------

  private virtualControllerArrived: boolean = false;
  private physicalControllerArrived = new Set<number>();
  private activeGamepadMask: number = 0;
  /** 在连接建立前锁定触控板能力，确保首次 arrival 就带正确元数据。 */
  private ds5TouchpadEnabled: boolean = false;
  /** 连接期间稳定不变的主机能力，避免触摸 MOVE 热路径跨 NAPI 查询。 */
  private hostFeatureFlags: number = 0;
  private hostFeatureFlagsKnown: boolean = false;
  /** 屏幕触控板 clickpad 的粘滞状态，独立于各来源的完整手柄快照。 */
  private ds5TouchpadButtonPressed: boolean = false;
  /** 每个槽位最近一次完整状态，触控板点击必须在此状态上合并。 */
  private controllerStates: Map<number, ControllerState> = new Map();
  private physicalControllerTypes: Map<number, number> = new Map();
  private controllerState: ControllerState = {
    buttonFlags: 0,
    leftTrigger: 0,
    rightTrigger: 0,
    leftStickX: 0,
    leftStickY: 0,
    rightStickX: 0,
    rightStickY: 0
  };

  // ---------------------------------------------------------------------------
  // 成员变量 — 性能统计
  // ---------------------------------------------------------------------------

  private stats: StreamStats = {
    fps: 0, codecOutputFps: 0, renderedFps: 0, bitrate: 0, latency: 0,
    hostLatency: 0, networkLatency: 0, packetLoss: 0,
    networkFrameLossPercent: 0,
    decodedFrames: 0, codecOutputFrames: 0, droppedFrames: 0,
    hdrVivid: false,
    hostMaxLuminance: 0, hostMaxFullFrame: 0,
    hdrMode: 0, hdrBrightnessSource: 'static', hdrBrightnessOverride: false,
    measuredSdrNits: 0, measuredPeakNits: 0, measuredFullFrameNits: 0,
    sentSdrWhiteNits: 0, sentPeakNits: 0, sentFullFrameNits: 0,
    framesLost: 0, totalFrames: 0,
    globalAvgDecodeLatency: 0, globalAvgHostLatency: 0, globalAvgFps: 0,
    droppedByL1: 0, droppedByL2: 0, droppedByL3: 0, droppedByL4: 0, droppedByL5: 0,
    droppedByQueueOverflow: 0, droppedByTimeout: 0,
    syncDrainEvents: 0, syncDrainFrames: 0,
    syncDecode: false, hostPacedPresentationActive: false,
    presentationPrepared: 0, presentationScheduled: 0,
    presentationExpired: 0, presentationMissing: 0, presentationFuture: 0,
    presentationNonMonotonicDrops: 0, presentationRenderFallbacks: 0,
    presentationLeadUnder1Ms: 0, presentationLead1To2Ms: 0,
    presentationLead2To4Ms: 0, presentationLead4To8Ms: 0,
    presentationLeadAtLeast8Ms: 0, presentationPendingHighWater: 0
  };
  private lastValidStats: StreamStats | null = null;
  /** 宿主最近一次通过 SS_HDR_METADATA 下发的元数据(null=未收到) */
  private lastHostHdrMetadata: HostHdrMetadata | null = null;

  // 滑动窗口丢包率统计（对齐 Android: lastTwo = lastWindow + activeWindow）
  private prevSnapshotLost: number = 0;    // 上一窗口起始时的累计 framesLost
  private prevSnapshotTotal: number = 0;   // 上一窗口起始时的累计 totalFrames
  private activeSnapshotLost: number = 0;  // 当前窗口起始时的累计 framesLost
  private activeSnapshotTotal: number = 0; // 当前窗口起始时的累计 totalFrames
  private lastWindowFlipTime: number = 0;  // 上次窗口翻转的时间戳

  // ---------------------------------------------------------------------------
  // 成员变量 — 音频与麦克风
  // ---------------------------------------------------------------------------

  private audioVibrationService: AudioVibrationService = new AudioVibrationService();
  private microphoneStream: MicrophoneStream | null = null;
  private abilityContext: common.UIAbilityContext | undefined = undefined;

  // ---------------------------------------------------------------------------
  // 成员变量 — 智能码率
  // ---------------------------------------------------------------------------

  private abrService: AdaptiveBitrateService | null = null;

  // ---------------------------------------------------------------------------
  // 构造函数
  // ---------------------------------------------------------------------------

  constructor() {
    this.nativeModule = nativeLib as NativeModule;
  }

  // ---------------------------------------------------------------------------
  // 回调设置
  // ---------------------------------------------------------------------------

  setHdrStateCallback(callback: HdrStateCallback | null): void {
    this.hdrStateCallback = callback;
  }

  setCodecStateCallback(callback: CodecStateCallback | null): void {
    this.codecStateCallback = callback;
  }

  /**
   * 设置连接终止回调
   * errorCode: 0 = 正常关闭, <0 = 错误
   */
  setConnectionTerminatedCallback(callback: ((errorCode: number) => void) | null): void {
    this.connectionTerminatedCallback = callback;
  }

  setResolutionChangedCallback(callback: ResolutionChangedCallback | null): void {
    this.resolutionChangedCallback = callback;
  }

  setStageProgressCallback(callback: ((stage: number, stageName: string) => void) | null): void {
    this.stageProgressCallback = callback;
  }

  setConnectionStatusCallback(callback: ((connectionStatus: number) => void) | null): void {
    this.connectionStatusCallback = callback;
  }

  /**
   * 设置"视频解码器已启动"回调（对应 native drStart）。
   * 此回调在 LiStartConnection 内部、首帧渲染前触发，比 session.start() resolve 更早。
   * UI 可以借此提前隐藏 loading 蒙层，让用户更快看到画面。
   */
  setDecoderStartedCallback(callback: (() => void) | null): void {
    this.decoderStartedCallback = callback;
  }

  // ---------------------------------------------------------------------------
  // 生命周期 — 启动 / 停止 / 恢复
  // ---------------------------------------------------------------------------

  /**
   * 开始串流会话
   */
  async start(
    computerId: string,
    appId: number,
    config: StreamConfig,
    surfaceId: string,
    context?: common.UIAbilityContext,
    displayGuid?: string,
    useVdd?: boolean
  ): Promise<void> {
    this.computerId = computerId;
    this.appId = appId;
    this.config = config;
    this.userBitrateLimitKbps = config.bitrate;
    this.surfaceId = surfaceId;
    this.displayGuid = displayGuid || '';
    this.useVdd = useVdd || false;
    this.abilityContext = context;
    this.userInitiatedStop = false;
    this.lastMeasuredSdrNits = 0;
    this.lastSentSdrWhiteNits = 0;
    this.brightnessSamplePending = false;
    this.brightnessSampleInFlight = false;
    this.brightnessUpdateGeneration++;
    this.lastHostHdrMetadata = null;
    // 亮度采样提前发起,与后续网络请求重叠执行,不增加启动延迟
    this.brightnessSamplePromise = sampleDisplayBrightness(0).catch(() => null);
    this.registerBrightnessProbe();

    console.info(`开始串流: computer=${computerId}, app=${appId}`);
    console.info(`配置: ${config.width}x${config.height}@${config.fps}fps, ${config.bitrate}kbps, ${config.codec}`);
    console.info(`HDR: hdr=${config.hdr}, hdrMode=${config.hdrMode}, colorRange=${config.colorRange}`);
    if (this.displayGuid || this.useVdd) {
      console.info(`显示器: displayGuid=${this.displayGuid}, useVdd=${this.useVdd}`);
    }

    try {
      await this.resolveComputer(computerId, context);
      await this.applyInitialBitratePolicy();
      this.generateInputKey();
      // 并行执行：网络请求（fetchServerInfo）与本地 native 初始化没有依赖，
      // 可重叠执行节省 50-300ms。两者都会更新 stageProgressCallback 文本，
      // 后到者覆盖前者，对用户感知无影响。
      await Promise.all([
        this.fetchServerInfo(),
        this.initializeNative(),
      ]);
      this.applyPreConnectionSettings(config);
      await this.setupVideoSurface();

      if (this.stageProgressCallback) {
        this.stageProgressCallback(0, '正在启动应用...');
      }
      const cachedCurrentGame = this.getCachedCurrentGame();
      await this.launchApp(cachedCurrentGame);
      // 成功 launch/resume 后 currentGame 必然变化（变为本次 appId），
      // 让缓存立即失效，避免下次进入串流复用陈旧的 currentGame 导致误判
      ComputerManager.getInstance().invalidateServerInfoCache(this.computerId);
      await this.connectToServer();
      if (this.userInitiatedStop) {
        return;
      }
      this.applyPostConnectionSettings(config);

      this.isRunning = true;
      // Network Boost Kit: 声明实时游戏类业务，让系统优先调度
      NetworkBoostService.getInstance().start();
    } catch (err) {
      await this.cleanup();
      throw new Error(`串流会话启动失败: ${(err as Error).message}`);
    }
  }

  /**
   * 停止串流会话
   */
  async stop(): Promise<void> {
    console.info('停止串流');
    this.userInitiatedStop = true;
    // 必须在 isRunning 翻转前注销：回调闭包以 isRunning 守卫，
    // 翻转后 CANCEL 无法发出，主机侧活动触点将悬死到断连
    GamepadManager.getInstance().setControllerTouchCallback(null);
    this.isRunning = false;
    this.resetControllerState();
    GamepadManager.getInstance().stopAllSensors();
    this.audioVibrationService.stop();
    NetworkBoostService.getInstance().stop();
    await this.cleanup();
  }

  /**
   * 退出远程应用并停止串流
   */
  async quitApp(): Promise<boolean> {
    console.info('退出远程应用');
    this.userInitiatedStop = true;
    let quitSuccess = false;

    if (this.nvHttp) {
      try {
        quitSuccess = await this.nvHttp.quitApp();
        console.info(quitSuccess ? '远程应用已退出' : '退出远程应用失败');
      } catch (err) {
        console.error('退出远程应用出错:', err);
      }
    }

    // 与 stop() 相同：在 isRunning 翻转前注销触点回调并发送 CANCEL
    GamepadManager.getInstance().setControllerTouchCallback(null);
    this.isRunning = false;
    NetworkBoostService.getInstance().stop();
    await this.cleanup();
    return quitSuccess;
  }

  /**
   * 从后台恢复解码器
   */
  resumeDecoder(): void {
    if (!this.isRunning) {
      console.warn('[StreamingSession] 串流已停止，无需恢复解码器');
      return;
    }
    try {
      (nativeLib as NativeModule).resumeDecoder();
      console.info('[StreamingSession] 解码器恢复命令已发送');
    } catch (err) {
      console.error('[StreamingSession] 恢复解码器失败:', err);
    }
  }

  // ---------------------------------------------------------------------------
  // 配置与状态查询
  // ---------------------------------------------------------------------------

  getEffectiveConfig(): StreamConfig | null {
    return this.config;
  }

  getCurrentBitrate(): number {
    return this.config?.bitrate || 0;
  }

  /**
   * 热更新当前会话的音频振动设置。
   *
   * SDK 接收场景创作配置及对应的内部检测灵敏度；用户强度继续由平台
   * 渲染层统一缩放，避免同时暴露 sensitivity 和输出增益两套旋钮。
   */
  updateAudioVibrationSettings(enabled: boolean, strength: number,
    vibrationMode: string, sceneMode: string): void {
    const normalizedStrength = Math.max(0, Math.min(100, Math.round(strength)));
    if (this.config) {
      this.config.enableAudioVibration = enabled;
      this.config.audioVibrationStrength = normalizedStrength;
      this.config.vibrationMode = vibrationMode;
      this.config.audioVibrationSceneMode = sceneMode;
    }

    this.audioVibrationService.setSettings(
      enabled, normalizedStrength, vibrationMode, sceneMode);
    this.nativeModule.setAudioHapticsConfig(
      enabled,
      this.audioVibrationService.getOnsetSensitivity(),
      this.audioVibrationService.getSceneModeInt());
  }

  // ---------------------------------------------------------------------------
  // 服务器控制
  // ---------------------------------------------------------------------------

  /**
   * 动态调整码率 (kbps)
   */
  async setBitrate(bitrate: number): Promise<boolean> {
    if (!this.nvHttp) return false;
    try {
      const success = await this.nvHttp.setBitrate(bitrate);
      if (success && this.config) this.config.bitrate = bitrate;
      return success;
    } catch {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 智能码率 (ABR)
  // ---------------------------------------------------------------------------

  /**
   * 启动智能码率调节
   */
  async startAbr(mode: string): Promise<void> {
    if (!this.nvHttp || !this.config) return;
    if (this.abrService) return;  // 已启动

    this.abrService = new AdaptiveBitrateService(this.nvHttp);
    await this.abrService.checkCapabilities();
    await this.abrService.start(
      this.config.bitrate,
      this.userBitrateLimitKbps,
      mode,
      () => this.getStats(),
      async (bitrate: number, _reason: string): Promise<boolean> => {
        return this.setBitrate(bitrate);
      },
      (bitrate: number): void => {
        if (this.config) {
          this.config.bitrate = bitrate;
        }
      }
    );
  }

  /**
   * 停止智能码率调节
   */
  async stopAbr(): Promise<void> {
    if (!this.abrService) return;
    await this.abrService.stop();
    this.abrService = null;
  }

  /**
   * 智能码率是否启用
   */
  isAbrEnabled(): boolean {
    return this.abrService?.isEnabled() ?? false;
  }

  /**
   * 获取 ABR 状态文本（用于性能面板）
   */
  getAbrStatusText(): string {
    return this.abrService?.getStatusText() ?? '';
  }

  /**
   * 发送超级指令 (Sunshine)
   */
  async sendSuperCmd(cmdId: string): Promise<boolean> {
    if (!this.nvHttp) return false;
    try {
      return await this.nvHttp.sendSuperCmd(cmdId);
    } catch {
      return false;
    }
  }

  /**
   * 旋转显示器方向 (Sunshine)
   * @param angle 0=横屏, 90=竖屏
   */
  async rotateDisplay(angle: number, displayName?: string): Promise<boolean> {
    if (!this.nvHttp) {
      console.warn('StreamingSession: rotateDisplay 失败 - nvHttp 未初始化');
      return false;
    }
    try {
      return await this.nvHttp.rotateDisplay(angle, displayName);
    } catch (err) {
      console.warn(`StreamingSession: rotateDisplay 失败: ${err}`);
      return false;
    }
  }

  /**
   * 设置音频音量 (0.0 ~ 1.0)
   */
  setAudioVolume(volume: number): boolean {
    return this.nativeModule.setAudioVolume(volume);
  }

  getActiveUpscaleMode(): number {
    return this.nativeModule.getActiveUpscaleMode();
  }

  // ---------------------------------------------------------------------------
  // 输入 — 键盘与文本
  // ---------------------------------------------------------------------------

  /**
   * 发送键盘输入
   * @param keyCode Windows 虚拟键码
   * @param keyAction 0x03=KEY_DOWN, 0x04=KEY_UP
   * @param modifiers SHIFT=0x01, CTRL=0x02, ALT=0x04, META=0x08
   */
  sendKeyboardInput(keyCode: number, keyAction: number, modifiers: number = 0): void {
    if (!this.isRunning) return;
    this.nativeModule.sendKeyboardInput(keyCode, keyAction, modifiers, 0);
  }

  /**
   * 发送按键序列（同时按下，延迟后释放）
   */
  sendKeys(keyCodes: number[]): void {
    if (!this.isRunning || keyCodes.length === 0) return;

    let modifier = 0;
    for (const key of keyCodes) {
      this.nativeModule.sendKeyboardInput(key, KEY_ACTION_DOWN, modifier, 0);
      modifier |= StreamingSession.getModifierForKey(key);
    }

    setTimeout(() => {
      for (let i = keyCodes.length - 1; i >= 0; i--) {
        modifier &= ~StreamingSession.getModifierForKey(keyCodes[i]);
        this.nativeModule.sendKeyboardInput(keyCodes[i], KEY_ACTION_UP, modifier, 0);
      }
    }, 25);
  }

  /**
   * 发送 UTF-8 文本（用于 IME 输入）
   */
  sendUtf8Text(text: string): void {
    if (!this.isRunning || text.length === 0) return;
    this.nativeModule.sendUtf8Text(text);
  }

  /**
   * 在下一次 controller arrival 上声明触控板能力。
   * 该开关应在连接建立前设置；Sunshine 不会接受已分配槽位的重复 arrival。
   */
  setDs5TouchpadEnabled(enabled: boolean): void {
    const changed = this.ds5TouchpadEnabled !== enabled;
    this.ds5TouchpadEnabled = enabled;
    if (changed && this.isRunning) {
      this.reannouncePrimaryController();
    }
  }

  isDs5TouchpadEnabled(): boolean {
    return this.ds5TouchpadEnabled;
  }

  /** 主机是否宣告 controller-touch 扩展。 */
  isControllerTouchpadSupported(): boolean {
    if (!this.isRunning) return false;
    if (!this.hostFeatureFlagsKnown) this.readHostFeatureFlags();
    return (this.hostFeatureFlags & LI_FF_CONTROLLER_TOUCH_EVENTS) !== 0;
  }

  private readHostFeatureFlags(): number {
    try {
      this.hostFeatureFlags = this.nativeModule.getHostFeatureFlags();
      this.hostFeatureFlagsKnown = true;
    } catch (_) {
      this.hostFeatureFlags = 0;
      // Feature flags are fixed for the lifetime of the connection. Treat a
      // failed read as unsupported and avoid retrying on every MOVE event.
      this.hostFeatureFlagsKnown = true;
    }
    return this.hostFeatureFlags;
  }

  /** Ds5TouchpadInputSink: 发送屏幕触控板触点。 */
  sendDs5TouchpadEvent(eventType: number, pointerId: number,
    x: number, y: number, pressure: number): number {
    // -2 means the local session is unavailable; it must not trigger the
    // user-facing "host unsupported" fallback in the gesture handler.
    if (!this.isRunning || !this.ds5TouchpadEnabled) return -2;
    if (!this.isControllerTouchpadSupported()) return LI_ERR_UNSUPPORTED;

    this.ensureVirtualControllerArrival(0);
    return this.nativeModule.sendControllerTouchEvent(
      0, eventType, pointerId, x, y, pressure
    );
  }

  /** Ds5TouchpadInputSink: 在最近一次完整手柄状态上合并 clickpad。 */
  setDs5TouchpadButtonPressed(pressed: boolean): void {
    if (!this.isRunning || (!this.ds5TouchpadEnabled && pressed)) return;

    if (this.ds5TouchpadEnabled) {
      this.ensureVirtualControllerArrival(0);
    } else if (!this.virtualControllerArrived && !this.physicalControllerArrived.has(0)) {
      return;
    }
    this.ds5TouchpadButtonPressed = pressed;
    this.sendControllerStateSnapshot(0, this.getControllerState(0));
  }

  /**
   * 发送虚拟手柄输入（供 CustomKeyManager 使用）
   *
   * 与直接调用 MoonBridge 不同，此方法会先确保 controllerArrival 已发送，
   * 并使用正确的 activeGamepadMask。对应 Android ControllerHandler 的流程。
   */
  sendVirtualControllerInput(
    buttonFlags: number, leftTrigger: number, rightTrigger: number,
    leftStickX: number, leftStickY: number,
    rightStickX: number, rightStickY: number,
  ): void {
    if (!this.isRunning) return;
    const controllerIndex = 0;
    this.ensureVirtualControllerArrival(controllerIndex);
    this.controllerState.buttonFlags = buttonFlags;
    this.controllerState.leftTrigger = leftTrigger;
    this.controllerState.rightTrigger = rightTrigger;
    this.controllerState.leftStickX = leftStickX;
    this.controllerState.leftStickY = leftStickY;
    this.controllerState.rightStickX = rightStickX;
    this.controllerState.rightStickY = rightStickY;
    this.controllerStates.set(controllerIndex, this.cloneControllerState(this.controllerState));
    this.sendControllerStateSnapshot(controllerIndex, this.controllerState);
  }

  // ---------------------------------------------------------------------------
  // 输入 — 手柄（虚拟 + 物理）
  // ---------------------------------------------------------------------------

  /**
   * 发送虚拟手柄输入事件
   */
  sendInput(input: InputEvent): void {
    if (!this.isRunning) return;

    if (input.type === InputType.CONTROLLER_BUTTON) {
      this.handleControllerButton(input as ControllerButtonEvent);
    } else if (input.type === InputType.CONTROLLER_AXIS) {
      this.handleControllerAxis(input as ControllerAxisEvent);
    }
  }

  /**
   * 发送物理手柄完整状态
   */
  sendGamepadState(
    controllerIndex: number,
    buttons: number,
    leftStickX: number, leftStickY: number,
    rightStickX: number, rightStickY: number,
    leftTrigger: number, rightTrigger: number,
    controllerType: number = CONTROLLER_TYPE_XBOX
  ): void {
    if (!this.isRunning) return;

    if (controllerIndex < 0 || controllerIndex > 3) {
      console.warn(`[Gamepad] controllerIndex 越界: ${controllerIndex}, 钳位到 0`);
      controllerIndex = 0;
    }

    this.ensurePhysicalControllerArrival(controllerIndex, controllerType);
    const state: ControllerState = {
      buttonFlags: buttons,
      leftTrigger: leftTrigger,
      rightTrigger: rightTrigger,
      leftStickX: leftStickX,
      leftStickY: leftStickY,
      rightStickX: rightStickX,
      rightStickY: rightStickY
    };
    this.controllerStates.set(controllerIndex, state);
    this.sendControllerStateSnapshot(controllerIndex, state);
  }

  /**
   * 物理 USB 附加驱动可能晚于 GCK 输入设备到达。
   * 对已声明的槽位重发 arrival，使主机重新读取新增的 IMU 能力。
   */
  refreshPhysicalControllerCapabilities(
    controllerIndex: number,
    controllerType: number = CONTROLLER_TYPE_XBOX
  ): void {
    if (!this.isRunning || !this.physicalControllerArrived.has(controllerIndex)) return;
    if (controllerIndex === 0 && this.virtualControllerArrived) {
      this.reannouncePrimaryController(controllerType);
      return;
    }
    this.physicalControllerArrived.delete(controllerIndex);
    this.ensurePhysicalControllerArrival(controllerIndex, controllerType);
  }

  // ---------------------------------------------------------------------------
  // 性能统计
  // ---------------------------------------------------------------------------

  /**
   * 获取实时性能统计
   */
  getStats(): StreamStats {
    try {
      const vs = this.nativeModule.getVideoStats();
      this.stats.decodedFrames = vs.framesDecoded;
      this.stats.codecOutputFrames = vs.codecOutputFrames || 0;
      this.stats.droppedFrames = vs.framesDropped;
      this.stats.hdrVivid = vs.hdrVivid || false;
      this.stats.hostMaxLuminance = this.lastHostHdrMetadata ? this.lastHostHdrMetadata.maxDisplayLuminance : 0;
      this.stats.hostMaxFullFrame = this.lastHostHdrMetadata ? this.lastHostHdrMetadata.maxFullFrameLuminance : 0;
      this.stats.fps = vs.fps || 0;
      this.stats.codecOutputFps = vs.codecOutputFps || 0;
      this.stats.renderedFps = vs.renderedFps || 0;
      this.stats.bitrate = vs.bitrate || 0;
      this.stats.latency = vs.avgDecodeTimeMs || 0;
      this.stats.hostLatency = vs.hostLatency || 0;
      this.stats.networkFrameLossPercent = vs.networkFrameLossPercent || 0;

      // 滑动窗口丢包率（对齐 Android: ~2秒窗口 = lastWindow + activeWindow）
      const totalFrames = vs.totalFrames || 0;
      const framesLost = vs.framesLost || 0;
      this.stats.totalFrames = totalFrames;
      this.stats.framesLost = framesLost;
      const now = Date.now();
      if (this.lastWindowFlipTime === 0) {
        // 首次调用：初始化窗口
        this.lastWindowFlipTime = now;
        this.activeSnapshotLost = framesLost;
        this.activeSnapshotTotal = totalFrames;
        this.prevSnapshotLost = framesLost;
        this.prevSnapshotTotal = totalFrames;
      } else if (now - this.lastWindowFlipTime >= 1000) {
        // 每秒翻转窗口：prev <- active, active <- 当前累计值
        this.prevSnapshotLost = this.activeSnapshotLost;
        this.prevSnapshotTotal = this.activeSnapshotTotal;
        this.activeSnapshotLost = framesLost;
        this.activeSnapshotTotal = totalFrames;
        this.lastWindowFlipTime = now;
      }
      // 用最近两个窗口的增量计算丢包率
      const windowLost = framesLost - this.prevSnapshotLost;
      const windowTotal = totalFrames - this.prevSnapshotTotal;
      this.stats.packetLoss = windowTotal > 0 ? (windowLost / windowTotal * 100) : 0;

      // 分级丢帧统计
      this.stats.droppedByL1 = vs.droppedByL1 || 0;
      this.stats.droppedByL2 = vs.droppedByL2 || 0;
      this.stats.droppedByL3 = vs.droppedByL3 || 0;
      this.stats.droppedByL4 = vs.droppedByL4 || 0;
      this.stats.droppedByL5 = vs.droppedByL5 || 0;
      this.stats.droppedByQueueOverflow = vs.droppedByQueueOverflow || 0;
      this.stats.droppedByTimeout = vs.droppedByTimeout || 0;
      this.stats.syncDrainEvents = vs.syncDrainEvents || 0;
      this.stats.syncDrainFrames = vs.syncDrainFrames || 0;
      this.stats.syncDecode = vs.syncDecode || false;
      this.stats.hostPacedPresentationActive = vs.hostPacedPresentationActive || false;
      this.stats.presentationPrepared = vs.presentationPrepared || 0;
      this.stats.presentationScheduled = vs.presentationScheduled || 0;
      this.stats.presentationExpired = vs.presentationExpired || 0;
      this.stats.presentationMissing = vs.presentationMissing || 0;
      this.stats.presentationFuture = vs.presentationFuture || 0;
      this.stats.presentationNonMonotonicDrops = vs.presentationNonMonotonicDrops || 0;
      this.stats.presentationRenderFallbacks = vs.presentationRenderFallbacks || 0;
      this.stats.presentationLeadUnder1Ms = vs.presentationLeadUnder1Ms || 0;
      this.stats.presentationLead1To2Ms = vs.presentationLead1To2Ms || 0;
      this.stats.presentationLead2To4Ms = vs.presentationLead2To4Ms || 0;
      this.stats.presentationLead4To8Ms = vs.presentationLead4To8Ms || 0;
      this.stats.presentationLeadAtLeast8Ms = vs.presentationLeadAtLeast8Ms || 0;
      this.stats.presentationPendingHighWater = vs.presentationPendingHighWater || 0;

      if ((vs.validDecodeFrames || 0) > 0) {
        this.stats.globalAvgDecodeLatency = (vs.totalDecodeTimeMs || 0) / vs.validDecodeFrames;
      }
      if ((vs.framesWithHostLatency || 0) > 0) {
        this.stats.globalAvgHostLatency = (vs.totalHostLatencyMs || 0) / vs.framesWithHostLatency;
      }
      if (vs.globalAvgFps > 0) {
        this.stats.globalAvgFps = vs.globalAvgFps;
      }

      const rttInfo = this.nativeModule.getEstimatedRttInfo();
      if (rttInfo >= 0) {
        this.stats.networkLatency = Math.floor(rttInfo / 0x100000000);
      }
    } catch (_) { /* ignore */ }

    const copy: StreamStats = {
      fps: this.stats.fps,
      codecOutputFps: this.stats.codecOutputFps,
      renderedFps: this.stats.renderedFps,
      bitrate: this.stats.bitrate,
      latency: this.stats.latency,
      hostLatency: this.stats.hostLatency,
      networkLatency: this.stats.networkLatency,
      packetLoss: this.stats.packetLoss,
      networkFrameLossPercent: this.stats.networkFrameLossPercent,
      decodedFrames: this.stats.decodedFrames,
      codecOutputFrames: this.stats.codecOutputFrames,
      droppedFrames: this.stats.droppedFrames,
      hdrVivid: this.stats.hdrVivid,
      hostMaxLuminance: this.stats.hostMaxLuminance,
      hostMaxFullFrame: this.stats.hostMaxFullFrame,
      hdrMode: this.stats.hdrMode,
      hdrBrightnessSource: this.stats.hdrBrightnessSource,
      hdrBrightnessOverride: this.stats.hdrBrightnessOverride,
      measuredSdrNits: this.stats.measuredSdrNits,
      measuredPeakNits: this.stats.measuredPeakNits,
      measuredFullFrameNits: this.stats.measuredFullFrameNits,
      sentSdrWhiteNits: this.stats.sentSdrWhiteNits,
      sentPeakNits: this.stats.sentPeakNits,
      sentFullFrameNits: this.stats.sentFullFrameNits,
      framesLost: this.stats.framesLost,
      totalFrames: this.stats.totalFrames,
      globalAvgDecodeLatency: this.stats.globalAvgDecodeLatency,
      globalAvgHostLatency: this.stats.globalAvgHostLatency,
      globalAvgFps: this.stats.globalAvgFps,
      droppedByL1: this.stats.droppedByL1,
      droppedByL2: this.stats.droppedByL2,
      droppedByL3: this.stats.droppedByL3,
      droppedByL4: this.stats.droppedByL4,
      droppedByL5: this.stats.droppedByL5,
      droppedByQueueOverflow: this.stats.droppedByQueueOverflow,
      droppedByTimeout: this.stats.droppedByTimeout,
      syncDrainEvents: this.stats.syncDrainEvents,
      syncDrainFrames: this.stats.syncDrainFrames,
      syncDecode: this.stats.syncDecode,
      hostPacedPresentationActive: this.stats.hostPacedPresentationActive,
      presentationPrepared: this.stats.presentationPrepared,
      presentationScheduled: this.stats.presentationScheduled,
      presentationExpired: this.stats.presentationExpired,
      presentationMissing: this.stats.presentationMissing,
      presentationFuture: this.stats.presentationFuture,
      presentationNonMonotonicDrops: this.stats.presentationNonMonotonicDrops,
      presentationRenderFallbacks: this.stats.presentationRenderFallbacks,
      presentationLeadUnder1Ms: this.stats.presentationLeadUnder1Ms,
      presentationLead1To2Ms: this.stats.presentationLead1To2Ms,
      presentationLead2To4Ms: this.stats.presentationLead2To4Ms,
      presentationLead4To8Ms: this.stats.presentationLead4To8Ms,
      presentationLeadAtLeast8Ms: this.stats.presentationLeadAtLeast8Ms,
      presentationPendingHighWater: this.stats.presentationPendingHighWater,
    };
    copy.fps = Math.round(copy.fps);
    copy.codecOutputFps = Math.round(copy.codecOutputFps);
    copy.renderedFps = Math.round(copy.renderedFps);
    copy.bitrate = Math.round(copy.bitrate);

    if (copy.renderedFps > 0 || copy.latency > 0) {
      this.lastValidStats = copy;
    }
    return copy;
  }

  /**
   * 获取汇总统计（串流结束后使用，回退到最后有效快照）
   */
  getSummaryStats(): StreamStats {
    const current = this.getStats();
    if (current.renderedFps > 0 || current.latency > 0) return current;
    return this.lastValidStats || current;
  }

  // ---------------------------------------------------------------------------
  // 内部 — 启动流程子步骤
  // ---------------------------------------------------------------------------

  private async resolveComputer(computerId: string, context?: common.UIAbilityContext): Promise<void> {
    const computerManager = ComputerManager.getInstance();
    const computerResult = computerManager.getComputer(computerId);
    if (!computerResult) throw new Error(`找不到电脑: ${computerId}`);
    this.computer = computerResult;
    const selectedAddress = selectBestAddress(this.computer);
    if (!selectedAddress) throw new Error(`没有可用的连接地址: ${this.computer.name}`);

    this.selectedAddress = selectedAddress;
    // NvHttp 允许地址中携带自定义 HTTP 端口；原生 LiStartConnection 需要纯 host。
    this.connectionAddress = parseAddressAndPort(selectedAddress).host;
    console.info(`串流连接地址: selected=${selectedAddress}, nativeHost=${this.connectionAddress}`);
    this.nvHttp = NvHttp.fromAddress(selectedAddress, this.computer, context);
  }

  private async applyInitialBitratePolicy(): Promise<void> {
    if (!this.config || !this.selectedAddress || !this.nvHttp) {
      return;
    }
    try {
      const decision = await BandwidthProbeService.getInstance().resolveInitialBitrate(
        this.computerId, this.selectedAddress, this.config.bitrate, this.nvHttp);
      this.config.bitrate = decision.bitrateKbps;
      console.info('StreamingSession: 初始码率路径=' + decision.path + ', userLimit=' +
        decision.userLimitKbps.toString() + 'kbps, effective=' + decision.bitrateKbps.toString() +
        'kbps, probeApplied=' + decision.probeApplied.toString() + ', measured=' +
        Math.round(decision.measuredKbps).toString() + 'kbps');
    } catch (err) {
      console.warn('StreamingSession: 初始码率策略回退到原配置: ' + String(err));
    }
  }

  private async fetchServerInfo(): Promise<void> {
    if (!this.nvHttp) throw new Error('nvHttp 未初始化');

    // 命中 ComputerManager 的 ServerInfo 缓存：避免与轮询/AppList 刷新刚拿到的
    // 数据重复一次 HTTPS round-trip（典型局域网 50-200ms，远程更长）。
    const cached = ComputerManager.getInstance().getCachedServerInfo(this.computerId);
    if (cached) {
      this.serverAppVersion = cached.appVersion || '';
      this.serverGfeVersion = cached.gfeVersion || '';
      this.serverCodecModeSupport = cached.serverCodecModeSupport || 0;
      this.cachedCurrentGame = cached.currentGame || 0;
      console.info(`串流: 命中 ServerInfo 缓存, currentGame=${this.cachedCurrentGame}, codecSupport=${this.serverCodecModeSupport}`);
      if (this.stageProgressCallback) {
        this.stageProgressCallback(0, '正在初始化...');
      }
      return;
    }

    // 主机/Sunshine 重启窗口（mDNS/ICMP 已恢复但 HTTPS 监听尚未 ready）会让单次 ServerInfo
    // 请求必败。委托给 NvHttp.getServerInfoRobust 处理瞬时错误重试 + 取消响应，
    // 避免在业务层重复维护错误识别 / 重试 / 取消的细节。
    const serverInfo = await this.nvHttp.getServerInfoRobust({
      isCancelled: (): boolean => this.userInitiatedStop,
      // 注意：onRetry 仅在还有后续重试时触发，maxAttempts === 1 时不会被调用
      onRetry: (attempt: number, maxAttempts: number): void => {
        if (this.stageProgressCallback) {
          this.stageProgressCallback(0, `连接重试中 (${attempt}/${Math.max(1, maxAttempts - 1)})...`);
        }
      },
    });

    this.serverAppVersion = serverInfo.appVersion || '';
    this.serverGfeVersion = serverInfo.gfeVersion || '';
    this.serverCodecModeSupport = serverInfo.serverCodecModeSupport || 0;
    this.cachedCurrentGame = serverInfo.currentGame || 0;
    console.info(`服务器版本: app=${this.serverAppVersion}, gfe=${this.serverGfeVersion}, ` +
      `codecSupport=${this.serverCodecModeSupport}, currentGame=${this.cachedCurrentGame}`);

    // 写回缓存供后续短期内复用（场景：连接失败后用户立即重试）
    ComputerManager.getInstance().cacheServerInfo(this.computerId, serverInfo);

    if (this.stageProgressCallback) {
      this.stageProgressCallback(0, '正在初始化...');
    }
  }

  private getCachedCurrentGame(): number {
    return this.cachedCurrentGame;
  }

  private generateInputKey(): void {
    this.riKey = CryptoUtil.generateAesKey();
    this.riKeyId = CryptoUtil.generateRandomUint32();
  }

  private applyPreConnectionSettings(config: StreamConfig): void {
    this.nativeModule.setSpatialAudioEnabled(config.enableSpatializer);
    if (config.enableSpatializer) {
      console.info('空间音频已启用');
    }
    this.nativeModule.setAudioCompatMode(config.audioCompatMode);
    if (config.audioCompatMode) {
      console.info('音频兼容模式已启用');
    }
    if (config.performanceMode) {
      this.nativeModule.setPerformanceModeEnabled(true);
      console.info('性能模式已启用');
    }
    this.audioVibrationService.setSettings(
      config.enableAudioVibration, config.audioVibrationStrength, config.vibrationMode,
      config.audioVibrationSceneMode
    );
  }

  private applyPostConnectionSettings(config: StreamConfig): void {
    // 必须在 connectToServer() 之后，确保 SDK Core 已按实际 PCM 格式创建。
    this.updateAudioVibrationSettings(
      config.enableAudioVibration,
      config.audioVibrationStrength,
      config.vibrationMode,
      config.audioVibrationSceneMode
    );
    if (config.enableAudioVibration) {
      console.info(`音频振动已启用, 强度=${config.audioVibrationStrength}, 模式=${config.vibrationMode}, 场景=${config.audioVibrationSceneMode}`);
    }
  }

  // ---------------------------------------------------------------------------
  // 内部 — Native 初始化
  // ---------------------------------------------------------------------------

  private async initializeNative(): Promise<void> {
    console.info('初始化 Native 模块');
    // Capture the registration generation in each callback closure. Reading the
    // mutable member here would let an old closure observe the next session's
    // generation and accept a delayed HDR notification.
    const generation = ++StreamingSession.callbackGeneration;

    const callbacks: StreamCallbacks = {
      drSetup: (videoFormat: number, width: number, height: number, redrawRate: number): void => {
        const actualCodec = StreamingSession.detectCodec(videoFormat);
        const actualHdr = (videoFormat & VIDEO_FORMAT_MASK_10BIT) !== 0;
        console.info(`视频设置: format=0x${videoFormat.toString(16)}, ${width}x${height}@${redrawRate}, ` +
          `codec=${actualCodec}, HDR=${actualHdr}`);

        if (this.config && this.config.hdr !== actualHdr) {
          console.info(`HDR 状态更新: ${this.config.hdr} -> ${actualHdr}`);
          this.config.hdr = actualHdr;
        }
        if (this.codecStateCallback) this.codecStateCallback(actualCodec);
        if (this.hdrStateCallback) this.hdrStateCallback(actualHdr);
      },
      drStart: (): void => {
        console.info('视频解码器启动');
        // 隔离外部回调异常，避免冒泡进 native 回调链导致连接流程不稳定
        if (this.decoderStartedCallback) {
          try {
            this.decoderStartedCallback();
          } catch (err) {
            console.error(`[StreamingSession] decoderStartedCallback 执行失败: ${err}`);
          }
        }
      },
      drStop: (): void => { console.info('视频解码器停止'); },
      drCleanup: (): void => { console.info('视频解码器清理'); },
      arInit: (audioConfiguration: number, sampleRate: number, samplesPerFrame: number): void => {
        console.info(`音频初始化: config=${audioConfiguration}, rate=${sampleRate}, samples=${samplesPerFrame}`);
      },
      arStart: (): void => { console.info('音频渲染器启动'); },
      arStop: (): void => {
        console.info('音频渲染器停止');
        this.audioVibrationService.stop();
      },
      arCleanup: (): void => {
        console.info('音频渲染器清理');
        this.audioVibrationService.stop();
      },
      stageStarting: (stage: number): void => {
        const name = STAGE_NAMES[stage] || `阶段 ${stage}`;
        console.info(`连接阶段开始: ${stage} (${name})`);
        if (this.stageProgressCallback) this.stageProgressCallback(stage, name);
      },
      stageComplete: (stage: number): void => { console.info(`连接阶段完成: ${stage}`); },
      stageFailed: (stage: number, errorCode: number): void => {
        const name = STAGE_NAMES[stage] || `阶段 ${stage}`;
        this.lastFailedStage = stage;
        console.error(`连接阶段失败: stage=${stage} (${name}), error=${errorCode}`);
      },
      connectionStarted: (): void => {
        console.info('连接已建立');
        this.isRunning = true;
        this.readHostFeatureFlags();
        if (this.lastMeasuredSdrNits > 0) {
          this.sendDynamicSdrWhite(this.lastMeasuredSdrNits);
        } else {
          this.scheduleBrightnessResample(0);
        }
        if (this.ds5TouchpadEnabled) {
          const supported = this.isControllerTouchpadSupported();
          console.info(`DS5 屏幕触控板: 主机 controller-touch=${supported}`);
        }
        this.startMicrophoneIfNeeded();
      },
      connectionTerminated: (errorCode: number): void => {
        console.info(`连接已终止: ${errorCode}, userInitiated=${this.userInitiatedStop}`);
        this.isRunning = false;
        this.stopBrightnessUpdates();
        this.hostFeatureFlags = 0;
        this.hostFeatureFlagsKnown = false;
        NetworkBoostService.getInstance().stop();
        GamepadManager.getInstance().stopAllSensors();
        // 立即停止所有振动（设备马达 + USB 手柄马达 + 音频振动）
        GamepadManager.getInstance().stopAllVibration();
        this.audioVibrationService.stop();
        this.stopMicrophone();
        // 用户主动停止时不触发外部回调（避免弹出“连接已断开”提示）
        if (!this.userInitiatedStop && this.connectionTerminatedCallback) {
          this.connectionTerminatedCallback(errorCode);
        }
      },
      connectionStatusUpdate: (status: number): void => {
        console.info(`连接状态更新: ${status}`);
        // 反馈给系统 Network Boost Kit，触发网络加速调度
        NetworkBoostService.getInstance().reportConnectionStatus(status === 1 /* CONN_STATUS_POOR */);
        if (this.connectionStatusCallback) {
          this.connectionStatusCallback(status);
        }
      },
      clipboardData: (kind: number, token: number, payload: Uint8Array): void => {
        ClipboardNativeBridge.onClipboardDataReceived(kind, token, payload);
      },
      setHdrMode: (enabled: boolean, hasMetadata: boolean, maxDisplayLuminance: number,
        minDisplayLuminance: number, maxContentLightLevel: number, maxFrameAverageLightLevel: number,
        maxFullFrameLuminance: number): void => {
        // setHdrMode 与 connectionTerminated 分属不同 TSFN,无跨队列顺序保证:
        // 丢弃旧代次注册或已终止会话的迟到回调(启动窗口靠 isStartingConnection 放行)
        if (generation !== StreamingSession.callbackGeneration) return;
        if (!this.isRunning && !this.isStartingConnection) return;
        const metadata: HostHdrMetadata | null = hasMetadata ? {
          maxDisplayLuminance,
          minDisplayLuminance,
          maxContentLightLevel,
          maxFrameAverageLightLevel,
          maxFullFrameLuminance
        } : null;
        console.info(`HDR 模式变化通知: ${enabled}` +
          (metadata ? `, hostMaxLum=${metadata.maxDisplayLuminance}, hostFullFrame=${metadata.maxFullFrameLuminance}` : ''));
        this.lastHostHdrMetadata = metadata;
        if (this.config && this.config.hdr !== enabled) {
          this.config.hdr = enabled;
        }
        if (this.hdrStateCallback) this.hdrStateCallback(enabled);
      },
      rumble: (cn: number, low: number, high: number): void => {
        // Rumble callbacks are queued asynchronously and may outlive the
        // connection that produced them. Do not let a late packet restart
        // feedback after connectionTerminated has already cleared it.
        if (!this.isRunning) return;
        GamepadManager.getInstance().handleRumble(cn, low, high);
      },
      ds5HapticsIrV2: (frame: Ds5HapticsIrV2Frame): void => {
        // IR callbacks use a separate TSFN and may arrive after termination;
        // never let stale work restart a stopped session's vibration source.
        if (!this.isRunning) return;
        GamepadManager.getInstance().handleDs5HapticsIrV2(frame);
      },
      setAdaptiveTriggers: (frame: AdaptiveTriggersFrame): void => {
        // This callback owns a separate TSFN and may already be queued when the
        // session ends. Never apply stale trigger state to the next session.
        if (!this.isRunning) return;
        GamepadManager.getInstance().handleAdaptiveTriggers(frame);
      },
      rumbleTriggers: (cn: number, lt: number, rt: number): void => {
        if (!this.isRunning) return;
        GamepadManager.getInstance().handleRumbleTriggers(cn, lt, rt);
      },
      setMotionEventState: (cn: number, motionType: number, rateHz: number): void => {
        console.info(`传感器状态: controller=${cn}, type=${motionType}, rate=${rateHz}`);
        GamepadManager.getInstance().handleSetMotionEventState(cn, motionType, rateHz);
      },
      setControllerLED: (cn: number, r: number, g: number, b: number): void => {
        console.info(`LED: controller=${cn}, rgb=(${r},${g},${b})`);
      },
      resolutionChanged: (width: number, height: number): void => {
        console.info(`分辨率变化: ${width}x${height}`);
        if (this.resolutionChangedCallback) this.resolutionChangedCallback(width, height);
      },
      audioHapticFrame: (frame: AudioHapticFrame): void => {
        this.audioVibrationService.handleHapticFrame(frame);
      }
    };

    // 设置传感器数据回调
    GamepadManager.getInstance().setSensorDataCallback(
      (cn: number, motionType: number, x: number, y: number, z: number): void => {
        if (this.isRunning) this.nativeModule.sendControllerMotionEvent(cn, motionType, x, y, z);
      }
    );

    // USB DS5 物理触摸板原生触点转发（主机需宣告 controller-touch 扩展）
    GamepadManager.getInstance().setControllerTouchCallback(
      (cn: number, eventType: number, pointerId: number, x: number, y: number, pressure: number): void => {
        if (!this.isRunning || !this.isControllerTouchpadSupported()) return;
        this.nativeModule.sendControllerTouchEvent(cn, eventType, pointerId, x, y, pressure);
      }
    );

    // USB DS5 电池状态转发
    GamepadManager.getInstance().setControllerBatteryCallback(
      (cn: number, batteryState: number, batteryPercentage: number): void => {
        if (this.isRunning) {
          this.nativeModule.sendControllerBatteryEvent(cn, batteryState, batteryPercentage);
        }
      }
    );

    this.nativeModule.init(callbacks);
  }

  // ---------------------------------------------------------------------------
  // 内部 — 视频 Surface
  // ---------------------------------------------------------------------------

  private async setupVideoSurface(): Promise<void> {
    console.info(`设置视频 Surface: ${this.surfaceId}`);
    if (!this.nativeModule.setVideoSurface(this.surfaceId)) {
      throw new Error('设置视频 Surface 失败');
    }
  }

  // ---------------------------------------------------------------------------
  // 内部 — 应用启动
  // ---------------------------------------------------------------------------

  private async launchApp(cachedCurrentGame: number = 0): Promise<void> {
    if (!this.nvHttp || !this.config || !this.riKey) {
      throw new Error('启动应用前提条件不满足');
    }

    console.info(`启动应用: appId=${this.appId}`);

    const riKeyHex = Array.from(new Uint8Array(this.riKey))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    // 检查并调整 HDR 支持
    let effectiveHdr = this.config.hdr;
    if (effectiveHdr) {
      try {
        const caps = StreamingSession.getDecoderCapabilities();
        if (!caps.supportsHEVC && !caps.supportsAV1) {
          console.warn('设备不支持 HEVC/AV1，自动禁用 HDR');
          effectiveHdr = false;
        }
      } catch {
        console.warn('获取解码器能力失败，禁用 HDR');
        effectiveHdr = false;
      }
    }
    if (this.config.hdr !== effectiveHdr) {
      console.info(`HDR 状态已调整: ${this.config.hdr} -> ${effectiveHdr}`);
      this.config.hdr = effectiveHdr;
    }

    const brightnessRange = await this.resolveBrightnessRange(effectiveHdr);

    this.stats.hdrMode = effectiveHdr ? this.config.hdrMode : 0;
    this.stats.hdrBrightnessSource = effectiveHdr ? this.brightnessSource : 'static';
    this.stats.hdrBrightnessOverride = effectiveHdr && this.config.hdrBrightnessOverride;
    this.stats.measuredSdrNits = this.lastMeasuredSdrNits;
    this.stats.measuredPeakNits = this.lastMeasuredPeakNits;
    this.stats.measuredFullFrameNits = this.lastMeasuredFullFrameNits;
    this.stats.sentSdrWhiteNits = this.lastMeasuredSdrNits;
    this.stats.sentPeakNits = effectiveHdr ? brightnessRange[1] : 0;
    this.stats.sentFullFrameNits = effectiveHdr ? brightnessRange[2] : 0;

    const launchConfig: LaunchConfig = {
      appId: this.appId,
      width: this.config.width,
      height: this.config.height,
      fps: this.config.fps,
      bitrate: this.config.bitrate,
      sops: this.config.sops,
      localAudio: this.config.playLocalAudio,
      riKey: riKeyHex,
      riKeyId: this.riKeyId,
      audioConfig: getSurroundAudioInfo(this.config.audioConfig).toString(),
      enableHdr: effectiveHdr,
      hdrMode: effectiveHdr ? this.config.hdrMode : HdrMode.SDR,
      displayGuid: this.displayGuid,
      minBrightness: brightnessRange[0],
      maxBrightness: brightnessRange[1],
      maxAverageBrightness: brightnessRange[2],
      sdrBrightness: this.lastMeasuredSdrNits > 0 ? this.lastMeasuredSdrNits : undefined,
      screenCombinationMode: this.config.screenCombinationMode,
    };

    try {
      if (cachedCurrentGame !== 0) {
        if (cachedCurrentGame === this.appId) {
          console.info('同一应用正在运行，尝试恢复会话...');
          try {
            this.rtspSessionUrl = await this.nvHttp.resumeApp(launchConfig);
            console.info(`恢复会话成功, sessionUrl=${this.rtspSessionUrl}`);
            return;
          } catch (resumeErr) {
            console.warn(`恢复失败: ${(resumeErr as Error).message}，尝试重新启动...`);
          }
        }

        console.info('正在退出当前运行的应用...');
        if (!(await this.nvHttp.quitApp())) {
          throw new Error('无法退出当前运行的应用，请在 PC 上手动退出');
        }
      }

      this.rtspSessionUrl = await this.nvHttp.launchApp(this.appId, launchConfig);
      console.info(`应用启动成功, sessionUrl=${this.rtspSessionUrl}`);
    } catch (err) {
      throw new Error(`启动应用失败: ${(err as Error).message}`);
    }
  }

  // ---------------------------------------------------------------------------
  // 内部 — 服务器连接
  // ---------------------------------------------------------------------------

  private async connectToServer(): Promise<void> {
    if (!this.config || !this.computer || !this.riKey) {
      throw new Error('配置未设置');
    }

    // 构建 supportedVideoFormats
    let supportedVideoFormats = 0x0001; // H.264
    let actualCodec: 'H.264' | 'HEVC' = this.config.codec;

    try {
      const caps = StreamingSession.getDecoderCapabilities();
      console.info(`解码器: H264=${caps.supportsH264}, HEVC=${caps.supportsHEVC}, AV1=${caps.supportsAV1}, ` +
        `max=${caps.maxWidth}x${caps.maxHeight}@${caps.maxFps}`);

      if (caps.supportsHEVC) {
        supportedVideoFormats |= 0x0100;
        if (this.config.hdr) supportedVideoFormats |= 0x0200;
      }
      if (caps.supportsAV1) {
        supportedVideoFormats |= 0x1000;
        if (this.config.hdr) supportedVideoFormats |= 0x2000;
      }
      if (this.config.codec === 'HEVC' && !caps.supportsHEVC) {
        console.warn('设备不支持 HEVC，降级到 H.264');
        actualCodec = 'H.264';
      }
    } catch (err) {
      console.warn(`获取解码器能力失败: ${(err as Error).message}`);
      actualCodec = 'H.264';
      supportedVideoFormats = 0x0001;
    }

    console.info(`编解码器: ${actualCodec}, formats=0x${supportedVideoFormats.toString(16)}`);

    // 生成 IV: 前4字节 = riKeyId (big-endian), 后12字节 = 0
    const riAesIv = new ArrayBuffer(16);
    new DataView(riAesIv).setUint32(0, this.riKeyId, false);

    // 应用解码器设置
    this.nativeModule.setDecoderBufferCount(this.config.decoderBufferCount);
    this.nativeModule.setDecoderSyncMode(this.config.enableSyncDecode);
    this.nativeModule.setVsyncEnabled(this.config.enableVsync);
    this.nativeModule.setHostPacedPresentationEnabled(
      this.config.enableHostPacedPresentation ?? true);
    this.nativeModule.setVrrEnabled(this.config.enableVrr);
    this.nativeModule.setPostProcessEnabled(this.config.enablePostProcess ?? false);
    this.nativeModule.setUpscaleMode(this.config.upscaleMode ?? 0, this.config.upscaleSharpness ?? 0.5);
    try {
      this.nativeModule.setSdrToHdr(this.config.sdrToHdr ?? false, this.config.sdrToHdrPeakNits ?? 500, this.config.sdrToHdrSaturation ?? 1.3, this.config.sdrToHdrContrast ?? 1.0);
    } catch (e) {
      console.error(`SDR→HDR: call FAILED: ${e}`);
    }

    console.info(`解码器: buffers=${this.config.decoderBufferCount}, sync=${this.config.enableSyncDecode}, ` +
      `vsync=${this.config.enableVsync}, hostPaced=${this.config.enableHostPacedPresentation ?? true}, ` +
      `vrr=${this.config.enableVrr}`);

    const callStart = async (address: string): Promise<number> => {
      this.isStartingConnection = true;
      this.lastFailedStage = 0;
      try {
        console.info(`StreamingSession: native connection address=${address}`);
        const pendingStart: Promise<number> = this.nativeModule.startConnectionAsync(
          address,
          this.serverAppVersion,
          this.serverGfeVersion,
          this.rtspSessionUrl,
          this.serverCodecModeSupport,
          this.config!.width, this.config!.height, this.config!.fps,
          this.config!.bitrate,
          1392, // packetSize (will be capped by moonlight-common-c for remote)
          2,    // streamingRemotely: STREAM_CFG_AUTO - let moonlight-common-c auto-detect
          this.config!.audioConfig,
          supportedVideoFormats,
          this.config!.clientRefreshRateX100,
          this.riKey!, riAesIv,
          0x01 | 0x02, // videoCapabilities: DIRECT_SUBMIT | RFI_AVC
          this.config!.hdr ? 2 : 1, // colorSpace: REC_2020 / REC_709
          this.config!.colorRange,
          this.config!.hdr ? this.config!.hdrMode : HdrMode.SDR,
          this.config!.microphoneEnabled,
          this.config!.controlOnly
        );
        this.connectionStartPromise = pendingStart;
        return await pendingStart;
      } finally {
        this.isStartingConnection = false;
        this.connectionStartPromise = null;
      }
    };

    let activeConnectionAddress = this.connectionAddress;
    let result = await callStart(activeConnectionAddress);

    // getaddrinfo() may fail after /launch succeeds when the selected hostname
    // is stale or temporarily unavailable. In that specific stage, retry with
    // the concrete host Sunshine just advertised in sessionUrl0. Do not use
    // this address unconditionally: behind IPv4 NAT, sessionUrl0 may contain a
    // private host while the selected WAN address is the correct route.
    const rtspSessionHost = parseRtspSessionHost(this.rtspSessionUrl);
    if (result === -2 &&
        this.lastFailedStage === STAGE_NAME_RESOLUTION &&
        rtspSessionHost &&
        rtspSessionHost !== activeConnectionAddress) {
      if (this.userInitiatedStop) {
        return;
      }
      console.warn(`StreamingSession: 名称解析失败，改用 sessionUrl0 主机 ${rtspSessionHost} 重试`);
      this.nativeModule.stopConnection();
      activeConnectionAddress = rtspSessionHost;
      result = await callStart(activeConnectionAddress);
      if (result === 0) {
        console.info('StreamingSession: sessionUrl0 主机回退成功');
      }
    }

    // RTSP/ENet 瞬态错误自动重试 1 次：errno 4=EINTR、110=ETIMEDOUT、104=ECONNRESET、32=EPIPE
    // 这类错误通常是 ENet service 循环被打断或网络抖动，host 端不需要重新 launchApp，
    // 只需 stopConnection 释放 native 资源后等待短暂窗口再重试即可恢复。
    const TRANSIENT_ERRORS = [4, 32, 104, 110];
    if (result !== 0 && TRANSIENT_ERRORS.includes(result)) {
      // 瞬态错误后立即检查是否已被用户取消
      if (this.userInitiatedStop) {
        return;
      }
      console.warn(`StreamingSession: startConnection 返回瞬态错误 ${result}，1.5s 后重试一次`);
      if (!this.userInitiatedStop) {
        this.nativeModule.stopConnection();
      }
      await new Promise<void>(resolve => setTimeout(resolve, 1500));
      // 重试前再次检查是否已被用户取消
      if (this.userInitiatedStop) {
        return;
      }
      result = await callStart(activeConnectionAddress);
      if (result === 0) {
        console.info('StreamingSession: 重试成功');
      }
    }

    if (this.userInitiatedStop) {
      return;
    }

    if (result !== 0) {
      throw new Error(`连接失败，错误码: ${result}`);
    }
  }

  // ---------------------------------------------------------------------------
  // 内部 — 手柄输入处理
  // ---------------------------------------------------------------------------

  private handleControllerButton(event: ControllerButtonEvent): void {
    const buttonValue = event.button as number;
    if (event.isPressed) {
      this.controllerState.buttonFlags |= buttonValue;
    } else {
      this.controllerState.buttonFlags &= ~buttonValue;
    }
    this.sendControllerState(event.controllerIndex);
  }

  private handleControllerAxis(event: ControllerAxisEvent): void {
    switch (event.axis) {
      case 0: this.controllerState.leftStickX = event.value; break;
      case 1: this.controllerState.leftStickY = event.value; break;
      case 2: this.controllerState.rightStickX = event.value; break;
      case 3: this.controllerState.rightStickY = event.value; break;
      case 4:
        this.controllerState.leftTrigger = StreamingSession.normalizeTrigger(event.value);
        break;
      case 5:
        this.controllerState.rightTrigger = StreamingSession.normalizeTrigger(event.value);
        break;
    }
    this.sendControllerState(event.controllerIndex);
  }

  private sendControllerState(controllerIndex: number): void {
    this.ensureVirtualControllerArrival(controllerIndex);
    const s = this.controllerState;
    this.controllerStates.set(controllerIndex, this.cloneControllerState(s));
    this.sendControllerStateSnapshot(controllerIndex, s);
  }

  private ensureVirtualControllerArrival(controllerIndex: number): void {
    // A screen touchpad augments the primary physical controller. Reuse its
    // slot instead of sending a duplicate arrival packet for controller 0.
    if (this.virtualControllerArrived || this.physicalControllerArrived.has(controllerIndex)) return;

    this.activeGamepadMask |= (1 << controllerIndex);
    const touchpadEnabled = this.ds5TouchpadEnabled;
    const supportedButtons = touchpadEnabled
      ? STANDARD_BUTTON_FLAGS | TOUCHPAD_FLAG
      : STANDARD_BUTTON_FLAGS;
    const controllerType = touchpadEnabled ? CONTROLLER_TYPE_PS : CONTROLLER_TYPE_XBOX;
    const capabilities = LI_CCAP_ANALOG_TRIGGERS | LI_CCAP_RUMBLE |
      (touchpadEnabled ? LI_CCAP_TOUCHPAD : 0);
    const ret = this.nativeModule.sendControllerArrivalEvent(
      controllerIndex, this.activeGamepadMask,
      controllerType, supportedButtons, capabilities
    );

    if (ret >= 0) {
      this.virtualControllerArrived = true;
      console.info(`[VirtualCtrl] arrival sent, index=${controllerIndex}, mask=0x${this.activeGamepadMask.toString(16)}`);
    } else {
      console.warn(`[VirtualCtrl] arrival failed (ret=${ret}), will retry`);
    }
  }

  private ensurePhysicalControllerArrival(controllerIndex: number, controllerType: number = CONTROLLER_TYPE_XBOX): void {
    if (this.physicalControllerArrived.has(controllerIndex)) return;

    // A virtual controller may have claimed slot 0 before the physical device
    // produced its first input. Treat the first physical state as the same
    // logical controller and keep the already-advertised capability profile.
    if (this.virtualControllerArrived && controllerIndex === 0) {
      this.physicalControllerArrived.add(controllerIndex);
      this.physicalControllerTypes.set(controllerIndex, controllerType);
      console.info(`[Gamepad] reusing virtual arrival for physical slot ${controllerIndex}`);
      return;
    }

    let capabilities = LI_CCAP_ANALOG_TRIGGERS | LI_CCAP_RUMBLE;
    capabilities |= GamepadManager.getInstance().getSensorCapabilities(controllerIndex);
    // 物理触摸板/电池能力（USB DS5）；位值与 ControllerCapabilities 对齐
    const physicalCaps = GamepadManager.getInstance().getPhysicalControllerCapabilities(controllerIndex);
    const hasPhysicalTouchpad = (physicalCaps & LI_CCAP_TOUCHPAD) !== 0;
    if (hasPhysicalTouchpad || (this.ds5TouchpadEnabled && controllerIndex === 0)) {
      capabilities |= LI_CCAP_TOUCHPAD;
    }
    if ((physicalCaps & LI_CCAP_BATTERY_STATE) !== 0) {
      capabilities |= LI_CCAP_BATTERY_STATE;
    }

    let reportedType = controllerType;
    if (this.ds5TouchpadEnabled && controllerIndex === 0) {
      // A screen-provided touchpad is a PS-family capability. The host's
      // explicit DS5 mode still decides whether the slot is backed by DS5.
      reportedType = CONTROLLER_TYPE_PS;
    }
    if ((capabilities & (LI_CCAP_ACCEL | LI_CCAP_GYRO)) && reportedType !== CONTROLLER_TYPE_PS) {
      reportedType = CONTROLLER_TYPE_UNKNOWN;
    }

    this.activeGamepadMask |= (1 << controllerIndex);
    const ret = this.nativeModule.sendControllerArrivalEvent(
      controllerIndex, this.activeGamepadMask,
      reportedType,
      (hasPhysicalTouchpad || (this.ds5TouchpadEnabled && controllerIndex === 0))
        ? STANDARD_BUTTON_FLAGS | TOUCHPAD_FLAG
        : STANDARD_BUTTON_FLAGS,
      capabilities
    );

    if (ret >= 0) {
      this.physicalControllerArrived.add(controllerIndex);
      this.physicalControllerTypes.set(controllerIndex, controllerType);
      console.info(`[Gamepad] arrival: index=${controllerIndex}, type=${reportedType}(orig=${controllerType}), ` +
        `caps=0x${capabilities.toString(16)}, mask=0x${this.activeGamepadMask.toString(16)}`);
    }
  }

  private resetControllerState(): void {
    this.virtualControllerArrived = false;
    this.physicalControllerArrived.clear();
    this.physicalControllerTypes.clear();
    this.activeGamepadMask = 0;
    this.hostFeatureFlags = 0;
    this.hostFeatureFlagsKnown = false;
    this.ds5TouchpadButtonPressed = false;
    this.controllerStates.clear();
    this.controllerState.buttonFlags = 0;
    this.controllerState.leftTrigger = 0;
    this.controllerState.rightTrigger = 0;
    this.controllerState.leftStickX = 0;
    this.controllerState.leftStickY = 0;
    this.controllerState.rightStickX = 0;
    this.controllerState.rightStickY = 0;
  }

  private getControllerState(controllerIndex: number): ControllerState {
    const existing = this.controllerStates.get(controllerIndex);
    if (existing) return existing;
    const initial = this.cloneControllerState(this.controllerState);
    this.controllerStates.set(controllerIndex, initial);
    return initial;
  }

  private cloneControllerState(state: ControllerState): ControllerState {
    return {
      buttonFlags: state.buttonFlags,
      leftTrigger: state.leftTrigger,
      rightTrigger: state.rightTrigger,
      leftStickX: state.leftStickX,
      leftStickY: state.leftStickY,
      rightStickX: state.rightStickX,
      rightStickY: state.rightStickY
    };
  }

  private sendControllerStateSnapshot(controllerIndex: number, state: ControllerState): void {
    const buttonFlags = controllerIndex === 0 && this.ds5TouchpadEnabled && this.ds5TouchpadButtonPressed
      ? state.buttonFlags | TOUCHPAD_FLAG
      : state.buttonFlags;
    this.nativeModule.sendMultiControllerInput(
      controllerIndex, this.activeGamepadMask,
      buttonFlags, state.leftTrigger, state.rightTrigger,
      state.leftStickX, state.leftStickY, state.rightStickX, state.rightStickY
    );
  }

  /**
   * Rebuild slot 0 when the user changes the touchpad mode during a session.
   * Sunshine ignores duplicate arrival packets, so a real removal packet is
   * required before advertising the new capability profile.
   */
  private reannouncePrimaryController(physicalTypeOverride?: number): void {
    if (!this.isRunning) return;

    const hadPhysical = this.physicalControllerArrived.has(0);
    const hadSlot = hadPhysical || this.virtualControllerArrived || (this.activeGamepadMask & 1) !== 0;
    if (!hadSlot) return;

    const remainingMask = this.activeGamepadMask & ~1;
    this.nativeModule.sendMultiControllerInput(0, remainingMask, 0, 0, 0, 0, 0, 0, 0);
    this.activeGamepadMask = remainingMask;
    this.virtualControllerArrived = false;
    this.physicalControllerArrived.delete(0);

    if (hadPhysical) {
      const originalType = physicalTypeOverride ??
        this.physicalControllerTypes.get(0) ?? CONTROLLER_TYPE_XBOX;
      this.ensurePhysicalControllerArrival(0, originalType);
    } else {
      this.ensureVirtualControllerArrival(0);
    }
  }

  // ---------------------------------------------------------------------------
  // 内部 — 麦克风
  // ---------------------------------------------------------------------------

  private startMicrophoneIfNeeded(): void {
    if (!this.config?.microphoneEnabled) return;
    if (!MoonBridge.isMicrophoneRequested()) {
      console.info('主机未请求麦克风');
      return;
    }

    console.info('启动麦克风...');
    this.ensureMicPermissionAndStart();
  }

  /**
   * 检查/请求麦克风权限后启动
   */
  private async ensureMicPermissionAndStart(): Promise<void> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const bundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      const tokenId = bundleInfo.appInfo.accessTokenId;
      const permission: Permissions = 'ohos.permission.MICROPHONE';

      let granted = atManager.checkAccessTokenSync(tokenId, permission)
        === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;

      if (!granted && this.abilityContext) {
        console.info('请求麦克风权限...');
        const result = await atManager.requestPermissionsFromUser(
          this.abilityContext, [permission]
        );
        granted = result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      }

      if (!granted) {
        console.error('麦克风权限被拒绝');
        return;
      }

      this.microphoneStream = new MicrophoneStream(MoonBridge);
      const success = await this.microphoneStream.start();
      if (!success) {
        console.error('麦克风启动失败');
        this.microphoneStream = null;
      }
    } catch (error) {
      console.error(`麦克风启动异常: ${(error as Error).message}`);
      this.microphoneStream = null;
    }
  }

  private stopMicrophone(): void {
    if (!this.microphoneStream) return;
    console.info('停止麦克风...');
    this.microphoneStream.stop().catch((error: Error) => {
      console.warn(`停止麦克风出错: ${error.message}`);
    });
    this.microphoneStream = null;
  }

  async toggleMicrophone(): Promise<boolean> {
    if (!this.microphoneStream) return false;
    return this.microphoneStream.toggle();
  }

  isMicrophoneActive(): boolean {
    return this.microphoneStream?.isRunning() ?? false;
  }

  isMicrophoneEnabled(): boolean {
    return this.config?.microphoneEnabled ?? false;
  }

  hasMicrophoneStream(): boolean {
    return this.microphoneStream !== null;
  }

  // ---------------------------------------------------------------------------
  // 内部 — 清理
  // ---------------------------------------------------------------------------

  /** 注册亮度变化失效信号；不直接信任事件携带的瞬时值。 */
  private registerBrightnessProbe(): void {
    try {
      this.brightnessProbeHandler = (displayId: number, info: display.BrightnessInfo): void => {
        console.info(`[BrightnessProbe] display=${displayId}, sdrNits=${info.sdrNits}, ` +
          `currentHeadroom=${info.currentHeadroom}, maxHeadroom=${info.maxHeadroom}`);
        if (displayId === 0) {
          this.scheduleBrightnessResample(SDR_WHITE_DEBOUNCE_MS);
        }
      };
      display.on('brightnessInfoChange', this.brightnessProbeHandler);
    } catch (err) {
      this.brightnessProbeHandler = null;
      console.warn(`[BrightnessProbe] brightnessInfoChange 不可用: ${err}`);
    }
  }

  private isDynamicSdrWhiteSupported(): boolean {
    return this.isRunning && this.config?.hdr === true && this.config.hdrMode === HdrMode.HLG &&
      (this.hostFeatureFlags & LI_FF_DYNAMIC_SDR_WHITE) !== 0;
  }

  private sendDynamicSdrWhite(nits: number): void {
    if (!this.isDynamicSdrWhiteSupported() || !Number.isFinite(nits) ||
      nits < SDR_WHITE_MIN_NITS || nits > SDR_WHITE_MAX_NITS) return;
    if (this.lastSentSdrWhiteNits > 0) {
      const threshold = Math.max(SDR_WHITE_MIN_DELTA_NITS,
        this.lastSentSdrWhiteNits * SDR_WHITE_MIN_DELTA_RATIO);
      if (Math.abs(nits - this.lastSentSdrWhiteNits) < threshold) return;
    }

    const result = this.nativeModule.sendClientSdrWhiteNits(nits);
    if (result === 0) {
      this.lastSentSdrWhiteNits = nits;
      this.lastMeasuredSdrNits = nits;
      console.info(`[Brightness] 动态 SDR white 已更新: ${nits} nits`);
    } else {
      console.warn(`[Brightness] 动态 SDR white 发送失败: nits=${nits}, error=${result}`);
    }
  }

  private scheduleBrightnessResample(delayMs: number): void {
    if (!this.isDynamicSdrWhiteSupported()) return;
    if (this.brightnessSampleInFlight) {
      this.brightnessSamplePending = true;
      return;
    }
    if (this.brightnessUpdateTimer >= 0) {
      clearTimeout(this.brightnessUpdateTimer);
    }
    const generation = this.brightnessUpdateGeneration;
    this.brightnessUpdateTimer = setTimeout(() => {
      this.brightnessUpdateTimer = -1;
      this.resampleAndSendSdrWhite(generation);
    }, delayMs);
  }

  private async resampleAndSendSdrWhite(generation: number): Promise<void> {
    if (generation !== this.brightnessUpdateGeneration || !this.isDynamicSdrWhiteSupported()) return;
    this.brightnessSampleInFlight = true;
    try {
      const measured = await sampleDisplayBrightness(0);
      if (generation === this.brightnessUpdateGeneration && measured && this.isDynamicSdrWhiteSupported()) {
        this.sendDynamicSdrWhite(measured.sdrNits);
      }
    } catch (err) {
      console.warn(`[Brightness] 动态重采样失败: ${err}`);
    } finally {
      if (generation !== this.brightnessUpdateGeneration) return;
      this.brightnessSampleInFlight = false;
      if (this.brightnessSamplePending) {
        this.brightnessSamplePending = false;
        this.scheduleBrightnessResample(SDR_WHITE_DEBOUNCE_MS);
      }
    }
  }

  private stopBrightnessUpdates(): void {
    this.brightnessUpdateGeneration++;
    if (this.brightnessUpdateTimer >= 0) {
      clearTimeout(this.brightnessUpdateTimer);
      this.brightnessUpdateTimer = -1;
    }
    this.brightnessSamplePending = false;
    this.brightnessSampleInFlight = false;
    this.unregisterBrightnessProbe();
  }

  private unregisterBrightnessProbe(): void {
    if (this.brightnessProbeHandler) {
      try {
        display.off('brightnessInfoChange', this.brightnessProbeHandler);
      } catch (_) { /* ignore */ }
      this.brightnessProbeHandler = null;
    }
  }

  private async cleanup(): Promise<void> {
    console.info('清理串流资源');
    this.isRunning = false;
    this.stopBrightnessUpdates();
    // LiStopConnection() suppresses connectionTerminated for an explicit stop,
    // so clear controller output here as well as in the termination callback.
    GamepadManager.getInstance().stopAllVibration();
    this.stopMicrophone();
    await this.stopAbr();
    this.nativeModule.setPerformanceModeEnabled(false);
    try {
      if (this.isStartingConnection) {
        const pendingStart = this.connectionStartPromise;
        if (pendingStart !== null) {
          this.nativeModule.interruptConnection();
          try {
            await pendingStart;
          } catch (err) {
            console.warn(`等待启动中断完成失败: ${err}`);
          }
        }
      }
      this.nativeModule.stopConnection();
      this.nativeModule.releaseVideoSurface();
    } catch (err) {
      console.error('清理资源失败:', err);
    }
  }

  // ---------------------------------------------------------------------------
  // 内部 — 工具方法
  // ---------------------------------------------------------------------------

  /**
   * 根据 videoFormat 位掩码检测编解码器名称
   */
  private static detectCodec(videoFormat: number): string {
    if ((videoFormat & VIDEO_FORMAT_MASK_AV1) !== 0) return 'AV1';
    if ((videoFormat & VIDEO_FORMAT_MASK_H265) !== 0) return 'HEVC';
    if ((videoFormat & VIDEO_FORMAT_MASK_H264) !== 0) return 'H.264';
    return 'HEVC';
  }

  /**
   * 归一化扳机值到 0~255
   * 虚拟手柄: 0~255, 物理手柄: -32768~32767
   */
  private static normalizeTrigger(value: number): number {
    if (value >= 0 && value <= 255) return value;
    return Math.floor((value + 32768) / 256);
  }

  /**
   * 获取键码对应的修饰键掩码
   */
  private static getModifierForKey(key: number): number {
    switch (key) {
      case VK_SHIFT: return MODIFIER_SHIFT;
      case VK_CONTROL: return MODIFIER_CTRL;
      case VK_MENU: return MODIFIER_ALT;
      case VK_LWIN: return MODIFIER_META;
      default: return 0;
    }
  }
}
