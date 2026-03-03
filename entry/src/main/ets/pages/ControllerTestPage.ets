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
 * 手柄测试页面
 * 支持 USB 驱动、Game Controller Kit (蓝牙/系统) 和设备传感器三种测试模式
 */

import { router } from '@kit.ArkUI';
import { UsbControllerTestView } from '../components/UsbControllerTestView';
import { GameControllerTestView } from '../components/GameControllerTestView';
import { SensorTestView } from '../components/SensorTestView';
import { AppColors, AppSizes, AppSpacing } from '../common/Theme';
import { GamepadManager } from '../service/GamepadManager';

@Entry
@Component
struct ControllerTestPage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 56;  // 动态状态栏安全区高度
  @State currentTabIndex: number = 0;
  @State keyEventLogs: string[] = [];  // 按键事件日志
  
  // KeyEvent 处理器引用
  private gcKeyEventHandler: ((event: KeyEvent) => boolean) | null = null;
  
  /**
   * 页面销毁时恢复 GamepadManager 的完整回调链路。
   *
   * 子 Tab 的 aboutToDisappear 会在 Page 销毁前触发，但
   * UsbControllerTestView.stopDriver() 在释放设备后不再重启驱动
   * （避免切到 GCK Tab 时设备被立即重新独占）。
   * 因此当整个测试页面退出时，需要在此处完整恢复 GamepadManager。
   */
  aboutToDisappear(): void {
    try {
      GamepadManager.getInstance().reattachInputCallbacks();
      console.info('[ControllerTestPage] 页面销毁，已恢复 GamepadManager 回调');
    } catch (err) {
      console.error('[ControllerTestPage] 恢复 GamepadManager 回调失败:', err);
    }
  }
  
  /**
   * 处理所有按键事件
   */
  handleKeyEvent(event: KeyEvent): boolean {
    const timestamp = new Date().toLocaleTimeString();
    const keyCode = event.keyCode;
    const isPressed = event.type === KeyType.Down;
    
    // 记录日志
    const logEntry = `[${timestamp}] KeyEvent: code=${keyCode} ${isPressed ? 'DOWN' : 'UP'}`;
    this.keyEventLogs = [logEntry, ...this.keyEventLogs.slice(0, 19)];
    
    // 如果在 GC Kit 标签页，转发给 GameControllerTestView
    if (this.currentTabIndex === 1 && this.gcKeyEventHandler) {
      return this.gcKeyEventHandler(event);
    }
    
    // 返回 true 阻止系统默认行为
    return true;
  }
  
  build() {
    Column() {
      // 标题栏 — 与 SettingsPageV2 等页面风格统一
      Row() {
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
        .onClick(() => {
          router.back();
        })
        
        Column() {
          Text('手柄测试')
            .fontSize(AppSizes.FontTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.Primary)
          Text(this.currentTabIndex === 0 ? 'USB 驱动模式' : this.currentTabIndex === 1 ? 'Game Controller Kit 模式' : '设备传感器测试')
            .fontSize(AppSizes.FontCaption)
            .fontColor(AppColors.TextSecondary)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: AppSpacing.Medium })
        
        Blank()
        
        // 模式指示器
        Row({ space: 4 }) {
          Circle()
            .width(8)
            .height(8)
            .fill(this.currentTabIndex === 0 ? '#4CAF50' : this.currentTabIndex === 1 ? '#2196F3' : '#FF9800')
          Text(this.currentTabIndex === 0 ? 'USB' : this.currentTabIndex === 1 ? 'GC Kit' : '传感器')
            .fontSize(11)
            .fontColor(AppColors.TextSecondary)
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor(AppColors.SurfaceTransparent)
        .borderRadius(12)
      }
      .width('100%')
      .padding({
        left: AppSpacing.Large,
        right: AppSpacing.Large,
        top: this.topSafeHeight,
        bottom: AppSpacing.Medium
      })

      // 标签页切换
      Row({ space: 0 }) {
        this.TabButton('USB 驱动', '有线手柄', 0)
        this.TabButton('系统/蓝牙', 'GC Kit', 1)
        this.TabButton('传感器', '陀螺仪/加速度计', 2)
      }
      .width('100%')
      .padding({ left: AppSpacing.Large, right: AppSpacing.Large, top: AppSpacing.Small, bottom: AppSpacing.Small })
      .backgroundColor(AppColors.Surface)
      .border({ width: { bottom: 1 }, color: AppColors.Divider })

      // 内容区域
      if (this.currentTabIndex === 0) {
        UsbControllerTestView()
      } else if (this.currentTabIndex === 1) {
        GameControllerTestView({
          onKeyEventRef: (handler: (event: KeyEvent) => boolean) => {
            this.gcKeyEventHandler = handler;
          }
        })
      } else {
        SensorTestView()
      }
      
      // KeyEvent 日志显示区域
      if (this.keyEventLogs.length > 0) {
        Column() {
          Text('KeyEvent 日志 (直接按键)')
            .fontSize(AppSizes.FontCaption)
            .fontColor(AppColors.TextSecondary)
            .margin({ bottom: AppSpacing.XSmall })
          
          ForEach(this.keyEventLogs, (log: string) => {
            Text(log)
              .fontSize(11)
              .fontColor(AppColors.TextTertiary)
              .fontFamily('monospace')
          })
        }
        .width('100%')
        .padding(AppSpacing.Medium)
        .backgroundColor(AppColors.SurfaceTransparent)
        .borderRadius(AppSizes.RadiusMedium)
        .margin({ left: AppSpacing.Large, right: AppSpacing.Large, bottom: AppSpacing.Large })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.Background)
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      return this.handleKeyEvent(event);
    })
  }
  
  @Builder
  TabButton(title: string, subtitle: string, index: number) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(AppSizes.FontBody)
        .fontWeight(this.currentTabIndex === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.currentTabIndex === index ? AppColors.Primary : AppColors.TextSecondary)
      Text(subtitle)
        .fontSize(10)
        .fontColor(AppColors.TextTertiary)
    }
    .layoutWeight(1)
    .padding({ top: AppSpacing.Small, bottom: AppSpacing.Small })
    .backgroundColor(this.currentTabIndex === index ? AppColors.SurfaceTransparent : Color.Transparent)
    .borderRadius(AppSizes.RadiusMedium)
    .onClick(() => {
      this.currentTabIndex = index;
    })
  }
}
