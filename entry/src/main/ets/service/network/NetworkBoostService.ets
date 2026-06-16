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
 *   Step 3: 订阅 'netSceneChange' 弱信号预测 → 主动降码率/提示用户
 *   Step 4: 引入 netHandover 多网切换（远程串流场景，需 LINKTURBO 受限权限）
 */

import { netBoost, netQuality } from '@kit.NetworkBoostKit';
import { Available, BusinessError, deviceInfo } from '@kit.BasicServicesKit';

const STREAMING_SERVICE_TYPE: netQuality.ServiceType = 'realtimeGame';

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

export type NetworkBoostTransportProtocol = 'udp' | 'tcp';
export type NetworkBoostFlowPriority = 'normal' | 'high';

export interface NetworkBoostEndpoint {
  address: string;
  port: number;
}

export interface NetworkBoostFlowExpectation {
  /** 上行带宽，单位 Kbps */
  uplinkBandwidthKbps?: number;
  /** 下行带宽，单位 Kbps */
  downlinkBandwidthKbps?: number;
  /** 期望时延，单位毫秒 */
  latencyMs?: number;
  /** 请求/上传对象大小，单位 KB */
  objectSizeKb?: number;
  /** 流优先级 */
  priority?: NetworkBoostFlowPriority;
  /** 是否倾向低功耗传输 */
  lowPowerMode?: boolean;
}

export interface NetworkBoostFiveTupleFlow {
  flowType: 'fiveTuple';
  protocol: NetworkBoostTransportProtocol;
  local: NetworkBoostEndpoint;
  remote: NetworkBoostEndpoint;
  expectations?: NetworkBoostFlowExpectation;
}

export interface NetworkBoostSocketFlow {
  flowType: 'socket';
  socketFd: number;
  expectations?: NetworkBoostFlowExpectation;
}

export class NetworkBoostService {
  private static instance: NetworkBoostService | null = null;

  private active: boolean = false;
  private lastState: StreamQoeState | null = null;
  private supported: boolean = true;

  private qosCallback: ((list: Array<netQuality.NetworkQos>) => void) | null = null;
  private latestQos: SystemNetQos | null = null;
  private listeners: Set<SystemNetQosListener> = new Set();

  private sceneCallback: ((list: Array<netQuality.NetworkScene>) => void) | null = null;
  private latestScene: SystemNetScene | null = null;
  private sceneListeners: Set<SystemNetSceneListener> = new Set();
  private activeDataFlow: NetworkBoostFiveTupleFlow | NetworkBoostSocketFlow | null = null;

  static getInstance(): NetworkBoostService {
    if (!NetworkBoostService.instance) {
      NetworkBoostService.instance = new NetworkBoostService();
    }
    return NetworkBoostService.instance;
  }

  /** 串流会话开始：声明业务类型 + 订阅网络质量回调 */
  start(): void {
    if (this.active) {
      return;
    }
    this.active = true;
    this.lastState = null;
    this.reportInternal('good');
    this.subscribeQos();
    this.subscribeScene();
  }

  /** 串流会话结束：取消订阅 */
  stop(): void {
    if (!this.active) {
      return;
    }
    this.active = false;
    this.lastState = null;
    this.unsubscribeQos();
    this.unsubscribeScene();
    this.clearDataFlowDesc();
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
        console.warn(`[NetworkBoost] listener 异常: ${(err as Error).message}`);
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
        console.warn(`[NetworkBoost] scene listener 异常: ${(err as Error).message}`);
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
    return this.supported;
  }

  /**
   * HarmonyOS 26.0.0: 为关键串流 socket 标记实时游戏流。
   *
   * 只有在调用方能提供 native socket fd 或完整五元组时才调用；
   * 当前 ArkTS 层没有可靠本地端口/fd，因此先作为可选入口保留。
   */
  setDataFlowDesc(flow: NetworkBoostFiveTupleFlow | NetworkBoostSocketFlow): boolean {
    if (!this.supported || !this.active) {
      return false;
    }
    try {
      netBoost.setSceneDesc({
        scene: STREAMING_SERVICE_TYPE,
        sceneEvent: netBoost.SceneEvent.SCENE_EVENT_ENTER
      });
      if (flow.expectations?.lowPowerMode !== undefined && deviceInfo.sdkApiVersion >= 24) {
        netBoost.setLowPowerMode(flow.expectations.lowPowerMode);
      }
      this.activeDataFlow = flow;
      console.info('[NetworkBoost] setSceneDesc scene=realtimeGame event=enter');
      return true;
    } catch (err) {
      this.handleErr('setDataFlowDesc', err);
      return false;
    }
  }

  // ───── reportQoe ─────

  private reportInternal(state: StreamQoeState): void {
    if (!this.supported || this.lastState === state) {
      return;
    }
    this.lastState = state;
    const qoeType: netQuality.QoeType = state === 'good' ? 'good' : 'highLatency';
    try {
      const appQoe: netQuality.AppQoe = {
        serviceType: STREAMING_SERVICE_TYPE,
        qoeType
      };
      netQuality.reportQoe(appQoe);
      console.info(`[NetworkBoost] reportQoe serviceType=realtimeGame qoeType=${qoeType}`);
    } catch (err) {
      this.handleErr('reportQoe', err);
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
      console.info(`[NetworkBoost] netQos path=${qos.pathType} rtt=${qos.rttMs}ms ` +
        `bw=${(qos.upBandwidthBps / 1_000_000).toFixed(1)}/${(qos.downBandwidthBps / 1_000_000).toFixed(1)}Mbps ` +
        `rate=${(qos.upRateBps / 1_000_000).toFixed(1)}/${(qos.downRateBps / 1_000_000).toFixed(1)}Mbps ` +
        `bufDelay=${qos.upBufferDelayMs}ms cong=${qos.upBufferCongestionPercent}%`);
      this.listeners.forEach((listener) => {
        try {
          listener(qos);
        } catch (err) {
          console.warn(`[NetworkBoost] listener 异常: ${(err as Error).message}`);
        }
      });
    };
    try {
      netQuality.on('netQosChange', cb);
      this.qosCallback = cb;
      console.info('[NetworkBoost] 订阅 netQosChange');
    } catch (err) {
      this.handleErr('on(netQosChange)', err);
    }
  }

  private unsubscribeQos(): void {
    if (!this.qosCallback) {
      return;
    }
    try {
      netQuality.off('netQosChange', this.qosCallback);
      console.info('[NetworkBoost] 取消订阅 netQosChange');
    } catch (err) {
      console.warn(`[NetworkBoost] off(netQosChange) 失败: ${(err as Error).message}`);
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
      console.info(`[NetworkBoost] netScene path=${scene.pathType} scene=${scene.scene} ` +
        `action=${scene.recommendedAction}` +
        (wspValid ? ` weakSignalIn=${scene.weakSignalStartSec}s for=${scene.weakSignalDurationSec}s` : ''));
      this.sceneListeners.forEach((listener) => {
        try {
          listener(scene);
        } catch (err) {
          console.warn(`[NetworkBoost] scene listener 异常: ${(err as Error).message}`);
        }
      });
    };
    try {
      netQuality.on('netSceneChange', cb);
      this.sceneCallback = cb;
      console.info('[NetworkBoost] 订阅 netSceneChange');
    } catch (err) {
      this.handleErr('on(netSceneChange)', err);
    }
  }

  private unsubscribeScene(): void {
    if (!this.sceneCallback) {
      return;
    }
    try {
      netQuality.off('netSceneChange', this.sceneCallback);
      console.info('[NetworkBoost] 取消订阅 netSceneChange');
    } catch (err) {
      console.warn(`[NetworkBoost] off(netSceneChange) 失败: ${(err as Error).message}`);
    }
    this.sceneCallback = null;
  }

  private clearDataFlowDesc(): void {
    if (!this.activeDataFlow) {
      this.activeDataFlow = null;
      return;
    }
    try {
      netBoost.setSceneDesc({
        scene: STREAMING_SERVICE_TYPE,
        sceneEvent: netBoost.SceneEvent.SCENE_EVENT_LEAVE
      });
      console.info('[NetworkBoost] setSceneDesc scene=realtimeGame event=leave');
    } catch (err) {
      console.warn(`[NetworkBoost] clearDataFlowDesc 澶辫触: ${(err as Error).message}`);
    }
    this.activeDataFlow = null;
  }

  private handleErr(api: string, err: object): void {
    const error = err as BusinessError;
    if (error.code === 801) {
      this.supported = false;
      console.info(`[NetworkBoost] 设备不支持 NetworkBoostKit (${api})，已禁用`);
    } else {
      console.warn(`[NetworkBoost] ${api} 失败 code=${error.code} msg=${error.message}`);
    }
  }
}
