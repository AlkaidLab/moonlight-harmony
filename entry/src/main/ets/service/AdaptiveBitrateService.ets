/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { NvHttp, AbrConfig, NetworkFeedback, AbrCapabilities, AbrAction } from './NvHttp';
import { StreamStats } from './StreamingSession';

const TAG = '[ABR]';

/**
 * 智能码率调节服务
 *
 * 两层架构：
 * 1. 优先让 Sunshine 服务端做码率决策（ABR API feedback 模式）
 * 2. 服务端不支持时回退到客户端本地 PID 控制器
 *
 * 客户端每秒上报网络指标 → 服务端返回码率调整指令 → 客户端执行
 */
export class AdaptiveBitrateService {
  private nvHttp: NvHttp;
  private enabled: boolean = false;
  private serverSupported: boolean = false;
  private mode: string = 'balanced';
  private minBitrate: number = 3000;  // Kbps
  private maxBitrate: number = 100000;  // Kbps
  private initialBitrate: number = 0;
  private currentBitrate: number = 0;

  // 本地 fallback 控制器状态
  private stableSeconds: number = 0;
  private lossStreak: number = 0;
  private lastAdjustTime: number = 0;
  private lastDirection: 'up' | 'down' | 'none' = 'none';

  // 回调
  private onBitrateChange: ((bitrate: number, reason: string) => Promise<boolean>) | null = null;

  // 定时器
  private tickInterval: number = -1;
  private getStatsFn: (() => StreamStats) | null = null;

  constructor(nvHttp: NvHttp) {
    this.nvHttp = nvHttp;
  }

  /**
   * 检查服务端 ABR 能力（串流开始前调用一次）
   */
  async checkCapabilities(): Promise<AbrCapabilities> {
    const caps = await this.nvHttp.getAbrCapabilities();
    this.serverSupported = caps.supported;
    console.info(`${TAG} 服务端 ABR: supported=${caps.supported}, version=${caps.version}, features=${JSON.stringify(caps.features)}`);
    return caps;
  }

  /**
   * 启动智能码率调节
   */
  async start(
    initialBitrate: number,
    mode: string,
    getStats: () => StreamStats,
    onBitrateChange: (bitrate: number, reason: string) => Promise<boolean>
  ): Promise<void> {
    if (this.enabled) return;

    this.initialBitrate = initialBitrate;
    this.currentBitrate = initialBitrate;
    this.mode = mode;
    this.getStatsFn = getStats;
    this.onBitrateChange = onBitrateChange;
    this.resetState();

    // 设置模式参数
    this.applyModePreset(mode);

    // 通知服务端
    if (this.serverSupported) {
      const config: AbrConfig = {
        enabled: true,
        minBitrate: this.minBitrate,
        maxBitrate: this.maxBitrate,
        mode: this.mode,
      };
      const ok = await this.nvHttp.setAbrMode(config);
      console.info(`${TAG} 服务端 ABR 启用: ${ok ? '成功' : '不支持，使用本地控制器'}`);
      if (!ok) {
        this.serverSupported = false;
      }
    }

    this.enabled = true;

    // 启动每秒 tick（延迟 3 秒开始，让连接稳定）
    this.tickInterval = setInterval(() => {
      this.tick();
    }, 1000);

    console.info(`${TAG} 已启动: bitrate=${initialBitrate}kbps, mode=${mode}, server=${this.serverSupported}`);
  }

  /**
   * 停止智能码率调节
   */
  async stop(): Promise<void> {
    if (!this.enabled) return;

    if (this.tickInterval >= 0) {
      clearInterval(this.tickInterval);
      this.tickInterval = -1;
    }

    // 通知服务端关闭
    if (this.serverSupported) {
      await this.nvHttp.setAbrMode({
        enabled: false,
        minBitrate: 0,
        maxBitrate: 0,
        mode: 'balanced',
      });
    }

    // 恢复初始码率
    if (this.currentBitrate !== this.initialBitrate && this.onBitrateChange) {
      await this.onBitrateChange(this.initialBitrate, 'restore');
    }

    this.enabled = false;
    this.resetState();
    console.info(`${TAG} 已停止，恢复码率: ${this.initialBitrate}kbps`);
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  isServerSupported(): boolean {
    return this.serverSupported;
  }

  getCurrentBitrate(): number {
    return this.currentBitrate;
  }

  /**
   * 获取当前状态描述（用于性能面板显示）
   */
  getStatusText(): string {
    if (!this.enabled) return '';
    const mode = this.serverSupported ? 'server' : 'local';
    return `ABR:${mode} ${Math.round(this.currentBitrate / 1000)}M`;
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  private applyModePreset(mode: string): void {
    switch (mode) {
      case 'quality':
        // 画质优先：高下限，慢降快升
        this.minBitrate = Math.max(5000, this.initialBitrate * 0.5);
        this.maxBitrate = Math.min(150000, this.initialBitrate * 1.5);
        break;
      case 'lowLatency':
        // 低延迟优先：低下限，快降慢升
        this.minBitrate = 2000;
        this.maxBitrate = this.initialBitrate * 1.2;
        break;
      default: // balanced
        this.minBitrate = Math.max(3000, this.initialBitrate * 0.3);
        this.maxBitrate = Math.min(150000, this.initialBitrate * 2);
        break;
    }
  }

  private resetState(): void {
    this.stableSeconds = 0;
    this.lossStreak = 0;
    this.lastAdjustTime = 0;
    this.lastDirection = 'none';
  }

  private async tick(): Promise<void> {
    if (!this.enabled || !this.getStatsFn || !this.onBitrateChange) return;

    const stats = this.getStatsFn();

    if (this.serverSupported) {
      await this.tickServer(stats);
    } else {
      await this.tickLocal(stats);
    }
  }

  /**
   * 服务端模式：上报指标，执行服务端指令
   */
  private async tickServer(stats: StreamStats): Promise<void> {
    const feedback: NetworkFeedback = {
      packetLoss: stats.packetLoss,
      rttMs: stats.networkLatency,
      decodeFps: stats.renderedFps,
      droppedFrames: stats.droppedFrames,
      currentBitrate: this.currentBitrate,
    };

    const action = await this.nvHttp.reportNetworkFeedback(feedback);
    if (action?.newBitrate && action.newBitrate !== this.currentBitrate) {
      const clamped = clamp(action.newBitrate, this.minBitrate, this.maxBitrate);
      const success = await this.onBitrateChange!(clamped, action.reason ?? 'server');
      if (success) {
        console.info(`${TAG} [server] ${this.currentBitrate}→${clamped}kbps (${action.reason})`);
        this.currentBitrate = clamped;
      }
    }
  }

  /**
   * 本地 fallback 模式：PID 式控制器
   */
  private async tickLocal(stats: StreamStats): Promise<void> {
    const now = Date.now();
    const cooldown = this.mode === 'lowLatency' ? 1500 : 2000;

    // 防抖：调整后冷却期
    if (now - this.lastAdjustTime < cooldown) return;

    let newBitrate = this.currentBitrate;
    let reason = '';

    if (stats.packetLoss > 5) {
      // 紧急降档：丢包 > 5%
      newBitrate = this.currentBitrate * 0.7;
      reason = `loss=${stats.packetLoss.toFixed(1)}% emergency`;
      this.stableSeconds = 0;
      this.lossStreak++;
    } else if (stats.packetLoss > 2) {
      // 温和降档：丢包 2-5%
      this.lossStreak++;
      if (this.lossStreak >= 2) {
        newBitrate = this.currentBitrate * 0.9;
        reason = `loss=${stats.packetLoss.toFixed(1)}% sustained`;
        this.stableSeconds = 0;
      }
    } else if (stats.packetLoss > 0.5) {
      // 轻微丢包：缓慢降档
      this.lossStreak++;
      this.stableSeconds = 0;
      if (this.lossStreak >= 4) {
        newBitrate = this.currentBitrate * 0.95;
        reason = `loss=${stats.packetLoss.toFixed(1)}% mild`;
      }
    } else {
      // 无丢包：考虑升档
      this.lossStreak = 0;
      this.stableSeconds++;

      const probeThreshold = this.mode === 'quality' ? 3 : 5;
      if (this.stableSeconds >= probeThreshold && this.currentBitrate < this.maxBitrate) {
        // 防震荡：如果上次是降档，升档速度减半
        const step = this.lastDirection === 'down' ? 1.02 : 1.05;
        newBitrate = this.currentBitrate * step;
        reason = `stable ${this.stableSeconds}s probe`;
        this.stableSeconds = 0;
      }
    }

    // 应用变更
    newBitrate = clamp(Math.round(newBitrate), this.minBitrate, this.maxBitrate);
    if (newBitrate !== this.currentBitrate) {
      const success = await this.onBitrateChange!(newBitrate, reason);
      if (success) {
        this.lastDirection = newBitrate > this.currentBitrate ? 'up' : 'down';
        console.info(`${TAG} [local] ${this.currentBitrate}→${newBitrate}kbps (${reason})`);
        this.currentBitrate = newBitrate;
        this.lastAdjustTime = now;
      }
    }
  }
}

function clamp(v: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, v));
}
