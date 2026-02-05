/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { router } from '@kit.ArkUI';
import { AppColors } from '../common/Theme';

@Entry
@Component
struct Index {
  @State isLoading: boolean = true;
  @State logoScale: number = 0.6;
  @State logoOpacity: number = 0;
  @State contentOpacity: number = 0;
  @State bottomOpacity: number = 0;

  aboutToAppear(): void {
    this.startAnimation();
  }

  startAnimation(): void {
    // Logo 淡入
    animateTo({
      duration: 500,
      curve: Curve.EaseOut,
    }, () => {
      this.logoOpacity = 1;
      this.logoScale = 1;
    });

    // 内容淡入
    setTimeout(() => {
      animateTo({
        duration: 400,
        curve: Curve.EaseOut,
      }, () => {
        this.contentOpacity = 1;
      });
    }, 300);

    // 底部淡入
    setTimeout(() => {
      animateTo({
        duration: 400,
        curve: Curve.EaseOut,
      }, () => {
        this.bottomOpacity = 1;
      });
    }, 500);

    // 跳转
    setTimeout(() => {
      this.isLoading = false;
      try {
        router.replaceUrl({ url: 'pages/PcListPageV2' });
      } catch (e) {
        console.error('Index: navigation failed - ' + e);
      }
    }, 2000);
  }

  build() {
    Column() {
      Blank()
        .layoutWeight(1)

      // Logo
      Image($r('app.media.app_icon'))
        .width(100)
        .height(100)
        .borderRadius(20)
        .scale({ x: this.logoScale, y: this.logoScale })
        .opacity(this.logoOpacity)
        .margin({ bottom: 24 })

      // 标题
      Column() {
        Text('Moonlight')
          .fontSize(36)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.TextPrimary)

        Row() {
          Text('V+')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.Primary)
            .backgroundColor(AppColors.PrimaryGlow)
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ right: 6 })

          Text('for HarmonyOS')
            .fontSize(14)
            .fontColor(AppColors.TextSecondary)
        }
        .margin({ top: 8 })
      }
      .opacity(this.contentOpacity)
      .margin({ bottom: 48 })

      // 加载
      if (this.isLoading) {
        LoadingProgress()
          .width(36)
          .height(36)
          .color(AppColors.Primary)
          .opacity(this.contentOpacity)
      }

      Blank()
        .layoutWeight(1)

      // 底部
      Column() {
        Text('Powered by AlkaidLab')
          .fontSize(12)
          .fontColor(AppColors.TextTertiary)
      }
      .opacity(this.bottomOpacity)
      .margin({ bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(AppColors.Background)
  }
}
