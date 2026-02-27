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
 * 虚拟控制器组件
 * 现代化设计，支持完整的游戏手柄功能
 */
import { InputEvent, InputType, ControllerButton, ControllerButtonEvent, ControllerAxis, ControllerAxisEvent } from '../model/InputEvent';
import { AnalogStick, AnalogStickConfig } from './AnalogStick';
import { vibrator } from '@kit.SensorServiceKit';
import { PreferencesUtil } from '../utils/PreferencesUtil';

const SCALE_KEY = 'virtual_controller_scale';
const OPACITY_KEY = 'virtual_controller_opacity';

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
export struct VirtualController {
  // 配置（普通属性，不使用 @Prop，避免父组件重渲染时因新对象引用触发子组件不必要的更新）
  config: VirtualControllerConfig = {};

  // 回调
  onInput: (input: InputEvent) => void = () => {};

  /** 触摸穿透模式 */
  touchPassthrough: boolean = false;

  /** 按钮缩放比例（由父组件驱动） */
  @Prop controllerScale: number = 1.0;

  // 计算后的配置值
  private controllerOpacity: number = 0.75;
  private controllerDeadzone: number = 0.15;

  aboutToAppear(): void {
    // 应用配置
    if (this.config.opacity !== undefined) {
      this.controllerOpacity = this.config.opacity;
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
            Column() {
              Text('LT')
                .fontSize(12 * this.controllerScale)
                .fontColor(this.withAlpha('#FFFFFF', 0.5))
                .fontWeight(FontWeight.Bold)
            }
            .width(60 * this.controllerScale)
            .height(44 * this.controllerScale)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Color.Transparent)
            .borderRadius(12)
            .border({ width: 1, color: this.withAlpha('#FFFFFF', 0.15) })
            .hitTestBehavior(HitTestMode.Block)
            .onTouch((event: TouchEvent) => this.handleTriggerTouch(true, event))

            // LB
            Column() {
              Text('LB')
                .fontSize(12 * this.controllerScale)
                .fontColor(this.withAlpha('#FFFFFF', 0.5))
                .fontWeight(FontWeight.Medium)
            }
            .width(64 * this.controllerScale)
            .height(34 * this.controllerScale)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Color.Transparent)
            .borderRadius(17 * this.controllerScale)
            .border({ width: 1, color: this.withAlpha('#FFFFFF', 0.15) })
            .hitTestBehavior(HitTestMode.Block)
            .onTouch((event: TouchEvent) => this.handleButtonTouch(ControllerButton.LB, event))
          }
          .alignItems(HorizontalAlign.Start)

          Blank()

          // 右侧肩键组
          Column({ space: 6 }) {
            // RT
            Column() {
              Text('RT')
                .fontSize(12 * this.controllerScale)
                .fontColor(this.withAlpha('#FFFFFF', 0.5))
                .fontWeight(FontWeight.Bold)
            }
            .width(60 * this.controllerScale)
            .height(44 * this.controllerScale)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Color.Transparent)
            .borderRadius(12)
            .border({ width: 1, color: this.withAlpha('#FFFFFF', 0.15) })
            .hitTestBehavior(HitTestMode.Block)
            .onTouch((event: TouchEvent) => this.handleTriggerTouch(false, event))

            // RB
            Column() {
              Text('RB')
                .fontSize(12 * this.controllerScale)
                .fontColor(this.withAlpha('#FFFFFF', 0.5))
                .fontWeight(FontWeight.Medium)
            }
            .width(64 * this.controllerScale)
            .height(34 * this.controllerScale)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Color.Transparent)
            .borderRadius(17 * this.controllerScale)
            .border({ width: 1, color: this.withAlpha('#FFFFFF', 0.15) })
            .hitTestBehavior(HitTestMode.Block)
            .onTouch((event: TouchEvent) => this.handleButtonTouch(ControllerButton.RB, event))
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

      // ===== 底部 - Start/Back/Guide =====
      if (this.config.showCenter !== false) {
        Row({ space: 12 }) {
          // Back
          this.buildCenterButton('◂', 'BACK', ControllerButton.BACK)

          // Guide
          Column() {
            Text('◉')
              .fontSize(18 * this.controllerScale)
              .fontColor(this.withAlpha('#7EB8E0', 0.6))
          }
          .width(42 * this.controllerScale)
          .height(42 * this.controllerScale)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Color.Transparent)
          .borderRadius(21 * this.controllerScale)
          .border({ width: 1.5, color: this.withAlpha('#7EB8E0', 0.25) })
          .hitTestBehavior(HitTestMode.Block)
          .onTouch((event: TouchEvent) => this.handleButtonTouch(ControllerButton.SPECIAL, event))

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
    .justifyContent(FlexAlign.End)
  }

  // ==================== ABXY 按钮（全透明 + 彩色边框）====================
  @Builder
  buildActionButton(label: string, button: ControllerButton, color: string) {
    Column() {
      Text(label)
        .fontSize(17 * this.controllerScale)
        .fontColor(this.withAlpha(color, 0.7))
        .fontWeight(FontWeight.Bold)
    }
    .width(48 * this.controllerScale)
    .height(48 * this.controllerScale)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Color.Transparent)
    .borderRadius(24 * this.controllerScale)
    .border({ width: 1.5, color: this.withAlpha(color, 0.35) })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => this.handleButtonTouch(button, event))
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
            .fontColor(this.withAlpha('#FFFFFF', 0.5))
            .fontWeight(FontWeight.Bold)
        }
        .width(36 * this.controllerScale)
        .height(36 * this.controllerScale)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Color.Transparent)
        .borderRadius({ topLeft: 14, topRight: 14, bottomLeft: 0, bottomRight: 0 })
        .border({
          width: { top: 1, left: 1, right: 1, bottom: 0 },
          color: this.withAlpha('#FFFFFF', 0.18)
        })
        .hitTestBehavior(HitTestMode.Block)
        .onTouch((event: TouchEvent) => this.handleButtonTouch(ControllerButton.UP, event))

        Column().width(36 * this.controllerScale).height(36 * this.controllerScale)
      }

      // 第二行：左 | 中心 | 右
      Row() {
        Column() {
          Text('◂')
            .fontSize(14 * this.controllerScale)
            .fontColor(this.withAlpha('#FFFFFF', 0.5))
            .fontWeight(FontWeight.Bold)
        }
        .width(36 * this.controllerScale)
        .height(36 * this.controllerScale)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Color.Transparent)
        .borderRadius({ topLeft: 14, topRight: 0, bottomLeft: 14, bottomRight: 0 })
        .border({
          width: { top: 1, left: 1, right: 0, bottom: 1 },
          color: this.withAlpha('#FFFFFF', 0.18)
        })
        .hitTestBehavior(HitTestMode.Block)
        .onTouch((event: TouchEvent) => this.handleButtonTouch(ControllerButton.LEFT, event))

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
            .fontColor(this.withAlpha('#FFFFFF', 0.5))
            .fontWeight(FontWeight.Bold)
        }
        .width(36 * this.controllerScale)
        .height(36 * this.controllerScale)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Color.Transparent)
        .borderRadius({ topLeft: 0, topRight: 14, bottomLeft: 0, bottomRight: 14 })
        .border({
          width: { top: 1, left: 0, right: 1, bottom: 1 },
          color: this.withAlpha('#FFFFFF', 0.18)
        })
        .hitTestBehavior(HitTestMode.Block)
        .onTouch((event: TouchEvent) => this.handleButtonTouch(ControllerButton.RIGHT, event))
      }

      // 第三行：空 | 下 | 空
      Row() {
        Column().width(36 * this.controllerScale).height(36 * this.controllerScale)
        Column() {
          Text('▾')
            .fontSize(14 * this.controllerScale)
            .fontColor(this.withAlpha('#FFFFFF', 0.5))
            .fontWeight(FontWeight.Bold)
        }
        .width(36 * this.controllerScale)
        .height(36 * this.controllerScale)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Color.Transparent)
        .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 14, bottomRight: 14 })
        .border({
          width: { top: 0, left: 1, right: 1, bottom: 1 },
          color: this.withAlpha('#FFFFFF', 0.18)
        })
        .hitTestBehavior(HitTestMode.Block)
        .onTouch((event: TouchEvent) => this.handleButtonTouch(ControllerButton.DOWN, event))

        Column().width(36 * this.controllerScale).height(36 * this.controllerScale)
      }
    }
  }

  // ==================== 中间功能键（Back/Start）====================
  @Builder
  buildCenterButton(icon: string, label: string, button: ControllerButton) {
    Column() {
      Row({ space: 4 }) {
        Text(icon)
          .fontSize(13 * this.controllerScale)
          .fontColor(this.withAlpha('#FFFFFF', 0.4))
        Text(label)
          .fontSize(8 * this.controllerScale)
          .fontColor(this.withAlpha('#FFFFFF', 0.4))
          .fontWeight(FontWeight.Medium)
      }
    }
    .height(34 * this.controllerScale)
    .padding({ left: 10, right: 10 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Color.Transparent)
    .borderRadius(17 * this.controllerScale)
    .border({ width: 1, color: this.withAlpha('#FFFFFF', 0.12) })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => this.handleButtonTouch(button, event))
  }

  // ==================== L3/R3 小按钮 ====================
  @Builder
  buildSmallButton(label: string, button: ControllerButton) {
    Column() {
      Text(label)
        .fontSize(11 * this.controllerScale)
        .fontColor(this.withAlpha('#FFFFFF', 0.4))
        .fontWeight(FontWeight.Medium)
    }
    .width(44 * this.controllerScale)
    .height(30 * this.controllerScale)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Color.Transparent)
    .borderRadius(15 * this.controllerScale)
    .border({ width: 1, color: this.withAlpha('#FFFFFF', 0.12) })
    .hitTestBehavior(HitTestMode.Block)
    .onTouch((event: TouchEvent) => this.handleButtonTouch(button, event))
  }

  // ==================== 事件处理 ====================
  private handleButtonTouch(button: ControllerButton, event: TouchEvent): void {
    event.stopPropagation();
    const isPressed = event.type === TouchType.Down;
    const isReleased = event.type === TouchType.Up || event.type === TouchType.Cancel;
    
    if (!isPressed && !isReleased) {
      return; // Move 事件不处理
    }
    
    // 先发送事件（不修改 @State，避免重渲染导致 Up 事件丢失）
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
    event.stopPropagation();
    const isPressed = event.type === TouchType.Down;
    const isReleased = event.type === TouchType.Up || event.type === TouchType.Cancel;
    
    if (!isPressed && !isReleased) {
      return;
    }
    
    // 先发送扳机轴事件（不修改 @State，避免重渲染导致 Up 丢失）
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

// =============================================================================
// 虚拟控制器叠加层
// 封装 VirtualController，设置通过 GameMenuDialog 卡片调整
// =============================================================================

@Component
export struct VirtualControllerOverlay {
  /** 输入事件回调 */
  onInput: (input: InputEvent) => void = () => {};

  /** 触摸穿透状态（双向 — 外部需读取来控制 XComponent hitTest） */
  @Link touchPassthrough: boolean;

  /** 控制器缩放值（双向 — 外部需读取传递给 config） */
  @Link controllerScale: number;

  /** 控制器整体透明度（双向 — 外部菜单可调节） */
  @Link controllerOpacity: number;

  /**
   * 触摸注册修复触发器。ArkUI 首次渲染时按钮的命中测试区域可能未正确建立，
   * 通过在父容器（而非 VirtualController）触发一次重渲染来刷新命中测试树。
   * 父容器重渲染不会导致 V2 重渲染（@Prop 值不变），但 ArkUI 会重算整棵树的命中区域。
   */
  @State private hitTestReady: number = 0;

  aboutToAppear(): void {
    // 延迟 100ms 在父层触发一次重渲染，刷新整个 Stack 的命中测试区域
    setTimeout(() => {
      this.hitTestReady = 1;
    }, 100);
  }

  build() {
    Stack() {
      // 控制器主体 — 底部对齐
      Column() {
        VirtualController({
          touchPassthrough: this.touchPassthrough,
          controllerScale: this.controllerScale,
          config: {
            opacity: 1.0,
            deadzone: 0.15,
            showLeftStick: true,
            showRightStick: true,
            showDpad: true,
            showButtons: true,
            showShoulder: true,
            showCenter: true,
            showL3R3: false,
            enableVibration: true
          } as VirtualControllerConfig,
          onInput: (input: InputEvent) => {
            this.onInput(input);
          }
        })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .opacity(this.controllerOpacity)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(this.touchPassthrough ? HitTestMode.Transparent : HitTestMode.Default)
    // hitTestReady: 父层重渲染触发 ArkUI 重算命中测试区域（opacity 微变不可见）
    .opacity(this.hitTestReady > 0 ? 1 : 0.99)
  }

  /**
   * 静态方法：加载持久化的缩放值
   */
  static async loadScale(): Promise<number> {
    return await PreferencesUtil.get<number>(SCALE_KEY, 1.0);
  }

  /**
   * 静态方法：保存缩放值
   */
  static saveScale(value: number): void {
    PreferencesUtil.put(SCALE_KEY, value);
  }

  /**
   * 静态方法：加载持久化的透明度值
   */
  static async loadOpacity(): Promise<number> {
    return await PreferencesUtil.get<number>(OPACITY_KEY, 0.75);
  }

  /**
   * 静态方法：保存透明度值
   */
  static saveOpacity(value: number): void {
    PreferencesUtil.put(OPACITY_KEY, value);
  }
}
