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
 * USB 手柄测试视图
 * 用于测试 USB 手柄驱动是否正常工作
 */

import { usbManager } from '@kit.BasicServicesKit';
import { UsbDriverService, UsbDriverListener, ControllerType, AbstractController, ButtonFlags } from '../service/usbdriver';
import { AppColors } from '../common/Theme';

// 手柄状态类
class ControllerInputState {
  buttons: number = 0;
  leftStickX: number = 0;
  leftStickY: number = 0;
  rightStickX: number = 0;
  rightStickY: number = 0;
  leftTrigger: number = 0;
  rightTrigger: number = 0;
}

// 设备信息类
class DeviceInfo {
  name: string = '';
  vid: number = 0;
  pid: number = 0;
  type: number = 0;
}

// USB 驱动监听器实现类
class TestViewDriverListener implements UsbDriverListener {
  private view: UsbControllerTestView;
  
  constructor(view: UsbControllerTestView) {
    this.view = view;
  }
  
  reportControllerState(controllerId: number, buttonFlags: number,
    leftStickX: number, leftStickY: number,
    rightStickX: number, rightStickY: number,
    leftTrigger: number, rightTrigger: number): void {
    
    this.view.incrementPollCount();
    
    const state = new ControllerInputState();
    state.buttons = buttonFlags;
    state.leftStickX = Math.max(-32767, Math.min(32767, Math.round(leftStickX * 32767)));
    state.leftStickY = Math.max(-32767, Math.min(32767, Math.round(leftStickY * 32767)));
    state.rightStickX = Math.max(-32767, Math.min(32767, Math.round(rightStickX * 32767)));
    state.rightStickY = Math.max(-32767, Math.min(32767, Math.round(rightStickY * 32767)));
    state.leftTrigger = leftTrigger;
    state.rightTrigger = rightTrigger;
    
    this.view.updateInputState(state);
  }

  reportControllerMotion(controllerId: number, motionType: number,
    x: number, y: number, z: number): void {
  }

  deviceAdded(controller: AbstractController): void {
    this.view.onDeviceAdded(controller);
  }

  deviceRemoved(controller: AbstractController): void {
    this.view.onDeviceRemoved(controller);
  }
}

@Component
export struct UsbControllerTestView {
  @State isRunning: boolean = false;
  @State deviceCount: number = 0;
  @State connectedDevices: DeviceInfo[] = [];
  @State lastInputState: ControllerInputState | null = null;
  @State logMessages: string[] = [];
  @State pollRate: number = 0;
  @State pollCount: number = 0;

  private usbDriverService: UsbDriverService | null = null;
  private listener: TestViewDriverListener | null = null;
  private pollCountInternal: number = 0;
  private lastPollStatTime: number = 0;
  private pollRateTimer: number = -1;

  aboutToAppear(): void {
    this.addLog('USB 手柄测试视图初始化');
    this.checkUsbDevices();
    this.startPollRateTimer();
  }

  aboutToDisappear(): void {
    this.stopPollRateTimer();
    this.stopDriver();
  }
  
  private startPollRateTimer(): void {
    this.lastPollStatTime = Date.now();
    this.pollCountInternal = 0;
    
    this.pollRateTimer = setInterval(() => {
      const now = Date.now();
      const elapsed = (now - this.lastPollStatTime) / 1000;
      
      if (elapsed > 0) {
        this.pollRate = Math.round(this.pollCountInternal / elapsed);
        this.pollCount = this.pollCountInternal;
      }
      
      this.pollCountInternal = 0;
      this.lastPollStatTime = now;
    }, 1000);
  }
  
  private stopPollRateTimer(): void {
    if (this.pollRateTimer !== -1) {
      clearInterval(this.pollRateTimer);
      this.pollRateTimer = -1;
    }
  }
  
  incrementPollCount(): void {
    this.pollCountInternal++;
  }

  addLog(message: string): void {
    const timestamp: string = new Date().toLocaleTimeString();
    this.logMessages = [`[${timestamp}] ${message}`, ...this.logMessages.slice(0, 49)];
  }
  
  updateInputState(state: ControllerInputState): void {
    this.lastInputState = state;
  }
  
  onDeviceAdded(controller: AbstractController): void {
    this.addLog(`设备已连接: ${controller.getName()}`);
    const deviceInfo = new DeviceInfo();
    deviceInfo.name = controller.getName();
    deviceInfo.vid = controller.getVendorId();
    deviceInfo.pid = controller.getProductId();
    deviceInfo.type = controller.getControllerType();
    this.connectedDevices = [...this.connectedDevices, deviceInfo];
  }
  
  onDeviceRemoved(controller: AbstractController): void {
    this.addLog(`设备已断开: ${controller.getName()}`);
    this.connectedDevices = [];
  }

  private checkUsbDevices(): void {
    try {
      const devices: usbManager.USBDevice[] = usbManager.getDevices();
      this.deviceCount = devices.length;
      this.addLog(`发现 ${devices.length} 个 USB 设备`);

      for (let i: number = 0; i < devices.length; i++) {
        const device: usbManager.USBDevice = devices[i];
        this.addLog(`设备 ${i + 1}: VID=0x${device.vendorId.toString(16).toUpperCase()}, PID=0x${device.productId.toString(16).toUpperCase()}`);
      }
    } catch (err) {
      this.addLog(`检查设备失败: ${err}`);
    }
  }

  private startDriver(): void {
    if (this.usbDriverService !== null) {
      return;
    }

    this.listener = new TestViewDriverListener(this);
    this.usbDriverService = UsbDriverService.getInstance();
    this.usbDriverService.setListener(this.listener);
    this.usbDriverService.start();
    this.isRunning = true;
    this.addLog('USB 驱动服务已启动');
  }

  private stopDriver(): void {
    if (this.usbDriverService !== null) {
      this.usbDriverService.stop();
      this.usbDriverService = null;
      this.listener = null;
      this.isRunning = false;
      this.connectedDevices = [];
      this.lastInputState = null;
      this.addLog('USB 驱动服务已停止');
    }
  }

  private getControllerTypeName(type: number): string {
    if (type === ControllerType.XBOX) {
      return 'Xbox';
    } else if (type === ControllerType.PS) {
      return 'PlayStation';
    } else if (type === ControllerType.NINTENDO) {
      return 'Nintendo';
    } else {
      return 'Generic';
    }
  }
  
  private getControllerTypeIcon(type: number): string {
    if (type === ControllerType.XBOX) {
      return '🎮';
    } else if (type === ControllerType.PS) {
      return '🎮';
    } else if (type === ControllerType.NINTENDO) {
      return '🕹️';
    } else {
      return '🎮';
    }
  }
  
  private getPollRateColor(): ResourceColor {
    if (this.pollRate >= 250) {
      return AppColors.Success;
    } else if (this.pollRate >= 100) {
      return AppColors.Primary;
    } else if (this.pollRate >= 60) {
      return AppColors.Warning;
    } else {
      return AppColors.Error;
    }
  }
  
  private getPollRateDesc(): string {
    if (this.pollRate >= 500) {
      return '专业级响应';
    } else if (this.pollRate >= 250) {
      return '流畅游戏';
    } else if (this.pollRate >= 125) {
      return '标准响应';
    } else if (this.pollRate >= 60) {
      return '可能有延迟';
    } else if (this.pollRate > 0) {
      return '响应较慢';
    } else {
      return '等待数据';
    }
  }

  private formatStickValue(value: number): string {
    const percent = Math.round((value / 32767) * 100);
    if (percent > 0) {
      return `+${percent}%`;
    }
    return `${percent}%`;
  }
  
  private formatTriggerValue(value: number): string {
    return `${Math.round(value * 100)}%`;
  }

  private isButtonPressed(buttons: number, flag: number): boolean {
    return (buttons & flag) !== 0;
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        // 控制按钮区
        Row({ space: 12 }) {
          Button(this.isRunning ? '停止驱动' : '启动驱动')
            .onClick(() => {
              if (this.isRunning) {
                this.stopDriver();
              } else {
                this.startDriver();
              }
            })
            .backgroundColor(this.isRunning ? AppColors.Error : AppColors.Success)
            .fontColor(AppColors.TextOnPrimary)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .height(40)
            .padding({ left: 20, right: 20 })
            .borderRadius(20)

          Button('刷新设备')
            .onClick(() => {
              this.checkUsbDevices();
            })
            .backgroundColor(AppColors.Primary)
            .fontColor(AppColors.TextOnPrimary)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .height(40)
            .padding({ left: 20, right: 20 })
            .borderRadius(20)
        }

        // 设备状态卡片
        Column({ space: 12 }) {
          Row() {
            Text('🎮')
              .fontSize(20)
            Text('设备状态')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.TextPrimary)
              .margin({ left: 8 })
            Blank()
            // 设备数量徽章
            Text(`${this.deviceCount}`)
              .fontSize(12)
              .fontColor(AppColors.TextOnPrimary)
              .backgroundColor(AppColors.Primary)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(10)
          }
          .width('100%')
          
          Row({ space: 16 }) {
            Column({ space: 4 }) {
              Text('USB 设备')
                .fontSize(12)
                .fontColor(AppColors.TextSecondary)
              Text(`${this.deviceCount}`)
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColors.TextPrimary)
            }
            .alignItems(HorizontalAlign.Center)
            
            Divider()
              .vertical(true)
              .height(40)
              .color(AppColors.Divider)
            
            Column({ space: 4 }) {
              Text('已连接手柄')
                .fontSize(12)
                .fontColor(AppColors.TextSecondary)
              Text(`${this.connectedDevices.length}`)
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.connectedDevices.length > 0 ? AppColors.Success : AppColors.TextTertiary)
            }
            .alignItems(HorizontalAlign.Center)
            
            if (this.connectedDevices.length > 0) {
              Divider()
                .vertical(true)
                .height(40)
                .color(AppColors.Divider)
              
              Column({ space: 4 }) {
                Text('轮询率')
                  .fontSize(12)
                  .fontColor(AppColors.TextSecondary)
                Row() {
                  Text(`${this.pollRate}`)
                    .fontSize(24)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.getPollRateColor())
                  Text(' Hz')
                    .fontSize(14)
                    .fontColor(AppColors.TextSecondary)
                }
              }
              .alignItems(HorizontalAlign.Center)
            }
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceEvenly)

          // 已连接设备列表
          if (this.connectedDevices.length > 0) {
            Divider().color(AppColors.Divider)
            
            ForEach(this.connectedDevices, (device: DeviceInfo) => {
              Row({ space: 8 }) {
                Text(this.getControllerTypeIcon(device.type))
                  .fontSize(24)
                Column({ space: 2 }) {
                  Text(device.name)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppColors.TextPrimary)
                  Text(`${this.getControllerTypeName(device.type)} · VID:0x${device.vid.toString(16).toUpperCase()} PID:0x${device.pid.toString(16).toUpperCase()}`)
                    .fontSize(11)
                    .fontColor(AppColors.TextTertiary)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                
                Text(this.getPollRateDesc())
                  .fontSize(11)
                  .fontColor(this.getPollRateColor())
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .backgroundColor(AppColors.SurfaceDark)
                  .borderRadius(4)
              }
              .width('100%')
              .padding(8)
              .backgroundColor(AppColors.SurfaceTransparent)
              .borderRadius(8)
            })
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(AppColors.CardBackground)
        .borderRadius(12)
        .border({ width: 1, color: AppColors.CardBorder })

        // 输入状态卡片 - 手柄形状可视化
        if (this.lastInputState !== null) {
          Column({ space: 12 }) {
            Row() {
              Text('🕹️')
                .fontSize(20)
              Text('输入状态')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColors.TextPrimary)
                .margin({ left: 8 })
            }
            .width('100%')

            // 手柄可视化面板
            Column() {
              // 顶部：扳机和肩键
              Row() {
                // 左扳机 LT
                Column({ space: 2 }) {
                  Text('LT')
                    .fontSize(10)
                    .fontColor(AppColors.TextSecondary)
                  this.TriggerBar(this.lastInputState!.leftTrigger, true)
                }
                // 左肩键 LB
                this.ShoulderButton('LB', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.LB_FLAG))
                
                Blank()
                
                // 右肩键 RB
                this.ShoulderButton('RB', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.RB_FLAG))
                // 右扳机 RT
                Column({ space: 2 }) {
                  Text('RT')
                    .fontSize(10)
                    .fontColor(AppColors.TextSecondary)
                  this.TriggerBar(this.lastInputState!.rightTrigger, false)
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
              
              // 主体部分：手柄轮廓
              Row() {
                // 左半部分：D-Pad + 左摇杆
                Column({ space: 16 }) {
                  // 左摇杆
                  Column({ space: 4 }) {
                    this.StickVisualizer(this.lastInputState!.leftStickX, this.lastInputState!.leftStickY, false)
                    Row() {
                      Text('L3')
                        .fontSize(9)
                        .fontColor(this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.LS_CLK_FLAG) ? 
                          AppColors.Primary : AppColors.TextTertiary)
                        .fontWeight(this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.LS_CLK_FLAG) ? 
                          FontWeight.Bold : FontWeight.Normal)
                    }
                  }
                  
                  // D-Pad
                  this.DPadVisualizer()
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
                
                // 中间部分：功能键
                Column({ space: 12 }) {
                  // Back / Start
                  Row({ space: 16 }) {
                    this.FunctionButton('⏪', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.BACK_FLAG))
                    this.FunctionButton('🏠', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.SPECIAL_BUTTON_FLAG))
                    this.FunctionButton('⏯', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.PLAY_FLAG))
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
                .justifyContent(FlexAlign.Center)
                
                // 右半部分：ABXY + 右摇杆
                Column({ space: 16 }) {
                  // ABXY 按钮（菱形布局）
                  this.ABXYVisualizer()
                  
                  // 右摇杆
                  Column({ space: 4 }) {
                    this.StickVisualizer(this.lastInputState!.rightStickX, this.lastInputState!.rightStickY, true)
                    Row() {
                      Text('R3')
                        .fontSize(9)
                        .fontColor(this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.RS_CLK_FLAG) ? 
                          AppColors.Error : AppColors.TextTertiary)
                        .fontWeight(this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.RS_CLK_FLAG) ? 
                          FontWeight.Bold : FontWeight.Normal)
                    }
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
              }
              .width('100%')
              .padding(16)
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .backgroundColor(AppColors.SurfaceTransparent)
            .borderRadius(16)
            
            // 底部数值显示
            Row({ space: 16 }) {
              // 左摇杆数值
              Column({ space: 2 }) {
                Text('左摇杆')
                  .fontSize(10)
                  .fontColor(AppColors.TextTertiary)
                Text(`${this.formatStickValue(this.lastInputState!.leftStickX)}, ${this.formatStickValue(this.lastInputState!.leftStickY)}`)
                  .fontSize(11)
                  .fontColor(AppColors.TextSecondary)
                  .fontFamily('monospace')
              }
              .alignItems(HorizontalAlign.Center)
              
              Divider().vertical(true).height(24).color(AppColors.Divider)
              
              // 扳机数值
              Column({ space: 2 }) {
                Text('扳机')
                  .fontSize(10)
                  .fontColor(AppColors.TextTertiary)
                Text(`L:${this.formatTriggerValue(this.lastInputState!.leftTrigger)} R:${this.formatTriggerValue(this.lastInputState!.rightTrigger)}`)
                  .fontSize(11)
                  .fontColor(AppColors.TextSecondary)
                  .fontFamily('monospace')
              }
              .alignItems(HorizontalAlign.Center)
              
              Divider().vertical(true).height(24).color(AppColors.Divider)
              
              // 右摇杆数值
              Column({ space: 2 }) {
                Text('右摇杆')
                  .fontSize(10)
                  .fontColor(AppColors.TextTertiary)
                Text(`${this.formatStickValue(this.lastInputState!.rightStickX)}, ${this.formatStickValue(this.lastInputState!.rightStickY)}`)
                  .fontSize(11)
                  .fontColor(AppColors.TextSecondary)
                  .fontFamily('monospace')
              }
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceEvenly)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColors.CardBackground)
          .borderRadius(12)
          .border({ width: 1, color: AppColors.CardBorder })
        }

        // 日志卡片
        Column({ space: 12 }) {
          Row() {
            Text('📋')
              .fontSize(20)
            Text('调试日志')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.TextPrimary)
              .margin({ left: 8 })
            Blank()
            Text(`${this.logMessages.length} 条`)
              .fontSize(12)
              .fontColor(AppColors.TextTertiary)
          }
          .width('100%')

          List() {
            ForEach(this.logMessages, (message: string, index: number) => {
              ListItem() {
                Text(message)
                  .fontSize(11)
                  .fontColor(AppColors.TextSecondary)
                  .fontFamily('monospace')
                  .width('100%')
              }
              .padding({ top: 4, bottom: 4 })
            })
          }
          .height(120)
          .width('100%')
          .backgroundColor(AppColors.SurfaceTransparent)
          .borderRadius(8)
          .padding(8)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(AppColors.CardBackground)
        .borderRadius(12)
        .border({ width: 1, color: AppColors.CardBorder })
      }
      .padding(16)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.Background)
    .scrollBar(BarState.Off)
  }

  // 摇杆可视化 - 实时动画
  @Builder
  StickVisualizer(x: number, y: number, isRight: boolean) {
    Stack() {
      // 外圈
      Circle()
        .width(80)
        .height(80)
        .fill(AppColors.SurfaceDark)
        .stroke(AppColors.Border)
        .strokeWidth(2)
      
      // 十字线
      Line()
        .width(60)
        .height(1)
        .backgroundColor(AppColors.Divider)
      Line()
        .width(1)
        .height(60)
        .backgroundColor(AppColors.Divider)
      
      // 死区圈
      Circle()
        .width(16)
        .height(16)
        .fill(Color.Transparent)
        .stroke(AppColors.Divider)
        .strokeWidth(1)
      
      // 移动轨迹 (淡化效果)
      Circle()
        .width(8)
        .height(8)
        .fill(isRight ? '#E8112320' : '#3D8ECF20')
        .offset({
          x: (x / 32767) * 30,
          y: -(y / 32767) * 30
        })
        .animation({ duration: 150, curve: Curve.EaseOut })
      
      // 指示点 - 添加平滑动画
      Circle()
        .width(16)
        .height(16)
        .fill(isRight ? AppColors.Error : AppColors.Primary)
        .shadow({ radius: 8, color: isRight ? '#E8112360' : '#3D8ECF60', offsetX: 0, offsetY: 0 })
        .offset({
          x: (x / 32767) * 30,
          y: -(y / 32767) * 30
        })
        .animation({ duration: 50, curve: Curve.Linear })  // 快速响应
    }
    .width(80)
    .height(80)
  }

  // 扳机条 - 实时动画
  @Builder
  TriggerBar(value: number, isLeft: boolean) {
    Stack({ alignContent: Alignment.Bottom }) {
      // 背景
      Column()
        .width(24)
        .height(60)
        .backgroundColor(AppColors.SurfaceDark)
        .borderRadius(12)
      
      // 发光层 (value > 0 时显示)
      if (value > 0.1) {
        Column()
          .width(24)
          .height(Math.max(4, value * 60))
          .backgroundColor(isLeft ? '#3D8ECF40' : '#E8112340')
          .borderRadius(12)
          .animation({ duration: 80, curve: Curve.EaseOut })
      }
      
      // 填充 - 添加平滑动画
      Column()
        .width(24)
        .height(Math.max(4, value * 60))
        .backgroundColor(isLeft ? AppColors.Primary : AppColors.Error)
        .borderRadius(12)
        .animation({ duration: 50, curve: Curve.Linear })  // 快速响应
    }
    .width(24)
    .height(60)
  }
  
  // 肩键按钮 - 带按下动画
  @Builder
  ShoulderButton(label: string, pressed: boolean) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(pressed ? '#FFFFFF' : AppColors.TextTertiary)
    }
    .width(48)
    .height(24)
    .borderRadius(12)
    .backgroundColor(pressed ? AppColors.Primary : AppColors.SurfaceDark)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .margin({ left: 8, right: 8 })
    .scale({ x: pressed ? 0.95 : 1, y: pressed ? 0.95 : 1 })
    .animation({ duration: 60 })
  }
  
  // 功能键（Back/Start/Home）- 带按下动画
  @Builder
  FunctionButton(label: string, pressed: boolean) {
    Column() {
      Text(label)
        .fontSize(14)
        .fontColor(pressed ? '#FFFFFF' : AppColors.TextTertiary)
    }
    .width(32)
    .height(32)
    .borderRadius(16)
    .backgroundColor(pressed ? AppColors.Primary : AppColors.SurfaceDark)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .scale({ x: pressed ? 0.9 : 1, y: pressed ? 0.9 : 1 })
    .animation({ duration: 80 })
  }
  
  // ABXY 按钮菱形布局
  @Builder
  ABXYVisualizer() {
    Column({ space: 2 }) {
      // Y 在上
      this.ABXYButton('Y', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.Y_FLAG), '#FFB900')
      
      // X 和 B 在中间
      Row({ space: 24 }) {
        this.ABXYButton('X', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.X_FLAG), '#0078D4')
        this.ABXYButton('B', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.B_FLAG), '#E81123')
      }
      
      // A 在下
      this.ABXYButton('A', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.A_FLAG), '#107C10')
    }
  }
  
  // 单个 ABXY 按钮 - 带按下动画
  @Builder
  ABXYButton(label: string, pressed: boolean, color: string) {
    Column() {
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(pressed ? '#FFFFFF' : AppColors.TextTertiary)
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .backgroundColor(pressed ? color : AppColors.SurfaceDark)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .shadow(pressed ? { radius: 12, color: color, offsetX: 0, offsetY: 2 } : undefined)
    .scale({ x: pressed ? 1.15 : 1, y: pressed ? 1.15 : 1 })
    .animation({ duration: 60 })
  }
  
  // D-Pad 十字键可视化
  @Builder
  DPadVisualizer() {
    Column({ space: 2 }) {
      // 上
      this.DPadArrow('▲', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.UP_FLAG))
      
      // 左 中心 右
      Row({ space: 2 }) {
        this.DPadArrow('◀', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.LEFT_FLAG))
        // 中心占位
        Column()
          .width(28)
          .height(28)
          .backgroundColor(AppColors.SurfaceDark)
          .borderRadius(4)
        this.DPadArrow('▶', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.RIGHT_FLAG))
      }
      
      // 下
      this.DPadArrow('▼', this.isButtonPressed(this.lastInputState!.buttons, ButtonFlags.DOWN_FLAG))
    }
  }
  
  // D-Pad 单个方向键 - 带按下动画
  @Builder
  DPadArrow(label: string, pressed: boolean) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(pressed ? '#FFFFFF' : AppColors.TextTertiary)
    }
    .width(28)
    .height(28)
    .borderRadius(4)
    .backgroundColor(pressed ? AppColors.Primary : AppColors.SurfaceDark)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .scale({ x: pressed ? 1.1 : 1, y: pressed ? 1.1 : 1 })
    .animation({ duration: 60 })
  }
}
