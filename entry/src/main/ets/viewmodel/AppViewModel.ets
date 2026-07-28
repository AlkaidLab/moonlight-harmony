/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { AppEntry, NvHttp, SuperCmd } from '../service/streaming/NvHttp';

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

  // 图标加载代际标记：每次 setApps / cancelIconLoading 自增，
  // 旧的串行加载循环在 await 恢复后发现代际已变即自行退出（避免多个循环并发跑）
  private iconLoadGeneration: number = 0;

  /**
   * 设置应用列表（带图标 URL）
   *
   * 增量合并：按 id 复用已有的 ObservableApp 实例，只更新变化的字段。
   * 不能全量重建——那会把 localIconPath/iconLoaded 清空，导致每次刷新
   * 整个列表先闪回占位符再逐个恢复图标（视觉上的"跳动"）。
   *
   * @param entries 应用列表
   * @param nvHttp NvHttp 实例（用于生成图标 URL 和加载图标）
   */
  setApps(entries: AppEntry[], nvHttp?: NvHttp): void {
    // 查找正在运行的应用
    const runningApps = entries.filter(e => e.isRunning);
    console.info(`AppListViewModel: 加载 ${entries.length} 个应用, 正在运行: ${runningApps.map(a => `${a.name}(${a.id})`).join(', ') || '无'}`);

    const existing: Map<number, ObservableApp> = new Map();
    for (const app of this.apps) {
      existing.set(app.id, app);
    }

    this.apps = entries.map(entry => {
      const iconUrl = nvHttp ? nvHttp.getBoxArtUrl(entry.id) : '';
      const reused = existing.get(entry.id);
      if (reused) {
        // 复用实例：@ObjectLink 会把变化推给组件，无需重建 UI 节点
        reused.updateFrom(entry, iconUrl);
        return reused;
      }
      return new ObservableApp(entry, iconUrl);
    });
    this.updateFilteredApps();
    this.updateRunningApp();

    // 异步加载尚未拿到图标的应用
    if (nvHttp) {
      this.loadAllIcons(nvHttp, ++this.iconLoadGeneration);
    }
  }

  /**
   * 按最新的 runningGameId 同步现有列表的运行状态
   *
   * 用于拿不到新 applist、但已知服务端运行状态的场合（如静默刷新返回空列表时
   * 保留旧数据）：不同步的话 hasRunningApp 会一直停在旧值，退游戏后的收敛轮询
   * 就永远等不到收敛。
   */
  syncRunningState(runningGameId: number): void {
    for (const app of this.apps) {
      app.isRunning = runningGameId > 0 && app.id === runningGameId;
    }
    this.updateRunningApp();
  }

  /**
   * 取消正在进行的图标加载
   */
  cancelIconLoading(): void {
    this.iconLoadGeneration++;
    console.info(`AppListViewModel: 图标加载已取消`);
  }

  /**
   * 异步加载所有应用图标（串行加载，避免并发过多）
   * 已加载成功的图标会被跳过，刷新时不会重新拉取。
   */
  private async loadAllIcons(nvHttp: NvHttp, generation: number): Promise<void> {
    const pending = this.apps.filter(app => !app.iconLoaded);
    if (pending.length === 0) {
      return;
    }
    console.info(`AppListViewModel: 开始加载 ${pending.length} 个应用图标`);

    // 串行加载图标，避免并发过多导致卡顿
    for (const app of pending) {
      // 检查是否已被更新的一轮加载取代
      if (this.iconLoadGeneration !== generation) {
        console.info(`AppListViewModel: 图标加载被取消，停止加载`);
        return;
      }

      try {
        const localPath = await nvHttp.getAppAssetCached(app.id);
        if (localPath && this.iconLoadGeneration === generation) {
          app.setLocalIconPath(localPath);
          console.info(`AppListViewModel: 图标加载成功 ${app.name}`);
        }
      } catch (err) {
        console.warn(`AppListViewModel: 图标加载失败 ${app.name}`, err);
      }
    }

    if (this.iconLoadGeneration === generation) {
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
