/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { NvHttp, NetworkProbeCapabilities, NetworkProbeSession } from '../streaming/NvHttp';
import { SettingsService, BandwidthProbeSettings } from '../SettingsService';
import { ConnectionPath, ConnectionPathInfo, ConnectionPathService } from './ConnectionPathService';
import { StringUtil } from '../../utils/StringUtil';

export const METERED_BANDWIDTH_PROBE_MAX_BYTES: number = 320 * 1024;

class BandwidthProbeCacheEntry {
  measuredKbps: number;
  safeBitrateKbps: number;
  measuredAt: number;
  highConfidence: boolean;

  constructor(measuredKbps: number, safeBitrateKbps: number, measuredAt: number, highConfidence: boolean) {
    this.measuredKbps = measuredKbps;
    this.safeBitrateKbps = safeBitrateKbps;
    this.measuredAt = measuredAt;
    this.highConfidence = highConfidence;
  }
}

export class InitialBitrateDecision {
  bitrateKbps: number;
  userLimitKbps: number;
  path: ConnectionPath;
  measuredKbps: number;
  probeApplied: boolean;

  constructor(bitrateKbps: number, userLimitKbps: number, path: ConnectionPath,
    measuredKbps: number, probeApplied: boolean) {
    this.bitrateKbps = bitrateKbps;
    this.userLimitKbps = userLimitKbps;
    this.path = path;
    this.measuredKbps = measuredKbps;
    this.probeApplied = probeApplied;
  }
}

export class BandwidthProbeService {
  private static instance: BandwidthProbeService | null = null;
  private static readonly CACHE_TTL_MS = 15 * 60 * 1000;
  private static readonly TOTAL_BUDGET_MS = 800;
  private static readonly SAMPLE_STOP_MS = 250;
  private static readonly SAFE_FACTOR = 0.70;
  private static readonly SAMPLE_SIZES: number[] = [65536, 262144, 1048576, 4194304];

  private cache: Map<string, BandwidthProbeCacheEntry> = new Map();
  private activeSession: NetworkProbeSession | null = null;
  private operationId: number = 0;

  static getInstance(): BandwidthProbeService {
    if (!BandwidthProbeService.instance) {
      BandwidthProbeService.instance = new BandwidthProbeService();
    }
    return BandwidthProbeService.instance;
  }

  /** 应用列表加载完成后调用；失败不会影响 UI 或开流。 */
  async preheat(hostId: string, endpoint: string, nvHttp: NvHttp): Promise<void> {
    const settings = await SettingsService.getInstance().getBandwidthProbeSettings();
    if (!settings.probeEnabled) {
      return;
    }

    const pathInfo = await ConnectionPathService.inspect(endpoint);
    if (!this.canProbe(pathInfo, settings)) {
      return;
    }
    const cacheKey = pathInfo.cacheKey(hostId);
    if (this.getFreshCache(cacheKey)) {
      return;
    }

    this.cancel();
    const operationId = this.operationId;
    let probeSession: NetworkProbeSession | null = null;
    try {
      const capabilities = await nvHttp.getNetworkProbeCapabilities();
      if (!capabilities || operationId !== this.operationId) {
        return;
      }
      probeSession = await nvHttp.createNetworkProbeSession(capabilities);
      if (operationId !== this.operationId) {
        probeSession.close();
        return;
      }
      this.activeSession = probeSession;
      const result = await this.runProgressiveProbe(probeSession, capabilities, pathInfo.isMetered, operationId);
      if (result && operationId === this.operationId) {
        this.cache.set(cacheKey, result);
        console.info('BandwidthProbeService: path=' + pathInfo.path + ', measured=' +
          Math.round(result.measuredKbps).toString() + 'kbps, safe=' + result.safeBitrateKbps.toString() + 'kbps');
      }
    } catch (err) {
      if (operationId === this.operationId) {
        console.info('BandwidthProbeService: 启动前探测已回退: ' + String(err));
      }
    } finally {
      if (probeSession) {
        probeSession.close();
      }
      if (this.activeSession === probeSession) {
        this.activeSession = null;
      }
    }
  }

  cancel(): void {
    this.operationId++;
    const activeSession = this.activeSession;
    this.activeSession = null;
    if (activeSession) {
      activeSession.close();
    }
  }

  async resolveInitialBitrate(hostId: string, endpoint: string, configuredBitrateKbps: number): Promise<InitialBitrateDecision> {
    const settings = await SettingsService.getInstance().getBandwidthProbeSettings();
    const pathInfo = await ConnectionPathService.inspect(endpoint);
    let effective = configuredBitrateKbps;
    let measured = 0;
    let probeApplied = false;

    if (settings.probeEnabled) {
      const cached = this.getFreshCache(pathInfo.cacheKey(hostId));
      if (cached) {
        measured = cached.measuredKbps;
        if (cached.highConfidence && cached.safeBitrateKbps >= 2000 && cached.safeBitrateKbps < effective) {
          effective = cached.safeBitrateKbps;
          probeApplied = true;
        }
      }
    }
    return new InitialBitrateDecision(effective, configuredBitrateKbps, pathInfo.path, measured, probeApplied);
  }

  private canProbe(pathInfo: ConnectionPathInfo, settings: BandwidthProbeSettings): boolean {
    if ((pathInfo.isMetered || pathInfo.isCellular) && !settings.meteredProbeEnabled) {
      console.info('BandwidthProbeService: 计费或蜂窝网络未授权主动探测');
      return false;
    }
    return true;
  }

  private getFreshCache(cacheKey: string): BandwidthProbeCacheEntry | null {
    const cached = this.cache.get(cacheKey);
    if (!cached) {
      return null;
    }
    if (Date.now() - cached.measuredAt > BandwidthProbeService.CACHE_TTL_MS) {
      this.cache.delete(cacheKey);
      return null;
    }
    return cached;
  }

  private async runProgressiveProbe(session: NetworkProbeSession, capabilities: NetworkProbeCapabilities,
    metered: boolean, operationId: number): Promise<BandwidthProbeCacheEntry | null> {
    const nonce = StringUtil.generateUUID();
    const startedAt = Date.now();
    let bestDuration = 0;
    let bestBytes = 0;
    let bestKbps = 0;
    let requestedBytes = 0;
    let warmupCompleted = false;

    for (let i = 0; i < BandwidthProbeService.SAMPLE_SIZES.length; i++) {
      const bytes = BandwidthProbeService.SAMPLE_SIZES[i];
      if (bytes < capabilities.minBytes || bytes > capabilities.maxBytes) {
        continue;
      }
      if (metered && requestedBytes + bytes > METERED_BANDWIDTH_PROBE_MAX_BYTES) {
        break;
      }
      const remainingBudgetMs = BandwidthProbeService.TOTAL_BUDGET_MS - (Date.now() - startedAt);
      if (operationId !== this.operationId || remainingBudgetMs <= 0) {
        break;
      }

      const sampleStartedAt = Date.now();
      const timeoutMs = Math.max(1, Math.min(NvHttp.NETWORK_PROBE_TIMEOUT, remainingBudgetMs));
      requestedBytes += bytes;
      const data = await session.download(bytes, nonce, timeoutMs);
      const durationMs = Math.max(1, Date.now() - sampleStartedAt);
      if (operationId !== this.operationId) {
        return null;
      }
      if (data.byteLength !== bytes) {
        throw new Error('探测响应长度不匹配');
      }

      // 第一个服务端允许的样本作为连接预热，不参与最终吞吐计算。
      if (warmupCompleted) {
        const measuredKbps = bytes * 8 / durationMs;
        if (durationMs >= bestDuration) {
          bestDuration = durationMs;
          bestBytes = bytes;
          bestKbps = measuredKbps;
        }
        if (durationMs >= BandwidthProbeService.SAMPLE_STOP_MS) {
          break;
        }
      } else {
        warmupCompleted = true;
      }
    }

    if (bestBytes === 0) {
      return null;
    }
    const highConfidence = bestBytes >= 131072 && bestDuration >= 50;
    const safeBitrate = Math.max(1, Math.floor(bestKbps * BandwidthProbeService.SAFE_FACTOR));
    return new BandwidthProbeCacheEntry(bestKbps, safeBitrate, Date.now(), highConfidence);
  }
}
