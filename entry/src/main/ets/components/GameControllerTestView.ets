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
import { gcButtonMap, AXIS_MAX, TRIGGER_MAX } from '../service/GamepadTypes';
import { AppColors } from '../common/Theme';

// @Builder 按引用传参接口
interface ButtonIndicatorParams {
  name: string;
  buttons: number;
  flag: number;
}

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
  // 使用纯原始类型 @State —— ArkUI 对 number/boolean 的变化检测最可靠
  @State displayButtons: number = 0;
  @State displayLSX: number = 0;
  @State displayLSY: number = 0;
  @State displayRSX: number = 0;
  @State displayRSY: number = 0;
  @State displayLT: number = 0;
  @State displayRT: number = 0;
  @State hasInput: boolean = false;  // 是否收到过输入数据
  @State logMessages: string[] = [];
  @State buttonEventLogs: ButtonEventLog[] = [];
  @State rawButtonEvents: string[] = [];
  @State keyEventLogs: string[] = [];
  
  // 接收来自父组件的 KeyEvent 处理器注册函数
  onKeyEventRef?: (handler: (event: KeyEvent) => boolean) => void;

  // 内部缓冲区：GCK 回调在系统线程，直接写 @State 不可靠且导致卡顿
  // 所有回调数据先写入缓冲区，由 30Hz UI 刷新定时器统一同步到 @State
  private internalState: ControllerInputState = new ControllerInputState();
  private stateDirty: boolean = false;
  private internalLogs: string[] = [];
  private logsDirty: boolean = false;
  private internalRawButtonEvents: string[] = [];
  private internalButtonEventLogs: ButtonEventLog[] = [];
  private buttonEventsDirty: boolean = false;
  private internalKeyEventLogs: string[] = [];
  private keyEventsDirty: boolean = false;
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

  // 30Hz UI 刷新定时器：将内部缓冲区统一同步到 @State 变量
  // GCK 回调运行在系统线程，直接赋值 @State 不可靠且会引发高频重渲染
  private startUiRefreshTimer(): void {
    this.uiRefreshTimer = setInterval(() => {
      // 同步手柄状态（纯原始类型赋值，ArkUI 可靠检测变化）
      if (this.stateDirty) {
        const s = this.internalState;
        this.displayButtons = s.buttons;
        this.displayLSX = s.leftStickX;
        this.displayLSY = s.leftStickY;
        this.displayRSX = s.rightStickX;
        this.displayRSY = s.rightStickY;
        this.displayLT = s.leftTrigger;
        this.displayRT = s.rightTrigger;
        this.hasInput = true;
        this.stateDirty = false;
      }
      // 同步日志
      if (this.logsDirty) {
        this.logMessages = [...this.internalLogs];
        this.logsDirty = false;
      }
      // 同步按键事件
      if (this.buttonEventsDirty) {
        this.rawButtonEvents = [...this.internalRawButtonEvents];
        this.buttonEventLogs = [...this.internalButtonEventLogs];
        this.buttonEventsDirty = false;
      }
      // 同步 KeyEvent 日志
      if (this.keyEventsDirty) {
        this.keyEventLogs = [...this.internalKeyEventLogs];
        this.keyEventsDirty = false;
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
      this.internalKeyEventLogs = [logEntry, ...this.internalKeyEventLogs.slice(0, 29)];
      this.keyEventsDirty = true;
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
    this.internalLogs = [`[${timestamp}] ${message}`, ...this.internalLogs.slice(0, 99)];
    this.logsDirty = true;
  }
  
  private addButtonEventLog(deviceId: string, buttonCode: number, isPressed: boolean): void {
    const log = new ButtonEventLog(deviceId, buttonCode, isPressed);
    this.internalButtonEventLogs = [log, ...this.internalButtonEventLogs.slice(0, 49)];
    this.internalRawButtonEvents = [`[${log.timestamp}] ${isPressed ? '按下' : '释放'} buttonCode=${buttonCode} (${log.buttonName})`, 
                            ...this.internalRawButtonEvents.slice(0, 29)];
    this.buttonEventsDirty = true;
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
    
    // 立即从缓存读取当前设备（可能为空）
    const cachedCount = gameControllerService.getDeviceCount();
    this.addLog(`当前 GCK 缓存设备数: ${cachedCount}`);
    this.refreshConnectedDevices();
    
    // USB 驱动释放设备后，UsbDriverService 会在 300ms 后通过 native ioctl (USBDEVFS_CONNECT)
    // 重绑定内核 HID 驱动。GCK 需要额外时间才能检测到重新绑定的设备。
    // 分多次延迟刷新，覆盖不同设备重新枚举的时间差异。
    const refreshDelays = [1000, 2000, 4000, 7000];
    for (const delay of refreshDelays) {
      setTimeout(() => {
        if (this.isMonitoring) {
          const newCount = gameControllerService.refreshDeviceCache();
          const totalCount = gameControllerService.getDeviceCount();
          if (newCount > 0) {
            this.addLog(`刷新(${delay}ms): 新发现 ${newCount} 个设备，总计 ${totalCount}`);
            this.refreshConnectedDevices();
          } else if (newCount < 0) {
            this.addLog(`刷新(${delay}ms): 查询失败`);
          }
          
          // 最后一次刷新：如果仍然没有设备，给出重插提示
          if (delay === 7000 && totalCount === 0) {
            this.addLog('⚠ 未检测到手柄设备。如果之前使用过 USB 驱动测试，可能需要重新插拔手柄。');
          }
        }
      }, delay);
    }
  }
  
  /**
   * 停止监听 Game Controller Kit 事件
   */
  private stopMonitoring(): void {
    if (!this.isMonitoring) {
      return;
    }
    
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
      // 重置状态
      this.internalState = new ControllerInputState();
      this.stateDirty = true;
    }
  }
  
  private onButtonEvent(deviceId: string, buttonCode: number, isPressed: boolean): void {
    // 记录原始事件（写入缓冲区，由 timer 同步）
    this.addButtonEventLog(deviceId, buttonCode, isPressed);
    
    // 更新内部缓冲区状态
    const state = this.internalState;
    
    const flag = this.buttonCodeToFlag(buttonCode);
    if (flag !== 0) {
      if (isPressed) {
        state.buttons |= flag;
      } else {
        state.buttons &= ~flag;
      }
      // 标记脏数据，由定时器同步到 @State
      this.stateDirty = true;
    }
  }
  
  private buttonCodeToFlag(code: number): number {
    return gcButtonMap.get(code) ?? 0;
  }
  
  private handleAxisEvent(deviceId: string, axisType: number, x: number, y: number): void {
    const state = this.internalState;
    
    // AxisType: 0=左摇杆, 1=右摇杆, 2=D-Pad, 3=左扳机, 4=右扳机
    switch (axisType) {
      case 0: // 左摇杆
        state.leftStickX = Math.floor(x * AXIS_MAX);
        state.leftStickY = Math.floor(-y * AXIS_MAX);
        break;
      case 1: // 右摇杆
        state.rightStickX = Math.floor(x * AXIS_MAX);
        state.rightStickY = Math.floor(-y * AXIS_MAX);
        break;
      case 3: // 左扳机
        state.leftTrigger = Math.floor(x * TRIGGER_MAX);
        break;
      case 4: // 右扳机
        state.rightTrigger = Math.floor(x * TRIGGER_MAX);
        break;
    }
    
    this.stateDirty = true;
  }

  private formatStickValue(value: number): string {
    const percent = Math.round((value / AXIS_MAX) * 100);
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
              // 先查询系统设备列表更新缓存，再从缓存读取
              const newCount = gameControllerService.refreshDeviceCache();
              if (newCount > 0) {
                this.addLog(`手动刷新: 新发现 ${newCount} 个设备`);
              }
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
        if (this.hasInput) {
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
  
  // 获取第一个设备的状态（现在使用纯原始类型 @State 变量）
  
  @Builder
  buildButtonsDisplay() {
    Column({ space: 8 }) {
      Text('🎮 按键状态')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.TextPrimary)
        .width('100%')

      // 按键网格
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        this.buildButtonIndicator({ name: 'A', buttons: this.displayButtons, flag: 0x1000 })
        this.buildButtonIndicator({ name: 'B', buttons: this.displayButtons, flag: 0x2000 })
        this.buildButtonIndicator({ name: 'X', buttons: this.displayButtons, flag: 0x4000 })
        this.buildButtonIndicator({ name: 'Y', buttons: this.displayButtons, flag: 0x8000 })
        this.buildButtonIndicator({ name: 'LB', buttons: this.displayButtons, flag: 0x0100 })
        this.buildButtonIndicator({ name: 'RB', buttons: this.displayButtons, flag: 0x0200 })
        this.buildButtonIndicator({ name: 'LS', buttons: this.displayButtons, flag: 0x0040 })
        this.buildButtonIndicator({ name: 'RS', buttons: this.displayButtons, flag: 0x0080 })
        this.buildButtonIndicator({ name: 'Start', buttons: this.displayButtons, flag: 0x0010 })
        this.buildButtonIndicator({ name: 'Back', buttons: this.displayButtons, flag: 0x0020 })
        this.buildButtonIndicator({ name: 'Home', buttons: this.displayButtons, flag: 0x0400 })
        this.buildButtonIndicator({ name: '↑', buttons: this.displayButtons, flag: 0x0001 })
        this.buildButtonIndicator({ name: '↓', buttons: this.displayButtons, flag: 0x0002 })
        this.buildButtonIndicator({ name: '←', buttons: this.displayButtons, flag: 0x0004 })
        this.buildButtonIndicator({ name: '→', buttons: this.displayButtons, flag: 0x0008 })
      }
      .width('100%')

      // 摇杆和扳机
      Row({ space: 16 }) {
        Column({ space: 4 }) {
          Text('左摇杆')
            .fontSize(11)
            .fontColor(AppColors.TextSecondary)
          Text(`X: ${this.formatStickValue(this.displayLSX)}`)
            .fontSize(12)
            .fontColor(AppColors.TextPrimary)
          Text(`Y: ${this.formatStickValue(this.displayLSY)}`)
            .fontSize(12)
            .fontColor(AppColors.TextPrimary)
        }
        
        Column({ space: 4 }) {
          Text('右摇杆')
            .fontSize(11)
            .fontColor(AppColors.TextSecondary)
          Text(`X: ${this.formatStickValue(this.displayRSX)}`)
            .fontSize(12)
            .fontColor(AppColors.TextPrimary)
          Text(`Y: ${this.formatStickValue(this.displayRSY)}`)
            .fontSize(12)
            .fontColor(AppColors.TextPrimary)
        }
        
        Column({ space: 4 }) {
          Text('扳机')
            .fontSize(11)
            .fontColor(AppColors.TextSecondary)
          Text(`LT: ${this.displayLT}`)
            .fontSize(12)
            .fontColor(AppColors.TextPrimary)
          Text(`RT: ${this.displayRT}`)
            .fontSize(12)
            .fontColor(AppColors.TextPrimary)
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(AppColors.Surface)
    .borderRadius(12)
  }
  
  @Builder
  buildButtonIndicator($$: ButtonIndicatorParams) {
    Text($$.name)
      .fontSize(12)
      .fontColor(($$.buttons & $$.flag) !== 0 ? AppColors.TextOnPrimary : AppColors.TextSecondary)
      .backgroundColor(($$.buttons & $$.flag) !== 0 ? AppColors.Success : AppColors.SurfaceDark)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(4)
      .margin(4)
  }
}
