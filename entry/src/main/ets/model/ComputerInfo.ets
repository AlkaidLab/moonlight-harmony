/**
 * 电脑信息模型
 */
export enum ComputerState {
  UNKNOWN = 0,
  ONLINE = 1,
  OFFLINE = 2,
  PAIRING = 3
}

export interface ComputerInfo {
  uuid: string;
  name: string;
  address: string;
  localAddress: string;
  remoteAddress: string;
  macAddress: string;
  state: ComputerState;
  pairState: PairState;
  runningGameId: number;
  serverCert: string;
  gpuType: string;
  maxSupportedResolution: Resolution;
  isNvidiaSoftware: boolean;
}

export enum PairState {
  NOT_PAIRED = 0,
  PAIRED = 1,
  PIN_WRONG = 2,
  FAILED = 3
}

export interface Resolution {
  width: number;
  height: number;
}

export class ComputerInfoBuilder {
  private info: ComputerInfo;

  constructor() {
    this.info = {
      uuid: '',
      name: '',
      address: '',
      localAddress: '',
      remoteAddress: '',
      macAddress: '',
      state: ComputerState.UNKNOWN,
      pairState: PairState.NOT_PAIRED,
      runningGameId: 0,
      serverCert: '',
      gpuType: '',
      maxSupportedResolution: { width: 1920, height: 1080 },
      isNvidiaSoftware: false
    };
  }

  setUuid(uuid: string): ComputerInfoBuilder {
    this.info.uuid = uuid;
    return this;
  }

  setName(name: string): ComputerInfoBuilder {
    this.info.name = name;
    return this;
  }

  setAddress(address: string): ComputerInfoBuilder {
    this.info.address = address;
    return this;
  }

  setLocalAddress(localAddress: string): ComputerInfoBuilder {
    this.info.localAddress = localAddress;
    return this;
  }

  setRemoteAddress(remoteAddress: string): ComputerInfoBuilder {
    this.info.remoteAddress = remoteAddress;
    return this;
  }

  setMacAddress(macAddress: string): ComputerInfoBuilder {
    this.info.macAddress = macAddress;
    return this;
  }

  setState(state: ComputerState): ComputerInfoBuilder {
    this.info.state = state;
    return this;
  }

  setPairState(pairState: PairState): ComputerInfoBuilder {
    this.info.pairState = pairState;
    return this;
  }

  setRunningGameId(gameId: number): ComputerInfoBuilder {
    this.info.runningGameId = gameId;
    return this;
  }

  setServerCert(cert: string): ComputerInfoBuilder {
    this.info.serverCert = cert;
    return this;
  }

  setGpuType(gpuType: string): ComputerInfoBuilder {
    this.info.gpuType = gpuType;
    return this;
  }

  setMaxSupportedResolution(res: Resolution): ComputerInfoBuilder {
    this.info.maxSupportedResolution = res;
    return this;
  }

  setIsNvidiaSoftware(isNvidia: boolean): ComputerInfoBuilder {
    this.info.isNvidiaSoftware = isNvidia;
    return this;
  }

  build(): ComputerInfo {
    const result: ComputerInfo = {
      uuid: this.info.uuid,
      name: this.info.name,
      address: this.info.address,
      localAddress: this.info.localAddress,
      remoteAddress: this.info.remoteAddress,
      macAddress: this.info.macAddress,
      state: this.info.state,
      pairState: this.info.pairState,
      runningGameId: this.info.runningGameId,
      serverCert: this.info.serverCert,
      gpuType: this.info.gpuType,
      maxSupportedResolution: {
        width: this.info.maxSupportedResolution.width,
        height: this.info.maxSupportedResolution.height
      },
      isNvidiaSoftware: this.info.isNvidiaSoftware
    };
    return result;
  }
}
