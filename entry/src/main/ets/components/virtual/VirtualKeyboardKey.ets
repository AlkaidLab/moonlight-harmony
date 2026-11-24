/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/** 按键类型 */
export enum KeyType {
  NORMAL,
  MODIFIER,
  SPACER,
}

/** 单个按键定义 */
export interface KeyDef {
  label: string;
  subLabel?: string;
  vk: number;
  weight?: number;
  type?: KeyType;
}

/** 按下态使用较深的蓝色，与粘滞修饰键的浅色高亮区分。 */
const KEY_PRESSED_BG_COLOR = '#D936708A';
const KEY_PRESSED_BORDER_COLOR = '#B0D9F2FF';
const KEY_RADIUS = 10;

/** 独立组件让多态样式拥有自己的刷新节点，按键事件仍交由键盘处理。 */
@Component
export struct VirtualKeyboardKey {
  keyDef: KeyDef = { label: '', vk: 0 };
  isFuncRow: boolean = false;
  isSpace: boolean = false;
  @Prop isActive: boolean = false;
  onKeyTouch: (event: TouchEvent) => void = () => {};

  @Styles
  private pressedKeyStyle() {
    .backgroundColor(KEY_PRESSED_BG_COLOR)
    .borderColor(KEY_PRESSED_BORDER_COLOR)
  }

  private getKeyBgColor(): string {
    if (this.isActive) {
      return '#60A8D8EA';
    }
    if (this.keyDef.type === KeyType.MODIFIER) {
      return '#2A3A4A5A';
    }
    if (this.isSpace) {
      return '#1A3A4A5A';
    }
    return '#22FFFFFF';
  }

  private getKeyTextColor(): string {
    if (this.isActive) {
      return '#FFFFFF';
    }
    if (this.keyDef.type === KeyType.MODIFIER) {
      return '#C0D0E0FF';
    }
    return '#E8F0FFFF';
  }

  build() {
    Text(this.keyDef.label)
      .fontSize(this.isFuncRow ? 10 : (this.keyDef.weight && this.keyDef.weight > 1.5 ? 11 : 13))
      .fontColor(this.getKeyTextColor())
      .fontWeight(FontWeight.Bold)
      .fontFamily('HarmonyOS Sans')
      .textAlign(TextAlign.Center)
      .width('100%')
      .height('100%')
      .backgroundColor(this.getKeyBgColor())
      .borderRadius(KEY_RADIUS)
      .border({
        width: { top: 1, left: 1, right: 1, bottom: 1 },
        color: {
          top: this.isActive ? '#70A8D8EA' : '#28FFFFFF',
          left: this.isActive ? '#50A8D8EA' : '#18FFFFFF',
          right: this.isActive ? '#50A8D8EA' : '#10FFFFFF',
          bottom: this.isActive ? '#40A8D8EA' : '#08FFFFFF',
        },
      })
      .shadow({
        radius: this.isActive ? 6 : 2,
        color: this.isActive ? '#40A8D8EA' : '#18000000',
        offsetY: 1,
      })
      .stateStyles({ pressed: this.pressedKeyStyle })
      .onTouch((event: TouchEvent) => {
        this.onKeyTouch(event);
      })
  }
}
