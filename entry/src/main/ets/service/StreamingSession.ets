/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { StreamConfig, HdrMode, getSurroundAudioInfo } from '../model/StreamConfig';
import { InputEvent, InputType, ControllerButtonEvent, ControllerAxisEvent, ControllerButton } from '../model/InputEvent';
import { ComputerManager } from './ComputerManager';
import { ComputerInfo, selectBestAddress } from '../model/ComputerInfo';
import { NvHttp, LaunchConfig } from './NvHttp';
import { CryptoUtil } from '../utils/CryptoUtil';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { GamepadManager } from './GamepadManager';
import { MoonlightButton } from './GamepadTypes';
import { MicrophoneStream } from './microphone/MicrophoneStream';
import { AudioVibrationService } from './AudioVibrationService';
import {
  MoonBridge,
  CONTROLLER_TYPE_UNKNOWN,
  CONTROLLER_TYPE_XBOX,
  CONTROLLER_TYPE_PS,
  LI_CCAP_ANALOG_TRIGGERS,
  LI_CCAP_RUMBLE,
  LI_CCAP_ACCEL,
  LI_CCAP_GYRO
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
  renderedFps: number;     // 渲染帧率 (Rd)
  bitrate: number;         // Kbps
  latency: number;         // 解码延迟 ms (EMA 瞬时值)
  hostLatency: number;     // 主机处理延迟（编码时间）ms
  networkLatency: number;  // 网络延迟（RTT）ms
  packetLoss: number;      // %
  decodedFrames: number;
  droppedFrames: number;
  globalAvgDecodeLatency: number;  // 全局平均解码延迟 ms
  globalAvgHostLatency: number;    // 全局平均主机延迟 ms
  globalAvgFps: number;            // 全局平均帧率
  // 分级丢帧统计
  droppedByL1: number;     // L1: sync drain-to-latest
  droppedByL2: number;     // L2: async 延迟过高跳帧
  droppedByL3: number;     // L3: 临界延迟 IDR 恢复
  droppedByL4: number;     // L4: 网络突发检测
  droppedByL5: number;     // L5: async 渲染跳帧
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
  setVrrEnabled(enabled: boolean): void;
  setSpatialAudioEnabled(enabled: boolean): void;
  isSpatialAudioEnabled(): boolean;
  setAudioVolume(volume: number): boolean;
  setPerformanceModeEnabled(enabled: boolean): void;
  getPerformanceModeEnabled(): boolean;
  setBassVibrationConfig(enabled: boolean, sensitivity: number, sceneMode?: number): void;
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
  sendControllerMotionEvent(
    controllerNumber: number, motionType: number, x: number, y: number, z: number
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
  setHdrMode?: (enabled: boolean) => void;
  rumble?: (controllerNumber: number, lowFreqMotor: number, highFreqMotor: number) => void;
  rumbleTriggers?: (controllerNumber: number, leftTrigger: number, rightTrigger: number) => void;
  setMotionEventState?: (controllerNumber: number, motionType: number, reportRateHz: number) => void;
  setControllerLED?: (controllerNumber: number, r: number, g: number, b: number) => void;
  resolutionChanged?: (width: number, height: number) => void;
  bassEnergy?: (intensity: number) => void;
}

interface VideoStats {
  framesDecoded: number;
  framesDropped: number;
  avgDecodeTimeMs: number;
  fps: number;
  renderedFps: number;
  bitrate: number;
  hostLatency: number;
  totalDecodeTimeMs: number;
  validDecodeFrames: number;
  totalHostLatencyMs: number;
  framesWithHostLatency: number;
  globalAvgFps: number;
  // 分级丢帧统计
  droppedByL1: number;
  droppedByL2: number;
  droppedByL3: number;
  droppedByL4: number;
  droppedByL5: number;
  droppedByQueueOverflow: number;
  droppedByTimeout: number;
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

/** 键盘动作常量 */
const KEY_DOWN = 0x03;
const KEY_UP = 0x04;

/** 修饰键虚拟键码 */
const VK_SHIFT = 0x10;
const VK_CONTROL = 0x11;
const VK_MENU = 0x12;
const VK_LWIN = 0x5B;

/** 修饰键掩码 */
const MODIFIER_SHIFT = 0x01;
const MODIFIER_CTRL = 0x02;
const MODIFIER_ALT = 0x04;
const MODIFIER_META = 0x08;

/** 标准 Xbox 手柄支持的按钮集合 */
const STANDARD_BUTTON_FLAGS =
  MoonlightButton.A | MoonlightButton.B | MoonlightButton.X | MoonlightButton.Y |
  MoonlightButton.UP | MoonlightButton.DOWN | MoonlightButton.LEFT | MoonlightButton.RIGHT |
  MoonlightButton.LB | MoonlightButton.RB |
  MoonlightButton.LS | MoonlightButton.RS |
  MoonlightButton.START | MoonlightButton.BACK | MoonlightButton.SPECIAL;

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
export class StreamingSession {

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
   * 获取设备屏幕亮度范围（用于服务端 HDR tone mapping）
   * @returns [minBrightness, maxBrightness, maxAverageBrightness] (nits)
   */
  private static getBrightnessRange(): number[] {
    let minBrightness = 2;
    let maxBrightness = 500;
    let maxAverageBrightness = 200;

    try {
      const brightnessInfo = display.getBrightnessInfo(0);
      console.info(`[Brightness] sdrNits=${brightnessInfo.sdrNits}, ` +
        `currentHeadroom=${brightnessInfo.currentHeadroom}, maxHeadroom=${brightnessInfo.maxHeadroom}`);

      if (brightnessInfo.sdrNits > 0) {
        maxBrightness = brightnessInfo.sdrNits * brightnessInfo.maxHeadroom;
        maxAverageBrightness = brightnessInfo.sdrNits;
      }
    } catch (err) {
      console.warn(`[Brightness] getBrightnessInfo 不可用，使用默认值: ${err}`);
    }

    console.info(`[Brightness] min=${minBrightness}, max=${maxBrightness}, avg=${maxAverageBrightness} nits`);
    return [minBrightness, maxBrightness, maxAverageBrightness];
  }

  // ---------------------------------------------------------------------------
  // 成员变量 — 连接与配置
  // ---------------------------------------------------------------------------

  private nativeModule: NativeModule;
  private computerId: string = '';
  private appId: number = 0;
  private config: StreamConfig | null = null;
  private surfaceId: string = '';
  private isRunning: boolean = false;
  /** 用户主动发起的停止（菜单断开/退出游戏），抑制 connectionTerminated 回调弹窗 */
  private userInitiatedStop: boolean = false;
  private computer: ComputerInfo | null = null;
  private nvHttp: NvHttp | null = null;
  private riKey: ArrayBuffer | null = null;
  private riKeyId: number = 0;
  private displayGuid: string = '';
  private useVdd: boolean = false;

  // 服务器信息
  private serverAppVersion: string = '';
  private serverGfeVersion: string = '';
  private serverCodecModeSupport: number = 0;
  private rtspSessionUrl: string = '';

  // ---------------------------------------------------------------------------
  // 成员变量 — 回调
  // ---------------------------------------------------------------------------

  private hdrStateCallback: HdrStateCallback | null = null;
  private codecStateCallback: CodecStateCallback | null = null;
  private connectionTerminatedCallback: ((errorCode: number) => void) | null = null;
  private resolutionChangedCallback: ResolutionChangedCallback | null = null;
  private stageProgressCallback: ((stage: number, stageName: string) => void) | null = null;

  // ---------------------------------------------------------------------------
  // 成员变量 — 手柄状态
  // ---------------------------------------------------------------------------

  private virtualControllerArrived: boolean = false;
  private physicalControllerArrived = new Set<number>();
  private activeGamepadMask: number = 0;
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
    fps: 0, renderedFps: 0, bitrate: 0, latency: 0,
    hostLatency: 0, networkLatency: 0, packetLoss: 0,
    decodedFrames: 0, droppedFrames: 0,
    globalAvgDecodeLatency: 0, globalAvgHostLatency: 0, globalAvgFps: 0,
    droppedByL1: 0, droppedByL2: 0, droppedByL3: 0, droppedByL4: 0, droppedByL5: 0
  };
  private lastValidStats: StreamStats | null = null;

  // ---------------------------------------------------------------------------
  // 成员变量 — 音频与麦克风
  // ---------------------------------------------------------------------------

  private audioVibrationService: AudioVibrationService = new AudioVibrationService();
  private microphoneStream: MicrophoneStream | null = null;

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
    this.surfaceId = surfaceId;
    this.displayGuid = displayGuid || '';
    this.useVdd = useVdd || false;

    console.info(`开始串流: computer=${computerId}, app=${appId}`);
    console.info(`配置: ${config.width}x${config.height}@${config.fps}fps, ${config.bitrate}kbps, ${config.codec}`);
    console.info(`HDR: hdr=${config.hdr}, hdrMode=${config.hdrMode}, colorRange=${config.colorRange}`);
    if (this.displayGuid || this.useVdd) {
      console.info(`显示器: displayGuid=${this.displayGuid}, useVdd=${this.useVdd}`);
    }

    try {
      await this.resolveComputer(computerId, context);
      await this.fetchServerInfo();
      this.generateInputKey();
      await this.initializeNative();
      this.applyPreConnectionSettings(config);
      await this.setupVideoSurface();

      if (this.stageProgressCallback) {
        this.stageProgressCallback(0, '正在启动应用...');
      }
      const cachedCurrentGame = await this.getCachedCurrentGame();
      await this.launchApp(cachedCurrentGame);
      await this.connectToServer();
      this.applyPostConnectionSettings(config);

      this.isRunning = true;
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
    this.isRunning = false;
    this.resetControllerState();
    GamepadManager.getInstance().stopAllSensors();
    this.audioVibrationService.stop();
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

    this.isRunning = false;
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
      this.nativeModule.sendKeyboardInput(key, KEY_DOWN, modifier, 0);
      modifier |= StreamingSession.getModifierForKey(key);
    }

    setTimeout(() => {
      for (let i = keyCodes.length - 1; i >= 0; i--) {
        modifier &= ~StreamingSession.getModifierForKey(keyCodes[i]);
        this.nativeModule.sendKeyboardInput(keyCodes[i], KEY_UP, modifier, 0);
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
    this.nativeModule.sendMultiControllerInput(
      controllerIndex, this.activeGamepadMask,
      buttons, leftTrigger, rightTrigger,
      leftStickX, leftStickY, rightStickX, rightStickY
    );
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
      this.stats.droppedFrames = vs.framesDropped;
      this.stats.fps = vs.fps || 0;
      this.stats.renderedFps = vs.renderedFps || 0;
      this.stats.bitrate = vs.bitrate || 0;
      this.stats.latency = vs.avgDecodeTimeMs || 0;
      this.stats.hostLatency = vs.hostLatency || 0;
      // 分级丢帧统计
      this.stats.droppedByL1 = vs.droppedByL1 || 0;
      this.stats.droppedByL2 = vs.droppedByL2 || 0;
      this.stats.droppedByL3 = vs.droppedByL3 || 0;
      this.stats.droppedByL4 = vs.droppedByL4 || 0;
      this.stats.droppedByL5 = vs.droppedByL5 || 0;

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
      renderedFps: this.stats.renderedFps,
      bitrate: this.stats.bitrate,
      latency: this.stats.latency,
      hostLatency: this.stats.hostLatency,
      networkLatency: this.stats.networkLatency,
      packetLoss: this.stats.packetLoss,
      decodedFrames: this.stats.decodedFrames,
      droppedFrames: this.stats.droppedFrames,
      globalAvgDecodeLatency: this.stats.globalAvgDecodeLatency,
      globalAvgHostLatency: this.stats.globalAvgHostLatency,
      globalAvgFps: this.stats.globalAvgFps,
      droppedByL1: this.stats.droppedByL1,
      droppedByL2: this.stats.droppedByL2,
      droppedByL3: this.stats.droppedByL3,
      droppedByL4: this.stats.droppedByL4,
      droppedByL5: this.stats.droppedByL5,
    };
    copy.fps = Math.round(copy.fps);
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
    this.nvHttp = new NvHttp(
      selectBestAddress(this.computer), this.computer.serverCert, context, this.computer.httpPort
    );
  }

  private async fetchServerInfo(): Promise<void> {
    if (!this.nvHttp) throw new Error('nvHttp 未初始化');
    const serverInfo = await this.nvHttp.getServerInfo();
    this.serverAppVersion = serverInfo.appVersion || '';
    this.serverGfeVersion = serverInfo.gfeVersion || '';
    this.serverCodecModeSupport = serverInfo.serverCodecModeSupport || 0;
    console.info(`服务器版本: app=${this.serverAppVersion}, gfe=${this.serverGfeVersion}, ` +
      `codecSupport=${this.serverCodecModeSupport}`);

    if (this.stageProgressCallback) {
      this.stageProgressCallback(0, '正在初始化...');
    }
  }

  private async getCachedCurrentGame(): Promise<number> {
    if (!this.nvHttp) return 0;
    const serverInfo = await this.nvHttp.getServerInfo();
    return serverInfo.currentGame || 0;
  }

  private generateInputKey(): void {
    this.riKey = CryptoUtil.generateAesKey();
    this.riKeyId = CryptoUtil.generateRandomUint32();
  }

  private applyPreConnectionSettings(config: StreamConfig): void {
    if (config.enableSpatializer) {
      this.nativeModule.setSpatialAudioEnabled(true);
      console.info('空间音频已启用');
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
    // 必须在 connectToServer() 之后，因为 BridgeArInit() 会重置 enabled_=false
    // 第三个参数: sceneMode (游戏/电影=0, 音乐/节奏=1, 自动=2)
    const sceneMode = this.audioVibrationService.getSceneModeInt();
    this.nativeModule.setBassVibrationConfig(config.enableAudioVibration, 1.0, sceneMode);
    if (config.enableAudioVibration) {
      console.info(`音频振动已启用, 强度=${config.audioVibrationStrength}, 模式=${config.vibrationMode}, 场景=${config.audioVibrationSceneMode}`);
    }
  }

  // ---------------------------------------------------------------------------
  // 内部 — Native 初始化
  // ---------------------------------------------------------------------------

  private async initializeNative(): Promise<void> {
    console.info('初始化 Native 模块');

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
      drStart: (): void => { console.info('视频解码器启动'); },
      drStop: (): void => { console.info('视频解码器停止'); },
      drCleanup: (): void => { console.info('视频解码器清理'); },
      arInit: (audioConfiguration: number, sampleRate: number, samplesPerFrame: number): void => {
        console.info(`音频初始化: config=${audioConfiguration}, rate=${sampleRate}, samples=${samplesPerFrame}`);
      },
      arStart: (): void => { console.info('音频渲染器启动'); },
      arStop: (): void => { console.info('音频渲染器停止'); },
      arCleanup: (): void => { console.info('音频渲染器清理'); },
      stageStarting: (stage: number): void => {
        const name = STAGE_NAMES[stage] || `阶段 ${stage}`;
        console.info(`连接阶段开始: ${stage} (${name})`);
        if (this.stageProgressCallback) this.stageProgressCallback(stage, name);
      },
      stageComplete: (stage: number): void => { console.info(`连接阶段完成: ${stage}`); },
      stageFailed: (stage: number, errorCode: number): void => {
        const name = STAGE_NAMES[stage] || `阶段 ${stage}`;
        console.error(`连接阶段失败: stage=${stage} (${name}), error=${errorCode}`);
      },
      connectionStarted: (): void => {
        console.info('连接已建立');
        this.isRunning = true;
        this.startMicrophoneIfNeeded();
      },
      connectionTerminated: (errorCode: number): void => {
        console.info(`连接已终止: ${errorCode}, userInitiated=${this.userInitiatedStop}`);
        this.isRunning = false;
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
      connectionStatusUpdate: (status: number): void => { console.info(`连接状态更新: ${status}`); },
      setHdrMode: (enabled: boolean): void => {
        console.info(`HDR 模式变化通知: ${enabled}`);
        if (this.config && this.config.hdr !== enabled) {
          this.config.hdr = enabled;
        }
        if (this.hdrStateCallback) this.hdrStateCallback(enabled);
      },
      rumble: (cn: number, low: number, high: number): void => {
        GamepadManager.getInstance().handleRumble(cn, low, high);
      },
      rumbleTriggers: (cn: number, lt: number, rt: number): void => {
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
      bassEnergy: (intensity: number): void => {
        this.audioVibrationService.handleBassEnergy(intensity);
      }
    };

    // 设置传感器数据回调
    GamepadManager.getInstance().setSensorDataCallback(
      (cn: number, motionType: number, x: number, y: number, z: number): void => {
        if (this.isRunning) this.nativeModule.sendControllerMotionEvent(cn, motionType, x, y, z);
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

    const brightnessRange = StreamingSession.getBrightnessRange();

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
      maxAverageBrightness: brightnessRange[2]
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
    this.nativeModule.setVrrEnabled(this.config.enableVrr);

    console.info(`解码器: buffers=${this.config.decoderBufferCount}, sync=${this.config.enableSyncDecode}, ` +
      `vsync=${this.config.enableVsync}, vrr=${this.config.enableVrr}`);

    const result = this.nativeModule.startConnection(
      this.computer.address,
      this.serverAppVersion,
      this.serverGfeVersion,
      this.rtspSessionUrl,
      this.serverCodecModeSupport,
      this.config.width, this.config.height, this.config.fps,
      this.config.bitrate,
      1392, // packetSize
      0,    // streamingRemotely
      this.config.audioConfig,
      supportedVideoFormats,
      this.config.clientRefreshRateX100,
      this.riKey, riAesIv,
      0x01 | 0x02, // videoCapabilities: DIRECT_SUBMIT | RFI_AVC
      this.config.hdr ? 2 : 1, // colorSpace: REC_2020 / REC_709
      this.config.colorRange,
      this.config.hdr ? this.config.hdrMode : HdrMode.SDR,
      this.config.microphoneEnabled,
      false // controlOnly
    );

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
    this.nativeModule.sendMultiControllerInput(
      controllerIndex, this.activeGamepadMask,
      s.buttonFlags, s.leftTrigger, s.rightTrigger,
      s.leftStickX, s.leftStickY, s.rightStickX, s.rightStickY
    );
  }

  private ensureVirtualControllerArrival(controllerIndex: number): void {
    if (this.virtualControllerArrived) return;

    this.activeGamepadMask |= (1 << controllerIndex);
    const ret = this.nativeModule.sendControllerArrivalEvent(
      controllerIndex, this.activeGamepadMask,
      CONTROLLER_TYPE_XBOX, STANDARD_BUTTON_FLAGS,
      LI_CCAP_ANALOG_TRIGGERS | LI_CCAP_RUMBLE
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

    let capabilities = LI_CCAP_ANALOG_TRIGGERS | LI_CCAP_RUMBLE;
    capabilities |= GamepadManager.getInstance().getSensorCapabilities();

    let reportedType = controllerType;
    if ((capabilities & (LI_CCAP_ACCEL | LI_CCAP_GYRO)) && controllerType !== CONTROLLER_TYPE_PS) {
      reportedType = CONTROLLER_TYPE_UNKNOWN;
    }

    this.activeGamepadMask |= (1 << controllerIndex);
    const ret = this.nativeModule.sendControllerArrivalEvent(
      controllerIndex, this.activeGamepadMask,
      reportedType, STANDARD_BUTTON_FLAGS, capabilities
    );

    if (ret >= 0) {
      this.physicalControllerArrived.add(controllerIndex);
      console.info(`[Gamepad] arrival: index=${controllerIndex}, type=${reportedType}(orig=${controllerType}), ` +
        `caps=0x${capabilities.toString(16)}, mask=0x${this.activeGamepadMask.toString(16)}`);
    }
  }

  private resetControllerState(): void {
    this.virtualControllerArrived = false;
    this.physicalControllerArrived.clear();
    this.activeGamepadMask = 0;
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
    this.microphoneStream = new MicrophoneStream(MoonBridge);
    this.microphoneStream.start().then((success: boolean) => {
      if (!success) {
        console.error('麦克风启动失败');
        this.microphoneStream = null;
      }
    }).catch((error: Error) => {
      console.error(`麦克风启动异常: ${error.message}`);
      this.microphoneStream = null;
    });
  }

  private stopMicrophone(): void {
    if (!this.microphoneStream) return;
    console.info('停止麦克风...');
    this.microphoneStream.stop().catch((error: Error) => {
      console.warn(`停止麦克风出错: ${error.message}`);
    });
    this.microphoneStream = null;
  }

  // ---------------------------------------------------------------------------
  // 内部 — 清理
  // ---------------------------------------------------------------------------

  private async cleanup(): Promise<void> {
    console.info('清理串流资源');
    this.stopMicrophone();
    this.nativeModule.setPerformanceModeEnabled(false);
    try {
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
