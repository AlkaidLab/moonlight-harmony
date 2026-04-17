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
import { promptAction } from '@kit.ArkUI';
import { common, bundleManager, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppColors, AppSizes, AppSpacing, AppAnimation } from '../../common/Theme';
import { ToastQueue } from '../../utils/ToastQueue';

const GITHUB_URL = 'https://github.com/AlkaidLab/moonlight-harmony';
const QQ_GROUP_NUMBER = '103206957';

/**
 * PIN 码对话框
 */
@Component
export struct PinDialogView {
  @Prop pin: string = '';
  @Prop computerName: string = '';
  onClose: () => void = () => {};

  build() {
    Stack() {
      // 背景遮罩
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => { this.onClose(); })

      // 对话框
      Column() {
        Text('配对 PIN 码')
          .fontSize(AppSizes.FontHeadline)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.TextPrimary)
          .margin({ bottom: AppSpacing.Medium })

        Text(`请在 ${this.computerName} 上输入以下 PIN 码：`)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextSecondary)
          .textAlign(TextAlign.Center)
          .margin({ bottom: AppSpacing.Large })

        // PIN 码显示
        Row() {
          ForEach(this.pin.split(''), (digit: string) => {
            Text(digit)
              .fontSize(36)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.Primary)
              .width(56)
              .height(72)
              .textAlign(TextAlign.Center)
              .backgroundColor(AppColors.PrimaryGlow)
              .borderRadius(AppSizes.RadiusMedium)
          })
        }
        .justifyContent(FlexAlign.SpaceEvenly)
        .width('100%')
        .margin({ bottom: AppSpacing.XLarge })

        Text('正在等待配对完成...')
          .fontSize(AppSizes.FontCaption)
          .fontColor(AppColors.TextSecondary)

        Button('取消')
          .width('100%')
          .height(44)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextSecondary)
          .backgroundColor(Color.Transparent)
          .margin({ top: AppSpacing.Large })
          .onClick(() => { this.onClose(); })
      }
      .width('85%')
      .padding(AppSpacing.XLarge)
      .backgroundColor(AppColors.Surface)
      .borderRadius(AppSizes.RadiusXLarge)
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.OPACITY.animation({ duration: AppAnimation.Normal, curve: Curve.EaseOut })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }).animation({ duration: AppAnimation.Normal, curve: Curve.EaseOut })))
  }
}

/**
 * 关于对话框
 */
@Component
export struct AboutDialogView {
  onClose: () => void = () => {};

  build() {
    Stack() {
      // 背景遮罩
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => { this.onClose(); })

      // 对话框
      Column() {
        Image($r('app.media.vplus'))
          .width(80)
          .height(80)
          .borderRadius(16)
          .objectFit(ImageFit.Cover)
          .margin({ bottom: AppSpacing.Medium })

        Text('Moonlight V+')
          .fontSize(AppSizes.FontLargeTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.Primary)
          .margin({ bottom: AppSpacing.Small })

        Text(AboutDialogView.getVersionInfo())
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextSecondary)
          .margin({ bottom: AppSpacing.Large })

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
            .onClick(() => { AboutDialogView.openUrl(GITHUB_URL); })

          Button('复制QQ群号')
            .height(40)
            .fontSize(AppSizes.FontBody)
            .fontColor(Color.White)
            .backgroundColor('#12B7F5')
            .borderRadius(AppSizes.RadiusMedium)
            .layoutWeight(1)
            .margin({ left: AppSpacing.Medium })
            .onClick(() => { AboutDialogView.copyQQGroupNumber(); })
        }
        .width('100%')
        .margin({ bottom: AppSpacing.Medium })

        Button('关闭')
          .width('100%')
          .height(44)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextSecondary)
          .backgroundColor(Color.Transparent)
          .onClick(() => { this.onClose(); })
      }
      .width('85%')
      .padding(AppSpacing.XLarge)
      .backgroundColor(AppColors.Surface)
      .borderRadius(AppSizes.RadiusXLarge)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.OPACITY.animation({ duration: AppAnimation.Normal, curve: Curve.EaseOut })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }).animation({ duration: AppAnimation.Normal, curve: Curve.EaseOut })))
  }

  static getVersionInfo(): string {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      return `版本 ${bundleInfo.versionName} (Build ${bundleInfo.versionCode})`;
    } catch (_e) {
      return '版本未知';
    }
  }

  static openUrl(url: string): void {
    try {
      const context = getContext() as common.UIAbilityContext;
      const want: Want = { action: 'ohos.want.action.viewData', uri: url };
      context.startAbility(want);
    } catch (_e) {
      ToastQueue.show({ message: '无法打开链接' });
    }
  }

  static copyQQGroupNumber(): void {
    const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, QQ_GROUP_NUMBER);
    pasteboard.getSystemPasteboard().setDataSync(pasteData);
    ToastQueue.show({ message: `群号 ${QQ_GROUP_NUMBER} 已复制，请在 QQ 中搜索加入` });
  }
}
