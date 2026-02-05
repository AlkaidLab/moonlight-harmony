/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { InputEvent, InputType, ControllerButton, ControllerButtonEvent } from '../model/InputEvent';

/**
 * 虚拟控制器组件
 */
@Component
export struct VirtualController {
  onInput: (input: InputEvent) => void = () => {};
  
  @State showDpad: boolean = true;
  @State showButtons: boolean = true;
  @State showTriggers: boolean = true;
  @State controllerOpacity: number = 0.6;

  build() {
    Stack() {
      // 左侧 - 方向键/摇杆
      if (this.showDpad) {
        Column() {
          this.DPad()
        }
        .position({ x: 32, y: '50%' })
        .translate({ y: '-50%' })
      }

      // 右侧 - ABXY 按钮
      if (this.showButtons) {
        Column() {
          this.ActionButtons()
        }
        .position({ x: '100%', y: '50%' })
        .translate({ x: '-100%', y: '-50%' })
        .margin({ right: 32 })
      }

      // 上方 - 肩键和扳机
      if (this.showTriggers) {
        Row() {
          this.ShoulderButton('LB', ControllerButton.LB)
          this.TriggerButton('LT')
          Blank()
          this.TriggerButton('RT')
          this.ShoulderButton('RB', ControllerButton.RB)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .position({ y: 16 })
      }

      // 中间 - Start/Back
      Row() {
        this.SmallButton('BACK', ControllerButton.BACK)
        Blank().width(80)
        this.SmallButton('START', ControllerButton.START)
      }
      .position({ x: '50%', y: '100%' })
      .translate({ x: '-50%', y: '-100%' })
      .margin({ bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  DPad() {
    Column() {
      // 上
      Column() {
        this.DPadButton('↑', ControllerButton.UP)
      }
      .margin({ bottom: 4 })

      Row() {
        // 左
        Column() {
          this.DPadButton('←', ControllerButton.LEFT)
        }
        .margin({ right: 4 })

        // 中心
        Circle()
          .width(40)
          .height(40)
          .fill('#33ffffff')

        // 右
        Column() {
          this.DPadButton('→', ControllerButton.RIGHT)
        }
        .margin({ left: 4 })
      }

      // 下
      Column() {
        this.DPadButton('↓', ControllerButton.DOWN)
      }
      .margin({ top: 4 })
    }
    .opacity(this.controllerOpacity)
  }

  @Builder
  DPadButton(label: string, button: ControllerButton) {
    Button(label)
      .width(48)
      .height(48)
      .fontSize(20)
      .fontColor(Color.White)
      .backgroundColor('#66000000')
      .borderRadius(8)
      .onTouch((event) => {
        this.handleButtonTouch(button, event);
      })
  }

  @Builder
  ActionButtons() {
    Column() {
      // Y
      Column() {
        this.ActionButton('Y', ControllerButton.Y, '#FFCC00')
      }
      .margin({ bottom: 8 })

      Row() {
        // X
        Column() {
          this.ActionButton('X', ControllerButton.X, '#0066FF')
        }
        .margin({ right: 8 })

        // B
        Column() {
          this.ActionButton('B', ControllerButton.B, '#FF3300')
        }
        .margin({ left: 8 })
      }

      // A
      Column() {
        this.ActionButton('A', ControllerButton.A, '#00CC00')
      }
      .margin({ top: 8 })
    }
    .opacity(this.controllerOpacity)
  }

  @Builder
  ActionButton(label: string, button: ControllerButton, color: string) {
    Button(label)
      .width(56)
      .height(56)
      .fontSize(20)
      .fontWeight(FontWeight.Bold)
      .fontColor(Color.White)
      .backgroundColor(color)
      .borderRadius(28)
      .opacity(0.8)
      .onTouch((event) => {
        this.handleButtonTouch(button, event);
      })
  }

  @Builder
  ShoulderButton(label: string, button: ControllerButton) {
    Button(label)
      .width(72)
      .height(40)
      .fontSize(14)
      .fontColor(Color.White)
      .backgroundColor('#66000000')
      .borderRadius(8)
      .opacity(this.controllerOpacity)
      .onTouch((event) => {
        this.handleButtonTouch(button, event);
      })
  }

  @Builder
  TriggerButton(label: string) {
    Button(label)
      .width(56)
      .height(48)
      .fontSize(14)
      .fontColor(Color.White)
      .backgroundColor('#66000000')
      .borderRadius(8)
      .opacity(this.controllerOpacity)
      .onTouch((event) => {
        // TODO: 处理扳机（模拟量）输入
      })
  }

  @Builder
  SmallButton(label: string, button: ControllerButton) {
    Button(label)
      .width(64)
      .height(32)
      .fontSize(12)
      .fontColor(Color.White)
      .backgroundColor('#66000000')
      .borderRadius(16)
      .opacity(this.controllerOpacity)
      .onTouch((event) => {
        this.handleButtonTouch(button, event);
      })
  }

  handleButtonTouch(button: ControllerButton, event: TouchEvent): void {
    const isPressed = event.type === TouchType.Down;
    
    const inputEvent: ControllerButtonEvent = {
      type: InputType.CONTROLLER_BUTTON,
      timestamp: Date.now(),
      controllerIndex: 0,
      button: button,
      isPressed: isPressed
    };

    this.onInput(inputEvent);
  }
}
