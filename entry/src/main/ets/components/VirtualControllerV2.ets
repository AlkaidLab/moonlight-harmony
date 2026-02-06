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
import { vibrator } from '@kit.SensorServiceKit';

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

  // 辅助方法：给 6 位 hex 颜色添加 alpha 前缀（ArkUI 使用 #AARRGGBB 格式）
  private withAlpha(color: string, alpha: number): string {
    const hex = Math.round(alpha * 255).toString(16).padStart(2, '0');
    return '#' + hex + color.substring(1);
  }

  build() {
    // 使用 Column + Row 标准 flex 布局
    // 确保所有子组件正确参与 ArkUI 触摸测试树
    Column() {
      // ===== 上方 - 肩键和扳机 =====
      if (this.config.showShoulder !== false) {
        Row() {
          // 左侧肩键组
          Column({ space: 6 }) {
            // LT
            Button() {
              Text('LT')
                .fontSize(12 * this.controllerScale)
                .fontColor(this.leftTriggerActive ? '#FFFFFF' : this.withAlpha('#FFFFFF', 0.5))
                .fontWeight(FontWeight.Bold)
            }
            .width(60 * this.controllerScale)
            .height(44 * this.controllerScale)
            .backgroundColor(this.leftTriggerActive ? this.withAlpha('#5090FF', 0.4) : Color.Transparent)
            .borderRadius(12)
            .border({ width: 1, color: this.leftTriggerActive ? this.withAlpha('#5090FF', 0.6) : this.withAlpha('#FFFFFF', 0.15) })
            .onTouch((event) => this.handleTriggerTouch(true, event))

            // LB
            Button() {
              Text('LB')
                .fontSize(12 * this.controllerScale)
                .fontColor(this.pressedButtons.has(ControllerButton.LB) ? '#FFFFFF' : this.withAlpha('#FFFFFF', 0.5))
                .fontWeight(FontWeight.Medium)
            }
            .width(64 * this.controllerScale)
            .height(34 * this.controllerScale)
            .backgroundColor(this.pressedButtons.has(ControllerButton.LB) ? this.withAlpha('#5090FF', 0.4) : Color.Transparent)
            .borderRadius(17 * this.controllerScale)
            .border({ width: 1, color: this.pressedButtons.has(ControllerButton.LB) ? this.withAlpha('#5090FF', 0.6) : this.withAlpha('#FFFFFF', 0.15) })
            .onTouch((event) => this.handleButtonTouch(ControllerButton.LB, event))
          }
          .alignItems(HorizontalAlign.Start)

          Blank()

          // 右侧肩键组
          Column({ space: 6 }) {
            // RT
            Button() {
              Text('RT')
                .fontSize(12 * this.controllerScale)
                .fontColor(this.rightTriggerActive ? '#FFFFFF' : this.withAlpha('#FFFFFF', 0.5))
                .fontWeight(FontWeight.Bold)
            }
            .width(60 * this.controllerScale)
            .height(44 * this.controllerScale)
            .backgroundColor(this.rightTriggerActive ? this.withAlpha('#5090FF', 0.4) : Color.Transparent)
            .borderRadius(12)
            .border({ width: 1, color: this.rightTriggerActive ? this.withAlpha('#5090FF', 0.6) : this.withAlpha('#FFFFFF', 0.15) })
            .onTouch((event) => this.handleTriggerTouch(false, event))

            // RB
            Button() {
              Text('RB')
                .fontSize(12 * this.controllerScale)
                .fontColor(this.pressedButtons.has(ControllerButton.RB) ? '#FFFFFF' : this.withAlpha('#FFFFFF', 0.5))
                .fontWeight(FontWeight.Medium)
            }
            .width(64 * this.controllerScale)
            .height(34 * this.controllerScale)
            .backgroundColor(this.pressedButtons.has(ControllerButton.RB) ? this.withAlpha('#5090FF', 0.4) : Color.Transparent)
            .borderRadius(17 * this.controllerScale)
            .border({ width: 1, color: this.pressedButtons.has(ControllerButton.RB) ? this.withAlpha('#5090FF', 0.6) : this.withAlpha('#FFFFFF', 0.15) })
            .onTouch((event) => this.handleButtonTouch(ControllerButton.RB, event))
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16 })
      }

      // ===== 中间区域 - 左摇杆+D-Pad / ABXY+右摇杆 =====
      Row() {
        // 左侧：左摇杆 + D-Pad
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
            .margin({ bottom: 16 })
          }

          // D-Pad（可爱十字键造型）
          if (this.config.showDpad !== false) {
            this.buildCrossDpad()
          }
        }
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .padding({ left: 24 })

        Blank()

        // 右侧：ABXY + 右摇杆
        Column() {
          // ABXY 按钮
          if (this.config.showButtons !== false) {
            Column() {
              // Y
              this.buildActionButton('Y', ControllerButton.Y, '#FFB900')

              Row({ space: 8 }) {
                // X
                this.buildActionButton('X', ControllerButton.X, '#4BA3E3')
                // B
                this.buildActionButton('B', ControllerButton.B, '#E87070')
              }
              .margin({ top: 8 })

              // A
              Column() {
                this.buildActionButton('A', ControllerButton.A, '#50C878')
              }
              .margin({ top: 8 })
            }
            .margin({ bottom: 16 })
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
        .justifyContent(FlexAlign.Center)
        .padding({ right: 24 })
      }
      .width('100%')
      .layoutWeight(1)

      // ===== 底部 - Start/Back/Guide =====
      if (this.config.showCenter !== false) {
        Row({ space: 12 }) {
          // Back
          this.buildCenterButton('◂', 'BACK', ControllerButton.BACK)

          // Guide
          Button() {
            Text('◉')
              .fontSize(18 * this.controllerScale)
              .fontColor(this.pressedButtons.has(ControllerButton.SPECIAL) ? '#FFFFFF' : this.withAlpha('#7EB8E0', 0.6))
          }
          .width(42 * this.controllerScale)
          .height(42 * this.controllerScale)
          .backgroundColor(this.pressedButtons.has(ControllerButton.SPECIAL) ? this.withAlpha('#5090FF', 0.4) : Color.Transparent)
          .borderRadius(21 * this.controllerScale)
          .border({ width: 1.5, color: this.pressedButtons.has(ControllerButton.SPECIAL) ? '#5090FF' : this.withAlpha('#7EB8E0', 0.25) })
          .onTouch((event) => this.handleButtonTouch(ControllerButton.SPECIAL, event))

          // Start
          this.buildCenterButton('▸', 'START', ControllerButton.START)
        }
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: 20 })
      }

      // ===== 独立 L3/R3 按钮（可选）=====
      if (this.config.showL3R3 === true) {
        Row() {
          this.buildSmallButton('L3', ControllerButton.LS)
          Blank()
          this.buildSmallButton('R3', ControllerButton.RS)
        }
        .width('100%')
        .padding({ left: 100, right: 100 })
        .margin({ bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Default)
    .onTouch(() => {})
  }

  // ==================== ABXY 按钮（全透明 + 彩色边框）====================
  @Builder
  buildActionButton(label: string, button: ControllerButton, color: string) {
    Button() {
      Text(label)
        .fontSize(17 * this.controllerScale)
        .fontColor(this.pressedButtons.has(button) ? '#FFFFFF' : this.withAlpha(color, 0.7))
        .fontWeight(FontWeight.Bold)
    }
    .width(48 * this.controllerScale)
    .height(48 * this.controllerScale)
    .backgroundColor(this.pressedButtons.has(button) ? this.withAlpha(color, 0.35) : Color.Transparent)
    .borderRadius(24 * this.controllerScale)
    .border({ width: 1.5, color: this.pressedButtons.has(button) ? color : this.withAlpha(color, 0.35) })
    .shadow({
      radius: this.pressedButtons.has(button) ? 8 : 0,
      color: this.pressedButtons.has(button) ? this.withAlpha(color, 0.3) : 'transparent',
      offsetX: 0,
      offsetY: 0
    })
    .onTouch((event) => this.handleButtonTouch(button, event))
  }

  // ==================== 十字键（Cross D-Pad）====================
  @Builder
  buildCrossDpad() {
    // 十字键：3x3 网格，只填充十字位置，外角圆润
    // 每个格子 36x36，间距 1px
    Column() {
      // 第一行：空 | 上 | 空
      Row() {
        Column().width(36 * this.controllerScale).height(36 * this.controllerScale)
        Column() {
          Text('▴')
            .fontSize(14 * this.controllerScale)
            .fontColor(this.pressedButtons.has(ControllerButton.UP) ? '#FFFFFF' : this.withAlpha('#FFFFFF', 0.5))
            .fontWeight(FontWeight.Bold)
        }
        .width(36 * this.controllerScale)
        .height(36 * this.controllerScale)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.pressedButtons.has(ControllerButton.UP) ? this.withAlpha('#5090FF', 0.35) : Color.Transparent)
        .borderRadius({ topLeft: 14, topRight: 14, bottomLeft: 0, bottomRight: 0 })
        .border({
          width: { top: 1, left: 1, right: 1, bottom: 0 },
          color: this.pressedButtons.has(ControllerButton.UP) ? this.withAlpha('#5090FF', 0.6) : this.withAlpha('#FFFFFF', 0.18)
        })
        .onTouch((event) => this.handleButtonTouch(ControllerButton.UP, event))

        Column().width(36 * this.controllerScale).height(36 * this.controllerScale)
      }

      // 第二行：左 | 中心 | 右
      Row() {
        Column() {
          Text('◂')
            .fontSize(14 * this.controllerScale)
            .fontColor(this.pressedButtons.has(ControllerButton.LEFT) ? '#FFFFFF' : this.withAlpha('#FFFFFF', 0.5))
            .fontWeight(FontWeight.Bold)
        }
        .width(36 * this.controllerScale)
        .height(36 * this.controllerScale)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.pressedButtons.has(ControllerButton.LEFT) ? this.withAlpha('#5090FF', 0.35) : Color.Transparent)
        .borderRadius({ topLeft: 14, topRight: 0, bottomLeft: 14, bottomRight: 0 })
        .border({
          width: { top: 1, left: 1, right: 0, bottom: 1 },
          color: this.pressedButtons.has(ControllerButton.LEFT) ? this.withAlpha('#5090FF', 0.6) : this.withAlpha('#FFFFFF', 0.18)
        })
        .onTouch((event) => this.handleButtonTouch(ControllerButton.LEFT, event))

        // 中心格（十字交叉点）
        Column() {
          Circle()
            .width(8 * this.controllerScale)
            .height(8 * this.controllerScale)
            .fill('#FFFFFF')
            .fillOpacity(0.12)
        }
        .width(36 * this.controllerScale)
        .height(36 * this.controllerScale)
        .justifyContent(FlexAlign.Center)
        .border({
          width: { top: 0, left: 0, right: 0, bottom: 0 },
          color: this.withAlpha('#FFFFFF', 0.18)
        })

        Column() {
          Text('▸')
            .fontSize(14 * this.controllerScale)
            .fontColor(this.pressedButtons.has(ControllerButton.RIGHT) ? '#FFFFFF' : this.withAlpha('#FFFFFF', 0.5))
            .fontWeight(FontWeight.Bold)
        }
        .width(36 * this.controllerScale)
        .height(36 * this.controllerScale)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.pressedButtons.has(ControllerButton.RIGHT) ? this.withAlpha('#5090FF', 0.35) : Color.Transparent)
        .borderRadius({ topLeft: 0, topRight: 14, bottomLeft: 0, bottomRight: 14 })
        .border({
          width: { top: 1, left: 0, right: 1, bottom: 1 },
          color: this.pressedButtons.has(ControllerButton.RIGHT) ? this.withAlpha('#5090FF', 0.6) : this.withAlpha('#FFFFFF', 0.18)
        })
        .onTouch((event) => this.handleButtonTouch(ControllerButton.RIGHT, event))
      }

      // 第三行：空 | 下 | 空
      Row() {
        Column().width(36 * this.controllerScale).height(36 * this.controllerScale)
        Column() {
          Text('▾')
            .fontSize(14 * this.controllerScale)
            .fontColor(this.pressedButtons.has(ControllerButton.DOWN) ? '#FFFFFF' : this.withAlpha('#FFFFFF', 0.5))
            .fontWeight(FontWeight.Bold)
        }
        .width(36 * this.controllerScale)
        .height(36 * this.controllerScale)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.pressedButtons.has(ControllerButton.DOWN) ? this.withAlpha('#5090FF', 0.35) : Color.Transparent)
        .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 14, bottomRight: 14 })
        .border({
          width: { top: 0, left: 1, right: 1, bottom: 1 },
          color: this.pressedButtons.has(ControllerButton.DOWN) ? this.withAlpha('#5090FF', 0.6) : this.withAlpha('#FFFFFF', 0.18)
        })
        .onTouch((event) => this.handleButtonTouch(ControllerButton.DOWN, event))

        Column().width(36 * this.controllerScale).height(36 * this.controllerScale)
      }
    }
  }

  // ==================== 中间功能键（Back/Start）====================
  @Builder
  buildCenterButton(icon: string, label: string, button: ControllerButton) {
    Button() {
      Row({ space: 4 }) {
        Text(icon)
          .fontSize(13 * this.controllerScale)
          .fontColor(this.pressedButtons.has(button) ? '#FFFFFF' : this.withAlpha('#FFFFFF', 0.4))
        Text(label)
          .fontSize(8 * this.controllerScale)
          .fontColor(this.pressedButtons.has(button) ? '#FFFFFF' : this.withAlpha('#FFFFFF', 0.4))
          .fontWeight(FontWeight.Medium)
      }
    }
    .height(34 * this.controllerScale)
    .padding({ left: 10, right: 10 })
    .backgroundColor(this.pressedButtons.has(button) ? this.withAlpha('#5090FF', 0.4) : Color.Transparent)
    .borderRadius(17 * this.controllerScale)
    .border({ width: 1, color: this.pressedButtons.has(button) ? this.withAlpha('#5090FF', 0.6) : this.withAlpha('#FFFFFF', 0.12) })
    .onTouch((event) => this.handleButtonTouch(button, event))
  }

  // ==================== L3/R3 小按钮 ====================
  @Builder
  buildSmallButton(label: string, button: ControllerButton) {
    Button() {
      Text(label)
        .fontSize(11 * this.controllerScale)
        .fontColor(this.pressedButtons.has(button) ? '#FFFFFF' : this.withAlpha('#FFFFFF', 0.4))
        .fontWeight(FontWeight.Medium)
    }
    .width(44 * this.controllerScale)
    .height(30 * this.controllerScale)
    .backgroundColor(this.pressedButtons.has(button) ? this.withAlpha('#5090FF', 0.4) : Color.Transparent)
    .borderRadius(15 * this.controllerScale)
    .border({ width: 1, color: this.pressedButtons.has(button) ? this.withAlpha('#5090FF', 0.6) : this.withAlpha('#FFFFFF', 0.12) })
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
      vibrator.startVibration({
        type: 'time',
        duration: 30
      }, {
        id: 0,
        usage: 'touch'
      });
    } catch (e) {
      // 忽略震动错误
    }
  }
  
}
