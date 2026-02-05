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
 * MoonBridge - Native 桥接模块
 * 
 * 这是 ArkTS 与 moonlight-common-c 之间的桥接层
 * 参照 Android MoonBridge.java 实现
 */

import nativeLib from 'libmoonlight_nativelib.so';

// =============================================================================
// 常量定义
// =============================================================================

// 鼠标按钮动作
export const BUTTON_ACTION_PRESS = 0x07;
export const BUTTON_ACTION_RELEASE = 0x08;

// 鼠标按钮
export const BUTTON_LEFT = 0x01;
export const BUTTON_MIDDLE = 0x02;
export const BUTTON_RIGHT = 0x03;
export const BUTTON_X1 = 0x04;
export const BUTTON_X2 = 0x05;

// 键盘动作
export const KEY_ACTION_DOWN = 0x03;
export const KEY_ACTION_UP = 0x04;

// 修饰键
export const MODIFIER_SHIFT = 0x01;
export const MODIFIER_CTRL = 0x02;
export const MODIFIER_ALT = 0x04;
export const MODIFIER_META = 0x08;

// 触摸事件类型
export const TOUCH_EVENT_HOVER = 0x00;
export const TOUCH_EVENT_DOWN = 0x01;
export const TOUCH_EVENT_UP = 0x02;
export const TOUCH_EVENT_MOVE = 0x03;
export const TOUCH_EVENT_CANCEL = 0x04;
export const TOUCH_EVENT_BUTTON_ONLY = 0x05;
export const TOUCH_EVENT_HOVER_LEAVE = 0x06;
export const TOUCH_EVENT_CANCEL_ALL = 0x07;

// 手柄按钮
export const A_FLAG = 0x1000;
export const B_FLAG = 0x2000;
export const X_FLAG = 0x4000;
export const Y_FLAG = 0x8000;
export const UP_FLAG = 0x0001;
export const DOWN_FLAG = 0x0002;
export const LEFT_FLAG = 0x0004;
export const RIGHT_FLAG = 0x0008;
export const LB_FLAG = 0x0100;
export const RB_FLAG = 0x0200;
export const PLAY_FLAG = 0x0010;
export const BACK_FLAG = 0x0020;
export const LS_CLK_FLAG = 0x0040;
export const RS_CLK_FLAG = 0x0080;
export const SPECIAL_FLAG = 0x0400;
export const PADDLE1_FLAG = 0x010000;
export const PADDLE2_FLAG = 0x020000;
export const PADDLE3_FLAG = 0x040000;
export const PADDLE4_FLAG = 0x080000;
export const TOUCHPAD_FLAG = 0x100000;
export const MISC_FLAG = 0x200000;

// 手柄类型
export const CONTROLLER_TYPE_UNKNOWN = 0x00;
export const CONTROLLER_TYPE_XBOX = 0x01;
export const CONTROLLER_TYPE_PS = 0x02;
export const CONTROLLER_TYPE_NINTENDO = 0x03;

// 视频格式
export const VIDEO_FORMAT_H264 = 0x0001;
export const VIDEO_FORMAT_H265 = 0x0100;
export const VIDEO_FORMAT_H265_MAIN10 = 0x0200;
export const VIDEO_FORMAT_AV1_MAIN8 = 0x1000;
export const VIDEO_FORMAT_AV1_MAIN10 = 0x2000;

// RTT 信息接口
export interface RttInfo {
  rtt: number;
  variance: number;
}

// 音频配置
export const AUDIO_CONFIGURATION_STEREO = 0;
export const AUDIO_CONFIGURATION_51_SURROUND = 1;
export const AUDIO_CONFIGURATION_71_SURROUND = 2;

// 连接阶段
export const STAGE_NONE = 0;
export const STAGE_PLATFORM_INIT = 1;
export const STAGE_NAME_RESOLUTION = 2;
export const STAGE_RTSP_HANDSHAKE = 3;
export const STAGE_CONTROL_STREAM_INIT = 4;
export const STAGE_VIDEO_STREAM_INIT = 5;
export const STAGE_AUDIO_STREAM_INIT = 6;
export const STAGE_INPUT_STREAM_INIT = 7;
export const STAGE_CONTROL_STREAM_START = 8;
export const STAGE_VIDEO_STREAM_START = 9;
export const STAGE_AUDIO_STREAM_START = 10;
export const STAGE_INPUT_STREAM_START = 11;
export const STAGE_MAX = 12;

// 连接状态
export const CONN_STATUS_OKAY = 0;
export const CONN_STATUS_POOR = 1;

// 视频能力
export const CAPABILITY_DIRECT_SUBMIT = 0x01;
export const CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC = 0x02;
export const CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC = 0x04;
export const CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1 = 0x08;
export const CAPABILITY_SLICES_PER_FRAME = 0x10;

// Buffer 类型
export const BUFFER_TYPE_PICDATA = 0x00;
export const BUFFER_TYPE_SPS = 0x01;
export const BUFFER_TYPE_PPS = 0x02;
export const BUFFER_TYPE_VPS = 0x03;

// 帧类型
export const FRAME_TYPE_PFRAME = 0x00;
export const FRAME_TYPE_IDR = 0x01;

// =============================================================================
// 回调接口定义
// =============================================================================

export interface VideoDecoderCallbacks {
  /** 设置视频解码器 */
  drSetup?: (videoFormat: number, width: number, height: number, redrawRate: number) => number;
  /** 开始视频解码 */
  drStart?: () => void;
  /** 停止视频解码 */
  drStop?: () => void;
  /** 清理视频解码器 */
  drCleanup?: () => void;
  /** 提交解码单元 */
  drSubmitDecodeUnit?: (data: ArrayBuffer, frameNumber: number, frameType: number) => number;
}

export interface AudioRendererCallbacks {
  /** 初始化音频渲染器 */
  arInit?: (audioConfiguration: number, sampleRate: number, samplesPerFrame: number) => number;
  /** 开始音频渲染 */
  arStart?: () => void;
  /** 停止音频渲染 */
  arStop?: () => void;
  /** 清理音频渲染器 */
  arCleanup?: () => void;
  /** 播放音频样本 */
  arPlaySample?: (samples: Int16Array) => void;
}

export interface ConnectionListenerCallbacks {
  /** 阶段开始 */
  stageStarting?: (stage: number) => void;
  /** 阶段完成 */
  stageComplete?: (stage: number) => void;
  /** 阶段失败 */
  stageFailed?: (stage: number, errorCode: number) => void;
  /** 连接已建立 */
  connectionStarted?: () => void;
  /** 连接已终止 */
  connectionTerminated?: (errorCode: number) => void;
  /** 震动反馈 */
  rumble?: (controllerNumber: number, lowFreqMotor: number, highFreqMotor: number) => void;
  /** 连接状态更新 */
  connectionStatusUpdate?: (connectionStatus: number) => void;
  /** 分辨率变更 */
  resolutionChanged?: (width: number, height: number) => void;
}

export interface MoonBridgeCallbacks extends VideoDecoderCallbacks, AudioRendererCallbacks, ConnectionListenerCallbacks {
}

// =============================================================================
// 连接配置
// =============================================================================

/**
 * HDR 模式定义
 * 0 = SDR (标准动态范围)
 * 1 = HDR10/PQ (SMPTE ST 2084 传输特性)
 * 2 = HLG (Hybrid Log-Gamma, ARIB STD-B67 传输特性)
 */
export const HDR_MODE_SDR = 0;
export const HDR_MODE_HDR10 = 1;
export const HDR_MODE_HLG = 2;

export interface StreamConfiguration {
  address: string;
  appVersion: string;
  gfeVersion?: string;
  rtspSessionUrl?: string;
  serverCodecModeSupport: number;
  width: number;
  height: number;
  fps: number;
  bitrate: number;
  packetSize: number;
  streamingRemotely: number;
  audioConfiguration: number;
  supportedVideoFormats: number;
  clientRefreshRateX100: number;
  riAesKey: ArrayBuffer;
  riAesIv: ArrayBuffer;
  videoCapabilities: number;
  colorSpace: number;
  colorRange: number;
  hdrMode?: number;        // HDR 模式: 0=SDR, 1=HDR10/PQ, 2=HLG
  enableMic?: boolean;
  controlOnly?: boolean;
}

// =============================================================================
// MoonBridge 类
// =============================================================================

class MoonBridgeClass {
  private callbacks: MoonBridgeCallbacks | null = null;

  /**
   * 初始化桥接层
   */
  init(callbacks: MoonBridgeCallbacks): boolean {
    this.callbacks = callbacks;
    return nativeLib.init(callbacks);
  }

  /**
   * 开始连接
   */
  startConnection(config: StreamConfiguration): number {
    return nativeLib.startConnection(
      config.address,
      config.appVersion,
      config.gfeVersion || '',
      config.rtspSessionUrl || '',
      config.serverCodecModeSupport,
      config.width,
      config.height,
      config.fps,
      config.bitrate,
      config.packetSize,
      config.streamingRemotely,
      config.audioConfiguration,
      config.supportedVideoFormats,
      config.clientRefreshRateX100,
      config.riAesKey,
      config.riAesIv,
      config.videoCapabilities,
      config.colorSpace,
      config.colorRange,
      config.hdrMode || HDR_MODE_SDR,
      config.enableMic || false,
      config.controlOnly || false
    );
  }

  /**
   * 停止连接
   */
  stopConnection(): void {
    nativeLib.stopConnection();
  }

  /**
   * 中断连接
   */
  interruptConnection(): void {
    nativeLib.interruptConnection();
  }

  // ==========================================================================
  // 鼠标输入
  // ==========================================================================

  sendMouseMove(deltaX: number, deltaY: number): void {
    nativeLib.sendMouseMove(deltaX, deltaY);
  }

  sendMousePosition(x: number, y: number, referenceWidth: number, referenceHeight: number): void {
    nativeLib.sendMousePosition(x, y, referenceWidth, referenceHeight);
  }

  sendMouseMoveAsMousePosition(deltaX: number, deltaY: number, referenceWidth: number, referenceHeight: number): void {
    nativeLib.sendMouseMoveAsMousePosition(deltaX, deltaY, referenceWidth, referenceHeight);
  }

  sendMouseButton(buttonEvent: number, mouseButton: number): void {
    nativeLib.sendMouseButton(buttonEvent, mouseButton);
  }

  sendMouseHighResScroll(scrollAmount: number): void {
    nativeLib.sendMouseHighResScroll(scrollAmount);
  }

  sendMouseHighResHScroll(scrollAmount: number): void {
    nativeLib.sendMouseHighResHScroll(scrollAmount);
  }

  // ==========================================================================
  // 键盘输入
  // ==========================================================================

  sendKeyboardInput(keyCode: number, keyAction: number, modifiers: number, flags: number): void {
    nativeLib.sendKeyboardInput(keyCode, keyAction, modifiers, flags);
  }

  sendUtf8Text(text: string): void {
    nativeLib.sendUtf8Text(text);
  }

  // ==========================================================================
  // 手柄输入
  // ==========================================================================

  sendMultiControllerInput(
    controllerNumber: number,
    activeGamepadMask: number,
    buttonFlags: number,
    leftTrigger: number,
    rightTrigger: number,
    leftStickX: number,
    leftStickY: number,
    rightStickX: number,
    rightStickY: number
  ): void {
    nativeLib.sendMultiControllerInput(
      controllerNumber,
      activeGamepadMask,
      buttonFlags,
      leftTrigger,
      rightTrigger,
      leftStickX,
      leftStickY,
      rightStickX,
      rightStickY
    );
  }

  sendControllerArrivalEvent(
    controllerNumber: number,
    activeGamepadMask: number,
    type: number,
    supportedButtonFlags: number,
    capabilities: number
  ): number {
    return nativeLib.sendControllerArrivalEvent(
      controllerNumber,
      activeGamepadMask,
      type,
      supportedButtonFlags,
      capabilities
    );
  }

  sendControllerTouchEvent(
    controllerNumber: number,
    eventType: number,
    pointerId: number,
    x: number,
    y: number,
    pressure: number
  ): number {
    return nativeLib.sendControllerTouchEvent(controllerNumber, eventType, pointerId, x, y, pressure);
  }

  sendControllerMotionEvent(
    controllerNumber: number,
    motionType: number,
    x: number,
    y: number,
    z: number
  ): number {
    return nativeLib.sendControllerMotionEvent(controllerNumber, motionType, x, y, z);
  }

  sendControllerBatteryEvent(
    controllerNumber: number,
    batteryState: number,
    batteryPercentage: number
  ): number {
    return nativeLib.sendControllerBatteryEvent(controllerNumber, batteryState, batteryPercentage);
  }

  // ==========================================================================
  // 触摸输入
  // ==========================================================================

  sendTouchEvent(
    eventType: number,
    pointerId: number,
    x: number,
    y: number,
    pressureOrDistance: number,
    contactAreaMajor: number,
    contactAreaMinor: number,
    rotation: number
  ): number {
    return nativeLib.sendTouchEvent(
      eventType,
      pointerId,
      x,
      y,
      pressureOrDistance,
      contactAreaMajor,
      contactAreaMinor,
      rotation
    );
  }

  sendPenEvent(
    eventType: number,
    toolType: number,
    penButtons: number,
    x: number,
    y: number,
    pressureOrDistance: number,
    contactAreaMajor: number,
    contactAreaMinor: number,
    rotation: number,
    tilt: number
  ): number {
    return nativeLib.sendPenEvent(
      eventType,
      toolType,
      penButtons,
      x,
      y,
      pressureOrDistance,
      contactAreaMajor,
      contactAreaMinor,
      rotation,
      tilt
    );
  }

  // ==========================================================================
  // 麦克风
  // ==========================================================================

  getMicPortNumber(): number {
    return nativeLib.getMicPortNumber();
  }

  isMicrophoneRequested(): boolean {
    return nativeLib.isMicrophoneRequested();
  }

  sendMicrophoneOpusData(opusData: ArrayBuffer): number {
    return nativeLib.sendMicrophoneOpusData(opusData);
  }

  isMicrophoneEncryptionEnabled(): boolean {
    return nativeLib.isMicrophoneEncryptionEnabled();
  }

  // ==========================================================================
  // Opus 编码器
  // ==========================================================================

  /**
   * 创建 Opus 编码器实例
   * @param sampleRate 采样率 (默认 48000)
   * @param channels 通道数 (默认 1)
   * @param bitrate 比特率 (默认 64000)
   * @returns 编码器句柄 (>0 成功, <=0 失败)
   */
  opusEncoderCreate(sampleRate: number = 48000, channels: number = 1, bitrate: number = 64000): number {
    return nativeLib.opusEncoderCreate(sampleRate, channels, bitrate);
  }

  /**
   * 使用指定编码器编码 PCM 数据为 Opus
   * @param handle 编码器句柄
   * @param pcmData PCM 数据 (16位有符号整数, 小端序)
   * @returns 编码后的 Opus 数据，或 undefined 如果失败/暂无数据
   */
  opusEncoderEncode(handle: number, pcmData: ArrayBuffer): ArrayBuffer | undefined {
    return nativeLib.opusEncoderEncode(handle, pcmData);
  }

  /**
   * 销毁 Opus 编码器实例
   * @param handle 编码器句柄
   */
  opusEncoderDestroy(handle: number): void {
    nativeLib.opusEncoderDestroy(handle);
  }

  // ==========================================================================
  // 性能模式
  // ==========================================================================

  /**
   * 设置是否启用性能模式
   * 性能模式会优化线程优先级和系统资源调度
   * @param enabled 是否启用
   */
  setPerformanceModeEnabled(enabled: boolean): void {
    nativeLib.setPerformanceModeEnabled(enabled);
  }

  /**
   * 获取性能模式是否启用
   */
  getPerformanceModeEnabled(): boolean {
    return nativeLib.getPerformanceModeEnabled();
  }

  // ==========================================================================
  // 状态和统计
  // ==========================================================================

  getStageName(stage: number): string {
    return nativeLib.getStageName(stage);
  }

  getPendingAudioDuration(): number {
    return nativeLib.getPendingAudioDuration();
  }

  getPendingVideoFrames(): number {
    return nativeLib.getPendingVideoFrames();
  }

  getEstimatedRttInfo(): RttInfo | null {
    const combined: number = nativeLib.getEstimatedRttInfo();
    if (combined < 0) {
      return null;
    }
    const rtt = Number(BigInt(combined) >> 32n);
    const variance = combined & 0xFFFFFFFF;
    const result: RttInfo = { rtt: rtt, variance: variance };
    return result;
  }

  getHostFeatureFlags(): number {
    return nativeLib.getHostFeatureFlags();
  }

  getLaunchUrlQueryParameters(): string | null {
    return nativeLib.getLaunchUrlQueryParameters();
  }

  // ==========================================================================
  // 工具函数
  // ==========================================================================

  testClientConnectivity(testServerHostName: string, referencePort: number, testFlags: number): number {
    return nativeLib.testClientConnectivity(testServerHostName, referencePort, testFlags);
  }

  getPortFlagsFromStage(stage: number): number {
    return nativeLib.getPortFlagsFromStage(stage);
  }

  getPortFlagsFromTerminationErrorCode(errorCode: number): number {
    return nativeLib.getPortFlagsFromTerminationErrorCode(errorCode);
  }

  stringifyPortFlags(portFlags: number, separator: string): string {
    return nativeLib.stringifyPortFlags(portFlags, separator);
  }

  findExternalAddressIP4(stunHostName: string, stunPort: number): string | null {
    return nativeLib.findExternalAddressIP4(stunHostName, stunPort);
  }

  guessControllerType(vendorId: number, productId: number): number {
    return nativeLib.guessControllerType(vendorId, productId);
  }

  guessControllerHasPaddles(vendorId: number, productId: number): boolean {
    return nativeLib.guessControllerHasPaddles(vendorId, productId);
  }

  guessControllerHasShareButton(vendorId: number, productId: number): boolean {
    return nativeLib.guessControllerHasShareButton(vendorId, productId);
  }
}

// 导出类型和单例
export { MoonBridgeClass };
export const MoonBridge = new MoonBridgeClass();
export default MoonBridge;
