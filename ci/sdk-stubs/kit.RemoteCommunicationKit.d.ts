declare module '@kit.RemoteCommunicationKit' {
  namespace rcp {
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
    interface RequestConfiguration {
      security?: SecurityConfiguration;
      transfer?: TransferConfig;
    }
    interface SessionConfiguration {
      requestConfiguration?: RequestConfiguration;
    }
    interface Response {
      statusCode: number;
      body: ArrayBuffer;
    }
    interface Session {
      get(url: string): Promise<Response>;
      close(): void;
    }
    function createSession(config?: SessionConfiguration): Session;
  }
  export { rcp };
}
