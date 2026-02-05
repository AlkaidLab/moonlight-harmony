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
 * 快捷键编辑对话框
 * 
 * 用于添加或编辑自定义快捷键
 */
import { ShortcutManager, Shortcut, KeyOption } from './ShortcutManager';

/**
 * 快捷键编辑数据（不包含 id 和 isBuiltin）
 */
export interface ShortcutEditData {
  name: string;
  keys: number[];
  icon?: string;
  color?: string;
}

export interface ShortcutEditorCallbacks {
  onSave: (data: ShortcutEditData) => void;
  onCancel: () => void;
}

@CustomDialog
export struct ShortcutEditorDialog {
  controller: CustomDialogController;
  editingShortcut?: Shortcut;  // 如果传入则为编辑模式
  callbacks: ShortcutEditorCallbacks = {
    onSave: () => {},
    onCancel: () => {}
  };
  
  // 编辑状态
  @State private name: string = '';
  @State private selectedKeys: number[] = [];
  @State private selectedIcon: string = '⌨️';
  @State private selectedColor: string = '#9DABB2';  // 莫兰迪蓝灰
  
  // UI 状态
  @State private showKeyPicker: boolean = false;
  
  private shortcutManager = ShortcutManager.getInstance();
  private availableKeys: KeyOption[] = [];
  
  // 可选图标
  private iconOptions: string[] = ['⌨️', '🎮', '🖥️', '📁', '🔧', '⚡', '🎯', '💡', '🔒', '🔓'];
  
  // 可选颜色 - 莫兰迪色系（低饱和度、温和柔和）
  private colorOptions: string[] = [
    '#9DABB2', '#A7B5AA', '#C5B4A0', '#B8A9C0', 
    '#C9A9A6', '#D4C5A9', '#8FA3AD', '#A8B4A5'
  ];
  
  // 保存编辑数据的临时对象
  private editData: ShortcutEditData = {
    name: '',
    keys: [],
    icon: undefined,
    color: undefined
  };
  
  /**
   * 保存快捷键
   */
  private saveShortcut(): void {
    this.editData.name = this.name;
    this.editData.keys = this.selectedKeys;
    this.editData.icon = this.selectedIcon;
    this.editData.color = this.selectedColor;
    this.callbacks.onSave(this.editData);
    this.controller.close();
  }
  
  aboutToAppear(): void {
    this.availableKeys = this.shortcutManager.getAvailableKeys();
    
    // 如果是编辑模式，加载现有数据
    if (this.editingShortcut) {
      this.name = this.editingShortcut.name;
      this.selectedKeys = [...this.editingShortcut.keys];
      this.selectedIcon = this.editingShortcut.icon || '⌨️';
      this.selectedColor = this.editingShortcut.color || '#9DABB2';  // 莫兰迪蓝灰
    }
  }
  
  build() {
    Column() {
      // 标题栏
      Row() {
        Text(this.editingShortcut ? '编辑快捷键' : '添加快捷键')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Blank()
        Text('✕')
          .fontSize(16)
          .fontColor('#888888')
          .onClick(() => {
            this.controller.close();
            this.callbacks.onCancel();
          })
      }
      .width('100%')
      .margin({ bottom: 12 })
      
      // 名称和图标颜色在一行
      Row() {
        // 名称输入
        Column() {
          Text('名称')
            .fontSize(11)
            .fontColor('#666')
            .margin({ bottom: 4 })
          TextInput({ placeholder: '快捷键名称', text: this.name })
            .fontSize(13)
            .fontColor('#FFF')
            .placeholderColor('#555')
            .backgroundColor('#333')
            .borderRadius(6)
            .height(32)
            .onChange((value) => { this.name = value; })
        }
        .layoutWeight(1)
        
        // 图标选择
        Column() {
          Text('图标')
            .fontSize(11)
            .fontColor('#666')
            .margin({ bottom: 4 })
          Row() {
            ForEach(this.iconOptions.slice(0, 5), (icon: string) => {
              Text(icon)
                .fontSize(16)
                .width(28)
                .height(28)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.selectedIcon === icon ? `#50${this.selectedColor.replace('#', '')}` : 'transparent')
                .borderRadius(6)
                .onClick(() => { this.selectedIcon = icon; })
            })
          }
        }
        .margin({ left: 12 })
      }
      .width('100%')
      .margin({ bottom: 10 })
      
      // 颜色选择
      Row() {
        Text('颜色')
          .fontSize(11)
          .fontColor('#666')
        Blank()
        ForEach(this.colorOptions, (color: string, index: number) => {
          Column()
            .width(22)
            .height(22)
            .backgroundColor(color)
            .borderRadius(11)
            .border({ 
              width: this.selectedColor.toUpperCase() === color.toUpperCase() ? 2 : 0, 
              color: '#FFF' 
            })
            .margin({ left: 6 })
            .onClick(() => { this.selectedColor = color; })
        }, (color: string) => color)  // 使用颜色值作为唯一 key
      }
      .width('100%')
      .margin({ bottom: 10 })
      
      // 按键组合
      Column() {
        Row() {
          Text('按键组合')
            .fontSize(11)
            .fontColor('#666')
          Blank()
          if (this.selectedKeys.length > 0) {
            Text('清空')
              .fontSize(10)
              .fontColor('#FF6B6B')
              .onClick(() => { this.selectedKeys = []; })
          }
        }
        .width('100%')
        .margin({ bottom: 4 })
        
        // 已选按键显示
        Row() {
          if (this.selectedKeys.length === 0) {
            Text('点击下方选择按键')
              .fontSize(12)
              .fontColor('#555')
          } else {
            ForEach(this.selectedKeys, (keyCode: number, index) => {
              Row() {
                Text(this.getKeyName(keyCode))
                  .fontSize(11)
                  .fontColor('#FFF')
                Text('×')
                  .fontSize(9)
                  .fontColor('#888')
                  .margin({ left: 3 })
                  .onClick(() => {
                    this.selectedKeys = this.selectedKeys.filter((_, i) => i !== index);
                  })
              }
              .padding({ left: 6, right: 4, top: 3, bottom: 3 })
              .backgroundColor('#444')
              .borderRadius(4)
              .margin({ right: 4 })
            })
          }
        }
        .width('100%')
        .height(32)
        .padding({ left: 8, right: 8 })
        .backgroundColor('#333')
        .borderRadius(6)
        .alignItems(VerticalAlign.Center)
        
        // 按键选择器
        Scroll() {
          this.KeyPicker()
        }
        .width('100%')
        .constraintSize({ maxHeight: 200 })
        .scrollBar(BarState.Auto)
        .margin({ top: 6 })
      }
      .width('100%')
      .margin({ bottom: 10 })
      
      // 预览
      Row() {
        Text(this.selectedIcon)
          .fontSize(16)
          .margin({ right: 8 })
        Column() {
          Text(this.name || '名称')
            .fontSize(13)
            .fontColor('#FFF')
          Text(this.selectedKeys.length > 0 ? this.shortcutManager.keysToDisplayText(this.selectedKeys) : '--')
            .fontSize(10)
            .fontColor('#888')
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text('预览')
          .fontSize(10)
          .fontColor('#666')
      }
      .width('100%')
      .height(44)
      .padding({ left: 10, right: 10 })
      .backgroundColor(`#50${this.selectedColor.replace('#', '')}`)
      .borderRadius(8)
      .border({ width: 1, color: `#80${this.selectedColor.replace('#', '')}` })
      .margin({ bottom: 12 })
      
      // 操作按钮
      Row() {
        Button('取消')
          .fontSize(13)
          .fontColor('#AAA')
          .backgroundColor('#333')
          .borderRadius(8)
          .height(36)
          .layoutWeight(1)
          .onClick(() => {
            this.controller.close();
            this.callbacks.onCancel();
          })
        
        Button('保存')
          .fontSize(13)
          .fontColor('#FFF')
          .backgroundColor(this.canSave() ? this.selectedColor : '#444')
          .borderRadius(8)
          .height(36)
          .layoutWeight(1)
          .margin({ left: 10 })
          .enabled(this.canSave())
          .onClick(() => { this.saveShortcut(); })
      }
      .width('100%')
    }
    .width(320)
    .padding(16)
    .backgroundColor('#1A1A1A')
    .borderRadius(14)
  }
  
  @Builder
  KeyPicker() {
    Column() {
      // 修饰键
      this.KeySection('修饰键', 'modifier')
      // 功能键
      this.KeySection('功能键', 'function')
      // 方向键
      this.KeySection('方向键', 'arrow')
      // F键
      this.KeySection('F1-F12', 'fkey')
      // 字母
      this.KeySection('字母', 'letter')
      // 数字
      this.KeySection('数字', 'number')
      // 符号
      this.KeySection('符号', 'symbol')
      // 小键盘
      this.KeySection('小键盘', 'numpad')
      // 媒体键
      this.KeySection('媒体', 'media')
    }
    .width('100%')
    .padding(8)
    .backgroundColor('#222')
    .borderRadius(8)
  }
  
  @Builder
  KeySection(title: string, category: string) {
    Column() {
      Text(title)
        .fontSize(10)
        .fontColor('#555')
        .width('100%')
        .margin({ bottom: 3, top: 4 })
      
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.getKeysByCategory(category), (key: KeyOption) => {
          this.KeyButton(key)
        })
      }
    }
  }
  
  @Builder
  KeyButton(key: KeyOption) {
    Text(key.shortName)
      .fontSize(10)
      .fontColor(this.selectedKeys.includes(key.code) ? '#B8CCD0' : '#AAA')  // 莫兰迪淡蓝
      .padding({ left: 6, right: 6, top: 4, bottom: 4 })
      .backgroundColor(this.selectedKeys.includes(key.code) ? '#334ECDC4' : '#333')
      .borderRadius(4)
      .margin({ right: 4, bottom: 4 })
      .onClick(() => {
        if (this.selectedKeys.includes(key.code)) {
          this.selectedKeys = this.selectedKeys.filter(k => k !== key.code);
        } else if (this.selectedKeys.length < 4) {
          this.selectedKeys = [...this.selectedKeys, key.code];
        }
      })
  }
  
  private getKeyName(code: number): string {
    const key = this.availableKeys.find(k => k.code === code);
    return key ? key.shortName : `0x${code.toString(16)}`;
  }
  
  private getKeysByCategory(category: string): KeyOption[] {
    switch (category) {
      case 'modifier':
        return this.availableKeys.filter(k => 
          [0x11, 0x12, 0x10, 0x5B].includes(k.code));
      case 'function':
        return this.availableKeys.filter(k => 
          [0x1B, 0x09, 0x2E, 0x0D, 0x08, 0x20, 0x2D, 0x24, 0x23, 0x21, 0x22, 0x2C, 0x91, 0x13, 0x14, 0x90].includes(k.code));
      case 'arrow':
        return this.availableKeys.filter(k => 
          [0x25, 0x26, 0x27, 0x28].includes(k.code));
      case 'fkey':
        return this.availableKeys.filter(k => 
          k.code >= 0x70 && k.code <= 0x7B);
      case 'letter':
        return this.availableKeys.filter(k => 
          k.code >= 0x41 && k.code <= 0x5A);
      case 'number':
        return this.availableKeys.filter(k => 
          k.code >= 0x30 && k.code <= 0x39);
      case 'numpad':
        return this.availableKeys.filter(k => 
          k.code >= 0x60 && k.code <= 0x6F);
      case 'symbol':
        return this.availableKeys.filter(k => 
          [0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xDB, 0xDC, 0xDD, 0xDE].includes(k.code));
      case 'media':
        return this.availableKeys.filter(k => 
          [0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3].includes(k.code));
      default:
        return [];
    }
  }
  
  private canSave(): boolean {
    return this.name.trim().length > 0 && this.selectedKeys.length > 0;
  }
}
