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
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { common } from '@kit.AbilityKit';

/** 隐私政策同意状态持久化 key */
const PRIVACY_ACCEPTED_KEY = 'privacy_policy_accepted';

/**
 * 隐私政策章节
 */
interface PrivacySection {
  title: string;
  content: string;
}

@Entry
@Component
struct Index {
  @State isLoading: boolean = true;
  @State logoScale: number = 0.6;
  @State logoOpacity: number = 0;
  @State contentOpacity: number = 0;
  @State bottomOpacity: number = 0;
  /** 是否显示隐私政策同意弹窗 */
  @State showPrivacyConsent: boolean = false;
  /** 隐私政策弹窗透明度（用于淡入动画） */
  @State privacyDialogOpacity: number = 0;

  /** 隐私政策章节内容 */
  private privacySections: PrivacySection[] = [
    {
      title: '1. 数据收集与存储',
      content: '本应用不会主动收集、存储或传输任何用户的个人身份信息。' +
        '所有配置数据（如服务器地址、偏好设置、配对密钥）仅存储在您的设备本地。'
    } as PrivacySection,
    {
      title: '2. 设备信息',
      content: '本应用会读取设备型号名称（如 "HUAWEI Mate 60 Pro"）用于串流协议握手时标识客户端。' +
        '此信息仅在局域网内与您的电脑通信时使用，不会上传至任何互联网服务器。\n' +
        '本应用会在设备本地生成并保存一个随机标识符用于配对协议，该标识符不与任何个人身份信息关联。'
    } as PrivacySection,
    {
      title: '3. 网络通信',
      content: '• 应用仅在您的本地网络内与电脑建立连接，传输游戏音视频流和输入指令\n' +
        '• 使用 mDNS 协议在局域网内自动发现运行 GameStream/Sunshine 的电脑\n' +
        '• 不涉及任何互联网数据上传'
    } as PrivacySection,
    {
      title: '4. 权限使用',
      content: '• 网络权限：与电脑建立连接，传输游戏流\n' +
        '• 网络信息：检测网络连接状态，优化串流质量\n' +
        '• 麦克风：语音聊天功能（可选，使用时单独请求授权）\n' +
        '• 振动：手柄震动反馈\n' +
        '• 加速度/陀螺仪传感器：体感控制（可选）\n' +
        '• 后台运行：保持串流连接在后台不中断'
    } as PrivacySection,
    {
      title: '5. 第三方服务',
      content: '本应用不集成任何第三方分析、广告或数据追踪服务。'
    } as PrivacySection,
    {
      title: '6. 开源合规',
      content: '本应用基于 Moonlight 项目开发，遵循 GPLv3 开源协议。源代码可在 GitHub 获取。'
    } as PrivacySection
  ];

  aboutToAppear(): void {
    this.checkPrivacyConsent();
  }

  /**
   * 检查隐私政策同意状态
   * 已同意 → 正常启动动画 + 自动跳转
   * 未同意 → 显示隐私政策同意弹窗（阻止跳转，阻止任何数据收集）
   */
  private async checkPrivacyConsent(): Promise<void> {
    try {
      const accepted = await PreferencesUtil.get<boolean>(PRIVACY_ACCEPTED_KEY, false);
      if (accepted) {
        // 已同意隐私政策，正常启动
        this.startAnimation();
      } else {
        // 未同意，先显示 Logo 再弹出隐私政策
        animateTo({ duration: 500, curve: Curve.EaseOut }, () => {
          this.logoOpacity = 1;
          this.logoScale = 1;
        });
        setTimeout(() => {
          this.showPrivacyConsent = true;
          animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
            this.privacyDialogOpacity = 1;
          });
        }, 600);
      }
    } catch (err) {
      console.error('Index: 检查隐私政策状态失败', err);
      // 出错时也显示弹窗（安全起见）
      this.showPrivacyConsent = true;
      this.privacyDialogOpacity = 1;
    }
  }

  /**
   * 用户同意隐私政策
   */
  private async onPrivacyAccepted(): Promise<void> {
    try {
      await PreferencesUtil.put(PRIVACY_ACCEPTED_KEY, true);
    } catch (err) {
      console.error('Index: 保存隐私政策同意状态失败', err);
    }
    // 关闭弹窗，进入主页面
    animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      this.privacyDialogOpacity = 0;
    });
    setTimeout(() => {
      this.showPrivacyConsent = false;
      this.proceedToMain();
    }, 250);
  }

  /**
   * 用户拒绝隐私政策 → 退出应用
   */
  private onPrivacyDeclined(): void {
    const context = getContext(this) as common.UIAbilityContext;
    context.terminateSelf();
  }

  /**
   * 同意后快速过渡并跳转到主页面
   */
  private proceedToMain(): void {
    animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
      this.contentOpacity = 1;
      this.bottomOpacity = 1;
    });
    setTimeout(() => {
      this.isLoading = false;
      try {
        router.replaceUrl({ url: 'pages/PcListPageV2' });
      } catch (e) {
        console.error('Index: navigation failed - ' + e);
      }
    }, 800);
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
    Stack() {
      // ── 原有的启动页内容 ──
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

      // ── 隐私政策同意弹窗（首次启动时覆盖在启动页上方） ──
      if (this.showPrivacyConsent) {
        Column() {
          // 半透明遮罩
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .opacity(this.privacyDialogOpacity)

        Column() {
          // 标题
          Column({ space: 4 }) {
            Text('用户协议与隐私政策')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.TextPrimary)

            Text('请仔细阅读以下内容')
              .fontSize(13)
              .fontColor(AppColors.TextTertiary)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 24, bottom: 12, left: 20, right: 20 })

          // 概述
          Text('欢迎使用 Moonlight V+！在您使用本应用之前，请仔细阅读并了解我们的隐私政策：')
            .fontSize(14)
            .fontColor(AppColors.TextSecondary)
            .padding({ left: 20, right: 20, bottom: 8 })
            .width('100%')

          // 可滚动的隐私政策内容
          Scroll() {
            Column({ space: 12 }) {
              ForEach(this.privacySections, (section: PrivacySection) => {
                Column({ space: 6 }) {
                  Text(section.title)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppColors.TextPrimary)
                    .width('100%')

                  Text(section.content)
                    .fontSize(13)
                    .fontColor(AppColors.TextSecondary)
                    .width('100%')
                    .lineHeight(20)
                }
                .width('100%')
                .padding(12)
                .backgroundColor(AppColors.CardBackground)
                .borderRadius(8)
              })

              // 底部补充说明
              Text('完整隐私政策请查看项目仓库中的 PRIVACY_POLICY.md')
                .fontSize(12)
                .fontColor(AppColors.TextTertiary)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 4, bottom: 8 })
            }
            .padding({ left: 20, right: 20 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)

          // 按钮区域
          Column({ space: 10 }) {
            Button('同意并继续')
              .width('100%')
              .height(44)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .backgroundColor(AppColors.Primary)
              .borderRadius(22)
              .onClick(() => {
                this.onPrivacyAccepted();
              })

            Button('不同意')
              .width('100%')
              .height(44)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColors.TextSecondary)
              .backgroundColor(Color.Transparent)
              .border({ width: 1, color: AppColors.Divider, style: BorderStyle.Solid })
              .borderRadius(22)
              .onClick(() => {
                this.onPrivacyDeclined();
              })
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 12, bottom: 24 })
        }
        .width('88%')
        .height('75%')
        .backgroundColor(AppColors.Background)
        .borderRadius(20)
        .shadow({
          radius: 24,
          color: '#40000000',
          offsetX: 0,
          offsetY: 8
        })
        .opacity(this.privacyDialogOpacity)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.Background)
  }
}
