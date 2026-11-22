declare namespace rcp {
  interface CertificateConfig {
    type: string;
    filePath: string;
    key: string;
  }
  interface SecurityConfiguration {
    remoteValidation?: 'skip' | 'system';
    certificate?: CertificateConfig;
  }
  interface TimeoutConfig {
    connectMs?: number;
    transferMs?: number;
  }
  interface TransferConfig {
    timeout?: TimeoutConfig;
  }
  interface Configuration {
    security?: SecurityConfiguration;
    transfer?: TransferConfig;
  }
  interface RequestConfiguration extends Configuration {}
  interface ConnectionConfiguration {
    maxConnectionsPerHost?: number;
    maxTotalConnections?: number;
  }
  interface SessionConfiguration {
    requestConfiguration?: RequestConfiguration;
    connectionConfiguration?: ConnectionConfiguration;
  }
  interface Response {
    statusCode: number;
    body?: ArrayBuffer;
  }
  class Request {
    constructor(
      url: string,
      method?: string,
      headers?: Record<string, string>,
      body?: string | ArrayBuffer,
      reserved1?: object,
      reserved2?: object,
      configuration?: Configuration
    );
  }
  interface Session {
    get(url: string): Promise<Response>;
    fetch(request: Request): Promise<Response>;
    close(): void;
  }
  function createSession(config?: SessionConfiguration): Session;
}
export default rcp;
export { rcp };
