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

  // ========== 常量定义 ==========
  private readonly AVATAR_SIZE: number = AppSizes.AvatarLarge;
  private readonly ICON_SIZE: number = 40;
  private readonly STATUS_DOT_SIZE: number = 14;
  private readonly PRESS_SCALE: number = 0.98;

  // ========== 生命周期 ==========
  aboutToAppear() {
    // 组件初始化时重置加载状态
    this.boxArtLoadFailed = false;
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
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 头像内容
      if (this.shouldShowBoxArt()) {
        this.BoxArtWithFallback()
      } else {
        this.DefaultIcon()
      }

      // 状态指示点
      Circle()
        .width(this.STATUS_DOT_SIZE)
        .height(this.STATUS_DOT_SIZE)
        .fill(this.getStatusDotColor())
        .stroke(AppColors.CardBackground)
        .strokeWidth(2)
        .shadow({
          radius: 4,
          color: this.getStatusDotColor() + '80',
          offsetX: 0,
          offsetY: 0
        })
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

  /**
   * 获取状态文本颜色
   */
  private getStatusTextColor(): string {
    if (!this.computer.isOnline) return StatusColors.OfflineDark;
    if (!this.computer.isPaired) return StatusColors.UnpairedDark;
    if (this.computer.isGaming) return StatusColors.GamingDark;
    return StatusColors.OnlineDark;
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

      // 第二行：IP 地址
      Text(this.computer.address)
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .fontFamily('monospace')
        .margin({ top: AppSpacing.XSmall })

      // 第三行：状态文本（不再重复显示配对徽章）
      Text(this.computer.statusText)
        .fontSize(AppSizes.FontCaption)
        .fontColor(this.getStatusTextColor())
        .margin({ top: AppSpacing.Small })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
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
    .borderColor(this.isPressed ? AppColors.Primary : AppColors.CardBorder)
    .shadow(this.isPressed ? AppShadows.GlowGreen : AppShadows.Medium)
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
