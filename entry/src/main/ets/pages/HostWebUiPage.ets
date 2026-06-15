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
import { common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { ComputerInfo } from '../model/ComputerInfo';
import { ComputerManager } from '../service/ComputerManager';
import { AppColors, AppSizes, AppSpacing, AppShadows } from '../common/Theme';
import { buildHostWebUiUrl } from '../utils/HostWebUiUtil';
import { ToastQueue } from '../utils/ToastQueue';

interface HostWebUiPageParams {
  computerId: string;
}

@Entry
@Component
struct HostWebUiPage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 56;
  @State computerName: string = 'Host WebUI';
  @State webUiUrl: string = '';
  @State isLoading: boolean = true;
  @State loadError: string = '';
  @State acceptedSslError: boolean = false;
  @State showAuthDialog: boolean = false;
  @State authHost: string = '';
  @State authRealm: string = '';
  @State authUserName: string = '';
  @State authPassword: string = '';

  private controller: webview.WebviewController = new webview.WebviewController();
  private computerManager: ComputerManager = ComputerManager.getInstance();
  private authHandler: HttpAuthHandler | null = null;

  aboutToAppear(): void {
    this.loadHost();
  }

  onBackPress(): boolean {
    if (this.safeCanGoBack()) {
      this.controller.backward();
      return true;
    }
    return false;
  }

  private async loadHost(): Promise<void> {
    const params = router.getParams() as HostWebUiPageParams;
    if (!params?.computerId) {
      this.isLoading = false;
      this.loadError = '缺少主机信息';
      return;
    }

    const computer = await this.findComputer(params.computerId);
    if (!computer) {
      this.isLoading = false;
      this.loadError = '找不到这台主机';
      return;
    }

    this.computerName = computer.name;
    this.webUiUrl = buildHostWebUiUrl(computer);
    if (!this.webUiUrl) {
      this.isLoading = false;
      this.loadError = '没有可用的主机地址';
    }
  }

  private async findComputer(computerId: string): Promise<ComputerInfo | null> {
    try {
      const computers = await this.computerManager.getComputers();
      return computers.find((item: ComputerInfo) => item.uuid === computerId) || null;
    } catch (_e) {
      return null;
    }
  }

  private safeCanGoBack(): boolean {
    try {
      return this.controller.accessBackward();
    } catch (_e) {
      return false;
    }
  }

  private reload(): void {
    this.isLoading = true;
    this.loadError = '';
    this.acceptedSslError = false;
    this.authHandler = null;
    this.showAuthDialog = false;
    try {
      this.controller.refresh();
    } catch (_e) {
      if (this.webUiUrl) {
        this.controller.loadUrl(this.webUiUrl);
      }
    }
  }

  private copyUrl(): void {
    if (!this.webUiUrl) {
      return;
    }
    const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.webUiUrl);
    pasteboard.getSystemPasteboard().setDataSync(pasteData);
    ToastQueue.show({ message: 'WebUI 地址已复制' });
  }

  private async openInBrowser(): Promise<void> {
    if (!this.webUiUrl) {
      return;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const want: Want = { action: 'ohos.want.action.viewData', uri: this.webUiUrl };
      await context.startAbility(want);
    } catch (_e) {
      ToastQueue.show({ message: '无法打开外部浏览器' });
    }
  }

  private requestHttpAuth(event: OnHttpAuthRequestEvent): boolean {
    this.authHandler = event.handler;
    this.authHost = event.host;
    this.authRealm = event.realm;
    this.loadError = '';
    this.isLoading = false;
    this.showAuthDialog = true;
    return true;
  }

  private submitHttpAuth(): void {
    if (!this.authHandler) {
      this.showAuthDialog = false;
      return;
    }
    const confirmed = this.authHandler.confirm(this.authUserName, this.authPassword);
    this.authHandler = null;
    this.showAuthDialog = false;
    if (!confirmed) {
      ToastQueue.show({ message: 'WebUI 登录失败' });
    } else {
      this.isLoading = true;
      this.loadError = '';
    }
  }

  private cancelHttpAuth(): void {
    if (this.authHandler) {
      this.authHandler.cancel();
      this.authHandler = null;
    }
    this.showAuthDialog = false;
    this.loadError = '需要 Sunshine WebUI 用户名和密码';
  }

  build() {
    Column() {
      this.NavBar()

      if (this.webUiUrl) {
        Stack() {
          Web({ src: this.webUiUrl, controller: this.controller })
            .width('100%')
            .height('100%')
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .mixedMode(MixedMode.None)
            .zoomAccess(true)
            .onPageBegin(() => {
              this.isLoading = true;
              this.loadError = '';
            })
            .onPageEnd(() => {
              this.isLoading = false;
            })
            .onSslErrorEventReceive((event) => {
              this.acceptedSslError = true;
              this.loadError = '';
              event.handler.handleConfirm();
            })
            .onHttpAuthRequest((event) => this.requestHttpAuth(event))
            .onErrorReceive((event) => {
              if (event?.request && !event.request.isMainFrame()) {
                return;
              }
              this.isLoading = false;
              const errorInfo = event?.error;
              const description = errorInfo?.getErrorInfo ? errorInfo.getErrorInfo() : '';
              this.loadError = description || 'WebUI 加载失败';
            })

          if (this.isLoading) {
            this.LoadingOverlay()
          }

          if (this.loadError) {
            this.ErrorPanel()
          }
        }
        .layoutWeight(1)
        .backgroundColor(AppColors.Background)
      } else {
        this.EmptyState()
      }

      if (this.showAuthDialog) {
        HostWebUiAuthDialog({
          host: this.authHost,
          realm: this.authRealm,
          userName: this.authUserName,
          password: this.authPassword,
          onUserNameChange: (value: string) => {
            this.authUserName = value;
          },
          onPasswordChange: (value: string) => {
            this.authPassword = value;
          },
          onConfirm: () => this.submitHttpAuth(),
          onCancel: () => this.cancelHttpAuth()
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.Background)
  }

  @Builder
  private NavBar() {
    Row() {
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ic_back'))
          .width(20)
          .height(20)
          .fillColor(AppColors.TextPrimary)
      }
      .width(36)
      .height(36)
      .backgroundColor(AppColors.CardBackground)
      .shadow(AppShadows.Small)
      .onClick(() => router.back())

      Column() {
        Text(this.computerName)
          .fontSize(AppSizes.FontTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.TextPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.webUiUrl) {
          Text(this.webUiUrl)
            .fontSize(AppSizes.FontCaption)
            .fontColor(AppColors.TextSecondary)
            .fontFamily('monospace')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: AppSpacing.Medium, right: AppSpacing.Medium })

      this.IconButton($r('app.media.ic_copy'), () => this.copyUrl())
      this.IconButton($r('app.media.ic_refresh'), () => this.reload())
      this.IconButton($r('app.media.ic_arrow_right'), () => this.openInBrowser())
    }
    .width('100%')
    .height(64)
    .padding({ left: AppSpacing.Large, right: AppSpacing.Large })
    .margin({ top: this.topSafeHeight - 12 })
    .backgroundColor(AppColors.Background)
  }

  @Builder
  private IconButton(icon: Resource, onClick: () => void) {
    Button({ type: ButtonType.Circle }) {
      Image(icon)
        .width(18)
        .height(18)
        .fillColor(AppColors.TextPrimary)
    }
    .width(36)
    .height(36)
    .margin({ left: AppSpacing.Small })
    .backgroundColor(AppColors.CardBackground)
    .shadow(AppShadows.Small)
    .onClick(onClick)
  }

  @Builder
  private LoadingOverlay() {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color(AppColors.Primary)
      Text('正在打开 WebUI...')
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .margin({ top: AppSpacing.Medium })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(AppColors.Background)
  }

  @Builder
  private ErrorPanel() {
    Column() {
      Image($r('app.media.ic_host'))
        .width(48)
        .height(48)
        .fillColor(AppColors.Warning)
        .margin({ bottom: AppSpacing.Medium })

      Text(this.loadError)
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextPrimary)
        .textAlign(TextAlign.Center)
        .margin({ bottom: AppSpacing.Medium })

      Text(this.webUiUrl)
        .fontSize(AppSizes.FontCaption)
        .fontColor(AppColors.TextSecondary)
        .fontFamily('monospace')
        .textAlign(TextAlign.Center)
        .margin({ bottom: AppSpacing.Large })

      Row() {
        Button('重试')
          .height(40)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextOnPrimary)
          .backgroundColor(AppColors.Primary)
          .borderRadius(AppSizes.RadiusMedium)
          .layoutWeight(1)
          .onClick(() => this.reload())

        Button('外部打开')
          .height(40)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextPrimary)
          .backgroundColor(AppColors.CardBackground)
          .borderRadius(AppSizes.RadiusMedium)
          .layoutWeight(1)
          .margin({ left: AppSpacing.Medium })
          .onClick(() => this.openInBrowser())
      }
      .width('100%')
    }
    .width('88%')
    .padding(AppSpacing.XLarge)
    .backgroundColor(AppColors.Surface)
    .borderRadius(AppSizes.RadiusXLarge)
    .shadow(AppShadows.Medium)
  }

  @Builder
  private EmptyState() {
    Column() {
      Text(this.loadError || '无法打开 WebUI')
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
}

@Component
struct HostWebUiAuthDialog {
  host: string = '';
  realm: string = '';
  userName: string = '';
  password: string = '';
  onUserNameChange: (value: string) => void = () => {};
  onPasswordChange: (value: string) => void = () => {};
  onConfirm: () => void = () => {};
  onCancel: () => void = () => {};

  build() {
    Stack() {
      Column() {
        Column() {
          Text('登录 Sunshine WebUI')
            .fontSize(AppSizes.FontTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.TextPrimary)
            .margin({ bottom: AppSpacing.Small })

          Text(this.realm || this.host)
            .fontSize(AppSizes.FontCaption)
            .fontColor(AppColors.TextSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ bottom: AppSpacing.Large })

          TextInput({ placeholder: '用户名', text: this.userName })
            .width('100%')
            .height(48)
            .fontSize(AppSizes.FontBody)
            .fontColor(AppColors.TextPrimary)
            .caretColor(AppColors.Primary)
            .placeholderColor(AppColors.TextTertiary)
            .backgroundColor(AppColors.Surface)
            .borderRadius(AppSizes.RadiusMedium)
            .padding({ left: AppSpacing.Medium, right: AppSpacing.Medium })
            .margin({ bottom: AppSpacing.Medium })
            .onChange((value: string) => this.onUserNameChange(value))

          TextInput({ placeholder: '密码', text: this.password })
            .type(InputType.Password)
            .width('100%')
            .height(48)
            .fontSize(AppSizes.FontBody)
            .fontColor(AppColors.TextPrimary)
            .caretColor(AppColors.Primary)
            .placeholderColor(AppColors.TextTertiary)
            .backgroundColor(AppColors.Surface)
            .borderRadius(AppSizes.RadiusMedium)
            .padding({ left: AppSpacing.Medium, right: AppSpacing.Medium })
            .margin({ bottom: AppSpacing.Large })
            .onChange((value: string) => this.onPasswordChange(value))
            .onSubmit(() => this.onConfirm())

          Row({ space: AppSpacing.Medium }) {
            Button('取消')
              .layoutWeight(1)
              .height(44)
              .fontSize(AppSizes.FontBody)
              .fontColor(AppColors.TextSecondary)
              .backgroundColor(AppColors.Surface)
              .borderRadius(AppSizes.RadiusMedium)
              .onClick(() => this.onCancel())

            Button('登录')
              .layoutWeight(1)
              .height(44)
              .fontSize(AppSizes.FontBody)
              .fontColor(AppColors.TextOnPrimary)
              .backgroundColor(AppColors.Primary)
              .borderRadius(AppSizes.RadiusMedium)
              .onClick(() => this.onConfirm())
          }
          .width('100%')
        }
        .width('88%')
        .padding(AppSpacing.XLarge)
        .backgroundColor(AppColors.Background)
        .borderRadius(AppSizes.RadiusXLarge)
        .shadow(AppShadows.Medium)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
  }
}
