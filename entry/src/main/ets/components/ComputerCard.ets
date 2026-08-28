/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { ObservableComputer } from '../viewmodel/ComputerViewModel';
import { formatDisplayAddress } from '../model/ComputerInfo';
import { AppColors, AppSizes, AppSpacing, AppAnimation, AppShadows, StatusColors } from '../common/Theme';
import { LengthMetrics, ColorMetrics } from '@kit.ArkUI';

/**
 * 电脑卡片组件
 *
 * 功能特性：
 * - 显示电脑头像（boxArt）或默认图标
 * - 状态指示器（在线/离线/配对/游戏中）
 * - 快速串流按钮（在线且配对时显示）
 * - 触摸反馈动画
 * - 焦点支持（TV/键盘导航）
 * - 长按手势支持
 */
@Component
export struct ComputerCard {
  // ========== 必需属性 ==========
  @ObjectLink computer: ObservableComputer;

  // ========== 回调函数 ==========
  onTap: () => void = () => {};
  onLongPress: () => void = () => {};
  onQuickStream: () => void = () => {};  // 快速串流回调

  // ========== 私有状态 ==========
  @State private isPressed: boolean = false;
  @State private cardScale: number = 1;
  @State private boxArtLoadFailed: boolean = false;
  @State private quickStreamPressed: boolean = false;
  @State private quickStreamClicked: boolean = false;  // 标记快速串流按钮是否被点击
  @Prop @Watch('onOnlineTransitionChanged') onlineTransitionVersion: number = 0;
  @State private onlineHintActive: boolean = false;
  @State private onlinePulseScale: number = 0.45;
  @State private onlinePulseOpacity: number = 0;
  @State private onlineDotScale: number = 1;
  @State private onlineTextOffset: number = 0;
  @State private onlineTextOpacity: number = 1;
  private onlineHintResetTimer: number = -1;
  private onlineDotSettleTimer: number = -1;

  // ========== 常量定义 ==========
  private readonly AVATAR_SIZE: number = AppSizes.AvatarLarge;
  private readonly ICON_SIZE: number = 40;
  private readonly PRESS_SCALE: number = 0.98;

  // ========== 生命周期 ==========
  aboutToAppear() {
    // 组件初始化时重置加载状态
    this.boxArtLoadFailed = false;
    this.consumePendingOnlineHint();
  }

  aboutToDisappear(): void {
    this.clearOnlineHintTimer();
  }

  // ========== 辅助方法 ==========

  /**
   * 获取 boxArt 图片源（本地路径需要加 file:// 前缀）
   */
  private getBoxArtSource(): string {
    const url = this.computer.boxArtUrl;
    if (!url) return '';
    if (url.startsWith('http')) return url;
    return 'file://' + url;
  }

  /**
   * 判断是否显示 boxArt 图片
   */
  private shouldShowBoxArt(): boolean {
    return !!this.computer.boxArtUrl && !this.boxArtLoadFailed;
  }

  /**
   * 获取状态指示点颜色
   */
  private getStatusDotColor(): string {
    if (!this.computer.isOnline) return StatusColors.OfflineDark;
    if (!this.computer.isPaired) return StatusColors.UnpairedDark;
    if (this.computer.isGaming) return StatusColors.GamingDark;
    return StatusColors.OnlineDark;
  }

  /**
   * 获取图片透明度（离线时半透明）
   */
  private getImageOpacity(): number {
    return this.computer.isOnline ? 1 : 0.5;
  }

  /**
   * 是否显示快速串流按钮
   */
  private canQuickStream(): boolean {
    return this.computer.isOnline && this.computer.isPaired;
  }

  private clearOnlineHintTimer(): void {
    if (this.onlineHintResetTimer !== -1) {
      clearTimeout(this.onlineHintResetTimer);
      this.onlineHintResetTimer = -1;
    }
    if (this.onlineDotSettleTimer !== -1) {
      clearTimeout(this.onlineDotSettleTimer);
      this.onlineDotSettleTimer = -1;
    }
  }

  private onOnlineTransitionChanged(): void {
    this.consumePendingOnlineHint();
  }

  private consumePendingOnlineHint(): void {
    if (!this.computer.shouldPlayOnlineTransition()) {
      return;
    }
    this.computer.markOnlineTransitionPlayed();
    this.playOnlineHint();
  }

  private playOnlineHint(): void {
    this.clearOnlineHintTimer();
    this.onlineHintActive = true;
    this.onlinePulseScale = 0.45;
    this.onlinePulseOpacity = 0.48;
    this.onlineDotScale = 0.76;
    this.onlineTextOffset = 6;
    this.onlineTextOpacity = 0;

    animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
      this.onlineDotScale = 1.42;
      this.onlineTextOffset = 0;
      this.onlineTextOpacity = 1;
    });

    this.onlineDotSettleTimer = setTimeout(() => {
      this.onlineDotSettleTimer = -1;
      animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
        this.onlineDotScale = 1;
      });
    }, 260);

    animateTo({ duration: 1150, curve: Curve.EaseOut }, () => {
      this.onlinePulseScale = 3.4;
      this.onlinePulseOpacity = 0;
    });

    this.onlineHintResetTimer = setTimeout(() => {
      this.onlineHintActive = false;
      this.onlineDotScale = 1;
      this.onlineTextOffset = 0;
      this.onlineTextOpacity = 1;
      this.onlinePulseScale = 0.45;
      this.onlinePulseOpacity = 0;
      this.onlineHintResetTimer = -1;
    }, 1250);
  }

  private getOnlineHintPulseFill(): string {
    if (!this.computer.isPaired) {
      return 'rgba(255, 183, 77, 0.32)';
    }
    if (this.computer.isGaming) {
      return 'rgba(255, 112, 67, 0.30)';
    }
    return 'rgba(139, 195, 74, 0.30)';
  }

  private getOnlineHintShadowColor(): string {
    if (!this.computer.isPaired) {
      return 'rgba(255, 183, 77, 0.42)';
    }
    if (this.computer.isGaming) {
      return 'rgba(255, 112, 67, 0.36)';
    }
    return 'rgba(139, 195, 74, 0.38)';
  }

  private getCardBorderColor(): ResourceColor {
    if (this.isPressed) {
      return AppColors.Primary;
    }
    if (this.onlineHintActive) {
      return this.getStatusDotColor();
    }
    return AppColors.CardBorder;
  }

  private getCardShadow(): ShadowOptions {
    if (this.isPressed) {
      return AppShadows.GlowGreen;
    }
    if (this.onlineHintActive) {
      return {
        radius: 24,
        color: this.getOnlineHintShadowColor(),
        offsetX: 0,
        offsetY: 0
      };
    }
    return AppShadows.Medium;
  }

  // ========== UI 构建器 ==========

  /**
   * 构建默认图标
   */
  @Builder
  private DefaultIcon() {
    Column() {
      Image($r('app.media.ic_pc_default'))
        .width(this.ICON_SIZE)
        .height(this.ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .opacity(this.getImageOpacity())
    }
    .width(this.AVATAR_SIZE)
    .height(this.AVATAR_SIZE)
    .borderRadius(AppSizes.RadiusLarge)
    .backgroundColor(AppColors.Surface)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 构建头像区域（带状态指示器）
   */
  @Builder
  private AvatarSection() {
    Stack() {
      // 头像内容
      if (this.shouldShowBoxArt()) {
        this.BoxArtWithFallback()
      } else {
        this.DefaultIcon()
      }
    }
    .width(this.AVATAR_SIZE)
    .height(this.AVATAR_SIZE)
    .borderRadius(AppSizes.RadiusLarge)
    .clip(true)
    .margin({ right: AppSpacing.Large })
  }

  /**
   * 构建带 fallback 的 BoxArt 图片
   */
  @Builder
  private BoxArtWithFallback() {
    Stack() {
      // 底层：默认图标作为 fallback
      this.DefaultIcon()

      // 顶层：BoxArt 图片
      Image(this.getBoxArtSource())
        .width(this.AVATAR_SIZE)
        .height(this.AVATAR_SIZE)
        .borderRadius(AppSizes.RadiusLarge)
        .objectFit(ImageFit.Cover)
        .opacity(this.getImageOpacity())
        .onError(() => {
          this.boxArtLoadFailed = true;
        })
    }
    .width(this.AVATAR_SIZE)
    .height(this.AVATAR_SIZE)
  }

  /** 状态文本颜色复用状态指示点颜色 */
  private getStatusTextColor(): string {
    return this.getStatusDotColor();
  }

  /**
   * 构建电脑信息区域
   */
  @Builder
  private InfoSection() {
    Column() {
      // 第一行：名称
      Text(this.computer.name)
        .fontSize(AppSizes.FontTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.computer.isOnline ? AppColors.Primary : AppColors.TextSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      // 第二行：IP 地址（优先显示手动地址，保持稳定；否则显示轮询活跃地址；自定义端口时附带 :port）
      Text(formatDisplayAddress(this.computer))
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .fontFamily('monospace')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.MARQUEE })
        .margin({ top: AppSpacing.XSmall })

      // 第三行：状态圆点 + 状态文本
      Row() {
        this.OnlineStatusDot()
        Text(this.computer.statusText)
          .fontSize(AppSizes.FontCaption)
          .fontColor(this.getStatusTextColor())
          .opacity(this.onlineHintActive ? this.onlineTextOpacity : 1)
          .translate({ y: this.onlineHintActive ? this.onlineTextOffset : 0 })
      }
      .margin({ top: AppSpacing.Small })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder
  private OnlineStatusDot() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.onlineHintActive && this.computer.isOnline) {
        Ellipse()
          .width(18)
          .height(18)
          .fill(this.getOnlineHintPulseFill())
          .opacity(this.onlinePulseOpacity)
          .scale({ x: this.onlinePulseScale, y: this.onlinePulseScale })
      }
      Ellipse()
        .width(8)
        .height(8)
        .fill(this.getStatusDotColor())
        .scale({ x: this.onlineHintActive ? this.onlineDotScale : 1, y: this.onlineHintActive ? this.onlineDotScale : 1 })
    }
    .width(24)
    .height(24)
    .margin({ right: 2 })
  }

  /**
   * 构建快速串流按钮
   */
  @Builder
  private QuickStreamButton() {
    Column() {
      Image($r('app.media.ic_play'))
        .width(20)
        .height(20)
        .fillColor(Color.White)
    }
    .width(44)
    .height(44)
    .borderRadius(22)
    .backgroundColor(this.quickStreamPressed ? AppColors.PrimaryDark : AppColors.Primary)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .shadow({
      radius: this.quickStreamPressed ? 4 : 8,
      color: AppColors.GlowGreen,
      offsetX: 0,
      offsetY: 2
    })
    .scale({ x: this.quickStreamPressed ? 0.95 : 1, y: this.quickStreamPressed ? 0.95 : 1 })
    .animation({ duration: 100 })
    .onClick(() => {
      // 标记快速串流按钮被点击，防止触发卡片点击
      this.quickStreamClicked = true;
      this.onQuickStream();
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.quickStreamPressed = true;
        this.quickStreamClicked = false;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.quickStreamPressed = false;
      }
    })
  }

  // ========== 主构建方法 ==========
  build() {
    Column() {
      Row() {
        // 头像区域
        this.AvatarSection()

        // 信息区域
        this.InfoSection()

        // 快速串流按钮（仅在线且配对时显示）
        if (this.canQuickStream()) {
          this.QuickStreamButton()
        } else {
          // 箭头指示器
          Image($r('app.media.ic_arrow_right'))
            .width(AppSizes.IconMedium)
            .height(AppSizes.IconMedium)
            .fillColor(this.computer.isOnline ? AppColors.Primary : AppColors.TextTertiary)
        }
      }
      .width('100%')
      .padding(AppSpacing.Large)
    }
    .width('100%')
    .backgroundColor(AppColors.CardBackground)
    .borderRadius(AppSizes.RadiusLarge)
    .borderWidth(1)
    .borderColor(this.getCardBorderColor())
    .shadow(this.getCardShadow())
    .scale({ x: this.cardScale, y: this.cardScale })
    .animation({
      duration: AppAnimation.Fast,
      curve: AppAnimation.Spring
    })
    // 焦点支持
    .focusable(true)
    .focusOnTouch(true)
    .focusBox({
      margin: LengthMetrics.vp(2),
      strokeColor: ColorMetrics.rgba(0, 212, 255, 1),
      strokeWidth: LengthMetrics.vp(2)
    })
    .onKeyEvent((event: KeyEvent) => {
      if (event.type === KeyType.Down) {
        // A键/回车 → 选择此电脑
        if (event.keyCode === 2054 || event.keyCode === 2050) {
          this.onTap();
          return true;
        }
        // 菜单键 → 长按菜单
        if (event.keyCode === 2051) {
          this.onLongPress();
          return true;
        }
      }
      return false;
    })
    // 触摸事件
    .onClick(() => {
      // 如果是快速串流按钮点击，不触发卡片点击
      if (this.quickStreamClicked) {
        this.quickStreamClicked = false;
        return;
      }
      this.onTap();
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.isPressed = true;
        this.cardScale = this.PRESS_SCALE;
        this.quickStreamClicked = false;  // 重置标记
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPressed = false;
        this.cardScale = 1;
      }
    })
    // 长按手势
    .gesture(
      LongPressGesture({ duration: 500 })
        .onAction(() => this.onLongPress())
    )
  }
}
