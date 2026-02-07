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
 * Game Controller Kit 测试视图
 * 用于测试蓝牙/系统手柄的输入（非 USB 直连模式）
 */

import { gameControllerService, GameControllerService, ButtonCode } from '../service/GameControllerService';
import { GamepadManager } from '../service/GamepadManager';
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
class GCDeviceInfo {
  deviceId: string = '';
  name: string = '';
  productId: number = 0;
}

// 按键事件历史记录
class ButtonEventLog {
  timestamp: string;
  deviceId: string;
  buttonCode: number;
  buttonName: string;
  isPressed: boolean;
  
  constructor(deviceId: string, buttonCode: number, isPressed: boolean) {
    this.timestamp = new Date().toLocaleTimeString();
    this.deviceId = deviceId;
    this.buttonCode = buttonCode;
    this.buttonName = ButtonEventLog.getButtonName(buttonCode);
    this.isPressed = isPressed;
  }
  
  static getButtonName(code: number): string {
    // 根据实际测试调整的映射
    switch (code) {
      case 2301: return 'A';
      case 2302: return 'B';
      case 2303: return 'C';
      case 2304: return 'X';
      case 2305: return 'Y';
      case 2306: return 'Z';
      case 2307: return 'L1';
      case 2308: return 'R1';
      case 2309: return 'LT (按钮)';
      case 2310: return 'RT (按钮)';
      case 2311: return 'Select';
      case 2312: return 'Start';
      case 2313: return 'Home/Mode (可自定义)';  // 设置 → 手柄 → Home 键动作
      case 2314: return 'L3';
      case 2315: return 'R3';
      // D-Pad
      case 2012: return 'D-Up';
      case 2013: return 'D-Down';
      case 2014: return 'D-Left';
      case 2015: return 'D-Right';
      default: return `未知(${code})`;
    }
  }
}

@Component
export struct GameControllerTestView {
  @State isMonitoring: boolean = false;
  @State isAvailable: boolean = false;
  @State connectedDevices: GCDeviceInfo[] = [];
  @State inputStates: Map<string, ControllerInputState> = new Map();
  @State logMessages: string[] = [];
  @State buttonEventLogs: ButtonEventLog[] = [];
  @State rawButtonEvents: string[] = [];
  @State keyEventLogs: string[] = [];  // 新增：KeyEvent 日志
  
  // 接收来自父组件的 KeyEvent 处理器注册函数
  onKeyEventRef?: (handler: (event: KeyEvent) => boolean) => void;

  // 内部缓冲区：回调写入此变量，由 UI 刷新定时器同步到 @State
  private internalInputStates: Map<string, ControllerInputState> = new Map();
  private inputStatesDirty: boolean = false;
  private uiRefreshTimer: number = -1;

  aboutToAppear(): void {
    this.addLog('Game Controller Kit 测试视图初始化');
    this.checkAvailability();
    this.startUiRefreshTimer();
    
    // 注册 KeyEvent 处理器
    if (this.onKeyEventRef) {
      this.onKeyEventRef((event: KeyEvent) => this.handleKeyEvent(event));
    }
  }

  aboutToDisappear(): void {
    this.stopUiRefreshTimer();
    this.stopMonitoring();
  }

  // 30Hz UI 刷新定时器：将内部缓冲区同步到 @State 变量
  private startUiRefreshTimer(): void {
    this.uiRefreshTimer = setInterval(() => {
      if (this.inputStatesDirty) {
        this.inputStates = new Map(this.internalInputStates);
        this.inputStatesDirty = false;
      }
    }, 33);
  }

  private stopUiRefreshTimer(): void {
    if (this.uiRefreshTimer !== -1) {
      clearInterval(this.uiRefreshTimer);
      this.uiRefreshTimer = -1;
    }
  }
  
  /**
   * 处理 KeyEvent (API 15+ 支持 2311-2315 手柄按键)
   * 注意：GC Kit 不支持 2313 (Mode)，只能通过 KeyEvent 捕获
   */
  private handleKeyEvent(event: KeyEvent): boolean {
    const keyCode = event.keyCode;
    // KeyType.Down = 0, KeyType.Up = 1
    const isPressed = event.type === 0;
    const timestamp = new Date().toLocaleTimeString();
    
    // 记录所有 2300+ 范围的按键（手柄相关）
    if (keyCode >= 2300 && keyCode <= 2320) {
      const buttonName = ButtonEventLog.getButtonName(keyCode);
      const logEntry = `[${timestamp}] KeyEvent: code=${keyCode} (${buttonName}) ${isPressed ? '按下' : '释放'}`;
      this.keyEventLogs = [logEntry, ...this.keyEventLogs.slice(0, 29)];
      this.addLog(`KeyEvent: ${keyCode} (${buttonName}) ${isPressed ? '按下' : '释放'}`);
      
      // 特别标记 2313
      if (keyCode === 2313) {
        this.addLog(`⭐ 收到 2313 (Mode) 按键！GC Kit 不支持此按键，通过 KeyEvent 捕获`);
      }
      
      return true;  // 已处理
    }
    
    return false;  // 未处理
  }
  
  private checkAvailability(): void {
    this.isAvailable = gameControllerService.isAvailable();
    this.addLog(`Game Controller Kit 可用性: ${this.isAvailable ? '可用' : '不可用'}`);
    
    if (this.isAvailable) {
      this.addLog('可以测试蓝牙/系统手柄输入');
    } else {
      this.addLog('警告: Game Controller Kit 不可用，可能需要 API 21+');
    }
  }

  addLog(message: string): void {
    const timestamp = new Date().toLocaleTimeString();
    this.logMessages = [`[${timestamp}] ${message}`, ...this.logMessages.slice(0, 99)];
  }
  
  private addButtonEventLog(deviceId: string, buttonCode: number, isPressed: boolean): void {
    const log = new ButtonEventLog(deviceId, buttonCode, isPressed);
    this.buttonEventLogs = [log, ...this.buttonEventLogs.slice(0, 49)];
    this.rawButtonEvents = [`[${log.timestamp}] ${isPressed ? '按下' : '释放'} buttonCode=${buttonCode} (${log.buttonName})`, 
                            ...this.rawButtonEvents.slice(0, 29)];
  }
  
  private startMonitoring(): void {
    if (!this.isAvailable) {
      this.addLog('错误: Game Controller Kit 不可用');
      return;
    }
    
    if (this.isMonitoring) {
      this.addLog('已在监听中');
      return;
    }
    
    // 初始化
    if (!gameControllerService.init()) {
      this.addLog('错误: 初始化失败');
      return;
    }
    
    // 临时接管回调（覆盖 GamepadManager 的回调用于测试）
    gameControllerService.setDeviceCallback((deviceId, isConnected, info) => {
      this.onDeviceChanged(deviceId, isConnected, info);
    });
    
    gameControllerService.setButtonCallback((deviceId, buttonCode, isPressed) => {
      this.onButtonEvent(deviceId, buttonCode, isPressed);
    });
    
    gameControllerService.setAxisCallback((deviceId, axisType, x, y) => {
      this.handleAxisEvent(deviceId, axisType, x, y);
    });
    
    // 开始监听（如果已在监听中会直接返回 true）
    if (!gameControllerService.startMonitor()) {
      this.addLog('错误: 开始监听失败');
      return;
    }
    
    this.isMonitoring = true;
    this.addLog('开始监听 Game Controller Kit 事件');
    
    // 获取已连接设备
    this.refreshConnectedDevices();
  }
  
  private stopMonitoring(): void {
    if (!this.isMonitoring) return;
    
    // 不调用 stopMonitor()，避免停止全局监听影响 GamepadManager
    // 只需恢复 GamepadManager 的回调即可
    this.restoreGamepadManagerCallbacks();
    
    this.isMonitoring = false;
    this.addLog('停止监听（已恢复 GamepadManager 回调）');
  }
  
  /**
   * 恢复 GamepadManager 的回调，避免测试页面退出后串流手柄输入丢失
   */
  private restoreGamepadManagerCallbacks(): void {
    try {
      GamepadManager.getInstance().reattachInputCallbacks();
    } catch (err) {
      console.error('[GameControllerTest] 恢复 GamepadManager 回调失败:', err);
    }
  }
  
  private refreshConnectedDevices(): void {
    const devices = gameControllerService.getAllDevices();
    this.connectedDevices = [];

    // 按 physicalAddress 去重：同一物理设备的多个 HID 接口只保留第一个
    const seenPhysicalAddresses = new Set<string>();
    const seenNameProduct = new Set<string>();

    for (const device of devices) {
      // 主去重：physicalAddress
      if (device.physicalAddress && device.physicalAddress.length > 0) {
        if (seenPhysicalAddresses.has(device.physicalAddress)) {
          this.addLog(`跳过重复接口: ${device.name} (物理地址: ${device.physicalAddress})`);
          continue;
        }
        seenPhysicalAddresses.add(device.physicalAddress);
      } else {
        // 备用去重：name + product
        const key = `${device.name}::${device.product}`;
        if (seenNameProduct.has(key)) {
          this.addLog(`跳过重复接口: ${device.name} (name+product去重)`);
          continue;
        }
        seenNameProduct.add(key);
      }

      const info = new GCDeviceInfo();
      info.deviceId = device.deviceId;
      info.name = device.name;
      info.productId = device.product;
      this.connectedDevices.push(info);
      this.addLog(`发现设备: ${device.name} (ID: ${device.deviceId})`);
    }
    
    if (this.connectedDevices.length === 0) {
      this.addLog('未发现已连接的手柄设备');
    }
  }
  
  private onDeviceChanged(deviceId: string, isConnected: boolean, info: object | null): void {
    if (isConnected) {
      this.addLog(`设备连接: ${deviceId}`);
      this.refreshConnectedDevices();
    } else {
      this.addLog(`设备断开: ${deviceId}`);
      this.connectedDevices = this.connectedDevices.filter(d => d.deviceId !== deviceId);
      this.internalInputStates.delete(deviceId);
      this.inputStatesDirty = true;
    }
  }
  
  private onButtonEvent(deviceId: string, buttonCode: number, isPressed: boolean): void {
    // 记录原始事件
    this.addButtonEventLog(deviceId, buttonCode, isPressed);
    this.addLog(`按键事件: device=${deviceId}, code=${buttonCode}, pressed=${isPressed}`);
    
    // 更新内部缓冲区状态
    let state = this.internalInputStates.get(deviceId);
    if (!state) {
      state = new ControllerInputState();
      this.internalInputStates.set(deviceId, state);
    }
    
    const flag = this.buttonCodeToFlag(buttonCode);
    if (flag !== 0) {
      if (isPressed) {
        state.buttons |= flag;
      } else {
        state.buttons &= ~flag;
      }
      // 标记脏数据，由定时器同步到 @State
      this.inputStatesDirty = true;
    }
  }
  
  private buttonCodeToFlag(code: number): number {
    switch (code) {
      case 2301: return 0x1000;  // A
      case 2302: return 0x2000;  // B
      case 2303: return 0x0020;  // C -> BACK/Select
      case 2304: return 0x4000;  // X
      case 2305: return 0x8000;  // Y
      case 2306: return 0x0100;  // L1
      case 2307: return 0x0200;  // R1
      case 2310: return 0x0040;  // L3
      case 2311: return 0x0080;  // R3
      case 2312: return 0x0010;  // Menu -> START
      case 2313: return 0x0020;  // View -> BACK (官方不支持)
      case 2314: return 0x0400;  // Home -> SPECIAL
      case 2315: return 0x0001;  // D-Up
      case 2316: return 0x0002;  // D-Down
      case 2317: return 0x0004;  // D-Left
      case 2318: return 0x0008;  // D-Right
      default: return 0;
    }
  }
  
  private handleAxisEvent(deviceId: string, axisType: number, x: number, y: number): void {
    let state = this.internalInputStates.get(deviceId);
    if (!state) {
      state = new ControllerInputState();
      this.internalInputStates.set(deviceId, state);
    }
    
    // AxisType: 0=左摇杆, 1=右摇杆, 2=D-Pad, 3=左扳机, 4=右扳机
    switch (axisType) {
      case 0: // 左摇杆
        state.leftStickX = Math.round(x * 32767);
        state.leftStickY = Math.round(-y * 32767);
        break;
      case 1: // 右摇杆
        state.rightStickX = Math.round(x * 32767);
        state.rightStickY = Math.round(-y * 32767);
        break;
      case 3: // 左扳机
        state.leftTrigger = Math.round(x * 255);
        break;
      case 4: // 右扳机
        state.rightTrigger = Math.round(x * 255);
        break;
    }
    
    // 标记脏数据，由定时器同步到 @State
    this.inputStatesDirty = true;
  }

  private formatStickValue(value: number): string {
    const percent = Math.round((value / 32767) * 100);
    if (percent > 0) {
      return `+${percent}%`;
    }
    return `${percent}%`;
  }

  private isButtonPressed(buttons: number, flag: number): boolean {
    return (buttons & flag) !== 0;
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        // 状态标题
        Row({ space: 8 }) {
          Circle()
            .width(12)
            .height(12)
            .fill(this.isAvailable ? (this.isMonitoring ? AppColors.Success : AppColors.Warning) : AppColors.Error)
          Text(this.isAvailable ? (this.isMonitoring ? '监听中' : '就绪') : '不可用')
            .fontSize(14)
            .fontColor(AppColors.TextPrimary)
        }
        
        // 控制按钮
        Row({ space: 12 }) {
          Button(this.isMonitoring ? '停止监听' : '开始监听')
            .onClick(() => {
              if (this.isMonitoring) {
                this.stopMonitoring();
              } else {
                this.startMonitoring();
              }
            })
            .backgroundColor(this.isMonitoring ? AppColors.Error : AppColors.Success)
            .fontColor(AppColors.TextOnPrimary)
            .fontSize(14)
            .height(40)
            .padding({ left: 20, right: 20 })
            .borderRadius(20)
            .enabled(this.isAvailable)

          Button('刷新设备')
            .onClick(() => {
              this.refreshConnectedDevices();
            })
            .backgroundColor(AppColors.Primary)
            .fontColor(AppColors.TextOnPrimary)
            .fontSize(14)
            .height(40)
            .padding({ left: 20, right: 20 })
            .borderRadius(20)
            .enabled(this.isMonitoring)
        }

        // 已连接设备
        Column({ space: 8 }) {
          Text(`已连接设备 (${this.connectedDevices.length})`)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.TextPrimary)
            .width('100%')

          if (this.connectedDevices.length === 0) {
            Text('未检测到手柄设备\n请确保蓝牙手柄已配对连接')
              .fontSize(13)
              .fontColor(AppColors.TextSecondary)
              .textAlign(TextAlign.Center)
              .padding(16)
          } else {
            ForEach(this.connectedDevices, (device: GCDeviceInfo) => {
              Row({ space: 8 }) {
                Text('🎮')
                  .fontSize(20)
                Column({ space: 2 }) {
                  Text(device.name)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppColors.TextPrimary)
                  Text(`ID: ${device.deviceId}`)
                    .fontSize(11)
                    .fontColor(AppColors.TextTertiary)
                  if (device.productId !== 0) {
                    Text(`PID:0x${device.productId.toString(16).toUpperCase()}`)
                      .fontSize(10)
                      .fontColor(AppColors.TextTertiary)
                  }
                }
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding(12)
              .backgroundColor(AppColors.SurfaceTransparent)
              .borderRadius(8)
            })
          }
        }
        .width('100%')
        .padding(12)
        .backgroundColor(AppColors.Surface)
        .borderRadius(12)

        // 原始按键事件（重要诊断信息）
        Column({ space: 8 }) {
          Row() {
            Text('🔑 原始按键事件')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.TextPrimary)
            Blank()
            Text('按手柄按键查看码值')
              .fontSize(11)
              .fontColor(AppColors.TextTertiary)
          }
          .width('100%')

          if (this.rawButtonEvents.length === 0) {
            Text('等待按键输入...\n按下手柄上的任意按键')
              .fontSize(13)
              .fontColor(AppColors.TextSecondary)
              .textAlign(TextAlign.Center)
              .padding(16)
          } else {
            ForEach(this.rawButtonEvents.slice(0, 10), (event: string, index: number) => {
              Text(event)
                .fontSize(12)
                .fontColor(index === 0 ? AppColors.Primary : AppColors.TextSecondary)
                .fontFamily('monospace')
                .width('100%')
                .padding({ top: 4, bottom: 4 })
            })
          }
        }
        .width('100%')
        .padding(12)
        .backgroundColor(AppColors.Surface)
        .borderRadius(12)

        // 按键状态可视化
        if (this.connectedDevices.length > 0) {
          this.buildButtonsDisplay()
        }

        // 日志
        Column({ space: 8 }) {
          Text('📋 日志')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.TextPrimary)
            .width('100%')

          ForEach(this.logMessages.slice(0, 20), (log: string) => {
            Text(log)
              .fontSize(11)
              .fontColor(AppColors.TextSecondary)
              .width('100%')
              .padding({ top: 2, bottom: 2 })
          })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(AppColors.Surface)
        .borderRadius(12)
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.Background)
  }
  
  // 获取第一个设备的状态
  private getFirstDeviceState(): ControllerInputState | null {
    if (this.connectedDevices.length > 0) {
      return this.inputStates.get(this.connectedDevices[0].deviceId) ?? null;
    }
    return null;
  }
  
  @Builder
  buildButtonsDisplay() {
    Column({ space: 8 }) {
      Text('🎮 按键状态')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.TextPrimary)
        .width('100%')

      if (this.getFirstDeviceState() === null) {
        Text('等待输入...')
          .fontSize(13)
          .fontColor(AppColors.TextSecondary)
      } else {
        // 按键网格
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          this.buildButtonIndicator('A', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x1000))
          this.buildButtonIndicator('B', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x2000))
          this.buildButtonIndicator('X', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x4000))
          this.buildButtonIndicator('Y', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x8000))
          this.buildButtonIndicator('LB', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x0100))
          this.buildButtonIndicator('RB', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x0200))
          this.buildButtonIndicator('LS', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x0040))
          this.buildButtonIndicator('RS', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x0080))
          this.buildButtonIndicator('Start', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x0010))
          this.buildButtonIndicator('Back', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x0020))
          this.buildButtonIndicator('Home', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x0400))
          this.buildButtonIndicator('↑', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x0001))
          this.buildButtonIndicator('↓', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x0002))
          this.buildButtonIndicator('←', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x0004))
          this.buildButtonIndicator('→', this.isButtonPressed(this.getFirstDeviceState()!.buttons, 0x0008))
        }
        .width('100%')

        // 摇杆和扳机
        Row({ space: 16 }) {
          Column({ space: 4 }) {
            Text('左摇杆')
              .fontSize(11)
              .fontColor(AppColors.TextSecondary)
            Text(`X: ${this.formatStickValue(this.getFirstDeviceState()!.leftStickX)}`)
              .fontSize(12)
              .fontColor(AppColors.TextPrimary)
            Text(`Y: ${this.formatStickValue(this.getFirstDeviceState()!.leftStickY)}`)
              .fontSize(12)
              .fontColor(AppColors.TextPrimary)
          }
          
          Column({ space: 4 }) {
            Text('右摇杆')
              .fontSize(11)
              .fontColor(AppColors.TextSecondary)
            Text(`X: ${this.formatStickValue(this.getFirstDeviceState()!.rightStickX)}`)
              .fontSize(12)
              .fontColor(AppColors.TextPrimary)
            Text(`Y: ${this.formatStickValue(this.getFirstDeviceState()!.rightStickY)}`)
              .fontSize(12)
              .fontColor(AppColors.TextPrimary)
          }
          
          Column({ space: 4 }) {
            Text('扳机')
              .fontSize(11)
              .fontColor(AppColors.TextSecondary)
            Text(`LT: ${this.getFirstDeviceState()!.leftTrigger}`)
              .fontSize(12)
              .fontColor(AppColors.TextPrimary)
            Text(`RT: ${this.getFirstDeviceState()!.rightTrigger}`)
              .fontSize(12)
              .fontColor(AppColors.TextPrimary)
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceEvenly)
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(AppColors.Surface)
    .borderRadius(12)
  }
  
  @Builder
  buildButtonIndicator(name: string, isPressed: boolean) {
    Text(name)
      .fontSize(12)
      .fontColor(isPressed ? AppColors.TextOnPrimary : AppColors.TextSecondary)
      .backgroundColor(isPressed ? AppColors.Success : AppColors.SurfaceDark)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(4)
      .margin(4)
  }
}
