/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * 性能覆盖层组件
 * 
 * 从 StreamPage 抽离的独立组件，显示串流性能数据
 * 支持拖动、吸附、布局切换等功能
 */
import { promptAction } from '@kit.ArkUI';
import { batteryInfo } from '@kit.BasicServicesKit';
import { OptionPickerDialog, OptionPickerDialogConfig, OptionItem, SliderConfig } from './OptionPickerDialog';
import {
  PerformanceItem, PerformanceData, PerfIcons, PerfLabels,
  getMoonPhaseIcon, formatDataRate, getDecoderString,
  getPacketLossColor, getLatencyColor, getBatteryColor,
  calculateSnapPosition, findNearestSnapPosition,
  getPerformanceItemInfo, getSnapBorderRadius, SnapPosition
} from './PerformanceOverlayManager';
import { StreamViewModel } from '../viewmodel/StreamViewModel';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { SettingsKeys } from '../service/SettingsService';

/**
 * 点击检测阈值常量
 */
const CLICK_THRESHOLD = 10;
const DOUBLE_CLICK_TIMEOUT = 300;

@Component
export struct PerformanceOverlay {
  // 外部传入的 ViewModel
  @ObjectLink viewModel: StreamViewModel;
  
  // 屏幕尺寸
  @Prop screenWidth: number = 0;
  @Prop screenHeight: number = 0;
  
  // 性能数据 - 独立 @State 变量确保UI刷新
  @State perfFps: number = 0;
  @State perfRenderedFps: number = 0;
  @State perfBitrate: number = 0;
  @State perfLatency: number = 0;
  @State perfNetworkLatency: number = 0;
  @State perfHostLatency: number = 0;
  @State perfPacketLoss: number = 0;
  @State perfBatteryLevel: number = 100;
  @State perfIsCharging: boolean = false;
  
  // 覆盖层状态
  @State overlayX: number = 8;
  @State overlayY: number = 8;
  @State overlayOpacity: number = 1.0;
  @State overlayScale: number = 1.0;
  @State isVertical: boolean = true;
  @State overlayBgOpacity: number = 0.53;
  @State currentSnapPosition: SnapPosition = SnapPosition.TOP_RIGHT;
  @State overlayDragging: boolean = false;  // 拖动中显示全圆角
  
  // 启用的性能项（@State 数组驱动 UI 响应式渲染，Set 变更不被追踪）
  @State enabledItemsList: string[] = [];
  
  // 拖动状态
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private clickStartTime: number = 0;
  private lastClickTime: number = 0;
  private moveDistance: number = 0;
  private overlayWidth: number = 200;
  private overlayHeight: number = 200;
  
  // 定时器
  private updateTimer: number = -1;
  
  // 弹窗控制器
  private settingsDialogController: CustomDialogController | null = null;
  
  aboutToAppear(): void {
    // 初始化位置和布局
    this.initPosition();
    
    // 初始化背景透明度
    this.overlayBgOpacity = this.viewModel.overlayState.config.bgOpacity;
    
    // 同步启用项目列表（@State 数组驱动 UI）
    this.enabledItemsList = Array.from(this.viewModel.overlayState.config.enabledItems);
    
    // 启动数据更新定时器
    this.startUpdateTimer();
  }
  
  aboutToDisappear(): void {
    this.stopUpdateTimer();
  }
  
  private initPosition(): void {
    this.currentSnapPosition = this.viewModel.overlayState.config.position;
    const snapPos = calculateSnapPosition(
      this.currentSnapPosition,
      this.screenWidth,
      this.screenHeight,
      this.overlayWidth,
      this.overlayHeight
    );
    this.overlayX = snapPos.x;
    this.overlayY = snapPos.y;
    this.isVertical = this.viewModel.overlayState.config.isVertical;
  }
  
  private startUpdateTimer(): void {
    let batteryUpdateCounter = 0;
    this.updateTimer = setInterval(() => {
      // 从 ViewModel 获取 session 更新性能数据
      const session = this.viewModel.getSession();
      if (session) {
        const stats = session.getStats();
        this.perfFps = stats.fps;
        this.perfRenderedFps = stats.renderedFps;
        this.perfBitrate = stats.bitrate;
        this.perfLatency = stats.latency;
        this.perfNetworkLatency = stats.networkLatency;
        this.perfHostLatency = stats.hostLatency;
        this.perfPacketLoss = stats.packetLoss;
      }
      
      // 每15秒更新电池
      batteryUpdateCounter++;
      if (batteryUpdateCounter >= 15) {
        batteryUpdateCounter = 0;
        try {
          this.perfBatteryLevel = batteryInfo.batterySOC;
          this.perfIsCharging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE ||
            batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL;
        } catch (e) {
          // 忽略电池信息获取失败
        }
      }
    }, 1000);
    
    // 初始化电池信息
    try {
      this.perfBatteryLevel = batteryInfo.batterySOC;
      this.perfIsCharging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE ||
        batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL;
    } catch (e) {
      // 忽略
    }
  }
  
  private stopUpdateTimer(): void {
    if (this.updateTimer !== -1) {
      clearInterval(this.updateTimer);
      this.updateTimer = -1;
    }
  }
  
  build() {
    Column() {
      if (this.isVertical) {
        this.VerticalContent()
      } else {
        this.HorizontalContent()
      }
    }
    .padding(this.isVertical ? 12 : { left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(`#${Math.round(this.overlayBgOpacity * 255).toString(16).padStart(2, '0')}161616`)
    .borderRadius(this.overlayDragging ? 12 : getSnapBorderRadius(this.currentSnapPosition, 12))
    .opacity(this.overlayOpacity)
    .scale({ x: this.overlayScale, y: this.overlayScale })
    .position({ x: this.overlayX, y: this.overlayY })
    .hitTestBehavior(HitTestMode.Block)
    .focusable(false)  // 禁止获取控制器焦点，确保游戏能接收输入
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const oldWidth = this.overlayWidth;
      const oldHeight = this.overlayHeight;
      this.overlayWidth = newValue.width as number;
      this.overlayHeight = newValue.height as number;
      
      // 首次渲染时重新计算位置（因为 aboutToAppear 时尺寸还不准确）
      if (oldWidth === 200 && oldHeight === 200 && 
          (this.overlayWidth !== 200 || this.overlayHeight !== 200)) {
        this.initPosition();
      }
    })
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.All, distance: 5 })
        .onActionStart((event: GestureEvent) => {
          if (this.viewModel.overlayState.config.isLocked) return;
          this.handleDragStart(event);
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.viewModel.overlayState.config.isLocked) return;
          this.handleDragUpdate(event);
        })
        .onActionEnd((event: GestureEvent) => {
          if (this.viewModel.overlayState.config.isLocked) return;
          this.handleDragEnd(event);
        })
    )
    .onClick(() => {
      if (this.viewModel.overlayState.config.isLocked) return;
      this.handleClick();
    })
  }
  
  // ==================== 垂直布局 ====================
  
  @Builder
  VerticalContent() {
    // 分辨率行
    if (this.enabledItemsList.includes(PerformanceItem.RESOLUTION)) {
      Row() {
        Text(getMoonPhaseIcon())
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
        Text(` ${this.viewModel.displayInfo.streamWidth}x${this.viewModel.displayInfo.streamHeight}@${this.viewModel.streamConfig?.fps || 60}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .margin({ bottom: 4 })
    }

    // 解码器行
    if (this.enabledItemsList.includes(PerformanceItem.DECODER)) {
      Row() {
        Text(getDecoderString(this.viewModel.actualCodec || 'HEVC', this.viewModel.actualHdr))
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
      .margin({ bottom: 4 })
    }

    // FPS行
    if (this.enabledItemsList.includes(PerformanceItem.RENDER_FPS)) {
      Row() {
        Text(`Rx ${this.perfFps} / Rd ${this.perfRenderedFps}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0DDAF4')
        Text(' FPS')
          .fontSize(11)
          .fontColor('#CCFFFFFF')
      }
      .margin({ bottom: 4 })
    }

    // 丢包行
    if (this.enabledItemsList.includes(PerformanceItem.PACKET_LOSS)) {
      Row() {
        Text(PerfIcons.PACKET_LOSS)
          .fontSize(13)
        Text(` ${this.perfPacketLoss.toFixed(2)}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(getPacketLossColor(this.perfPacketLoss))
        Text('%')
          .fontSize(11)
          .fontColor('#CCFFFFFF')
      }
      .margin({ bottom: 4 })
    }

    // 带宽行
    if (this.enabledItemsList.includes(PerformanceItem.BITRATE)) {
      Row() {
        Text(PerfIcons.BITRATE)
          .fontSize(13)
        Text(` ${formatDataRate(this.perfBitrate)}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#BCEDD3')
      }
      .margin({ bottom: 4 })
    }

    // 网络延迟行
    if (this.enabledItemsList.includes(PerformanceItem.NETWORK_LATENCY)) {
      Row() {
        Text(PerfIcons.NETWORK)
          .fontSize(13)
        Text(this.perfNetworkLatency > 0 ? ` ${this.perfNetworkLatency}` : ' N/A')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.perfNetworkLatency > 50 ? '#FFA726' : '#4CAF50')
        Text(' ms')
          .fontSize(11)
          .fontColor('#CCFFFFFF')
      }
      .margin({ bottom: 4 })
    }

    // 解码延迟行
    if (this.enabledItemsList.includes(PerformanceItem.DECODE_LATENCY)) {
      Row() {
        Text(this.perfLatency < 15 ? PerfIcons.DECODE_NORMAL : PerfIcons.DECODE_HOT)
          .fontSize(13)
        Text(` ${this.perfLatency.toFixed(2)}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(getLatencyColor(this.perfLatency))
        Text(' ms')
          .fontSize(11)
          .fontColor('#CCFFFFFF')
      }
      .margin({ bottom: 4 })
    }

    // 主机延迟行
    if (this.enabledItemsList.includes(PerformanceItem.HOST_LATENCY)) {
      Row() {
        Text(PerfIcons.HOST)
          .fontSize(13)
        Text(this.perfHostLatency > 0 ? ` ${this.perfHostLatency.toFixed(1)}` : ' N/A')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#009688')
        Text(' ms')
          .fontSize(11)
          .fontColor('#CCFFFFFF')
      }
      .margin({ bottom: 4 })
    }

    // 电池行
    if (this.enabledItemsList.includes(PerformanceItem.BATTERY)) {
      Row() {
        Text(this.perfIsCharging ? PerfIcons.CHARGING : PerfIcons.BATTERY)
          .fontSize(13)
        Text(` ${this.perfBatteryLevel}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(getBatteryColor(this.perfBatteryLevel))
        Text('%')
          .fontSize(11)
          .fontColor('#CCFFFFFF')
      }
    }
  }
  
  // ==================== 水平布局 ====================
  
  @Builder
  HorizontalContent() {
    Row() {
      // 分辨率
      if (this.enabledItemsList.includes(PerformanceItem.RESOLUTION)) {
        Text(getMoonPhaseIcon())
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
        Text(` ${this.viewModel.displayInfo.streamWidth}x${this.viewModel.displayInfo.streamHeight}@${this.viewModel.streamConfig?.fps || 60}`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
        if (this.hasNextItem(PerformanceItem.RESOLUTION)) this.Separator()
      }
      
      // 解码器
      if (this.enabledItemsList.includes(PerformanceItem.DECODER)) {
        Text(getDecoderString(this.viewModel.actualCodec || 'HEVC', this.viewModel.actualHdr))
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        if (this.hasNextItem(PerformanceItem.DECODER)) this.Separator()
      }
      
      // FPS
      if (this.enabledItemsList.includes(PerformanceItem.RENDER_FPS)) {
        Text(`${this.perfFps}/${this.perfRenderedFps}`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0DDAF4')
        Text(' FPS')
          .fontSize(10)
          .fontColor('#CCFFFFFF')
        if (this.hasNextItem(PerformanceItem.RENDER_FPS)) this.Separator()
      }
      
      // 丢包
      if (this.enabledItemsList.includes(PerformanceItem.PACKET_LOSS)) {
        Text(PerfIcons.PACKET_LOSS)
          .fontSize(12)
        Text(` ${this.perfPacketLoss.toFixed(1)}%`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(getPacketLossColor(this.perfPacketLoss))
        if (this.hasNextItem(PerformanceItem.PACKET_LOSS)) this.Separator()
      }
      
      // 带宽
      if (this.enabledItemsList.includes(PerformanceItem.BITRATE)) {
        Text(PerfIcons.BITRATE)
          .fontSize(12)
        Text(` ${formatDataRate(this.perfBitrate)}`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#BCEDD3')
        if (this.hasNextItem(PerformanceItem.BITRATE)) this.Separator()
      }
      
      // 网络延迟
      if (this.enabledItemsList.includes(PerformanceItem.NETWORK_LATENCY)) {
        Text(PerfIcons.NETWORK)
          .fontSize(12)
        Text(this.perfNetworkLatency > 0 ? ` ${this.perfNetworkLatency} ms` : ' N/A')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.perfNetworkLatency > 50 ? '#FFA726' : '#4CAF50')
        if (this.hasNextItem(PerformanceItem.NETWORK_LATENCY)) this.Separator()
      }
      
      // 解码延迟
      if (this.enabledItemsList.includes(PerformanceItem.DECODE_LATENCY)) {
        Text(this.perfLatency < 15 ? PerfIcons.DECODE_NORMAL : PerfIcons.DECODE_HOT)
          .fontSize(12)
        Text(` ${this.perfLatency.toFixed(1)} ms`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(getLatencyColor(this.perfLatency))
        if (this.hasNextItem(PerformanceItem.DECODE_LATENCY)) this.Separator()
      }
      
      // 主机延迟
      if (this.enabledItemsList.includes(PerformanceItem.HOST_LATENCY)) {
        Text(PerfIcons.HOST)
          .fontSize(12)
        Text(this.perfHostLatency > 0 ? ` ${this.perfHostLatency.toFixed(1)} ms` : ' N/A')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#009688')
        if (this.hasNextItem(PerformanceItem.HOST_LATENCY)) this.Separator()
      }
      
      // 电池
      if (this.enabledItemsList.includes(PerformanceItem.BATTERY)) {
        Text(this.perfIsCharging ? PerfIcons.CHARGING : PerfIcons.BATTERY)
          .fontSize(12)
        Text(` ${this.perfBatteryLevel}%`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(getBatteryColor(this.perfBatteryLevel))
      }
    }
  }
  
  @Builder
  Separator() {
    Text('  |  ')
      .fontSize(11)
      .fontColor('#66FFFFFF')
  }
  
  // ==================== 辅助方法 ====================
  
  private hasNextItem(currentItem: PerformanceItem): boolean {
    const orderedItems = [
      PerformanceItem.RESOLUTION,
      PerformanceItem.DECODER,
      PerformanceItem.RENDER_FPS,
      PerformanceItem.PACKET_LOSS,
      PerformanceItem.BITRATE,
      PerformanceItem.NETWORK_LATENCY,
      PerformanceItem.DECODE_LATENCY,
      PerformanceItem.HOST_LATENCY,
      PerformanceItem.BATTERY
    ];
    
    const currentIndex = orderedItems.indexOf(currentItem);
    for (let i = currentIndex + 1; i < orderedItems.length; i++) {
      if (this.enabledItemsList.includes(orderedItems[i])) {
        return true;
      }
    }
    return false;
  }
  
  // ==================== 拖动处理 ====================
  
  private handleDragStart(event: GestureEvent): void {
    this.overlayDragging = true;
    this.dragStartX = this.overlayX;
    this.dragStartY = this.overlayY;
    this.clickStartTime = Date.now();
    this.moveDistance = 0;
    
    // 视觉反馈
    this.overlayOpacity = 0.7;
    this.overlayScale = 1.05;
  }
  
  private handleDragUpdate(event: GestureEvent): void {
    if (!this.overlayDragging) return;
    
    const offsetX = event.offsetX;
    const offsetY = event.offsetY;
    
    this.moveDistance += Math.abs(offsetX) + Math.abs(offsetY);
    
    let newX = this.dragStartX + offsetX;
    let newY = this.dragStartY + offsetY;
    
    // 边界限制
    newX = Math.max(0, Math.min(newX, this.screenWidth - this.overlayWidth));
    newY = Math.max(0, Math.min(newY, this.screenHeight - this.overlayHeight));
    
    this.overlayX = newX;
    this.overlayY = newY;
  }
  
  private handleDragEnd(event: GestureEvent): void {
    // 恢复视觉效果
    this.overlayOpacity = 1.0;
    this.overlayScale = 1.0;
    
    const duration = Date.now() - this.clickStartTime;
    if (this.moveDistance < CLICK_THRESHOLD && duration < 500) {
      // 非拖动（点击），恢复贴边圆角
      this.overlayDragging = false;
      const timeSinceLastClick = Date.now() - this.lastClickTime;
      if (timeSinceLastClick < DOUBLE_CLICK_TIMEOUT && this.lastClickTime > 0) {
        this.toggleLayout();
        this.lastClickTime = 0;
      } else {
        this.lastClickTime = Date.now();
        setTimeout(() => {
          if (Date.now() - this.lastClickTime >= DOUBLE_CLICK_TIMEOUT) {
            this.showInfo();
          }
        }, DOUBLE_CLICK_TIMEOUT);
      }
    } else {
      // 拖动结束，snapToPosition 内动画中会恢复 overlayDragging
      this.snapToPosition();
    }
  }
  
  private snapToPosition(): void {
    const nearestPos = findNearestSnapPosition(
      this.overlayX,
      this.overlayY,
      this.screenWidth,
      this.screenHeight,
      this.overlayWidth,
      this.overlayHeight
    );
    
    const snapPos = calculateSnapPosition(
      nearestPos,
      this.screenWidth,
      this.screenHeight,
      this.overlayWidth,
      this.overlayHeight
    );
    
    this.getUIContext()?.animateTo({
      duration: 200,
      curve: Curve.EaseOut
    }, () => {
      this.overlayX = snapPos.x;
      this.overlayY = snapPos.y;
      this.currentSnapPosition = nearestPos;
      this.overlayDragging = false;  // 恢复贴边圆角，跟随动画过渡
    });
    
    this.viewModel.overlayState.config.position = nearestPos;
  }
  
  // ==================== 点击处理 ====================
  
  private handleClick(): void {
    const now = Date.now();
    const timeSinceLastClick = now - this.lastClickTime;
    
    if (timeSinceLastClick < DOUBLE_CLICK_TIMEOUT && this.lastClickTime > 0) {
      // 双击 - 切换布局
      this.toggleLayout();
      this.lastClickTime = 0;
    } else {
      // 第一次点击
      const clickTime = now;
      this.lastClickTime = clickTime;
      setTimeout(() => {
        if (this.lastClickTime === clickTime) {
          this.showInfo();
          this.lastClickTime = 0;
        }
      }, DOUBLE_CLICK_TIMEOUT);
    }
  }
  
  private toggleLayout(): void {
    this.isVertical = !this.isVertical;
    this.viewModel.overlayState.config.isVertical = this.isVertical;
    
    try {
      promptAction.showToast({
        message: this.isVertical ? '已切换为垂直布局' : '已切换为水平布局',
        duration: 1500
      });
    } catch (e) {
      // 忽略
    }
  }
  
  private showInfo(): void {
    const perfData = this.getPerformanceData();
    this.showSettingsDialog(perfData);
  }
  
  private getPerformanceData(): PerformanceData {
    const data = new PerformanceData();
    data.streamWidth = this.viewModel.displayInfo.streamWidth;
    data.streamHeight = this.viewModel.displayInfo.streamHeight;
    data.targetFps = this.viewModel.streamConfig?.fps || 60;
    data.codec = this.viewModel.actualCodec || 'HEVC';
    data.isHdr = this.viewModel.actualHdr;
    data.receivedFps = this.perfFps;
    data.renderedFps = this.perfRenderedFps;
    data.packetLoss = this.perfPacketLoss;
    data.bitrate = this.perfBitrate;
    data.networkLatency = this.perfNetworkLatency;
    data.decodeLatency = this.perfLatency;
    data.hostLatency = this.perfHostLatency;
    data.batteryLevel = this.perfBatteryLevel;
    data.isCharging = this.perfIsCharging;
    return data;
  }

  /**
   * 所有性能项目列表
   */
  private static readonly ALL_ITEMS: PerformanceItem[] = [
    PerformanceItem.RESOLUTION,
    PerformanceItem.DECODER,
    PerformanceItem.RENDER_FPS,
    PerformanceItem.PACKET_LOSS,
    PerformanceItem.BITRATE,
    PerformanceItem.NETWORK_LATENCY,
    PerformanceItem.DECODE_LATENCY,
    PerformanceItem.HOST_LATENCY,
    PerformanceItem.BATTERY
  ];

  /**
   * 构建设置弹窗的选项列表（可重复调用以刷新）
   */
  private buildSettingsOptions(): OptionItem[] {
    const enabledItems = this.viewModel.overlayState.config.enabledItems;
    const options: OptionItem[] = [];

    for (let i = 0; i < PerformanceOverlay.ALL_ITEMS.length; i++) {
      const item = PerformanceOverlay.ALL_ITEMS[i];
      const info = getPerformanceItemInfo(item);
      const isEnabled = enabledItems.has(item);
      const opt: OptionItem = {
        title: info.title,
        subtitle: info.description,
        value: `item_${i}`,
        checked: isEnabled
      };
      options.push(opt);
    }

    return options;
  }

  /**
   * 显示设置弹窗 — 保持打开模式
   * 切换项目后弹窗不关闭, 实时刷新选项列表和覆盖层
   */
  private showSettingsDialog(perfData: PerformanceData): void {
    const allItems = PerformanceOverlay.ALL_ITEMS;
    const currentPercent = Math.round(this.overlayBgOpacity * 100);

    const sliderCfg: SliderConfig = {
      title: '🎨 背景透明度',
      value: currentPercent,
      min: 0,
      max: 100,
      step: 5,
      onChange: (value: number) => {
        this.updateBgOpacity(value / 100);
      }
    };

    const config: OptionPickerDialogConfig = {
      title: '性能覆盖层',
      subtitle: '单击设置显示/隐藏项目，拖动调整位置，双击切换布局',
      options: this.buildSettingsOptions(),
      selectedValue: '',
      sliderConfig: sliderCfg,
      closeOnSelect: false,
      refreshOptions: (): OptionItem[] => {
        return this.buildSettingsOptions();
      },
      onSelect: (option: OptionItem) => {
        const val = option.value as string;
        if (val.startsWith('item_')) {
          const itemIndex = parseInt(val.replace('item_', ''));
          if (itemIndex >= 0 && itemIndex < allItems.length) {
            this.toggleItem(allItems[itemIndex]);
          }
        }
      }
    };

    this.settingsDialogController = new CustomDialogController({
      builder: OptionPickerDialog({ config: config }),
      alignment: DialogAlignment.Bottom,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.settingsDialogController.open();
  }

  /**
   * 切换某个性能项目的显示/隐藏
   */
  private toggleItem(item: PerformanceItem): void {
    const config = this.viewModel.overlayState.config;
    if (config.enabledItems.has(item)) {
      config.enabledItems.delete(item);
    } else {
      config.enabledItems.add(item);
    }
    // 同步 @State 数组，触发 UI 重新渲染
    this.enabledItemsList = Array.from(config.enabledItems);
    // 持久化
    PreferencesUtil.put(SettingsKeys.PERF_OVERLAY_ITEMS, this.enabledItemsList.join(','));
  }

  /**
   * 更新背景透明度
   */
  private updateBgOpacity(value: number): void {
    this.overlayBgOpacity = value;
    this.viewModel.overlayState.config.bgOpacity = value;
    PreferencesUtil.put(SettingsKeys.PERF_OVERLAY_BG_OPACITY, value);
  }
}
