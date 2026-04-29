/**
 * @ohos.networkBoost.netQuality stub
 * Public OpenHarmony SDK lacks the HMS Network Boost Kit; this stub provides
 * just enough surface for the codebase to compile under CI. Real device runtime
 * loads the actual HMS implementation (richer than this stub).
 *
 * Field set kept aligned with HarmonyOS NEXT3 SDK 6.0.0 (API 20):
 *   NetworkQos: linkUp/DownBandwidth, linkUp/DownRate, rttMs,
 *               linkUpBufferDelayMs, linkUpBufferCongestionPercent.
 */
declare namespace netQuality {
  type ServiceType =
    | 'default' | 'background' | 'realtimeVoice' | 'realtimeVideo'
    | 'callSignaling' | 'realtimeGame' | 'normalGame' | 'shortVideo'
    | 'longVideo' | 'livestreamingAnchor' | 'livestreamingWatcher'
    | 'download' | 'upload' | 'browser' | 'transaction' | 'shopping'
    | 'detection' | 'cloudService' | 'voiceConference' | 'videoConference'
    | 'audio' | 'navigation' | 'seckillService' | 'login';

  type BadQoeCause =
    | 'unknown' | 'serverErr' | 'noData' | 'packetLost'
    | 'packetOutOfOrder' | 'highJitter' | 'highLatency';

  type QoeType = 'good' | BadQoeCause;

  interface AppQoe {
    serviceType?: ServiceType;
    qoeType?: QoeType;
  }

  enum PathType {
    CELLULAR_PRIMARY = 0,
    CELLULAR_SECONDARY = 1,
    WIFI_PRIMARY = 2,
    WIFI_SECONDARY = 3
  }

  type RateBps = number;

  interface NetworkQos {
    pathType?: PathType;
    linkUpBandwidth?: RateBps;
    linkDownBandwidth?: RateBps;
    linkUpRate?: RateBps;
    linkDownRate?: RateBps;
    rttMs?: number;
    linkUpBufferDelayMs?: number;
    linkUpBufferCongestionPercent?: number;
  }

  type Scene = 'normal' | 'congestion' | 'frequentHandover' | 'weakSignal';
  type DataSpeedSimpleAction = 'suspendData' | 'decreaseData' | 'increaseData' | 'keepData';
  type RecommendedAction = 'doCaching' | DataSpeedSimpleAction;

  interface WeakSignalPrediction {
    isLastPredictionValid?: boolean;
    startTime?: number;
    duration?: number;
  }

  interface NetworkScene {
    pathType?: PathType;
    scene?: Scene;
    recommendedAction?: RecommendedAction;
    weakSignalPrediction?: WeakSignalPrediction;
  }

  type NetQosChangeCallback = (list: Array<NetworkQos>) => void;
  type NetSceneChangeCallback = (list: Array<NetworkScene>) => void;

  function on(type: 'netQosChange', callback: NetQosChangeCallback): void;
  function off(type: 'netQosChange', callback?: NetQosChangeCallback): void;
  function on(type: 'netSceneChange', callback: NetSceneChangeCallback): void;
  function off(type: 'netSceneChange', callback?: NetSceneChangeCallback): void;
  function reportQoe(appQoe: AppQoe): void;
}

export default netQuality;
