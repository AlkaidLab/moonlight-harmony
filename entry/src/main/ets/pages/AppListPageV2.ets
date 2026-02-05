/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { router, promptAction } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { ComputerManager } from '../service/ComputerManager';
import { NvHttp, AppEntry, DisplayInfo } from '../service/NvHttp';
import { AppCard } from '../components/AppCard';
import { AppListViewModel, ObservableApp } from '../viewmodel/AppViewModel';
import { AppColors, AppSizes, AppSpacing, AppAnimation, AppShadows } from '../common/Theme';
import { common } from '@kit.AbilityKit';
import { PairState } from '../model/ComputerInfo';
import { OptionPickerDialog, OptionPickerDialogConfig, OptionItem } from '../components/OptionPickerDialog';
import { ConfirmDialog, ConfirmDialogConfig } from '../components/ConfirmDialog';

interface AppListPageParams {
  computerId: string;
}

/**
 * 应用列表页面 (现代化版本)
 */
// 竖屏时，app数量小于等于此阈值时使用1行
const VERTICAL_SINGLE_ROW_THRESHOLD = 5;
// 默认行数
const DEFAULT_VERTICAL_ROW_COUNT = 2;
const DEFAULT_HORIZONTAL_ROW_COUNT = 1;

@Entry
@Component
struct AppListPageV2 {
  @State viewModel: AppListViewModel = new AppListViewModel();
  @State computerName: string = '';
  @State isLoading: boolean = true;
  @State isRefreshing: boolean = false;
  @State searchText: string = '';
  @State showSearch: boolean = false;
  @State gridColumns: number = 3;
  @State backgroundImageUrl: string = '';
  @State backgroundOpacity: number = 0; // 背景透明度（用于淡入动画）
  @State rowCount: number = DEFAULT_HORIZONTAL_ROW_COUNT;
  @State isLandscape: boolean = true;
  // 显示器选择相关
  @State availableDisplays: DisplayInfo[] = [];
  @State selectedDisplayIndex: number = -1; // -1 表示使用默认显示器
  @State useVirtualDisplay: boolean = false; // 是否使用虚拟显示器
  @State supportsDisplayApi: boolean = false; // 服务器是否支持 displays API
  
  private computerId: string = '';
  private computerManager: ComputerManager = ComputerManager.getInstance();
  private nvHttp: NvHttp | null = null;
  private searchDebounceTimer: number = -1; // 搜索防抖定时器
  private iconPollIntervalId: number = -1; // 图标轮询定时器ID
  
  // CustomDialogController 配置
  private optionPickerDialogConfig: OptionPickerDialogConfig = {
    title: '',
    options: [],
    onSelect: () => {}
  };
  private confirmDialogConfig: ConfirmDialogConfig = {
    title: '',
    message: '',
    confirmButton: { text: '', onClick: () => {} }
  };
  
  // CustomDialogController 实例
  private optionPickerDialogController: CustomDialogController | null = null;
  private confirmDialogController: CustomDialogController | null = null;

  /**
   * 显示确认弹窗
   */
  private showConfirmDialog(config: ConfirmDialogConfig): void {
    this.confirmDialogConfig = config;
    this.confirmDialogController = new CustomDialogController({
      builder: ConfirmDialog({
        config: this.confirmDialogConfig
      }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.confirmDialogController.open();
  }

  aboutToAppear(): void {
    this.updateLayoutConfig();
    
    const params = router.getParams() as AppListPageParams;
    if (params?.computerId) {
      this.computerId = params.computerId;
      this.loadApps();
    } else if (this.isLoading) {
      this.isLoading = false;
    }
  }

  aboutToDisappear(): void {
    this.viewModel.cancelIconLoading();
    // 清理图标轮询定时器
    if (this.iconPollIntervalId !== -1) {
      clearInterval(this.iconPollIntervalId);
      this.iconPollIntervalId = -1;
    }
    // 清理搜索防抖定时器
    if (this.searchDebounceTimer !== -1) {
      clearTimeout(this.searchDebounceTimer);
      this.searchDebounceTimer = -1;
    }
  }

  onBackPress(): boolean {
    this.viewModel.cancelIconLoading();
    return false;
  }

  /**
   * 页面重新显示时刷新应用列表状态
   */
  onPageShow(): void {
    this.updateLayoutConfig();
    
    if (!this.nvHttp && this.computerId) {
      this.loadApps();
      return;
    }
    
    if (this.isLoading && this.nvHttp) {
      this.isLoading = false;
    }
    
    this.refreshApps();
    
    // 从串流返回时延迟刷新，等待服务器状态更新
    if (this.viewModel.hasRunningApp) {
      setTimeout(() => this.refreshApps(), 1000);
    }
  }

  /**
   * 更新布局配置（根据屏幕方向和app数量）
   */
  private updateLayoutConfig(): void {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      this.isLandscape = displayInfo.width > displayInfo.height;
      this.calculateOptimalRowCount();
    } catch (err) {
      this.isLandscape = true;
      this.rowCount = DEFAULT_HORIZONTAL_ROW_COUNT;
    }
  }

  /**
   * 计算最优行数（参考Android项目的逻辑）
   */
  private calculateOptimalRowCount(): void {
    if (this.isLandscape) {
      // 横屏：固定1行
      this.rowCount = DEFAULT_HORIZONTAL_ROW_COUNT;
    } else {
      // 竖屏：根据app数量判断
      const appCount = this.viewModel.filteredApps.length;
      if (appCount === 0) {
        this.rowCount = DEFAULT_VERTICAL_ROW_COUNT;
      } else if (appCount <= VERTICAL_SINGLE_ROW_THRESHOLD) {
        this.rowCount = DEFAULT_HORIZONTAL_ROW_COUNT;
      } else {
        this.rowCount = DEFAULT_VERTICAL_ROW_COUNT;
      }
    }
  }

  private async loadApps(): Promise<void> {
    this.isLoading = true;
    
    try {
      const computer = this.computerManager.getComputer(this.computerId);
      if (!computer) {
        promptAction.showToast({ message: '找不到电脑' });
        router.back();
        return;
      }
      
      if (computer.pairState !== PairState.PAIRED) {
        promptAction.showToast({ message: '设备未配对，请重新配对' });
        router.back();
        return;
      }
      
      this.computerName = computer.name;
      
      const context = getContext(this) as common.UIAbilityContext;
      this.nvHttp = new NvHttp(computer.address, computer.serverCert, context, computer.httpPort);
      
      const apps = await this.nvHttp.getAppList();

      // 标记正在运行的应用
      const runningGameId = computer.runningGameId;
      if (runningGameId > 0) {
        for (const app of apps) {
          app.isRunning = (app.id === runningGameId);
        }
      }

      this.viewModel.setApps(apps, this.nvHttp);
      this.calculateOptimalRowCount();
      this.loadDisplays();
      this.waitForFirstAppIcon();
    } catch (err) {
      promptAction.showToast({ message: `加载失败: ${(err as Error).message}` });
    } finally {
      this.isLoading = false;
    }
  }
  
  /**
   * 等待第一个 app 图标加载完成后设置背景
   */
  private waitForFirstAppIcon(): void {
    // 先清理之前的定时器
    if (this.iconPollIntervalId !== -1) {
      clearInterval(this.iconPollIntervalId);
      this.iconPollIntervalId = -1;
    }
    
    if (this.viewModel.filteredApps.length === 0) return;
    
    const firstApp = this.viewModel.filteredApps[0];
    
    const setBackground = () => {
      if (firstApp.iconLoaded && firstApp.localIconPath) {
        this.backgroundImageUrl = `file://${firstApp.localIconPath}`;
        setTimeout(() => {
          animateTo({ duration: 500, curve: Curve.EaseOut }, () => {
            this.backgroundOpacity = 0.7;
          });
        }, 50);
        return true;
      }
      return false;
    };
    
    if (setBackground()) return;
    
    // 轮询等待（最多3秒）
    let attempts = 0;
    this.iconPollIntervalId = setInterval(() => {
      if (setBackground() || ++attempts >= 30) {
        if (this.iconPollIntervalId !== -1) {
          clearInterval(this.iconPollIntervalId);
          this.iconPollIntervalId = -1;
        }
      }
    }, 100);
  }

  /**
   * 更新背景图
   */
  private updateBackgroundForApp(app: ObservableApp): void {
    if (!app.localIconPath || !app.iconLoaded) return;
    
    const newUrl = `file://${app.localIconPath}`;
    if (this.backgroundImageUrl !== newUrl) {
      animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
        this.backgroundImageUrl = newUrl;
      });
    }
  }

  private async refreshApps(): Promise<void> {
    this.isRefreshing = true;
    
    try {
      const computer = this.computerManager.getComputer(this.computerId);
      if (computer && computer.pairState !== PairState.PAIRED) {
        promptAction.showToast({ message: '配对已失效，请重新配对' });
        router.back();
        return;
      }
      
      if (this.nvHttp) {
        // 获取最新的服务器状态
        try {
          const serverInfo = await this.nvHttp.getServerInfo();
          if (computer) {
            computer.runningGameId = serverInfo.currentGame;
          }
        } catch {
          // 忽略服务器状态获取失败
        }
        
        const apps = await this.nvHttp.getAppList();

        // 标记正在运行的应用
        const runningGameId = computer?.runningGameId || 0;
        for (const app of apps) {
          app.isRunning = runningGameId > 0 && app.id === runningGameId;
        }

        this.viewModel.setApps(apps, this.nvHttp);
        this.calculateOptimalRowCount();
      }
    } catch (err) {
      const errMsg = (err as Error).message || '';
      if (errMsg.includes('401') || errMsg.includes('not authorized') || errMsg.includes('Certificate verification')) {
        promptAction.showToast({ message: '配对已失效，请重新配对' });
        router.back();
        return;
      }
      promptAction.showToast({ message: '刷新失败' });
    } finally {
      this.isRefreshing = false;
    }
  }

  build() {
    Stack() {
      // 纯色基础背景
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(AppColors.Background)
      
      // 背景图层（使用 app 封面，带淡入动画）
      if (this.backgroundImageUrl.length > 0) {
        Image(this.backgroundImageUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.backgroundOpacity)
        
        // 渐变叠加层
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [
              [AppColors.Background, 0.0],
              ['rgba(0,0,0,0)', 0.4],
              [AppColors.Background, 1.0]
            ]
          })
          .opacity(this.backgroundOpacity > 0 ? 1 : 0)
      }
      
      // 主内容
      Column() {
        // 标题栏
        this.TitleBar()
        
        // 内容区域
        Stack() {
          if (this.isLoading) {
            this.LoadingState()
          } else if (this.viewModel.isEmpty) {
            // 当列表为空时，显示空状态
            // 即使在刷新中也显示，避免出现完全空白的页面
            this.EmptyState()
          } else {
            Column() {
              // 搜索栏 (放在内容区域顶部，紧贴 AppGrid)
              if (this.showSearch) {
                this.SearchBar()
              }
              
              this.AppGrid()
            }
            .width('100%')
            .height('100%')
          }
        }
        .layoutWeight(1)
        
        // 显示器选择栏（底部，服务器支持 displays API 时显示）
        if (this.supportsDisplayApi) {
          this.DisplaySelector()
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  @Builder
  TitleBar() {
    Row() {
      // 返回按钮 - 霓虹风格
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ic_back'))
          .width(AppSizes.IconMedium)
          .height(AppSizes.IconMedium)
          .fillColor(AppColors.Primary)
      }
      .width(40)
      .height(40)
      .backgroundColor(AppColors.Surface)
      .borderWidth(1)
      .borderColor(AppColors.CardBorder)
      .onClick(() => router.back())

      // 标题
      Column() {
        Text(this.computerName || '应用列表')
          .fontSize(AppSizes.FontTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.Primary)

        if (!this.isLoading) {
          Row() {
            Text('🎮')
              .fontSize(12)
              .margin({ right: 4 })
            Text(`${this.viewModel.filteredCount} 个应用`)
              .fontSize(AppSizes.FontCaption)
              .fontColor(AppColors.TextSecondary)
          }
          .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: AppSpacing.Medium })

      Blank()

      // 搜索按钮 - 霓虹风格
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(20)
          .fontColor([this.showSearch ? AppColors.TextOnPrimary : AppColors.Accent])
      }
      .width(40)
      .height(40)
      .backgroundColor(this.showSearch ? AppColors.Accent : AppColors.Surface)
      .borderWidth(1)
      .borderColor(this.showSearch ? AppColors.Accent : AppColors.CardBorder)
      .onClick(() => {
        animateTo({ duration: AppAnimation.Normal, curve: AppAnimation.EaseOut }, () => {
          this.showSearch = !this.showSearch;
          if (!this.showSearch) {
            this.searchText = '';
            this.viewModel.setSearchKeyword('');
          }
        });
      })
      
      // 刷新按钮 - 霓虹风格
      Button({ type: ButtonType.Circle }) {
        if (this.isRefreshing) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(AppColors.Primary)
        } else {
          Image($r('app.media.ic_refresh'))
            .width(AppSizes.IconMedium)
            .height(AppSizes.IconMedium)
            .fillColor(AppColors.Primary)
        }
      }
      .width(40)
      .height(40)
      .backgroundColor(AppColors.Surface)
      .borderWidth(1)
      .borderColor(AppColors.CardBorder)
      .margin({ left: AppSpacing.Small })
      .onClick(() => this.refreshApps())
    }
    .width('100%')
    .padding({
      left: AppSpacing.Large,
      right: AppSpacing.Large,
      top: 56,
      bottom: AppSpacing.Medium
    })
  }

  @Builder
  SearchBar() {
    Row() {
      Row() {
        // 搜索图标
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(16)
          .fontColor([AppColors.TextTertiary])
          .margin({ right: 8 })

        TextInput({ placeholder: '搜索游戏...', text: this.searchText })
          .layoutWeight(1)
          .height(32)
          .fontSize(14)
          .fontColor(AppColors.TextPrimary)
          .placeholderColor(AppColors.TextTertiary)
          .caretColor(AppColors.Primary)
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            this.searchText = value;
            // 防抖：300ms 内不重复触发搜索
            if (this.searchDebounceTimer !== -1) {
              clearTimeout(this.searchDebounceTimer);
            }
            this.searchDebounceTimer = setTimeout(() => {
              this.viewModel.setSearchKeyword(this.searchText);
              this.searchDebounceTimer = -1;
            }, 300);
          })

        // 清空按钮
        if (this.searchText.length > 0) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(10)
              .fontColor([AppColors.TextTertiary])
          }
          .width(24)
          .height(24)
          .backgroundColor(AppColors.Surface)
          .onClick(() => {
            // 清除防抖定时器
            if (this.searchDebounceTimer !== -1) {
              clearTimeout(this.searchDebounceTimer);
              this.searchDebounceTimer = -1;
            }
            this.searchText = '';
            this.viewModel.setSearchKeyword('');
          })
        }
      }
      .height(40)
      .padding({ left: 14, right: 10 })
      .backgroundColor(AppColors.CardBackground)
      .borderRadius(20)
      .borderWidth(1)
      .borderColor(this.searchText.length > 0 ? AppColors.Primary : AppColors.CardBorder)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 24, right: 24, bottom: 8 })
    .justifyContent(FlexAlign.Center)
    .transition(TransitionEffect.OPACITY.animation({ duration: AppAnimation.Normal }))
  }

  @Builder
  DisplaySelector() {
    Column() {
      // 提示说明
      Text('Foundation Sunshine 专属功能')
        .fontSize(10)
        .fontColor(AppColors.TextTertiary)
        .margin({ bottom: 4 })
      
      Row() {
        // 显示器图标和标签
        Row() {
          SymbolGlyph($r('sys.symbol.display'))
            .fontSize(18)
            .fontColor([AppColors.TextSecondary])
            .margin({ right: 6 })
          Text('串流屏幕')
            .fontSize(13)
            .fontColor(AppColors.TextSecondary)
        }
        .margin({ right: AppSpacing.Small })

        // 横向滚动的选项
        Scroll() {
          Row({ space: 8 }) {
            // 默认选项（不选择任何显示器）
            Text('默认')
              .fontSize(12)
              .fontWeight((!this.useVirtualDisplay && this.selectedDisplayIndex === -1) ? FontWeight.Medium : FontWeight.Normal)
              .fontColor((!this.useVirtualDisplay && this.selectedDisplayIndex === -1) ? AppColors.TextOnPrimary : AppColors.TextSecondary)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor((!this.useVirtualDisplay && this.selectedDisplayIndex === -1) ? AppColors.Primary : AppColors.Surface)
              .borderRadius(16)
              .borderWidth(1)
              .borderColor((!this.useVirtualDisplay && this.selectedDisplayIndex === -1) ? AppColors.Primary : AppColors.CardBorder)
              .onClick(() => {
                this.useVirtualDisplay = false;
                this.selectedDisplayIndex = -1;
              })

            // 物理显示器选项
            ForEach(this.availableDisplays, (disp: DisplayInfo, index: number) => {
              Text(disp.name)
                .fontSize(12)
                .fontWeight((!this.useVirtualDisplay && this.selectedDisplayIndex === index) ? FontWeight.Medium : FontWeight.Normal)
                .fontColor((!this.useVirtualDisplay && this.selectedDisplayIndex === index) ? AppColors.TextOnPrimary : AppColors.TextSecondary)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor((!this.useVirtualDisplay && this.selectedDisplayIndex === index) ? AppColors.Primary : AppColors.Surface)
                .borderRadius(16)
                .borderWidth(1)
                .borderColor((!this.useVirtualDisplay && this.selectedDisplayIndex === index) ? AppColors.Primary : AppColors.CardBorder)
                .onClick(() => {
                  this.useVirtualDisplay = false;
                  this.selectedDisplayIndex = index;
                })
            }, (disp: DisplayInfo) => `display_${disp.index}`)

            // 虚拟显示器选项
            Text('虚拟显示器')
              .fontSize(12)
              .fontWeight(this.useVirtualDisplay ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.useVirtualDisplay ? AppColors.TextOnPrimary : AppColors.TextSecondary)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.useVirtualDisplay ? AppColors.Primary : AppColors.Surface)
              .borderRadius(16)
              .borderWidth(1)
              .borderColor(this.useVirtualDisplay ? AppColors.Primary : AppColors.CardBorder)
              .onClick(() => {
                this.useVirtualDisplay = true;
                this.selectedDisplayIndex = -1;
              })
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: AppSpacing.Large, right: AppSpacing.Large })
    .margin({ top: AppSpacing.Small, bottom: AppSpacing.Small })
  }

  @Builder
  LoadingState() {
    Column() {
      // 加载动画容器
      Column() {
        LoadingProgress()
          .width(48)
          .height(48)
          .color(AppColors.Primary)
      }
      .width(80)
      .height(80)
      .justifyContent(FlexAlign.Center)
      .borderRadius(40)
      .backgroundColor(AppColors.CardBackground)
      .borderWidth(2)
      .borderColor(AppColors.Primary)
      .shadow({ radius: 20, color: AppColors.GlowGreen, offsetX: 0, offsetY: 0 })

      Text('正在加载应用列表...')
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.Primary)
        .margin({ top: AppSpacing.Large })

      Text('请稍候')
        .fontSize(AppSizes.FontCaption)
        .fontColor(AppColors.TextTertiary)
        .margin({ top: AppSpacing.Small })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyState() {
    Column() {
      Text(this.viewModel.isSearchEmpty ? '🔍' : '🎮')
        .fontSize(40)
        .margin({ bottom: AppSpacing.Medium })

      Text(this.viewModel.isSearchEmpty ? '没有找到匹配的应用' : '没有可用的应用')
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)

      if (!this.viewModel.isSearchEmpty) {
        Text('刷新')
          .fontSize(AppSizes.FontCaption)
          .fontColor(AppColors.Accent)
          .margin({ top: AppSpacing.Medium })
          .onClick(() => this.refreshApps())
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  AppGrid() {
    Refresh({ refreshing: $$this.isRefreshing }) {
      // 横向滚动的布局（参考Android项目的布局方式）
      Scroll() {
        // 使用Column布局，支持多行横向排列
        Column() {
          ForEach(this.generateRows(), (rowApps: ObservableApp[], rowIndex: number) => {
            Row({ space: AppSpacing.Medium }) {
              ForEach(rowApps, (app: ObservableApp) => {
                AppCard({
                  app: app,
                  onTap: () => this.launchApp(app),
                  onLongPress: () => this.openAppMenu(app),
                  onSelect: () => {
                    this.updateBackgroundForApp(app);
                  }
                })
              }, (app: ObservableApp) => `${app.id}_${app.isRunning}_${app.iconLoaded}`)
            }
            .margin({ bottom: rowIndex < this.rowCount - 1 ? AppSpacing.Medium : 0 })
          }, (rowApps: ObservableApp[], rowIndex: number) => {
            // 行的 key 需要包含该行所有应用的 ID 和运行状态
            const appIds = rowApps.map(a => `${a.id}:${a.isRunning ? 1 : 0}`).join(',');
            return `row_${rowIndex}_apps_${appIds}`;
          })
        }
        .padding({
          left: AppSpacing.Large,
          right: AppSpacing.Large,
          top: AppSpacing.Small,
          bottom: AppSpacing.XLarge
        })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height('100%')
      .align(Alignment.Center)
    }
    .onRefreshing(() => this.refreshApps())
  }

  /**
   * 将应用列表按行分组
   */
  private generateRows(): ObservableApp[][] {
    const apps = this.viewModel.filteredApps;
    const rows: ObservableApp[][] = [];
    
    if (apps.length === 0 || this.rowCount === 0) {
      return rows;
    }
    
    // 计算每行的应用数量
    const appsPerRow = Math.ceil(apps.length / this.rowCount);
    
    // 按行分组
    for (let i = 0; i < this.rowCount; i++) {
      const rowApps: ObservableApp[] = [];
      for (let j = 0; j < appsPerRow; j++) {
        const index = j * this.rowCount + i;
        if (index < apps.length) {
          rowApps.push(apps[index]);
        }
      }
      if (rowApps.length > 0) {
        rows.push(rowApps);
      }
    }
    
    return rows;
  }

  /**
   * 根据行数生成rowsTemplate（保留用于可能的后续使用）
   */
  private generateRowsTemplate(): string {
    const templates: string[] = [];
    for (let i = 0; i < this.rowCount; i++) {
      templates.push('1fr');
    }
    return templates.join(' ');
  }

  /**
   * 加载可用的显示器列表 (Sunshine 功能)
   */
  private async loadDisplays(): Promise<void> {
    if (!this.nvHttp) return;
    
    try {
      this.availableDisplays = await this.nvHttp.getDisplays();
      this.supportsDisplayApi = true;
    } catch {
      this.availableDisplays = [];
      this.supportsDisplayApi = false;
    }
  }

  /**
   * 获取当前选择的显示器 GUID
   */
  private getSelectedDisplayGuid(): string {
    if (this.useVirtualDisplay) {
      return ''; // 虚拟显示器不需要 GUID
    }
    if (this.selectedDisplayIndex >= 0 && this.selectedDisplayIndex < this.availableDisplays.length) {
      const display = this.availableDisplays[this.selectedDisplayIndex];
      return display.guid || display.name;
    }
    return ''; // 使用默认显示器
  }

  private async launchApp(app: ObservableApp): Promise<void> {
    // 如果有正在运行的应用
    if (this.viewModel.hasRunningApp && this.viewModel.runningApp?.id !== app.id) {
      this.showConfirmDialog({
        title: '确认',
        message: `${this.viewModel.runningApp?.name} 正在运行。\n启动 ${app.name} 将会退出当前应用。`,
        confirmButton: {
          text: '继续',
          onClick: () => {
            this.doLaunchApp(app);
          }
        }
      });
    } else {
      this.doLaunchApp(app);
    }
  }

  private doLaunchApp(app: ObservableApp): void {
    const displayGuid = this.getSelectedDisplayGuid();
    router.pushUrl({
      url: 'pages/StreamPage',
      params: {
        computerId: this.computerId,
        appId: app.id,
        appName: app.name,
        cmdList: app.cmdList.length > 0 ? JSON.stringify(app.cmdList) : undefined,
        resume: app.isRunning,
        displayGuid: displayGuid,
        useVdd: this.useVirtualDisplay
      }
    });
  }

  private openAppMenu(app: ObservableApp): void {
    // 长按时更新背景图
    this.updateBackgroundForApp(app);
    
    const options: OptionItem[] = [];
    const actionMap = new Map<string, () => void>();
    let actionIndex = 0;
    
    const hasOtherRunningApp = this.viewModel.hasRunningApp && this.viewModel.runningApp?.id !== app.id;
    
    if (app.isRunning) {
      // 当前应用正在运行
      const resumeKey = `action_${actionIndex++}`;
      actionMap.set(resumeKey, () => this.doLaunchApp(app));
      options.push({
        title: '恢复',
        subtitle: '继续当前游戏',
        value: resumeKey
      });
      
      const quitKey = `action_${actionIndex++}`;
      actionMap.set(quitKey, () => this.quitApp());
      options.push({
        title: '退出',
        subtitle: '关闭当前运行的应用',
        value: quitKey
      });
    } else if (hasOtherRunningApp) {
      // 其他应用正在运行，显示"退出并启动"选项
      const quitAndStartKey = `action_${actionIndex++}`;
      actionMap.set(quitAndStartKey, () => this.quitAndStartApp(app));
      options.push({
        title: '退出并启动',
        subtitle: `退出 ${this.viewModel.runningApp?.name} 并启动此应用`,
        value: quitAndStartKey
      });
    } else {
      // 没有应用在运行
      const launchKey = `action_${actionIndex++}`;
      actionMap.set(launchKey, () => this.launchApp(app));
      options.push({
        title: '启动',
        subtitle: '开始串流',
        value: launchKey
      });
    }
    
    // HDR 选项（如果支持）
    if (app.isHdrSupported && !app.isRunning) {
      const hdrKey = `action_${actionIndex++}`;
      actionMap.set(hdrKey, () => {
        // TODO: 以 HDR 模式启动
        this.doLaunchApp(app);
      });
      options.push({
        title: '启动 (HDR)',
        subtitle: '以 HDR 模式启动',
        value: hdrKey
      });
    }
    
    // 查看详情
    const detailsKey = `action_${actionIndex++}`;
    actionMap.set(detailsKey, () => this.showAppDetails(app));
    options.push({
      title: '查看详情',
      subtitle: '显示应用信息',
      value: detailsKey
    });

    // 状态副标题
    let subtitle = '';
    if (app.isRunning) {
      subtitle = '正在运行';
    } else if (app.isHdrSupported) {
      subtitle = '支持 HDR';
    }

    this.optionPickerDialogConfig = {
      title: app.name,
      subtitle: subtitle,
      options: options,
      selectedValue: '',
      onSelect: (option: OptionItem) => {
        const action = actionMap.get(option.value as string);
        if (action) {
          action();
        }
      }
    };
    
    // 创建并打开弹窗
    this.optionPickerDialogController = new CustomDialogController({
      builder: OptionPickerDialog({
        config: this.optionPickerDialogConfig
      }),
      alignment: DialogAlignment.Bottom,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.optionPickerDialogController.open();
  }

  /**
   * 退出当前应用并启动新应用
   */
  private async quitAndStartApp(app: ObservableApp): Promise<void> {
    if (!this.nvHttp) return;
    
    try {
      if (await this.nvHttp.quitApp()) {
        promptAction.showToast({ message: '正在启动新应用...' });
        setTimeout(() => this.doLaunchApp(app), 500);
      } else {
        promptAction.showToast({ message: '退出失败' });
      }
    } catch {
      promptAction.showToast({ message: '退出失败' });
    }
  }

  /**
   * 显示应用详情
   */
  private showAppDetails(app: ObservableApp): void {
    const lines: string[] = [
      `应用名称: ${app.name}`,
      `应用 ID: ${app.id}`,
      `HDR 支持: ${app.isHdrSupported ? '是' : '否'}`,
      `运行状态: ${app.isRunning ? '运行中' : '未运行'}`
    ];
    
    // 如果有超级指令，显示在详情中
    if (app.cmdList && app.cmdList.length > 0) {
      lines.push('');
      lines.push('服务端指令:');
      for (const cmd of app.cmdList) {
        lines.push(`  • ${cmd.name} (${cmd.id})`);
      }
    }
    
    const details = lines.join('\n');
    
    this.confirmDialogConfig = {
      title: '应用详情',
      message: details,
      confirmButton: {
        text: '确定',
        onClick: () => {}
      }
    };
    
    this.confirmDialogController = new CustomDialogController({
      builder: ConfirmDialog({
        config: this.confirmDialogConfig
      }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.confirmDialogController.open();
  }

  private async quitApp(): Promise<void> {
    if (!this.nvHttp) return;
    
    try {
      if (await this.nvHttp.quitApp()) {
        promptAction.showToast({ message: '应用已退出' });
        await this.refreshApps();
      } else {
        promptAction.showToast({ message: '退出失败' });
      }
    } catch {
      promptAction.showToast({ message: '退出失败' });
    }
  }
}
