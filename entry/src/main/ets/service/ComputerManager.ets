import { ComputerInfo, ComputerState, PairState, ComputerInfoBuilder } from '../model/ComputerInfo';
import { NvHttp } from './NvHttp';
import { MdnsDiscovery, DiscoveredComputer } from './MdnsDiscovery';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';

/**
 * 电脑管理器 - 管理所有已发现和手动添加的电脑
 */
export class ComputerManager {
  private static instance: ComputerManager;
  private computers: Map<string, ComputerInfo> = new Map();
  private mdnsDiscovery: MdnsDiscovery | null = null;
  private context: common.Context | null = null;
  private onComputerListChanged: (() => void) | null = null;

  private constructor() {
    // mdnsDiscovery 需要在 init 时使用 context 初始化
  }

  static getInstance(): ComputerManager {
    if (!ComputerManager.instance) {
      ComputerManager.instance = new ComputerManager();
    }
    return ComputerManager.instance;
  }

  /**
   * 初始化，需要传入 Context
   */
  init(context: common.Context): void {
    this.context = context;
    this.mdnsDiscovery = new MdnsDiscovery(context);

    // 设置 mDNS 发现回调
    this.mdnsDiscovery.setOnComputerFoundListener((discovered: DiscoveredComputer) => {
      this.handleDiscoveredComputer(discovered);
    });

    // 加载已保存的电脑
    this.loadComputers();
  }

  /**
   * 设置电脑列表变化回调
   */
  setOnComputerListChangedListener(callback: () => void): void {
    this.onComputerListChanged = callback;
  }

  /**
   * 处理 mDNS 发现的电脑
   */
  private async handleDiscoveredComputer(discovered: DiscoveredComputer): Promise<void> {
    console.info(`ComputerManager: 处理发现的电脑 ${discovered.name} @ ${discovered.address}`);

    // 检查是否已存在（按地址匹配）
    const existing = Array.from(this.computers.values())
      .find(c => c.address === discovered.address || c.localAddress === discovered.address);

    if (existing) {
      // 更新已有电脑的状态
      existing.state = ComputerState.ONLINE;
      console.info(`ComputerManager: 更新已有电脑 ${existing.name}`);
    } else {
      // 尝试连接并添加新电脑
      try {
        await this.addComputerInternal(discovered.address, discovered.name);
      } catch (err) {
        console.error(`ComputerManager: 无法添加电脑 ${discovered.name}: ${err}`);
      }
    }

    // 通知列表变化
    if (this.onComputerListChanged) {
      this.onComputerListChanged();
    }
  }

  /**
   * 获取所有电脑列表
   */
  async getComputers(): Promise<ComputerInfo[]> {
    return Array.from(this.computers.values());
  }

  /**
   * 根据 UUID 获取电脑
   */
  getComputer(uuid: string): ComputerInfo | undefined {
    return this.computers.get(uuid);
  }

  /**
   * 手动添加电脑
   */
  async addComputer(address: string): Promise<ComputerInfo> {
    return this.addComputerInternal(address);
  }

  /**
   * 内部添加电脑方法
   */
  private async addComputerInternal(address: string, discoveredName?: string): Promise<ComputerInfo> {
    const nvHttp = new NvHttp(address, null);

    try {
      // 获取服务器信息
      const serverInfo = await nvHttp.getServerInfo();

      const computer = new ComputerInfoBuilder()
        .setUuid(serverInfo.uniqueId)
        .setName(serverInfo.hostname || discoveredName || address)
        .setAddress(address)
        .setLocalAddress(address)
        .setState(ComputerState.ONLINE)
        .setPairState(serverInfo.paired ? PairState.PAIRED : PairState.NOT_PAIRED)
        .build();

      this.computers.set(computer.uuid, computer);
      await this.saveComputers();

      console.info(`ComputerManager: 成功添加电脑 ${computer.name} (${computer.uuid})`);
      return computer;
    } catch (err) {
      // 如果无法获取服务器信息，仍然添加但标记为离线
      if (discoveredName) {
        const computer = new ComputerInfoBuilder()
          .setUuid(`discovered-${Date.now()}`)
          .setName(discoveredName)
          .setAddress(address)
          .setLocalAddress(address)
          .setState(ComputerState.UNKNOWN)
          .setPairState(PairState.NOT_PAIRED)
          .build();

        this.computers.set(computer.uuid, computer);
        console.info(`ComputerManager: 添加未确认电脑 ${computer.name}`);
        return computer;
      }
      throw new Error(`无法连接到 ${address}: ${err}`);
    }
  }

  /**
   * 删除电脑
   */
  async removeComputer(uuid: string): Promise<void> {
    this.computers.delete(uuid);
    await this.saveComputers();
  }

  /**
   * 刷新所有电脑状态
   */
  async refreshAllComputers(): Promise<void> {
    const refreshPromises = Array.from(this.computers.values()).map(async (computer) => {
      try {
        const nvHttp = new NvHttp(computer.address, computer.serverCert);
        const serverInfo = await nvHttp.getServerInfo();
        
        computer.state = ComputerState.ONLINE;
        computer.runningGameId = serverInfo.currentGame;
      } catch {
        computer.state = ComputerState.OFFLINE;
      }
    });

    await Promise.all(refreshPromises);
  }

  /**
   * 扫描网络发现电脑
   */
  async scanNetwork(): Promise<void> {
    if (!this.mdnsDiscovery) {
      console.error('ComputerManager: mDNS 发现服务未初始化');
      return;
    }

    console.info('ComputerManager: 开始扫描网络...');

    try {
      const discovered = await this.mdnsDiscovery.discover(5000);
      console.info(`ComputerManager: 发现 ${discovered.length} 台电脑`);

      for (const computer of discovered) {
        // handleDiscoveredComputer 会在 mDNS 回调中被调用
        // 这里只是确保超时后也处理完毕
      }
    } catch (err) {
      console.error('ComputerManager: 网络扫描失败', err);
    }
  }

  /**
   * 开始持续扫描（后台）
   */
  startBackgroundScan(): void {
    if (!this.mdnsDiscovery) {
      return;
    }

    this.mdnsDiscovery.startDiscovery().catch(err => {
      console.error('ComputerManager: 后台扫描启动失败', err);
    });
  }

  /**
   * 停止后台扫描
   */
  stopBackgroundScan(): void {
    if (this.mdnsDiscovery) {
      this.mdnsDiscovery.stopDiscovery();
    }
  }

  /**
   * 与电脑配对
   */
  async pairComputer(uuid: string): Promise<string> {
    const computer = this.computers.get(uuid);
    if (!computer) {
      throw new Error('电脑不存在');
    }

    const nvHttp = new NvHttp(computer.address, null);
    const pin = this.generatePin();
    
    computer.pairState = PairState.NOT_PAIRED;
    
    try {
      await nvHttp.pair(pin);
      computer.pairState = PairState.PAIRED;
      computer.serverCert = nvHttp.getServerCert();
      await this.saveComputers();
      return pin;
    } catch (err) {
      computer.pairState = PairState.FAILED;
      throw err;
    }
  }

  /**
   * 取消配对
   */
  async unpairComputer(uuid: string): Promise<void> {
    const computer = this.computers.get(uuid);
    if (!computer) {
      throw new Error('电脑不存在');
    }

    const nvHttp = new NvHttp(computer.address, computer.serverCert);
    await nvHttp.unpair();
    
    computer.pairState = PairState.NOT_PAIRED;
    computer.serverCert = '';
    await this.saveComputers();
  }

  /**
   * 网络唤醒 (Wake-on-LAN)
   */
  async wakeComputer(uuid: string): Promise<void> {
    const computer = this.computers.get(uuid);
    if (!computer || !computer.macAddress) {
      throw new Error('无法唤醒：缺少 MAC 地址');
    }

    // TODO: 发送 WOL 魔术包
  }

  /**
   * 生成配对 PIN 码
   */
  private generatePin(): string {
    let pin = '';
    for (let i = 0; i < 4; i++) {
      pin += Math.floor(Math.random() * 10).toString();
    }
    return pin;
  }

  /**
   * 保存电脑列表到持久化存储
   */
  private async saveComputers(): Promise<void> {
    // TODO: 使用 Preferences 保存
  }

  /**
   * 从持久化存储加载电脑列表
   */
  private async loadComputers(): Promise<void> {
    // TODO: 从 Preferences 加载
  }
}
