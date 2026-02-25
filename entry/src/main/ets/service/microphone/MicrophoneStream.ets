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
 * 麦克风数据流
 * 整合麦克风捕获、Opus 编码和网络发送
 *
 * 使用 OHAudio C API 的 FAST 低时延模式，
 * 在 native 回调线程中直接完成 PCM 帧累积、Opus 编码和网络发送。
 */
import { MoonBridge, MoonBridgeClass } from '../MoonBridge';
import { MicrophoneConfig, MicrophoneState, MicrophoneStateListener } from './MicrophoneConfig';

const TAG = '[MicStream]';

/**
 * 麦克风数据流
 * 负责协调音频捕获、Opus 编码和网络发送
 *
 * 使用 native OHAudio C API 的 FAST 低时延模式，
 * 在 C++ 回调线程中直接完成帧累积、Opus 编码和网络发送。
 */
export class MicrophoneStream {
  private moonBridge: MoonBridgeClass;
  private running: boolean = false;
  private paused: boolean = false;
  private hostRequested: boolean = false;

  // 状态监听器
  private stateListener: MicrophoneStateListener | null = null;

  // 统计定时器
  private statsTimerId: number = -1;
  private lastLogTime: number = 0;
  
  constructor(moonBridge: MoonBridgeClass) {
    this.moonBridge = moonBridge;
    console.info(TAG, '初始化麦克风流');
  }
  
  /**
   * 设置状态监听器
   */
  setStateListener(listener: MicrophoneStateListener): void {
    this.stateListener = listener;
  }
  
  /**
   * 检查主机是否请求了麦克风
   */
  isMicrophoneAvailable(): boolean {
    return this.moonBridge.isMicrophoneRequested();
  }
  
  /**
   * 是否正在运行
   */
  isRunning(): boolean {
    return this.running && !this.paused;
  }
  
  /**
   * 启动麦克风流
   */
  async start(): Promise<boolean> {
    if (this.running) {
      console.info(TAG, '麦克风流已在运行');
      return true;
    }
    
    // 检查主机是否请求了麦克风
    if (!this.moonBridge.isMicrophoneRequested()) {
      console.info(TAG, '主机未请求麦克风');
      return false;
    }
    
    this.hostRequested = true;
    
    // 记录加密状态
    if (this.moonBridge.isMicrophoneEncryptionEnabled()) {
      console.info(TAG, '麦克风加密已启用');
    }
    
    return this.startMicrophoneCapture();
  }
  
  /**
   * 启动麦克风捕获
   * 使用 native 低时延麦克风采集器（OHAudio FAST 模式），
   * 在 C++ 回调线程中直接完成 Opus 编码和网络发送。
   */
  private async startMicrophoneCapture(): Promise<boolean> {
    if (this.running) {
      return true;
    }
    
    try {
      // 获取麦克风端口
      const micPort = this.moonBridge.getMicPortNumber();
      if (micPort === 0) {
        console.warn(TAG, '未获取到麦克风端口');
      } else {
        console.info(TAG, `使用麦克风端口: ${micPort}`);
      }
      
      // 启动 native 低时延采集器
      const bitrate = MicrophoneConfig.getOpusBitrate();
      console.info(TAG, `启动 native 麦克风: rate=${MicrophoneConfig.SAMPLE_RATE} ch=${MicrophoneConfig.CHANNELS} bitrate=${bitrate}`);

      const ret = this.moonBridge.nativeMicStart(
        MicrophoneConfig.SAMPLE_RATE,
        MicrophoneConfig.CHANNELS,
        bitrate
      );
      
      if (ret !== 0) {
        console.error(TAG, `启动 native 麦克风失败: ${ret}`);
        this.notifyError('启动低时延麦克风采集失败');
        return false;
      }
      
      this.running = true;
      this.paused = false;
      this.lastLogTime = Date.now();

      // 启动统计日志定时器
      this.startStatsTimer();

      this.notifyStateChanged(MicrophoneState.CAPTURING);
      console.info(TAG, '麦克风流已启动（native 低时延模式）');
      
      return true;
      
    } catch (error) {
      console.error(TAG, `启动麦克风捕获失败: ${error}`);
      this.moonBridge.nativeMicStop();
      this.notifyError(`启动麦克风捕获失败: ${error}`);
      return false;
    }
  }
  
  
  /**
   * 暂停麦克风流
   */
  async pause(): Promise<void> {
    if (!this.running || this.paused) {
      return;
    }

    this.paused = true;
    this.moonBridge.nativeMicPause();

    this.notifyStateChanged(MicrophoneState.PAUSED);
    console.info(TAG, '麦克风流已暂停');
  }
  
  /**
   * 恢复麦克风流
   */
  async resume(): Promise<void> {
    if (!this.running || !this.paused) {
      return;
    }
    
    this.moonBridge.nativeMicResume();
    this.paused = false;
    this.notifyStateChanged(MicrophoneState.CAPTURING);
    console.info(TAG, '麦克风流已恢复');
  }
  
  /**
   * 切换麦克风状态（暂停/恢复）
   */
  async toggle(): Promise<boolean> {
    if (!this.running) {
      // 如果未运行，尝试启动
      return this.start();
    }
    
    if (this.paused) {
      await this.resume();
    } else {
      await this.pause();
    }
    
    return !this.paused;
  }
  
  /**
   * 停止麦克风流
   */
  async stop(): Promise<void> {
    if (!this.running) {
      return;
    }

    console.info(TAG, '停止麦克风流');

    this.running = false;
    this.paused = false;

    // 停止统计定时器
    this.stopStatsTimer();

    // 停止 native 采集器（会释放 OHAudio capturer + Opus 编码器）
    this.moonBridge.nativeMicStop();

    this.notifyStateChanged(MicrophoneState.STOPPED);
    console.info(TAG, '麦克风流已停止');
  }

  /**
   * 清理资源（内部使用，在初始化失败时调用）
   */
  private async cleanup(): Promise<void> {
    this.moonBridge.nativeMicStop();
    this.stopStatsTimer();
    this.running = false;
    this.paused = false;
  }

  /**
   * 启动统计定时器
   * 每 10 秒从 native 层获取统计信息并记录日志
   */
  private startStatsTimer(): void {
    this.stopStatsTimer();
    this.statsTimerId = setInterval(() => {
      if (!this.running) {
        this.stopStatsTimer();
        return;
      }
      try {
        const stats = this.moonBridge.nativeMicGetStats();
        if (stats) {
          console.info(TAG,
            `麦克风统计: 已采集=${stats.captured}, 已编码=${stats.encoded}, ` +
            `已发送=${stats.sent}, 丢弃=${stats.dropped}, ` +
            `速率=${(stats.sent / 10).toFixed(1)} pps`);
        }
      } catch (e) {
        console.warn(TAG, `获取麦克风统计失败: ${e}`);
      }
    }, 10000);
  }

  /**
   * 停止统计定时器
   */
  private stopStatsTimer(): void {
    if (this.statsTimerId !== -1) {
      clearInterval(this.statsTimerId);
      this.statsTimerId = -1;
    }
  }
  
  /**
   * 通知状态变更
   */
  private notifyStateChanged(state: MicrophoneState): void {
    if (this.stateListener) {
      this.stateListener.onMicrophoneStateChanged(state);
    }
  }
  
  /**
   * 通知错误
   */
  private notifyError(error: string): void {
    if (this.stateListener) {
      this.stateListener.onMicrophoneError(error);
    }
  }
}
