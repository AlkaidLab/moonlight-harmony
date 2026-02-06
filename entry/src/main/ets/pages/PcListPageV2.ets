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
import { ComputerInfo, ComputerState, PairState } from '../model/ComputerInfo';
import { ComputerManager } from '../service/ComputerManager';
import { ComputerCard } from '../components/ComputerCard';
import { ComputerListViewModel, ObservableComputer, ComputerDataSource } from '../viewmodel/ComputerViewModel';
import { AppColors, AppSizes, AppSpacing, AppAnimation, AppShadows } from '../common/Theme';
import { PairingManager, PairState as PMPairState } from '../service/PairingManager';
import { NvHttp } from '../service/NvHttp';
import { common, bundleManager, Want } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { BackgroundImageUtil } from '../utils/BackgroundImageUtil';
import { BackgroundImage } from '../components/BackgroundImage';
import { sensor } from '@kit.SensorServiceKit';
import { OptionPickerDialog, OptionPickerDialogConfig, OptionItem } from '../components/OptionPickerDialog';
import { ConfirmDialog, ConfirmDialogConfig, InfoDialog, InfoDialogConfig } from '../components/ConfirmDialog';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';

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
  
  // LazyForEach 数据源
  private computerDataSource: ComputerDataSource = new ComputerDataSource();
  
  private computerManager: ComputerManager = ComputerManager.getInstance();
  private backgroundUtil: BackgroundImageUtil = BackgroundImageUtil.getInstance();
  
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
    
    this.initializeAsync();
    this.loadBackgroundImage();
    this.startShakeDetection();
  }
  
  private async loadBackgroundImage(): Promise<void> {
    try {
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
        this.TitleBar()
        
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
        this.PinDialog()
      }
      
      // 关于对话框
      if (this.showAboutDialog) {
        this.AboutDialog()
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
  TitleBar() {
    Row() {
      Column() {
        Row() {
          // 应用图标/Logo - 使用 V+ Logo
          Image($r('app.media.vplus'))
            .width(44)
            .height(44)
            .borderRadius(12)
            .objectFit(ImageFit.Cover)
            .margin({ right: AppSpacing.Medium })

          Column() {
            Text('Moonlight V+')
              .fontSize(AppSizes.FontLargeTitle)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.Primary)

            if (this.viewModel.computers.length > 0) {
              Row() {
                Circle()
                  .width(6)
                  .height(6)
                  .fill(AppColors.Online)
                  .margin({ right: 6 })
                Text(`${this.viewModel.onlineCount} 在线`)
                  .fontSize(AppSizes.FontCaption)
                  .fontColor(AppColors.Online)
                Text(` / ${this.viewModel.computerCount} 台设备`)
                  .fontSize(AppSizes.FontCaption)
                  .fontColor(AppColors.TextSecondary)
              }
              .margin({ top: 4 })
            }
          }
          .alignItems(HorizontalAlign.Start)
        }
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      // 关于按钮
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ic_info'))
          .width(AppSizes.IconMedium)
          .height(AppSizes.IconMedium)
          .fillColor(AppColors.Primary)
      }
      .width(44)
      .height(44)
      .backgroundColor(AppColors.Surface)
      .borderWidth(1)
      .borderColor(AppColors.CardBorder)
      .margin({ right: AppSpacing.Small })
      .onClick(() => {
        this.showAboutDialog = true;
      })

      // 设置按钮
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ic_settings'))
          .width(AppSizes.IconMedium)
          .height(AppSizes.IconMedium)
          .fillColor(AppColors.Primary)
      }
      .width(44)
      .height(44)
      .backgroundColor(AppColors.Surface)
      .borderWidth(1)
      .borderColor(AppColors.CardBorder)
      .onClick(() => {
        router.pushUrl({ url: 'pages/SettingsPageV2' });
      })
    }
    .width('100%')
    .padding({
      left: AppSpacing.Large,
      right: AppSpacing.Large,
      top: 56,
      bottom: AppSpacing.Large
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
                onTap: () => this.handleComputerTap(computer),
                onLongPress: () => this.showComputerMenu(computer),
                onQuickStream: () => this.handleQuickStream(computer)
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
                onTap: () => this.handleComputerTap(computer),
                onLongPress: () => this.showComputerMenu(computer),
                onQuickStream: () => this.handleQuickStream(computer)
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
  
  @Builder
  PinDialog() {
    Column() {
      // 背景遮罩
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.showPinDialog = false;
        })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .zIndex(100)
    
    // 对话框
    Column() {
      // 标题
      Text('配对 PIN 码')
        .fontSize(AppSizes.FontHeadline)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.TextPrimary)
        .margin({ bottom: AppSpacing.Medium })
      
      Text(`请在 ${this.pairingComputerName} 上输入以下 PIN 码：`)
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .textAlign(TextAlign.Center)
        .margin({ bottom: AppSpacing.Large })
      
      // PIN 码显示
      Row() {
        ForEach(this.currentPin.split(''), (digit: string) => {
          Text(digit)
            .fontSize(36)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.Primary)
            .width(56)
            .height(72)
            .textAlign(TextAlign.Center)
            .backgroundColor('#E8F2FF')
            .borderRadius(AppSizes.RadiusMedium)
        })
      }
      .justifyContent(FlexAlign.SpaceEvenly)
      .width('100%')
      .margin({ bottom: AppSpacing.XLarge })
      
      // 提示
      Text('正在等待配对完成...')
        .fontSize(AppSizes.FontCaption)
        .fontColor(AppColors.TextSecondary)
        
      // 关闭按钮
      Button('取消')
        .width('100%')
        .height(44)
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .backgroundColor(Color.Transparent)
        .margin({ top: AppSpacing.Large })
        .onClick(() => {
          this.showPinDialog = false;
        })
    }
    .width('85%')
    .padding(AppSpacing.XLarge)
    .backgroundColor(AppColors.Surface)
    .borderRadius(AppSizes.RadiusXLarge)
    .position({ x: '7.5%', y: '30%' })
    .zIndex(101)
  }
  
  @Builder
  AboutDialog() {
    Column() {
      // 背景遮罩
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.showAboutDialog = false;
        })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .zIndex(100)
    
    // 对话框
    Column() {
      // Logo
      Image($r('app.media.vplus'))
        .width(80)
        .height(80)
        .borderRadius(16)
        .objectFit(ImageFit.Cover)
        .margin({ bottom: AppSpacing.Medium })
      
      // 应用名称
      Text('Moonlight V+')
        .fontSize(AppSizes.FontLargeTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.Primary)
        .margin({ bottom: AppSpacing.Small })
      
      // 版本信息
      Text(this.getVersionInfo())
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .margin({ bottom: AppSpacing.Large })
      
      // 描述
      Text('开源游戏串流客户端，基于 Moonlight 开发')
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .textAlign(TextAlign.Center)
        .margin({ bottom: AppSpacing.Small })
        
      Text('支持 NVIDIA GeForce Experience 和 Sunshine')
        .fontSize(AppSizes.FontCaption)
        .fontColor(AppColors.TextTertiary)
        .textAlign(TextAlign.Center)
        .margin({ bottom: AppSpacing.XLarge })
      
      // 按钮组
      Row() {
        Button('GitHub')
          .height(40)
          .fontSize(AppSizes.FontBody)
          .fontColor(Color.White)
          .backgroundColor('#24292e')
          .borderRadius(AppSizes.RadiusMedium)
          .layoutWeight(1)
          .onClick(() => {
            this.openUrl('https://github.com/qiin2333/moonlight-vplus');
          })
        
        Button('加入QQ群')
          .height(40)
          .fontSize(AppSizes.FontBody)
          .fontColor(Color.White)
          .backgroundColor('#12B7F5')
          .borderRadius(AppSizes.RadiusMedium)
          .layoutWeight(1)
          .margin({ left: AppSpacing.Medium })
          .onClick(() => {
            this.joinQQGroup('MeQFXB4ZoznvRzz7q_38LTmW5HrcfzcL');
          })
      }
      .width('100%')
      .margin({ bottom: AppSpacing.Medium })
      
      // 关闭按钮
      Button('关闭')
        .width('100%')
        .height(44)
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showAboutDialog = false;
        })
    }
    .width('85%')
    .padding(AppSpacing.XLarge)
    .backgroundColor(AppColors.Surface)
    .borderRadius(AppSizes.RadiusXLarge)
    .alignItems(HorizontalAlign.Center)
    .position({ x: '7.5%', y: '20%' })
    .zIndex(101)
  }

  // ==================== 业务逻辑 ====================
  
  /**
   * 获取版本信息
   */
  private getVersionInfo(): string {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const versionName = bundleInfo.versionName;
      const versionCode = bundleInfo.versionCode;
      return `版本 ${versionName} (Build ${versionCode})`;
    } catch (err) {
      console.error('获取版本信息失败', err);
      return '版本未知';
    }
  }
  
  /**
   * 打开 URL
   */
  private openUrl(url: string): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url
      };
      context.startAbility(want);
    } catch (err) {
      console.error('打开 URL 失败', err);
      promptAction.showToast({ message: '无法打开链接' });
    }
  }
  
  /**
   * 加入 QQ 群
   */
  private joinQQGroup(key: string): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      // 尝试使用 QQ 的 URI scheme
      const qqUri = `mqqopensdkapi://bizAgent/qm/qr?url=http%3A%2F%2Fqm.qq.com%2Fcgi-bin%2Fqm%2Fqr%3Ffrom%3Dapp%26p%3Dandroid%26jump_from%3Dwebapi%26k%3D${key}`;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: qqUri
      };
      context.startAbility(want).catch((err: BusinessError) => {
        // 如果 QQ 未安装，打开网页版
        console.info('QQ 未安装，打开网页版', err);
        this.openUrl('https://qm.qq.com/cgi-bin/qm/qr?k=' + key);
      });
    } catch (err) {
      console.error('加入 QQ 群失败', err);
      promptAction.showToast({ message: '无法打开 QQ' });
    }
  }
  
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

  private handleComputerTap(computer: ObservableComputer): void {
    // 离线 -> 显示菜单
    if (!computer.isOnline) {
      this.showComputerMenu(computer);
      return;
    }
    
    // 已配对 -> 进入应用列表
    if (computer.isPaired) {
      router.pushUrl({
        url: 'pages/AppListPageV2',
        params: { computerId: computer.uuid }
      });
      return;
    }
    
    // 在线未配对 -> 配对
    this.pairWithComputer(computer);
  }

  /**
   * 快速串流处理
   * 点击快速串流按钮时：
   * 1. 如果有正在运行的游戏，恢复该游戏
   * 2. 否则获取应用列表，启动第一个应用
   */
  private async handleQuickStream(computer: ObservableComputer): Promise<void> {
    if (!computer.isOnline || !computer.isPaired) {
      promptAction.showToast({ message: '设备未就绪' });
      return;
    }

    try {
      // 显示加载提示
      promptAction.showToast({ message: '正在准备串流...', duration: 1000 });

      // 获取完整电脑信息（包含 serverCert）
      const computerInfo = this.computerManager.getComputer(computer.uuid);
      if (!computerInfo || computerInfo.pairState !== PairState.PAIRED) {
        promptAction.showToast({ message: '设备未配对' });
        return;
      }

      // 如果有正在运行的游戏，直接恢复
      if (computer.runningGameId > 0) {
        console.info(`PcListPageV2: 快速恢复游戏 ID=${computer.runningGameId}`);
        router.pushUrl({
          url: 'pages/StreamPage',
          params: {
            computerId: computer.uuid,
            appId: computer.runningGameId,
            appName: '正在运行',  // 占位，实际会从服务器获取
            resume: true
          }
        });
        return;
      }

      // 获取应用列表
      const context = getContext(this) as common.UIAbilityContext;
      const nvHttp = new NvHttp(computerInfo.address, computerInfo.serverCert, context, computerInfo.httpPort);
      const apps = await nvHttp.getAppList();

      if (apps.length === 0) {
        promptAction.showToast({ message: '没有可用的应用' });
        return;
      }

      // 启动第一个应用
      const firstApp = apps[0];
      console.info(`PcListPageV2: 快速启动应用 ${firstApp.name} (ID=${firstApp.id})`);
      router.pushUrl({
        url: 'pages/StreamPage',
        params: {
          computerId: computer.uuid,
          appId: firstApp.id,
          appName: firstApp.name,
          resume: false
        }
      });
    } catch (err) {
      console.error(`PcListPageV2: 快速串流失败`, err);
      promptAction.showToast({ message: `启动失败: ${(err as Error).message}` });
    }
  }

  private async pairWithComputer(computer: ObservableComputer): Promise<void> {
    // 检查是否在线
    if (!computer.isOnline) {
      promptAction.showToast({ message: '电脑离线，无法配对' });
      return;
    }

    // 生成PIN码
    const pin = PairingManager.generatePin();
    this.currentPin = pin;
    this.pairingComputerName = computer.name;
    this.showPinDialog = true;

    try {
      console.info(`PcListPageV2: 开始配对 ${computer.name}, PIN: ${pin}, httpPort: ${computer.httpPort}`);

      // 执行配对（使用保存的自定义端口）
      const context = getContext(this) as common.UIAbilityContext;
      const pairingManager = new PairingManager(computer.address, computer.uuid, context, computer.httpPort);
      const result = await pairingManager.pair(pin);

      console.info(`PcListPageV2: 配对结果 ${result.state}`);
      this.showPinDialog = false;

      if (result.state === PMPairState.PAIRED) {
        // 使用 updateComputer 方法更新原始电脑数据
        let serverCertBase64 = '';
        if (result.serverCert) {
          const buf = buffer.from(result.serverCert);
          serverCertBase64 = buf.toString('base64');
        }
        
        await this.computerManager.updateComputer(computer.uuid, {
          pairState: PairState.PAIRED,
          serverCert: serverCertBase64,
          pairName: result.pairName || ''
        });
        
        console.info(`PcListPageV2: 配对成功，serverCert 长度: ${serverCertBase64.length}`);
        
        // 刷新列表
        await this.syncViewModelFromManager();

        // 显示成功消息
        promptAction.showToast({ message: '配对成功！' });

        // 自动进入应用列表
        router.pushUrl({
          url: 'pages/AppListPageV2',
          params: { computerId: computer.uuid }
        });
      } else if (result.state === PMPairState.PIN_WRONG) {
        promptAction.showToast({ message: 'PIN 码错误，请重试' });
      } else if (result.state === PMPairState.ALREADY_IN_PROGRESS) {
        promptAction.showToast({ message: '另一个设备正在配对中' });
      } else {
        promptAction.showToast({ message: `配对失败: ${result.state}` });
      }
    } catch (error) {
      const err = error as Error;
      this.showPinDialog = false;
      console.error('PcListPageV2: 配对异常', err);
      promptAction.showToast({ message: `配对失败: ${err.message}` });
    }
  }

  private showComputerMenu(computer: ObservableComputer): void {
    const options: OptionItem[] = [];
    const actionMap = new Map<string, () => void>();
    let actionIndex = 0;
    
    if (!computer.isOnline) {
      const key = `action_${actionIndex++}`;
      actionMap.set(key, () => this.wakeComputer(computer));
      options.push({
        title: '发送唤醒包 (WOL)',
        subtitle: '尝试通过网络唤醒电脑',
        value: key
      });
    } else if (!computer.isPaired) {
      const key = `action_${actionIndex++}`;
      actionMap.set(key, () => this.pairWithComputer(computer));
      options.push({
        title: '配对',
        subtitle: '与电脑建立安全连接',
        value: key
      });
    } else {
      if (computer.isGaming) {
        const resumeKey = `action_${actionIndex++}`;
        actionMap.set(resumeKey, () => this.resumeGame(computer));
        options.push({
          title: '恢复游戏',
          subtitle: '继续之前的游戏会话',
          value: resumeKey
        });
        
        const quitKey = `action_${actionIndex++}`;
        actionMap.set(quitKey, () => this.quitGame(computer));
        options.push({
          title: '退出游戏',
          subtitle: '结束当前运行的游戏',
          value: quitKey
        });
      }
      
      const appListKey = `action_${actionIndex++}`;
      actionMap.set(appListKey, () => router.pushUrl({
        url: 'pages/AppListPageV2',
        params: { computerId: computer.uuid }
      }));
      options.push({
        title: '应用列表',
        subtitle: '查看可串流的应用',
        value: appListKey
      });
      
      const unpairKey = `action_${actionIndex++}`;
      actionMap.set(unpairKey, () => this.unpairComputer(computer));
      options.push({
        title: '取消配对',
        subtitle: '断开与电脑的配对',
        value: unpairKey
      });
      
      const sleepKey = `action_${actionIndex++}`;
      actionMap.set(sleepKey, () => this.sleepComputer(computer));
      options.push({
        title: '休眠电脑',
        subtitle: '让电脑进入休眠状态',
        value: sleepKey
      });
    }
    
    const networkKey = `action_${actionIndex++}`;
    actionMap.set(networkKey, () => this.testNetwork(computer));
    options.push({
      title: '网络测试',
      subtitle: '测试与电脑的网络连接',
      value: networkKey
    });
    
    const detailsKey = `action_${actionIndex++}`;
    actionMap.set(detailsKey, () => this.showComputerDetails(computer));
    options.push({
      title: '查看详情',
      subtitle: '显示电脑的详细信息',
      value: detailsKey
    });
    
    const deleteKey = `action_${actionIndex++}`;
    actionMap.set(deleteKey, () => this.deleteComputer(computer));
    options.push({
      title: '删除电脑',
      subtitle: '从列表中移除此电脑',
      value: deleteKey
    });

    // 设置配置
    this.optionPickerDialogConfig = {
      title: computer.name,
      subtitle: computer.statusText,
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

  private async wakeComputer(computer: ObservableComputer): Promise<void> {
    console.info(`PcListPageV2: wakeComputer 被调用 - ${computer.name}, MAC: ${computer.macAddress}`);
    
    if (!computer.macAddress || computer.macAddress === '00:00:00:00:00:00') {
      console.warn(`PcListPageV2: ${computer.name} 缺少有效的 MAC 地址`);
      promptAction.showToast({ message: '缺少有效的 MAC 地址。请先在电脑在线时配对，以获取 MAC 地址。' });
      return;
    }
    
    try {
      console.info(`PcListPageV2: 正在发送 WOL 唤醒包...`);
      await this.computerManager.wakeComputer(computer.uuid);
      console.info(`PcListPageV2: WOL 唤醒包已发送成功`);
      promptAction.showToast({ message: '唤醒包已发送' });
    } catch (err) {
      console.error(`PcListPageV2: WOL 发送失败:`, err);
      const errMessage = err instanceof Error ? err.message : String(err);
      promptAction.showToast({ message: `发送失败: ${errMessage}` });
    }
  }

  private async quitGame(computer: ObservableComputer): Promise<void> {
    if (!computer.isOnline) {
      const toastOpts: promptAction.ShowToastOptions = { message: '电脑离线，无法退出游戏' };
      promptAction.showToast(toastOpts);
      return;
    }

    if (!computer.isPaired) {
      const toastOpts: promptAction.ShowToastOptions = { message: '未配对，无法退出游戏' };
      promptAction.showToast(toastOpts);
      return;
    }

    if (!computer.runningGameId || computer.runningGameId <= 0) {
      const toastOpts: promptAction.ShowToastOptions = { message: '没有正在运行的游戏' };
      promptAction.showToast(toastOpts);
      return;
    }

    this.showConfirmDialog({
      title: '退出游戏',
      message: '确定要退出当前运行的游戏吗？',
      confirmButton: {
        text: '退出',
        color: AppColors.Error,
        onClick: async () => {
          try {
            const toastOptions: promptAction.ShowToastOptions = { message: '正在退出游戏...' };
            promptAction.showToast(toastOptions);

            const context = getContext(this) as common.UIAbilityContext;
            const nvHttp = new NvHttp(computer.address, computer.serverCert || null, context, computer.httpPort);
            const success = await nvHttp.quitApp();

            if (success) {
              const successToast: promptAction.ShowToastOptions = { message: '游戏已退出' };
              promptAction.showToast(successToast);
              await this.computerManager.pollComputer(computer.toComputerInfo());
              await this.syncViewModelFromManager();
            } else {
              const failToast: promptAction.ShowToastOptions = { message: '退出游戏失败' };
              promptAction.showToast(failToast);
            }
          } catch (error) {
            const err = error as Error;
            const errorToast: promptAction.ShowToastOptions = { message: `退出游戏失败: ${err.message}` };
            promptAction.showToast(errorToast);
          }
        }
      }
    });
  }

  private async sleepComputer(computer: ObservableComputer): Promise<void> {
    if (!computer.isOnline) {
      const toastOpts: promptAction.ShowToastOptions = { message: '电脑离线，无法休眠' };
      promptAction.showToast(toastOpts);
      return;
    }

    if (!computer.isPaired) {
      const toastOpts: promptAction.ShowToastOptions = { message: '未配对，无法发送休眠命令' };
      promptAction.showToast(toastOpts);
      return;
    }

    this.showConfirmDialog({
      title: '休眠电脑',
      message: `确定要让 "${computer.name}" 进入睡眠模式吗？`,
      confirmButton: {
        text: '休眠',
        onClick: async () => {
          try {
            const toastOpts: promptAction.ShowToastOptions = { message: '正在发送休眠命令...' };
            promptAction.showToast(toastOpts);

            const context = getContext(this) as common.UIAbilityContext;
            const nvHttp = new NvHttp(computer.address, computer.serverCert || null, context, computer.httpPort);
            const success = await nvHttp.pcSleep();

            if (success) {
              promptAction.showToast({ message: '睡眠命令已发送' });
              // 电脑将进入睡眠，先本地标记为离线，再刷新列表
              computer.state = ComputerState.OFFLINE;
              await this.syncViewModelFromManager();
            } else {
              promptAction.showToast({ message: '发送睡眠命令失败' });
            }
          } catch (error) {
            const err = error as Error;
            promptAction.showToast({ message: `发送睡眠命令失败: ${err.message}` });
          }
        }
      }
    });
  }

  private resumeGame(computer: ObservableComputer): void {
    router.pushUrl({
      url: 'pages/StreamPage',
      params: {
        computerId: computer.uuid,
        appId: computer.runningGameId,
        resume: true
      }
    });
  }

  private async unpairComputer(computer: ObservableComputer): Promise<void> {
    this.showConfirmDialog({
      title: '取消配对',
      message: `确定要取消与 ${computer.name} 的配对吗？`,
      confirmButton: {
        text: '确定',
        color: AppColors.Error,
        onClick: async () => {
          try {
            await this.computerManager.unpairComputer(computer.uuid);
            promptAction.showToast({ message: '已取消配对' });
            this.syncViewModelFromManager();
          } catch (err) {
            promptAction.showToast({ message: '操作失败' });
          }
        }
      }
    });
  }

  private async deleteComputer(computer: ObservableComputer): Promise<void> {
    this.showConfirmDialog({
      title: '删除电脑',
      message: `确定要删除 ${computer.name} 吗？`,
      confirmButton: {
        text: '删除',
        color: AppColors.Error,
        onClick: async () => {
          try {
            await this.computerManager.removeComputer(computer.uuid);
            promptAction.showToast({ message: '已删除' });
            this.syncViewModelFromManager();
          } catch (err) {
            promptAction.showToast({ message: '删除失败' });
          }
        }
      }
    });
  }

  private async testNetwork(computer: ObservableComputer): Promise<void> {
    promptAction.showToast({ message: '正在测试网络...' });
    
    try {
      // 简单地尝试 poll 电脑获取状态
      const computerInfo = computer.toComputerInfo();
      await this.computerManager.pollComputer(computerInfo);
      
      this.showInfoDialog({
        title: '网络测试结果',
        content: `电脑 ${computer.name} 响应正常`
      });
    } catch (error) {
      const err = error as Error;
      this.showInfoDialog({
        title: '网络测试结果',
        content: `电脑 ${computer.name} 无法连接\n${err.message}`
      });
    }
  }

  private showComputerDetails(computer: ObservableComputer): void {
    const stateText = computer.isOnline ? '在线' : '离线';
    const pairText = computer.isPaired ? '已配对' : '未配对';
    const gamingText = computer.isGaming ? `正在运行游戏 (ID: ${computer.runningGameId})` : '空闲';
    
    // 构建地址信息（显示所有类型）
    const addressLines: string[] = [];
    const info = computer.toComputerInfo();
    if (info.manualAddress) {
      addressLines.push(`手动地址: ${info.manualAddress}`);
    }
    if (info.localAddress) {
      addressLines.push(`本地地址: ${info.localAddress}`);
    }
    if (info.remoteAddress) {
      addressLines.push(`远程地址: ${info.remoteAddress}`);
    }
    if (info.address && info.address !== info.localAddress && info.address !== info.remoteAddress && info.address !== info.manualAddress) {
      addressLines.push(`当前地址: ${info.address}`);
    }
    if (addressLines.length === 0) {
      addressLines.push(`地址: 未知`);
    }
    
    const details = [
      `名称: ${computer.name}`,
      `状态: ${stateText}`,
      `配对: ${pairText}`,
      `游戏: ${gamingText}`,
      ``,
      `UUID: ${computer.uuid}`,
      ...addressLines,
      `MAC 地址: ${computer.macAddress || '未知'}`,
      `HTTPS 端口: ${NvHttp.DEFAULT_HTTPS_PORT}`,
      `HTTP 端口: ${info.httpPort || NvHttp.DEFAULT_HTTP_PORT}`,
    ].join('\n');
    
    this.showInfoDialog({
      title: computer.name,
      content: details
    });
  }
}
