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
 * 自定义按键管理器
 *
 * 从 StreamPage 中解耦的自定义按键业务逻辑层。
 * 负责：
 *   - 按键动作分发（键盘/鼠标/手柄/组合/特殊功能）
 *   - 配置的导入/导出（文件选择器交互）
 *   - 状态管理的回调桥接
 *
 * 设计：无状态 Manager，通过回调接口与 UI 层通信。
 */

import { promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { MoonBridge, BUTTON_ACTION_PRESS, BUTTON_ACTION_RELEASE } from './MoonBridge';
import { CustomKeyStore } from './CustomKeyStore';
import {
  KeyAction,
  KeyboardAction,
  MouseButtonAction,
  MouseScrollAction,
  GamepadButtonAction,
  GamepadTriggerAction,
  GamepadStickAction,
  GamepadButton,
  ComboAction,
  ShortcutAction,
  SpecialAction,
  sendShortcutKeys,
} from './CustomKeyTypes';

// =============================================================================
// 回调接口
// =============================================================================

/** 自定义按键管理器需要的外部能力（由 StreamPage 等宿主提供） */
export interface CustomKeyManagerHost {
  /** 获取当前串流 session（用于发送键盘输入） */
  getSession(): SessionLike | null;
  /** 切换虚拟键盘显示 */
  toggleVirtualKeyboard(): void;
  /** 显示 IME 输入法 */
  showIME(): void;
  /** 打开游戏菜单 */
  openGameMenu(): void;
  /** 切换鼠标模式（轨迹球/触控板等） */
  toggleMouseMode(): void;
  /** 切换配置档案 */
  switchProfile(): void;
  /** 切换编辑模式 */
  toggleEditMode(): void;
  /** 通知状态变化（如导入后需要刷新覆盖层） */
  onCustomKeysImported(): void;
}

/** session 只需要 sendKeyboardInput 能力 */
export interface SessionLike {
  sendKeyboardInput(vk: number, flags: number): void;
  /** 发送按键组合（同时按下，延迟后释放） */
  sendKeys(keyCodes: number[]): void;
  /** 发送虚拟手柄输入（内部处理 controller arrival + activeGamepadMask） */
  sendVirtualControllerInput(
    buttonFlags: number,
    leftTrigger: number,
    rightTrigger: number,
    leftStickX: number,
    leftStickY: number,
    rightStickX: number,
    rightStickY: number,
  ): void;
}

// =============================================================================
// Manager
// =============================================================================

export class CustomKeyManager {
  private host: CustomKeyManagerHost;

  /** 共享手柄输入上下文（累积所有按下的手柄按键，参照 Android GamepadInputContext） */
  private gamepadInputMap: number = 0;
  private gamepadLeftTrigger: number = 0;
  private gamepadRightTrigger: number = 0;
  /** 摇杆轴值 (-32767 ~ 32767) */
  private static readonly STICK_MAX = 32767;
  private leftStickX: number = 0;
  private leftStickY: number = 0;
  private rightStickX: number = 0;
  private rightStickY: number = 0;

  constructor(host: CustomKeyManagerHost) {
    this.host = host;
  }

  /**
   * 初始化自定义按键存储
   * 应在串流启动时调用
   */
  async init(): Promise<void> {
    await CustomKeyStore.init();
  }

  /**
   * 重置所有输入状态
   * 在串流结束时调用，确保不残留虚拟按键状态
   */
  reset(): void {
    if (this.gamepadInputMap !== 0 || this.gamepadLeftTrigger !== 0 || this.gamepadRightTrigger !== 0 ||
        this.leftStickX !== 0 || this.leftStickY !== 0 || this.rightStickX !== 0 || this.rightStickY !== 0) {
      this.gamepadInputMap = 0;
      this.gamepadLeftTrigger = 0;
      this.gamepadRightTrigger = 0;
      this.leftStickX = 0;
      this.leftStickY = 0;
      this.rightStickX = 0;
      this.rightStickY = 0;
      this.sendGamepadState();
    }
  }

  // ── 按键动作分发 ──

  /**
   * 处理自定义按键动作（键盘/鼠标/手柄/组合）
   * 由 CustomKeyOverlay 回调触发
   */
  handleAction(action: KeyAction, isDown: boolean): void {
    const session = this.host.getSession();
    if (!session) return;

    switch (action.type) {
      case 'keyboard': {
        const kbAction = action as KeyboardAction;
        session.sendKeyboardInput(kbAction.vk, isDown ? 0x03 : 0x04);
        break;
      }
      case 'mouse': {
        const mouseAction = action as MouseButtonAction;
        MoonBridge.sendMouseButton(
          isDown ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE,
          mouseAction.button
        );
        break;
      }
      case 'mouseScroll': {
        const scrollAction = action as MouseScrollAction;
        if (isDown) {
          MoonBridge.sendMouseHighResScroll(scrollAction.direction > 0 ? 120 : -120);
        }
        break;
      }
      case 'gamepadButton': {
        const gpAction = action as GamepadButtonAction;
        const mask: number = gpAction.mask;
        if (isDown) {
          this.gamepadInputMap |= mask;
        } else {
          this.gamepadInputMap &= ~mask;
        }
        this.sendGamepadState();
        break;
      }
      case 'gamepadTrigger': {
        const trigAction = action as GamepadTriggerAction;
        if (trigAction.trigger === 'left') {
          this.gamepadLeftTrigger = isDown ? 0xFF : 0;
        } else {
          this.gamepadRightTrigger = isDown ? 0xFF : 0;
        }
        this.sendGamepadState();
        break;
      }
      case 'gamepadStick': {
        const stickAction = action as GamepadStickAction;
        const posMax: number = CustomKeyManager.STICK_MAX;
        const negMax: number = 0 - posMax;
        if (stickAction.stick === 'left') {
          if (stickAction.direction === 'up') this.leftStickY = isDown ? negMax : 0;
          else if (stickAction.direction === 'down') this.leftStickY = isDown ? posMax : 0;
          else if (stickAction.direction === 'left') this.leftStickX = isDown ? negMax : 0;
          else if (stickAction.direction === 'right') this.leftStickX = isDown ? posMax : 0;
        } else {
          if (stickAction.direction === 'up') this.rightStickY = isDown ? negMax : 0;
          else if (stickAction.direction === 'down') this.rightStickY = isDown ? posMax : 0;
          else if (stickAction.direction === 'left') this.rightStickX = isDown ? negMax : 0;
          else if (stickAction.direction === 'right') this.rightStickX = isDown ? posMax : 0;
        }
        this.sendGamepadState();
        break;
      }
      case 'combo': {
        const comboAction = action as ComboAction;
        for (const subAction of comboAction.actions) {
          this.handleAction(subAction, isDown);
        }
        break;
      }
      case 'shortcut': {
        // 快捷键：仅在按下时一次性触发完整组合/序列，释放无操作
        if (isDown) {
          const scAction = action as ShortcutAction;
          this.executeShortcut(scAction, session);
        }
        break;
      }
      case 'special': {
        const specialAction = action as SpecialAction;
        if (isDown) {
          this.handleSpecialAction(specialAction.id);
        }
        break;
      }
    }
  }

  /**
   * 发送当前累积的手柄状态
   * 通过 session 的 sendVirtualControllerInput 发送，确保 controllerArrival 已注册。
   * 参照 Android ElementController.sendGamepadEvent()
   */
  private sendGamepadState(): void {
    const session = this.host.getSession();
    if (!session) return;
    session.sendVirtualControllerInput(
      this.gamepadInputMap,
      this.gamepadLeftTrigger,
      this.gamepadRightTrigger,
      this.leftStickX,
      this.leftStickY,
      this.rightStickX,
      this.rightStickY
    );
  }

  /**
   * 处理模拟摇杆的连续移动输入
   * 由 VirtualJoystick 组件直接调用（不经过 handleAction）
   *
   * @param stick 'left' | 'right'
   * @param x 归一化水平值 -1.0 ~ 1.0
   * @param y 归一化垂直值 -1.0 ~ 1.0（屏幕坐标，向下为正）
   */
  handleAnalogStickMovement(stick: string, x: number, y: number): void {
    // 归一化值 → 16-bit 轴值 (0x7FFE = 32766，与 Android 保持一致)
    // Y 轴取反：屏幕坐标 Y 向下为正，游戏协议 Y 向上为正（与 AnalogStick.ets 一致）
    const axisX = Math.round(x * 0x7FFE);
    const negY: number = 0 - y;
    const axisY = Math.round(negY * 0x7FFE);
    if (stick === 'left') {
      this.leftStickX = axisX;
      this.leftStickY = axisY;
    } else {
      this.rightStickX = axisX;
      this.rightStickY = axisY;
    }
    this.sendGamepadState();
  }

  /**
   * 处理模拟摇杆的 L3/R3 点击（双击触发，与 AnalogStick.ets 行为一致）
   * 发送短暂的按下+释放（50ms），而非持续按住。
   * @param stick 'left' | 'right'
   */
  handleAnalogStickClick(stick: string): void {
    const mask: number = stick === 'left' ? GamepadButton.LS : GamepadButton.RS;
    // 按下
    this.gamepadInputMap |= mask;
    this.sendGamepadState();
    // 50ms 后自动释放（与 AnalogStick.ets 一致）
    setTimeout(() => {
      this.gamepadInputMap &= ~mask;
      this.sendGamepadState();
    }, 50);
  }

  /**
   * 执行快捷键动作（一次性组合键或多步序列）
   */
  private executeShortcut(action: ShortcutAction, session: SessionLike): void {
    sendShortcutKeys((keys: number[]) => session.sendKeys(keys), action.keys, action.keySequence);
  }

  /**
   * 处理自定义按键的特殊功能
   */
  handleSpecialAction(actionId: string): void {
    switch (actionId) {
      case 'toggleKeyboard':
        this.host.toggleVirtualKeyboard();
        break;
      case 'toggleIME':
        this.host.showIME();
        break;
      case 'toggleMouseMode':
        this.host.toggleMouseMode();
        break;
      case 'switchProfile':
        this.host.switchProfile();
        break;
      case 'openGameMenu':
        this.host.openGameMenu();
        break;
      case 'editMode':
        this.host.toggleEditMode();
        break;
      case 'none':
      default:
        break;
    }
  }

  // ── 导入/导出 ──

  /**
   * 导出当前配置到 JSON 文件
   * 打开系统文件保存选择器
   */
  async exportProfile(): Promise<void> {
    try {
      const json = await CustomKeyStore.exportProfile();
      const profileName = await CustomKeyStore.getActiveProfileName();

      const documentPicker = new picker.DocumentViewPicker();
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = [`moonlight-keys-${profileName}.json`];
      saveOptions.fileSuffixChoices = ['.json'];
      const uris = await documentPicker.save(saveOptions);

      if (uris && uris.length > 0) {
        const file = fileIo.openSync(uris[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, json);
        fileIo.closeSync(file);
        promptAction.showToast({ message: `配置 "${profileName}" 已导出`, duration: 2000 });
      }
    } catch (e) {
      console.error('[CustomKeyManager] 导出失败:', JSON.stringify(e));
      promptAction.showToast({ message: '导出失败', duration: 2000 });
    }
  }

  /**
   * 从 JSON 文件导入配置
   * 打开系统文件选择器
   */
  async importProfile(): Promise<boolean> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const selectOptions = new picker.DocumentSelectOptions();
      selectOptions.maxSelectNumber = 1;
      selectOptions.fileSuffixFilters = ['.json'];
      const uris = await documentPicker.select(selectOptions);

      if (uris && uris.length > 0) {
        const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
        const stat = fileIo.statSync(file.fd);
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buf);
        fileIo.closeSync(file);

        const json = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
        const success = await CustomKeyStore.importProfile(json);

        if (success) {
          const name = await CustomKeyStore.getActiveProfileName();
          promptAction.showToast({ message: `配置 "${name}" 已导入`, duration: 2000 });
          this.host.onCustomKeysImported();
          return true;
        } else {
          promptAction.showToast({ message: '导入失败：配置文件格式无效', duration: 2000 });
        }
      }
    } catch (e) {
      console.error('[CustomKeyManager] 导入失败:', JSON.stringify(e));
      promptAction.showToast({ message: '导入失败', duration: 2000 });
    }
    return false;
  }
}
