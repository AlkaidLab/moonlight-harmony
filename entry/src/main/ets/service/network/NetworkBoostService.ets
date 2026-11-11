/**
 * NetworkBoostService — HarmonyOS Network Boost Kit 接入封装
 *
 * Step 1: 应用传输体验反馈 (reportQoe)
 *   声明本应用为「实时游戏」类业务（serviceType='realtimeGame'），
 *   让系统优先调度网络资源，降低 Wi-Fi 拥塞场景下的延迟/抖动。
 *   根据 connectionStatusUpdate 实时反馈 QoE（good / highLatency）。
 *
 * Step 2: 订阅 netQosChange
 *   实时获取 RTT/抖动/上下行带宽/丢包率，缓存最新一份 NetworkQos，
 *   通过 listener 推给 UI（统计悬浮层）和后续的自适应码率（Step 3 接入）。
 *
 * 兼容性：仅 Phone/Tablet/PC，且仅 Wi-Fi/Cellular 场景下生效；
 *        非 HMS 设备/模拟器会抛 801（Capability not supported），
 *        本服务静默忽略。
 *
 * 后续步骤：
 *   Step 4: 引入 netHandover 多网切换（远程串流场景，需 LINKTURBO 受限权限）
 */

import { netBoost, netQuality } from '@kit.NetworkBoostKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { MoonBridge, StreamSocketFds, StreamSocketInfo } from '../streaming/MoonBridge';
import { Logger } from '../../common/Logger';
import { AppState, AppStateService } from '../AppStateService';

/** NetworkBoost Kit 系统能力（netBoost/netQuality 全部 API 共用同一 syscap） */
const NETWORK_BOOST_SYSCAP = 'SystemCapability.Communication.NetworkBoost.Core';

const STREAMING_SERVICE_TYPE: netQuality.ServiceType = 'realtimeGame';

/** setDataFlowDesc 起始 API 版本 */
const DATA_FLOW_DESC_MIN_API = 26;
// API 26: foreground applications may describe at most two flows.
const MAX_DATA_FLOW_DESCRIPTIONS = 2;
const MAX_CLEANUP_RETRIES = 3;
const CLEANUP_RETRY_DELAY_MS = 250;
const FLOW_MONITOR_INTERVAL_MS = 1000;
const MAX_FLOW_REFRESH_RETRIES = 3;

interface RegisteredFlow {
  sourceFd: number;
  retainedFd: number;
}

type StreamQoeState = 'good' | 'poor';

/**
 * 系统反馈的网络质量摘要（只提取真实 SDK 有的字段）。
 * 多路径时取主路径（WIFI_PRIMARY 或 CELLULAR_PRIMARY）。
 */
export interface SystemNetQos {
  /** 系统时间戳（毫秒） */
  timestampMs: number;
  /** 路径类型，0=蜂窝主 1=蜂窝副 2=WiFi主 3=WiFi副 */
  pathType: number;
  /** RTT 延迟（毫秒） */
  rttMs: number;
  /** 上行带宽 bps */
  upBandwidthBps: number;
  /** 下行带宽 bps */
  downBandwidthBps: number;
  /** 上行速率 bps */
  upRateBps: number;
  /** 下行速率 bps */
  downRateBps: number;
  /** 上行缓冲时延（毫秒） */
  upBufferDelayMs: number;
  /** 上行缓冲拥塞百分比 0-100 */
  upBufferCongestionPercent: number;
}

export type SystemNetQosListener = (qos: SystemNetQos) => void;

export type NetSceneType = 'normal' | 'congestion' | 'frequentHandover' | 'weakSignal';
export type NetRecommendedAction = 'doCaching' | 'suspendData' | 'decreaseData' | 'increaseData' | 'keepData';

/**
 * 系统推送的网络场景事件，用于 UI/ABR 全局决策。
 */
export interface SystemNetScene {
  /** 路径类型，0=蜂窝主 1=蜂窝副 2=WiFi主 3=WiFi副 */
  pathType: number;
  /** 场景类型 */
  scene: NetSceneType;
  /** 推荐发包策略 */
  recommendedAction: NetRecommendedAction;
  /** 弱信号预测：预计 startTime 秒后进入弱信号区，持续 duration 秒 */
  weakSignalStartSec?: number;
  weakSignalDurationSec?: number;
}

export type SystemNetSceneListener = (scene: SystemNetScene) => void;

export class NetworkBoostService {
  private static instance: NetworkBoostService | null = null;

  private active: boolean = false;
  private sessionGeneration: number = 0;
  private lastState: StreamQoeState | null = null;
  private supported: boolean = true;

  private qosCallback: ((list: Array<netQuality.NetworkQos>) => void) | null = null;
  private latestQos: SystemNetQos | null = null;
  private listeners: Set<SystemNetQosListener> = new Set();

  private sceneCallback: ((list: Array<netQuality.NetworkScene>) => void) | null = null;
  private latestScene: SystemNetScene | null = null;
  private sceneListeners: Set<SystemNetSceneListener> = new Set();
  private registeredFlows: RegisteredFlow[] = [];
  private sceneEntered: boolean = false;
  private dataFlowSupported: boolean = true;
  private streamingFlows: StreamSocketFds | null = null;
  private cleanupRetryTimer: number = -1;
  private cleanupRetryCount: number = 0;
  private cleanupRetryGeneration: number = 0;
  private flowMonitorTimer: number = -1;
  private flowMonitorGeneration: number = 0;
  private flowRefreshPending: boolean = false;
  private flowRefreshRetries: number = 0;
  private appStateListener: (state: AppState) => void = (_state: AppState): void => {
    if (!this.active) {
      return;
    }
    this.cancelFlowMonitor();
    this.cancelCleanupRetry();
    this.flowRefreshRetries = 0;
    if (this.active && !this.isNativeConnectionActive()) {
      this.stop();
      return;
    }
    if (AppStateService.getInstance().getCurrentState() === AppState.FOREGROUND && this.streamingFlows) {
      this.updateSocketSnapshot();
    }
    this.refreshDataFlowDesc();
    if (AppStateService.getInstance().getCurrentState() !== AppState.FOREGROUND) {
      this.scheduleCleanupRetry();
    }
    this.scheduleFlowMonitor();
  };

  static getInstance(): NetworkBoostService {
    if (!NetworkBoostService.instance) {
      NetworkBoostService.instance = new NetworkBoostService();
    }
    return NetworkBoostService.instance;
  }

  /** 串流会话开始：声明业务类型 + 订阅网络质量回调 */
  start(): number {
    if (this.active) {
      return this.sessionGeneration;
    }
    this.cancelCleanupRetry();
    this.active = true;
    const generation = ++this.sessionGeneration;
    try {
      AppStateService.getInstance().addListener(this.appStateListener);
      this.lastState = null;
      this.reportInternal('good');
      this.subscribeQos();
      this.subscribeScene();
    } catch (err) {
      this.stop(generation);
      throw new Error((err as Error).message);
    }
    return generation;
  }

  /** 串流会话结束：取消订阅 */
  stop(generation?: number): void {
    if (!this.active || (generation !== undefined && generation !== this.sessionGeneration)) {
      return;
    }
    this.active = false;
    this.cancelFlowMonitor();
    this.cancelCleanupRetry();
    AppStateService.getInstance().removeListener(this.appStateListener);
    this.streamingFlows = null;
    this.lastState = null;
    this.unsubscribeQos();
    this.unsubscribeScene();
    this.clearDataFlowDesc();
    this.scheduleCleanupRetry();
    this.latestQos = null;
    this.latestScene = null;
  }

  /** connectionStatusUpdate 驱动的 QoE 反馈 */
  reportConnectionStatus(poor: boolean): void {
    if (!this.active) {
      return;
    }
    this.reportInternal(poor ? 'poor' : 'good');
  }

  /** UI / 自适应码率注册 QoS 监听 */
  addListener(listener: SystemNetQosListener): void {
    this.listeners.add(listener);
    if (this.latestQos) {
      try {
        listener(this.latestQos);
      } catch (err) {
        Logger.warn('NetworkBoostService', `[NetworkBoost] listener 异常: ${(err as Error).message}`);
      }
    }
  }

  removeListener(listener: SystemNetQosListener): void {
    this.listeners.delete(listener);
  }

  /** 订阅网络场景变更（弱信号预测/拥塞等） */
  addSceneListener(listener: SystemNetSceneListener): void {
    this.sceneListeners.add(listener);
    if (this.latestScene) {
      try {
        listener(this.latestScene);
      } catch (err) {
        Logger.warn('NetworkBoostService', `[NetworkBoost] scene listener 异常: ${(err as Error).message}`);
      }
    }
  }

  removeSceneListener(listener: SystemNetSceneListener): void {
    this.sceneListeners.delete(listener);
  }

  getLatestScene(): SystemNetScene | null {
    return this.latestScene;
  }

  /** 最近一次系统上报的网络质量；未支持/未上报则为 null */
  getLatestQos(): SystemNetQos | null {
    return this.latestQos;
  }

  /** 设备是否支持 NetworkBoostKit（一次失败后置 false） */
  isSupported(): boolean {
    return this.supported && canIUse(NETWORK_BOOST_SYSCAP);
  }

  /**
   * HarmonyOS 26.0.0: 为关键串流 socket 注册系统级流描述,获得 per-flow 调度优先级。
   *
   * 原始 fd 来自 native 层 getStreamSocketFds()。登记使用独立副本，
   * 让 socket 替换后仍可注销旧流；注册失败不影响串流。
   */
  registerStreamingFlows(fds: StreamSocketFds): void {
    if (!this.active) {
      return;
    }
    this.streamingFlows = fds;
    this.flowRefreshRetries = 0;
    this.refreshDataFlowDesc();
    this.scheduleFlowMonitor();
  }

  private isNativeConnectionActive(): boolean {
    try {
      return MoonBridge.isConnectionActive();
    } catch (err) {
      Logger.warn('NetworkBoostService', `[NetworkBoost] 查询连接状态失败: ${(err as Error).message}`);
      return false;
    }
  }

  /** Refresh the snapshot when a stream replaces its socket, not for a NAT-only port change. */
  private updateSocketSnapshot(): boolean {
    try {
      const next = MoonBridge.getStreamSocketFds();
      const current = this.streamingFlows;
      if (!next || !current) {
        return false;
      }
      const controlChanged = next.control.fd !== current.control.fd || next.control.localPort !== current.control.localPort;
      const videoChanged = next.videoRtp.fd !== current.videoRtp.fd || next.videoRtp.localPort !== current.videoRtp.localPort;
      const audioChanged = next.audioRtp.fd !== current.audioRtp.fd || next.audioRtp.localPort !== current.audioRtp.localPort;
      const audioRegistered = this.registeredFlows.some((flow: RegisteredFlow): boolean =>
        flow.sourceFd === current.audioRtp.fd);
      if (controlChanged || videoChanged || audioChanged) {
        this.streamingFlows = next;
      }
      // Audio does not occupy a slot when control and video are registered.
      return controlChanged || videoChanged || (audioChanged && audioRegistered);
    } catch (err) {
      Logger.warn('NetworkBoostService', `[NetworkBoost] 获取串流 socket 失败: ${(err as Error).message}`);
      return false;
    }
  }

  private scheduleFlowMonitor(): void {
    if (this.flowMonitorTimer !== -1 || !this.active || !this.streamingFlows || !this.supported ||
      !this.dataFlowSupported || deviceInfo.sdkApiVersion < DATA_FLOW_DESC_MIN_API ||
      !canIUse(NETWORK_BOOST_SYSCAP) ||
      AppStateService.getInstance().getCurrentState() !== AppState.FOREGROUND) {
      return;
    }
    const generation = this.flowMonitorGeneration;
    this.flowMonitorTimer = setTimeout((): void => {
      if (generation !== this.flowMonitorGeneration) {
        return;
      }
      this.flowMonitorTimer = -1;
      if (this.active && AppStateService.getInstance().getCurrentState() === AppState.FOREGROUND) {
        if (!this.isNativeConnectionActive()) {
          this.stop();
          return;
        }
        if (this.updateSocketSnapshot()) {
          this.flowRefreshRetries = 0;
          this.refreshDataFlowDesc();
        } else if (this.flowRefreshPending && this.flowRefreshRetries < MAX_FLOW_REFRESH_RETRIES) {
          this.flowRefreshRetries++;
          this.refreshDataFlowDesc();
        }
      }
      this.scheduleFlowMonitor();
    }, FLOW_MONITOR_INTERVAL_MS);
  }

  private cancelFlowMonitor(): void {
    this.flowMonitorGeneration++;
    if (this.flowMonitorTimer !== -1) {
      clearTimeout(this.flowMonitorTimer);
      this.flowMonitorTimer = -1;
    }
  }

  /** Release stale descriptions before registering the current foreground session. */
  private refreshDataFlowDesc(): void {
    // Release the previous descriptors before reconnecting or going into background.
    this.clearDataFlowDesc();
    this.flowRefreshPending = this.registeredFlows.length > 0 || this.sceneEntered;
    if (!this.active || !this.supported || !this.dataFlowSupported || !this.streamingFlows ||
      this.flowRefreshPending ||
      deviceInfo.sdkApiVersion < DATA_FLOW_DESC_MIN_API ||
      AppStateService.getInstance().getCurrentState() !== AppState.FOREGROUND) {
      return;
    }
    if (canIUse(NETWORK_BOOST_SYSCAP)) {
      try {
        netBoost.setSceneDesc({
          scene: STREAMING_SERVICE_TYPE,
          sceneEvent: netBoost.SceneEvent.SCENE_EVENT_ENTER
        });
        this.sceneEntered = true;
      } catch (err) {
        const error: BusinessError = err;
        this.handleDataFlowError('setSceneDesc', error);
        return;
      }

      // Input latency and video delivery take priority; audio can fill an unused slot.
      this.registerOneFlow('control', this.streamingFlows.control);
      this.registerOneFlow('videoRtp', this.streamingFlows.videoRtp);
      this.registerOneFlow('audioRtp', this.streamingFlows.audioRtp);
    }
  }

  /** Fill one priority slot with a valid, distinct socket descriptor. */
  private registerOneFlow(name: string, socket: StreamSocketInfo): void {
    const fd = socket.fd;
    if (!this.dataFlowSupported || !Number.isInteger(fd) || fd < 0 ||
      this.registeredFlows.some((flow: RegisteredFlow): boolean => flow.sourceFd === fd) ||
      this.registeredFlows.length >= MAX_DATA_FLOW_DESCRIPTIONS) {
      return;
    }
    if (canIUse(NETWORK_BOOST_SYSCAP)) {
      let retainedFd = -1;
      try {
        retainedFd = MoonBridge.retainStreamSocket(fd, socket.localPort);
      } catch (err) {
        Logger.warn('NetworkBoostService', `[NetworkBoost] 复制串流 socket 失败: ${(err as Error).message}`);
      }
      if (!Number.isInteger(retainedFd) || retainedFd < 0) {
        this.flowRefreshPending = true;
        return;
      }
      try {
        const description: netBoost.DataFlowDesc = {
          dataFlowInfo: retainedFd,
          scene: STREAMING_SERVICE_TYPE,
          sceneEvent: netBoost.SceneEvent.SCENE_EVENT_ENTER,
          expectations: { priority: netBoost.PriorityLevel.PRIO_HIGH }
        };
        netBoost.setDataFlowDesc(description);
        this.registeredFlows.push({ sourceFd: fd, retainedFd: retainedFd });
        Logger.info('NetworkBoostService', '[NetworkBoost] setDataFlowDesc ' + name + ' fd=' + retainedFd);
      } catch (err) {
        MoonBridge.releaseStreamSocket(retainedFd);
        const error: BusinessError = err;
        this.handleDataFlowError('setDataFlowDesc ' + name, error);
      }
    }
  }

  /** Disable only optional flow setup when its scene or flow API is unavailable. */
  private handleDataFlowError(api: string, error: BusinessError): void {
    if (error.code === 801) {
      this.dataFlowSupported = false;
    }
    Logger.warn('NetworkBoostService', '[NetworkBoost] ' + api + ' failed: ' + error.message);
  }

  /** Keep failed releases pending, and leave the scene only after all flows are released. */
  private clearDataFlowDesc(): void {
    const flows = this.registeredFlows;
    this.registeredFlows = [];
    flows.forEach((flow: RegisteredFlow) => {
      const fd = flow.retainedFd;
      if (canIUse(NETWORK_BOOST_SYSCAP)) {
        try {
          const description: netBoost.DataFlowDesc = {
            dataFlowInfo: fd,
            scene: STREAMING_SERVICE_TYPE,
            sceneEvent: netBoost.SceneEvent.SCENE_EVENT_LEAVE
          };
          netBoost.setDataFlowDesc(description);
          MoonBridge.releaseStreamSocket(fd);
          Logger.info('NetworkBoostService', `[NetworkBoost] setDataFlowDesc fd=${fd} event=leave`);
        } catch (err) {
          this.registeredFlows.push(flow);
          Logger.warn('NetworkBoostService', `[NetworkBoost] setDataFlowDesc(fd=${fd}) leave 失败: ${(err as Error).message}`);
        }
      } else {
        MoonBridge.releaseStreamSocket(fd);
      }
    });
    if (this.registeredFlows.length > 0 || !this.sceneEntered) {
      return;
    }
    if (canIUse(NETWORK_BOOST_SYSCAP)) {
      try {
        netBoost.setSceneDesc({
          scene: STREAMING_SERVICE_TYPE,
          sceneEvent: netBoost.SceneEvent.SCENE_EVENT_LEAVE
        });
        this.sceneEntered = false;
        Logger.info('NetworkBoostService', '[NetworkBoost] setSceneDesc scene=realtimeGame event=leave');
      } catch (err) {
        Logger.warn('NetworkBoostService', `[NetworkBoost] clearDataFlowDesc 失败: ${(err as Error).message}`);
      }
    }
  }

  /** Retry background or stopped-session cleanup at most three times. */
  private scheduleCleanupRetry(): void {
    if ((this.active && AppStateService.getInstance().getCurrentState() === AppState.FOREGROUND) ||
      this.cleanupRetryTimer !== -1 || this.cleanupRetryCount >= MAX_CLEANUP_RETRIES ||
      (this.registeredFlows.length === 0 && !this.sceneEntered)) {
      return;
    }
    const generation = this.cleanupRetryGeneration;
    this.cleanupRetryTimer = setTimeout((): void => {
      if (generation !== this.cleanupRetryGeneration) {
        return;
      }
      this.cleanupRetryTimer = -1;
      if (this.active && AppStateService.getInstance().getCurrentState() === AppState.FOREGROUND) {
        return;
      }
      this.cleanupRetryCount++;
      this.clearDataFlowDesc();
      if (this.cleanupRetryCount >= MAX_CLEANUP_RETRIES && this.registeredFlows.length > 0) {
        // Never retain sockets indefinitely if the system refuses flow cleanup.
        Logger.warn('NetworkBoostService', '[NetworkBoost] 流描述清理失败，释放保留的 socket');
        this.registeredFlows.forEach((flow: RegisteredFlow) => MoonBridge.releaseStreamSocket(flow.retainedFd));
        this.registeredFlows = [];
        this.clearDataFlowDesc();
      }
      this.scheduleCleanupRetry();
    }, CLEANUP_RETRY_DELAY_MS);
  }

  /** A new session owns cleanup from here, so stale timers must not touch its flows. */
  private cancelCleanupRetry(): void {
    this.cleanupRetryGeneration++;
    if (this.cleanupRetryTimer !== -1) {
      clearTimeout(this.cleanupRetryTimer);
      this.cleanupRetryTimer = -1;
    }
    this.cleanupRetryCount = 0;
  }

  // ───── reportQoe ─────

  private reportInternal(state: StreamQoeState): void {
    if (!this.supported || this.lastState === state) {
      return;
    }
    this.lastState = state;
    if (canIUse(NETWORK_BOOST_SYSCAP)) {
      const qoeType: netQuality.QoeType = state === 'good' ? 'good' : 'highLatency';
      try {
        const appQoe: netQuality.AppQoe = {
          serviceType: STREAMING_SERVICE_TYPE,
          qoeType
        };
        netQuality.reportQoe(appQoe);
        Logger.info('NetworkBoostService', `[NetworkBoost] reportQoe serviceType=realtimeGame qoeType=${qoeType}`);
      } catch (err) {
        this.handleErr('reportQoe', err);
      }
    }
  }

  // ───── netQosChange ─────

  private subscribeQos(): void {
    if (!this.supported || this.qosCallback) {
      return;
    }
    const cb = (list: Array<netQuality.NetworkQos>): void => {
      if (!list || list.length === 0) {
        return;
      }
      if (canIUse(NETWORK_BOOST_SYSCAP)) {
        // 优先取主路径（WIFI_PRIMARY=2 / CELLULAR_PRIMARY=0）；否则取第一条
        let primary: netQuality.NetworkQos | undefined = list.find((q) =>
          q.pathType === 2 /* WIFI_PRIMARY */ || q.pathType === 0 /* CELLULAR_PRIMARY */);
        if (!primary) {
          primary = list[0];
        }
        const qos: SystemNetQos = {
          timestampMs: Date.now(),
          pathType: (primary.pathType ?? -1) as number,
          rttMs: primary.rttMs ?? 0,
          upBandwidthBps: primary.linkUpBandwidth ?? 0,
          downBandwidthBps: primary.linkDownBandwidth ?? 0,
          upRateBps: primary.linkUpRate ?? 0,
          downRateBps: primary.linkDownRate ?? 0,
          upBufferDelayMs: primary.linkUpBufferDelayMs ?? 0,
          upBufferCongestionPercent: primary.linkUpBufferCongestionPercent ?? 0
        };
        this.latestQos = qos;
        Logger.info('NetworkBoostService', `[NetworkBoost] netQos path=${qos.pathType} rtt=${qos.rttMs}ms ` +
          `bw=${(qos.upBandwidthBps / 1_000_000).toFixed(1)}/${(qos.downBandwidthBps / 1_000_000).toFixed(1)}Mbps ` +
          `rate=${(qos.upRateBps / 1_000_000).toFixed(1)}/${(qos.downRateBps / 1_000_000).toFixed(1)}Mbps ` +
          `bufDelay=${qos.upBufferDelayMs}ms cong=${qos.upBufferCongestionPercent}%`);
        this.listeners.forEach((listener) => {
          try {
            listener(qos);
          } catch (err) {
            Logger.warn('NetworkBoostService', `[NetworkBoost] listener 异常: ${(err as Error).message}`);
          }
        });
      }
    };
    if (canIUse(NETWORK_BOOST_SYSCAP)) {
      try {
        netQuality.on('netQosChange', cb);
        this.qosCallback = cb;
        Logger.info('NetworkBoostService', '[NetworkBoost] 订阅 netQosChange');
      } catch (err) {
        this.handleErr('on(netQosChange)', err);
      }
    }
  }

  private unsubscribeQos(): void {
    if (!this.qosCallback) {
      return;
    }
    if (canIUse(NETWORK_BOOST_SYSCAP)) {
      try {
        netQuality.off('netQosChange', this.qosCallback);
        Logger.info('NetworkBoostService', '[NetworkBoost] 取消订阅 netQosChange');
      } catch (err) {
        Logger.warn('NetworkBoostService', `[NetworkBoost] off(netQosChange) 失败: ${(err as Error).message}`);
      }
    }
    this.qosCallback = null;
  }

  // ───── netSceneChange（弱信号预测/拥塞） ─────

  private subscribeScene(): void {
    if (!this.supported || this.sceneCallback) {
      return;
    }
    const cb = (list: Array<netQuality.NetworkScene>): void => {
      if (!list || list.length === 0) {
        return;
      }
      if (canIUse(NETWORK_BOOST_SYSCAP)) {
        let primary: netQuality.NetworkScene | undefined = list.find((s) =>
          s.pathType === 2 /* WIFI_PRIMARY */ || s.pathType === 0 /* CELLULAR_PRIMARY */);
        if (!primary) {
          primary = list[0];
        }
        const wsp = primary.weakSignalPrediction;
        const wspValid = wsp && wsp.isLastPredictionValid && (wsp.duration ?? 0) > 0;
        const scene: SystemNetScene = {
          pathType: (primary.pathType ?? -1) as number,
          scene: (primary.scene ?? 'normal') as NetSceneType,
          recommendedAction: (primary.recommendedAction ?? 'keepData') as NetRecommendedAction,
          weakSignalStartSec: wspValid ? wsp!.startTime : undefined,
          weakSignalDurationSec: wspValid ? wsp!.duration : undefined
        };
        this.latestScene = scene;
        Logger.info('NetworkBoostService', `[NetworkBoost] netScene path=${scene.pathType} scene=${scene.scene} ` +
          `action=${scene.recommendedAction}` +
          (wspValid ? ` weakSignalIn=${scene.weakSignalStartSec}s for=${scene.weakSignalDurationSec}s` : ''));
        this.sceneListeners.forEach((listener) => {
          try {
            listener(scene);
          } catch (err) {
            Logger.warn('NetworkBoostService', `[NetworkBoost] scene listener 异常: ${(err as Error).message}`);
          }
        });
      }
    };
    if (canIUse(NETWORK_BOOST_SYSCAP)) {
      try {
        netQuality.on('netSceneChange', cb);
        this.sceneCallback = cb;
        Logger.info('NetworkBoostService', '[NetworkBoost] 订阅 netSceneChange');
      } catch (err) {
        this.handleErr('on(netSceneChange)', err);
      }
    }
  }

  private unsubscribeScene(): void {
    if (!this.sceneCallback) {
      return;
    }
    if (canIUse(NETWORK_BOOST_SYSCAP)) {
      try {
        netQuality.off('netSceneChange', this.sceneCallback);
        Logger.info('NetworkBoostService', '[NetworkBoost] 取消订阅 netSceneChange');
      } catch (err) {
        Logger.warn('NetworkBoostService', `[NetworkBoost] off(netSceneChange) 失败: ${(err as Error).message}`);
      }
    }
    this.sceneCallback = null;
  }

  private handleErr(api: string, err: object): void {
    const error = err as BusinessError;
    if (error.code === 801) {
      this.supported = false;
      Logger.info('NetworkBoostService', `[NetworkBoost] 设备不支持 NetworkBoostKit (${api})，已禁用`);
    } else {
      Logger.warn('NetworkBoostService', `[NetworkBoost] ${api} 失败 code=${error.code} msg=${error.message}`);
    }
  }
}
