
declare namespace netBoost {
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

  function setDataFlowDesc(dataFlowDesc: DataFlowDesc): void;
}
