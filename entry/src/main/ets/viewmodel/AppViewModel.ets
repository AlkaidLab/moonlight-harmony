/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { AppEntry, NvHttp, SuperCmd } from '../service/NvHttp';

/**
 * 可观察的应用数据类
 */
@Observed
export class ObservableApp {
  id: number = 0;
  name: string = '';
  isRunning: boolean = false;
  isHdrSupported: boolean = false;
  iconUrl: string = '';
  // 本地缓存图标路径
  localIconPath: string = '';
  // 图标加载状态
  iconLoaded: boolean = false;
  // 超级指令列表 (Sunshine 功能)
  cmdList: SuperCmd[] = [];
  
  constructor(entry?: AppEntry, iconUrl?: string) {
    if (entry) {
      this.updateFrom(entry, iconUrl);
    }
  }
  
  updateFrom(entry: AppEntry, iconUrl?: string): void {
    this.id = entry.id;
    this.name = entry.name;
    this.isRunning = entry.isRunning;
    this.isHdrSupported = entry.isHdrSupported;
    this.cmdList = entry.cmdList || [];
    if (iconUrl) {
      this.iconUrl = iconUrl;
    }
  }

  /**
   * 设置本地图标路径
   */
  setLocalIconPath(path: string): void {
    this.localIconPath = path;
    this.iconLoaded = true;
  }
}

/**
 * 应用列表 ViewModel
 */
@Observed
export class AppListViewModel {
  // 应用列表
  apps: ObservableApp[] = [];
  
  // 过滤后的应用列表
  filteredApps: ObservableApp[] = [];
  
  // 搜索关键词
  searchKeyword: string = '';
  
  // 加载状态
  isLoading: boolean = false;
  isRefreshing: boolean = false;
  
  // 错误信息
  errorMessage: string = '';
  
  // 正在运行的应用
  runningApp: ObservableApp | null = null;
  
  // 选中的应用（准备启动）
  selectedApp: ObservableApp | null = null;
  
  // 排序方式
  sortBy: 'name' | 'recent' = 'name';

  // 图标加载取消标志
  private iconLoadingCancelled: boolean = false;
  
  /**
   * 设置应用列表（带图标 URL）
   * @param entries 应用列表
   * @param nvHttp NvHttp 实例（用于生成图标 URL 和加载图标）
   */
  setApps(entries: AppEntry[], nvHttp?: NvHttp): void {
    // 取消之前的图标加载任务
    this.iconLoadingCancelled = true;

    // 查找正在运行的应用
    const runningApps = entries.filter(e => e.isRunning);
    console.info(`AppListViewModel: 加载 ${entries.length} 个应用, 正在运行: ${runningApps.map(a => `${a.name}(${a.id})`).join(', ') || '无'}`);

    this.apps = entries.map(entry => {
      const iconUrl = nvHttp ? nvHttp.getBoxArtUrl(entry.id) : '';
      return new ObservableApp(entry, iconUrl);
    });
    this.updateFilteredApps();
    this.updateRunningApp();

    // 异步加载所有图标
    if (nvHttp) {
      this.iconLoadingCancelled = false;
      this.loadAllIcons(nvHttp);
    }
  }

  /**
   * 取消正在进行的图标加载
   */
  cancelIconLoading(): void {
    this.iconLoadingCancelled = true;
    console.info(`AppListViewModel: 图标加载已取消`);
  }

  /**
   * 异步加载所有应用图标（串行加载，避免并发过多）
   */
  private async loadAllIcons(nvHttp: NvHttp): Promise<void> {
    console.info(`AppListViewModel: 开始加载 ${this.apps.length} 个应用图标`);

    // 串行加载图标，避免并发过多导致卡顿
    for (const app of this.apps) {
      // 检查是否已取消
      if (this.iconLoadingCancelled) {
        console.info(`AppListViewModel: 图标加载被取消，停止加载`);
        return;
      }

      try {
        const localPath = await nvHttp.getAppAssetCached(app.id);
        if (localPath && !this.iconLoadingCancelled) {
          app.setLocalIconPath(localPath);
          console.info(`AppListViewModel: 图标加载成功 ${app.name}`);
        }
      } catch (err) {
        console.warn(`AppListViewModel: 图标加载失败 ${app.name}`, err);
      }
    }

    if (!this.iconLoadingCancelled) {
      console.info(`AppListViewModel: 所有图标加载完成`);
    }
  }
  
  /**
   * 更新过滤后的列表
   * 注意：保持服务端返回的原始顺序，不进行排序
   */
  updateFilteredApps(): void {
    // 搜索过滤
    if (this.searchKeyword.trim()) {
      const keyword = this.searchKeyword.toLowerCase().trim();
      this.filteredApps = this.apps.filter(app => 
        app.name.toLowerCase().includes(keyword)
      );
    } else {
      // 创建新数组以触发 UI 更新
      this.filteredApps = [...this.apps];
    }
  }
  
  /**
   * 设置搜索关键词
   */
  setSearchKeyword(keyword: string): void {
    this.searchKeyword = keyword;
    this.updateFilteredApps();
  }
  
  /**
   * 更新正在运行的应用
   */
  private updateRunningApp(): void {
    this.runningApp = this.apps.find(app => app.isRunning) || null;
  }
  
  /**
   * 选择应用
   */
  selectApp(app: ObservableApp): void {
    this.selectedApp = app;
  }
  
  /**
   * 清除选择
   */
  clearSelection(): void {
    this.selectedApp = null;
  }
  
  /**
   * 获取应用数量
   */
  get appCount(): number {
    return this.apps.length;
  }
  
  /**
   * 获取过滤后的数量
   */
  get filteredCount(): number {
    return this.filteredApps.length;
  }
  
  /**
   * 是否有正在运行的应用
   */
  get hasRunningApp(): boolean {
    return this.runningApp !== null;
  }
  
  /**
   * 是否为空
   */
  get isEmpty(): boolean {
    return this.apps.length === 0;
  }
  
  /**
   * 搜索结果是否为空
   */
  get isSearchEmpty(): boolean {
    return this.searchKeyword.trim() !== '' && this.filteredApps.length === 0;
  }
}
