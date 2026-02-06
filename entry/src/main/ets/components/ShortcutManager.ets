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
 * 快捷键配置管理器
 * 
 * 管理用户自定义的快捷键组合
 * 支持持久化存储到 Preferences
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { VirtualKey } from './StreamMenuManager';

/**
 * 快捷键定义
 */
export interface Shortcut {
  id: string;           // 唯一标识
  name: string;         // 显示名称
  keys: number[];       // 虚拟键码数组
  icon?: string;        // 图标
  color?: string;       // 颜色
  isBuiltin?: boolean;  // 是否为内置快捷键
}

/**
 * 所有可用的虚拟键（供用户选择）
 */
export interface KeyOption {
  code: number;
  name: string;
  shortName: string;    // 短名称用于显示
}

/**
 * 快捷键配置管理器
 */
export class ShortcutManager {
  private static instance: ShortcutManager;
  private shortcuts: Shortcut[] = [];
  private context: common.UIAbilityContext | null = null;
  private prefs: preferences.Preferences | null = null;
  private initialized: boolean = false;
  
  private static readonly PREFS_NAME = 'shortcut_config';
  private static readonly KEY_SHORTCUTS = 'user_shortcuts';
  
  /**
   * 获取单例
   */
  static getInstance(): ShortcutManager {
    if (!ShortcutManager.instance) {
      ShortcutManager.instance = new ShortcutManager();
    }
    return ShortcutManager.instance;
  }
  
  /**
   * 初始化（需要传入 context）
   */
  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    
    this.context = context;
    try {
      this.prefs = await preferences.getPreferences(context, ShortcutManager.PREFS_NAME);
      await this.loadShortcuts();
      this.initialized = true;
    } catch (error) {
      console.error('ShortcutManager', `初始化失败: ${error}`);
      // 即使失败也使用默认配置
      this.shortcuts = this.getDefaultShortcuts();
      this.initialized = true;
    }
  }
  
  /**
   * 获取所有快捷键
   */
  getShortcuts(): Shortcut[] {
    return [...this.shortcuts];
  }
  
  /**
   * 获取用户自定义快捷键（不包括内置）
   */
  getUserShortcuts(): Shortcut[] {
    return this.shortcuts.filter(s => !s.isBuiltin);
  }
  
  /**
   * 获取内置快捷键
   */
  getBuiltinShortcuts(): Shortcut[] {
    return this.shortcuts.filter(s => s.isBuiltin);
  }
  
  /**
   * 添加自定义快捷键
   */
  async addShortcut(name: string, keys: number[], icon?: string, color?: string): Promise<Shortcut> {
    const newShortcut: Shortcut = {
      id: `user_${Date.now()}`,
      name: name,
      keys: keys,
      icon: icon,
      color: color,
      isBuiltin: false
    };
    
    this.shortcuts.push(newShortcut);
    await this.saveShortcuts();
    return newShortcut;
  }
  
  /**
   * 更新快捷键
   */
  async updateShortcut(id: string, name?: string, keys?: number[], icon?: string, color?: string): Promise<boolean> {
    const index = this.shortcuts.findIndex(s => s.id === id);
    if (index === -1) return false;
    
    // 内置快捷键不允许修改
    if (this.shortcuts[index].isBuiltin) return false;
    
    const current = this.shortcuts[index];
    this.shortcuts[index] = {
      id: current.id,
      name: name !== undefined ? name : current.name,
      keys: keys !== undefined ? keys : current.keys,
      icon: icon !== undefined ? icon : current.icon,
      color: color !== undefined ? color : current.color,
      isBuiltin: current.isBuiltin
    };
    await this.saveShortcuts();
    return true;
  }
  
  /**
   * 删除快捷键
   */
  async deleteShortcut(id: string): Promise<boolean> {
    const index = this.shortcuts.findIndex(s => s.id === id);
    if (index === -1) return false;
    
    // 内置快捷键不允许删除
    if (this.shortcuts[index].isBuiltin) return false;
    
    this.shortcuts.splice(index, 1);
    await this.saveShortcuts();
    return true;
  }
  
  /**
   * 重置为默认配置
   */
  async resetToDefault(): Promise<void> {
    this.shortcuts = this.getDefaultShortcuts();
    await this.saveShortcuts();
  }
  
  /**
   * 获取所有可用的键选项
   */
  getAvailableKeys(): KeyOption[] {
    return [
      // ========== 修饰键 ==========
      { code: VirtualKey.VK_CONTROL, name: 'Ctrl', shortName: 'Ctrl' },
      { code: VirtualKey.VK_MENU, name: 'Alt', shortName: 'Alt' },
      { code: VirtualKey.VK_SHIFT, name: 'Shift', shortName: 'Shift' },
      { code: VirtualKey.VK_LWIN, name: 'Windows', shortName: 'Win' },
      
      // ========== 常用功能键 ==========
      { code: VirtualKey.VK_ESCAPE, name: 'Escape', shortName: 'Esc' },
      { code: VirtualKey.VK_TAB, name: 'Tab', shortName: 'Tab' },
      { code: VirtualKey.VK_DELETE, name: 'Delete', shortName: 'Del' },
      { code: 0x0D, name: 'Enter', shortName: 'Enter' },
      { code: 0x08, name: 'Backspace', shortName: 'Back' },
      { code: 0x20, name: 'Space', shortName: 'Space' },
      { code: 0x2D, name: 'Insert', shortName: 'Ins' },
      { code: 0x24, name: 'Home', shortName: 'Home' },
      { code: 0x23, name: 'End', shortName: 'End' },
      { code: 0x21, name: 'Page Up', shortName: 'PgUp' },
      { code: 0x22, name: 'Page Down', shortName: 'PgDn' },
      { code: 0x2C, name: 'Print Screen', shortName: 'PrtSc' },
      { code: 0x91, name: 'Scroll Lock', shortName: 'ScrLk' },
      { code: 0x13, name: 'Pause', shortName: 'Pause' },
      { code: 0x14, name: 'Caps Lock', shortName: 'Caps' },
      { code: 0x90, name: 'Num Lock', shortName: 'NumLk' },
      
      // ========== 方向键 ==========
      { code: 0x25, name: '← Left', shortName: '←' },
      { code: 0x26, name: '↑ Up', shortName: '↑' },
      { code: 0x27, name: '→ Right', shortName: '→' },
      { code: 0x28, name: '↓ Down', shortName: '↓' },
      
      // ========== F1-F12 ==========
      { code: 0x70, name: 'F1', shortName: 'F1' },
      { code: 0x71, name: 'F2', shortName: 'F2' },
      { code: 0x72, name: 'F3', shortName: 'F3' },
      { code: VirtualKey.VK_F4, name: 'F4', shortName: 'F4' },
      { code: 0x74, name: 'F5', shortName: 'F5' },
      { code: 0x75, name: 'F6', shortName: 'F6' },
      { code: 0x76, name: 'F7', shortName: 'F7' },
      { code: 0x77, name: 'F8', shortName: 'F8' },
      { code: 0x78, name: 'F9', shortName: 'F9' },
      { code: 0x79, name: 'F10', shortName: 'F10' },
      { code: 0x7A, name: 'F11', shortName: 'F11' },
      { code: 0x7B, name: 'F12', shortName: 'F12' },
      
      // ========== 字母键 A-Z ==========
      { code: 0x41, name: 'A', shortName: 'A' },
      { code: VirtualKey.VK_B, name: 'B', shortName: 'B' },
      { code: 0x43, name: 'C', shortName: 'C' },
      { code: 0x44, name: 'D', shortName: 'D' },
      { code: 0x45, name: 'E', shortName: 'E' },
      { code: 0x46, name: 'F', shortName: 'F' },
      { code: 0x47, name: 'G', shortName: 'G' },
      { code: 0x48, name: 'H', shortName: 'H' },
      { code: 0x49, name: 'I', shortName: 'I' },
      { code: 0x4A, name: 'J', shortName: 'J' },
      { code: 0x4B, name: 'K', shortName: 'K' },
      { code: VirtualKey.VK_L, name: 'L', shortName: 'L' },
      { code: 0x4D, name: 'M', shortName: 'M' },
      { code: VirtualKey.VK_N, name: 'N', shortName: 'N' },
      { code: VirtualKey.VK_O, name: 'O', shortName: 'O' },
      { code: 0x50, name: 'P', shortName: 'P' },
      { code: 0x51, name: 'Q', shortName: 'Q' },
      { code: 0x52, name: 'R', shortName: 'R' },
      { code: VirtualKey.VK_S, name: 'S', shortName: 'S' },
      { code: 0x54, name: 'T', shortName: 'T' },
      { code: VirtualKey.VK_U, name: 'U', shortName: 'U' },
      { code: 0x56, name: 'V', shortName: 'V' },
      { code: 0x57, name: 'W', shortName: 'W' },
      { code: VirtualKey.VK_X, name: 'X', shortName: 'X' },
      { code: 0x59, name: 'Y', shortName: 'Y' },
      { code: 0x5A, name: 'Z', shortName: 'Z' },
      
      // ========== 数字键 0-9 ==========
      { code: 0x30, name: '0', shortName: '0' },
      { code: 0x31, name: '1', shortName: '1' },
      { code: 0x32, name: '2', shortName: '2' },
      { code: 0x33, name: '3', shortName: '3' },
      { code: 0x34, name: '4', shortName: '4' },
      { code: 0x35, name: '5', shortName: '5' },
      { code: 0x36, name: '6', shortName: '6' },
      { code: 0x37, name: '7', shortName: '7' },
      { code: 0x38, name: '8', shortName: '8' },
      { code: 0x39, name: '9', shortName: '9' },
      
      // ========== 小键盘 ==========
      { code: 0x60, name: 'Numpad 0', shortName: 'Num0' },
      { code: 0x61, name: 'Numpad 1', shortName: 'Num1' },
      { code: 0x62, name: 'Numpad 2', shortName: 'Num2' },
      { code: 0x63, name: 'Numpad 3', shortName: 'Num3' },
      { code: 0x64, name: 'Numpad 4', shortName: 'Num4' },
      { code: 0x65, name: 'Numpad 5', shortName: 'Num5' },
      { code: 0x66, name: 'Numpad 6', shortName: 'Num6' },
      { code: 0x67, name: 'Numpad 7', shortName: 'Num7' },
      { code: 0x68, name: 'Numpad 8', shortName: 'Num8' },
      { code: 0x69, name: 'Numpad 9', shortName: 'Num9' },
      { code: 0x6A, name: 'Numpad *', shortName: 'Num*' },
      { code: 0x6B, name: 'Numpad +', shortName: 'Num+' },
      { code: 0x6D, name: 'Numpad -', shortName: 'Num-' },
      { code: 0x6E, name: 'Numpad .', shortName: 'Num.' },
      { code: 0x6F, name: 'Numpad /', shortName: 'Num/' },
      
      // ========== 符号键 ==========
      { code: 0xBA, name: '; / :', shortName: ';' },
      { code: 0xBB, name: '= / +', shortName: '=' },
      { code: 0xBC, name: ', / <', shortName: ',' },
      { code: 0xBD, name: '- / _', shortName: '-' },
      { code: 0xBE, name: '. / >', shortName: '.' },
      { code: 0xBF, name: '/ / ?', shortName: '/' },
      { code: 0xC0, name: '` / ~', shortName: '`' },
      { code: 0xDB, name: '[ / {', shortName: '[' },
      { code: 0xDC, name: '\\ / |', shortName: '\\' },
      { code: 0xDD, name: '] / }', shortName: ']' },
      { code: 0xDE, name: "' / \"", shortName: "'" },
      
      // ========== 媒体键 ==========
      { code: 0xAD, name: 'Volume Mute', shortName: '🔇' },
      { code: 0xAE, name: 'Volume Down', shortName: '🔉' },
      { code: 0xAF, name: 'Volume Up', shortName: '🔊' },
      { code: 0xB0, name: 'Next Track', shortName: '⏭' },
      { code: 0xB1, name: 'Previous Track', shortName: '⏮' },
      { code: 0xB2, name: 'Stop', shortName: '⏹' },
      { code: 0xB3, name: 'Play/Pause', shortName: '⏯' },
    ];
  }
  
  /**
   * 将键码数组转换为显示文本
   */
  keysToDisplayText(keys: number[]): string {
    const availableKeys = this.getAvailableKeys();
    return keys.map(code => {
      const option = availableKeys.find(k => k.code === code);
      return option ? option.shortName : `0x${code.toString(16).toUpperCase()}`;
    }).join('+');
  }
  
  /**
   * 加载快捷键配置
   */
  private async loadShortcuts(): Promise<void> {
    if (!this.prefs) {
      this.shortcuts = this.getDefaultShortcuts();
      return;
    }
    
    try {
      const jsonStr = await this.prefs.get(ShortcutManager.KEY_SHORTCUTS, '') as string;
      if (jsonStr) {
        const userShortcuts: Shortcut[] = JSON.parse(jsonStr);
        // 合并内置和用户自定义
        this.shortcuts = [...this.getDefaultShortcuts(), ...userShortcuts];
      } else {
        this.shortcuts = this.getDefaultShortcuts();
      }
    } catch (error) {
      console.error('ShortcutManager', `加载快捷键失败: ${error}`);
      this.shortcuts = this.getDefaultShortcuts();
    }
  }
  
  /**
   * 保存快捷键配置
   */
  private async saveShortcuts(): Promise<void> {
    if (!this.prefs) return;
    
    try {
      // 只保存用户自定义的快捷键
      const userShortcuts = this.shortcuts.filter(s => !s.isBuiltin);
      await this.prefs.put(ShortcutManager.KEY_SHORTCUTS, JSON.stringify(userShortcuts));
      await this.prefs.flush();
    } catch (error) {
      console.error('ShortcutManager', `保存快捷键失败: ${error}`);
    }
  }
  
  /**
   * 获取默认快捷键配置
   */
  private getDefaultShortcuts(): Shortcut[] {
    // 内置快捷键使用莫兰迪色系
    return [
      {
        id: 'builtin_ctrl_alt_del',
        name: 'Ctrl+Alt+Del',
        keys: [VirtualKey.VK_CONTROL, VirtualKey.VK_MENU, VirtualKey.VK_DELETE],
        icon: '🔐',
        color: '#8FA3AD',  // 莫兰迪灰蓝
        isBuiltin: true
      },
      {
        id: 'builtin_alt_tab',
        name: 'Alt+Tab',
        keys: [VirtualKey.VK_MENU, VirtualKey.VK_TAB],
        icon: '🔄',
        color: '#B8A9C0',  // 莫兰迪淡紫
        isBuiltin: true
      },
      {
        id: 'builtin_alt_f4',
        name: 'Alt+F4',
        keys: [VirtualKey.VK_MENU, VirtualKey.VK_F4],
        icon: '❌',
        color: '#C9A9A6',  // 莫兰迪玫瑰
        isBuiltin: true
      },
      {
        id: 'builtin_win_d',
        name: 'Win+D',
        keys: [VirtualKey.VK_LWIN, 0x44],
        icon: '🖥️',
        color: '#A7B5AA',  // 莫兰迪绿
        isBuiltin: true
      },
      {
        id: 'builtin_win_e',
        name: 'Win+E',
        keys: [VirtualKey.VK_LWIN, 0x45],
        icon: '📁',
        color: '#D4C5A9',  // 莫兰迪暖棕
        isBuiltin: true
      },
      {
        id: 'builtin_toggle_cursor',
        name: '切换远端光标',
        keys: [VirtualKey.VK_CONTROL, VirtualKey.VK_MENU, VirtualKey.VK_SHIFT, VirtualKey.VK_N],
        icon: '🖱️',
        color: '#A9C4D4',  // 莫兰迪天蓝
        isBuiltin: true
      }
    ];
  }
}
