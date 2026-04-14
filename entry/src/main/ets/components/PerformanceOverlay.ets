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
import { OptionPickerDialog, OptionPickerDialogConfig, OptionItem, SliderConfig } from './dialogs/OptionPickerDialog';
import {
  PerformanceItem, PerformanceData, PerfLabels, PerfSymbols,
  getMoonPhaseIcon, formatDataRate, getDecoderString,
  getPacketLossColor, getLatencyColor, getBatteryColor, getBatteryIcon,
  calculateSnapPosition, findNearestSnapPosition,
  getPerformanceItemInfo, getSnapBorderRadius, SnapPosition,
  isAprilFools
} from './PerformanceOverlayManager';
import { StreamViewModel } from '../viewmodel/StreamViewModel';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { SettingsKeys } from '../service/SettingsService';

/**
 * 点击检测阈值常量
 */
const CLICK_THRESHOLD = 10;
const DOUBLE_CLICK_TIMEOUT = 300;

/** AppStorage 键：与 StreamPage 解锁时同步，保证解锁后覆盖层图标/透传立即刷新 */
const PERF_OVERLAY_LOCKED_STORAGE_KEY = 'perf_overlay_locked';

@Component
export struct PerformanceOverlay {
  // 外部传入的 ViewModel
  @ObjectLink viewModel: StreamViewModel;
  
  // 屏幕尺寸
  @Prop screenWidth: number = 0;
  @Prop screenHeight: number = 0;
  
  // 锁定状态用 StorageLink，菜单解锁时 set 后覆盖层能立即重绘
  @StorageLink(PERF_OVERLAY_LOCKED_STORAGE_KEY) overlayLocked: boolean = false;
  
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
  @State perfUpscaleMode: number = 0;
  private aprilFoolsToastShown: boolean = false;
  
  // 覆盖层状态
  @State overlayX: number = 8;
  @State overlayY: number = 8;
  @State overlayOpacity: number = 1.0;
  @State overlayScale: number = 1.0;
  @State isVertical: boolean = true;
  @State overlayBgOpacity: number = 0.53;
  @State currentSnapPosition: SnapPosition = SnapPosition.TOP_RIGHT;
  @State overlayDragging: boolean = false;  // 拖动中显示全圆角
  
  // 首次引导
  @State showGuide: boolean = false;
  
  // 锁定闪烁边框
  @State lockFlashBorderOpacity: number = 0;
  
  // 时钟图标弹跳动画
  @State clockIconScale: number = 1.0;
  @State clockHourAngle: number = 0;
  @State clockMinuteAngle: number = 0;
  @State showMiniClock: boolean = false;  // 是否显示迷你时钟而不是月相
  
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
  private guideTimer: number = -1;
  
  // 弹窗控制器
  private settingsDialogController: CustomDialogController | null = null;
  
  aboutToAppear(): void {
    // 初始化位置和布局
    this.initPosition();
    
    // 与 viewModel 同步锁定状态到 AppStorage，供本组件与菜单解锁联动
    AppStorage.setOrCreate(PERF_OVERLAY_LOCKED_STORAGE_KEY, this.viewModel.overlayState.config.isLocked);
    
    // 初始化背景透明度
    this.overlayBgOpacity = this.viewModel.overlayState.config.bgOpacity;
    
    // 同步启用项目列表（@State 数组驱动 UI）
    this.enabledItemsList = Array.from(this.viewModel.overlayState.config.enabledItems);
    
    // 如果当前正好是整刻钟，立即显示时钟（避免等待第一个定时器 tick）
    this.updateClock();
    
    // 启动数据更新定时器
    this.startUpdateTimer();
    
    // 首次显示引导
    this.checkAndShowGuide();
  }
  
  aboutToDisappear(): void {
    this.stopUpdateTimer();
    if (this.guideTimer !== -1) {
      clearTimeout(this.guideTimer);
    }
    this.settingsDialogController?.close();
  }
  
  private async checkAndShowGuide(): Promise<void> {
    try {
      const shown = await PreferencesUtil.get<boolean>(SettingsKeys.PERF_OVERLAY_GUIDE_SHOWN, false);
      if (!shown) {
        // 延迟 500ms 显示，让覆盖层先渲染完
        setTimeout(() => {
          this.showGuide = true;
          // 5 秒后自动关闭
          this.guideTimer = setTimeout(() => {
            this.dismissGuide();
          }, 5000);
        }, 500);
        PreferencesUtil.put(SettingsKeys.PERF_OVERLAY_GUIDE_SHOWN, true);
      }
    } catch (_) {
      // 忽略
    }
  }
  
  private dismissGuide(): void {
    if (this.showGuide) {
      animateTo({ duration: 200, curve: Curve.EaseIn }, () => {
        this.showGuide = false;
      });
    }
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
      this.updateClock();
      this.updateSessionStats();
      batteryUpdateCounter++;
      if (batteryUpdateCounter >= 15) {
        batteryUpdateCounter = 0;
        this.updateBattery();
      }
    }, 1000);
    
    // 初始化电池信息
    this.updateBattery();
  }

  /** 整刻钟时钟显示/隐藏 */
  private updateClock(): void {
    const isClockMinute = new Date().getMinutes() % 15 === 0;
    if (isClockMinute) {
      if (!this.showMiniClock) {
        this.showMiniClock = true;
        this.triggerClockBounce();
      }
      this.updateClockAngles();
    } else if (this.showMiniClock) {
      this.showMiniClock = false;
    }
  }

  /** 从 session 拉取性能数据（try-catch 防止 native 异常中断定时器） */
  private updateSessionStats(): void {
    const session = this.viewModel.getSession();
    if (!session) {
      return;
    }
    try {
      const stats = session.getStats();
      this.perfFps = stats.fps;
      this.perfRenderedFps = stats.renderedFps;
      this.perfBitrate = stats.bitrate;
      this.perfLatency = stats.latency;
      this.perfNetworkLatency = stats.networkLatency;
      this.perfHostLatency = stats.hostLatency;
      this.perfPacketLoss = stats.packetLoss;

      // 🎃 愚人节彩蛋：负延迟串流™
      if (isAprilFools()) {
        if (stats.latency > 0) {
          this.perfLatency = -(stats.latency * (0.3 + Math.random() * 0.4));
        }
        if (stats.networkLatency > 0) {
          this.perfNetworkLatency = -Math.ceil(stats.networkLatency * (0.2 + Math.random() * 0.3));
        }
        if (stats.hostLatency > 0) {
          this.perfHostLatency = -(stats.hostLatency * (0.3 + Math.random() * 0.3));
        }
        if (!this.aprilFoolsToastShown) {
          this.aprilFoolsToastShown = true;
          promptAction.showToast({
            message: '🔮 负延迟串流™ 已激活\n画面将在你操作之前到达',
            duration: 5000
          });
        }
      }

      // 延迟查询超分引擎（解码器初始化后才有值）
      if (this.perfUpscaleMode === 0) {
        const mode = session.getActiveUpscaleMode();
        if (mode > 0) {
          this.perfUpscaleMode = mode;
        }
      }
    } catch (e) {
      // 防止 native 调用异常中断定时器回调
    }
  }

  private updateBattery(): void {
    try {
      this.perfBatteryLevel = batteryInfo.batterySOC;
      this.perfIsCharging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE ||
        batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL;
    } catch (e) {
      // 忽略电池信息获取失败
    }
  }
  
  private stopUpdateTimer(): void {
    if (this.updateTimer !== -1) {
      clearInterval(this.updateTimer);
      this.updateTimer = -1;
    }
  }
  
  /** 时钟图标出现时的弹跳动画 */
  private triggerClockBounce(): void {
    // 指针从上一刻钟的时间位置旋转到当前时间
    const now = new Date();
    const prevTime = new Date(now.getTime() - 15 * 60 * 1000);
    const prevH = prevTime.getHours() % 12;
    const prevM = prevTime.getMinutes();
    this.clockHourAngle = prevH * 30 + prevM * 0.5;
    this.clockMinuteAngle = prevM * 6;
    setTimeout(() => {
      this.updateClockAngles();
    }, 50);
    // 缩放脉冲
    let step = 0;
    const bounce = () => {
      if (step >= 6) {
        this.clockIconScale = 1.0;
        return;
      }
      this.clockIconScale = (step % 2 === 0) ? 4.0 : 1.0;
      step++;
      setTimeout(bounce, 200);
    };
    bounce();
  }

  /** 更新时钟指针角度 */
  private updateClockAngles(): void {
    const now = new Date();
    const h = now.getHours() % 12;
    const m = now.getMinutes();
    // 时针：每小时30°，每分钟0.5°
    this.clockHourAngle = h * 30 + m * 0.5;
    // 分针：每分钟6°
    this.clockMinuteAngle = m * 6;
  }

  /** 自绘极简时钟（时针+分针+刻度） */
  @Builder
  MiniClock(size: number) {
    Stack() {
      // 四个刻度（12/3/6/9 点钟位置）
      ForEach([0, 90, 180, 270], (angle: number) => {
        Line()
          .width(0.8)
          .height(size * 0.13)
          .backgroundColor('#80FFFFFF')
          .borderRadius(0.4)
          .position({ x: size / 2 - 0.4, y: 0.5 })
          .rotate({ angle: angle, centerX: '50%', centerY: size / 2 - 0.5 })
      })
      // 时针（短粗）
      Line()
        .width(1.5)
        .height(size * 0.28)
        .backgroundColor('#FFFFFF')
        .borderRadius(1)
        .rotate({ angle: this.clockHourAngle, centerX: '50%', centerY: '100%' })
        .animation({ duration: 800, curve: Curve.EaseOut })
        .position({ x: size / 2 - 0.75, y: size / 2 - size * 0.28 })
      // 分针（长细）
      Line()
        .width(1)
        .height(size * 0.4)
        .backgroundColor('#FFFFFF')
        .borderRadius(0.5)
        .rotate({ angle: this.clockMinuteAngle, centerX: '50%', centerY: '100%' })
        .animation({ duration: 800, curve: Curve.EaseOut })
        .position({ x: size / 2 - 0.5, y: size / 2 - size * 0.4 })
      // 中心点
      Circle()
        .width(2)
        .height(2)
        .fill('#FFFFFF')
        .position({ x: size / 2 - 1, y: size / 2 - 1 })
    }
    .width(size)
    .height(size)
    .scale({ x: this.clockIconScale, y: this.clockIconScale })
    .animation({ duration: 200, curve: Curve.EaseOut })
  }

  /** 锁定时播放金色边框闪烁动画（闪 3 次） */
  private playLockFlash(): void {
    let count = 0;
    const flash = () => {
      if (count >= 3) {
        this.lockFlashBorderOpacity = 0;
        return;
      }
      animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
        this.lockFlashBorderOpacity = 0.8;
      });
      setTimeout(() => {
        animateTo({ duration: 150, curve: Curve.EaseIn }, () => {
          this.lockFlashBorderOpacity = 0;
        });
        count++;
        setTimeout(flash, 180);
      }, 180);
    };
    flash();
  }
  
  build() {
    Stack() {
      // 主覆盖层
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
      .border({
        width: this.lockFlashBorderOpacity > 0 ? 2 : 0,
        color: `#${Math.round(this.lockFlashBorderOpacity * 255).toString(16).padStart(2, '0')}FFD700`
      })
      .opacity(this.overlayOpacity)
      .scale({ x: this.overlayScale, y: this.overlayScale })
      .position({ x: this.overlayX, y: this.overlayY })
      // 锁定状态下透传触摸到下层串流视图，未锁定时拦截（用 overlayLocked 保证菜单解锁后立即刷新）
      .hitTestBehavior(this.overlayLocked ? HitTestMode.Transparent : HitTestMode.Block)
      .focusable(false)  // 禁止获取控制器焦点，确保游戏能接收输入
      .onAreaChange((oldValue: Area, newValue: Area) => {
      const oldWidth = this.overlayWidth;
      const oldHeight = this.overlayHeight;
      this.overlayWidth = newValue.width as number;
      this.overlayHeight = newValue.height as number;
      
      if (oldWidth === 200 && oldHeight === 200 && 
          (this.overlayWidth !== 200 || this.overlayHeight !== 200)) {
        // 首次渲染时重新计算位置（因为 aboutToAppear 时尺寸还不准确）
        this.initPosition();
      } else if (oldWidth !== this.overlayWidth || oldHeight !== this.overlayHeight) {
        // 尺寸变化（数值位数改变等），重新对齐到当前吸附位置
        const snapPos = calculateSnapPosition(
          this.currentSnapPosition,
          this.screenWidth,
          this.screenHeight,
          this.overlayWidth,
          this.overlayHeight
        );
        this.overlayX = snapPos.x;
        this.overlayY = snapPos.y;
      }
    })
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.All, distance: 5 })
        .onActionStart((event: GestureEvent) => {
          if (this.overlayLocked) return;
          this.handleDragStart(event);
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.overlayLocked) return;
          this.handleDragUpdate(event);
        })
        .onActionEnd((event: GestureEvent) => {
          if (this.overlayLocked) return;
          this.handleDragEnd(event);
        })
    )
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction(() => {
          if (this.overlayLocked) return;
          this.overlayLocked = true;
          this.viewModel.overlayState.config.isLocked = true;
          this.viewModel.overlayState.configVersion++;
          PreferencesUtil.put(SettingsKeys.PERF_OVERLAY_LOCKED, true);
          this.playLockFlash();
          try {
            promptAction.showToast({ message: '� 已锁定，触摸将透传至游戏', duration: 1500 });
          } catch (_) {}
        })
    )
    .onClick(() => {
      if (this.overlayLocked) return;
      this.handleClick();
    })

      // 首次操作引导提示
      if (this.showGuide) {
        Column({ space: 6 }) {
          Text('操作提示')
            .fontSize(12)
            .fontColor('#FFD700')
            .fontWeight(FontWeight.Bold)
          Text('👆 单击 → 设置显示项')
            .fontSize(11)
            .fontColor('#DDFFFFFF')
          Text('👆👆 双击 → 切换横竖布局')
            .fontSize(11)
            .fontColor('#DDFFFFFF')
          Text('✋ 拖动 → 调整位置')
            .fontSize(11)
            .fontColor('#DDFFFFFF')
          Text('👇 长按 → 锁定(触摸穿透)')
            .fontSize(11)
            .fontColor('#DDFFFFFF')
        }
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor('#E0161616')
        .borderRadius(10)
        .border({ width: 1, color: '#30FFD700' })
        .position({
          x: this.overlayX + this.overlayWidth + 8,
          y: this.overlayY
        })
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }
  
  // ==================== 矢量图标 ====================
  
  @Builder
  PerfIcon(res: Resource, size: number = 14, color: ResourceColor = '#FFFFFF') {
    Image(res)
      .width(size)
      .height(size)
      .fillColor(color)
  }

  /**
   * 电池图标 — 通过 if/else 分支让 ArkUI 在电量档位变化时销毁/重建 Image
   * 解决 Image(Resource) 不检测 Resource 对象变化的框架问题
   */
  @Builder
  BatteryIcon(size: number) {
    if (this.perfIsCharging) {
      Image(PerfSymbols.CHARGING).width(size).height(size).fillColor(getBatteryColor(this.perfBatteryLevel))
    } else if (this.perfBatteryLevel > 75) {
      Image(PerfSymbols.BATTERY_FULL).width(size).height(size).fillColor(getBatteryColor(this.perfBatteryLevel))
    } else if (this.perfBatteryLevel > 50) {
      Image(PerfSymbols.BATTERY_MID).width(size).height(size).fillColor(getBatteryColor(this.perfBatteryLevel))
    } else if (this.perfBatteryLevel > 20) {
      Image(PerfSymbols.BATTERY_LOW).width(size).height(size).fillColor(getBatteryColor(this.perfBatteryLevel))
    } else {
      Image(PerfSymbols.BATTERY_EMPTY).width(size).height(size).fillColor(getBatteryColor(this.perfBatteryLevel))
    }
  }
  
  // ==================== 垂直布局 ====================
  
  @Builder
  VerticalContent() {
    // 分辨率行
    if (this.enabledItemsList.includes(PerformanceItem.RESOLUTION)) {
      Row() {
        if (this.showMiniClock) {
          this.MiniClock(14)
        } else {
          Text(getMoonPhaseIcon(this.overlayLocked))
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
        }
        Text(` ${this.viewModel.displayInfo.streamWidth}x${this.viewModel.displayInfo.streamHeight}@${this.viewModel.streamConfig?.fps || 60}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
        if (this.perfUpscaleMode > 0) {
          Text(` ${this.perfUpscaleMode === 1 ? 'XEngine' : 'FSR1'}`)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor('#7CFC00')
        }
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
        this.PerfIcon(PerfSymbols.PACKET_LOSS, 14, getPacketLossColor(this.perfPacketLoss))
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
        this.PerfIcon(PerfSymbols.BITRATE, 14, '#BCEDD3')
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
        this.PerfIcon(PerfSymbols.NETWORK, 14,
          this.perfNetworkLatency < 0 ? '#64FFDA' : (this.perfNetworkLatency > 50 ? '#FFA726' : '#4CAF50'))
        Text(this.perfNetworkLatency !== 0 ? ` ${this.perfNetworkLatency}` : ' N/A')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.perfNetworkLatency < 0 ? '#64FFDA' : (this.perfNetworkLatency > 50 ? '#FFA726' : '#4CAF50'))
        Text(' ms')
          .fontSize(11)
          .fontColor('#CCFFFFFF')
      }
      .margin({ bottom: 4 })
    }

    // 解码延迟行
    if (this.enabledItemsList.includes(PerformanceItem.DECODE_LATENCY)) {
      Row() {
        if (this.perfLatency >= 20) {
          Text('🔥').fontSize(13)
        } else if (this.perfLatency < 0) {
          Text('❄️').fontSize(13)
        } else {
          this.PerfIcon(PerfSymbols.DECODE_NORMAL, 14, getLatencyColor(this.perfLatency))
        }
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
        this.PerfIcon(PerfSymbols.HOST, 14, this.perfHostLatency < 0 ? '#64FFDA' : '#009688')
        Text(this.perfHostLatency !== 0 ? ` ${this.perfHostLatency.toFixed(1)}` : ' N/A')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.perfHostLatency < 0 ? '#64FFDA' : '#009688')
        Text(' ms')
          .fontSize(11)
          .fontColor('#CCFFFFFF')
      }
      .margin({ bottom: 4 })
    }

    // 电池行
    if (this.enabledItemsList.includes(PerformanceItem.BATTERY)) {
      Row() {
        this.BatteryIcon(14)
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
        if (this.showMiniClock) {
          this.MiniClock(13)
        } else {
          Text(getMoonPhaseIcon(this.overlayLocked))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
        }
        Text(` ${this.viewModel.displayInfo.streamWidth}x${this.viewModel.displayInfo.streamHeight}@${this.viewModel.streamConfig?.fps || 60}`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
        if (this.perfUpscaleMode > 0) {
          Text(` ${this.perfUpscaleMode === 1 ? 'XEngine' : 'FSR1'}`)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor('#7CFC00')
        }
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
        this.PerfIcon(PerfSymbols.PACKET_LOSS, 13, getPacketLossColor(this.perfPacketLoss))
        Text(` ${this.perfPacketLoss.toFixed(1)}%`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(getPacketLossColor(this.perfPacketLoss))
        if (this.hasNextItem(PerformanceItem.PACKET_LOSS)) this.Separator()
      }
      
      // 带宽
      if (this.enabledItemsList.includes(PerformanceItem.BITRATE)) {
        this.PerfIcon(PerfSymbols.BITRATE, 13, '#BCEDD3')
        Text(` ${formatDataRate(this.perfBitrate)}`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#BCEDD3')
        if (this.hasNextItem(PerformanceItem.BITRATE)) this.Separator()
      }
      
      // 网络延迟
      if (this.enabledItemsList.includes(PerformanceItem.NETWORK_LATENCY)) {
        this.PerfIcon(PerfSymbols.NETWORK, 13,
          this.perfNetworkLatency < 0 ? '#64FFDA' : (this.perfNetworkLatency > 50 ? '#FFA726' : '#4CAF50'))
        Text(this.perfNetworkLatency !== 0 ? ` ${this.perfNetworkLatency} ms` : ' N/A')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.perfNetworkLatency < 0 ? '#64FFDA' : (this.perfNetworkLatency > 50 ? '#FFA726' : '#4CAF50'))
        if (this.hasNextItem(PerformanceItem.NETWORK_LATENCY)) this.Separator()
      }
      
      // 解码延迟
      if (this.enabledItemsList.includes(PerformanceItem.DECODE_LATENCY)) {
        if (this.perfLatency >= 20) {
          Text('🥵').fontSize(12)
        } else if (this.perfLatency < 0) {
          Text('❄️').fontSize(12)
        } else {
          this.PerfIcon(PerfSymbols.DECODE_NORMAL, 13, getLatencyColor(this.perfLatency))
        }
        Text(` ${this.perfLatency.toFixed(1)} ms`)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(getLatencyColor(this.perfLatency))
        if (this.hasNextItem(PerformanceItem.DECODE_LATENCY)) this.Separator()
      }
      
      // 主机延迟
      if (this.enabledItemsList.includes(PerformanceItem.HOST_LATENCY)) {
        this.PerfIcon(PerfSymbols.HOST, 13, this.perfHostLatency < 0 ? '#64FFDA' : '#009688')
        Text(this.perfHostLatency !== 0 ? ` ${this.perfHostLatency.toFixed(1)} ms` : ' N/A')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.perfHostLatency < 0 ? '#64FFDA' : '#009688')
        if (this.hasNextItem(PerformanceItem.HOST_LATENCY)) this.Separator()
      }
      
      // 电池
      if (this.enabledItemsList.includes(PerformanceItem.BATTERY)) {
        this.BatteryIcon(13)
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
        checked: isEnabled,
        icon: info.icon
      };
      options.push(opt);
    }

    // 隐藏覆盖层选项
    options.push({
      title: '隐藏覆盖层',
      subtitle: '可在游戏菜单中重新打开',
      value: 'hide_overlay',
      icon: $r('app.media.perf_hide')
    });

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
      title: '背景透明度',
      icon: $r('app.media.perf_opacity'),
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
      subtitle: '单击设置显示/隐藏项目，拖动调整位置，双击切换布局，长按锁定事件穿透',
      options: this.buildSettingsOptions(),
      selectedValue: '',
      sliderConfig: sliderCfg,
      closeOnSelect: false,
      refreshOptions: (): OptionItem[] => {
        return this.buildSettingsOptions();
      },
      onSelect: (option: OptionItem) => {
        const val = option.value as string;
        if (val === 'hide_overlay') {
          this.viewModel.toggleOverlay();
          this.settingsDialogController?.close();
          return;
        }
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
