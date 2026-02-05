/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { router, promptAction } from '@kit.ArkUI';
import { ComputerManager } from '../service/ComputerManager';
import { AppColors, AppSizes, AppSpacing, AppAnimation, AppShadows } from '../common/Theme';
import { common } from '@kit.AbilityKit';

/**
 * 地址解析结果
 */
class AddressPortResult {
  address: string = '';
  port: number | undefined = undefined;
}

/**
 * 添加电脑页面 (现代化版本)
 */
@Entry
@Component
struct AddPcPageV2 {
  @State ipAddress: string = '';
  @State isAdding: boolean = false;
  @State errorMessage: string = '';
  @State isValidInput: boolean = false;
  @State showSuccess: boolean = false;
  
  private computerManager: ComputerManager = ComputerManager.getInstance();

  build() {
    Column() {
      // 标题栏
      this.TitleBar()
      
      // 主内容
      Scroll() {
        Column() {
          // 说明卡片
          this.InstructionCard()
          
          // 输入区域
          this.InputSection()
          
          // 错误提示
          if (this.errorMessage) {
            this.ErrorMessage()
          }
          
          // 添加按钮
          this.AddButton()
          
          // 提示信息
          this.HelpInfo()
        }
        .width('100%')
        .padding({ left: AppSpacing.Large, right: AppSpacing.Large })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.Background)
  }

  @Builder
  TitleBar() {
    Row() {
      // 返回按钮 - 霓虹风格
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ic_back'))
          .width(AppSizes.IconMedium)
          .height(AppSizes.IconMedium)
          .fillColor(AppColors.Primary)
      }
      .width(40)
      .height(40)
      .backgroundColor(AppColors.Surface)
      .borderWidth(1)
      .borderColor(AppColors.CardBorder)
      .onClick(() => router.back())

      Column() {
        Text('添加电脑')
          .fontSize(AppSizes.FontTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.Primary)
        Text('手动输入 IP 地址')
          .fontSize(AppSizes.FontCaption)
          .fontColor(AppColors.TextSecondary)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: AppSpacing.Medium })

      Blank()
    }
    .width('100%')
    .padding({
      left: AppSpacing.Large,
      right: AppSpacing.Large,
      top: 56,
      bottom: AppSpacing.Large
    })
  }

  @Builder
  InstructionCard() {
    Column() {
      Row() {
        // 图标 - 霓虹发光
        Column() {
          Text('🌐')
            .fontSize(24)
        }
        .width(48)
        .height(48)
        .borderRadius(14)
        .backgroundColor(AppColors.Surface)
        .borderWidth(2)
        .borderColor(AppColors.Accent)
        .justifyContent(FlexAlign.Center)
        .shadow(AppShadows.GlowCyan)

        Column() {
          Text('连接到主机')
            .fontSize(AppSizes.FontSubtitle)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.Accent)

          Text('输入运行 Sunshine 或 GeForce Experience 的电脑 IP 地址')
            .fontSize(AppSizes.FontCaption)
            .fontColor(AppColors.TextSecondary)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: AppSpacing.Medium })
        .layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%')
    .padding(AppSpacing.Large)
    .backgroundColor(AppColors.CardBackground)
    .borderRadius(AppSizes.RadiusLarge)
    .borderWidth(1)
    .borderColor(AppColors.CardBorder)
    .margin({ top: AppSpacing.Large })
  }

  @Builder
  InputSection() {
    Column() {
      Text('IP 地址或主机名')
        .fontSize(AppSizes.FontCaption)
        .fontColor(AppColors.Primary)
        .fontWeight(FontWeight.Medium)
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: AppSpacing.Small })

      Row() {
        Image($r('app.media.ic_computer'))
          .width(20)
          .height(20)
          .fillColor(this.ipAddress ? AppColors.Primary : AppColors.TextTertiary)
          .margin({ right: AppSpacing.Medium })

        TextInput({ placeholder: '例如: 192.168.1.100 或 192.168.1.100:47989', text: this.ipAddress })
          .layoutWeight(1)
          .height(48)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextPrimary)
          .caretColor(AppColors.Primary)
          .placeholderColor(AppColors.TextTertiary)
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            this.ipAddress = value;
            this.validateInput();
            this.errorMessage = '';
          })
          .onSubmit(() => {
            if (this.isValidInput) {
              this.addComputer();
            }
          })

        if (this.ipAddress.length > 0) {
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.ic_error'))
              .width(16)
              .height(16)
              .fillColor(AppColors.TextSecondary)
          }
          .width(28)
          .height(28)
          .backgroundColor(AppColors.Surface)
          .onClick(() => {
            this.ipAddress = '';
            this.isValidInput = false;
            this.errorMessage = '';
          })
        }
      }
      .width('100%')
      .height(56)
      .padding({ left: AppSpacing.Medium, right: AppSpacing.Small })
      .backgroundColor(AppColors.Surface)
      .borderRadius(AppSizes.RadiusLarge)
      .border({
        width: 1.5,
        color: this.errorMessage ? AppColors.Error :
               (this.ipAddress ? AppColors.Primary : AppColors.CardBorder)
      })
    }
    .width('100%')
    .margin({ top: AppSpacing.XLarge })
  }

  @Builder
  ErrorMessage() {
    Row() {
      Image($r('app.media.ic_error'))
        .width(16)
        .height(16)
        .fillColor(AppColors.Error)
        .margin({ right: AppSpacing.Small })

      Text(this.errorMessage)
        .fontSize(AppSizes.FontCaption)
        .fontColor(AppColors.Error)
    }
    .width('100%')
    .padding({ left: AppSpacing.Small, right: AppSpacing.Small, top: AppSpacing.Small, bottom: AppSpacing.Small })
    .backgroundColor(AppColors.Error + '15')
    .borderRadius(AppSizes.RadiusMedium)
    .margin({ top: AppSpacing.Small })
    .transition(TransitionEffect.OPACITY.animation({ duration: AppAnimation.Fast }))
  }

  @Builder
  AddButton() {
    Button({ type: ButtonType.Normal }) {
      Row() {
        if (this.isAdding) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(AppColors.TextOnPrimary)
            .margin({ right: AppSpacing.Small })
        }
        Text(this.isAdding ? '正在连接...' : '添加电脑')
          .fontSize(AppSizes.FontSubtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColors.TextOnPrimary)
      }
    }
    .width('100%')
    .height(52)
    .borderRadius(AppSizes.RadiusLarge)
    .backgroundColor(this.isValidInput && !this.isAdding ? AppColors.Primary : AppColors.TextTertiary)
    .shadow(this.isValidInput && !this.isAdding ? AppShadows.GlowGreen : AppShadows.Small)
    .enabled(this.isValidInput && !this.isAdding)
    .margin({ top: AppSpacing.XLarge })
    .onClick(() => this.addComputer())
  }

  @Builder
  HelpInfo() {
    Column() {
      Text('提示')
        .fontSize(AppSizes.FontCaption)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColors.TextSecondary)
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: AppSpacing.Medium })
      
      this.HelpItem('确保电脑和手机在同一网络')
      this.HelpItem('确保 Sunshine 或 GFE 正在运行')
      this.HelpItem('检查防火墙是否允许连接')
      this.HelpItem('支持 IPv4 和 IPv6 地址')
      this.HelpItem('支持自定义端口，如 192.168.1.100:47989')
      this.HelpItem('IPv6 自定义端口格式: [::1]:47989')
    }
    .width('100%')
    .padding(AppSpacing.Large)
    .backgroundColor(AppColors.Surface)
    .borderRadius(AppSizes.RadiusLarge)
    .margin({ top: AppSpacing.XXLarge })
  }

  @Builder
  HelpItem(text: string) {
    Row() {
      Circle()
        .width(6)
        .height(6)
        .fill(AppColors.TextTertiary)
        .margin({ right: AppSpacing.Medium })
      
      Text(text)
        .fontSize(AppSizes.FontCaption)
        .fontColor(AppColors.TextSecondary)
    }
    .width('100%')
    .margin({ bottom: AppSpacing.Small })
  }

  private validateInput(): void {
    const value = this.ipAddress.trim();
    
    if (!value) {
      this.isValidInput = false;
      return;
    }
    
    // 分离地址和端口
    const parseResult = this.parseAddressAndPort(value);
    if (!parseResult) {
      this.isValidInput = false;
      return;
    }
    
    const address = parseResult.address;
    const port = parseResult.port;
    
    // 验证端口（如果存在）
    if (port !== undefined && (port <= 0 || port > 65535)) {
      this.isValidInput = false;
      return;
    }
    
    // IPv4 格式
    const ipv4Regex = /^(\d{1,3}\.){3}\d{1,3}$/;
    if (ipv4Regex.test(address)) {
      const parts = address.split('.');
      this.isValidInput = parts.every(part => {
        const num = parseInt(part);
        return num >= 0 && num <= 255;
      });
      return;
    }
    
    // IPv6 格式 (简化检测)
    if (address.includes(':')) {
      this.isValidInput = true;
      return;
    }
    
    // 主机名格式
    const hostnameRegex = /^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$/;
    this.isValidInput = hostnameRegex.test(address);
  }

  /**
   * 解析地址和端口
   * 支持格式：
   *   - "192.168.1.100" -> { address: "192.168.1.100" }
   *   - "192.168.1.100:47989" -> { address: "192.168.1.100", port: 47989 }
   *   - "[::1]" -> { address: "::1" }
   *   - "[::1]:47989" -> { address: "::1", port: 47989 }
   *   - "::1" -> { address: "::1" }
   */
  private parseAddressAndPort(input: string): AddressPortResult | null {
    // 检查是否为 IPv6 地址（包含多个冒号）
    let colonCount = 0;
    for (let i = 0; i < input.length; i++) {
      if (input.charAt(i) === ':') {
        colonCount++;
      }
    }
    const isLikelyIPv6 = colonCount >= 2;
    const result = new AddressPortResult();
    
    if (isLikelyIPv6) {
      if (input.startsWith('[')) {
        // 格式: [::1] 或 [::1]:47989
        const closeBracket = input.indexOf(']');
        if (closeBracket > 0) {
          result.address = input.substring(1, closeBracket);
          if (closeBracket < input.length - 1 && input.charAt(closeBracket + 1) === ':') {
            const portStr = input.substring(closeBracket + 2);
            const port = parseInt(portStr);
            if (!isNaN(port)) {
              result.port = port;
              return result;
            }
            return null; // 无效端口
          }
          return result;
        }
        return null; // 无效格式
      } else {
        // 纯 IPv6 地址，不尝试解析端口（太复杂）
        result.address = input;
        return result;
      }
    } else {
      // IPv4 或主机名
      const colonIndex = input.indexOf(':');
      if (colonIndex > 0) {
        // 格式: 192.168.1.100:47989
        result.address = input.substring(0, colonIndex);
        const portStr = input.substring(colonIndex + 1);
        const port = parseInt(portStr);
        if (!isNaN(port)) {
          result.port = port;
          return result;
        }
        return null; // 无效端口
      }
      result.address = input;
      return result;
    }
  }

  private async addComputer(): Promise<void> {
    if (!this.isValidInput || this.isAdding) {
      return;
    }
    
    this.isAdding = true;
    this.errorMessage = '';
    
    try {
      const result = await this.computerManager.addComputer(this.ipAddress.trim());
      
      if (result) {
        // 成功动画
        animateTo({ duration: AppAnimation.Normal }, () => {
          this.showSuccess = true;
        });
        
        promptAction.showToast({ message: '添加成功' });
        
        // 延迟返回
        setTimeout(() => {
          router.back();
        }, 500);
      } else {
        this.errorMessage = '无法连接到主机，请检查地址是否正确';
      }
    } catch (err) {
      this.errorMessage = (err as Error).message || '连接失败';
    } finally {
      this.isAdding = false;
    }
  }
}
