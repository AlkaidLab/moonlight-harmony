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
 * 麦克风配置模块
 * 管理麦克风相关的配置参数
 */

/**
 * 麦克风配置常量和参数
 */
export class MicrophoneConfig {
  // ========== 音频参数 ==========
  /** 采样率 (Hz) */
  static readonly SAMPLE_RATE: number = 48000;
  /** 声道数（单声道） */
  static readonly CHANNELS: number = 1;
  
  // ========== Opus 编码参数 ==========
  /** Opus 帧大小 (毫秒) */
  static readonly FRAME_SIZE_MS: number = 20;
  /** 每帧采样数 (960 = 48000 * 20 / 1000) */
  static readonly SAMPLES_PER_FRAME: number = MicrophoneConfig.SAMPLE_RATE * MicrophoneConfig.FRAME_SIZE_MS / 1000;
  /** 每帧字节数 (1920 = 960 * 1 * 2) - PCM 16bit */
  static readonly BYTES_PER_FRAME: number = MicrophoneConfig.SAMPLES_PER_FRAME * MicrophoneConfig.CHANNELS * 2;
  
  // ========== 缓冲区参数 ==========
  /** 捕获缓冲区大小 (毫秒) */
  static readonly CAPTURE_BUFFER_SIZE_MS: number = 40;
  /** 捕获缓冲区字节数 */
  static readonly CAPTURE_BUFFER_SIZE: number = 
    MicrophoneConfig.SAMPLE_RATE * MicrophoneConfig.CAPTURE_BUFFER_SIZE_MS / 1000 * MicrophoneConfig.CHANNELS * 2;
  
  // ========== 队列和延迟参数 ==========
  /** 最大队列大小 */
  static readonly MAX_QUEUE_SIZE: number = 5;
  /** 帧间隔 (毫秒) */
  static readonly FRAME_INTERVAL_MS: number = 20;
  /** 发送线程睡眠时间 (毫秒) */
  static readonly SENDER_THREAD_SLEEP_MS: number = 5;
  
  // ========== 运行时配置 ==========
  private static opusBitrateKbps: number = 64;
  
  /**
   * 获取当前配置的 Opus 比特率 (bps)
   */
  static getOpusBitrate(): number {
    return MicrophoneConfig.opusBitrateKbps * 1000;
  }
  
  /**
   * 获取当前配置的 Opus 比特率 (Kbps)
   */
  static getOpusBitrateKbps(): number {
    return MicrophoneConfig.opusBitrateKbps;
  }
  
  /**
   * 设置 Opus 比特率
   * @param bitrateKbps 比特率 (Kbps)
   */
  static setOpusBitrate(bitrateKbps: number): void {
    MicrophoneConfig.opusBitrateKbps = bitrateKbps;
  }
  
  /**
   * 获取配置摘要信息
   */
  static getConfigSummary(): string {
    return `麦克风配置:
采样率: ${MicrophoneConfig.SAMPLE_RATE} Hz
声道数: ${MicrophoneConfig.CHANNELS}
Opus 比特率: ${MicrophoneConfig.opusBitrateKbps} Kbps
帧大小: ${MicrophoneConfig.FRAME_SIZE_MS} ms (${MicrophoneConfig.SAMPLES_PER_FRAME} samples)`;
  }
}

/**
 * 麦克风状态枚举
 */
export enum MicrophoneState {
  /** 已停止 */
  STOPPED = 'stopped',
  /** 正在初始化 */
  INITIALIZING = 'initializing',
  /** 正在捕获 */
  CAPTURING = 'capturing',
  /** 已暂停 */
  PAUSED = 'paused',
  /** 发生错误 */
  ERROR = 'error'
}

/**
 * 麦克风事件类型
 */
export enum MicrophoneEventType {
  /** 状态变更 */
  STATE_CHANGED = 'stateChanged',
  /** 主机请求麦克风 */
  HOST_REQUESTED = 'hostRequested',
  /** 错误发生 */
  ERROR = 'error',
  /** 数据发送 */
  DATA_SENT = 'dataSent'
}

/**
 * 麦克风事件数据
 */
export interface MicrophoneEvent {
  type: MicrophoneEventType;
  state?: MicrophoneState;
  error?: string;
  data?: object;
}

/**
 * 麦克风状态监听器接口
 */
export interface MicrophoneStateListener {
  onMicrophoneStateChanged(state: MicrophoneState): void;
  onMicrophoneError(error: string): void;
}
