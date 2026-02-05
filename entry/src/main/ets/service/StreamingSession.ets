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
import { ComputerInfo } from '../model/ComputerInfo';
import { NvHttp, LaunchConfig } from './NvHttp';
import { CryptoUtil } from '../utils/CryptoUtil';
import { common } from '@kit.AbilityKit';
import { GamepadManager } from './GamepadManager';
import { MicrophoneStream } from './microphone/MicrophoneStream';
import { MoonBridge } from './MoonBridge';
import nativeLib from 'libmoonlight_nativelib.so';

/**
 * 串流会话管理
 * 
 * 负责管理与服务器的串流连接，包括：
 * - 视频解码与渲染
 * - 音频解码与播放
 * - 输入事件发送
 * - 性能统计
 */
export interface StreamStats {
  fps: number;             // 接收帧率 (Rx)
  renderedFps: number;     // 渲染帧率 (Rd)
  bitrate: number;         // Kbps
  latency: number;         // 解码延迟 ms
  hostLatency: number;     // 主机处理延迟（编码时间）ms
  networkLatency: number;  // 网络延迟（RTT）ms
  packetLoss: number;      // %
  decodedFrames: number;
  droppedFrames: number;
}

// Native 模块类型声明
interface NativeModule {
  init(callbacks: StreamCallbacks): void;
  startConnection(
    address: string,
    appVersion: string,
    gfeVersion: string,
    rtspSessionUrl: string,
    serverCodecModeSupportFlags: number,
    width: number,
    height: number,
    fps: number,
    bitrate: number,
    packetSize: number,
    streamingRemotely: number,
    audioConfiguration: number,
    supportedVideoFormats: number,
    clientRefreshRateX100: number,
    riAesKey: ArrayBuffer,
    riAesIv: ArrayBuffer,
    videoCapabilities: number,
    colorSpace: number,
    colorRange: number,
    hdrMode: number,
    enableMic: boolean,
    controlOnly: boolean
  ): number;
  stopConnection(): void;
  interruptConnection(): void;
  resumeDecoder(): void;  // 从后台恢复解码器
  setVideoSurface(surfaceId: string): boolean;
  releaseVideoSurface(): void;
  getVideoStats(): VideoStats;
  getDecoderCapabilities(): DecoderCapabilities;
  setDecoderBufferCount(count: number): void;
  setDecoderSyncMode(enabled: boolean): void;   // 同步解码模式（API 20+，减少回调延迟）
  isDecoderSyncMode(): boolean;
  // VSync 设置（使用 RenderOutputBufferAtTime 精确呈现）
  setVsyncEnabled(enabled: boolean): void;
  isVsyncEnabled(): boolean;
  // VRR (Variable Refresh Rate) 可变刷新率设置
  // 启用后解码器输出将适配可变刷新率显示，根据视频内容动态调整屏幕刷新率
  // 注意：VRR 可能会丢帧以匹配屏幕刷新率，主要用于节能
  setVrrEnabled(enabled: boolean): void;
  // 音频设置
  setSpatialAudioEnabled(enabled: boolean): void;
  isSpatialAudioEnabled(): boolean;
  setAudioVolume(volume: number): boolean;
  // 性能模式设置
  setPerformanceModeEnabled(enabled: boolean): void;
  getPerformanceModeEnabled(): boolean;
  getEstimatedRttInfo(): number;  // 返回组合值 (rtt << 32) | variance，-1 表示无效
  sendMouseMove(deltaX: number, deltaY: number): void;
  sendMouseButton(buttonEvent: number, mouseButton: number): void;
  sendKeyboardInput(keyCode: number, keyAction: number, modifiers: number, flags: number): void;
  sendMultiControllerInput(controllerNumber: number, activeGamepadMask: number,
    buttonFlags: number, leftTrigger: number, rightTrigger: number,
    leftStickX: number, leftStickY: number, rightStickX: number, rightStickY: number): void;
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
  clStageStarting?: (stage: number) => void;
  clStageComplete?: (stage: number) => void;
  clStageFailed?: (stage: number, errorCode: number) => void;
  clConnectionStarted?: () => void;
  clConnectionTerminated?: (errorCode: number) => void;
  clConnectionStatusUpdate?: (connectionStatus: number) => void;
  setHdrMode?: (enabled: boolean) => void;
  rumble?: (controllerNumber: number, lowFreqMotor: number, highFreqMotor: number) => void;
}

interface VideoStats {
  framesDecoded: number;
  framesDropped: number;
  avgDecodeTimeMs: number;
  fps: number;           // 接收帧率 (Rx)
  renderedFps: number;   // 渲染帧率 (Rd)
  bitrate: number;
  hostLatency: number;   // 主机处理延迟（编码时间）ms
}

export interface DecoderCapabilities {
  supportsH264: boolean;
  supportsHEVC: boolean;
  supportsAV1: boolean;
  maxWidth: number;
  maxHeight: number;
  maxFps: number;
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

// 导出 nativeLib 的引用以供静态方法使用
const nativeModuleRef = nativeLib as NativeModule;

/**
 * HDR 状态变化回调类型
 */
export type HdrStateCallback = (isHdr: boolean) => void;

export class StreamingSession {
  private computerId: string = '';
  private appId: number = 0;
  private config: StreamConfig | null = null;
  private surfaceId: string = '';
  private isRunning: boolean = false;
  private nativeModule: NativeModule;
  private computer: ComputerInfo | null = null;
  private nvHttp: NvHttp | null = null;
  private riKey: ArrayBuffer | null = null;
  private riKeyId: number = 0;
  private hdrStateCallback: HdrStateCallback | null = null;
  private displayGuid: string = '';  // 选择的显示器 GUID
  private useVdd: boolean = false;   // 是否使用虚拟显示器
  
  // 服务器信息（用于连接）
  private serverAppVersion: string = '';
  private serverGfeVersion: string = '';
  private serverCodecModeSupport: number = 0;
  private rtspSessionUrl: string = '';
  
  // 性能统计
  private stats: StreamStats = {
    fps: 0,
    renderedFps: 0,
    bitrate: 0,
    latency: 0,
    hostLatency: 0,
    networkLatency: 0,
    packetLoss: 0,
    decodedFrames: 0,
    droppedFrames: 0
  };

  // 麦克风
  private microphoneStream: MicrophoneStream | null = null;

  constructor() {
    this.nativeModule = nativeLib as NativeModule;
  }

  /**
   * 设置 HDR 状态变化回调
   * 当 drSetup 检测到实际 HDR 状态时调用
   */
  setHdrStateCallback(callback: HdrStateCallback | null): void {
    this.hdrStateCallback = callback;
  }

  /**
   * 获取当前实际使用的串流配置
   * 这个配置可能与初始配置不同（例如 HDR 可能因设备不支持而被禁用）
   */
  getEffectiveConfig(): StreamConfig | null {
    return this.config;
  }

  /**
   * 获取解码器能力信息（静态方法）
   * 用于在设置页面显示支持的编解码器
   */
  static getDecoderCapabilities(): DecoderCapabilities {
    return nativeModuleRef.getDecoderCapabilities();
  }

  /**
   * 开始串流会话
   * @param computerId 电脑ID
   * @param appId 应用ID
   * @param config 串流配置
   * @param surfaceId 视频Surface ID
   * @param context UI上下文（用于客户端证书）
   * @param displayGuid 指定的显示器 GUID (Sunshine)
   * @param useVdd 是否使用虚拟显示器 (Sunshine)
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
    console.info(`HDR配置: hdr=${config.hdr}, hdrMode=${config.hdrMode} (0=SDR,1=HDR10,2=HLG), colorRange=${config.colorRange} (0=Limited,1=Full)`);
    if (this.displayGuid || this.useVdd) {
      console.info(`显示器配置: displayGuid=${this.displayGuid}, useVdd=${this.useVdd}`);
    };
    
    try {
      // 1. 获取电脑信息
      const computerManager = ComputerManager.getInstance();
      const computerResult = computerManager.getComputer(computerId);
      if (!computerResult) {
        throw new Error(`找不到电脑: ${computerId}`);
      }
      this.computer = computerResult;
      
      // 2. 创建 NvHttp 实例（传递 context 以支持客户端证书，传递 httpPort 支持自定义端口）
      this.nvHttp = new NvHttp(this.computer.address, this.computer.serverCert, context, this.computer.httpPort);
      
      // 3. 获取服务器信息（包括 appVersion、gfeVersion）
      const serverInfo = await this.nvHttp.getServerInfo();
      this.serverAppVersion = serverInfo.appVersion || '';
      this.serverGfeVersion = serverInfo.gfeVersion || '';
      this.serverCodecModeSupport = serverInfo.serverCodecModeSupport || 0;
      console.info(`服务器版本: app=${this.serverAppVersion}, gfe=${this.serverGfeVersion}, codecSupport=${this.serverCodecModeSupport}`);
      
      // 4. 生成随机输入密钥（使用加密安全的随机数）
      this.riKey = CryptoUtil.generateAesKey();
      this.riKeyId = CryptoUtil.generateRandomUint32();
      
      // 5. 初始化 Native 模块
      await this.initializeNative();
      
      // 5.1 应用音频设置（空间音频）
      if (config.enableSpatializer) {
        this.nativeModule.setSpatialAudioEnabled(true);
        console.info('空间音频已启用');
      }
      
      // 5.2 应用性能模式设置
      if (config.performanceMode) {
        this.nativeModule.setPerformanceModeEnabled(true);
        console.info('性能模式已启用');
      }
      
      // 6. 设置视频 Surface
      await this.setupVideoSurface();
      
      // 7. 启动应用（获取 RTSP Session URL）
      await this.launchApp();
      
      // 8. 连接到服务器
      await this.connectToServer();
      
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
    this.isRunning = false;
    
    await this.cleanup();
  }
  
  /**
   * 从后台恢复解码器
   * 当应用从后台切回前台时调用
   */
  resumeDecoder(): void {
    console.info('[StreamingSession] 恢复解码器');
    
    if (!this.isRunning) {
      console.warn('[StreamingSession] 串流已停止，无需恢复解码器');
      return;
    }
    
    try {
      // 调用 native 层的恢复方法
      (nativeLib as NativeModule).resumeDecoder();
      console.info('[StreamingSession] 解码器恢复命令已发送');
    } catch (err) {
      console.error('[StreamingSession] 恢复解码器失败:', err);
    }
  }

  /**
   * 退出远程应用并停止串流
   * 调用服务器 API 退出当前运行的游戏
   * @returns 是否成功退出
   */
  async quitApp(): Promise<boolean> {
    console.info('退出远程应用');
    
    let quitSuccess = false;
    
    // 先调用服务器 API 退出应用
    if (this.nvHttp) {
      try {
        quitSuccess = await this.nvHttp.quitApp();
        if (quitSuccess) {
          console.info('远程应用已退出');
        } else {
          console.warn('退出远程应用失败');
        }
      } catch (err) {
        console.error('退出远程应用出错:', err);
      }
    }
    
    // 无论退出成功与否都停止串流
    this.isRunning = false;
    await this.cleanup();
    
    return quitSuccess;
  }

  /**
   * 发送输入事件
   */
  sendInput(input: InputEvent): void {
    if (!this.isRunning) {
      return;
    }
    
    if (input.type === InputType.CONTROLLER_BUTTON) {
      const buttonEvent = input as ControllerButtonEvent;
      this.handleControllerButton(buttonEvent);
    } else if (input.type === InputType.CONTROLLER_AXIS) {
      const axisEvent = input as ControllerAxisEvent;
      this.handleControllerAxis(axisEvent);
    }
  }

  // 当前控制器状态接口
  private controllerState: ControllerState = {
    buttonFlags: 0,
    leftTrigger: 0,
    rightTrigger: 0,
    leftStickX: 0,
    leftStickY: 0,
    rightStickX: 0,
    rightStickY: 0
  };

  /**
   * 处理控制器按钮事件
   */
  private handleControllerButton(event: ControllerButtonEvent): void {
    const buttonValue = event.button as number;
    
    if (event.isPressed) {
      this.controllerState.buttonFlags |= buttonValue;
    } else {
      this.controllerState.buttonFlags &= ~buttonValue;
    }
    
    this.sendControllerState(event.controllerIndex);
  }

  /**
   * 处理控制器轴事件
   */
  private handleControllerAxis(event: ControllerAxisEvent): void {
    switch (event.axis) {
      case 0: // LEFT_X
        this.controllerState.leftStickX = event.value;
        break;
      case 1: // LEFT_Y
        this.controllerState.leftStickY = event.value;
        break;
      case 2: // RIGHT_X
        this.controllerState.rightStickX = event.value;
        break;
      case 3: // RIGHT_Y
        this.controllerState.rightStickY = event.value;
        break;
      case 4: // LEFT_TRIGGER
        this.controllerState.leftTrigger = Math.floor((event.value + 32768) / 256);
        break;
      case 5: // RIGHT_TRIGGER
        this.controllerState.rightTrigger = Math.floor((event.value + 32768) / 256);
        break;
    }
    
    this.sendControllerState(event.controllerIndex);
  }

  /**
   * 发送控制器状态到服务器
   */
  private sendControllerState(controllerIndex: number): void {
    this.nativeModule.sendMultiControllerInput(
      controllerIndex,
      1 << controllerIndex, // activeGamepadMask
      this.controllerState.buttonFlags,
      this.controllerState.leftTrigger,
      this.controllerState.rightTrigger,
      this.controllerState.leftStickX,
      this.controllerState.leftStickY,
      this.controllerState.rightStickX,
      this.controllerState.rightStickY
    );
  }

  /**
   * 直接发送完整的手柄状态（用于物理手柄输入）
   * @param controllerIndex 控制器索引
   * @param buttons 按钮状态位掩码
   * @param leftStickX 左摇杆X (-32768~32767)
   * @param leftStickY 左摇杆Y (-32768~32767)
   * @param rightStickX 右摇杆X (-32768~32767)
   * @param rightStickY 右摇杆Y (-32768~32767)
   * @param leftTrigger 左扳机 (0~255)
   * @param rightTrigger 右扳机 (0~255)
   */
  sendGamepadState(
    controllerIndex: number,
    buttons: number,
    leftStickX: number,
    leftStickY: number,
    rightStickX: number,
    rightStickY: number,
    leftTrigger: number,
    rightTrigger: number
  ): void {
    if (!this.isRunning) {
      return;
    }
    
    this.nativeModule.sendMultiControllerInput(
      controllerIndex,
      1 << controllerIndex, // activeGamepadMask
      buttons,
      leftTrigger,
      rightTrigger,
      leftStickX,
      leftStickY,
      rightStickX,
      rightStickY
    );
  }

  /**
   * 获取性能统计
   */
  getStats(): StreamStats {
    // 从 Native 层获取视频解码统计
    try {
      const videoStats = this.nativeModule.getVideoStats();
      this.stats.decodedFrames = videoStats.framesDecoded;
      this.stats.droppedFrames = videoStats.framesDropped;
      this.stats.fps = videoStats.fps || 0;                    // 接收帧率 (Rx)
      this.stats.renderedFps = videoStats.renderedFps || 0;   // 渲染帧率 (Rd)
      this.stats.bitrate = videoStats.bitrate || 0;
      // 解码时间保留小数
      this.stats.latency = videoStats.avgDecodeTimeMs || 0;
      this.stats.hostLatency = videoStats.hostLatency || 0;   // 主机处理延迟（编码时间）
      
      // 获取网络延迟 (RTT)
      const rttInfo = this.nativeModule.getEstimatedRttInfo();
      if (rttInfo >= 0) {
        // rttInfo 是组合值: (rtt << 32) | variance
        // 在 JavaScript 中处理 64 位整数需要特殊处理
        // RTT 在高 32 位
        this.stats.networkLatency = Math.floor(rttInfo / 0x100000000);  // 右移 32 位
      }
    } catch (err) {
      // ignore
    }
    
    const statsCopy: StreamStats = {
      fps: Math.round(this.stats.fps),
      renderedFps: Math.round(this.stats.renderedFps),
      bitrate: Math.round(this.stats.bitrate),
      latency: this.stats.latency,          // 解码延迟，保留小数精度
      hostLatency: this.stats.hostLatency,  // 主机处理延迟（编码时间）
      networkLatency: this.stats.networkLatency,  // 网络延迟（RTT）
      packetLoss: this.stats.packetLoss,
      decodedFrames: this.stats.decodedFrames,
      droppedFrames: this.stats.droppedFrames
    };
    return statsCopy;
  }

  /**
   * 动态调整码率
   * @param bitrate 目标码率（kbps）
   * @returns 是否成功
   */
  async setBitrate(bitrate: number): Promise<boolean> {
    if (!this.nvHttp) {
      return false;
    }
    
    try {
      const success = await this.nvHttp.setBitrate(bitrate);
      if (success && this.config) {
        this.config.bitrate = bitrate;
      }
      return success;
    } catch {
      return false;
    }
  }
  
  /**
   * 发送超级指令 (Sunshine 功能)
   * @param cmdId 指令 ID
   * @returns 是否成功
   */
  async sendSuperCmd(cmdId: string): Promise<boolean> {
    if (!this.nvHttp) {
      return false;
    }
    
    try {
      return await this.nvHttp.sendSuperCmd(cmdId);
    } catch {
      return false;
    }
  }

  /**
   * 旋转显示器方向 (Sunshine 功能)
   * 
   * 通知服务端同步修改分辨率方向，用于屏幕旋转同步
   * 
   * @param angle 旋转角度：0 表示横屏，90 表示竖屏
   * @param displayName 可选的显示器名称
   * @returns 是否成功
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
   * 获取当前码率
   */
  getCurrentBitrate(): number {
    return this.config?.bitrate || 0;
  }

  // VIDEO_FORMAT 常量定义
  private static readonly VIDEO_FORMAT_MASK_10BIT = 0xAA00;  // 10-bit 格式掩码（HDR需要10位）

  /**
   * 初始化 Native 模块
   */
  private async initializeNative(): Promise<void> {
    console.info('初始化 Native 模块');
    
    const callbacks: StreamCallbacks = {
      drSetup: (videoFormat: number, width: number, height: number, redrawRate: number): void => {
        // 检测实际的 HDR 状态（通过 10-bit 格式判断）
        const actualHdr = (videoFormat & StreamingSession.VIDEO_FORMAT_MASK_10BIT) !== 0;
        console.info(`视频设置: format=0x${videoFormat.toString(16)}, ${width}x${height}@${redrawRate}, HDR=${actualHdr}`);
        
        // 如果实际 HDR 状态与配置不同，更新配置并通知回调
        if (this.config && this.config.hdr !== actualHdr) {
          console.info(`HDR 状态更新: ${this.config.hdr} -> ${actualHdr}`);
          this.config.hdr = actualHdr;
        }
        
        // 通知 HDR 状态回调（无论是否变化都通知，确保初始状态正确）
        if (this.hdrStateCallback) {
          this.hdrStateCallback(actualHdr);
        }
      },
      drStart: (): void => {
        console.info('视频解码器启动');
      },
      drStop: (): void => {
        console.info('视频解码器停止');
      },
      drCleanup: (): void => {
        console.info('视频解码器清理');
      },
      arInit: (audioConfiguration: number, sampleRate: number, samplesPerFrame: number): void => {
        console.info(`音频初始化: config=${audioConfiguration}, rate=${sampleRate}, samples=${samplesPerFrame}`);
      },
      arStart: (): void => {
        console.info('音频渲染器启动');
      },
      arStop: (): void => {
        console.info('音频渲染器停止');
      },
      arCleanup: (): void => {
        console.info('音频渲染器清理');
      },
      clStageStarting: (stage: number): void => {
        console.info(`连接阶段开始: ${stage}`);
      },
      clStageComplete: (stage: number): void => {
        console.info(`连接阶段完成: ${stage}`);
      },
      clStageFailed: (stage: number, errorCode: number): void => {
        console.error(`连接阶段失败: stage=${stage}, error=${errorCode}`);
      },
      clConnectionStarted: (): void => {
        console.info('连接已建立');
        this.isRunning = true;
        // 启动麦克风（如果启用且主机请求）
        this.startMicrophoneIfNeeded();
      },
      clConnectionTerminated: (errorCode: number): void => {
        console.info(`连接已终止: ${errorCode}`);
        this.isRunning = false;
        // 停止麦克风
        this.stopMicrophone();
      },
      clConnectionStatusUpdate: (connectionStatus: number): void => {
        console.info(`连接状态更新: ${connectionStatus}`);
      },
      setHdrMode: (enabled: boolean): void => {
        console.info(`HDR 模式变化通知: ${enabled}`);
        // 更新配置中的 HDR 状态
        if (this.config && this.config.hdr !== enabled) {
          console.info(`HDR 状态更新: ${this.config.hdr} -> ${enabled}`);
          this.config.hdr = enabled;
        }
        // 通知 HDR 状态回调
        if (this.hdrStateCallback) {
          this.hdrStateCallback(enabled);
        }
      },
      rumble: (controllerNumber: number, lowFreqMotor: number, highFreqMotor: number): void => {
        // 将服务器发送的震动命令传递给 GamepadManager
        console.info(`收到震动回调: controller=${controllerNumber}, low=${lowFreqMotor}, high=${highFreqMotor}`);
        GamepadManager.getInstance().handleRumble(controllerNumber, lowFreqMotor, highFreqMotor);
      }
    };
    
    this.nativeModule.init(callbacks);
  }

  /**
   * 设置视频 Surface
   */
  private async setupVideoSurface(): Promise<void> {
    console.info(`设置视频 Surface: ${this.surfaceId}`);
    
    const success = this.nativeModule.setVideoSurface(this.surfaceId);
    if (!success) {
      throw new Error('设置视频 Surface 失败');
    }
  }

  /**
   * 启动应用
   */
  private async launchApp(): Promise<void> {
    if (!this.nvHttp || !this.config || !this.riKey) {
      throw new Error('启动应用前提条件不满足');
    }
    
    console.info(`启动应用: appId=${this.appId}`);
    
    // 将 riKey 转换为十六进制字符串
    const riKeyArray = new Uint8Array(this.riKey);
    const riKeyHex = Array.from(riKeyArray)
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');
    
    // 检查是否可以启用 HDR
    // HDR 需要 HEVC 或 AV1 解码器支持，H.264 不支持 HDR
    let effectiveHdr = this.config.hdr;
    if (effectiveHdr) {
      try {
        const capabilities = StreamingSession.getDecoderCapabilities();
        // 只有 HEVC 或 AV1 支持 HDR
        if (!capabilities.supportsHEVC && !capabilities.supportsAV1) {
          console.warn('设备不支持 HEVC/AV1 解码器，自动禁用 HDR（H.264 不支持 HDR）');
          effectiveHdr = false;
        }
      } catch (err) {
        console.warn('获取解码器能力失败，禁用 HDR');
        effectiveHdr = false;
      }
    }
    // 更新 config.hdr 以确保性能覆盖层显示正确的 HDR 状态
    if (this.config.hdr !== effectiveHdr) {
      console.info(`HDR 状态已调整: ${this.config.hdr} -> ${effectiveHdr}`);
      this.config.hdr = effectiveHdr;
    }
    
    const launchConfig: LaunchConfig = {
      appId: this.appId,
      width: this.config.width,
      height: this.config.height,
      fps: this.config.fps,
      bitrate: this.config.bitrate,
      sops: this.config.sops,  // 使用配置中的 SOPS 设置
      localAudio: this.config.playLocalAudio,  // 使用配置中的本地音频设置
      riKey: riKeyHex,
      riKeyId: this.riKeyId,
      audioConfig: getSurroundAudioInfo(this.config.audioConfig).toString(),  // 转换为 surroundAudioInfo 格式
      enableHdr: effectiveHdr,
      hdrMode: effectiveHdr ? this.config.hdrMode : HdrMode.SDR,  // 0=SDR, 1=HDR10, 2=HLG
      displayGuid: this.displayGuid  // Sunshine 显示器选择
    };
    
    try {
      // 首先检查是否有游戏正在运行
      const serverInfo = await this.nvHttp.getServerInfo();
      const currentGame = serverInfo.currentGame;
      
      console.info(`当前运行的游戏 ID: ${currentGame}, 目标应用 ID: ${this.appId}`);
      
      if (currentGame !== 0) {
        // 有游戏正在运行
        if (currentGame === this.appId) {
          // 同一个游戏，尝试 resume
          console.info('同一应用正在运行，尝试恢复会话...');
          try {
            this.rtspSessionUrl = await this.nvHttp.resumeApp(launchConfig);
            console.info(`恢复会话成功, sessionUrl=${this.rtspSessionUrl}`);
            return;
          } catch (resumeErr) {
            console.warn(`恢复会话失败: ${(resumeErr as Error).message}，尝试重新启动...`);
            // resume 失败，尝试 quit 后重新 launch
          }
        }
        
        // 不同游戏或 resume 失败，需要先退出当前游戏
        console.info('正在退出当前运行的应用...');
        const quitSuccess = await this.nvHttp.quitApp();
        if (!quitSuccess) {
          throw new Error('无法退出当前运行的应用，请在 PC 上手动退出');
        }
        console.info('当前应用已退出');
      }
      
      // 启动应用
      this.rtspSessionUrl = await this.nvHttp.launchApp(this.appId, launchConfig);
      console.info(`应用启动成功, sessionUrl=${this.rtspSessionUrl}`);
    } catch (err) {
      throw new Error(`启动应用失败: ${(err as Error).message}`);
    }
  }

  /**
   * 连接到串流服务器
   */
  private async connectToServer(): Promise<void> {
    console.info('连接到服务器');
    
    if (!this.config || !this.computer || !this.riKey) {
      throw new Error('配置未设置');
    }
    
    // 获取解码器能力，确定客户端支持的所有编解码格式
    let supportedVideoFormats = 0x0001; // H.264 总是支持
    let actualCodec: 'H.264' | 'HEVC' = this.config.codec;
    
    try {
      const capabilities = StreamingSession.getDecoderCapabilities();
      console.info(`解码器能力: H264=${capabilities.supportsH264}, HEVC=${capabilities.supportsHEVC}, AV1=${capabilities.supportsAV1}`);
      
      // 构建 supportedVideoFormats 位掩码（包含所有支持的格式）
      if (capabilities.supportsHEVC) {
        supportedVideoFormats |= 0x0100; // H.265 (HEVC)
        if (this.config.hdr) {
          supportedVideoFormats |= 0x0200; // H.265 MAIN10 (HDR)
        }
      }
      if (capabilities.supportsAV1) {
        supportedVideoFormats |= 0x1000; // AV1 MAIN8
        if (this.config.hdr) {
          supportedVideoFormats |= 0x2000; // AV1 MAIN10 (HDR)
        }
      }
      
      // 如果用户选择了 HEVC 但设备不支持，降级到 H.264
      if (this.config.codec === 'HEVC' && !capabilities.supportsHEVC) {
        console.warn('设备不支持 HEVC 解码，降级到 H.264');
        actualCodec = 'H.264';
      }
    } catch (err) {
      console.warn(`获取解码器能力失败，使用默认 H.264: ${(err as Error).message}`);
      actualCodec = 'H.264';
      supportedVideoFormats = 0x0001; // 只支持 H.264
    }
    
    console.info(`实际使用的编解码器: ${actualCodec} (配置: ${this.config.codec})`);
    console.info(`supportedVideoFormats: 0x${supportedVideoFormats.toString(16)}`);
    
    // 生成 IV：前4字节是 riKeyId（大端序），后12字节是0
    // 这与 moonlight-android 的实现一致
    const riAesIv = new ArrayBuffer(16);
    const ivView = new DataView(riAesIv);
    ivView.setUint32(0, this.riKeyId, false); // 大端序（Big Endian）
    // 后12字节自动为0
    
    console.info(`连接参数: address=${this.computer.address}, appVersion=${this.serverAppVersion}, gfeVersion=${this.serverGfeVersion}, sessionUrl=${this.rtspSessionUrl}`);
    console.info(`音频配置: audioConfig=${this.config.audioConfig.toString(16)}`);
    
    // 设置解码器缓冲区数量（在开始连接之前）
    this.nativeModule.setDecoderBufferCount(this.config.decoderBufferCount);
    console.info(`解码器缓冲区数量: ${this.config.decoderBufferCount}`);
    
    // 设置同步解码模式（API 20+，减少回调延迟）
    this.nativeModule.setDecoderSyncMode(this.config.enableSyncDecode);
    console.info(`同步解码模式: ${this.config.enableSyncDecode ? '启用 (低延迟)' : '禁用 (异步)'}`);
    
    // 设置 VSync 渲染模式
    this.nativeModule.setVsyncEnabled(this.config.enableVsync);
    console.info(`VSync 渲染模式: ${this.config.enableVsync ? '启用' : '禁用'}`);
    
    // 设置 VRR 可变刷新率模式
    this.nativeModule.setVrrEnabled(this.config.enableVrr);
    console.info(`VRR 可变刷新率: ${this.config.enableVrr ? '启用' : '禁用'}`);
    
    const result = this.nativeModule.startConnection(
      this.computer.address,
      this.serverAppVersion,
      this.serverGfeVersion,
      this.rtspSessionUrl,
      this.serverCodecModeSupport,
      this.config.width,
      this.config.height,
      this.config.fps,
      this.config.bitrate, // 单位是 kbps，与 moonlight-common-c 一致
      1392, // packetSize - 与 Android 一致
      0, // streamingRemotely (0=local, 1=remote)
      this.config.audioConfig, // audioConfiguration - 使用 MAKE_AUDIO_CONFIGURATION 格式
      supportedVideoFormats, // 包含所有支持格式的位掩码
      this.config.clientRefreshRateX100, // clientRefreshRateX100 - 支持 NTSC 帧率如 119.88 Hz (11988)
      this.riKey,
      riAesIv,
      0x01 | 0x02, // videoCapabilities: CAPABILITY_DIRECT_SUBMIT | CAPABILITY_RFI_AVC
      this.config.hdr ? 2 : 1, // colorSpace: HDR 使用 REC_2020 (2), SDR 使用 REC_709 (1)
      this.config.colorRange, // colorRange: 来自配置 (0=LIMITED, 1=FULL)
      this.config.hdr ? this.config.hdrMode : HdrMode.SDR, // hdrMode: 只有启用 HDR 时才发送实际 HDR 模式
      this.config.microphoneEnabled, // enableMic
      false  // controlOnly
    );
    
    if (result !== 0) {
      throw new Error(`连接失败，错误码: ${result}`);
    }
  }

  /**
   * 发送键盘输入
   * @param keyCode Windows 虚拟键码
   * @param keyAction 按键动作：0x03 = KEY_DOWN, 0x04 = KEY_UP
   * @param modifiers 修饰键掩码：SHIFT=0x01, CTRL=0x02, ALT=0x04, META=0x08
   */
  sendKeyboardInput(keyCode: number, keyAction: number, modifiers: number = 0): void {
    if (!this.isRunning) {
      console.warn('无法发送键盘输入：串流未运行');
      return;
    }
    this.nativeModule.sendKeyboardInput(keyCode, keyAction, modifiers, 0);
  }

  /**
   * 发送按键序列（按下所有键，然后释放）
   * @param keyCodes Windows 虚拟键码数组
   */
  sendKeys(keyCodes: number[]): void {
    if (!this.isRunning || keyCodes.length === 0) {
      return;
    }

    const KEY_DOWN = 0x03;
    const KEY_UP = 0x04;

    // 修饰键定义
    const VK_SHIFT = 0x10;
    const VK_CONTROL = 0x11;
    const VK_MENU = 0x12;  // Alt
    const VK_LWIN = 0x5B;

    const MODIFIER_SHIFT = 0x01;
    const MODIFIER_CTRL = 0x02;
    const MODIFIER_ALT = 0x04;
    const MODIFIER_META = 0x08;

    // 计算修饰键掩码
    const getModifier = (key: number): number => {
      switch (key) {
        case VK_SHIFT: return MODIFIER_SHIFT;
        case VK_CONTROL: return MODIFIER_CTRL;
        case VK_MENU: return MODIFIER_ALT;
        case VK_LWIN: return MODIFIER_META;
        default: return 0;
      }
    };

    let modifier = 0;

    // 按下所有键
    for (const key of keyCodes) {
      this.nativeModule.sendKeyboardInput(key, KEY_DOWN, modifier, 0);
      modifier |= getModifier(key);
    }

    // 延迟后释放所有键（从后往前）
    setTimeout(() => {
      for (let i = keyCodes.length - 1; i >= 0; i--) {
        const key = keyCodes[i];
        modifier &= ~getModifier(key);
        this.nativeModule.sendKeyboardInput(key, KEY_UP, modifier, 0);
      }
    }, 25);
  }

  // ==========================================================================
  // 麦克风相关方法
  // ==========================================================================

  /**
   * 检查并启动麦克风（如果配置启用且主机请求）
   */
  private startMicrophoneIfNeeded(): void {
    if (!this.config?.microphoneEnabled) {
      console.info('麦克风未启用，跳过');
      return;
    }

    // 检查主机是否请求麦克风
    if (!MoonBridge.isMicrophoneRequested()) {
      console.info('主机未请求麦克风，跳过');
      return;
    }

    console.info('启动麦克风...');
    this.microphoneStream = new MicrophoneStream(MoonBridge);

    // 异步启动麦克风
    this.microphoneStream.start().then((success: boolean) => {
      if (success) {
        console.info('麦克风启动成功');
      } else {
        console.error('麦克风启动失败');
        this.microphoneStream = null;
      }
    }).catch((error: Error) => {
      console.error(`麦克风启动异常: ${error.message}`);
      this.microphoneStream = null;
    });
  }

  /**
   * 停止麦克风
   */
  private stopMicrophone(): void {
    if (this.microphoneStream) {
      console.info('停止麦克风...');
      this.microphoneStream.stop().then(() => {
        console.info('麦克风已停止');
      }).catch((error: Error) => {
        console.warn(`停止麦克风时出错: ${error.message}`);
      });
      this.microphoneStream = null;
    }
  }

  /**
   * 清理资源
   */
  private async cleanup(): Promise<void> {
    console.info('清理串流资源');
    
    // 停止麦克风
    this.stopMicrophone();
    
    // 重置性能模式
    this.nativeModule.setPerformanceModeEnabled(false);
    
    try {
      this.nativeModule.stopConnection();
      this.nativeModule.releaseVideoSurface();
    } catch (err) {
      console.error('清理资源失败:', err);
    }
  }
}
