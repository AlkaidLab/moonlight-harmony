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
 * 串流页面输入处理器
 *
 * 封装键盘、鼠标、滚轮、音量键、按键拦截器等所有输入处理逻辑，
 * 从 StreamPage 中解耦以降低单文件复杂度。
 */
import { display, window, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { StreamViewModel } from '../viewmodel/StreamViewModel';
import { GamepadManager } from '../service/GamepadManager';

import {
  MoonBridge,
  BUTTON_ACTION_PRESS,
  BUTTON_ACTION_RELEASE,
  BUTTON_LEFT,
  BUTTON_MIDDLE,
  BUTTON_RIGHT,
  BUTTON_X1,
  BUTTON_X2,
  KEY_ACTION_DOWN,
  KEY_ACTION_UP,
  MODIFIER_SHIFT,
  MODIFIER_CTRL,
  MODIFIER_ALT,
  MODIFIER_META
} from '../service/MoonBridge';
import { KeyboardTranslator } from '../service/KeyboardTranslator';
import { InputInterceptorService, MouseInterceptorService } from '../service/InputInterceptorService';

export class StreamInputHandler {
  // ── 键盘修饰键状态追踪（位掩码：Shift=0x01, Ctrl=0x02, Alt=0x04, Meta=0x08）──
  private modifierFlags: number = 0;

  // ── 鼠标拦截器（绕过 ArkUI 帧率限制，全速鼠标轮询）──
  private mouseInterceptorActive: boolean = false;

  // ── XComponent 实际渲染尺寸（vp，用于绝对模式坐标归一化）──
  private viewWidthVp: number = 0;
  private viewHeightVp: number = 0;

  // ── 屏幕物理尺寸（px，用于相对模式边缘检测和 configure 传参）──
  private screenWidthPx: number = 1080;
  private screenHeightPx: number = 2400;


  // ── 应用音频音量回退（C++ 层无法回注音量键时的应用级音量补偿）──
  private appVolume: number = 1.0;
  private preMuteVolume: number = 1.0;
  private static readonly VOLUME_STEP: number = 0.1;

  // ── 外部依赖 ──
  private viewModel: StreamViewModel | null = null;
  private gamepadManager: GamepadManager | null = null;

  /**
   * 初始化依赖项
   */
  initialize(viewModel: StreamViewModel, gamepadManager: GamepadManager): void {
    this.viewModel = viewModel;
    this.gamepadManager = gamepadManager;
  }

  /**
   * 重置所有输入状态（串流停止时调用）
   */
  resetState(): void {
    this.modifierFlags = 0;
    this.stopMouseInterceptor();
  }

  // ==================== 鼠标高速轮询 ====================

  /**
   * 启动鼠标高速轮询
   *
   * 优先尝试 C++ 层 OH_Input_AddMouseEventMonitor（需要 INPUT_MONITORING 权限），
   * 以硬件轮询率直接调用 moonlight API。
   *
   * @param viewWidth 视图宽度 (vp)
   * @param viewHeight 视图高度 (vp)
   * @returns true 表示 C++ Monitor 已启动（不需要 keepalive），
   *          false 表示 Monitor 不可用（调用方应启用 keepalive 动画来保持 ArkUI 帧率）
   */
  startMouseInterceptor(viewWidth: number, viewHeight: number): boolean {
    const mouseInterceptor = MouseInterceptorService.getInstance();

    // 保存 XComponent 实际尺寸，供 ArkUI 回退路径绝对模式使用
    this.viewWidthVp = viewWidth;
    this.viewHeightVp = viewHeight;

    // 获取屏幕物理尺寸
    let screenWidthPx = 1080;
    let screenHeightPx = 2400;
    try {
      const displayInfo = display.getDefaultDisplaySync();
      screenWidthPx = displayInfo.width;
      screenHeightPx = displayInfo.height;
    } catch (_) {}

    // 保存屏幕尺寸供后续 configure 调用使用
    this.screenWidthPx = screenWidthPx;
    this.screenHeightPx = screenHeightPx;

    // 读取游戏鼠标模式设置
    const relativeMode = this.viewModel?.inputSettings?.gameMouseMode ?? false;

    // 初始使用屏幕尺寸（全屏时完全正确），窗口模式下异步获取实际窗口矩形更新
    mouseInterceptor.configure(0, 0, screenWidthPx, screenHeightPx,
                                screenWidthPx, screenHeightPx, relativeMode);

    const result = mouseInterceptor.start();
    if (result === 0) {
      this.mouseInterceptorActive = true;
      const modeLabel = relativeMode ? '相对/游戏' : '绝对/桌面';
      console.info(`StreamInputHandler: C++ 鼠标 Monitor 已启动 (${screenWidthPx}x${screenHeightPx}px, ${modeLabel})`);

      // 异步获取实际窗口矩形（窗口模式下与屏幕尺寸不同）
      this.fetchAndUpdateWindowRect();
      return true;
    }

    this.mouseInterceptorActive = false;
    console.info(`StreamInputHandler: C++ Monitor 不可用 (${result})，将使用 keepalive 动画保持 .onMouse 全速`);
    return false;
  }

  /**
   * 更新 XComponent 在屏幕上的精确位置（由 onAreaChange 回调触发）
   * C++ 鼠标 Monitor 使用窗口矩形映射，onAreaChange 时重新获取窗口矩形
   */
  updateXComponentScreenPosition(screenX: number, screenY: number): void {
    // 窗口大小或位置可能变化，重新获取窗口矩形
    if (this.mouseInterceptorActive) {
      this.fetchAndUpdateWindowRect();
    }
  }

  /**
   * 异步获取窗口矩形并更新到 C++ 层
   * 全屏模式下窗口矩形=屏幕尺寸（已在初始化时设置），
   * 窗口模式下获取实际窗口位置和尺寸
   */
  private fetchAndUpdateWindowRect(): void {
    try {
      const context = getContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((win: window.Window) => {
        const rect = win.getWindowProperties().windowRect;
        if (rect && this.mouseInterceptorActive) {
          const relativeMode = this.viewModel?.inputSettings?.gameMouseMode ?? false;
          MouseInterceptorService.getInstance().configure(
            rect.left, rect.top, rect.width, rect.height,
            this.screenWidthPx, this.screenHeightPx, relativeMode
          );
          console.info(`StreamInputHandler: 窗口矩形已更新 (${rect.left},${rect.top},${rect.width}x${rect.height})`);
        }
      }).catch((err: Error) => {
        console.warn(`StreamInputHandler: 获取窗口矩形失败: ${err?.message}`);
      });
    } catch (_) {}
  }

  /**
   * 停止鼠标高速轮询
   */
  stopMouseInterceptor(): void {
    if (!this.mouseInterceptorActive) return;
    MouseInterceptorService.getInstance().stop();
    this.mouseInterceptorActive = false;
  }

  /**
   * 查询 C++ Monitor 是否激活
   */
  isMouseInterceptorActive(): boolean {
    return this.mouseInterceptorActive;
  }

  // ==================== 鼠标输入 ====================

  /**
   * 处理物理鼠标事件（挂载在 XComponent 上以获取原生 Surface 级事件频率）
   * 当鼠标拦截器启用时，鼠标事件由 C++ 层直接处理，此方法不再执行。
   */
  handleMouseEvent(event: MouseEvent): void {
    if (!this.viewModel?.isConnected) return;

    // 阻止事件继续传递，避免触发系统默认行为（无论 Monitor 是否启用都要调用）
    event.stopPropagation();

    // Monitor 启用时鼠标事件已由 C++ 层直接处理，跳过 ArkTS 处理避免重复
    if (this.mouseInterceptorActive) return;

    if (event.action === MouseAction.Move) {
      // 绝对模式：发送坐标位置
      // event.x/y 为相对于 XComponent 的 vp 坐标，用 XComponent 尺寸作为参考域
      MoonBridge.sendMousePosition(
        Math.round(event.x), Math.round(event.y),
        this.viewWidthVp, this.viewHeightVp
      );
    } else if (event.action === MouseAction.Press || event.action === MouseAction.Release) {
      const button = this.mapMouseButton(event.button);
      if (button > 0) {
        const action = event.action === MouseAction.Press
          ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE;
        MoonBridge.sendMouseButton(action, button);
      }
    }
  }

  // ==================== 滚轮输入 ====================

  /**
   * 处理鼠标滚轮事件（挂载在 XComponent 上以确保 native surface 能接收轴事件）
   */
  handleAxisEvent(event: AxisEvent): void {
    if (!this.viewModel?.isConnected) return;

    const vertical = event.getVerticalAxisValue();
    const horizontal = event.getHorizontalAxisValue();

    // scrollStep: 系统「鼠标滚轮速度」设置的放大倍数（文档：上报数值受系统放大倍数影响）
    // 对于串流，我们模拟物理鼠标→应发送原始每格数据，让远端 PC 应用自己的滚轮速度
    // 因此需要除以 scrollStep 归一化掉本地放大倍数
    const scrollStep = (event.scrollStep && event.scrollStep > 0) ? event.scrollStep : 1;

    // HarmonyOS 滚轮：向前滚动（远离用户）= 负值，向后滚动（靠近用户）= 正值
    // Moonlight sendMouseHighResScroll：正值 = 向上滚动（远离用户）
    // 因此需要取反
    // 归一化后的值 / scrollStep 为每格原始值，× 8 = 120 units（Windows WHEEL_DELTA）
    if (vertical !== 0) {
      const scrollAmount = Math.round(-vertical / scrollStep * 8);
      console.info(`滚轮: vertical=${vertical.toFixed(2)}, scrollStep=${scrollStep}, send=${scrollAmount}`);
      MoonBridge.sendMouseHighResScroll(scrollAmount);
    }

    // 水平滚动（同样取反、归一化）
    if (horizontal !== 0) {
      MoonBridge.sendMouseHighResHScroll(Math.round(-horizontal / scrollStep * 8));
    }
  }

  // ==================== 键盘输入 ====================

  /**
   * 处理键盘/手柄按键事件
   *
   * 区分手柄按键与键盘按键：
   * - 手柄按键（传统 InputKit 19-22/96-110，GCK 2300-2320）→ GamepadManager
   * - 键盘按键（2000-2120）→ 翻译为 Windows VK 码后通过 sendKeyboardInput 发送
   *
   * @param event 按键事件
   * @returns 是否已处理该事件
   */
  handleKeyEvent(event: KeyEvent): boolean {
    const keyCode = event.keyCode;
    const isGamepadKey = KeyboardTranslator.isGamepadKey(keyCode);

    if (!this.viewModel?.isConnected) {
      // 即使未连接，也要拦截手柄按键，防止触发系统导航
      return isGamepadKey;
    }

    if (isGamepadKey) {
      // 手柄按键 → 转发给 GamepadManager
      const deviceId = event.deviceId ?? 0;
      this.gamepadManager?.handleKeyEvent(
        deviceId,
        keyCode,
        event.type === KeyType.Down
      );
      return true;
    }

    // D-pad 方向键 (2012-2015) - 仅在有 GCK 手柄实际连接时消费，避免与 GCK Axis 路径双发
    // 蓝牙手柄 D-pad 会同时产生 GCK Axis 事件和 KeyEvent(2012-2015)
    // GCK Axis 已发送手柄 D-pad，这里如果再翻译成键盘方向键 VK_UP 等就会"按一下走两格"
    // 注意：仅检查 isUsingGameControllerKit() 会在无手柄时也过滤掉物理键盘方向键
    if (keyCode >= 2012 && keyCode <= 2015 && this.gamepadManager?.hasActiveGcGamepad()) {
      return true; // GCK 手柄已接管 D-pad，消费事件
    }

    // 键盘按键 → 翻译为 Windows VK 码并发送
    if (KeyboardTranslator.isKeyboardKey(keyCode)) {
      const vkCode = KeyboardTranslator.translate(keyCode);
      if (vkCode > 0) {
        this.updateModifierFlags(vkCode, event.type === KeyType.Down);
        const session = this.viewModel?.getSession();
        if (session) {
          const keyAction = event.type === KeyType.Down ? KEY_ACTION_DOWN : KEY_ACTION_UP;
          session.sendKeyboardInput(vkCode, keyAction, this.modifierFlags);
        }
      }
      return true;
    }

    // 未识别的按键，不拦截
    return false;
  }

  // ==================== 按键拦截器 ====================

  /**
   * 启动按键事件拦截器
   * 拦截被系统劫持的手柄按键和特殊键盘按键，转发给 GamepadManager / StreamingSession 处理
   */
  startKeyInterceptor(): void {
    const result = InputInterceptorService.getInstance().start((event) => {
      if (!this.viewModel?.isConnected) {
        return;
      }
      const keyCode = event.keyCode;
      // action: 1=KEY_DOWN, 2=KEY_UP
      const isPressed = event.action === 1;

      // 1. 手柄按键范围 (2300-2320 GC Kit / 110 标准 Mode) - 转发给 GamepadManager
      if ((keyCode >= 2300 && keyCode <= 2320) || keyCode === 110) {
        this.gamepadManager?.handleKeyEvent(0, keyCode, isPressed);
        return;
      }

      // 2. D-pad 方向键 (2012-2015) - GCK 活跃时消费掉，避免与 GCK Axis 双发
      //    GCK Axis 已经处理了手柄 D-pad，这里如果再翻译成键盘方向键发送
      //    会导致游戏同时收到手柄 D-pad + 键盘方向键 = "按一下走两格"
      if (keyCode >= 2012 && keyCode <= 2015) {
        if (this.gamepadManager?.hasActiveGcGamepad()) {
          // GCK 手柄已接管 D-pad，丢弃拦截器中的方向键事件
          return;
        }
        // 没有 GCK 设备时，作为键盘方向键正常转发（后面的 isKeyboardKey 分支会处理）
      }

      // 3. 音量键 (16=VOLUME_UP, 17=VOLUME_DOWN, 22=VOLUME_MUTE)
      //    C++ 层已优先尝试回注到系统；到达这里说明回注失败，用应用级音量补偿
      if (keyCode === 16 || keyCode === 17 || keyCode === 22) {
        if (isPressed) {
          this.handleVolumeKey(keyCode);
        }
        return;
      }

      // 4. 键盘按键（2000-2120）— 翻译为 Windows VK 码后发送
      if (KeyboardTranslator.isKeyboardKey(keyCode)) {
        const vkCode = KeyboardTranslator.translate(keyCode);
        if (vkCode > 0) {
          this.updateModifierFlags(vkCode, isPressed);
          const session = this.viewModel?.getSession();
          if (session) {
            const keyAction = isPressed ? KEY_ACTION_DOWN : KEY_ACTION_UP;
            session.sendKeyboardInput(vkCode, keyAction, this.modifierFlags);
          }
        }
        return;
      }

      // 5. 容易被系统劫持的特殊键盘按键 - 转发到主机
      //    Home(1), Back(2), 多任务(3),
      //    媒体键: Play/Pause(10), Stop(11), Next(12), Previous(13)
      const SYSTEM_HIJACKED_KEYS: Set<number> = new Set([
        1, 2, 3,                   // Home, Back, Recent
        10, 11, 12, 13             // Media keys
      ]);

      if (SYSTEM_HIJACKED_KEYS.has(keyCode)) {
        const session = this.viewModel?.getSession();
        if (session) {
          // HarmonyOS keyCode -> Windows VK 映射
          const vkCode = this.mapSystemKeyToVK(keyCode);
          if (vkCode > 0) {
            const keyAction = isPressed ? 0x03 : 0x04; // KEY_DOWN : KEY_UP
            session.sendKeyboardInput(vkCode, keyAction, this.modifierFlags);
          }
        }
      }
    });
    if (result !== 0) {
      console.warn(`StreamPage: 按键拦截器启动失败 (${result})，手柄 Home 键可能被系统劫持`);
      promptAction.showToast({
        message: '按键反劫持启动失败：蓝牙手柄 Home 键可能导致退出（需系统级签名）',
        duration: 3500
      });
    }
  }

  // ==================== 映射工具 ====================

  /**
   * 将 HarmonyOS 系统按键码映射到 Windows 虚拟键码
   */
  private mapSystemKeyToVK(keyCode: number): number {
    switch (keyCode) {
      case 1: return 0; // Home - 不转发（避免触发 Windows 开始菜单）
      case 2: return 0x1B; // Back → VK_ESCAPE
      case 3: return 0; // Recent/多任务 - 不转发
      case 10: return 0xB3; // Media Play/Pause → VK_MEDIA_PLAY_PAUSE
      case 11: return 0xB2; // Media Stop → VK_MEDIA_STOP
      case 12: return 0xB0; // Media Next → VK_MEDIA_NEXT_TRACK
      case 13: return 0xB1; // Media Previous → VK_MEDIA_PREV_TRACK
      default: return 0;
    }
  }

  /**
   * 将 HarmonyOS MouseButton 映射到 MoonBridge 鼠标按钮常量
   */
  private mapMouseButton(button: MouseButton): number {
    switch (button) {
      case MouseButton.Left: return BUTTON_LEFT;       // 0x01
      case MouseButton.Middle: return BUTTON_MIDDLE;   // 0x02
      case MouseButton.Right: return BUTTON_RIGHT;     // 0x03
      case MouseButton.Back: return BUTTON_X1;         // 0x04
      case MouseButton.Forward: return BUTTON_X2;      // 0x05
      default: return 0;
    }
  }

  /**
   * 根据 Windows VK 码更新修饰键状态位掩码
   * 参照 Android 版 Game.java handleSpecialKeys() 的实现
   *
   * @param vkCode Windows 虚拟键码
   * @param isDown 是否按下
   */
  private updateModifierFlags(vkCode: number, isDown: boolean): void {
    let mask = 0;
    switch (vkCode) {
      case 0xA0: // VK_LSHIFT
      case 0xA1: // VK_RSHIFT
        mask = MODIFIER_SHIFT;
        break;
      case 0xA2: // VK_LCONTROL
      case 0xA3: // VK_RCONTROL
        mask = MODIFIER_CTRL;
        break;
      case 0xA4: // VK_LMENU (Alt Left)
      case 0xA5: // VK_RMENU (Alt Right)
        mask = MODIFIER_ALT;
        break;
      case 0x5B: // VK_LWIN
      case 0x5C: // VK_RWIN
        mask = MODIFIER_META;
        break;
    }
    if (mask !== 0) {
      if (isDown) {
        this.modifierFlags |= mask;
      } else {
        this.modifierFlags &= ~mask;
      }
    }
  }

  // ==================== 音量键 ====================

  /**
   * 处理音量键事件（回退路径）
   * C++ 层优先尝试 OH_Input_InjectKeyEvent 回注到系统；
   * 如果回注失败（无权限/API 不可用），音量键事件到达这里，
   * 用 OH_AudioRenderer 的应用级音量补偿。
   */
  private handleVolumeKey(keyCode: number): void {
    const session = this.viewModel?.getSession();
    if (!session) {
      return;
    }

    if (keyCode === 16) {
      this.appVolume = Math.min(1.0, this.appVolume + StreamInputHandler.VOLUME_STEP);
    } else if (keyCode === 17) {
      this.appVolume = Math.max(0.0, this.appVolume - StreamInputHandler.VOLUME_STEP);
    } else if (keyCode === 22) {
      if (this.appVolume > 0) {
        this.preMuteVolume = this.appVolume;
        this.appVolume = 0.0;
      } else {
        this.appVolume = this.preMuteVolume > 0 ? this.preMuteVolume : 1.0;
      }
    }

    this.appVolume = Math.round(this.appVolume * 10) / 10;
    session.setAudioVolume(this.appVolume);

    const percent = Math.round(this.appVolume * 100);
    const icon = this.appVolume === 0 ? '🔇' : (this.appVolume < 0.5 ? '🔉' : '🔊');
    promptAction.showToast({
      message: `${icon} 音量 ${percent}%`,
      duration: 1000
    });
  }
}
