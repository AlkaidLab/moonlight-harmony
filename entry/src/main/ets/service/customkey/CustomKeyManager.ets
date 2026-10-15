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
import { MoonBridge, BUTTON_ACTION_PRESS, BUTTON_ACTION_RELEASE } from '../streaming/MoonBridge';
import { CustomKeyStore } from './CustomKeyStore';
import { ToastQueue } from '../../utils/ToastQueue';
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
  DPadAction,
} from './CustomKeyTypes';
import { KeyActionPulseRunner } from './KeyMenuController';
import { Logger } from '../../common/Logger';
import { StringUtil } from '../../utils/StringUtil';

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
  /** 隐藏自定义按键覆盖层 */
  hideCustomKeys(): void;
  /** 通知状态变化（如导入后需要刷新覆盖层） */
  onCustomKeysImported(): void;
}

/** session 只需要 sendKeyboardInput 能力 */
export interface SessionLike {
  sendKeyboardInput(vk: number, flags: number, modifiers?: number): void;
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
  private keyboardHolds: Map<number, number> = new Map();
  private mouseHolds: Map<number, number> = new Map();
  private gamepadButtonHolds: Map<number, number> = new Map();
  private triggerHolds: Map<number, number> = new Map();
  private stickDirectionHolds: Map<number, number> = new Map();
  private dpadDirection: number = 0;
  private pulses: KeyActionPulseRunner = new KeyActionPulseRunner();

  constructor(host: CustomKeyManagerHost) {
    this.host = host;
    this.pulses.onAction = (action: KeyAction, isDown: boolean): void => this.handleAction(action, isDown);
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
    this.pulses.reset();
    const session = this.host.getSession();
    const keyboardKeys = Array.from(this.keyboardHolds.keys()).reverse();
    for (const vk of keyboardKeys) {
      this.keyboardHolds.delete(vk);
      session?.sendKeyboardInput(vk, 0x04, this.keyboardModifiers());
    }
    this.mouseHolds.forEach((_count: number, button: number) => MoonBridge.sendMouseButton(BUTTON_ACTION_RELEASE, button));
    this.keyboardHolds.clear();
    this.mouseHolds.clear();
    this.gamepadButtonHolds.clear();
    this.triggerHolds.clear();
    const hadDirections = this.stickDirectionHolds.size > 0 || this.dpadDirection !== 0;
    this.stickDirectionHolds.clear();
    this.dpadDirection = 0;
    if (this.gamepadInputMap !== 0 || this.gamepadLeftTrigger !== 0 || this.gamepadRightTrigger !== 0 ||
        this.leftStickX !== 0 || this.leftStickY !== 0 || this.rightStickX !== 0 || this.rightStickY !== 0 || hadDirections) {
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

  /** 每个逻辑输入按住计数；最后一个来源松开时才向主机发送释放。 */
  private updateHold(holds: Map<number, number>, id: number, isDown: boolean): boolean {
    const count = Math.max(0, (holds.get(id) ?? 0) + (isDown ? 1 : -1));
    if (count > 0) holds.set(id, count);
    else holds.delete(id);
    return count > 0;
  }

  private resolveStickAxis(stick: number, negative: number, positive: number, analog: number): number {
    const neg = this.stickDirectionHolds.has(stick * 4 + negative);
    const pos = this.stickDirectionHolds.has(stick * 4 + positive);
    if (!neg && !pos) return analog;
    return (pos ? CustomKeyManager.STICK_MAX : 0) - (neg ? CustomKeyManager.STICK_MAX : 0);
  }

  private keyboardModifiers(): number {
    let modifiers = 0;
    this.keyboardHolds.forEach((_count: number, vk: number) => {
      if (vk === 0x10 || vk === 0xA0 || vk === 0xA1) modifiers |= 0x01;
      else if (vk === 0x11 || vk === 0xA2 || vk === 0xA3) modifiers |= 0x02;
      else if (vk === 0x12 || vk === 0xA4 || vk === 0xA5) modifiers |= 0x04;
      else if (vk === 0x5B || vk === 0x5C) modifiers |= 0x08;
    });
    return modifiers;
  }

  /** 视角区的连续输入独立于按下/释放分发，永远只发送相对鼠标位移。 */
  handleMouseLookMovement(deltaX: number, deltaY: number): void {
    if (!this.host.getSession()) return;
    MoonBridge.sendMouseMove(deltaX, deltaY);
  }

  handlePulseAction(action: KeyAction): void {
    if (this.host.getSession()) this.pulses.execute(action);
  }

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
        const modifiersBefore = this.keyboardModifiers();
        const wasHeld = this.keyboardHolds.has(kbAction.vk);
        const held = this.updateHold(this.keyboardHolds, kbAction.vk, isDown);
        if (wasHeld !== held) session.sendKeyboardInput(kbAction.vk, held ? 0x03 : 0x04,
          held ? modifiersBefore : this.keyboardModifiers());
        break;
      }
      case 'mouse': {
        const mouseAction = action as MouseButtonAction;
        const wasHeld = this.mouseHolds.has(mouseAction.button);
        const held = this.updateHold(this.mouseHolds, mouseAction.button, isDown);
        if (wasHeld !== held) MoonBridge.sendMouseButton(held ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, mouseAction.button);
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
        for (let bit = 0; bit < 32; bit++) {
          const flag = 1 << bit;
          if ((mask & flag) === 0) continue;
          if (this.updateHold(this.gamepadButtonHolds, flag, isDown)) this.gamepadInputMap |= flag;
          else this.gamepadInputMap &= ~flag;
        }
        this.sendGamepadState();
        break;
      }
      case 'gamepadTrigger': {
        const trigAction = action as GamepadTriggerAction;
        if (trigAction.trigger === 'left') {
          this.gamepadLeftTrigger = this.updateHold(this.triggerHolds, 0, isDown) ? 0xFF : 0;
        } else {
          this.gamepadRightTrigger = this.updateHold(this.triggerHolds, 1, isDown) ? 0xFF : 0;
        }
        this.sendGamepadState();
        break;
      }
      case 'gamepadStick': {
        const stickAction = action as GamepadStickAction;
        const directions: string[] = ['left', 'right', 'up', 'down'];
        const direction = directions.indexOf(stickAction.direction);
        if (direction < 0) break;
        this.updateHold(this.stickDirectionHolds, (stickAction.stick === 'left' ? 0 : 4) + direction, isDown);
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
          this.pulses.execute(scAction, 25);
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
      this.gamepadInputMap | this.dpadDirection,
      this.gamepadLeftTrigger,
      this.gamepadRightTrigger,
      this.resolveStickAxis(0, 0, 1, this.leftStickX),
      this.resolveStickAxis(0, 2, 3, this.leftStickY),
      this.resolveStickAxis(1, 0, 1, this.rightStickX),
      this.resolveStickAxis(1, 2, 3, this.rightStickY)
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
    this.pulses.execute({ type: 'gamepadButton', mask: mask } as GamepadButtonAction, 50);
  }

  /**
   * 处理十字键盘 (D-Pad) 方向变化
   * 由 VirtualDPad 组件直接调用。
   * direction 为方向位掩码组合（GamepadButton.UP/DOWN/LEFT/RIGHT），0 = 松开/无方向。
   */
  handleDPadDirectionChange(direction: number): void {
    // D-Pad 持续状态和菜单/常驻按钮独立合并，任一来源释放都不会清掉另一方。
    this.dpadDirection = direction & GamepadButton.DPAD_MASK;
    this.sendGamepadState();
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
      case 'hideCustomKeys':
        this.host.hideCustomKeys();
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
        ToastQueue.show({ message: `配置 "${profileName}" 已导出`, duration: 2000 });
      }
    } catch (e) {
      Logger.error('CustomKeyManager', '[CustomKeyManager] 导出失败:', JSON.stringify(e));
      ToastQueue.show({ message: '导出失败', duration: 2000 });
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

        const json = StringUtil.uint8ArrayToString(new Uint8Array(buf));
        const success = await CustomKeyStore.importProfile(json);

        if (success) {
          const name = await CustomKeyStore.getActiveProfileName();
          ToastQueue.show({ message: `配置 "${name}" 已导入`, duration: 2000 });
          this.host.onCustomKeysImported();
          return true;
        } else {
          ToastQueue.show({ message: '导入失败：配置文件格式无效', duration: 2000 });
        }
      }
    } catch (e) {
      Logger.error('CustomKeyManager', '[CustomKeyManager] 导入失败:', JSON.stringify(e));
      ToastQueue.show({ message: '导入失败', duration: 2000 });
    }
    return false;
  }
}
