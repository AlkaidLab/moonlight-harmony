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
 * 串流页面 ViewModel
 * 
 * 管理串流相关的状态、配置和业务逻辑
 */
import { StreamConfig, getDefaultStreamConfig } from '../model/StreamConfig';
import { SettingsService, InputSettings, DisplaySettings } from '../service/SettingsService';
import { StreamingSession, StreamStats } from '../service/StreamingSession';
import { InputEvent } from '../model/InputEvent';
import { OverlayConfig, PerformanceData, getDefaultOverlayConfig, SnapPosition, calculateSnapPosition } from '../components/PerformanceOverlayManager';
import { GamepadManager } from '../service/GamepadManager';
import { batteryInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

/**
 * 串流连接状态
 */
export enum StreamConnectionState {
  IDLE = 'idle',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  ERROR = 'error',
  DISCONNECTED = 'disconnected'
}

/**
 * 触摸输入模式
 */
export enum TouchMode {
  TRACKPAD = 'trackpad',
  DIRECT = 'direct',
  MOUSE = 'mouse'
}

/**
 * 性能统计数据
 */
@Observed
export class PerformanceStats {
  fps: number = 0;               // 接收帧率 (Rx)
  renderedFps: number = 0;       // 渲染帧率 (Rd)
  bitrate: number = 0;
  latency: number = 0;
  packetLoss: number = 0;
  decodedFrames: number = 0;
  droppedFrames: number = 0;
  networkLatency: number = 0;
  hostLatency: number = 0;
  batteryLevel: number = 100;
  isCharging: boolean = false;
}

/**
 * 屏幕/视频尺寸信息
 */
@Observed
export class DisplayInfo {
  screenWidth: number = 1920;
  screenHeight: number = 1080;
  streamWidth: number = 1920;
  streamHeight: number = 1080;
  xComponentWidth: Length = '100%';
  xComponentHeight: Length = '100%';
  stretchVideo: boolean = false;
}

/**
 * 覆盖层状态
 */
@Observed
export class OverlayState {
  config: OverlayConfig = getDefaultOverlayConfig();
  x: number = 0;
  y: number = 8;
  opacity: number = 1.0;
  scale: number = 1.0;
  width: number = 200;
  height: number = 200;
  isDragging: boolean = false;
  dragStartX: number = 0;
  dragStartY: number = 0;
  moveDistance: number = 0;
  clickStartTime: number = 0;
  lastClickTime: number = 0;
}

/**
 * StreamViewModel - 串流页面状态管理
 */
@Observed
export class StreamViewModel {
  // 连接状态
  connectionState: StreamConnectionState = StreamConnectionState.IDLE;
  errorMessage: string = '';
  
  // 性能统计
  performanceStats: PerformanceStats = new PerformanceStats();
  
  // 显示信息
  displayInfo: DisplayInfo = new DisplayInfo();
  
  // 覆盖层状态
  overlayState: OverlayState = new OverlayState();
  
  // 配置
  streamConfig: StreamConfig | null = null;
  inputSettings: InputSettings | null = null;
  displaySettings: DisplaySettings | null = null;
  
  // 触摸模式
  touchMode: TouchMode = TouchMode.TRACKPAD;
  
  // 实际 HDR 状态（从 drSetup 回调获取，用于 UI 显示）
  actualHdr: boolean = false;
  
  // UI 显示控制
  showOverlay: boolean = false;
  showController: boolean = false;
  
  // 私有服务
  private settingsService: SettingsService = SettingsService.getInstance();
  private streamingSession: StreamingSession | null = null;
  private statsTimer: number = -1;
  private batteryTimer: number = -1;
  
  // 便捷属性
  get isConnecting(): boolean {
    return this.connectionState === StreamConnectionState.CONNECTING;
  }
  
  get isConnected(): boolean {
    return this.connectionState === StreamConnectionState.CONNECTED;
  }
  
  get hasError(): boolean {
    return this.connectionState === StreamConnectionState.ERROR;
  }
  
  /**
   * 加载设置
   */
  async loadSettings(): Promise<void> {
    this.streamConfig = await this.settingsService.getStreamConfig();
    this.inputSettings = await this.settingsService.getInputSettings();
    this.displaySettings = await this.settingsService.getDisplaySettings();
    
    // 更新 UI 显示选项
    this.showOverlay = this.displaySettings.enablePerfOverlay;
    this.showController = this.inputSettings.enableOnscreenControls;
    this.displayInfo.stretchVideo = this.displaySettings.stretchVideo;
    
    // 配置覆盖层
    this.overlayState.config.isVertical = this.displaySettings.perfOverlayOrientation === '垂直';
    this.overlayState.config.isLocked = this.displaySettings.perfOverlayLocked || false;
    
    // 加载启用的项目
    if (this.displaySettings.perfOverlayItems) {
      this.overlayState.config.enabledItems = new Set(this.displaySettings.perfOverlayItems);
    }
    
    // 加载覆盖层位置
    this.overlayState.config.position = this.parseOverlayPosition(this.displaySettings.perfOverlayPosition);
    
    // 更新串流尺寸
    this.displayInfo.streamWidth = this.streamConfig.width;
    this.displayInfo.streamHeight = this.streamConfig.height;
    
    // 确定触摸模式
    if (this.inputSettings.absoluteMouseMode) {
      this.touchMode = TouchMode.DIRECT;
    } else if (this.inputSettings.touchscreenTrackpad) {
      this.touchMode = TouchMode.TRACKPAD;
    } else if (this.inputSettings.mouseEmulation) {
      this.touchMode = TouchMode.MOUSE;
    }
    
    console.info(`StreamViewModel: 配置加载完成 - ${this.streamConfig.width}x${this.streamConfig.height}@${this.streamConfig.fps}fps`);
    console.info(`StreamViewModel: 触摸模式=${this.touchMode}, 性能覆盖层=${this.showOverlay}, 虚拟控制器=${this.showController}`);
    
    // 配置震动设置
    const deviceVibrateEnabled = this.streamConfig.enableVibration && this.streamConfig.vibrateFallbackStrength > 0;
    GamepadManager.getInstance().setDeviceVibrate(
      deviceVibrateEnabled,
      this.streamConfig.vibrateFallbackStrength,
      this.streamConfig.vibrationMode
    );
  }
  
  /**
   * 开始串流
   */
  async startStreaming(
    computerId: string, 
    appId: number, 
    surfaceId: string, 
    context: common.UIAbilityContext,
    displayGuid?: string,
    useVdd?: boolean
  ): Promise<void> {
    this.connectionState = StreamConnectionState.CONNECTING;
    this.errorMessage = '';
    
    try {
      await this.loadSettings();
      
      // 初始化 actualHdr 状态为用户请求的 HDR 状态
      this.actualHdr = this.streamConfig?.hdr || false;
      
      // 创建串流会话
      this.streamingSession = new StreamingSession();
      
      // 设置 HDR 状态回调，当 drSetup 检测到实际 HDR 状态时更新 UI
      this.streamingSession.setHdrStateCallback((isHdr: boolean) => {
        console.info(`StreamViewModel: HDR 状态回调 actualHdr=${isHdr}`);
        this.actualHdr = isHdr;
      });
      
      await this.streamingSession.start(computerId, appId, this.streamConfig!, surfaceId, context, displayGuid, useVdd);
      
      // 同步实际使用的配置（可能与初始配置不同，例如 HDR 因设备不支持被禁用）
      const effectiveConfig = this.streamingSession.getEffectiveConfig();
      if (effectiveConfig) {
        // 更新关键配置项以确保 UI 显示正确
        if (this.streamConfig!.hdr !== effectiveConfig.hdr) {
          console.info(`StreamViewModel: HDR 状态同步 ${this.streamConfig!.hdr} -> ${effectiveConfig.hdr}`);
          this.streamConfig!.hdr = effectiveConfig.hdr;
        }
        if (this.streamConfig!.codec !== effectiveConfig.codec) {
          console.info(`StreamViewModel: Codec 状态同步 ${this.streamConfig!.codec} -> ${effectiveConfig.codec}`);
          this.streamConfig!.codec = effectiveConfig.codec;
        }
      }
      
      this.connectionState = StreamConnectionState.CONNECTED;
      
      // 性能监控现在由 StreamPage 组件直接处理，避免创建新对象的开销
      // this.startPerformanceMonitoring();
      
    } catch (err) {
      this.connectionState = StreamConnectionState.ERROR;
      const error = err as Error;
      this.errorMessage = `连接失败: ${error.message}`;
      throw error;
    }
  }
  
  /**
   * 停止串流
   */
  async stopStreaming(): Promise<void> {
    // 停止监控定时器
    this.stopPerformanceMonitoring();
    
    // 重置旋转状态
    this.resetRotationState();
    
    // 停止串流会话
    if (this.streamingSession) {
      await this.streamingSession.stop();
      this.streamingSession = null;
    }
    
    this.connectionState = StreamConnectionState.DISCONNECTED;
  }
  
  /**
   * 发送输入
   */
  sendInput(input: InputEvent): void {
    this.streamingSession?.sendInput(input);
  }

  /**
   * 发送手柄完整状态（用于物理手柄输入）
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
    this.streamingSession?.sendGamepadState(
      controllerIndex,
      buttons,
      leftStickX,
      leftStickY,
      rightStickX,
      rightStickY,
      leftTrigger,
      rightTrigger
    );
  }
  
  /**
   * 获取串流会话
   */
  getSession(): StreamingSession | null {
    return this.streamingSession;
  }
  
  /**
   * 开始性能监控
   */
  private startPerformanceMonitoring(): void {
    // 停止之前的定时器
    this.stopPerformanceMonitoring();
    
    console.info('StreamViewModel: 开始性能监控');
    
    // 性能统计每秒更新
    this.statsTimer = setInterval(() => {
      this.updatePerformanceStats();
    }, 1000);
    
    // 电池信息每15秒更新
    this.updateBatteryInfo();
    this.batteryTimer = setInterval(() => {
      this.updateBatteryInfo();
    }, 15000);
  }
  
  /**
   * 停止性能监控
   */
  private stopPerformanceMonitoring(): void {
    if (this.statsTimer !== -1) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
    
    if (this.batteryTimer !== -1) {
      clearInterval(this.batteryTimer);
      this.batteryTimer = -1;
    }
  }
  
  /**
   * 更新性能统计
   */
  private updatePerformanceStats(): void {
    if (this.streamingSession) {
      const stats = this.streamingSession.getStats();
      
      // 创建新的 PerformanceStats 对象来触发 UI 更新
      const newStats = new PerformanceStats();
      newStats.fps = stats.fps;
      newStats.renderedFps = stats.renderedFps;
      newStats.bitrate = stats.bitrate;
      newStats.latency = stats.latency;
      newStats.hostLatency = stats.hostLatency;
      newStats.networkLatency = stats.networkLatency;
      newStats.packetLoss = stats.packetLoss;
      newStats.decodedFrames = stats.decodedFrames;
      newStats.droppedFrames = stats.droppedFrames;
      // 保留电池信息
      newStats.batteryLevel = this.performanceStats.batteryLevel;
      newStats.isCharging = this.performanceStats.isCharging;
      
      this.performanceStats = newStats;
    }
  }
  
  /**
   * 更新电池信息
   */
  private updateBatteryInfo(): void {
    try {
      // 创建新对象来触发 UI 更新
      const newStats = new PerformanceStats();
      newStats.fps = this.performanceStats.fps;
      newStats.renderedFps = this.performanceStats.renderedFps;
      newStats.bitrate = this.performanceStats.bitrate;
      newStats.latency = this.performanceStats.latency;
      newStats.hostLatency = this.performanceStats.hostLatency;
      newStats.networkLatency = this.performanceStats.networkLatency;
      newStats.packetLoss = this.performanceStats.packetLoss;
      newStats.decodedFrames = this.performanceStats.decodedFrames;
      newStats.droppedFrames = this.performanceStats.droppedFrames;
      newStats.batteryLevel = batteryInfo.batterySOC;
      newStats.isCharging = 
        batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE ||
        batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL;
      
      this.performanceStats = newStats;
    } catch (err) {
      console.warn('获取电池信息失败:', err);
    }
  }
  
  /**
   * 将设置中的位置字符串转换为 SnapPosition
   */
  private parseOverlayPosition(positionStr: string): SnapPosition {
    switch (positionStr) {
      case '顶部':
        return SnapPosition.TOP_CENTER;
      case '底部':
        return SnapPosition.BOTTOM_CENTER;
      case '左上角':
        return SnapPosition.TOP_LEFT;
      case '右上角':
        return SnapPosition.TOP_RIGHT;
      case '左下角':
        return SnapPosition.BOTTOM_LEFT;
      case '右下角':
        return SnapPosition.BOTTOM_RIGHT;
      default:
        return SnapPosition.TOP_RIGHT;
    }
  }
  
  /**
   * 初始化覆盖层位置
   */
  initOverlayPosition(): void {
    const snapPos = calculateSnapPosition(
      this.overlayState.config.position,
      this.displayInfo.screenWidth,
      this.displayInfo.screenHeight,
      this.overlayState.width,
      this.overlayState.height
    );
    this.overlayState.x = snapPos.x;
    this.overlayState.y = snapPos.y;
    
    console.info(`StreamViewModel: 覆盖层初始位置 (${this.overlayState.x}, ${this.overlayState.y})`);
  }
  
  /**
   * 设置触摸模式
   */
  setTouchMode(mode: TouchMode): void {
    this.touchMode = mode;
    console.info(`StreamViewModel: 触摸模式切换为 ${mode}`);
  }
  
  /**
   * 切换性能监控覆盖层显示
   */
  toggleOverlay(): void {
    this.showOverlay = !this.showOverlay;
    console.info(`StreamViewModel: 性能覆盖层 ${this.showOverlay ? '显示' : '隐藏'}`);
  }
  
  /**
   * 切换虚拟控制器显示
   */
  toggleController(): void {
    this.showController = !this.showController;
    console.info(`StreamViewModel: 虚拟控制器 ${this.showController ? '显示' : '隐藏'}`);
  }
  
  /**
   * 切换覆盖层布局方向
   */
  toggleOverlayLayout(): void {
    this.overlayState.config.isVertical = !this.overlayState.config.isVertical;
  }
  
  /**
   * 退出远程游戏
   * 调用服务器 API 退出当前运行的游戏并停止串流
   */
  async quitGame(): Promise<void> {
    // 停止监控定时器
    this.stopPerformanceMonitoring();
    
    // 调用 StreamingSession 的 quitApp 方法退出远程游戏
    try {
      if (this.streamingSession) {
        const success = await this.streamingSession.quitApp();
        if (success) {
          console.info('远程游戏已退出');
        } else {
          console.warn('退出远程游戏失败，但已断开连接');
        }
        this.streamingSession = null;
      }
    } catch (err) {
      console.error('退出游戏失败:', err);
    }
    
    this.connectionState = StreamConnectionState.DISCONNECTED;
  }
  
  /**
   * 动态调整码率
   * @param bitrateKbps 目标码率（kbps）
   * @returns 是否成功
   */
  async setBitrate(bitrateKbps: number): Promise<boolean> {
    if (!this.streamingSession) {
      return false;
    }
    
    const success = await this.streamingSession.setBitrate(bitrateKbps);
    if (success && this.streamConfig) {
      this.streamConfig.bitrate = bitrateKbps;
    }
    return success;
  }
  
  /**
   * 发送超级指令 (Sunshine 功能)
   * @param cmdId 指令 ID
   * @returns 是否成功
   */
  async sendSuperCmd(cmdId: string): Promise<boolean> {
    if (!this.streamingSession) {
      return false;
    }
    return await this.streamingSession.sendSuperCmd(cmdId);
  }
  
  // ==================== 屏幕旋转同步 ====================
  
  // 旋转同步相关状态
  private lastRotation: number = -1;  // 上一次的方向：-1=未初始化，0=竖屏，1=横屏
  private isServerInitiatedRotation: boolean = false;  // 是否是服务器触发的旋转
  private pendingRotationTimeoutId: number = -1;  // 待处理的旋转定时器ID
  private static readonly ROTATION_DEBOUNCE_MS: number = 3000;  // 3秒防抖
  
  /**
   * 设置是否是服务器触发的旋转
   * 当收到服务器的分辨率变化通知时调用，避免循环通知
   */
  setServerInitiatedRotation(value: boolean): void {
    this.isServerInitiatedRotation = value;
    if (value) {
      console.info('StreamViewModel: 标记为服务器触发的旋转');
    }
  }
  
  /**
   * 处理屏幕方向变化
   * 当设备屏幕旋转时调用此方法，通知服务器同步修改分辨率
   * 
   * @param isLandscape 是否为横屏
   */
  handleRotationChange(isLandscape: boolean): void {
    // 检查是否启用了屏幕旋转同步
    if (!this.displaySettings?.rotableScreen) {
      console.info('StreamViewModel: 屏幕旋转同步未启用');
      return;
    }
    
    // 检查是否是服务器触发的旋转，避免循环通知
    if (this.isServerInitiatedRotation) {
      console.info('StreamViewModel: 跳过服务器触发的旋转');
      this.isServerInitiatedRotation = false;
      return;
    }
    
    // 检查连接状态
    if (!this.isConnected || !this.streamingSession) {
      console.warn('StreamViewModel: handleRotationChange - 连接未就绪');
      return;
    }
    
    const currentOrientation = isLandscape ? 1 : 0;
    
    // 首次调用，记录当前方向
    if (this.lastRotation === -1) {
      this.lastRotation = currentOrientation;
      console.info(`StreamViewModel: 初始化旋转方向=${currentOrientation}`);
      return;
    }
    
    // 方向未变化
    if (currentOrientation === this.lastRotation) {
      return;
    }
    
    // 记录新的方向
    this.lastRotation = currentOrientation;
    const angle = isLandscape ? 0 : 90;
    
    console.info(`StreamViewModel: 检测到旋转变化 isLandscape=${isLandscape}, angle=${angle}`);
    
    // 取消之前待处理的旋转请求（防抖）
    if (this.pendingRotationTimeoutId !== -1) {
      clearTimeout(this.pendingRotationTimeoutId);
    }
    
    // 延迟发送旋转请求（3秒防抖）
    this.pendingRotationTimeoutId = setTimeout(async () => {
      console.info(`StreamViewModel: 通知服务器旋转，angle=${angle}`);
      
      try {
        const success = await this.streamingSession?.rotateDisplay(angle);
        if (success) {
          console.info(`StreamViewModel: 服务器旋转成功，角度=${angle}`);
        } else {
          console.warn('StreamViewModel: 服务器旋转失败');
        }
      } catch (err) {
        console.error(`StreamViewModel: 旋转请求异常: ${err}`);
      }
      
      this.pendingRotationTimeoutId = -1;
    }, StreamViewModel.ROTATION_DEBOUNCE_MS) as number;
  }
  
  /**
   * 检查并同步屏幕方向
   * 当收到服务器分辨率变化时调用，检查客户端和服务端方向是否一致
   * 
   * @param serverWidth 服务器分辨率宽度
   * @param serverHeight 服务器分辨率高度
   * @param clientIsLandscape 客户端当前是否为横屏
   */
  checkAndSyncOrientation(serverWidth: number, serverHeight: number, clientIsLandscape: boolean): void {
    // 检查是否启用了屏幕旋转同步
    if (!this.displaySettings?.rotableScreen) {
      return;
    }
    
    const serverIsLandscape = serverWidth > serverHeight;
    
    console.info(`StreamViewModel: checkAndSyncOrientation - 客户端=${clientIsLandscape ? '横屏' : '竖屏'}, ` +
      `服务端=${serverWidth}x${serverHeight}(${serverIsLandscape ? '横屏' : '竖屏'})`);
    
    if (clientIsLandscape !== serverIsLandscape) {
      console.info('StreamViewModel: 方向不匹配，通知服务器同步');
      this.handleRotationChange(clientIsLandscape);
    } else {
      console.info('StreamViewModel: 方向匹配');
      // 初始化上次旋转方向
      if (this.lastRotation === -1) {
        this.lastRotation = clientIsLandscape ? 1 : 0;
      }
    }
  }
  
  /**
   * 重置旋转状态
   * 在串流结束时调用
   */
  private resetRotationState(): void {
    this.lastRotation = -1;
    this.isServerInitiatedRotation = false;
    if (this.pendingRotationTimeoutId !== -1) {
      clearTimeout(this.pendingRotationTimeoutId);
      this.pendingRotationTimeoutId = -1;
    }
  }
  
  /**
   * 获取当前码率
   */
  getCurrentBitrate(): number {
    return this.streamingSession?.getCurrentBitrate() || this.streamConfig?.bitrate || 0;
  }
  
  /**
   * 获取当前性能数据（用于详情弹窗）
   */
  getPerformanceData(): PerformanceData {
    const data = new PerformanceData();
    data.streamWidth = this.displayInfo.streamWidth;
    data.streamHeight = this.displayInfo.streamHeight;
    data.targetFps = this.streamConfig?.fps || 60;
    data.receivedFps = this.performanceStats.fps;
    data.renderedFps = this.performanceStats.renderedFps;
    data.codec = this.streamConfig?.codec || 'HEVC';
    data.isHdr = this.streamConfig?.hdr || false;
    data.packetLoss = this.performanceStats.packetLoss;
    data.bitrate = this.performanceStats.bitrate;
    data.decodeLatency = this.performanceStats.latency;
    data.networkLatency = this.performanceStats.networkLatency;
    data.hostLatency = this.performanceStats.hostLatency;
    data.batteryLevel = this.performanceStats.batteryLevel;
    data.isCharging = this.performanceStats.isCharging;
    return data;
  }
  
  /**
   * 从后台恢复串流
   * 当应用从后台切回前台时调用此方法
   */
  resumeFromBackground(): void {
    console.info('[StreamViewModel] 从后台恢复串流');
    
    if (!this.streamingSession) {
      console.warn('[StreamViewModel] 没有活跃的串流会话，无需恢复');
      return;
    }
    
    // 通知 native 层恢复解码和渲染
    try {
      this.streamingSession.resumeDecoder();
      console.info('[StreamViewModel] 解码器恢复成功');
    } catch (err) {
      console.error('[StreamViewModel] 恢复解码器失败:', err);
    }
  }
  
  /**
   * 清理资源
   */
  dispose(): void {
    this.stopPerformanceMonitoring();
    this.resetRotationState();
    if (this.streamingSession) {
      this.streamingSession.stop();
      this.streamingSession = null;
    }
  }
}
