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
import { GamepadManager } from '../service/GamepadManager';
import { AXIS_MAX } from '../service/GamepadTypes';
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

// @Builder 按引用传参接口
interface StickVisualizerParams {
  x: number;
  y: number;
  isRight: boolean;
}

interface ButtonStateParams {
  label: string;
  buttons: number;
  flag: number;
}

interface ABXYButtonParams {
  label: string;
  buttons: number;
  flag: number;
  color: string;
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
    state.leftStickX = Math.max(-AXIS_MAX, Math.min(AXIS_MAX, Math.floor(leftStickX * AXIS_MAX)));
    state.leftStickY = Math.max(-AXIS_MAX, Math.min(AXIS_MAX, Math.floor(-leftStickY * AXIS_MAX)));  // Y轴取负与串流一致
    state.rightStickX = Math.max(-AXIS_MAX, Math.min(AXIS_MAX, Math.floor(rightStickX * AXIS_MAX)));
    state.rightStickY = Math.max(-AXIS_MAX, Math.min(AXIS_MAX, Math.floor(-rightStickY * AXIS_MAX)));  // Y轴取负与串流一致
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
  // 使用纯原始类型 @State —— ArkUI 对 number/boolean 的变化检测最可靠
  @State displayButtons: number = 0;
  @State displayLSX: number = 0;
  @State displayLSY: number = 0;
  @State displayRSX: number = 0;
  @State displayRSY: number = 0;
  @State displayLT: number = 0;
  @State displayRT: number = 0;
  @State hasInput: boolean = false;
  @State logMessages: string[] = [];
  @State pollRate: number = 0;
  @State pollCount: number = 0;

  private usbDriverService: UsbDriverService | null = null;
  private listener: TestViewDriverListener | null = null;
  private pollCountInternal: number = 0;
  private lastPollStatTime: number = 0;
  private pollRateTimer: number = -1;
  private uiRefreshTimer: number = -1;
  // 内部缓冲区：USB 轮询回调（高频，125-1000Hz）写入此变量，
  // 由 UI 刷新定时器同步到 @State 以正确触发 UI 重渲染
  private internalLastInputState: ControllerInputState | null = null;

  aboutToAppear(): void {
    this.addLog('USB 手柄测试视图初始化');
    this.checkUsbDevices();
    this.startPollRateTimer();
    this.startUiRefreshTimer();
  }

  aboutToDisappear(): void {
    this.stopUiRefreshTimer();
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

  // 30Hz UI 刷新定时器：将内部缓冲区同步到 @State 变量
  // USB 轮询回调频率为 125-1000Hz，远高于 UI 刷新需求。
  // 使用纯原始类型赋值确保 ArkUI 可靠检测变化。
  private startUiRefreshTimer(): void {
    this.uiRefreshTimer = setInterval(() => {
      if (this.internalLastInputState !== null) {
        const s = this.internalLastInputState;
        this.displayButtons = s.buttons;
        this.displayLSX = s.leftStickX;
        this.displayLSY = s.leftStickY;
        this.displayRSX = s.rightStickX;
        this.displayRSY = s.rightStickY;
        this.displayLT = s.leftTrigger;
        this.displayRT = s.rightTrigger;
        this.hasInput = true;
      }
    }, 33);
  }

  private stopUiRefreshTimer(): void {
    if (this.uiRefreshTimer !== -1) {
      clearInterval(this.uiRefreshTimer);
      this.uiRefreshTimer = -1;
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
    this.internalLastInputState = state;
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
    // 临时接管 listener 用于测试（覆盖 GamepadManager 的 listener）
    this.usbDriverService.setListener(this.listener);
    this.usbDriverService.start();
    this.isRunning = true;
    this.addLog('USB 驱动服务已启动（测试模式）');
  }

  private stopDriver(): void {
    if (this.usbDriverService !== null) {
      // 测试页面场景：必须调用 stop() 释放 USB 设备的独占声明（claimInterface），
      // 否则切换到 GCK 测试页时，Game Controller Kit 无法通过系统 HID 输入栈检测到该设备。
      // 注意：这不影响串流，因为测试页面不在串流路径上。
      // 用户切回 USB Tab 时 startDriver() 会重新调用 start() 重新枚举设备。
      this.usbDriverService.stop();
      
      // 重要：仅恢复 GamepadManager 的 listener 引用，但不重启 USB 驱动。
      // 之前调用 reattachInputCallbacks() 会在传统模式下执行 usbDriverService.start()，
      // 导致设备被立即重新独占，GCK 测试页面无法检测到手柄。
      // GamepadManager 会在需要时（如串流启动）自行重启 USB 驱动。
      this.restoreGamepadManagerListenerOnly();
      
      this.usbDriverService = null;
      this.listener = null;
      this.isRunning = false;
      this.connectedDevices = [];
      this.hasInput = false;
      this.displayButtons = 0;
      this.displayLSX = 0;
      this.displayLSY = 0;
      this.displayRSX = 0;
      this.displayRSY = 0;
      this.displayLT = 0;
      this.displayRT = 0;
      this.internalLastInputState = null;
      this.addLog('USB 驱动测试已停止（已释放设备独占）');
    }
  }
  
  /**
   * 仅恢复 GamepadManager 的 USB 驱动 listener，不重启驱动。
   * 
   * 与 reattachInputCallbacks() 不同，此方法不会调用 usbDriverService.start()，
   * 避免在切换到 GCK 测试页时立即重新独占 USB 设备。
   */
  private restoreGamepadManagerListenerOnly(): void {
    try {
      const gamepadManager = GamepadManager.getInstance();
      // 仅恢复 listener，不启动驱动
      UsbDriverService.getInstance().setListener(gamepadManager);
      console.info('[UsbControllerTest] 已恢复 GamepadManager listener（未重启驱动）');
    } catch (err) {
      console.error('[UsbControllerTest] 恢复 GamepadManager listener 失败:', err);
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
    const percent = Math.round((value / AXIS_MAX) * 100);
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
      Column({ space: 10 }) {
        // ═══ 设备状态 + 控制按钮（合并为一张卡片）═══
        Column({ space: 10 }) {
          // 标题 + 操作按钮
          Row() {
            Text('设备状态')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.TextPrimary)

            Blank()

            Button(this.isRunning ? '停止' : '启动')
              .onClick(() => {
                if (this.isRunning) {
                  this.stopDriver();
                } else {
                  this.startDriver();
                }
              })
              .backgroundColor(this.isRunning ? AppColors.Error : AppColors.Success)
              .fontColor(AppColors.TextOnPrimary)
              .fontSize(12)
              .height(30)
              .padding({ left: 14, right: 14 })
              .borderRadius(15)

            Button('刷新')
              .onClick(() => {
                this.checkUsbDevices();
              })
              .backgroundColor(AppColors.Primary)
              .fontColor(AppColors.TextOnPrimary)
              .fontSize(12)
              .height(30)
              .padding({ left: 14, right: 14 })
              .borderRadius(15)
              .margin({ left: 8 })
          }
          .width('100%')

          // 统计数字行
          Row() {
            Column({ space: 2 }) {
              Text(`${this.deviceCount}`)
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColors.TextPrimary)
              Text('USB 设备')
                .fontSize(11)
                .fontColor(AppColors.TextSecondary)
            }
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1)

            Row().width(1).height(28).backgroundColor(AppColors.Divider)

            Column({ space: 2 }) {
              Text(`${this.connectedDevices.length}`)
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.connectedDevices.length > 0 ? AppColors.Success : AppColors.TextTertiary)
              Text('已连接')
                .fontSize(11)
                .fontColor(AppColors.TextSecondary)
            }
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1)

            if (this.connectedDevices.length > 0) {
              Row().width(1).height(28).backgroundColor(AppColors.Divider)

              Column({ space: 2 }) {
                Row() {
                  Text(`${this.pollRate}`)
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.getPollRateColor())
                  Text(' Hz')
                    .fontSize(12)
                    .fontColor(AppColors.TextSecondary)
                }
                Text(this.getPollRateDesc())
                  .fontSize(11)
                  .fontColor(AppColors.TextSecondary)
              }
              .alignItems(HorizontalAlign.Center)
              .layoutWeight(1)
            }
          }
          .width('100%')

          // 已连接设备列表
          if (this.connectedDevices.length > 0) {
            ForEach(this.connectedDevices, (device: DeviceInfo) => {
              Row({ space: 8 }) {
                Text(this.getControllerTypeIcon(device.type))
                  .fontSize(20)
                Column({ space: 1 }) {
                  Text(device.name)
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppColors.TextPrimary)
                  Text(`${this.getControllerTypeName(device.type)} · VID:0x${device.vid.toString(16).toUpperCase()} PID:0x${device.pid.toString(16).toUpperCase()}`)
                    .fontSize(10)
                    .fontColor(AppColors.TextTertiary)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .backgroundColor('#0A808080')
              .borderRadius(6)
            })
          }
        }
        .width('100%')
        .padding(12)
        .backgroundColor(AppColors.CardBackground)
        .borderRadius(12)
        .border({ width: 1, color: AppColors.CardBorder })

        // ═══ 输入可视化卡片 ═══
        if (this.hasInput) {
          Column({ space: 10 }) {
            // 标题行
            Row() {
              Text('输入状态')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColors.TextPrimary)
              Blank()
              Text('实时')
                .fontSize(10)
                .fontColor(AppColors.Success)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor('#1A4CAF50')
                .borderRadius(4)
            }
            .width('100%')

            // 扳机区
            Row() {
              // 左侧
              Column({ space: 4 }) {
                Row() {
                  Text('LB')
                    .fontSize(10)
                    .fontWeight(FontWeight.Medium)
                    .fontColor((this.displayButtons & ButtonFlags.LB_FLAG) !== 0 ? '#FFFFFF' : AppColors.TextTertiary)
                }
                .width(48)
                .height(22)
                .borderRadius(11)
                .backgroundColor((this.displayButtons & ButtonFlags.LB_FLAG) !== 0 ? AppColors.Primary : '#1A808080')
                .justifyContent(FlexAlign.Center)
                .animation({ duration: 60 })

                Row({ space: 4 }) {
                  Text('LT')
                    .fontSize(9)
                    .fontColor(AppColors.TextTertiary)
                  Stack({ alignContent: Alignment.Start }) {
                    Row().width(64).height(6).backgroundColor('#1A808080').borderRadius(3)
                    Row()
                      .width(Math.max(3, this.displayLT * 64))
                      .height(6)
                      .borderRadius(3)
                      .linearGradient({ angle: 90, colors: [['#3D8ECF', 0], ['#5BA8E6', 1]] })
                      .animation({ duration: 50, curve: Curve.Linear })
                  }
                }
              }
              .alignItems(HorizontalAlign.Center)

              Blank()

              // 右侧
              Column({ space: 4 }) {
                Row() {
                  Text('RB')
                    .fontSize(10)
                    .fontWeight(FontWeight.Medium)
                    .fontColor((this.displayButtons & ButtonFlags.RB_FLAG) !== 0 ? '#FFFFFF' : AppColors.TextTertiary)
                }
                .width(48)
                .height(22)
                .borderRadius(11)
                .backgroundColor((this.displayButtons & ButtonFlags.RB_FLAG) !== 0 ? AppColors.Error : '#1A808080')
                .justifyContent(FlexAlign.Center)
                .animation({ duration: 60 })

                Row({ space: 4 }) {
                  Stack({ alignContent: Alignment.End }) {
                    Row().width(64).height(6).backgroundColor('#1A808080').borderRadius(3)
                    Row()
                      .width(Math.max(3, this.displayRT * 64))
                      .height(6)
                      .borderRadius(3)
                      .linearGradient({ angle: 90, colors: [['#E85D75', 0], ['#E81123', 1]] })
                      .animation({ duration: 50, curve: Curve.Linear })
                  }
                  Text('RT')
                    .fontSize(9)
                    .fontColor(AppColors.TextTertiary)
                }
              }
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .padding({ left: 20, right: 20 })

            // 主体区
            Row() {
              // 左：摇杆 + D-Pad
              Column({ space: 14 }) {
                this.StickVisualizer({ x: this.displayLSX, y: this.displayLSY, isRight: false })
                Text((this.displayButtons & ButtonFlags.LS_CLK_FLAG) !== 0 ? 'L3 ●' : 'L3')
                  .fontSize(9)
                  .fontColor((this.displayButtons & ButtonFlags.LS_CLK_FLAG) !== 0 ?
                    AppColors.Primary : AppColors.TextTertiary)
                  .margin({ top: -8 })
                this.DPadVisualizer()
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)

              // 中：功能键
              Column() {
                Row({ space: 16 }) {
                  this.FunctionButton({ label: '≡', buttons: this.displayButtons, flag: ButtonFlags.BACK_FLAG })
                  this.FunctionButton({ label: '⊙', buttons: this.displayButtons, flag: ButtonFlags.SPECIAL_BUTTON_FLAG })
                  this.FunctionButton({ label: '▶', buttons: this.displayButtons, flag: ButtonFlags.PLAY_FLAG })
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
              .justifyContent(FlexAlign.Center)

              // 右：ABXY + 摇杆
              Column({ space: 14 }) {
                this.ABXYVisualizer()
                this.StickVisualizer({ x: this.displayRSX, y: this.displayRSY, isRight: true })
                Text((this.displayButtons & ButtonFlags.RS_CLK_FLAG) !== 0 ? 'R3 ●' : 'R3')
                  .fontSize(9)
                  .fontColor((this.displayButtons & ButtonFlags.RS_CLK_FLAG) !== 0 ?
                    AppColors.Error : AppColors.TextTertiary)
                  .margin({ top: -8 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .padding({ left: 4, right: 4 })

            // 数值行
            Row() {
              Column() {
                Text(`L: ${this.formatStickValue(this.displayLSX)},${this.formatStickValue(this.displayLSY)}`)
                  .fontSize(11)
                  .fontColor(AppColors.TextSecondary)
                  .fontFamily('monospace')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)

              Row().width(1).height(16).backgroundColor(AppColors.Divider)

              Column() {
                Text(`LT:${this.formatTriggerValue(this.displayLT)} RT:${this.formatTriggerValue(this.displayRT)}`)
                  .fontSize(11)
                  .fontColor(AppColors.TextSecondary)
                  .fontFamily('monospace')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)

              Row().width(1).height(16).backgroundColor(AppColors.Divider)

              Column() {
                Text(`R: ${this.formatStickValue(this.displayRSX)},${this.formatStickValue(this.displayRSY)}`)
                  .fontSize(11)
                  .fontColor(AppColors.TextSecondary)
                  .fontFamily('monospace')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .padding({ left: 4, right: 4, top: 6, bottom: 4 })
            .backgroundColor('#0A808080')
            .borderRadius(6)
          }
          .width('100%')
          .padding(12)
          .backgroundColor(AppColors.CardBackground)
          .borderRadius(12)
          .border({ width: 1, color: AppColors.CardBorder })
        }

        // ═══ 日志卡片 ═══
        Column({ space: 8 }) {
          Row() {
            Text('调试日志')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.TextPrimary)
            Blank()
            Text(`${this.logMessages.length} 条`)
              .fontSize(11)
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
              .padding({ top: 3, bottom: 3 })
            })
          }
          .height(100)
          .width('100%')
          .backgroundColor('#0A808080')
          .borderRadius(6)
          .padding(8)
        }
        .width('100%')
        .padding(12)
        .backgroundColor(AppColors.CardBackground)
        .borderRadius(12)
        .border({ width: 1, color: AppColors.CardBorder })
      }
      .padding(12)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.Background)
    .scrollBar(BarState.Off)
  }

  // 摇杆可视化 - 精致圆盘风格
  @Builder
  StickVisualizer($$: StickVisualizerParams) {
    Stack() {
      // 外圈 - 柔和边框
      Circle()
        .width(76)
        .height(76)
        .fill('#0A808080')
        .stroke('#20808080')
        .strokeWidth(1.5)

      // 十字参考线（淡）
      Line()
        .width(56)
        .height(0.5)
        .backgroundColor('#15808080')
      Line()
        .width(0.5)
        .height(56)
        .backgroundColor('#15808080')

      // 死区范围
      Circle()
        .width(12)
        .height(12)
        .fill(Color.Transparent)
        .stroke('#18808080')
        .strokeWidth(0.5)
      
      // 指示点 — 渐变发光
      Circle()
        .width(18)
        .height(18)
        .fill($$.isRight ? '#E81123' : '#3D8ECF')
        .shadow({ radius: 10, color: $$.isRight ? '#50E81123' : '#503D8ECF', offsetX: 0, offsetY: 0 })
        .offset({
          x: ($$.x / 32767) * 28,
          y: -($$.y / 32767) * 28
        })
        .animation({ duration: 50, curve: Curve.Linear })
    }
    .width(76)
    .height(76)
  }

  // 功能键（Back/Home/Start）- 小型胶囊风格
  @Builder
  FunctionButton($$: ButtonStateParams) {
    Column() {
      Text($$.label)
        .fontSize(13)
        .fontColor(($$.buttons & $$.flag) !== 0 ? '#FFFFFF' : AppColors.TextTertiary)
    }
    .width(30)
    .height(30)
    .borderRadius(15)
    .backgroundColor(($$.buttons & $$.flag) !== 0 ? '#606060' : '#1A808080')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .scale({ x: ($$.buttons & $$.flag) !== 0 ? 0.88 : 1, y: ($$.buttons & $$.flag) !== 0 ? 0.88 : 1 })
    .animation({ duration: 80 })
  }
  
  // ABXY 按钮菱形布局 — 紧凑排列
  @Builder
  ABXYVisualizer() {
    Column({ space: 1 }) {
      // Y 在上
      this.ABXYButton({ label: 'Y', buttons: this.displayButtons, flag: ButtonFlags.Y_FLAG, color: '#FFB900' })

      // X 和 B 在中间
      Row({ space: 22 }) {
        this.ABXYButton({ label: 'X', buttons: this.displayButtons, flag: ButtonFlags.X_FLAG, color: '#0078D4' })
        this.ABXYButton({ label: 'B', buttons: this.displayButtons, flag: ButtonFlags.B_FLAG, color: '#E81123' })
      }

      // A 在下
      this.ABXYButton({ label: 'A', buttons: this.displayButtons, flag: ButtonFlags.A_FLAG, color: '#107C10' })
    }
  }

  // 单个 ABXY 按钮 — 精致圆形
  @Builder
  ABXYButton($$: ABXYButtonParams) {
    Column() {
      Text($$.label)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(($$.buttons & $$.flag) !== 0 ? '#FFFFFF' : AppColors.TextTertiary)
    }
    .width(34)
    .height(34)
    .borderRadius(17)
    .backgroundColor(($$.buttons & $$.flag) !== 0 ? $$.color : '#1A808080')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .shadow(($$.buttons & $$.flag) !== 0 ?
      { radius: 10, color: `${$$.color}80`, offsetX: 0, offsetY: 1 } : undefined)
    .scale({ x: ($$.buttons & $$.flag) !== 0 ? 1.12 : 1, y: ($$.buttons & $$.flag) !== 0 ? 1.12 : 1 })
    .animation({ duration: 60 })
  }
  
  // D-Pad 十字键 — 更紧凑的十字形
  @Builder
  DPadVisualizer() {
    Column({ space: 1 }) {
      // 上
      this.DPadArrow({ label: '▲', buttons: this.displayButtons, flag: ButtonFlags.UP_FLAG })

      // 左 中心 右
      Row({ space: 1 }) {
        this.DPadArrow({ label: '◀', buttons: this.displayButtons, flag: ButtonFlags.LEFT_FLAG })
        Column()
          .width(26)
          .height(26)
          .backgroundColor('#1A808080')
          .borderRadius(3)
        this.DPadArrow({ label: '▶', buttons: this.displayButtons, flag: ButtonFlags.RIGHT_FLAG })
      }

      // 下
      this.DPadArrow({ label: '▼', buttons: this.displayButtons, flag: ButtonFlags.DOWN_FLAG })
    }
  }

  // D-Pad 单个方向键
  @Builder
  DPadArrow($$: ButtonStateParams) {
    Column() {
      Text($$.label)
        .fontSize(11)
        .fontColor(($$.buttons & $$.flag) !== 0 ? '#FFFFFF' : AppColors.TextTertiary)
    }
    .width(26)
    .height(26)
    .borderRadius(3)
    .backgroundColor(($$.buttons & $$.flag) !== 0 ? AppColors.Primary : '#1A808080')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .scale({ x: ($$.buttons & $$.flag) !== 0 ? 1.08 : 1, y: ($$.buttons & $$.flag) !== 0 ? 1.08 : 1 })
    .animation({ duration: 60 })
  }
}
