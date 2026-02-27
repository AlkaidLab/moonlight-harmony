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
 * 串流用 PC 风格虚拟键盘
 *
 * 自绘全键盘（ESC, F1-F12, 数字行, QWERTY, 方向键, 修饰键等），
 * 适用于串流场景，直接向远端发送 Windows 虚拟键码。
 *
 * 设计风格：
 *   - 半透明毛玻璃底板（与 GameMenuDialog 风格一致）
 *   - 按键使用微透明圆角卡片，按下时颜色反馈
 *   - 支持 Slider 调整透明度
 *   - 支持拖拽移动键盘位置
 *   - 修饰键 (Ctrl/Shift/Alt/Win) 支持粘滞 toggle
 *   - 支持自定义背景图片
 */

import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { vibrator } from '@kit.SensorServiceKit';


// =============================================================================
// Windows 虚拟键码
// =============================================================================

/** Windows 虚拟键码常量 */
class VK {
  static readonly ESCAPE: number = 0x1B;
  static readonly F1: number = 0x70;
  static readonly F2: number = 0x71;
  static readonly F3: number = 0x72;
  static readonly F4: number = 0x73;
  static readonly F5: number = 0x74;
  static readonly F6: number = 0x75;
  static readonly F7: number = 0x76;
  static readonly F8: number = 0x77;
  static readonly F9: number = 0x78;
  static readonly F10: number = 0x79;
  static readonly F11: number = 0x7A;
  static readonly F12: number = 0x7B;
  static readonly PRINT_SCREEN: number = 0x2C;
  static readonly SCROLL_LOCK: number = 0x91;
  static readonly PAUSE: number = 0x13;
  static readonly INSERT: number = 0x2D;
  static readonly DELETE: number = 0x2E;
  static readonly HOME: number = 0x24;
  static readonly END: number = 0x23;
  static readonly PAGE_UP: number = 0x21;
  static readonly PAGE_DOWN: number = 0x22;
  static readonly OEM_3: number = 0xC0;      // `~
  static readonly KEY_1: number = 0x31;
  static readonly KEY_2: number = 0x32;
  static readonly KEY_3: number = 0x33;
  static readonly KEY_4: number = 0x34;
  static readonly KEY_5: number = 0x35;
  static readonly KEY_6: number = 0x36;
  static readonly KEY_7: number = 0x37;
  static readonly KEY_8: number = 0x38;
  static readonly KEY_9: number = 0x39;
  static readonly KEY_0: number = 0x30;
  static readonly OEM_MINUS: number = 0xBD;   // -_
  static readonly OEM_PLUS: number = 0xBB;    // =+
  static readonly BACK: number = 0x08;         // Backspace
  static readonly TAB: number = 0x09;
  static readonly KEY_Q: number = 0x51;
  static readonly KEY_W: number = 0x57;
  static readonly KEY_E: number = 0x45;
  static readonly KEY_R: number = 0x52;
  static readonly KEY_T: number = 0x54;
  static readonly KEY_Y: number = 0x59;
  static readonly KEY_U: number = 0x55;
  static readonly KEY_I: number = 0x49;
  static readonly KEY_O: number = 0x4F;
  static readonly KEY_P: number = 0x50;
  static readonly OEM_4: number = 0xDB;       // [{
  static readonly OEM_6: number = 0xDD;       // ]}
  static readonly OEM_5: number = 0xDC;       // \|
  static readonly CAPS_LOCK: number = 0x14;
  static readonly KEY_A: number = 0x41;
  static readonly KEY_S: number = 0x53;
  static readonly KEY_D: number = 0x44;
  static readonly KEY_F: number = 0x46;
  static readonly KEY_G: number = 0x47;
  static readonly KEY_H: number = 0x48;
  static readonly KEY_J: number = 0x4A;
  static readonly KEY_K: number = 0x4B;
  static readonly KEY_L: number = 0x4C;
  static readonly OEM_1: number = 0xBA;       // ;:
  static readonly OEM_7: number = 0xDE;       // '"
  static readonly RETURN: number = 0x0D;
  static readonly LSHIFT: number = 0xA0;
  static readonly KEY_Z: number = 0x5A;
  static readonly KEY_X: number = 0x58;
  static readonly KEY_C: number = 0x43;
  static readonly KEY_V: number = 0x56;
  static readonly KEY_B: number = 0x42;
  static readonly KEY_N: number = 0x4E;
  static readonly KEY_M: number = 0x4D;
  static readonly OEM_COMMA: number = 0xBC;    // ,<
  static readonly OEM_PERIOD: number = 0xBE;   // .>
  static readonly OEM_2: number = 0xBF;        // /?
  static readonly RSHIFT: number = 0xA1;
  static readonly LCONTROL: number = 0xA2;
  static readonly LWIN: number = 0x5B;
  static readonly LMENU: number = 0xA4;        // Alt
  static readonly SPACE: number = 0x20;
  static readonly RMENU: number = 0xA5;
  static readonly RCONTROL: number = 0xA3;
  static readonly LEFT: number = 0x25;
  static readonly UP: number = 0x26;
  static readonly RIGHT: number = 0x27;
  static readonly DOWN: number = 0x28;
}

// =============================================================================
// 按键数据模型
// =============================================================================

/** 按键类型 */
enum KeyType {
  NORMAL,     // 普通按键
  MODIFIER,   // 修饰键（支持粘滞）
  SPACER,     // 占位空白
}

/** 单个按键定义 */
interface KeyDef {
  /** 显示标签 */
  label: string;
  /** 按下时显示的标签（如 Shift 激活后显示的字符） */
  subLabel?: string;
  /** Windows VK 码 */
  vk: number;
  /** 宽度权重（默认 1） */
  weight?: number;
  /** 按键类型 */
  type?: KeyType;
}

// =============================================================================
// 键盘行布局定义
// =============================================================================

/** 功能键行：ESC + F1-F12 + Del */
const ROW_FUNC: KeyDef[] = [
  { label: 'Esc', vk: VK.ESCAPE },
  { label: 'F1', vk: VK.F1 }, { label: 'F2', vk: VK.F2 },
  { label: 'F3', vk: VK.F3 }, { label: 'F4', vk: VK.F4 },
  { label: 'F5', vk: VK.F5 }, { label: 'F6', vk: VK.F6 },
  { label: 'F7', vk: VK.F7 }, { label: 'F8', vk: VK.F8 },
  { label: 'F9', vk: VK.F9 }, { label: 'F10', vk: VK.F10 },
  { label: 'F11', vk: VK.F11 }, { label: 'F12', vk: VK.F12 },
  { label: 'Ins', vk: VK.INSERT }, { label: 'Del', vk: VK.DELETE },
];

/** 数字行 */
const ROW_NUM: KeyDef[] = [
  { label: '`', subLabel: '~', vk: VK.OEM_3 },
  { label: '1', vk: VK.KEY_1 }, { label: '2', vk: VK.KEY_2 },
  { label: '3', vk: VK.KEY_3 }, { label: '4', vk: VK.KEY_4 },
  { label: '5', vk: VK.KEY_5 }, { label: '6', vk: VK.KEY_6 },
  { label: '7', vk: VK.KEY_7 }, { label: '8', vk: VK.KEY_8 },
  { label: '9', vk: VK.KEY_9 }, { label: '0', vk: VK.KEY_0 },
  { label: '-', subLabel: '_', vk: VK.OEM_MINUS },
  { label: '=', subLabel: '+', vk: VK.OEM_PLUS },
  { label: '⌫', vk: VK.BACK, weight: 2 },
];

/** QWERTY 第一行 */
const ROW_Q: KeyDef[] = [
  { label: 'Tab', vk: VK.TAB, weight: 1.5 },
  { label: 'Q', vk: VK.KEY_Q }, { label: 'W', vk: VK.KEY_W },
  { label: 'E', vk: VK.KEY_E }, { label: 'R', vk: VK.KEY_R },
  { label: 'T', vk: VK.KEY_T }, { label: 'Y', vk: VK.KEY_Y },
  { label: 'U', vk: VK.KEY_U }, { label: 'I', vk: VK.KEY_I },
  { label: 'O', vk: VK.KEY_O }, { label: 'P', vk: VK.KEY_P },
  { label: '[', subLabel: '{', vk: VK.OEM_4 },
  { label: ']', subLabel: '}', vk: VK.OEM_6 },
  { label: '\\', subLabel: '|', vk: VK.OEM_5, weight: 1.5 },
];

/** QWERTY 第二行 */
const ROW_A: KeyDef[] = [
  { label: 'Caps', vk: VK.CAPS_LOCK, weight: 1.8 },
  { label: 'A', vk: VK.KEY_A }, { label: 'S', vk: VK.KEY_S },
  { label: 'D', vk: VK.KEY_D }, { label: 'F', vk: VK.KEY_F },
  { label: 'G', vk: VK.KEY_G }, { label: 'H', vk: VK.KEY_H },
  { label: 'J', vk: VK.KEY_J }, { label: 'K', vk: VK.KEY_K },
  { label: 'L', vk: VK.KEY_L },
  { label: ';', subLabel: ':', vk: VK.OEM_1 },
  { label: "'", subLabel: '"', vk: VK.OEM_7 },
  { label: 'Enter', vk: VK.RETURN, weight: 2.2 },
];

/** QWERTY 第三行 */
const ROW_Z: KeyDef[] = [
  { label: 'Shift', vk: VK.LSHIFT, weight: 2.4, type: KeyType.MODIFIER },
  { label: 'Z', vk: VK.KEY_Z }, { label: 'X', vk: VK.KEY_X },
  { label: 'C', vk: VK.KEY_C }, { label: 'V', vk: VK.KEY_V },
  { label: 'B', vk: VK.KEY_B }, { label: 'N', vk: VK.KEY_N },
  { label: 'M', vk: VK.KEY_M },
  { label: ',', subLabel: '<', vk: VK.OEM_COMMA },
  { label: '.', subLabel: '>', vk: VK.OEM_PERIOD },
  { label: '/', subLabel: '?', vk: VK.OEM_2 },
  { label: 'Shift', vk: VK.RSHIFT, weight: 2.4, type: KeyType.MODIFIER },
];

/** 底行：修饰键 + 空格 + 方向键 */
const ROW_BOTTOM: KeyDef[] = [
  { label: 'Ctrl', vk: VK.LCONTROL, weight: 1.5, type: KeyType.MODIFIER },
  { label: 'Win', vk: VK.LWIN, weight: 1.2, type: KeyType.MODIFIER },
  { label: 'Alt', vk: VK.LMENU, weight: 1.3, type: KeyType.MODIFIER },
  { label: '', vk: VK.SPACE, weight: 6 },
  { label: 'Alt', vk: VK.RMENU, weight: 1.3, type: KeyType.MODIFIER },
  { label: 'Ctrl', vk: VK.RCONTROL, weight: 1.5, type: KeyType.MODIFIER },
  { label: '←', vk: VK.LEFT },
  { label: '↑', vk: VK.UP },
  { label: '↓', vk: VK.DOWN },
  { label: '→', vk: VK.RIGHT },
];

/** 所有行 */
const KEYBOARD_ROWS: KeyDef[][] = [
  ROW_FUNC, ROW_NUM, ROW_Q, ROW_A, ROW_Z, ROW_BOTTOM,
];

// =============================================================================
// 样式常量
// =============================================================================

/** 按键间距 */
const KEY_GAP = 4;
/** 行间距 */
const ROW_GAP = 4;
/** 按键圆角 */
const KEY_RADIUS = 10;
/** 键盘整体内边距 */
const KB_PADDING = 8;
/** 标题栏高度 */
const TITLE_BAR_HEIGHT = 36;
/** 单行按键高度 */
const KEY_HEIGHT = 36;
/** 功能键行高度（稍矮） */
const FUNC_KEY_HEIGHT = 30;

/** 键盘背景图存储键 */
const KB_BG_IMAGE_KEY = 'virtual_keyboard_bg_image';

// =============================================================================
// 组件
// =============================================================================

@Component
export struct VirtualKeyboard {
  /** 按键事件回调 */
  onVirtualKeyEvent: (vk: number, isDown: boolean) => void = () => {};
  /** 关闭键盘回调 */
  onClose: () => void = () => {};

  // ── 状态 ──
  /** 键盘整体透明度 */
  @State private opacity_: number = 0.85;
  /** 键盘偏移位置（拖拽） */
  @State private offsetX: number = 0;
  @State private offsetY: number = 0;
  /** 背景图片 URI（空=无背景图） */
  @State private backgroundImageUri: string = '';
  /** 组合键模式：修饰键粘滞 toggle */
  @State private comboMode: boolean = false;
  /** 粘滞修饰键集合（仅组合键模式） */
  @State private stickyModifiers: Set<number> = new Set<number>();
  /** 拖拽起始坐标 */
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private dragStartOffsetX: number = 0;
  private dragStartOffsetY: number = 0;

  async aboutToAppear(): Promise<void> {
    // 加载保存的背景图
    const savedUri = await PreferencesUtil.get<string>(KB_BG_IMAGE_KEY, '');
    if (savedUri) {
      // 检查文件是否存在
      try {
        await fileIo.access(savedUri);
        this.backgroundImageUri = savedUri;
      } catch (_e) {
        // 文件不存在，清除设置
        await PreferencesUtil.put(KB_BG_IMAGE_KEY, '');
      }
    }
  }

  build() {
    Column() {
      // 标题栏（功能控制 + 顶部居中拖拽把手）
      this.TitleBar()

      // 键盘主体（layoutWeight 自动填充剩余空间）
      Stack() {
        // 背景图层（绝对定位，填满 Stack）
        if (this.backgroundImageUri) {
          Image('file://' + this.backgroundImageUri)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .borderRadius({ bottomLeft: 15, bottomRight: 15 })
            .opacity(0.35)
            .position({ left: 0, top: 0 })
        }

        // 按键层（行均匀分布）
        Column({ space: ROW_GAP }) {
          ForEach(KEYBOARD_ROWS, (row: KeyDef[], rowIndex: number) => {
            this.KeyRow(row, rowIndex === 0)
          }, (_row: KeyDef[], index: number) => `row_${index}`)
        }
        .padding(KB_PADDING)
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.TopStart)
    }
    // 高度 = 标题栏 + 功能行(0.8权重) + 5普通行(1权重) + 间距 + 内边距
    // 总权重 5.8，以 KEY_HEIGHT 为基准：32 + 5.8 × 36 + 5 × 2 + 2 × 4 = 260 vp
    // 绝对高度保证布局优雅，constraintSize 限制大屏不超过 60%
    .height(TITLE_BAR_HEIGHT + (KEYBOARD_ROWS.length - 1) * KEY_HEIGHT
      + FUNC_KEY_HEIGHT + (KEYBOARD_ROWS.length - 1) * ROW_GAP + KB_PADDING * 2)
    .constraintSize({ maxHeight: '60%' })
    .backgroundColor('#CC1A1A2E')
    .backdropBlur(50)
    .borderRadius(16)
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 20, color: '#60000000', offsetY: 4 })
    .opacity(this.opacity_)
    .offset({ x: this.offsetX, y: this.offsetY })
    .clip(true)
  }

  // ── 标题栏 ──

  @Builder
  TitleBar() {
    Stack({ alignContent: Alignment.Top }) {
      // 控制栏（底层）
      Row() {
        Text('PC 键盘')
          .fontSize(12)
          .fontColor('#B0FFFFFF')
          .fontWeight(FontWeight.Medium)
          .margin({ left: 8 })

        // 组合键模式开关（图标+文字胶囊按钮）
        Row({ space: 4 }) {
          Text('⌘')
            .fontSize(13)
            .fontColor(this.comboMode ? '#FFFFFF' : '#80FFFFFF')
            .fontWeight(FontWeight.Bold)
          Text('组合键')
            .fontSize(10)
            .fontColor(this.comboMode ? '#FFFFFF' : '#80FFFFFF')
            .fontWeight(FontWeight.Medium)
        }
        .height(24)
        .padding({ left: 8, right: 8 })
        .alignItems(VerticalAlign.Center)
        .borderRadius(12)
        .backgroundColor(this.comboMode ? '#50A8D8EA' : '#20FFFFFF')
        .border({ width: 1, color: this.comboMode ? '#80A8D8EA' : '#00000000' })
        .margin({ left: 8 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.85 })
        .shadow({
          radius: this.comboMode ? 6 : 0,
          color: this.comboMode ? '#40A8D8EA' : '#00000000',
          offsetY: 0,
        })
        .onClick(() => {
          this.comboMode = !this.comboMode;
          if (!this.comboMode && this.stickyModifiers.size > 0) {
            this.stickyModifiers.forEach((modVk: number) => {
              this.onVirtualKeyEvent(modVk, false);
            });
            this.stickyModifiers = new Set<number>();
          }
        })

        Blank()

        // 透明度 Slider
        Text('👁')
          .fontSize(11)
          .fontColor('#80FFFFFF')

        Slider({
          value: this.opacity_ * 100,
          min: 20,
          max: 100,
          step: 5,
          style: SliderStyle.OutSet,
        })
          .width(80)
          .blockColor('#A8D8EA')
          .blockSize({ width: 12, height: 12 })
          .trackColor('#30FFFFFF')
          .selectedColor('#A8D8EA')
          .trackThickness(3)
          .showSteps(false)
          .showTips(false)
          .onChange((value: number) => {
            this.opacity_ = value / 100;
          })

        // 背景图按钮
        Text('❏')
          .fontSize(15)
          .fontColor(this.backgroundImageUri ? '#A8D8EA' : '#80FFFFFF')
          .width(28)
          .height(28)
          .textAlign(TextAlign.Center)
          .borderRadius(14)
          .backgroundColor(this.backgroundImageUri ? '#30A8D8EA' : '#20FFFFFF')
          .margin({ left: 4 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.85 })
          .onClick(() => {
            if (this.backgroundImageUri) {
              this.clearBackgroundImage();
            } else {
              this.pickBackgroundImage();
            }
          })

        // 关闭按钮
        Text('✕')
          .fontSize(14)
          .fontColor('#99FFFFFF')
          .width(28)
          .height(28)
          .textAlign(TextAlign.Center)
          .borderRadius(14)
          .backgroundColor('#30FFFFFF')
          .margin({ left: 4, right: 4 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.85 })
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Center)

      // 顶部居中拖拽把手（叠加层）
      Row()
        .width(36)
        .height(4)
        .backgroundColor('#40FFFFFF')
        .borderRadius(2)
        .margin({ top: 3 })
    }
    .width('100%')
    .height(TITLE_BAR_HEIGHT)
    .gesture(
      PanGesture({ direction: PanDirection.All })
        .onActionStart((event: GestureEvent) => {
          this.dragStartX = event.offsetX;
          this.dragStartY = event.offsetY;
          this.dragStartOffsetX = this.offsetX;
          this.dragStartOffsetY = this.offsetY;
        })
        .onActionUpdate((event: GestureEvent) => {
          this.offsetX = this.dragStartOffsetX + event.offsetX - this.dragStartX;
          this.offsetY = this.dragStartOffsetY + event.offsetY - this.dragStartY;
        })
    )
  }

  // ── 键盘行 ──

  @Builder
  KeyRow(keys: KeyDef[], isFuncRow: boolean) {
    Row({ space: KEY_GAP }) {
      ForEach(keys, (key: KeyDef) => {
        this.KeyButton(key, isFuncRow)
      }, (key: KeyDef) => `${key.vk}_${key.label}`)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .layoutWeight(isFuncRow ? 0.8 : 1)
  }

  // ── 单个按键 ──

  @Builder
  KeyButton(key: KeyDef, isFuncRow: boolean) {
    Text(key.label)
      .fontSize(isFuncRow ? 10 : (key.weight && key.weight > 1.5 ? 11 : 13))
      .fontColor(this.getKeyTextColor(key))
      .fontWeight(FontWeight.Bold)
      .fontFamily('HarmonyOS Sans')
      .textAlign(TextAlign.Center)
      .height('100%')
      .layoutWeight(key.weight ?? 1)
      .backgroundColor(this.getKeyBgColor(key))
      .borderRadius(KEY_RADIUS)
      .border({
        width: { top: 1, left: 1, right: 1, bottom: 1 },
        color: {
          top: this.isKeyActive(key) ? '#70A8D8EA' : '#28FFFFFF',   // 顶部高光边
          left: this.isKeyActive(key) ? '#50A8D8EA' : '#18FFFFFF',
          right: this.isKeyActive(key) ? '#50A8D8EA' : '#10FFFFFF',
          bottom: this.isKeyActive(key) ? '#40A8D8EA' : '#08FFFFFF', // 底部暗边
        },
      })
      .shadow({
        radius: this.isKeyActive(key) ? 6 : 2,
        color: this.isKeyActive(key) ? '#40A8D8EA' : '#18000000',
        offsetY: 1,
      })
      .onTouch((event: TouchEvent) => {
        this.handleKeyTouch(key, event);
      })
  }

  // ── 按键颜色逻辑 ──

  private getKeyBgColor(key: KeyDef): string {
    if (this.isKeyActive(key)) {
      return '#60A8D8EA';  // 激活状态：柔和蓝高光
    }
    if (key.type === KeyType.MODIFIER) {
      return '#2A3A4A5A';  // 修饰键：蓝灰色调，与普通键区分
    }
    if (key.vk === VK.SPACE) {
      return '#1A3A4A5A';  // 空格：微蓝灰
    }
    return '#22FFFFFF';    // 普通按键：微亮玻璃感
  }

  private getKeyTextColor(key: KeyDef): string {
    if (this.isKeyActive(key)) {
      return '#FFFFFF';
    }
    if (key.type === KeyType.MODIFIER) {
      return '#C0D0E0FF'; // 修饰键：淡蓝白，优雅区分
    }
    return '#E8F0FFFF';   // 普通：清透白，略带冷色
  }

  /** 按键是否处于激活状态（组合键模式下的粘滞修饰键） */
  private isKeyActive(key: KeyDef): boolean {
    return this.comboMode && this.stickyModifiers.has(key.vk);
  }

  // ── 触摸事件处理 ──

  private handleKeyTouch(key: KeyDef, event: TouchEvent): void {
    const touchType = event.type;

    // 组合键模式：修饰键使用粘滞 toggle
    if (this.comboMode && key.type === KeyType.MODIFIER) {
      if (touchType === TouchType.Down) {
        const newSet = new Set<number>(this.stickyModifiers);
        if (newSet.has(key.vk)) {
          newSet.delete(key.vk);
          this.onVirtualKeyEvent(key.vk, false);
        } else {
          newSet.add(key.vk);
          this.onVirtualKeyEvent(key.vk, true);
        }
        this.stickyModifiers = newSet;
      }
      // 粘滞模式下忽略 Up 事件
      return;
    }

    // 普通模式：所有按键 Down→KEY_DOWN, Up→KEY_UP
    // 不修改任何 @State，避免触发重渲染导致 Up 事件丢失
    if (touchType === TouchType.Down) {
      this.onVirtualKeyEvent(key.vk, true);
      // 触感反馈
      try {
        vibrator.startVibration({ type: 'time', duration: 20 }, { id: 0, usage: 'touch' });
      } catch (_e) {}
    } else if (touchType === TouchType.Up || touchType === TouchType.Cancel) {
      this.onVirtualKeyEvent(key.vk, false);

      // 组合键模式：普通键释放后自动释放所有粘滞修饰键
      if (this.comboMode && this.stickyModifiers.size > 0) {
        this.stickyModifiers.forEach((modVk: number) => {
          this.onVirtualKeyEvent(modVk, false);
        });
        this.stickyModifiers = new Set<number>();
      }
    }
  }

  // ── 背景图管理 ──

  private async pickBackgroundImage(): Promise<void> {
    try {
      const photoPicker = new picker.PhotoViewPicker();
      const options = new picker.PhotoSelectOptions();
      options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result = await photoPicker.select(options);
      if (result.photoUris && result.photoUris.length > 0) {
        const srcUri = result.photoUris[0];
        // 复制到应用沙箱以持久保存
        const context = getContext(this);
        const destPath = context.filesDir + '/keyboard_bg.jpg';
        const srcFile = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
        const destFile = fileIo.openSync(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        fileIo.copyFileSync(srcFile.fd, destFile.fd);
        fileIo.closeSync(srcFile);
        fileIo.closeSync(destFile);
        this.backgroundImageUri = destPath;
        await PreferencesUtil.put(KB_BG_IMAGE_KEY, destPath);
      }
    } catch (e) {
      console.error('VirtualKeyboard: pickBackgroundImage failed', e);
    }
  }

  private async clearBackgroundImage(): Promise<void> {
    try {
      if (this.backgroundImageUri) {
        // 删除沙箱中的缓存文件
        try {
          fileIo.unlinkSync(this.backgroundImageUri);
        } catch (_e) {
          // ignore
        }
      }
      this.backgroundImageUri = '';
      await PreferencesUtil.put(KB_BG_IMAGE_KEY, '');
    } catch (e) {
      console.error('VirtualKeyboard: clearBackgroundImage failed', e);
    }
  }
}
