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
import {
  NetworkBoostService,
  SystemNetQos,
  SystemNetQosListener,
  SystemNetScene,
  SystemNetSceneListener
} from '../network/NetworkBoostService';

const TAG = '[ABR]';

interface SceneMitigation {
  factor: number;
  reason: string;
  key: string;
}

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
  private lastSceneMitigationTime: number = 0;
  private lastSceneMitigationKey: string = '';

  private latestSystemQos: SystemNetQos | null = null;
  private latestSystemScene: SystemNetScene | null = null;
  private latestSystemSceneAt: number = 0;
  private latestWeakSignalStartAt: number = 0;
  private latestWeakSignalEndAt: number = 0;
  private qosListener: SystemNetQosListener | null = null;
  private sceneListener: SystemNetSceneListener | null = null;

  // 回调
  private onBitrateChange: ((bitrate: number, reason: string) => Promise<boolean>) | null = null;

  // 定时器
  private tickInterval: number = -1;
  private getStatsFn: (() => StreamStats) | null = null;

  // 服务端启用重试（每 RETRY_INTERVAL 秒一次，最多 MAX_RETRIES 次）
  private serverEnableRetries: number = 0;
  private serverRetryTickCounter: number = 0;
  private static readonly MAX_SERVER_ENABLE_RETRIES = 10;
  private static readonly SERVER_RETRY_INTERVAL_TICKS = 5;
  private static readonly SYSTEM_QOS_TTL_MS = 5_000;
  private static readonly SYSTEM_SCENE_TTL_MS = 12_000;
  private static readonly SCENE_MITIGATION_COOLDOWN_MS = 6_000;

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

    // 服务端启用由 tick 惰性重试（避免会话未就绪导致立即降级）
    if (this.serverSupported) {
      this.serverEnableRetries = 1;
    }

    this.enabled = true;
    this.subscribeNetworkBoostSignals();

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

    this.unsubscribeNetworkBoostSignals();

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
    let mode: string;
    if (this.serverSupported && this.serverEnableRetries === 0) {
      mode = 'server';
    } else if (this.serverSupported && this.serverEnableRetries > 0) {
      mode = 'connecting';
    } else {
      mode = 'local';
    }
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
    this.lastSceneMitigationTime = 0;
    this.lastSceneMitigationKey = '';
    this.latestSystemQos = null;
    this.latestSystemScene = null;
    this.latestSystemSceneAt = 0;
    this.latestWeakSignalStartAt = 0;
    this.latestWeakSignalEndAt = 0;
    this.serverEnableRetries = 0;
    this.serverRetryTickCounter = 0;
  }

  private subscribeNetworkBoostSignals(): void {
    if (this.qosListener || this.sceneListener) {
      return;
    }
    const service = NetworkBoostService.getInstance();
    const qosListener: SystemNetQosListener = (qos: SystemNetQos): void => {
      this.latestSystemQos = qos;
    };
    const sceneListener: SystemNetSceneListener = (scene: SystemNetScene): void => {
      const now = Date.now();
      this.latestSystemScene = scene;
      this.latestSystemSceneAt = now;
      this.latestWeakSignalStartAt = 0;
      this.latestWeakSignalEndAt = 0;
      if (scene.weakSignalStartSec !== undefined && scene.weakSignalStartSec >= 0) {
        this.latestWeakSignalStartAt = now + scene.weakSignalStartSec * 1000;
        if (scene.weakSignalDurationSec !== undefined && scene.weakSignalDurationSec > 0) {
          this.latestWeakSignalEndAt = this.latestWeakSignalStartAt + scene.weakSignalDurationSec * 1000;
        }
      }
    };
    this.qosListener = qosListener;
    this.sceneListener = sceneListener;
    service.addListener(qosListener);
    service.addSceneListener(sceneListener);
  }

  private unsubscribeNetworkBoostSignals(): void {
    const service = NetworkBoostService.getInstance();
    const qosListener = this.qosListener;
    if (qosListener) {
      service.removeListener(qosListener);
      this.qosListener = null;
    }
    const sceneListener = this.sceneListener;
    if (sceneListener) {
      service.removeSceneListener(sceneListener);
      this.sceneListener = null;
    }
    this.latestSystemQos = null;
    this.latestSystemScene = null;
    this.latestSystemSceneAt = 0;
    this.latestWeakSignalStartAt = 0;
    this.latestWeakSignalEndAt = 0;
  }

  /**
   * 尝试在服务端启用 ABR，返回是否成功
   */
  private async tryEnableServer(): Promise<boolean> {
    const config: AbrConfig = {
      enabled: true,
      minBitrate: this.minBitrate,
      maxBitrate: this.maxBitrate,
      mode: this.mode,
    };
    const ok = await this.nvHttp.setAbrMode(config);
    console.info(`${TAG} 服务端 ABR 启用: ${ok ? '成功' : '失败'}`);
    return ok;
  }

  private async tick(): Promise<void> {
    if (!this.enabled || !this.getStatsFn || !this.onBitrateChange) return;

    // 惰性重试：每 5 秒尝试一次服务端启用，最多 10 次
    if (this.serverSupported && this.serverEnableRetries > 0) {
      if (++this.serverRetryTickCounter >= AdaptiveBitrateService.SERVER_RETRY_INTERVAL_TICKS) {
        this.serverRetryTickCounter = 0;
        const retryNum = this.serverEnableRetries;
        const ok = await this.tryEnableServer();
        if (ok) {
          this.serverEnableRetries = 0;
          console.info(`${TAG} 服务端 ABR 启用成功（第 ${retryNum} 次）`);
        } else if (++this.serverEnableRetries > AdaptiveBitrateService.MAX_SERVER_ENABLE_RETRIES) {
          this.serverSupported = false;
          console.warn(`${TAG} 服务端 ABR 重试 ${AdaptiveBitrateService.MAX_SERVER_ENABLE_RETRIES} 次均失败，降级到本地控制器`);
        }
      }
    }

    const stats = this.getStatsFn();

    if (this.serverSupported && this.serverEnableRetries === 0) {
      await this.tickServer(stats);
    } else {
      await this.tickLocal(stats);
    }
  }

  /**
   * 服务端模式：上报指标，执行服务端指令
   */
  private async tickServer(stats: StreamStats): Promise<void> {
    const now = Date.now();
    const systemQos = this.getFreshSystemQos();
    const systemScene = this.getFreshSystemScene();
    const feedback: NetworkFeedback = {
      packetLoss: stats.packetLoss,
      rttMs: stats.networkLatency > 0 ? stats.networkLatency : (systemQos?.rttMs ?? 0),
      decodeFps: stats.renderedFps,
      droppedFrames: stats.droppedFrames,
      currentBitrate: this.currentBitrate,
    };
    if (systemQos) {
      feedback.systemRttMs = systemQos.rttMs;
      feedback.systemUpBufferDelayMs = systemQos.upBufferDelayMs;
      feedback.systemUpBufferCongestionPercent = systemQos.upBufferCongestionPercent;
      feedback.systemUpBandwidthBps = systemQos.upBandwidthBps;
      feedback.systemDownBandwidthBps = systemQos.downBandwidthBps;
    }
    if (systemScene) {
      feedback.systemNetworkScene = systemScene.scene;
      feedback.systemRecommendedAction = systemScene.recommendedAction;
      const weakSignalStartSec = this.getWeakSignalStartSec(now);
      if (weakSignalStartSec !== null) {
        feedback.weakSignalStartSec = weakSignalStartSec;
        feedback.weakSignalDurationSec = systemScene.weakSignalDurationSec;
      }
    }

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

  private getFreshSystemQos(): SystemNetQos | null {
    if (!this.latestSystemQos) {
      return null;
    }
    if (Date.now() - this.latestSystemQos.timestampMs > AdaptiveBitrateService.SYSTEM_QOS_TTL_MS) {
      return null;
    }
    return this.latestSystemQos;
  }

  private getFreshSystemScene(): SystemNetScene | null {
    if (!this.latestSystemScene) {
      return null;
    }
    if (Date.now() - this.latestSystemSceneAt > AdaptiveBitrateService.SYSTEM_SCENE_TTL_MS) {
      return null;
    }
    return this.latestSystemScene;
  }

  private getWeakSignalStartSec(now: number): number | null {
    if (this.latestWeakSignalStartAt <= 0) {
      return null;
    }
    if (this.latestWeakSignalEndAt > 0 && now > this.latestWeakSignalEndAt) {
      return null;
    }
    return Math.max(0, (this.latestWeakSignalStartAt - now) / 1000);
  }

  private getSceneMitigation(now: number): SceneMitigation | null {
    const scene = this.getFreshSystemScene();
    if (!scene) {
      return null;
    }

    let mitigation: SceneMitigation | null = null;
    const weakSignalStartSec = this.getWeakSignalStartSec(now);
    if (weakSignalStartSec !== null && weakSignalStartSec <= 8) {
      mitigation = {
        factor: 0.82,
        reason: `networkBoost weakSignal in ${Math.round(weakSignalStartSec)}s`,
        key: 'weakSignal'
      };
    } else if (scene.scene === 'congestion' && scene.recommendedAction === 'suspendData') {
      mitigation = {
        factor: 0.72,
        reason: 'networkBoost congestion suspendData',
        key: 'congestion:suspendData'
      };
    } else if (scene.scene === 'congestion' && scene.recommendedAction === 'decreaseData') {
      mitigation = {
        factor: 0.84,
        reason: 'networkBoost congestion decreaseData',
        key: 'congestion:decreaseData'
      };
    } else if (scene.scene === 'frequentHandover') {
      mitigation = {
        factor: 0.90,
        reason: 'networkBoost frequentHandover',
        key: 'frequentHandover'
      };
    }

    if (!mitigation) {
      return null;
    }
    if (mitigation.key === this.lastSceneMitigationKey &&
      now - this.lastSceneMitigationTime < AdaptiveBitrateService.SCENE_MITIGATION_COOLDOWN_MS) {
      return null;
    }
    return mitigation;
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

    const sceneMitigation = this.getSceneMitigation(now);
    if (sceneMitigation) {
      newBitrate = this.currentBitrate * sceneMitigation.factor;
      reason = sceneMitigation.reason;
      this.stableSeconds = 0;
      this.lossStreak++;
    } else if (stats.packetLoss > 5) {
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
        if (sceneMitigation) {
          this.lastSceneMitigationKey = sceneMitigation.key;
          this.lastSceneMitigationTime = now;
        }
      }
    }
  }
}

function clamp(v: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, v));
}
