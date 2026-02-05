/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { ObservableApp } from '../viewmodel/AppViewModel';
import { AppColors, AppSizes } from '../common/Theme';
import { LengthMetrics, ColorMetrics } from '@kit.ArkUI';

// 应用卡片尺寸常量
const CARD_WIDTH = 160;
const CARD_ICON_HEIGHT = 120;
const CARD_TITLE_HEIGHT = 40;

/**
 * 应用卡片组件 - 简洁现代风格
 */
@Component
export struct AppCard {
  @ObjectLink app: ObservableApp;
  onTap: () => void = () => {};
  onLongPress: () => void = () => {};
  onSelect: () => void = () => {}; // 选中回调（用于更新背景图）

  @State private isPressed: boolean = false;
  @State private isFocused: boolean = false;
  @State private imageLoadFailed: boolean = false;

  build() {
    Column() {
      // 图标区域
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.app.localIconPath && !this.imageLoadFailed) {
          Image('file://' + this.app.localIconPath)
            .width('100%')
            .height(CARD_ICON_HEIGHT)
            .objectFit(ImageFit.Cover)
            .borderRadius({ topLeft: AppSizes.RadiusMedium, topRight: AppSizes.RadiusMedium })
            .onError(() => {
              this.imageLoadFailed = true;
            })
        } else if (!this.app.iconLoaded && this.app.iconUrl) {
          Column() {
            LoadingProgress()
              .width(32)
              .height(32)
              .color(AppColors.TextSecondary)
          }
          .width('100%')
          .height(CARD_ICON_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#1E1E2E')
          .borderRadius({ topLeft: AppSizes.RadiusMedium, topRight: AppSizes.RadiusMedium })
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.gamecontroller_fill'))
              .fontSize(48)
              .fontColor([AppColors.TextSecondary])
          }
          .width('100%')
          .height(CARD_ICON_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#1E1E2E')
          .borderRadius({ topLeft: AppSizes.RadiusMedium, topRight: AppSizes.RadiusMedium })
        }

        // 运行中指示器
        if (this.app.isRunning) {
          Row() {
            Circle()
              .width(6)
              .height(6)
              .fill('#4ADE80')
            Text('运行中')
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor('#4ADE80')
              .margin({ left: 4 })
          }
          .padding({ left: 8, right: 10, top: 4, bottom: 4 })
          .backgroundColor('rgba(0, 0, 0, 0.7)')
          .borderRadius(12)
          .margin({ left: 6, top: 6 })
        }
      }
      .width('100%')
      .height(CARD_ICON_HEIGHT)

      // 应用名称
      Text(this.app.name)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColors.TextPrimary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .lineHeight(16)
        .width('100%')
        .height(CARD_TITLE_HEIGHT)
        .padding({ left: 6, right: 6, top: 4, bottom: 4 })
    }
    .width(CARD_WIDTH)
    .backgroundColor(AppColors.CardBackground)
    .borderRadius(AppSizes.RadiusMedium)
    .borderWidth(this.app.isRunning ? 2 : 1)
    .borderColor(this.app.isRunning ? '#4ADE80' : AppColors.CardBorder)
    .shadow({
      radius: this.isFocused ? 16 : 8,
      color: this.app.isRunning ? 'rgba(74, 222, 128, 0.25)' : 'rgba(0, 0, 0, 0.3)',
      offsetX: 0,
      offsetY: this.isFocused ? 8 : 4
    })
    .clip(true)
    // 缩放：按下时缩小，焦点时放大，其他正常
    .scale({
      x: this.isPressed ? 0.96 : (this.isFocused ? 1.05 : 1),
      y: this.isPressed ? 0.96 : (this.isFocused ? 1.05 : 1)
    })
    .animation({ duration: 150, curve: Curve.EaseOut })
    .focusable(true)
    .focusBox({
      margin: LengthMetrics.vp(2),
      strokeColor: ColorMetrics.rgba(74, 222, 128, 1),
      strokeWidth: LengthMetrics.vp(2)
    })
    .onFocus(() => {
      this.isFocused = true;
      this.onSelect();
    })
    .onBlur(() => {
      this.isFocused = false;
    })
    .onKeyEvent((event: KeyEvent) => {
      if (event.type === KeyType.Down) {
        // 确认键
        if (event.keyCode === 2054 || event.keyCode === 2050) {
          this.onTap();
          return true;
        }
        // 菜单键
        if (event.keyCode === 2051) {
          this.onLongPress();
          return true;
        }
      }
      return false;
    })
    .onClick(() => {
      this.onSelect();
      this.onTap();
    })
    .gesture(
      LongPressGesture({ duration: 500 })
        .onAction(() => {
          this.onSelect();
          this.onLongPress();
        })
    )
    .onTouch((event: TouchEvent) => {
      this.isPressed = (event.type === TouchType.Down);
    })
  }
}
