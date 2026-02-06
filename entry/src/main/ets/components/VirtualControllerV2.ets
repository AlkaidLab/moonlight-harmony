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
 * 虚拟控制器组件 V2
 * 现代化设计，支持完整的游戏手柄功能
 */
import { InputEvent, InputType, ControllerButton, ControllerButtonEvent, ControllerAxis, ControllerAxisEvent } from '../model/InputEvent';
import { AnalogStick, AnalogStickConfig } from './AnalogStick';

/**
 * 虚拟控制器配置
 */
export interface VirtualControllerConfig {
  /** 透明度 (0-1) */
  opacity?: number;
  /** 按钮缩放 (0.5-2) */
  scale?: number;
  /** 是否显示左摇杆 */
  showLeftStick?: boolean;
  /** 是否显示右摇杆 */
  showRightStick?: boolean;
  /** 是否显示 D-Pad */
  showDpad?: boolean;
  /** 是否显示 ABXY */
  showButtons?: boolean;
  /** 是否显示肩键和扳机 */
  showShoulder?: boolean;
  /** 是否显示 Start/Back/Guide */
  showCenter?: boolean;
  /** 是否显示独立 L3/R3 按钮 */
  showL3R3?: boolean;
  /** 启用震动反馈 */
  enableVibration?: boolean;
  /** 摇杆死区 */
  deadzone?: number;
}

@Component
export struct VirtualControllerV2 {
  // 配置
  @Prop config: VirtualControllerConfig = {};
  
  // 回调
  onInput: (input: InputEvent) => void = () => {};
  
  // 计算后的配置值
  private controllerOpacity: number = 0.75;
  private controllerScale: number = 1.0;
  private controllerDeadzone: number = 0.15;
  
  // 按钮状态（用于多点触控）
  @State pressedButtons: Set<ControllerButton> = new Set();
  
  // 扳机状态
  @State leftTriggerActive: boolean = false;
  @State rightTriggerActive: boolean = false;

  aboutToAppear(): void {
    // 应用配置
    if (this.config.opacity !== undefined) {
      this.controllerOpacity = this.config.opacity;
    }
    if (this.config.scale !== undefined) {
      this.controllerScale = this.config.scale;
    }
    if (this.config.deadzone !== undefined) {
      this.controllerDeadzone = this.config.deadzone;
    }
  }

  build() {
    Stack() {
      // ===== 左侧区域 =====
      Column() {
        // 左摇杆
        if (this.config.showLeftStick !== false) {
          Column() {
            AnalogStick({
              config: {
                isLeftStick: true,
                outerRadius: 55 * this.controllerScale,
                innerRadius: 24 * this.controllerScale,
                deadzone: this.controllerDeadzone,
                opacity: this.controllerOpacity,
                enableClick: true
              } as AnalogStickConfig,
              onInput: (event: InputEvent) => this.onInput(event)
            })
          }
          .margin({ bottom: 20 })
        }
        
        // D-Pad
        if (this.config.showDpad !== false) {
          Column() {
            // 上
            Button() {
              Text('▲')
                .fontSize(16 * this.controllerScale)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Bold)
            }
            .width(44 * this.controllerScale)
            .height(44 * this.controllerScale)
            .backgroundColor(this.pressedButtons.has(ControllerButton.UP) ? '#5090FF' : '#000000')
            .opacity(this.pressedButtons.has(ControllerButton.UP) ? 1 : 0.6)
            .borderRadius(8)
            .border({ width: 1, color: this.pressedButtons.has(ControllerButton.UP) ? '#5090FF' : 'rgba(255,255,255,0.3)' })
            .onTouch((event) => this.handleButtonTouch(ControllerButton.UP, event))
            .margin({ bottom: 4 })

            Row({ space: 4 }) {
              // 左
              Button() {
                Text('◀')
                  .fontSize(16 * this.controllerScale)
                  .fontColor('#FFFFFF')
                  .fontWeight(FontWeight.Bold)
              }
              .width(44 * this.controllerScale)
              .height(44 * this.controllerScale)
              .backgroundColor(this.pressedButtons.has(ControllerButton.LEFT) ? '#5090FF' : '#000000')
              .opacity(this.pressedButtons.has(ControllerButton.LEFT) ? 1 : 0.6)
              .borderRadius(8)
              .border({ width: 1, color: this.pressedButtons.has(ControllerButton.LEFT) ? '#5090FF' : 'rgba(255,255,255,0.3)' })
              .onTouch((event) => this.handleButtonTouch(ControllerButton.LEFT, event))
              
              // 中心
              Circle()
                .width(36 * this.controllerScale)
                .height(36 * this.controllerScale)
                .fill('#FFFFFF')
                .fillOpacity(0.1)
              
              // 右
              Button() {
                Text('▶')
                  .fontSize(16 * this.controllerScale)
                  .fontColor('#FFFFFF')
                  .fontWeight(FontWeight.Bold)
              }
              .width(44 * this.controllerScale)
              .height(44 * this.controllerScale)
              .backgroundColor(this.pressedButtons.has(ControllerButton.RIGHT) ? '#5090FF' : '#000000')
              .opacity(this.pressedButtons.has(ControllerButton.RIGHT) ? 1 : 0.6)
              .borderRadius(8)
              .border({ width: 1, color: this.pressedButtons.has(ControllerButton.RIGHT) ? '#5090FF' : 'rgba(255,255,255,0.3)' })
              .onTouch((event) => this.handleButtonTouch(ControllerButton.RIGHT, event))
            }

            // 下
            Button() {
              Text('▼')
                .fontSize(16 * this.controllerScale)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Bold)
            }
            .width(44 * this.controllerScale)
            .height(44 * this.controllerScale)
            .backgroundColor(this.pressedButtons.has(ControllerButton.DOWN) ? '#5090FF' : '#000000')
            .opacity(this.pressedButtons.has(ControllerButton.DOWN) ? 1 : 0.6)
            .borderRadius(8)
            .border({ width: 1, color: this.pressedButtons.has(ControllerButton.DOWN) ? '#5090FF' : 'rgba(255,255,255,0.3)' })
            .onTouch((event) => this.handleButtonTouch(ControllerButton.DOWN, event))
            .margin({ top: 4 })
          }
          .opacity(this.controllerOpacity)
        }
      }
      .alignItems(HorizontalAlign.Center)
      .position({ x: 24, y: '50%' })
      .translate({ y: '-50%' })
      .hitTestBehavior(HitTestMode.Block) // 阻止触摸事件穿透到游戏画面

      // ===== 右侧区域 =====
      Column() {
        // ABXY 按钮
        if (this.config.showButtons !== false) {
          Column() {
            // Y
            this.buildActionButton('Y', ControllerButton.Y, '#FFB900')
            
            Row({ space: 6 }) {
              // X
              this.buildActionButton('X', ControllerButton.X, '#0078D4')
              // B
              this.buildActionButton('B', ControllerButton.B, '#E81123')
            }
            .margin({ top: 6 })

            // A
            Column() {
              this.buildActionButton('A', ControllerButton.A, '#107C10')
            }
            .margin({ top: 6 })
          }
          .opacity(this.controllerOpacity)
          .margin({ bottom: 20 })
        }
        
        // 右摇杆
        if (this.config.showRightStick !== false) {
          AnalogStick({
            config: {
              isLeftStick: false,
              outerRadius: 55 * this.controllerScale,
              innerRadius: 24 * this.controllerScale,
              deadzone: this.controllerDeadzone,
              opacity: this.controllerOpacity,
              enableClick: true
            } as AnalogStickConfig,
            onInput: (event: InputEvent) => this.onInput(event)
          })
        }
      }
      .alignItems(HorizontalAlign.Center)
      .position({ x: '100%', y: '50%' })
      .translate({ x: '-100%', y: '-50%' })
      .margin({ right: 24 })
      .hitTestBehavior(HitTestMode.Block) // 阻止触摸事件穿透到游戏画面

      // ===== 上方 - 肩键和扳机 =====
      if (this.config.showShoulder !== false) {
        Row() {
          // 左侧肩键组
          Column() {
            // LT
            Button() {
              Text('LT')
                .fontSize(12 * this.controllerScale)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Bold)
            }
            .width(60 * this.controllerScale)
            .height(48 * this.controllerScale)
            .backgroundColor(this.leftTriggerActive ? '#5090FF' : '#000000')
            .opacity(this.leftTriggerActive ? 1 : 0.6)
            .borderRadius(8)
            .border({ width: 1, color: this.leftTriggerActive ? '#5090FF' : 'rgba(255,255,255,0.3)' })
            .onTouch((event) => this.handleTriggerTouch(true, event))
            
            // LB
            Button() {
              Text('LB')
                .fontSize(13 * this.controllerScale)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Medium)
            }
            .width(68 * this.controllerScale)
            .height(36 * this.controllerScale)
            .backgroundColor(this.pressedButtons.has(ControllerButton.LB) ? '#5090FF' : '#000000')
            .opacity(this.pressedButtons.has(ControllerButton.LB) ? 1 : 0.6)
            .borderRadius(18 * this.controllerScale)
            .border({ width: 1, color: this.pressedButtons.has(ControllerButton.LB) ? '#5090FF' : 'rgba(255,255,255,0.3)' })
            .onTouch((event) => this.handleButtonTouch(ControllerButton.LB, event))
            .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          
          Blank()
          
          // 右侧肩键组
          Column() {
            // RT
            Button() {
              Text('RT')
                .fontSize(12 * this.controllerScale)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Bold)
            }
            .width(60 * this.controllerScale)
            .height(48 * this.controllerScale)
            .backgroundColor(this.rightTriggerActive ? '#5090FF' : '#000000')
            .opacity(this.rightTriggerActive ? 1 : 0.6)
            .borderRadius(8)
            .border({ width: 1, color: this.rightTriggerActive ? '#5090FF' : 'rgba(255,255,255,0.3)' })
            .onTouch((event) => this.handleTriggerTouch(false, event))
            
            // RB
            Button() {
              Text('RB')
                .fontSize(13 * this.controllerScale)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Medium)
            }
            .width(68 * this.controllerScale)
            .height(36 * this.controllerScale)
            .backgroundColor(this.pressedButtons.has(ControllerButton.RB) ? '#5090FF' : '#000000')
            .opacity(this.pressedButtons.has(ControllerButton.RB) ? 1 : 0.6)
            .borderRadius(18 * this.controllerScale)
            .border({ width: 1, color: this.pressedButtons.has(ControllerButton.RB) ? '#5090FF' : 'rgba(255,255,255,0.3)' })
            .onTouch((event) => this.handleButtonTouch(ControllerButton.RB, event))
            .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16 })
        .hitTestBehavior(HitTestMode.Block) // 阻止触摸事件穿透到游戏画面
      }

      // ===== 中间 - Start/Back/Guide =====
      if (this.config.showCenter !== false) {
        Row({ space: 16 }) {
          // Back 按钮
          Button() {
            Column() {
              Text('⏴')
                .fontSize(14 * this.controllerScale)
                .fontColor('#FFFFFF')
              Text('BACK')
                .fontSize(8 * this.controllerScale)
                .fontColor('#FFFFFF')
                .opacity(0.7)
            }
          }
          .width(52 * this.controllerScale)
          .height(36 * this.controllerScale)
          .backgroundColor(this.pressedButtons.has(ControllerButton.BACK) ? '#5090FF' : '#000000')
          .opacity(this.pressedButtons.has(ControllerButton.BACK) ? 1 : 0.5)
          .borderRadius(18 * this.controllerScale)
          .border({ width: 1, color: this.pressedButtons.has(ControllerButton.BACK) ? '#5090FF' : 'rgba(255,255,255,0.2)' })
          .onTouch((event) => this.handleButtonTouch(ControllerButton.BACK, event))
          
          // Guide 按钮
          Button() {
            Text('◉')
              .fontSize(20 * this.controllerScale)
              .fontColor(this.pressedButtons.has(ControllerButton.SPECIAL) ? '#FFFFFF' : '#5090FF')
          }
          .width(44 * this.controllerScale)
          .height(44 * this.controllerScale)
          .backgroundColor(this.pressedButtons.has(ControllerButton.SPECIAL) ? '#5090FF' : 'transparent')
          .borderRadius(22 * this.controllerScale)
          .border({ width: 2, color: '#5090FF' })
          .onTouch((event) => this.handleButtonTouch(ControllerButton.SPECIAL, event))
          
          // Start 按钮
          Button() {
            Column() {
              Text('⏵')
                .fontSize(14 * this.controllerScale)
                .fontColor('#FFFFFF')
              Text('START')
                .fontSize(8 * this.controllerScale)
                .fontColor('#FFFFFF')
                .opacity(0.7)
            }
          }
          .width(52 * this.controllerScale)
          .height(36 * this.controllerScale)
          .backgroundColor(this.pressedButtons.has(ControllerButton.START) ? '#5090FF' : '#000000')
          .opacity(this.pressedButtons.has(ControllerButton.START) ? 1 : 0.5)
          .borderRadius(18 * this.controllerScale)
          .border({ width: 1, color: this.pressedButtons.has(ControllerButton.START) ? '#5090FF' : 'rgba(255,255,255,0.2)' })
          .onTouch((event) => this.handleButtonTouch(ControllerButton.START, event))
        }
        .position({ x: '50%', y: '100%' })
        .translate({ x: '-50%', y: '-100%' })
        .margin({ bottom: 24 })
        .hitTestBehavior(HitTestMode.Block) // 阻止触摸事件穿透到游戏画面
      }
      
      // ===== 独立 L3/R3 按钮（可选）=====
      if (this.config.showL3R3 === true) {
        Row() {
          // L3
          Button() {
            Text('L3')
              .fontSize(12 * this.controllerScale)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Medium)
          }
          .width(48 * this.controllerScale)
          .height(32 * this.controllerScale)
          .backgroundColor(this.pressedButtons.has(ControllerButton.LS) ? '#5090FF' : '#000000')
          .opacity(this.pressedButtons.has(ControllerButton.LS) ? 1 : 0.5)
          .borderRadius(16 * this.controllerScale)
          .border({ width: 1, color: this.pressedButtons.has(ControllerButton.LS) ? '#5090FF' : 'rgba(255,255,255,0.2)' })
          .onTouch((event) => this.handleButtonTouch(ControllerButton.LS, event))
          
          Blank()
          
          // R3
          Button() {
            Text('R3')
              .fontSize(12 * this.controllerScale)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Medium)
          }
          .width(48 * this.controllerScale)
          .height(32 * this.controllerScale)
          .backgroundColor(this.pressedButtons.has(ControllerButton.RS) ? '#5090FF' : '#000000')
          .opacity(this.pressedButtons.has(ControllerButton.RS) ? 1 : 0.5)
          .borderRadius(16 * this.controllerScale)
          .border({ width: 1, color: this.pressedButtons.has(ControllerButton.RS) ? '#5090FF' : 'rgba(255,255,255,0.2)' })
          .onTouch((event) => this.handleButtonTouch(ControllerButton.RS, event))
        }
        .width('100%')
        .padding({ left: 100, right: 100 })
        .position({ y: '100%' })
        .translate({ y: '-100%' })
        .margin({ bottom: 80 })
        .hitTestBehavior(HitTestMode.Block) // 阻止触摸事件穿透到游戏画面
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  // ==================== ABXY 按钮 ====================
  @Builder
  buildActionButton(label: string, button: ControllerButton, color: string) {
    Button() {
      Text(label)
        .fontSize(18 * this.controllerScale)
        .fontColor('#FFFFFF')
        .fontWeight(FontWeight.Bold)
    }
    .width(52 * this.controllerScale)
    .height(52 * this.controllerScale)
    .backgroundColor(this.pressedButtons.has(button) ? color : this.adjustColor(color, -40))
    .borderRadius(26 * this.controllerScale)
    .shadow({
      radius: this.pressedButtons.has(button) ? 12 : 4,
      color: this.pressedButtons.has(button) ? color : 'transparent',
      offsetX: 0,
      offsetY: 2
    })
    .onTouch((event) => this.handleButtonTouch(button, event))
  }

  // ==================== 事件处理 ====================
  private handleButtonTouch(button: ControllerButton, event: TouchEvent): void {
    const isPressed = event.type === TouchType.Down;
    const isReleased = event.type === TouchType.Up || event.type === TouchType.Cancel;
    
    if (isPressed) {
      this.pressedButtons.add(button);
    } else if (isReleased) {
      this.pressedButtons.delete(button);
    } else {
      return; // Move 事件不处理
    }
    
    // 触发状态更新
    this.pressedButtons = new Set(this.pressedButtons);
    
    const inputEvent: ControllerButtonEvent = {
      type: InputType.CONTROLLER_BUTTON,
      timestamp: Date.now(),
      controllerIndex: 0,
      button: button,
      isPressed: isPressed
    };

    this.onInput(inputEvent);
    
    // 震动反馈
    if (isPressed && this.config.enableVibration !== false) {
      this.triggerVibration();
    }
  }
  
  private handleTriggerTouch(isLeft: boolean, event: TouchEvent): void {
    const isPressed = event.type === TouchType.Down;
    const isReleased = event.type === TouchType.Up || event.type === TouchType.Cancel;
    
    if (isPressed) {
      if (isLeft) {
        this.leftTriggerActive = true;
      } else {
        this.rightTriggerActive = true;
      }
    } else if (isReleased) {
      if (isLeft) {
        this.leftTriggerActive = false;
      } else {
        this.rightTriggerActive = false;
      }
    } else {
      return;
    }
    
    // 发送扳机轴事件（完全按下 = 255，释放 = 0）
    const axis = isLeft ? ControllerAxis.LEFT_TRIGGER : ControllerAxis.RIGHT_TRIGGER;
    const value = isPressed ? 255 : 0;
    
    const axisEvent: ControllerAxisEvent = {
      type: InputType.CONTROLLER_AXIS,
      timestamp: Date.now(),
      controllerIndex: 0,
      axis: axis,
      value: value
    };
    
    this.onInput(axisEvent);
    
    // 震动反馈
    if (isPressed && this.config.enableVibration !== false) {
      this.triggerVibration();
    }
  }
  
  private triggerVibration(): void {
    try {
      // HarmonyOS 震动 API
      // import { vibrator } from '@kit.SensorServiceKit';
      // vibrator.startVibration({ type: 'time', duration: 30 });
    } catch (e) {
      // 忽略震动错误
    }
  }
  
  /**
   * 调整颜色亮度
   */
  private adjustColor(hex: string, amount: number): string {
    // 简单的颜色调整
    let color = hex.replace('#', '');
    let r = parseInt(color.substring(0, 2), 16);
    let g = parseInt(color.substring(2, 4), 16);
    let b = parseInt(color.substring(4, 6), 16);
    
    r = Math.max(0, Math.min(255, r + amount));
    g = Math.max(0, Math.min(255, g + amount));
    b = Math.max(0, Math.min(255, b + amount));
    
    return '#' + 
      r.toString(16).padStart(2, '0') +
      g.toString(16).padStart(2, '0') +
      b.toString(16).padStart(2, '0');
  }
}
