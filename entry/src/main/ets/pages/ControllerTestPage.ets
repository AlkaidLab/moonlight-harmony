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
 * 支持 USB 驱动和 Game Controller Kit (蓝牙/系统) 两种模式
 */

import { router } from '@kit.ArkUI';
import { UsbControllerTestView } from '../components/UsbControllerTestView';
import { GameControllerTestView } from '../components/GameControllerTestView';
import { AppColors } from '../common/Theme';

@Entry
@Component
struct ControllerTestPage {
  @State currentTabIndex: number = 0;
  @State keyEventLogs: string[] = [];  // 按键事件日志
  
  // KeyEvent 处理器引用
  private gcKeyEventHandler: ((event: KeyEvent) => boolean) | null = null;
  
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
      // 标题栏
      Row() {
        Row() {
          Image($r('app.media.ic_back'))
            .width(20)
            .height(20)
            .fillColor(AppColors.TextPrimary)
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(AppColors.SurfaceTransparent)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          router.back();
        })
        
        Column({ space: 2 }) {
          Text('手柄测试')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.TextPrimary)
          Text(this.currentTabIndex === 0 ? 'USB 驱动模式' : 'Game Controller Kit 模式')
            .fontSize(12)
            .fontColor(AppColors.TextSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
        
        Blank()
        
        // 模式指示器
        Row({ space: 4 }) {
          Circle()
            .width(8)
            .height(8)
            .fill(this.currentTabIndex === 0 ? '#4CAF50' : '#2196F3')
          Text(this.currentTabIndex === 0 ? 'USB' : 'GC Kit')
            .fontSize(11)
            .fontColor(AppColors.TextSecondary)
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor(AppColors.SurfaceTransparent)
        .borderRadius(12)
      }
      .width('100%')
      .height(60)
      .padding({ left: 16, right: 16 })
      .backgroundColor(AppColors.Surface)

      // 标签页切换
      Row({ space: 0 }) {
        this.TabButton('USB 驱动', '有线手柄', 0)
        this.TabButton('系统/蓝牙', 'Game Controller Kit', 1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(AppColors.Surface)
      .border({ width: { bottom: 1 }, color: AppColors.Divider })

      // 内容区域
      if (this.currentTabIndex === 0) {
        UsbControllerTestView()
      } else {
        GameControllerTestView({
          onKeyEventRef: (handler: (event: KeyEvent) => boolean) => {
            this.gcKeyEventHandler = handler;
          }
        })
      }
      
      // KeyEvent 日志显示区域
      if (this.keyEventLogs.length > 0) {
        Column() {
          Text('KeyEvent 日志 (直接按键)')
            .fontSize(12)
            .fontColor(AppColors.TextSecondary)
            .margin({ bottom: 4 })
          
          ForEach(this.keyEventLogs, (log: string) => {
            Text(log)
              .fontSize(11)
              .fontColor(AppColors.TextTertiary)
              .fontFamily('monospace')
          })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(AppColors.SurfaceTransparent)
        .borderRadius(8)
        .margin({ left: 16, right: 16, bottom: 16 })
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
        .fontSize(14)
        .fontWeight(this.currentTabIndex === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.currentTabIndex === index ? AppColors.Primary : AppColors.TextSecondary)
      Text(subtitle)
        .fontSize(10)
        .fontColor(AppColors.TextTertiary)
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
    .backgroundColor(this.currentTabIndex === index ? AppColors.SurfaceTransparent : Color.Transparent)
    .borderRadius(8)
    .onClick(() => {
      this.currentTabIndex = index;
    })
  }
}
