import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 发现的计算机信息
 */
export interface DiscoveredComputer {
  name: string;           // 主机名
  address: string;        // IP 地址
  port: number;           // 服务端口
  ipv6Address?: string;   // IPv6 地址（可选）
}

/**
 * mDNS 服务发现
 *
 * 用于在局域网内发现运行 NVIDIA GameStream / Sunshine 的主机
 * 参考 Android 版本的 NsdManagerDiscoveryAgent 实现
 */
export class MdnsDiscovery {
  private static readonly SERVICE_TYPE = '_nvstream._tcp';
  private static readonly DISCOVERY_TIMEOUT = 5000;  // 5秒超时

  private discoveryService: mdns.DiscoveryService | null = null;
  private discoveredComputers: Map<string, DiscoveredComputer> = new Map();
  private isDiscovering: boolean = false;
  private context: common.Context;
  private onComputerFound: ((computer: DiscoveredComputer) => void) | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  /**
   * 设置计算机发现回调
   */
  setOnComputerFoundListener(callback: (computer: DiscoveredComputer) => void): void {
    this.onComputerFound = callback;
  }

  /**
   * 开始发现局域网内的主机
   */
  async startDiscovery(): Promise<void> {
    if (this.isDiscovering) {
      console.info('MdnsDiscovery: 已经在发现中');
      return;
    }

    this.isDiscovering = true;
    this.discoveredComputers.clear();

    console.info(`MdnsDiscovery: 开始发现服务类型 ${MdnsDiscovery.SERVICE_TYPE}`);

    try {
      // 创建 mDNS 发现服务
      this.discoveryService = mdns.createDiscoveryService(
        this.context,
        MdnsDiscovery.SERVICE_TYPE
      );

      // 监听服务发现事件
      this.discoveryService.on('serviceFound', (serviceInfo: mdns.LocalServiceInfo) => {
        console.info(`MdnsDiscovery: 发现服务 ${serviceInfo.serviceName}`);
        this.resolveService(serviceInfo);
      });

      // 监听服务丢失事件
      this.discoveryService.on('serviceLost', (serviceInfo: mdns.LocalServiceInfo) => {
        console.info(`MdnsDiscovery: 服务丢失 ${serviceInfo.serviceName}`);
        this.discoveredComputers.delete(serviceInfo.serviceName);
      });

      // 开始搜索
      this.discoveryService.startSearchingMDNS();

    } catch (err) {
      const error = err as BusinessError;
      console.error(`MdnsDiscovery: 启动发现失败 - ${error.code}: ${error.message}`);
      this.isDiscovering = false;
      throw err;
    }
  }

  /**
   * 解析服务获取详细信息
   */
  private async resolveService(serviceInfo: mdns.LocalServiceInfo): Promise<void> {
    try {
      const resolvedService = await mdns.resolveLocalService(this.context, serviceInfo);

      console.info(`MdnsDiscovery: 解析服务 ${resolvedService.serviceName}`);
      console.info(`  - 主机: ${resolvedService.host?.address}`);
      console.info(`  - 端口: ${resolvedService.port}`);

      if (resolvedService.host?.address) {
        const computer: DiscoveredComputer = {
          name: resolvedService.serviceName,
          address: resolvedService.host.address,
          port: resolvedService.port || 47984
        };

        // 检查是否是 IPv6 地址
        if (resolvedService.host.address.includes(':')) {
          computer.ipv6Address = resolvedService.host.address;
          // IPv6 地址，尝试获取 IPv4
          // HarmonyOS API 可能只返回一个地址，暂时使用 IPv6
        }

        this.discoveredComputers.set(computer.name, computer);

        // 通知回调
        if (this.onComputerFound) {
          this.onComputerFound(computer);
        }
      }
    } catch (err) {
      const error = err as BusinessError;
      console.error(`MdnsDiscovery: 解析服务失败 - ${error.code}: ${error.message}`);
    }
  }

  /**
   * 停止发现
   */
  stopDiscovery(): void {
    if (!this.isDiscovering || !this.discoveryService) {
      return;
    }

    console.info('MdnsDiscovery: 停止发现');

    try {
      this.discoveryService.stopSearchingMDNS();
      this.discoveryService.off('serviceFound');
      this.discoveryService.off('serviceLost');
    } catch (err) {
      console.error('MdnsDiscovery: 停止发现失败', err);
    }

    this.discoveryService = null;
    this.isDiscovering = false;
  }

  /**
   * 发现一段时间后返回结果
   */
  async discover(timeout: number = MdnsDiscovery.DISCOVERY_TIMEOUT): Promise<DiscoveredComputer[]> {
    await this.startDiscovery();

    // 等待发现超时
    await new Promise(resolve => setTimeout(resolve, timeout));

    this.stopDiscovery();

    return Array.from(this.discoveredComputers.values());
  }

  /**
   * 获取已发现的计算机列表
   */
  getDiscoveredComputers(): DiscoveredComputer[] {
    return Array.from(this.discoveredComputers.values());
  }

  /**
   * 是否正在发现
   */
  isSearching(): boolean {
    return this.isDiscovering;
  }
}
