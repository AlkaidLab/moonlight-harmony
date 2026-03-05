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
import { VirtualKey, VK_DISPLAY_NAMES, getVkDisplayName } from '../service/CustomKeyTypes';

/**
 * 快捷键定义
 */
export interface Shortcut {
  id: string;           // 唯一标识
  name: string;         // 显示名称
  keys: number[];       // 虚拟键码数组（同时按下）
  keySequence?: number[][];  // 多步按键序列（依次执行，每步间隔 200ms）
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
  async addShortcut(name: string, keys: number[], icon?: string, color?: string, keySequence?: number[][]): Promise<Shortcut> {
    const newShortcut: Shortcut = {
      id: `user_${Date.now()}`,
      name: name,
      keys: keys,
      keySequence: keySequence,
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
  async updateShortcut(id: string, name?: string, keys?: number[], icon?: string, color?: string, keySequence?: number[][]): Promise<boolean> {
    const index = this.shortcuts.findIndex(s => s.id === id);
    if (index === -1) return false;
    
    // 内置快捷键不允许修改
    if (this.shortcuts[index].isBuiltin) return false;
    
    const current = this.shortcuts[index];
    this.shortcuts[index] = {
      id: current.id,
      name: name !== undefined ? name : current.name,
      keys: keys !== undefined ? keys : current.keys,
      keySequence: keySequence !== undefined ? keySequence : current.keySequence,
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
   * 获取所有可用的键选项（从统一的 VK_DISPLAY_NAMES 自动生成 + 补充小键盘/媒体键）
   */
  getAvailableKeys(): KeyOption[] {
    // 从 VK_DISPLAY_NAMES 自动生成（已包含字母/数字/功能键/修饰键/符号/方向键/小键盘/媒体键）
    const keys: KeyOption[] = [];
    const entries = Object.entries(VK_DISPLAY_NAMES);
    for (const entry of entries) {
      const code = Number(entry[0]);
      const shortName = entry[1] as string;
      const option: KeyOption = { code: code, name: shortName, shortName: shortName };
      keys.push(option);
    }
    return keys;
  }
  
  /**
   * 将键码数组转换为显示文本（使用统一的 getVkDisplayName）
   */
  keysToDisplayText(keys: number[]): string {
    return keys.map(code => getVkDisplayName(code)).join('+');
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
        id: 'builtin_win',
        name: 'Win',
        keys: [VirtualKey.VK_LWIN],
        icon: '⊞',
        color: '#5BA3D0',  // 蓝
        isBuiltin: true
      },
      {
        id: 'builtin_toggle_cursor',
        name: '切换远端光标',
        keys: [VirtualKey.VK_CONTROL, VirtualKey.VK_MENU, VirtualKey.VK_SHIFT, VirtualKey.VK_N],
        icon: '🖱️',
        color: '#A9C4D4',  // 莫兰迪天蓝
        isBuiltin: true
      },
      {
        id: 'builtin_sleep',
        name: '休眠',
        keys: [],  // 使用 keySequence
        keySequence: [
          [VirtualKey.VK_LWIN, 0x58],  // Win+X
          [0x55],                       // U
          [0x53]                        // S
        ],
        icon: '◐',
        color: '#909090',  // 莫兰迪灰
        isBuiltin: true
      },
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
      }
    ];
  }
}
