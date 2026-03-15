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
import { ComputerInfo, PairState, selectBestAddress } from '../model/ComputerInfo';
import { ComputerManager } from '../service/ComputerManager';
import { ComputerCard } from '../components/ComputerCard';
import { ComputerListViewModel, ObservableComputer, ComputerDataSource } from '../viewmodel/ComputerViewModel';
import { AppColors, AppSizes, AppSpacing } from '../common/Theme';
import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { BackgroundImageUtil, BackgroundImageType } from '../utils/BackgroundImageUtil';
import { BackgroundImage } from '../components/BackgroundImage';
import { sensor } from '@kit.SensorServiceKit';
import { OptionPickerDialog, OptionPickerDialogConfig, OptionItem } from '../components/OptionPickerDialog';
import { ConfirmDialog, ConfirmDialogConfig, InfoDialog, InfoDialogConfig } from '../components/ConfirmDialog';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { ComputerMenuHelper, ComputerMenuCallbacks } from '../viewmodel/ComputerMenuHelper';
import { PcListActions, PcListUICallbacks } from '../viewmodel/PcListActions';
import { PairingManager, PairState as PMPairState } from '../service/PairingManager';
import { QrShareService } from '../service/QrShareService';
import { CustomKeyStore } from '../service/CustomKeyStore';
import { PcListTitleBar, TitleBarConfig } from '../components/PcListTitleBar';
import { PinDialogView, AboutDialogView } from '../components/PcListDialogs';

/**
 * 电脑列表页面 (现代化版本)
 * 
 * 功能:
 * - 显示已添加的电脑列表
 * - 支持下拉刷新
 * - 支持 mDNS 自动发现
 * - 支持 WOL 唤醒
 * - 支持配对/取消配对
 */
@Entry
@Component
struct PcListPageV2 {
  @State viewModel: ComputerListViewModel = new ComputerListViewModel();
  @State isRefreshing: boolean = false;
  @State isScanning: boolean = false;
  @State isInitializing: boolean = true;
  @State showPinDialog: boolean = false;
  @State currentPin: string = '';
  @State pairingComputerName: string = '';
  @State backgroundImageUrl: string = '';
  @State showAboutDialog: boolean = false;
  @State isLandscape: boolean = false;  // 横屏检测
  @State screenWidth: number = 0;       // 屏幕宽度
  @StorageProp('topSafeHeight') topSafeHeight: number = 56;  // 动态状态栏安全区高度
  
  // LazyForEach 数据源
  private computerDataSource: ComputerDataSource = new ComputerDataSource();
  
  private computerManager: ComputerManager = ComputerManager.getInstance();
  private backgroundUtil: BackgroundImageUtil = BackgroundImageUtil.getInstance();
  private actions: PcListActions | null = null;
  
  // 摇一摇相关
  private lastShakeTime: number = 0;
  private shakeThreshold: number = 15; // 加速度阈值
  private shakeCooldown: number = 2000; // 2秒冷却时间
  
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
  private infoDialogConfig: InfoDialogConfig = {
    title: '',
    content: ''
  };
  
  // CustomDialogController 实例
  private optionPickerDialogController: CustomDialogController | null = null;
  private confirmDialogController: CustomDialogController | null = null;
  private infoDialogController: CustomDialogController | null = null;

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
  
  /**
   * 显示信息弹窗
   */
  private showInfoDialog(config: InfoDialogConfig): void {
    this.infoDialogConfig = config;
    this.infoDialogController = new CustomDialogController({
      builder: InfoDialog({
        config: this.infoDialogConfig
      }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.infoDialogController.open();
  }

  aboutToAppear(): void {
    // 先设置 context 以便后续使用本地缓存
    const context = getContext(this) as common.UIAbilityContext;
    this.backgroundUtil.setContext(context);

    // 初始化业务逻辑处理类
    this.actions = new PcListActions({
      showConfirmDialog: (config: ConfirmDialogConfig) => this.showConfirmDialog(config),
      showInfoDialog: (config: InfoDialogConfig) => this.showInfoDialog(config),
      syncViewModel: () => { this.syncViewModelFromManager(); },
      showPinDialog: (pin: string, computerName: string) => {
        this.currentPin = pin;
        this.pairingComputerName = computerName;
        this.showPinDialog = true;
      },
      hidePinDialog: () => { this.showPinDialog = false; }
    } as PcListUICallbacks);
    
    this.initializeAsync();
    this.loadBackgroundImage();
    this.startShakeDetection();
  }
  
  private async loadBackgroundImage(): Promise<void> {
    try {
      // 先检查背景图类型，如果是 NONE 则不加载
      const bgType = await this.backgroundUtil.getBackgroundImageType();
      if (bgType === BackgroundImageType.NONE) {
        this.backgroundImageUrl = '';
        return;
      }

      // 首次使用检查免责声明
      const disclaimerAccepted = await this.backgroundUtil.isDisclaimerAccepted();
      if (!disclaimerAccepted) {
        // 显示免责声明弹窗
        this.showBackgroundDisclaimerDialog();
        return;
      }
      
      // 优先使用本地缓存的图片
      const localPath = await this.backgroundUtil.downloadToLocalCache();
      if (localPath) {
        this.backgroundImageUrl = 'file://' + localPath;
      } else {
        // 如果本地缓存失败，使用在线 URL
        this.backgroundImageUrl = await this.backgroundUtil.getBackgroundImageUrl();
      }
    } catch (err) {
      // 忽略错误
    }
  }
  
  /**
   * 页面返回时重新加载背景图设置
   * 用户可能在设置页面更改了背景图类型
   */
  private async reloadBackgroundImage(): Promise<void> {
    try {
      // 检查类型是否发生变化
      const typeChanged = await this.backgroundUtil.reload();
      const currentType = await this.backgroundUtil.getBackgroundImageType();
      if (currentType === BackgroundImageType.NONE) {
        this.backgroundImageUrl = '';
      } else if (typeChanged) {
        // 类型变化，重新加载（缓存已在 setBackgroundImageType 中清除）
        this.loadBackgroundImage();
      }
    } catch (err) {
      // 忽略错误
    }
  }

  /**
   * 显示背景图免责声明弹窗
   */
  private showBackgroundDisclaimerDialog(): void {
    const config: ConfirmDialogConfig = {
      title: '背景壁纸功能说明',
      message: '本应用的背景壁纸来自互联网公开资源（Pipw API），图片版权归原作者所有。\n\n' +
        '• 本应用仅提供技术链接，不存储、不拥有这些图片的版权\n' +
        '• 如有侵权，请联系原图片来源方\n' +
        '• 您可以在设置中随时关闭壁纸功能或切换为其他来源\n\n' +
        '继续使用即表示您知悉并同意上述条款。',
      cancelButton: {
        text: '关闭壁纸',
        onClick: async () => {
          // 用户选择关闭壁纸，设置为 NONE
          await this.backgroundUtil.setDisclaimerAccepted();
          await this.backgroundUtil.disableBackgroundImage();
          this.backgroundImageUrl = '';
        }
      },
      confirmButton: {
        text: '知悉并继续',
        onClick: async () => {
          // 用户同意，保存状态并加载壁纸
          await this.backgroundUtil.setDisclaimerAccepted();
          this.loadBackgroundImageAfterDisclaimer();
        }
      }
    };
    this.showConfirmDialog(config);
  }
  
  /**
   * 免责声明确认后加载背景图
   */
  private async loadBackgroundImageAfterDisclaimer(): Promise<void> {
    try {
      const localPath = await this.backgroundUtil.downloadToLocalCache();
      if (localPath) {
        this.backgroundImageUrl = 'file://' + localPath;
      } else {
        this.backgroundImageUrl = await this.backgroundUtil.getBackgroundImageUrl();
      }
    } catch (err) {
      // 忽略错误
    }
  }

  private async initializeAsync(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await this.computerManager.init(context);

      this.computerManager.setOnComputerListChangedListener(() => {
        this.syncViewModelFromManager();
      });

      this.syncViewModelFromManager();
      this.computerManager.startBackgroundScan();
      
      this.isInitializing = false;
      
      // 异步刷新状态
      this.computerManager.refreshAllComputers().then(() => {
        this.syncViewModelFromManager();
        // 启动轮询
        this.computerManager.startPolling();
      }).catch((err: Error) => {
        console.error('[MOONLIGHT] PcListPage: 刷新失败', err);
        // 启动轮询
        this.computerManager.startPolling();
      });
    } catch (err) {
      console.error('PcListPage: 初始化失败', err);
      this.isInitializing = false;
    }
  }
  
  private async syncViewModelFromManager(): Promise<void> {
    const computers = await this.computerManager.getComputers();
    
    // 创建 UUID 到电脑信息的映射
    const computerMap = new Map<string, ComputerInfo>();
    for (const c of computers) {
      computerMap.set(c.uuid, c);
    }
    
    // 获取现有的 ObservableComputer 列表
    const existingMap = new Map<string, ObservableComputer>();
    for (const oc of this.viewModel.computers) {
      existingMap.set(oc.uuid, oc);
    }
    
    // 构建新的列表，复用现有对象以避免重新渲染
    const newList: ObservableComputer[] = [];
    let hasChanges = false;
    
    for (const c of computers) {
      const existing = existingMap.get(c.uuid);
      if (existing) {
        // 更新现有对象的属性（@Observed 会处理响应式更新）
        existing.updateFrom(c);
        newList.push(existing);
        existingMap.delete(c.uuid);
      } else {
        // 新电脑，创建新对象
        newList.push(new ObservableComputer(c));
        hasChanges = true;
      }
    }
    
    // 如果有电脑被删除
    if (existingMap.size > 0) {
      hasChanges = true;
    }
    
    // 只有当电脑数量变化时才替换整个数组
    if (hasChanges || this.viewModel.computers.length !== newList.length) {
      // 排序：在线已配对 > 在线未配对 > 离线，同优先级按名称排序
      newList.sort((a, b) => {
        const getPriority = (c: ObservableComputer): number => {
          if (c.isOnline && c.isPaired) return 0;  // 在线已配对
          if (c.isOnline) return 1;                  // 在线未配对
          return 2;                                   // 离线
        };
        const pa = getPriority(a);
        const pb = getPriority(b);
        if (pa !== pb) {
          return pa - pb;
        }
        return a.name.localeCompare(b.name);
      });
      this.viewModel.computers = newList;
      // 同步更新 LazyForEach 数据源
      this.computerDataSource.reloadData(newList);
    }
    
    // 更新缓存的统计值，确保 UI 显示正确
    this.viewModel.computerCount = newList.length;
    this.viewModel.onlineCount = newList.filter(c => c.isOnline).length;
  }

  aboutToDisappear(): void {
    this.computerManager.stopBackgroundScan();
    this.computerManager.stopPolling();
    this.stopShakeDetection();
  }

  onPageShow(): void {
    // 页面再次显示时启动轮询
    this.computerManager.startPolling();
    if (!this.isInitializing) {
      // 先同步当前数据
      this.syncViewModelFromManager();
      // 立即刷新一次状态（异步），确保显示最新的游戏运行状态
      this.computerManager.refreshAllComputers().then(() => {
        this.syncViewModelFromManager();
      }).catch((err: Error) => {
        console.warn('[MOONLIGHT] PcListPage: 刷新失败', err);
      });
      // 重新加载背景图设置（用户可能在设置中更改了背景图类型）
      // 注意：首次加载时 aboutToAppear 已调用 loadBackgroundImage，不需要重复
      this.reloadBackgroundImage();
    }
    // 重新启动摇一摇检测
    this.startShakeDetection();
  }
  
  onPageHide(): void {
    // 页面隐藏时停止轮询（节省资源）
    this.computerManager.stopPolling();
    // 停止摇一摇检测
    this.stopShakeDetection();
  }
  
  // 启动摇一摇检测
  private startShakeDetection(): void {
    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, (data) => {
        const x = data.x;
        const y = data.y;
        const z = data.z;
        const acceleration = Math.sqrt(x * x + y * y + z * z);
        
        // 检测是否超过阈值（摇一摇动作）
        // 正常重力加速度约为9.8，需要减去
        const shakeForce = Math.abs(acceleration - 9.8);
        
        if (shakeForce > this.shakeThreshold) {
          const now = Date.now();
          // 冷却时间检查，防止连续触发
          if (now - this.lastShakeTime > this.shakeCooldown) {
            this.lastShakeTime = now;
            this.refreshWallpaper();
          }
        }
      }, { interval: 100000000 }); // 100ms 采样间隔
    } catch (err) {
      // 某些设备可能不支持加速度传感器
    }
  }
  
  // 停止摇一摇检测
  private stopShakeDetection(): void {
    try {
      sensor.off(sensor.SensorId.ACCELEROMETER);
    } catch (err) {
      // 忽略错误
    }
  }

  build() {
    Stack() {
      // 背景图层
      BackgroundImage({ imageUrl: this.backgroundImageUrl, imageOpacity: 0.7 })
      
      // 主内容
      Column() {
        // 标题栏
        PcListTitleBar({
          config: {
            onlineCount: this.viewModel.onlineCount,
            totalCount: this.viewModel.computerCount,
            onAboutClick: () => { this.showAboutDialog = true; },
            onScanImport: () => { this.scanAndImportKeys(); },
            onSettingsClick: () => { router.pushUrl({ url: 'pages/SettingsPageV2' }); }
          } as TitleBarConfig
        })
        
        // 电脑列表或空状态
        if (this.isInitializing) {
          this.LoadingState()
        } else if (this.viewModel.computers.length === 0) {
          this.EmptyState()
        } else {
          this.ComputerList()
        }
        
        // 底部操作栏 (有电脑时显示，空状态由 EmptyState 自带按钮)
        if (!this.isInitializing && this.viewModel.computers.length > 0) {
          this.BottomBar()
        }
      }
      .width('100%')
      .height('100%')
      
      // PIN 对话框
      if (this.showPinDialog) {
        PinDialogView({
          pin: this.currentPin,
          computerName: this.pairingComputerName,
          onClose: () => { this.showPinDialog = false; }
        })
      }
      
      // 关于对话框
      if (this.showAboutDialog) {
        AboutDialogView({
          onClose: () => { this.showAboutDialog = false; }
        })
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // 检测屏幕尺寸变化（旋转屏幕时）
      const width = newValue.width as number;
      const height = newValue.height as number;
      this.screenWidth = width;
      this.isLandscape = width > height;
    })
  }

  @Builder
  LoadingState() {
    Column() {
      LoadingProgress()
        .width(48)
        .height(48)
        .color(AppColors.Primary)
      Text('正在加载...')
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .margin({ top: AppSpacing.Large })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyState() {
    Column() {
      // 霓虹风格插图
      Column() {
        Text('🖥️')
          .fontSize(48)
      }
      .width(120)
      .height(120)
      .borderRadius(60)
      .backgroundColor(AppColors.Surface)
      .borderWidth(2)
      .borderColor(AppColors.Primary)
      .justifyContent(FlexAlign.Center)
      .margin({ bottom: AppSpacing.XLarge })

      Text('开始连接')
        .fontSize(AppSizes.FontTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.Primary)
        .margin({ bottom: AppSpacing.Small })

      Text('扫描网络发现运行 Foundation Sunshine 的电脑')
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .textAlign(TextAlign.Center)
        .padding({ left: AppSpacing.XXLarge, right: AppSpacing.XXLarge })

      Text('或手动输入 IP 地址添加')
        .fontSize(AppSizes.FontCaption)
        .fontColor(AppColors.TextTertiary)
        .margin({ top: AppSpacing.Small })

      // 快速操作按钮 - 霓虹风格
      Row() {
        Button({ type: ButtonType.Normal }) {
          Row() {
            Image($r('app.media.ic_scan'))
              .width(20)
              .height(20)
              .fillColor(AppColors.TextOnPrimary)
              .margin({ right: 8 })
            Text('扫描网络')
              .fontSize(AppSizes.FontBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColors.TextOnPrimary)
          }
        }
        .height(48)
        .padding({ left: AppSpacing.XLarge, right: AppSpacing.XLarge })
        .borderRadius(AppSizes.RadiusLarge)
        .backgroundColor(AppColors.Primary)
        .onClick(() => this.scanNetwork())

        Button({ type: ButtonType.Normal }) {
          Row() {
            Image($r('app.media.ic_add'))
              .width(20)
              .height(20)
              .fillColor(AppColors.Primary)
              .margin({ right: 8 })
            Text('手动添加')
              .fontSize(AppSizes.FontBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColors.Primary)
          }
        }
        .height(48)
        .padding({ left: AppSpacing.XLarge, right: AppSpacing.XLarge })
        .borderRadius(AppSizes.RadiusLarge)
        .backgroundColor(Color.Transparent)
        .borderWidth(1.5)
        .borderColor(AppColors.Primary)
        .margin({ left: AppSpacing.Medium })
        .onClick(() => router.pushUrl({ url: 'pages/AddPcPageV2' }))
      }
      .margin({ top: AppSpacing.XXLarge })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 计算网格列数
   * 横屏或宽屏时使用多列布局
   */
  private getGridColumns(): number {
    if (this.screenWidth >= 900) return 3;  // 大屏幕 3 列
    if (this.screenWidth >= 600 || this.isLandscape) return 2;  // 中等屏幕或横屏 2 列
    return 1;  // 竖屏单列
  }

  @Builder
  ComputerList() {
    Refresh({ refreshing: $$this.isRefreshing }) {
      if (this.getGridColumns() > 1) {
        // 横屏/宽屏：使用 Grid 布局
        Grid() {
          ForEach(this.viewModel.computers, (computer: ObservableComputer, index: number) => {
            GridItem() {
              ComputerCard({
                computer: computer,
                onTap: () => {
                  if (!computer.isOnline) {
                    this.showComputerMenu(computer);
                  } else {
                    this.actions!.handleComputerTap(computer);
                  }
                },
                onLongPress: () => this.showComputerMenu(computer),
                onQuickStream: () => this.actions!.handleQuickStream(computer)
              })
            }
          }, (computer: ObservableComputer) => computer.uuid)
        }
        .columnsTemplate(this.getGridColumns() === 3 ? '1fr 1fr 1fr' : '1fr 1fr')
        .columnsGap(AppSpacing.Medium)
        .rowsGap(AppSpacing.Medium)
        .width('100%')
        .padding({ left: AppSpacing.Large, right: AppSpacing.Large })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        // 竖屏：使用 List 布局
        List({ space: AppSpacing.Medium }) {
          LazyForEach(this.computerDataSource, (computer: ObservableComputer, index: number) => {
            ListItem() {
              ComputerCard({
                computer: computer,
                onTap: () => {
                  if (!computer.isOnline) {
                    this.showComputerMenu(computer);
                  } else {
                    this.actions!.handleComputerTap(computer);
                  }
                },
                onLongPress: () => this.showComputerMenu(computer),
                onQuickStream: () => this.actions!.handleQuickStream(computer)
              })
            }
          }, (computer: ObservableComputer) => computer.uuid)
        }
        .width('100%')
        .padding({ left: AppSpacing.Large, right: AppSpacing.Large })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(5)
      }
    }
    .layoutWeight(1)
    .onRefreshing(() => {
      this.refreshComputers();
    })
  }

  @Builder
  BottomBar() {
    Row() {
      // 扫描按钮 - 搜索网络电脑
      Button({ type: ButtonType.Circle }) {
        if (this.isScanning) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(AppColors.TextSecondary)
        } else {
          Image($r('app.media.ic_search_network'))
            .width(22)
            .height(22)
            .fillColor(AppColors.TextSecondary)
        }
      }
      .width(44)
      .height(44)
      .backgroundColor(0x1A000000)  // 与 SaveButton 保持一致的半透明背景
      .enabled(!this.isScanning)
      .onClick(() => this.scanNetwork())

      // 添加按钮 - 突出显示的中央大按钮
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ic_add'))
          .width(28)
          .height(28)
          .fillColor(Color.White)
      }
      .width(56)
      .height(56)
      .backgroundColor(AppColors.Primary)
      .shadow({
        radius: 12,
        color: AppColors.PrimaryGlow,
        offsetX: 0,
        offsetY: 4
      })
      .margin({ left: AppSpacing.XLarge, right: AppSpacing.XLarge })
      .onClick(() => router.pushUrl({ url: 'pages/AddPcPageV2' }))
      
      // 下载壁纸到相册 - 使用 SaveButton 安全控件
      // 注意：SaveButton 作为安全控件，背景色透明度有最低限制 (α >= 0x1A)
      SaveButton({ 
        icon: SaveIconStyle.FULL_FILLED, 
        buttonType: ButtonType.Circle 
      })
        .width(44)
        .height(44)
        .iconSize(22)
        .iconColor(AppColors.TextSecondary)
        .backgroundColor(0x1A000000)  // 最低透明度的黑色背景
        .onClick(this.handleSaveWallpaperClick)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .padding({
      left: AppSpacing.Large,
      right: AppSpacing.Large,
      top: AppSpacing.Small,
      bottom: AppSpacing.Medium
    })
  }
  
  // 刷新壁纸（获取新的随机图片）- 由摇一摇触发
  private async refreshWallpaper(): Promise<void> {
    try {
      promptAction.showToast({ message: '正在刷新壁纸...' });
      const localPath = await this.backgroundUtil.downloadToLocalCache(true); // forceRefresh = true
      if (localPath) {
        // 添加时间戳参数强制 Image 组件重新加载（绕过缓存）
        this.backgroundImageUrl = 'file://' + localPath + '?t=' + Date.now();
        promptAction.showToast({ message: '壁纸已刷新' });
      } else {
        promptAction.showToast({ message: '刷新失败' });
      }
    } catch (err) {
      promptAction.showToast({ message: '刷新壁纸失败' });
    }
  }
  
  /**
   * SaveButton 保存壁纸点击回调
   * 使用安全控件授权后保存图片到相册
   */
  handleSaveWallpaperClick: SaveButtonCallback = async (
    event: ClickEvent, 
    result: SaveButtonOnClickResult, 
    error?: BusinessError
  ) => {
    if (result === SaveButtonOnClickResult.SUCCESS) {
      const localPath = this.backgroundUtil.getLocalCachePath();
      if (!localPath) {
        promptAction.showToast({ message: '没有可下载的壁纸' });
        return;
      }
      
      try {
        const context = getContext(this) as common.UIAbilityContext;
        promptAction.showToast({ message: '正在保存壁纸...' });
        
        // 读取本地缓存文件
        const stat = fileIo.statSync(localPath);
        if (!stat || stat.size === 0) {
          promptAction.showToast({ message: '缓存图片不存在' });
          return;
        }
        
        const file = fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY);
        const imageData = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, imageData);
        fileIo.closeSync(file.fd);
        
        // 使用 SaveButton 授权后创建图片资源
        const helper = photoAccessHelper.getPhotoAccessHelper(context);
        const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
        
        // 写入图片数据
        const photoFile = await fileIo.open(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        await fileIo.write(photoFile.fd, imageData);
        await fileIo.close(photoFile.fd);
        
        promptAction.showToast({ message: '壁纸已保存到相册' });
      } catch (err) {
        console.error('下载壁纸失败', err);
        const e = err as BusinessError;
        promptAction.showToast({ message: `保存失败: ${e.message || '未知错误'}` });
      }
    } else if (result === SaveButtonOnClickResult.TEMPORARY_AUTHORIZATION_FAILED) {
      console.error('保存授权失败', error);
      promptAction.showToast({ message: '保存授权失败' });
    }
  };

  // ==================== 业务逻辑 ====================
  
  private async refreshComputers(): Promise<void> {
    this.isRefreshing = true;
    try {
      await this.computerManager.refreshAllComputers();
      this.syncViewModelFromManager();
    } catch (err) {
      console.error('刷新失败', err);
    } finally {
      this.isRefreshing = false;
    }
  }

  /** 扫码：自动识别配对 URL 或按键配置 */
  private async scanAndImportKeys(): Promise<void> {
    const result = await QrShareService.scanQrCode();
    if (!result) {
      promptAction.showToast({ message: '扫码取消或失败', duration: 1500 });
      return;
    }

    // 检测 moonlight://pair URL（Sunshine QR 配对）
    if (result.startsWith('moonlight://pair')) {
      await this.handleQrPairing(result);
      return;
    }

    const parsed = QrShareService.deserialize(result);
    if (!parsed) {
      promptAction.showToast({ message: '无效的配置数据', duration: 2000 });
      return;
    }
    const name = parsed[0];
    const keys = parsed[1];
    this.optionPickerDialogConfig = {
      title: `导入配置: ${name}`,
      subtitle: `包含 ${keys.length} 个按键`,
      options: [
        { title: '替换导入', value: 'replace' } as OptionItem,
        { title: '合并导入', value: 'merge' } as OptionItem,
      ],
      selectedValue: '',
      onSelect: async (option: OptionItem) => {
        if (option.value === 'replace') {
          await CustomKeyStore.saveKeys(keys);
          promptAction.showToast({ message: `已导入 "${name}" (${keys.length} 个按键)`, duration: 2000 });
        } else {
          const existing = await CustomKeyStore.getKeys();
          await CustomKeyStore.saveKeys(existing.concat(keys));
          promptAction.showToast({ message: `已合并 ${keys.length} 个按键`, duration: 2000 });
        }
      }
    };
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

  /** 处理 Sunshine QR 配对 URL */
  private async handleQrPairing(url: string): Promise<void> {
    // 解析 moonlight://pair?host=...&port=...&pin=...&name=...
    const paramStr = url.substring(url.indexOf('?') + 1);
    const params = new Map<string, string>();
    for (const part of paramStr.split('&')) {
      const eq = part.indexOf('=');
      if (eq > 0) {
        params.set(part.substring(0, eq), decodeURIComponent(part.substring(eq + 1)));
      }
    }

    const host = params.get('host') ?? '';
    const portStr = params.get('port') ?? '';
    const pin = params.get('pin') ?? '';
    const serverName = params.get('name') ?? host;

    if (!host || !pin) {
      promptAction.showToast({ message: '二维码缺少必要信息', duration: 2000 });
      return;
    }

    const address = portStr ? `${host}:${portStr}` : host;
    promptAction.showToast({ message: `正在连接 ${serverName}...`, duration: 2000 });

    try {
      // 1. 添加电脑
      const computer = await this.computerManager.addComputer(address);
      this.syncViewModelFromManager();

      if (computer.pairState === PairState.PAIRED) {
        promptAction.showToast({ message: `${serverName} 已配对`, duration: 2000 });
        return;
      }

      // 2. 使用 QR 码中的 PIN 自动配对（服务端已 preset，无需用户输入）
      promptAction.showToast({ message: `正在与 ${serverName} 配对...`, duration: 2000 });
      const context = getContext() as common.UIAbilityContext;
      const pairingManager = new PairingManager(
        selectBestAddress(computer), computer.uuid, context, computer.httpPort
      );
      const result = await pairingManager.pair(pin);

      if (result.state === PMPairState.PAIRED) {
        let serverCertBase64 = '';
        if (result.serverCert) {
          serverCertBase64 = buffer.from(result.serverCert).toString('base64');
        }
        await this.computerManager.updateComputer(computer.uuid, {
          pairState: PairState.PAIRED,
          serverCert: serverCertBase64,
          pairName: result.pairName || ''
        });
        this.syncViewModelFromManager();
        promptAction.showToast({ message: `已成功配对 ${serverName}！` });
        router.pushUrl({ url: 'pages/AppListPageV2', params: { computerId: computer.uuid } });
      } else if (result.state === PMPairState.PIN_WRONG) {
        promptAction.showToast({ message: '二维码已过期，请在 Sunshine 重新生成', duration: 3000 });
      } else if (result.state === PMPairState.ALREADY_IN_PROGRESS) {
        promptAction.showToast({ message: '另一个设备正在配对中', duration: 2000 });
      } else {
        promptAction.showToast({ message: `配对失败: ${result.state}`, duration: 2000 });
      }
    } catch (error) {
      promptAction.showToast({ message: `连接失败: ${(error as Error).message}`, duration: 3000 });
    }
  }

  private async scanNetwork(): Promise<void> {
    this.isScanning = true;
    try {
      await this.computerManager.scanNetwork();
      this.syncViewModelFromManager();
      promptAction.showToast({ message: '扫描完成' });
    } catch (err) {
      console.error('扫描失败', err);
      promptAction.showToast({ message: '扫描失败' });
    } finally {
      this.isScanning = false;
    }
  }

  private showComputerMenu(computer: ObservableComputer): void {
    // 使用 ComputerMenuHelper 生成菜单
    const callbacks: ComputerMenuCallbacks = {
      onWake: (c) => this.actions!.wakeComputer(c),
      onPair: (c) => this.actions!.pairWithComputer(c),
      onResumeGame: (c) => this.actions!.resumeGame(c),
      onQuitGame: (c) => this.actions!.quitGame(c),
      onAppList: (c) => router.pushUrl({
        url: 'pages/AppListPageV2',
        params: { computerId: c.uuid }
      }),
      onUnpair: (c) => this.actions!.unpairComputer(c),
      onSleep: (c) => this.actions!.sleepComputer(c),
      onTestNetwork: (c) => this.actions!.testNetwork(c),
      onShowDetails: (c) => this.actions!.showComputerDetails(c),
      onDelete: (c) => this.actions!.deleteComputer(c)
    };
    
    const menuResult = ComputerMenuHelper.generateMenu(computer, callbacks);

    // 设置配置
    this.optionPickerDialogConfig = {
      title: computer.name,
      subtitle: computer.statusText,
      options: menuResult.options,
      selectedValue: '',
      onSelect: (option: OptionItem) => {
        const action = menuResult.actionMap.get(option.value as string);
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
}
