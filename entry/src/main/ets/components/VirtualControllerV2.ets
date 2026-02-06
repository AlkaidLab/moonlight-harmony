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
  private opacity: number = 0.75;
  private scale: number = 1.0;
  private deadzone: number = 0.15;
  
  // 按钮状态（用于多点触控）
  @State pressedButtons: Set<ControllerButton> = new Set();
  
  // 扳机状态
  @State leftTriggerActive: boolean = false;
  @State rightTriggerActive: boolean = false;

  aboutToAppear(): void {
    // 应用配置
    if (this.config.opacity !== undefined) {
      this.opacity = this.config.opacity;
    }
    if (this.config.scale !== undefined) {
      this.scale = this.config.scale;
    }
    if (this.config.deadzone !== undefined) {
      this.deadzone = this.config.deadzone;
    }
  }

  build() {
    Stack() {
      // ===== 左侧区域 =====
      Column() {
        // 左摇杆
        if (this.config.showLeftStick !== false) {
          AnalogStick({
            config: {
              isLeftStick: true,
              outerRadius: 55 * this.scale,
              innerRadius: 24 * this.scale,
              deadzone: this.deadzone,
              opacity: this.opacity,
              enableClick: true
            } as AnalogStickConfig,
            onInput: (event: InputEvent) => this.onInput(event)
          })
          .margin({ bottom: 20 })
        }
        
        // D-Pad
        if (this.config.showDpad !== false) {
          this.DPad()
        }
      }
      .alignItems(HorizontalAlign.Center)
      .position({ x: 24, y: '50%' })
      .translate({ y: '-50%' })

      // ===== 右侧区域 =====
      Column() {
        // ABXY 按钮
        if (this.config.showButtons !== false) {
          this.ActionButtons()
            .margin({ bottom: 20 })
        }
        
        // 右摇杆
        if (this.config.showRightStick !== false) {
          AnalogStick({
            config: {
              isLeftStick: false,
              outerRadius: 55 * this.scale,
              innerRadius: 24 * this.scale,
              deadzone: this.deadzone,
              opacity: this.opacity,
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

      // ===== 上方 - 肩键和扳机 =====
      if (this.config.showShoulder !== false) {
        Row() {
          // 左侧肩键组
          Column() {
            this.TriggerButton('LT', true)
            this.ShoulderButton('LB', ControllerButton.LB)
          }
          .alignItems(HorizontalAlign.Start)
          
          Blank()
          
          // 右侧肩键组
          Column() {
            this.TriggerButton('RT', false)
            this.ShoulderButton('RB', ControllerButton.RB)
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16 })
      }

      // ===== 中间 - Start/Back/Guide =====
      if (this.config.showCenter !== false) {
        Row({ space: 16 }) {
          // Back 按钮
          this.CenterButton('⏴', ControllerButton.BACK, 'BACK')
          
          // Guide 按钮
          this.GuideButton()
          
          // Start 按钮
          this.CenterButton('⏵', ControllerButton.START, 'START')
        }
        .position({ x: '50%', y: '100%' })
        .translate({ x: '-50%', y: '-100%' })
        .margin({ bottom: 24 })
      }
      
      // ===== 独立 L3/R3 按钮（可选）=====
      if (this.config.showL3R3 === true) {
        Row() {
          this.L3R3Button('L3', ControllerButton.LS)
          Blank()
          this.L3R3Button('R3', ControllerButton.RS)
        }
        .width('100%')
        .padding({ left: 100, right: 100 })
        .position({ y: '100%' })
        .translate({ y: '-100%' })
        .margin({ bottom: 80 })
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  // ==================== D-Pad ====================
  @Builder
  DPad() {
    Column() {
      // 上
      this.DPadButton('▲', ControllerButton.UP)
        .margin({ bottom: 4 })

      Row({ space: 4 }) {
        // 左
        this.DPadButton('◀', ControllerButton.LEFT)
        
        // 中心
        Circle()
          .width(36 * this.scale)
          .height(36 * this.scale)
          .fill('#FFFFFF')
          .fillOpacity(0.1)
        
        // 右
        this.DPadButton('▶', ControllerButton.RIGHT)
      }

      // 下
      this.DPadButton('▼', ControllerButton.DOWN)
        .margin({ top: 4 })
    }
    .opacity(this.opacity)
  }

  @Builder
  DPadButton(icon: string, button: ControllerButton) {
    Button() {
      Text(icon)
        .fontSize(16 * this.scale)
        .fontColor('#FFFFFF')
        .fontWeight(FontWeight.Bold)
    }
    .width(44 * this.scale)
    .height(44 * this.scale)
    .backgroundColor(this.pressedButtons.has(button) ? '#5090FF' : '#000000')
    .backgroundBlurStyle(BlurStyle.Regular)
    .opacity(this.pressedButtons.has(button) ? 1 : 0.6)
    .borderRadius(8)
    .border({ width: 1, color: '#FFFFFF', style: BorderStyle.Solid })
    .borderColor(this.pressedButtons.has(button) ? '#5090FF' : 'rgba(255,255,255,0.3)')
    .onTouch((event) => this.handleButtonTouch(button, event))
  }

  // ==================== ABXY 按钮 ====================
  @Builder
  ActionButtons() {
    Column() {
      // Y
      this.ActionButton('Y', ControllerButton.Y, '#FFB900')
        .margin({ bottom: 6 })

      Row({ space: 6 }) {
        // X
        this.ActionButton('X', ControllerButton.X, '#0078D4')
        // B
        this.ActionButton('B', ControllerButton.B, '#E81123')
      }

      // A
      this.ActionButton('A', ControllerButton.A, '#107C10')
        .margin({ top: 6 })
    }
    .opacity(this.opacity)
  }

  @Builder
  ActionButton(label: string, button: ControllerButton, color: string) {
    Button() {
      Text(label)
        .fontSize(18 * this.scale)
        .fontColor('#FFFFFF')
        .fontWeight(FontWeight.Bold)
    }
    .width(52 * this.scale)
    .height(52 * this.scale)
    .backgroundColor(this.pressedButtons.has(button) ? color : this.adjustColor(color, -40))
    .borderRadius(26 * this.scale)
    .shadow({
      radius: this.pressedButtons.has(button) ? 12 : 4,
      color: this.pressedButtons.has(button) ? color : 'transparent',
      offsetX: 0,
      offsetY: 2
    })
    .scale({ x: this.pressedButtons.has(button) ? 0.92 : 1, y: this.pressedButtons.has(button) ? 0.92 : 1 })
    .animation({ duration: 50 })
    .onTouch((event) => this.handleButtonTouch(button, event))
  }

  // ==================== 肩键 ====================
  @Builder
  ShoulderButton(label: string, button: ControllerButton) {
    Button() {
      Text(label)
        .fontSize(13 * this.scale)
        .fontColor('#FFFFFF')
        .fontWeight(FontWeight.Medium)
    }
    .width(68 * this.scale)
    .height(36 * this.scale)
    .backgroundColor(this.pressedButtons.has(button) ? '#5090FF' : '#000000')
    .backgroundBlurStyle(BlurStyle.Regular)
    .opacity(this.pressedButtons.has(button) ? 1 : 0.6)
    .borderRadius(18 * this.scale)
    .border({ width: 1, color: this.pressedButtons.has(button) ? '#5090FF' : 'rgba(255,255,255,0.3)' })
    .margin({ top: 4 })
    .onTouch((event) => this.handleButtonTouch(button, event))
  }

  // ==================== 扳机 ====================
  @Builder
  TriggerButton(label: string, isLeft: boolean) {
    Button() {
      Column() {
        Text(label)
          .fontSize(12 * this.scale)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Bold)
        
        // 扳机进度条
        Row()
          .width('80%')
          .height(4)
          .backgroundColor('#333333')
          .borderRadius(2)
        Row()
          .width((isLeft ? this.leftTriggerActive : this.rightTriggerActive) ? '80%' : '0%')
          .height(4)
          .backgroundColor('#5090FF')
          .borderRadius(2)
          .position({ x: '10%', y: 0 })
          .animation({ duration: 50 })
      }
      .justifyContent(FlexAlign.Center)
    }
    .width(60 * this.scale)
    .height(48 * this.scale)
    .backgroundColor((isLeft ? this.leftTriggerActive : this.rightTriggerActive) ? '#5090FF' : '#000000')
    .backgroundBlurStyle(BlurStyle.Regular)
    .opacity((isLeft ? this.leftTriggerActive : this.rightTriggerActive) ? 1 : 0.6)
    .borderRadius(8)
    .border({ width: 1, color: (isLeft ? this.leftTriggerActive : this.rightTriggerActive) ? '#5090FF' : 'rgba(255,255,255,0.3)' })
    .onTouch((event) => this.handleTriggerTouch(isLeft, event))
  }

  // ==================== 中间按钮 ====================
  @Builder
  CenterButton(icon: string, button: ControllerButton, label: string) {
    Button() {
      Column() {
        Text(icon)
          .fontSize(14 * this.scale)
          .fontColor('#FFFFFF')
        Text(label)
          .fontSize(8 * this.scale)
          .fontColor('#FFFFFF')
          .opacity(0.7)
      }
    }
    .width(52 * this.scale)
    .height(36 * this.scale)
    .backgroundColor(this.pressedButtons.has(button) ? '#5090FF' : '#000000')
    .backgroundBlurStyle(BlurStyle.Regular)
    .opacity(this.pressedButtons.has(button) ? 1 : 0.5)
    .borderRadius(18 * this.scale)
    .border({ width: 1, color: this.pressedButtons.has(button) ? '#5090FF' : 'rgba(255,255,255,0.2)' })
    .onTouch((event) => this.handleButtonTouch(button, event))
  }
  
  @Builder
  GuideButton() {
    Button() {
      Text('◉')
        .fontSize(20 * this.scale)
        .fontColor(this.pressedButtons.has(ControllerButton.SPECIAL) ? '#FFFFFF' : '#5090FF')
    }
    .width(44 * this.scale)
    .height(44 * this.scale)
    .backgroundColor(this.pressedButtons.has(ControllerButton.SPECIAL) ? '#5090FF' : 'transparent')
    .borderRadius(22 * this.scale)
    .border({ width: 2, color: '#5090FF' })
    .onTouch((event) => this.handleButtonTouch(ControllerButton.SPECIAL, event))
  }
  
  @Builder
  L3R3Button(label: string, button: ControllerButton) {
    Button() {
      Text(label)
        .fontSize(12 * this.scale)
        .fontColor('#FFFFFF')
        .fontWeight(FontWeight.Medium)
    }
    .width(48 * this.scale)
    .height(32 * this.scale)
    .backgroundColor(this.pressedButtons.has(button) ? '#5090FF' : '#000000')
    .backgroundBlurStyle(BlurStyle.Regular)
    .opacity(this.pressedButtons.has(button) ? 1 : 0.5)
    .borderRadius(16 * this.scale)
    .border({ width: 1, color: this.pressedButtons.has(button) ? '#5090FF' : 'rgba(255,255,255,0.2)' })
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
