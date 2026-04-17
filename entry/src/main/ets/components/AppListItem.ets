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
import { AppColors, AppSizes, AppSpacing } from '../common/Theme';

const ITEM_ICON_SIZE = 48;
const ACTION_BTN_SIZE = 36;
const LONG_PRESS_DURATION_MS = 500;

/**
 * 应用列表项（小图标模式使用）
 * - 左：图标 48×48
 * - 中：名称 + 运行状态 + HDR 标签
 * - 右：快捷操作（启动/停止 + 更多）
 */
@Component
export struct AppListItem {
  @ObjectLink app: ObservableApp;
  onTap: () => void = () => {};
  onLongPress: () => void = () => {};
  onPrimaryAction: () => void = () => {};   // 启动 / 停止
  onMoreAction: () => void = () => {};      // 打开完整菜单

  @Builder
  private Icon() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.app.localIconPath) {
        Image('file://' + this.app.localIconPath)
          .width(ITEM_ICON_SIZE)
          .height(ITEM_ICON_SIZE)
          .objectFit(ImageFit.Cover)
          .borderRadius(AppSizes.RadiusMedium)
          .draggable(false)
      } else if (!this.app.iconLoaded && this.app.iconUrl) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(AppColors.TextSecondary)
      } else {
        SymbolGlyph($r('sys.symbol.gamecontroller_fill'))
          .fontSize(28)
          .fontColor([AppColors.TextSecondary])
      }
    }
    .width(ITEM_ICON_SIZE)
    .height(ITEM_ICON_SIZE)
    .backgroundColor(AppColors.SurfaceDark)
    .borderRadius(AppSizes.RadiusMedium)
    .clip(true)
  }

  @Builder
  private HdrBadge() {
    Text('HDR')
      .fontSize(9)
      .fontWeight(FontWeight.Bold)
      .fontColor(AppColors.Accent)
      .borderWidth(1)
      .borderColor(AppColors.Accent)
      .borderRadius(AppSizes.RadiusSmall)
      .padding({
        left: AppSpacing.XSmall,
        right: AppSpacing.XSmall,
        top: 1,
        bottom: 1
      })
      .margin({ left: AppSpacing.Small })
  }

  @Builder
  private RunningIndicator() {
    Row() {
      Circle()
        .width(6)
        .height(6)
        .fill(AppColors.Online)
      Text('运行中')
        .fontSize(AppSizes.FontCaption - 1)
        .fontColor(AppColors.Online)
        .margin({ left: AppSpacing.XSmall })
    }
    .margin({ top: 2 })
  }

  @Builder
  private ActionButton(icon: Resource, color: ResourceColor, tap: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(icon)
        .fontSize(16)
        .fontColor([color])
    }
    .width(ACTION_BTN_SIZE)
    .height(ACTION_BTN_SIZE)
    .backgroundColor(AppColors.Surface)
    .borderWidth(1)
    .borderColor(AppColors.CardBorder)
    .onClick(() => tap())
  }

  @Builder
  private MoreButton() {
    Button({ type: ButtonType.Circle }) {
      Text('⋯')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.TextSecondary)
    }
    .width(ACTION_BTN_SIZE)
    .height(ACTION_BTN_SIZE)
    .backgroundColor(AppColors.Surface)
    .borderWidth(1)
    .borderColor(AppColors.CardBorder)
    .onClick(() => this.onMoreAction())
  }

  build() {
    Row() {
      this.Icon()

      Column() {
        Row() {
          Text(this.app.name)
            .fontSize(AppSizes.FontBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColors.TextPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.app.isHdrSupported) {
            this.HdrBadge()
          }
        }
        .width('100%')
        if (this.app.isRunning) {
          this.RunningIndicator()
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: AppSpacing.Medium, right: AppSpacing.Small })

      Row({ space: AppSpacing.Small }) {
        if (this.app.isRunning) {
          this.ActionButton($r('sys.symbol.xmark'), AppColors.Error, () => this.onPrimaryAction())
        } else {
          this.ActionButton($r('sys.symbol.play_fill'), AppColors.Accent, () => this.onPrimaryAction())
        }
        this.MoreButton()
      }
    }
    .width('100%')
    .padding({
      left: AppSpacing.Medium,
      right: AppSpacing.Medium,
      top: AppSpacing.Small,
      bottom: AppSpacing.Small
    })
    .backgroundColor(AppColors.CardBackground)
    .borderRadius(AppSizes.RadiusMedium)
    .borderWidth(this.app.isRunning ? 2 : 1)
    .borderColor(this.app.isRunning ? AppColors.Online : AppColors.CardBorder)
    .onClick(() => this.onTap())
    .gesture(
      LongPressGesture({ duration: LONG_PRESS_DURATION_MS })
        .onAction(() => this.onLongPress())
    )
  }
}
