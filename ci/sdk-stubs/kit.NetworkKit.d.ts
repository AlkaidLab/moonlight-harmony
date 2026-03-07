declare module '@kit.NetworkKit' {
  namespace socket {
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
  namespace http {
    enum RequestMethod { OPTIONS, GET, HEAD, POST, PUT, DELETE, TRACE, CONNECT }
    enum HttpDataType { STRING, OBJECT, ARRAY_BUFFER }
    interface HttpRequestOptions {
      method?: RequestMethod;
      extraData?: string | Object | ArrayBuffer;
      header?: Object;
      readTimeout?: number;
      connectTimeout?: number;
      expectDataType?: HttpDataType;
      usingCache?: boolean;
    }
    interface HttpResponse {
      result: string | Object | ArrayBuffer;
      responseCode: number;
      header: Object;
    }
    interface HttpRequest {
      request(url: string, options?: HttpRequestOptions, callback?: (err: Object, data: HttpResponse) => void): Promise<HttpResponse>;
      destroy(): void;
      on(type: string, callback: Function): void;
      off(type: string, callback?: Function): void;
    }
    function createHttp(): HttpRequest;
  }
  namespace connection {
    interface NetHandle {
      netId: number;
    }
    interface NetConnection {
      on(type: string, callback: Function): void;
      off(type: string, callback?: Function): void;
      register(callback: (err: Object) => void): void;
      unregister(callback: (err: Object) => void): void;
    }
    function createNetConnection(): NetConnection;
    function getDefaultNet(): Promise<NetHandle>;
    function hasDefaultNet(): Promise<boolean>;
    function getDefaultNetSync(): NetHandle;
    function hasDefaultNetSync(): boolean;
  }
  namespace webSocket {
    interface WebSocket {
      connect(url: string, options?: Object): Promise<boolean>;
      send(data: string | ArrayBuffer): Promise<boolean>;
      close(): Promise<boolean>;
      on(type: string, callback: Function): void;
      off(type: string, callback?: Function): void;
    }
    function createWebSocket(): WebSocket;
  }
  namespace mdns {
    interface LocalServiceInfo {
      serviceType: string;
      serviceName?: string;
      port?: number;
      host?: Object;
    }
    interface DiscoveryEventInfo {
      serviceInfo: LocalServiceInfo;
      errorCode?: number;
    }
    interface DiscoveryService {
      startSearchingMDNS(): void;
      stopSearchingMDNS(): void;
      on(type: string, callback: Function): void;
      off(type: string, callback?: Function): void;
    }
    function createDiscoveryService(context: Object, serviceType: string): DiscoveryService;
    function resolveLocalService(context: Object, serviceInfo: LocalServiceInfo): Promise<LocalServiceInfo>;
  }
  export { socket, http, connection, webSocket, mdns };
}
