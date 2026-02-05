/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { ComputerInfo, ComputerState, PairState } from '../model/ComputerInfo';
import { ComputerManager } from '../service/ComputerManager';

/**
 * 可观察的电脑数据类
 * 使用 @Observed 装饰器支持深度响应式
 * 注意：避免在 @Observed 类中使用 getter，会导致性能问题
 */
@Observed
export class ObservableComputer {
  uuid: string = '';
  name: string = '';
  address: string = '';
  state: ComputerState = ComputerState.UNKNOWN;
  pairState: PairState = PairState.NOT_PAIRED;
  runningGameId: number = 0;
  serverCert: string = '';
  macAddress: string = '';
  localAddress: string = '';
  remoteAddress: string = '';
  pairName: string = '';
  gpuType: string = '';
  isNvidiaSoftware: boolean = false;
  // 主机头像 - 使用第一个应用的缩略图
  boxArtUrl: string = '';
  // 自定义 HTTP 端口
  httpPort: number | undefined = undefined;
  
  // 缓存的状态值 - 避免使用 getter 引起的性能问题
  isOnline: boolean = false;
  isPaired: boolean = false;
  isGaming: boolean = false;
  statusText: string = '离线';
  
  constructor(info?: ComputerInfo) {
    if (info) {
      this.updateFrom(info);
    }
  }
  
  updateFrom(info: ComputerInfo): void {
    this.uuid = info.uuid;
    this.name = info.name;
    this.address = info.address;
    this.state = info.state;
    this.pairState = info.pairState;
    this.runningGameId = info.runningGameId;
    this.serverCert = info.serverCert;
    this.macAddress = info.macAddress;
    this.localAddress = info.localAddress;
    this.remoteAddress = info.remoteAddress;
    this.pairName = info.pairName;
    this.gpuType = info.gpuType;
    this.isNvidiaSoftware = info.isNvidiaSoftware;
    this.boxArtUrl = info.boxArtUrl || '';
    this.httpPort = info.httpPort;
    
    // 更新缓存的计算值
    this.updateCachedValues();
  }
  
  // 更新缓存的计算值
  private updateCachedValues(): void {
    this.isOnline = this.state === ComputerState.ONLINE;
    this.isPaired = this.pairState === PairState.PAIRED;
    this.isGaming = this.runningGameId > 0;
    
    if (!this.isOnline) {
      this.statusText = '离线';
    } else if (!this.isPaired) {
      this.statusText = '未配对';
    } else if (this.isGaming) {
      this.statusText = '正在运行游戏';
    } else {
      this.statusText = '在线';
    }
  }
  
  toComputerInfo(): ComputerInfo {
    const info: ComputerInfo = {
      uuid: this.uuid,
      name: this.name,
      address: this.address,
      state: this.state,
      pairState: this.pairState,
      runningGameId: this.runningGameId,
      serverCert: this.serverCert,
      macAddress: this.macAddress,
      localAddress: this.localAddress,
      remoteAddress: this.remoteAddress,
      pairName: this.pairName,
      gpuType: this.gpuType,
      maxSupportedResolution: { width: 1920, height: 1080 },
      isNvidiaSoftware: this.isNvidiaSoftware,
      boxArtUrl: this.boxArtUrl,
      httpPort: this.httpPort
    };
    return info;
  }
}

/**
 * 电脑列表 ViewModel
 * 
 * 管理电脑列表的状态和业务逻辑
 */
@Observed
export class ComputerListViewModel {
  // 电脑列表
  computers: ObservableComputer[] = [];
  
  // 加载状态
  isLoading: boolean = false;
  isRefreshing: boolean = false;
  
  // 错误信息
  errorMessage: string = '';
  
  // 选中的电脑（用于详情/操作）
  selectedComputer: ObservableComputer | null = null;
  
  // 配对相关
  isPairing: boolean = false;
  pairingPin: string = '';
  pairingComputer: ObservableComputer | null = null;
  
  private computerManager: ComputerManager;
  
  constructor() {
    this.computerManager = ComputerManager.getInstance();
  }
  
  /**
   * 加载电脑列表
   */
  async loadComputers(): Promise<void> {
    if (this.isLoading) return;
    
    this.isLoading = true;
    this.errorMessage = '';
    
    try {
      const computerInfos = await this.computerManager.getComputers();
      this.updateComputerList(computerInfos);
    } catch (error) {
      const err = error as Error;
      this.errorMessage = `加载失败: ${err.message}`;
    } finally {
      this.isLoading = false;
    }
  }
  
  /**
   * 刷新电脑列表（重新轮询）
   */
  async refreshComputers(): Promise<void> {
    if (this.isRefreshing) return;
    
    this.isRefreshing = true;
    
    try {
      // 轮询所有电脑获取最新状态
      const computers = await this.computerManager.getComputers();
      for (const computer of computers) {
        await this.computerManager.pollComputer(computer);
      }
      this.updateComputerList(await this.computerManager.getComputers());
    } catch (error) {
      const err = error as Error;
      this.errorMessage = `刷新失败: ${err.message}`;
    } finally {
      this.isRefreshing = false;
    }
  }
  
  /**
   * 更新电脑列表
   */
  private updateComputerList(infos: ComputerInfo[]): void {
    // 更新现有项或添加新项
    const existingUuids = new Set(this.computers.map(c => c.uuid));
    const newUuids = new Set(infos.map(i => i.uuid));
    
    // 更新现有电脑
    for (const computer of this.computers) {
      const info = infos.find(i => i.uuid === computer.uuid);
      if (info) {
        computer.updateFrom(info);
      }
    }
    
    // 添加新电脑
    for (const info of infos) {
      if (!existingUuids.has(info.uuid)) {
        this.computers.push(new ObservableComputer(info));
      }
    }
    
    // 移除已删除的电脑
    this.computers = this.computers.filter(c => newUuids.has(c.uuid));
    
    // 更新缓存的统计值，触发 UI 更新
    this.updateCachedCounts();
  }
  
  /**
   * 更新缓存的统计值（触发 @Observed 响应式更新）
   */
  private updateCachedCounts(): void {
    this.computerCount = this.computers.length;
    this.onlineCount = this.computers.filter(c => c.isOnline).length;
  }
  
  /**
   * 添加电脑
   */
  async addComputer(address: string): Promise<boolean> {
    this.isLoading = true;
    this.errorMessage = '';
    
    try {
      const result = await this.computerManager.addComputer(address);
      if (result) {
        this.updateComputerList(await this.computerManager.getComputers());
        return true;
      } else {
        this.errorMessage = '无法连接到主机';
        return false;
      }
    } catch (error) {
      const err = error as Error;
      this.errorMessage = err.message;
      return false;
    } finally {
      this.isLoading = false;
    }
  }
  
  /**
   * 移除电脑
   */
  async removeComputer(uuid: string): Promise<void> {
    await this.computerManager.removeComputer(uuid);
    this.computers = this.computers.filter(c => c.uuid !== uuid);
  }
  
  /**
   * 开始配对
   */
  async startPairing(computer: ObservableComputer): Promise<string> {
    this.isPairing = true;
    this.pairingComputer = computer;
    
    try {
      const pin = await this.computerManager.pairComputer(computer.uuid);
      this.pairingPin = pin;
      return pin;
    } catch (error) {
      const err = error as Error;
      this.errorMessage = err.message;
      this.isPairing = false;
      this.pairingComputer = null;
      throw new Error(err.message);
    }
  }
  
  /**
   * 取消配对
   */
  cancelPairing(): void {
    this.isPairing = false;
    this.pairingPin = '';
    this.pairingComputer = null;
  }
  
  /**
   * 唤醒电脑
   */
  async wakeComputer(computer: ObservableComputer): Promise<void> {
    await this.computerManager.wakeComputer(computer.uuid);
  }
  
  /**
   * 选择电脑
   */
  selectComputer(computer: ObservableComputer): void {
    this.selectedComputer = computer;
  }
  
  /**
   * 清除选择
   */
  clearSelection(): void {
    this.selectedComputer = null;
  }
  
  // 缓存的统计值（避免 getter 不触发 UI 更新的问题）
  computerCount: number = 0;
  onlineCount: number = 0;
  
  /**
   * 是否为空
   */
  get isEmpty(): boolean {
    return this.computers.length === 0;
  }
}

/**
 * 电脑列表数据源
 * 实现 IDataSource 接口以支持 LazyForEach
 */
export class ComputerDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private dataArray: ObservableComputer[] = [];
  
  // 获取数据总数
  totalCount(): number {
    return this.dataArray.length;
  }
  
  // 获取指定索引的数据
  getData(index: number): ObservableComputer {
    return this.dataArray[index];
  }
  
  // 注册数据变化监听器
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }
  
  // 注销数据变化监听器
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }
  
  // 重新加载所有数据
  reloadData(data: ObservableComputer[]): void {
    this.dataArray = data;
    this.notifyDataReload();
  }
  
  // 更新单个数据项（不重建组件，只更新内容）
  updateItem(index: number): void {
    this.notifyDataChange(index);
  }
  
  // 通知数据重新加载
  private notifyDataReload(): void {
    this.listeners.forEach(listener => {
      listener.onDataReloaded();
    });
  }
  
  // 通知单个数据变化
  private notifyDataChange(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataChange(index);
    });
  }
  
  // 通知数据添加
  notifyDataAdd(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataAdd(index);
    });
  }
  
  // 通知数据删除
  notifyDataDelete(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataDelete(index);
    });
  }
  
  // 添加数据
  pushData(data: ObservableComputer): void {
    this.dataArray.push(data);
    this.notifyDataAdd(this.dataArray.length - 1);
  }
  
  // 删除数据
  deleteData(index: number): void {
    this.dataArray.splice(index, 1);
    this.notifyDataDelete(index);
  }
}
