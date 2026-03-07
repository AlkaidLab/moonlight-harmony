declare namespace socket {
  interface NetAddress {
    address: string;
    port?: number;
    family?: number;
  }
  interface UDPSocket {
    bind(address: NetAddress): Promise<void>;
    send(options: UDPSendOptions): Promise<void>;
    setExtraOptions(options: UDPExtraOptions): Promise<void>;
    close(): Promise<void>;
    on(type: string, callback: Function): void;
    off(type: string, callback?: Function): void;
  }
  interface UDPSendOptions {
    data: string | ArrayBuffer;
    address: NetAddress;
  }
  interface UDPExtraOptions {
    broadcast?: boolean;
    receiveBufferSize?: number;
    sendBufferSize?: number;
    reuseAddress?: boolean;
    socketTimeout?: number;
  }
  function constructUDPSocketInstance(): UDPSocket;
}
export default socket;
export { socket };
