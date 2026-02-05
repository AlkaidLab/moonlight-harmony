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
 * 串流菜单管理器
 * 
 * 负责管理串流页面的菜单配置和业务逻辑
 * 与 Android GameMenu 功能对齐
 */
import { promptAction } from '@kit.ArkUI';
import { StreamingSession } from '../service/StreamingSession';
import { StreamViewModel, TouchMode } from '../viewmodel/StreamViewModel';
import { OptionPickerDialogConfig, OptionItem } from './OptionPickerDialog';

/**
 * Windows 虚拟键码定义
 */
export class VirtualKey {
  static readonly VK_ESCAPE = 0x1B;
  static readonly VK_LWIN = 0x5B;
  static readonly VK_MENU = 0x12;      // Alt
  static readonly VK_CONTROL = 0x11;
  static readonly VK_SHIFT = 0x10;
  static readonly VK_TAB = 0x09;
  static readonly VK_DELETE = 0x2E;
  static readonly VK_B = 0x42;
  static readonly VK_F4 = 0x73;
  static readonly VK_L = 0x4C;
  static readonly VK_N = 0x4E;
  static readonly VK_O = 0x4F;
  static readonly VK_X = 0x58;
  static readonly VK_U = 0x55;
  static readonly VK_S = 0x53;
}

/**
 * 菜单操作回调
 */
export interface StreamMenuCallbacks {
  onResume: () => void;
  onDisconnect: () => void;
  onQuitGame: () => void;
  onTouchModeChanged: (mode: string) => void;
  onShowTouchModeMenu: () => void;
}

/**
 * 串流菜单管理器
 */
export class StreamMenuManager {
  private viewModel: StreamViewModel;
  private callbacks: StreamMenuCallbacks;

  constructor(viewModel: StreamViewModel, callbacks: StreamMenuCallbacks) {
    this.viewModel = viewModel;
    this.callbacks = callbacks;
  }

  /**
   * 获取串流会话
   */
  private getSession(): StreamingSession | null {
    return this.viewModel.getSession();
  }

  /**
   * 显示 Toast 提示
   */
  private showToast(message: string): void {
    try {
      promptAction.showToast({
        message: message,
        duration: 1500
      });
    } catch (e) {
      console.warn('showToast failed:', e);
    }
  }

  /**
   * 获取触摸模式的中文名称
   */
  getTouchModeName(): string {
    switch (this.viewModel.touchMode) {
      case 'trackpad':
        return '触摸板模式';
      case 'direct':
        return '直接触摸模式';
      case 'mouse':
        return '鼠标模式';
      default:
        return this.viewModel.touchMode;
    }
  }

  /**
   * 获取性能覆盖层状态描述
   */
  getPerformanceOverlayStatus(): string {
    if (!this.viewModel.showOverlay) {
      return '当前: 关闭';
    } else if (this.viewModel.overlayState.config.isLocked) {
      return '当前: 固定显示';
    } else {
      return '当前: 悬浮显示';
    }
  }

  /**
   * 获取主串流菜单配置
   */
  getStreamMenuConfig(): OptionPickerDialogConfig {
    const options: OptionItem[] = [
      {
        title: '🎮 继续游戏',
        subtitle: '关闭此菜单，继续串流',
        value: 'resume'
      },
      {
        title: '⎋ 发送 ESC',
        subtitle: '向远程发送 ESC 键',
        value: 'send_esc'
      },
      {
        title: '⊞ 发送 Win',
        subtitle: '打开/关闭 Windows 开始菜单',
        value: 'send_win'
      },
      {
        title: '🌈 切换 HDR',
        subtitle: '发送 Win+Alt+B 切换 HDR',
        value: 'toggle_hdr'
      },
      {
        title: '⌨️ 打开主机键盘',
        subtitle: '发送 Win+Ctrl+O 呼出系统键盘',
        value: 'host_keyboard'
      },
      {
        title: `👆 切换触摸模式`,
        subtitle: `当前: ${this.getTouchModeName()}`,
        value: 'touch_mode'
      },
      {
        title: this.viewModel.showOverlay ? '📊 隐藏性能监控' : '📊 显示性能监控',
        subtitle: this.getPerformanceOverlayStatus(),
        value: 'toggle_overlay'
      },
      {
        title: this.viewModel.showController ? '🎮 隐藏虚拟按键' : '🎮 显示虚拟按键',
        subtitle: '切换屏幕虚拟控制器',
        value: 'toggle_controller'
      },
      {
        title: '🔌 断开连接',
        subtitle: '结束串流但保持游戏运行',
        value: 'disconnect'
      },
      {
        title: '🚪 退出游戏',
        subtitle: '关闭远程游戏并返回',
        value: 'quit_game'
      }
    ];

    return {
      title: '🍥 串流菜单',
      subtitle: '按返回键可再次打开此菜单',
      options: options,
      selectedValue: '',
      onSelect: (option: OptionItem) => {
        this.handleMainMenuSelect(option);
      }
    };
  }

  /**
   * 处理主菜单选择
   */
  private handleMainMenuSelect(option: OptionItem): void {
    const session = this.getSession();

    switch (option.value) {
      case 'resume':
        this.callbacks.onResume();
        break;
      case 'send_esc':
        session?.sendKeys([VirtualKey.VK_ESCAPE]);
        this.showToast('已发送 ESC');
        break;
      case 'send_win':
        session?.sendKeys([VirtualKey.VK_LWIN]);
        this.showToast('已发送 Win');
        break;
      case 'toggle_hdr':
        session?.sendKeys([VirtualKey.VK_LWIN, VirtualKey.VK_MENU, VirtualKey.VK_B]);
        this.showToast('已发送 Win+Alt+B');
        break;
      case 'host_keyboard':
        session?.sendKeys([VirtualKey.VK_LWIN, VirtualKey.VK_CONTROL, VirtualKey.VK_O]);
        this.showToast('已发送 Win+Ctrl+O');
        break;
      case 'touch_mode':
        this.callbacks.onShowTouchModeMenu();
        break;
      case 'toggle_overlay':
        this.viewModel.toggleOverlay();
        break;
      case 'toggle_controller':
        this.viewModel.toggleController();
        break;
      case 'disconnect':
        this.callbacks.onDisconnect();
        break;
      case 'quit_game':
        this.callbacks.onQuitGame();
        break;
    }
  }

  /**
   * 获取触摸模式子菜单配置
   */
  getTouchModeMenuConfig(): OptionPickerDialogConfig {
    const currentMode = this.viewModel.touchMode;

    const options: OptionItem[] = [
      {
        title: currentMode === 'trackpad' ? '✓ 触摸板模式' : '  触摸板模式',
        subtitle: '相对移动，像使用笔记本触摸板',
        value: 'trackpad'
      },
      {
        title: currentMode === 'direct' ? '✓ 直接触摸模式' : '  直接触摸模式',
        subtitle: '绝对坐标，点哪移哪',
        value: 'direct'
      },
      {
        title: currentMode === 'mouse' ? '✓ 鼠标模式' : '  鼠标模式',
        subtitle: '相对移动 + 按住拖动',
        value: 'mouse'
      },
      {
        title: '🖱️ 切换远程鼠标指针',
        subtitle: '发送 Ctrl+Alt+Shift+N 切换鼠标',
        value: 'toggle_remote_mouse'
      }
    ];

    return {
      title: '👆 选择触摸模式',
      subtitle: `当前: ${this.getTouchModeName()}`,
      options: options,
      selectedValue: this.viewModel.touchMode,
      onSelect: (option: OptionItem) => {
        this.handleTouchModeSelect(option);
      }
    };
  }

  /**
   * 处理触摸模式选择
   */
  private handleTouchModeSelect(option: OptionItem): void {
    if (option.value === 'toggle_remote_mouse') {
      const session = this.getSession();
      session?.sendKeys([VirtualKey.VK_CONTROL, VirtualKey.VK_MENU, VirtualKey.VK_SHIFT, VirtualKey.VK_N]);
      this.showToast('已发送切换远程鼠标指针');
    } else {
      this.callbacks.onTouchModeChanged(option.value as string);
      this.showToast(`已切换到${this.getTouchModeName()}`);
    }
  }
}
