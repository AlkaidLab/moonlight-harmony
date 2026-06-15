/**
 * @ohos.networkBoost.netBoost stub
 * Public OpenHarmony SDK lacks the HMS Network Boost Kit; this stub provides
 * the small netBoost surface used by CI builds. Real device runtime loads the
 * actual HMS implementation.
 */
import netQuality from '@ohos.networkBoost.netQuality';

declare namespace netBoost {
  interface SceneDesc {
    scene: netQuality.ServiceType;
    sceneEvent: SceneEvent;
    startTime?: number;
    duration?: number;
  }

  enum SceneEvent {
    SCENE_EVENT_ENTER = 0,
    SCENE_EVENT_UPDATE = 1,
    SCENE_EVENT_LEAVE = 2
  }

  interface DataFlowDesc {
    dataFlowInfo: DataFlowInfo | SocketFd;
    scene: netQuality.ServiceType;
    sceneEvent: SceneEvent;
    expectations?: ExpectedDescription;
  }

  type SocketFd = number;

  interface DataFlowInfo {
    protocol: ProtocolType;
    local: NetAddress;
    remote: NetAddress;
  }

  interface ExpectedDescription {
    uplinkBandwidth?: number;
    downlinkBandwidth?: number;
    latency?: number;
    objectSize?: number;
    priority?: PriorityLevel;
    lowPowerMode?: boolean;
  }

  interface NetAddress {
    address: string;
    port: number;
  }

  enum ProtocolType {
    PROTOCOL_UDP = 0,
    PROTOCOL_TCP = 1
  }

  enum PriorityLevel {
    PRIO_NORMAL = 0,
    PRIO_HIGH = 1
  }

  function setSceneDesc(sceneDesc: SceneDesc): void;
  function setDataFlowDesc(dataFlowDesc: DataFlowDesc): void;
  function setLowPowerMode(isEnable: boolean): void;
}

export default netBoost;
