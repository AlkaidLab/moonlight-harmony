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
 * PC 列表页面对话框组件
 * 
 * 包含:
 * - PIN 码配对对话框
 * - 关于对话框
 */
import { AppColors, AppSizes, AppSpacing } from '../common/Theme';

/**
 * PIN 码对话框配置
 */
export interface PinDialogConfig {
  /** 是否显示 */
  visible: boolean;
  /** PIN 码 */
  pin: string;
  /** 配对的电脑名称 */
  computerName: string;
  /** 关闭回调 */
  onClose: () => void;
}

/**
 * 关于对话框配置
 */
export interface AboutDialogConfig {
  /** 是否显示 */
  visible: boolean;
  /** 版本信息 */
  versionInfo: string;
  /** 关闭回调 */
  onClose: () => void;
  /** 打开 URL 回调 */
  onOpenUrl: (url: string) => void;
  /** 加入 QQ 群回调 */
  onJoinQQGroup: (key: string) => void;
}

/**
 * PIN 码配对对话框
 */
@Component
export struct PinDialog {
  @Prop config: PinDialogConfig = {
    visible: false,
    pin: '',
    computerName: '',
    onClose: () => {}
  };

  build() {
    if (this.config.visible) {
      Stack() {
        // 背景遮罩
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.config.onClose();
          })
        
        // 对话框内容
        Column() {
          // 标题
          Text('配对 PIN 码')
            .fontSize(AppSizes.FontHeadline)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.TextPrimary)
            .margin({ bottom: AppSpacing.Medium })
          
          Text(`请在 ${this.config.computerName} 上输入以下 PIN 码：`)
            .fontSize(AppSizes.FontBody)
            .fontColor(AppColors.TextSecondary)
            .textAlign(TextAlign.Center)
            .margin({ bottom: AppSpacing.Large })
          
          // PIN 码显示
          Row() {
            ForEach(this.config.pin.split(''), (digit: string) => {
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
              this.config.onClose();
            })
        }
        .width('85%')
        .padding(AppSpacing.XLarge)
        .backgroundColor(AppColors.Surface)
        .borderRadius(AppSizes.RadiusXLarge)
      }
      .width('100%')
      .height('100%')
    }
  }
}

/**
 * 关于对话框
 */
@Component
export struct AboutDialog {
  @Prop config: AboutDialogConfig = {
    visible: false,
    versionInfo: '',
    onClose: () => {},
    onOpenUrl: () => {},
    onJoinQQGroup: () => {}
  };

  build() {
    if (this.config.visible) {
      Stack() {
        // 背景遮罩
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.config.onClose();
          })
        
        // 对话框内容
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
          Text(this.config.versionInfo)
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
                this.config.onOpenUrl('https://github.com/qiin2333/moonlight-vplus');
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
                this.config.onJoinQQGroup('MeQFXB4ZoznvRzz7q_38LTmW5HrcfzcL');
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
              this.config.onClose();
            })
        }
        .width('85%')
        .padding(AppSpacing.XLarge)
        .backgroundColor(AppColors.Surface)
        .borderRadius(AppSizes.RadiusXLarge)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
    }
  }
}
