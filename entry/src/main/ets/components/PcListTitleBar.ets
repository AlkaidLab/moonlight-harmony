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
 * PC 列表页面标题栏组件
 */
import { router } from '@kit.ArkUI';
import { AppColors, AppSizes, AppSpacing } from '../common/Theme';

/**
 * 标题栏配置
 */
export interface TitleBarConfig {
  /** 在线设备数量 */
  onlineCount: number;
  /** 总设备数量 */
  totalCount: number;
  /** 关于按钮点击回调 */
  onAboutClick: () => void;
  /** 设置按钮点击回调 */
  onSettingsClick: () => void;
}

/**
 * PC 列表标题栏
 */
@Component
export struct PcListTitleBar {
  @Prop config: TitleBarConfig = {
    onlineCount: 0,
    totalCount: 0,
    onAboutClick: () => {},
    onSettingsClick: () => {}
  };

  build() {
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

            if (this.config.totalCount > 0) {
              Row() {
                Circle()
                  .width(6)
                  .height(6)
                  .fill(AppColors.Online)
                  .margin({ right: 6 })
                Text(`${this.config.onlineCount} 在线`)
                  .fontSize(AppSizes.FontCaption)
                  .fontColor(AppColors.Online)
                Text(` / ${this.config.totalCount} 台设备`)
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
        this.config.onAboutClick();
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
        this.config.onSettingsClick();
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
}
