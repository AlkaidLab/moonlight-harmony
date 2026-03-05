/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { inputDevice } from '@kit.InputKit';
import { UsbDriverService, UsbDriverListener, AbstractController, ButtonFlags } from './usbdriver/index';
import { 
  gameControllerService, 
  AxisType, 
  GameControllerDeviceInfo 
} from './GameControllerService';
import { SettingsService, SettingsKeys } from './SettingsService';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { DeviceSensorService, LI_MOTION_TYPE_ACCEL, LI_MOTION_TYPE_GYRO } from './DeviceSensorService';
import { MoonBridge } from './MoonBridge';
import { MouseEmulationService, MouseEmulationCallback } from './MouseEmulationService';
import { GamepadVibrationService } from './GamepadVibrationService';
import {
  GamepadState, GamepadInfo, GamepadInputListener, DeviceBusType,
  MoonlightButton, GCButton2313Action, GCButton2313ActionCallback,
  MoonlightControllerType, VendorId, ProductId,
  AXIS_MAX, TRIGGER_MAX, SPECIAL_KEYCODE_MIN, SPECIAL_KEYCODE_MAX,
  buttonMap, gcButtonMap, GAMEPAD_NAME_KEYWORDS, NON_GAMEPAD_KEYWORDS, isNonGamepadByName,
  hasStrongNonGamepadKeyword
} from './GamepadTypes';

// 重新导出公共类型，保持向后兼容
export {
  GamepadState, GamepadInfo, GamepadInputListener, DeviceBusType,
  MoonlightButton, GCButton2313Action, GCButton2313ActionCallback,
  MoonlightControllerType
} from './GamepadTypes';
export { MouseEmulationCallback } from './MouseEmulationService';

// ==================== 手柄输入管理器 ====================

/**
 * 手柄输入管理器
 * 
 * 优先使用 Game Controller Kit (API 21+) 提供统一的 USB/蓝牙手柄支持
 * 如果不可用则回退到 InputKit + USB 驱动方案
 */
export class GamepadManager implements UsbDriverListener {
  private static instance: GamepadManager;
  private static readonly DEBUG = false;
  private static readonly MAX_CONTROLLERS = 4;
  
  // 监听器
  private listener: GamepadInputListener | null = null;
  
  // 通用状态
  private connectedDevices = new Map<number, string>();
  private deviceStates = new Map<number, GamepadState>();
  private deviceInfoMap = new Map<number, GamepadInfo>();
  
  // USB 驱动服务
  private usbDriverService: UsbDriverService;
  
  // Game Controller Kit 状态
  private useGameControllerKit = false;
  /** USB 驱动是否已启用（混合模式：GCK 处理蓝牙，UsbDriver 处理 USB 震动/附加功能） */
  private useUsbDriverMode = false;
  /** 输入模式是否已确定（loadUsbDriverSetting 异步完成后置 true）。
   *  在此之前 setListener 不应扫描/通知设备，避免传统路径与 GCK 竞争产生幽灵手柄。 */
  private modeInitialized = false;
  private gcDeviceIdToSlot = new Map<string, number>();
  private gcDeviceStates = new Map<string, GamepadState>();
  private gcPhysicalAddressToDeviceId = new Map<string, string>();  // 物理地址→主设备ID，用于去重同一物理手柄的多个HID接口
  private gcDeviceInfoCache = new Map<string, GameControllerDeviceInfo>();  // 设备信息缓存，用于后备去重
  
  // 槽位管理（统一 GC Kit、InputKit 和 USB 驱动的槽位分配）
  private deviceKeyToSlot = new Map<string, number>();
  private slotOccupied = [false, false, false, false];
  private controllerIdToDeviceKey = new Map<number, string>();
  private usbDeviceKeyToId = new Map<string, number>();
  
  // 设备传感器回退
  private deviceSensorService: DeviceSensorService;
  private sensorFallbackEnabled = false;  // 用户设置：是否启用设备传感器回退
  private gamepadMotionSensorsEnabled = true;  // 用户设置：是否启用手柄运动传感器
  private usingDeviceSensorFallback = false;  // 当前是否正在使用设备传感器回退
  
  // 传感器数据发送回调（由 StreamingSession 设置）
  private sensorDataCallback: ((controllerNumber: number, motionType: number, x: number, y: number, z: number) => void) | null = null;

  // 2313 自定义动作设置
  private gcButton2313Action: GCButton2313Action = 'guide';
  private gcButton2313ActionCallback: GCButton2313ActionCallback | null = null;
  
  // ==================== 解耦的子服务 ====================
  /** 鼠标模拟服务（从本类解耦） */
  private mouseEmulationService: MouseEmulationService;
  /** 震动处理服务（从本类解耦） */
  private vibrationService: GamepadVibrationService;
  
  // ==================== 通道级D-pad去重 ====================
  /** GCK设备中已通过 Axis(DPAD) 通道提供D-pad数据的设备集合。
   *  当 Axis 通道活跃时，Button/KeyEvent 通道的 D-pad 事件被静默丢弃 */
  private gcDpadAxisActive = new Set<string>();
  /** 传统模式中已通过 ABS_HAT0X/Y 轴提供D-pad数据的设备集合 */
  private dpadAxisActive = new Set<number>();

  /** GCK 轴事件合并：Android 一次 MotionEvent 含所有轴只发 1 包，我们按轴类型多次回调会发 N 包，此处合并为每 tick 每 slot 只通知一次 */
  private gcAxisFlushPending = new Set<number>();
  private gcAxisFlushTimerId: number = -1;
  
  // ==================== 长按 Start → 返回菜单 ====================
  /** Start 按键按下的时间戳 (ms)，0 表示未按下 */
  private startKeyDownTime: number = 0;
  /** 长按 Start 的阈值 (ms)，对齐 Android START_DOWN_TIME_MOUSE_MODE_MS */
  private static readonly START_LONG_PRESS_MS = 750;
  /** 是否启用长按 Start 显示返回菜单（由设置控制） */
  private enableStartKeyMenu = true;
  /** 长按 Start 显示菜单的回调 */
  private showGameMenuCallback: (() => void) | null = null;

  /**
   * Start 长按检测（handleGCButtonEvent 和 handleKeyEvent 共用）
   * @returns true 表示长按已触发，调用方应吐掉此次按键释放
   */
  private handleStartLongPress(isPressed: boolean): boolean {
    if (isPressed) {
      this.startKeyDownTime = Date.now();
    } else if (this.startKeyDownTime > 0) {
      const pressDuration = Date.now() - this.startKeyDownTime;
      this.startKeyDownTime = 0;
      if (pressDuration > GamepadManager.START_LONG_PRESS_MS && this.enableStartKeyMenu) {
        this.showGameMenuCallback?.();
        return true;
      }
    }
    return false;
  }
  
  private constructor() {
    this.usbDriverService = UsbDriverService.getInstance();
    this.deviceSensorService = DeviceSensorService.getInstance();
    this.mouseEmulationService = new MouseEmulationService();
    this.vibrationService = new GamepadVibrationService(this.usbDriverService, this.deviceKeyToSlot);
    this.loadGCButtonMappingSettings();
    this.loadSensorSettings();
    this.loadUsbDriverSetting();
    this.loadStartKeyMenuSetting();
  }

  /**
   * 加载 USB 驱动设置并决定输入模式
   * 
   * 三种模式：
   * 1. 纯 GCK 模式（默认）：仅使用 Game Controller Kit，支持 USB + 蓝牙手柄
   * 2. 混合模式（USB_DRIVER_ENABLED=true）：GCK 处理输入 + USB 驱动提供震动/LED
   * 3. 强制 USB 模式（FORCE_USB_DRIVER_ONLY=true）：禁用 GCK，USB 驱动接管全部功能
   * 
   * 优先级：FORCE_USB_DRIVER_ONLY > USB_DRIVER_ENABLED > 默认 GCK
   */
  private loadUsbDriverSetting(): void {
    Promise.all([
      PreferencesUtil.get<boolean>(SettingsKeys.USB_DRIVER_ENABLED, false),
      PreferencesUtil.get<boolean>(SettingsKeys.FORCE_USB_DRIVER_ONLY, false)
    ]).then((results: boolean[]) => {
      const usbEnabled = results[0];
      const forceUsbOnly = results[1];
      
      if (forceUsbOnly) {
        // 模式 3：强制纯 USB 驱动模式（不启动 GCK）
        console.info('[GAMEPAD] 强制 USB 驱动模式：跳过 GCK，USB 驱动接管全部输入');
        this.useGameControllerKit = false;
        this.useUsbDriverMode = true;
        this.initializeDeviceListener();
        this.initializeUsbDriver();
      } else {
        // 始终优先尝试 GCK（为蓝牙手柄提供完整轴数据支持）
        this.initializeGameControllerKit();
        
        if (usbEnabled && this.useGameControllerKit) {
          // 模式 2：混合模式 - GCK 处理所有手柄输入，USB 驱动提供震动/LED
          console.info('[GAMEPAD] 混合模式：GCK(输入) + USB驱动(震动/高级功能)');
          this.useUsbDriverMode = true;
          this.initializeUsbDriver();
        } else if (usbEnabled && !this.useGameControllerKit) {
          // GCK 不可用，回退到纯 USB 驱动
          console.info('[GAMEPAD] GCK 不可用，回退到纯 USB 驱动 + InputKit 模式');
          this.useUsbDriverMode = true;
          this.initializeDeviceListener();
          this.initializeUsbDriver();
        } else if (!this.useGameControllerKit) {
          // GCK 不可用且 USB 驱动未启用
          console.info('[GAMEPAD] GCK 不可用，使用 InputKit 传统模式');
          this.initializeDeviceListener();
        }
        // else: 模式 1 - 纯 GCK 模式（默认）
      }

      this.modeInitialized = true;
      console.info(`[GAMEPAD] 最终输入模式: ${this.getInputModeDescription()}`);
      this.notifyListenerOfExistingDevices();
    }).catch(() => {
      // 读取设置失败，使用默认行为（尝试 GCK）
      this.initializeGameControllerKit();
      if (!this.useGameControllerKit) {
        this.initializeDeviceListener();
      }
      this.modeInitialized = true;
      this.notifyListenerOfExistingDevices();
    });
  }

  /**
   * 加载长按 Start 键显示返回菜单的设置
   */
  private async loadStartKeyMenuSetting(): Promise<void> {
    try {
      this.enableStartKeyMenu = await PreferencesUtil.get<boolean>(SettingsKeys.ENABLE_START_KEY_MENU, true);
    } catch (e) {
      this.enableStartKeyMenu = true;
    }
  }

  /**
   * 设置长按 Start 键显示返回菜单的回调
   */
  setShowGameMenuCallback(callback: (() => void) | null): void {
    this.showGameMenuCallback = callback;
  }
  
  static getInstance(): GamepadManager {
    if (!GamepadManager.instance) {
      GamepadManager.instance = new GamepadManager();
    }
    return GamepadManager.instance;
  }

  /**
   * 加载 Game Controller Kit 按键映射设置
   * 根据用户设置动态调整 2313 按键的动作
   */
  private async loadGCButtonMappingSettings(): Promise<void> {
    try {
      const action = await PreferencesUtil.get<string>(SettingsKeys.GC_BUTTON_HOME_MAPPING, 'guide');
      this.updateGCButton2313Action(action as GCButton2313Action);
    } catch (e) {
      this.updateGCButton2313Action('guide');
    }
  }

  /**
   * 设置 2313 按键的自定义动作回调
   * @param callback 回调接口，包含各种自定义动作的处理函数
   */
  setGCButton2313ActionCallback(callback: GCButton2313ActionCallback | null): void {
    this.gcButton2313ActionCallback = callback;
  }

  /**
   * 更新 GC Kit 2313 按键动作
   * @param action 动作类型
   */
  updateGCButton2313Action(action: GCButton2313Action): void {
    this.gcButton2313Action = action;

    // 对于按键映射类型，更新 gcButtonMap
    switch (action) {
      case 'guide':
        gcButtonMap.set(2313, MoonlightButton.SPECIAL);  // 映射为 Guide/Home
        break;
      case 'select':
        gcButtonMap.set(2313, MoonlightButton.BACK);  // 映射为 Select/Back
        break;
      default:
        // 自定义动作时，从映射表中移除 2313（在按键处理中单独处理）
        gcButtonMap.delete(2313);
        break;
    }
  }

  /**
   * 处理 2313 自定义动作
   * @returns true 如果动作已处理（不需要发送按键），false 如果需要正常发送按键
   */
  private handleGCButton2313Action(): boolean {
    switch (this.gcButton2313Action) {
      case 'toggle_mouse':
        this.toggleMouseEmulation();
        this.gcButton2313ActionCallback?.onToggleMouse?.();
        return true;
      case 'toggle_perf':
        this.gcButton2313ActionCallback?.onTogglePerf?.();
        return true;
      case 'show_menu':
        this.gcButton2313ActionCallback?.onShowMenu?.();
        return true;
      case 'none':
        return true;  // 不做任何操作，也不发送按键
      default:
        return false;  // guide/select 通过映射表处理
    }
  }
  
  /**
   * 初始化 Game Controller Kit (API 21+)
   * 优先使用系统级 API 提供统一的 USB/蓝牙手柄支持
   */
  private initializeGameControllerKit(): void {
    if (!gameControllerService.isAvailable()) {
      console.info('[GAMEPAD] Game Controller Kit 不可用，使用传统输入方案');
      this.fallbackToLegacyInput();
      return;
    }
    
    console.info('[GAMEPAD] Game Controller Kit 可用，初始化中...');
    
    if (!gameControllerService.init()) {
      console.warn('[GAMEPAD] Game Controller Kit 初始化失败，回退到传统方案');
      this.fallbackToLegacyInput();
      return;
    }
    
    this.useGameControllerKit = true;
    
    // 清理初始化竞争窗口内可能残留的传统设备状态
    // （setListener 在 modeInitialized 之前就被调用了，虽然我们阻止了扫描，
    //   仍需防范 handleKeyEvent 动态注册的幽灵设备）
    if (this.connectedDevices.size > 0) {
      console.info(`[GAMEPAD] 清理 ${this.connectedDevices.size} 个竞争期间注册的传统设备`);
      this.connectedDevices.forEach((name, deviceId) => {
        this.listener?.onGamepadDisconnected(deviceId);
      });
      this.connectedDevices.clear();
      this.deviceStates.clear();
      this.deviceInfoMap.clear();
      this.dpadAxisActive.clear();
    }
    
    this.setupGCCallbacks();
    gameControllerService.startMonitor();
    console.info('[GAMEPAD] Game Controller Kit 初始化成功');
  }
  
  /**
   * 设置 Game Controller Kit 回调
   */
  private setupGCCallbacks(): void {
    gameControllerService.setDeviceCallback((deviceId, isConnected, info) => {
      this.handleGCDeviceChange(deviceId, isConnected, info);
    });
    
    gameControllerService.setButtonCallback((deviceId, buttonCode, isPressed) => {
      this.handleGCButtonEvent(deviceId, buttonCode, isPressed);
    });
    
    gameControllerService.setAxisCallback((deviceId, axisType, x, y) => {
      this.handleGCAxisEvent(deviceId, axisType, x, y);
    });
  }
  
  /**
   * 回退到传统输入方案
   * 仅标记模式切换，不启动驱动服务（由 loadUsbDriverSetting 统一管理）
   */
  private fallbackToLegacyInput(): void {
    this.useGameControllerKit = false;
  }
  
  /**
   * 强制切换到 USB 驱动模式
   * 用于用户手动接管或 Game Controller Kit 有问题时
   * @returns 是否切换成功
   */
  async forceUsbDriverMode(): Promise<boolean> {
    console.info('[GAMEPAD] 用户请求强制切换到 USB 驱动模式');
    
    // 如果已经在纯传统模式，直接返回
    if (!this.useGameControllerKit) {
      console.info('[GAMEPAD] 当前已是 USB 驱动模式');
      return true;
    }
    
    // 停止 Game Controller Kit
    try {
      gameControllerService.stopMonitor();
      gameControllerService.setDeviceCallback(null);
      gameControllerService.setButtonCallback(null);
      gameControllerService.setAxisCallback(null);
      
      // 清理 GC Kit 相关状态
      // 先通知所有 GC Kit 设备断开，并释放槽位
      this.gcDeviceIdToSlot.forEach((slot, deviceId) => {
        if (this.listener) {
          this.listener.onGamepadDisconnected(slot);
        }
        // 释放 slotOccupied，防止后续 USB 设备无法分配到该槽位
        this.slotOccupied[slot] = false;
      });
      this.gcDeviceIdToSlot.clear();
      this.gcDeviceStates.clear();
      this.gcDpadAxisActive.clear();
      this.gcAxisFlushPending.clear();
      this.gcPhysicalAddressToDeviceId.clear();
      this.gcDeviceInfoCache.clear();
      
      console.info('[GAMEPAD] Game Controller Kit 已停止');
    } catch (err) {
      console.error('[GAMEPAD] 停止 Game Controller Kit 失败:', err);
    }
    
    // 如果是混合模式，USB 驱动已在运行，只需切到纯传统模式
    // 清理混合模式下仅用于震动的 USB 记录，让它们重新注册为输入设备
    const wasHybridMode = this.useUsbDriverMode;
    if (wasHybridMode) {
      this.usbDeviceKeyToId.clear();
      this.controllerIdToDeviceKey.clear();
    }
    
    // 切换到纯传统模式
    this.useGameControllerKit = false;
    this.useUsbDriverMode = true;
    this.initializeDeviceListener();
    
    // 如果 USB 驱动尚未运行（此前是纯 GCK 模式），启动它
    if (!wasHybridMode) {
      this.initializeUsbDriver();
    }
    
    // 持久化状态，下次串流启动时自动使用强制 USB 驱动模式
    Promise.all([
      PreferencesUtil.put(SettingsKeys.USB_DRIVER_ENABLED, true),
      PreferencesUtil.put(SettingsKeys.FORCE_USB_DRIVER_ONLY, true)
    ]).catch((err: Error) => {
      console.error('[GAMEPAD] 持久化 USB 驱动设置失败:', err);
    });
    
    console.info('[GAMEPAD] 已切换到纯 USB 驱动模式（已保存设置）');
    return true;
  }
  
  /**
   * 检查当前是否使用 Game Controller Kit
   * @returns true 表示使用 Game Controller Kit，false 表示使用 USB 驱动
   */
  isUsingGameControllerKit(): boolean {
    return this.useGameControllerKit;
  }

  /**
   * 是否有活跃的 GCK 手柄连接
   * 用于判断 D-pad 2012-2015 事件是否需要过滤
   * 仅当 GCK 已启用 且 有手柄实际连接时返回 true
   */
  hasActiveGcGamepad(): boolean {
    return this.useGameControllerKit && this.gcDeviceIdToSlot.size > 0;
  }

  // ==================== 鼠标模拟（委托 MouseEmulationService） ====================

  /** 设置鼠标模拟回调（由 StreamPage 调用） */
  setMouseEmulationCallback(callback: MouseEmulationCallback | null): void {
    this.mouseEmulationService.setCallback(callback);
  }

  /** 切换鼠标模拟模式 */
  toggleMouseEmulation(): void {
    this.mouseEmulationService.toggle();
  }

  /** 当前是否处于鼠标模拟模式 */
  isMouseEmulationActive(): boolean {
    return this.mouseEmulationService.isActive();
  }

  /**
   * 重新加载所有设置（串流开始时调用）
   * 
   * GamepadManager 是单例，构造函数里的设置加载仅执行一次。
   * 用户在设置页修改后需要手动同步，否则设置不会生效。
   */
  async reloadSettings(): Promise<void> {
    await Promise.all([
      this.loadStartKeyMenuSetting(),
      this.loadGCButtonMappingSettings(),
      this.loadSensorSettings()
    ]);
    // 注意：USB_DRIVER_ENABLED 和 FORCE_USB_DRIVER_ONLY 不在这里重新加载，因为切换需要完全重初始化手柄驱动
  }

  /**
   * 手柄状态拦截：鼠标模拟时委托给 MouseEmulationService
   * @returns true 表示已拦截（鼠标模拟模式），false 表示正常手柄处理
   */
  private interceptForMouseEmulation(slot: number, state: GamepadState): boolean {
    return this.mouseEmulationService.intercept(state, () => {
      if (this.listener) {
        this.listener.onGamepadInput(slot, this.createEmptyState());
      }
    });
  }

  /**
   * 重新挂载输入回调
   * 
   * 当手柄测试页面临时接管了底层服务的回调/监听器后，
   * 退出测试页面时应调用此方法将回调恢复给 GamepadManager，
   * 避免串流时手柄输入丢失。
   */
  reattachInputCallbacks(): void {
    console.info('[GAMEPAD] 重新挂载输入回调');

    if (this.useGameControllerKit) {
      // GC Kit 模式：重新设置回调并确保监听运行中
      this.setupGCCallbacks();
      gameControllerService.startMonitor();
      console.info('[GAMEPAD] GC Kit 回调已恢复');
      
      // 混合模式：同时恢复 USB 驱动（用于震动）
      if (this.useUsbDriverMode) {
        this.usbDriverService.setListener(this);
        this.usbDriverService.start();
        console.info('[GAMEPAD] USB 驱动 listener 已恢复（混合模式-震动）');
      }
    } else {
      // 传统模式：重新设置 USB 驱动 listener 并确保驱动运行中
      this.usbDriverService.setListener(this);
      this.usbDriverService.start();
      console.info('[GAMEPAD] USB 驱动 listener 已恢复并重启');
    }
  }
  
  /**
   * 获取当前输入模式的描述
   */
  getInputModeDescription(): string {
    if (this.useGameControllerKit && this.useUsbDriverMode) {
      return 'Game Controller Kit + USB 驱动 (混合模式)';
    } else if (this.useGameControllerKit) {
      return 'Game Controller Kit (系统统一输入)';
    } else {
      return 'USB 驱动 (直接设备控制)';
    }
  }
  
  /**
   * 初始化 USB 驱动
   */
  private async initializeUsbDriver(): Promise<void> {
    try {
      console.info('[GAMEPAD] 初始化 USB 驱动服务...');
      this.usbDriverService.setListener(this);
      await this.usbDriverService.start();
      console.info('[GAMEPAD] USB 驱动服务已启动');
    } catch (err) {
      console.error('[GAMEPAD] USB 驱动服务启动失败:', err);
    }
  }
  
  /**
   * 设置设备模拟震动
   * @param enabled 是否启用震动
   * @param strength 设备震动强度 (0-100)
   * @param mode 震动模式：自动/仅手柄/仅设备/同时
   */
  setDeviceVibrate(enabled: boolean, strength: number, mode: string): void {
    this.vibrationService.setSettings(enabled, strength, mode);
  }

  /**
   * 设置输入监听器
   * 设置后会立即通知所有已连接的设备
   * 如果使用 Game Controller Kit 模式，会确保 GC Kit 回调已设置
   */
  setListener(listener: GamepadInputListener | null): void {
    this.listener = listener;
    
    // 通知已连接的设备
    if (listener) {
      if (!this.modeInitialized) {
        // 输入模式尚未确定（loadUsbDriverSetting 异步初始化中）
        // 此时不扫描设备，避免传统路径与即将激活的 GCK 竞争产生幽灵手柄
        // 模式确定后 notifyListenerOfExistingDevices() 会自动补发通知
        console.info('GamepadManager: 设置监听器（输入模式初始化中，稍后通知已连接设备）');
        return;
      }
      this.notifyListenerOfExistingDevices();
    }
  }
  
  /**
   * 通知 listener 所有已连接的设备
   * 在 setListener 和 loadUsbDriverSetting 完成时调用
   */
  private notifyListenerOfExistingDevices(): void {
    const listener = this.listener;
    if (!listener) return;
    
    if (this.useGameControllerKit) {
        // Game Controller Kit 模式
        console.info(`GamepadManager: 设置监听器 (Game Controller Kit 模式)`);
        
        // 确保 GC Kit 回调已设置（可能被测试页面清空）
        // 临时置空 listener 避免 rescan 期间触发重复通知
        this.listener = null;
        this.ensureGCKitCallbacks();
        this.listener = listener;
        
        // 统一通知所有已连接的 Game Controller Kit 设备（仅此一处通知，按槽位去重）
        const devices = gameControllerService.getAllDevices();
        const notifiedSlots = new Set<number>();
        for (const device of devices) {
          // 过滤非手柄设备（如手表、手环等），但同时含手柄关键词时不过滤
          const deviceNameLower = (device.name || '').toLowerCase();
          if (isNonGamepadByName(deviceNameLower)) {
            console.info(`GamepadManager: 跳过非手柄设备: ${device.name}`);
            continue;
          }
          const slot = this.getSlotForGCDevice(device.deviceId);
          if (notifiedSlots.has(slot)) {
            console.info(`GamepadManager: 跳过重复槽位手柄: ${device.name} (Slot: ${slot})`);
            continue;
          }
          notifiedSlots.add(slot);
          const ctrlType = MoonlightControllerType.fromDeviceName(device.name);
          console.info(`GamepadManager: 通知已连接手柄: ${device.name} (Slot: ${slot}, Type: ${ctrlType})`);
          listener.onGamepadConnected(slot, device.name, ctrlType);
        }
      } else {
        // 传统模式
        console.info(`GamepadManager: 设置监听器，已连接设备数: ${this.connectedDevices.size}`);
        this.connectedDevices.forEach((name, deviceId) => {
          const info = this.deviceInfoMap.get(deviceId);
          const ctrlType = info?.vendor ? MoonlightControllerType.fromVendorProduct(info.vendor, info.product ?? 0) : MoonlightControllerType.fromDeviceName(name);
          const slot = this.getControllerSlot(deviceId);
          console.info(`GamepadManager: 通知已连接手柄: ${name} (ID: ${deviceId}, Slot: ${slot}, Type: ${ctrlType})`);
          listener.onGamepadConnected(slot, name, ctrlType);
        });
        
        // 重新扫描设备，确保不遗漏
        this.scanConnectedDevices();
        
        // 刷新 USB 设备
        this.usbDriverService.refreshDevices();
      }
  }
  
  /**
   * 确保 Game Controller Kit 回调已设置
   * 用于处理回调被其他组件（如测试页面）覆盖的情况
   */
  private ensureGCKitCallbacks(): void {
    // 检查 GC Kit 是否初始化
    if (!gameControllerService.init()) {
      console.warn('[GAMEPAD] GC Kit 初始化失败');
      return;
    }
    
    // 重新设置回调
    console.info('[GAMEPAD] 重新设置 Game Controller Kit 回调');
    this.setupGCCallbacks();
    
    // 确保监听器已启动
    gameControllerService.startMonitor();
    
    // 扫描已连接的设备（可能在监听暂停期间已经连接）
    this.rescanGCKitDevices();
    // 键鼠场景：若无手柄则暂停 Monitor，避免系统层以约 30Hz 占用/干扰鼠标轮询
    if (this.gcDeviceIdToSlot.size === 0) {
      gameControllerService.stopMonitor();
      console.info('[GAMEPAD] 初始扫描无手柄，暂停 GCK Monitor（键鼠场景保持高鼠标轮询率）');
    }
  }
  
  /**
   * 重新扫描 GC Kit 设备
   * 用于处理监听暂停后恢复的场景
   */
  private rescanGCKitDevices(): void {
    const devices = gameControllerService.getAllDevices();
    console.info(`[GAMEPAD] 扫描 GC Kit 设备: 发现 ${devices.length} 个`);
    
    for (const device of devices) {
      // 检查是否已经注册
      if (!this.gcDeviceIdToSlot.has(device.deviceId)) {
        console.info(`[GAMEPAD] 补充注册 GC Kit 设备: ${device.name} (${device.deviceId})`);
        this.handleGCDeviceChange(device.deviceId, true, device);
      }
    }
  }
  
  /**
   * 初始化设备监听
   */
  private initializeDeviceListener(): void {
    // 监听设备热插拔
    inputDevice.on('change', (data) => {
      console.info(`[GAMEPAD] 系统输入设备变化: type=${data.type}, deviceId=${data.deviceId}`);
      if (data.type === 'add') {
        this.handleDeviceAdded(data.deviceId);
        // 同时刷新 USB 设备，因为新的 USB 手柄插入也会触发此事件
        this.usbDriverService.refreshDevices();
        // 键鼠场景下曾暂停 GCK Monitor；新设备加入时尝试恢复并同步 GCK 设备列表
        if (this.useGameControllerKit && this.gcDeviceIdToSlot.size === 0) {
          gameControllerService.refreshDeviceCache();
          gameControllerService.startMonitor();
          this.rescanGCKitDevices();
        }
      } else if (data.type === 'remove') {
        this.handleDeviceRemoved(data.deviceId);
        // 检查 USB 控制器是否需要清理
        this.checkUsbControllerStatus();
      }
    });
    
    // 扫描已连接的设备
    this.scanConnectedDevices();
  }
  
  /**
   * 检查 USB 控制器状态，清理已断开的设备
   */
  private checkUsbControllerStatus(): void {
    // 获取当前 USB 设备列表，用于检查哪些控制器已断开
    const controllers = this.usbDriverService.getControllers();
    for (const controller of controllers) {
      if (!controller.isConnected()) {
        console.info(`[GAMEPAD] USB 控制器已断开: ID=${controller.getControllerId()}`);
        controller.stop();
      }
    }
  }
  
  /**
   * 扫描已连接的设备
   */
  private async scanConnectedDevices(): Promise<void> {
    try {
      const deviceIds = await inputDevice.getDeviceIds();
      
      console.info(`[GAMEPAD] ============ 开始扫描输入设备 ============`);
      console.info(`[GAMEPAD] 发现 ${deviceIds.length} 个输入设备`);
      
      for (const deviceId of deviceIds) {
        // 打印所有设备信息以便调试
        try {
          const info = await inputDevice.getDeviceInfo(deviceId);
          console.info(`[GAMEPAD] 设备[${deviceId}]: "${info.name}"`);
          console.info(`[GAMEPAD]   - sources: ${JSON.stringify(info.sources)}`);
          console.info(`[GAMEPAD]   - bus: ${info.bus}, vendor: 0x${info.vendor?.toString(16) || '0'}, product: 0x${info.product?.toString(16) || '0'}`);
        } catch (e) {
          console.error(`[GAMEPAD] 获取设备 ${deviceId} 信息失败`, e);
        }
        
        await this.checkAndRegisterDevice(deviceId);
      }
      
      console.info(`[GAMEPAD] ============ 扫描完成，注册了 ${this.connectedDevices.size} 个手柄 ============`);
    } catch (err) {
      console.error('[GAMEPAD] 扫描设备失败', err);
    }
  }
  
  /**
   * 检查并注册设备
   */
  private async checkAndRegisterDevice(deviceId: number): Promise<void> {
    try {
      const deviceInfo = await inputDevice.getDeviceInfo(deviceId);
      const deviceNameLower = deviceInfo.name.toLowerCase();
      const isUsbInForceUsbMode =
        !this.useGameControllerKit &&
        this.useUsbDriverMode &&
        deviceInfo.bus === DeviceBusType.BUS_USB;
      
      // 强制 USB 模式下，USB 手柄由 UsbDriverService 统一注册和上报；
      // 跳过 InputKit 的 USB 注册，避免同一物理手柄被重复识别为多个设备。
      if (isUsbInForceUsbMode) {
        console.info(`[GAMEPAD] 强制 USB 模式下跳过 InputKit USB 设备注册: "${deviceInfo.name}" (ID: ${deviceId})`);
        return;
      }
      
      // 检查是否应排除（键盘/鼠标等）
      if (this.isNonGamepadDevice(deviceNameLower, deviceInfo.sources)) {
        GamepadManager.DEBUG && console.info(`[GAMEPAD] 跳过非手柄设备: "${deviceInfo.name}"`);
        return;
      }
      
      // 检查是否是手柄
      const hasJoystickSource = deviceInfo.sources.some(s => s === 'joystick');
      const nameIndicatesGamepad = GAMEPAD_NAME_KEYWORDS.some(kw => deviceNameLower.includes(kw));
      
      if (!hasJoystickSource && !nameIndicatesGamepad) {
        GamepadManager.DEBUG && console.info(`[GAMEPAD] 跳过未识别设备: "${deviceInfo.name}"`);
        return;
      }
      
      // 注册手柄
      this.registerGamepad(deviceId, deviceInfo, hasJoystickSource, nameIndicatesGamepad);
    } catch (err) {
      console.error(`[GAMEPAD] 获取设备信息失败 ${deviceId}`, err);
    }
  }
  
  /**
   * 检查是否是非手柄设备
   */
  private isNonGamepadDevice(nameLower: string, sources: inputDevice.SourceType[]): boolean {
    // 智能判断：名称含手柄关键词时（如 "gamesir g8+ keyboard"），即使有 keyboard source 也视为手柄
    const hasGamepadKeyword = GAMEPAD_NAME_KEYWORDS.some(kw => nameLower.includes(kw));
    if (hasGamepadKeyword) return false;
    // 名称或 source 匹配非手柄特征
    if (isNonGamepadByName(nameLower)) return true;
    const hasNonGamepadSource = sources.includes('keyboard' as inputDevice.SourceType) ||
                                 sources.includes('mouse' as inputDevice.SourceType);
    return hasNonGamepadSource;
  }
  
  /**
   * 注册手柄设备
   */
  private registerGamepad(
    deviceId: number, 
    deviceInfo: inputDevice.InputDeviceData,
    hasJoystickSource: boolean,
    nameIndicatesGamepad: boolean
  ): void {
    const bus = deviceInfo.bus;
    const isUsb = bus === DeviceBusType.BUS_USB;
    const isBluetooth = bus === DeviceBusType.BUS_BLUETOOTH;
    
    this.connectedDevices.set(deviceId, deviceInfo.name);
    this.deviceStates.set(deviceId, this.createEmptyState());
    
    const gamepadInfo: GamepadInfo = {
      id: deviceId,
      name: deviceInfo.name,
      bus, vendor: deviceInfo.vendor, product: deviceInfo.product,
      isUsb, isBluetooth
    };
    this.deviceInfoMap.set(deviceId, gamepadInfo);
    
    // 为 InputKit 设备分配正确的槽位 (0-3)
    // USB 设备可能稍后由 UsbDriverService 接管（使用 USB deviceKey），
    // 这里用 InputKit deviceId 作为 key 先行分配
    const deviceKey = `inputkit_${deviceId}`;
    const slot = this.allocateSlotForDevice(deviceKey);
    if (slot >= 0) {
      this.controllerIdToDeviceKey.set(deviceId, deviceKey);
    }
    
    const connectionType = isBluetooth ? '蓝牙' : (isUsb ? 'USB' : `其他(${bus})`);
    const effectiveSlot = slot >= 0 ? slot : deviceId;
    console.info(`[GAMEPAD] ★ 注册手柄: "${deviceInfo.name}" (ID: ${deviceId}, Slot: ${effectiveSlot}, ${connectionType})`);
    GamepadManager.DEBUG && console.info(`[GAMEPAD]   检测: joystick源=${hasJoystickSource}, 名称匹配=${nameIndicatesGamepad}`);
    
    const ctrlType = deviceInfo.vendor ? MoonlightControllerType.fromVendorProduct(deviceInfo.vendor, deviceInfo.product ?? 0) : MoonlightControllerType.fromDeviceName(deviceInfo.name);
    this.listener?.onGamepadConnected(effectiveSlot, deviceInfo.name, ctrlType);
  }
  
  /**
   * 处理设备添加
   */
  private handleDeviceAdded(deviceId: number): void {
    this.checkAndRegisterDevice(deviceId);
  }
  
  /**
   * 处理设备移除
   */
  private async handleDeviceRemoved(deviceId: number): Promise<void> {
    // 检查是否应该忽略断开信号
    const inputSettings = await SettingsService.getInstance().getInputSettings();
    if (inputSettings.ignoreDeviceDisconnect) {
      console.info(`[GAMEPAD] 忽略设备断开信号: deviceId=${deviceId} (用户已启用忽略断开设置)`);
      return;
    }
    
    if (this.connectedDevices.has(deviceId)) {
      const name = this.connectedDevices.get(deviceId) || 'Unknown';
      const info = this.deviceInfoMap.get(deviceId);
      const connectionType = info?.isBluetooth ? '蓝牙' : (info?.isUsb ? 'USB' : '未知');
      
      // 获取槽位（在清理之前）
      const slot = this.getControllerSlot(deviceId);
      
      this.connectedDevices.delete(deviceId);
      this.deviceStates.delete(deviceId);
      this.deviceInfoMap.delete(deviceId);
      this.dpadAxisActive.delete(deviceId);
      
      // 释放 InputKit 设备的槽位
      const deviceKey = this.controllerIdToDeviceKey.get(deviceId);
      if (deviceKey) {
        this.releaseSlotForDevice(deviceKey);
        this.controllerIdToDeviceKey.delete(deviceId);
      }
      
      console.info(`GamepadManager: 移除手柄 ${name} (ID: ${deviceId}, Slot: ${slot}, 连接类型: ${connectionType})`);
      
      if (this.listener) {
        this.listener.onGamepadDisconnected(slot);
      }
    }
  }
  
  /**
   * 创建空状态
   */
  private createEmptyState(): GamepadState {
    return {
      buttons: 0,
      leftStickX: 0,
      leftStickY: 0,
      rightStickX: 0,
      rightStickY: 0,
      leftTrigger: 0,
      rightTrigger: 0
    };
  }
  
  /**
   * 更新按钮状态
   * @param state 状态对象
   * @param buttonFlag 按钮标志位
   * @param isPressed 是否按下
   */
  private updateButtonState(state: GamepadState, buttonFlag: number, isPressed: boolean): void {
    if (isPressed) {
      state.buttons |= buttonFlag;
    } else {
      state.buttons &= ~buttonFlag;
    }
  }
  
  /**
   * 创建状态副本
   * 避免直接传递引用导致状态被意外修改
   */
  private copyState(state: GamepadState): GamepadState {
    return {
      buttons: state.buttons,
      leftStickX: state.leftStickX,
      leftStickY: state.leftStickY,
      rightStickX: state.rightStickX,
      rightStickY: state.rightStickY,
      leftTrigger: state.leftTrigger,
      rightTrigger: state.rightTrigger
    };
  }

  // ==================== Game Controller Kit 事件处理 ====================
  
  /**
   * 通用槽位分配方法
   * @param deviceKey 设备唯一标识
   * @param keyToSlotMap 设备key到槽位的映射
   * @param logPrefix 日志前缀
   * @returns 分配的槽位 (0-3)，失败返回 -1
   */
  private allocateSlot(deviceKey: string, keyToSlotMap: Map<string, number>, logPrefix: string): number {
    // 检查是否已有槽位
    const existingSlot = keyToSlotMap.get(deviceKey);
    if (existingSlot !== undefined) {
      return existingSlot;
    }
    
    // 分配第一个空闲槽位
    for (let i = 0; i < GamepadManager.MAX_CONTROLLERS; i++) {
      if (!this.slotOccupied[i]) {
        this.slotOccupied[i] = true;
        keyToSlotMap.set(deviceKey, i);
        console.info(`[${logPrefix}] 为设备分配槽位: Key=${deviceKey}, Slot=${i}`);
        return i;
      }
    }
    
    console.warn(`[${logPrefix}] 所有槽位已满，无法分配: Key=${deviceKey}`);
    return -1;
  }
  
  /**
   * 通用槽位释放方法
   */
  private releaseSlot(deviceKey: string, keyToSlotMap: Map<string, number>, logPrefix: string): void {
    const slot = keyToSlotMap.get(deviceKey);
    if (slot !== undefined) {
      this.slotOccupied[slot] = false;
      keyToSlotMap.delete(deviceKey);
      console.info(`[${logPrefix}] 释放设备槽位: Key=${deviceKey}, Slot=${slot}`);
    }
  }
  
  /**
   * 判断是否为特殊按键码（2311-2315）
   * 仅用于传统 InputKit 路径：这些按键应路由到已连接设备而非创建新设备
   */
  private isSpecialKeyCode(keyCode: number): boolean {
    return keyCode >= SPECIAL_KEYCODE_MIN && keyCode <= SPECIAL_KEYCODE_MAX;
  }
  
  /**
   * 为 Game Controller Kit 设备分配槽位
   */
  private allocateSlotForGCDevice(deviceId: string): number {
    return this.allocateSlot(deviceId, this.gcDeviceIdToSlot, 'GAMEPAD-GC');
  }
  
  /**
   * 释放 Game Controller Kit 设备槽位
   */
  private releaseSlotForGCDevice(deviceId: string): void {
    this.releaseSlot(deviceId, this.gcDeviceIdToSlot, 'GAMEPAD-GC');
  }
  
  /**
   * 获取 Game Controller Kit 设备的槽位
   */
  private getSlotForGCDevice(deviceId: string): number {
    return this.gcDeviceIdToSlot.get(deviceId) ?? 0;
  }
  
  /**
   * 获取缓存的 GC Kit 设备信息（用于去重比较）
   */
  private getGCDeviceInfoCached(deviceId: string): GameControllerDeviceInfo | null {
    return this.gcDeviceInfoCache.get(deviceId) ?? null;
  }
  
  /**
   * 处理 Game Controller Kit 设备状态变化
   * 包含去重逻辑：同一物理 USB 手柄的多个 HID 接口只注册一次
   */
  private handleGCDeviceChange(deviceId: string, isConnected: boolean, info: GameControllerDeviceInfo): void {
    console.info(`[GAMEPAD-GC] 设备状态变化: deviceId=${deviceId}, isConnected=${isConnected}, name=${info?.name}, physAddr=${info?.physicalAddress || 'N/A'}`);
    
    if (isConnected) {
      // 防止重复注册：同一 deviceId 已分配槽位时，跳过（startMonitor 重复回调防护）
      if (this.gcDeviceIdToSlot.has(deviceId)) {
        console.info(`[GAMEPAD-GC] 设备已注册，跳过: deviceId=${deviceId}, slot=${this.gcDeviceIdToSlot.get(deviceId)}`);
        return;
      }

      // 过滤非手柄设备（如手表、手环等），但同时含手柄关键词时不过滤
      const deviceNameLower = (info?.name || '').toLowerCase();
      if (isNonGamepadByName(deviceNameLower)) {
        console.info(`[GAMEPAD-GC] 跳过非手柄设备: "${info?.name}"`);
        return;
      }

      // 品牌匹配通过但名称含强非手柄关键词（如 "RAPOO Keyboard-1 System Control"）
      // → 异步验证：查询 InputDevice 源类型，只有确实有 joystick 源才注册
      if (hasStrongNonGamepadKeyword(deviceNameLower)) {
        console.info(`[GAMEPAD-GC] 名称含非手柄关键词，验证设备源类型: "${info?.name}"`);
        this.verifyAndRegisterGCDevice(deviceId, info);
        return;
      }

      // 去重检查 1：同一物理地址的设备只注册一次
      const physAddr = info?.physicalAddress || '';
      if (physAddr && physAddr.length > 0) {
        const existingDeviceId = this.gcPhysicalAddressToDeviceId.get(physAddr);
        if (existingDeviceId && existingDeviceId !== deviceId) {
          // 同一物理设备的另一个 HID 接口，合并到已有设备
          console.info(`[GAMEPAD-GC] 跳过重复设备(物理地址): deviceId=${deviceId} -> 已有设备 ${existingDeviceId} (physAddr=${physAddr})`);
          // 将此 deviceId 映射到已有设备的槽位，使输入事件可以正确路由
          const existSlot = this.gcDeviceIdToSlot.get(existingDeviceId);
          if (existSlot !== undefined) {
            this.gcDeviceIdToSlot.set(deviceId, existSlot);
            this.gcDeviceStates.set(deviceId, this.gcDeviceStates.get(existingDeviceId) || this.createEmptyState());
          }
          return;
        }
        this.gcPhysicalAddressToDeviceId.set(physAddr, deviceId);
      }

      // 去重检查 2：同名同 product 的设备视为同一物理设备的不同 HID 接口
      // 仅在无法通过物理地址区分时执行：
      //   - 当前设备或已有设备物理地址为空 → 无法确认是否同一设备，按名称去重
      //   - 两者物理地址相同 → 同一物理设备的不同接口
      //   - 两者物理地址不同 → 跳过，说明是独立的物理设备（如两个同型号蓝牙手柄）
      {
        const slotEntries = Array.from(this.gcDeviceIdToSlot.entries());
        for (let i = 0; i < slotEntries.length; i++) {
          const existId = slotEntries[i][0];
          const existSlot = slotEntries[i][1];
          if (existId === deviceId) continue;
          const existInfo = this.getGCDeviceInfoCached(existId);
          if (existInfo && existInfo.name === info?.name && existInfo.product === info?.product) {
            // 如果两个设备都有非空物理地址且不同，则视为独立设备，不去重
            const existPhysAddr = existInfo.physicalAddress || '';
            if (physAddr.length > 0 && existPhysAddr.length > 0 && physAddr !== existPhysAddr) {
              continue;  // 不同物理地址 = 不同物理设备
            }
            console.info(`[GAMEPAD-GC] 跳过重复设备(名称+产品ID): deviceId=${deviceId} -> 已有设备 ${existId} (name=${info?.name}, product=${info?.product})`);
            this.gcDeviceIdToSlot.set(deviceId, existSlot);
            this.gcDeviceStates.set(deviceId, this.gcDeviceStates.get(existId) || this.createEmptyState());
            return;
          }
        }
      }

      // 无手柄时曾暂停 Monitor，现从 0→1 需恢复（键鼠场景下避免 GCK 干扰鼠标轮询）
      const hadNoGcDevices = this.gcDeviceIdToSlot.size === 0;

      // 分配槽位
      const slot = this.allocateSlotForGCDevice(deviceId);
      if (slot < 0) {
        console.warn(`[GAMEPAD-GC] 无法分配槽位，忽略设备: ${info?.name}`);
        return;
      }
      
      // 缓存设备信息用于后备去重
      if (info) {
        this.gcDeviceInfoCache.set(deviceId, info);
      }
      
      // 创建设备状态
      this.gcDeviceStates.set(deviceId, this.createEmptyState());
      
      // 通知监听器
      if (this.listener) {
        const ctrlType = MoonlightControllerType.fromDeviceName(info?.name || '');
        console.info(`[GAMEPAD-GC] 通知手柄连接: slot=${slot}, name=${info?.name || `Controller ${slot}`}, type=${ctrlType}`);
        this.listener.onGamepadConnected(slot, info?.name || `Controller ${slot}`, ctrlType);
      }

      if (hadNoGcDevices) {
        gameControllerService.startMonitor();
        console.info('[GAMEPAD] 检测到手柄连接，恢复 GCK Monitor');
      }
    } else {
      // 获取槽位（在清理之前）
      const slot = this.getSlotForGCDevice(deviceId);
      
      // 清理物理地址映射
      const addrEntries = Array.from(this.gcPhysicalAddressToDeviceId.entries());
      for (let i = 0; i < addrEntries.length; i++) {
        const addr = addrEntries[i][0];
        const id = addrEntries[i][1];
        if (id === deviceId) {
          this.gcPhysicalAddressToDeviceId.delete(addr);
          break;
        }
      }
      
      // 检查是否是某个物理设备的副本（共享槽位的设备）
      // 如果还有其他设备占据同一槽位，不释放槽位也不通知断开
      let isSharedSlotDevice = false;
      const slotEntries2 = Array.from(this.gcDeviceIdToSlot.entries());
      for (let i = 0; i < slotEntries2.length; i++) {
        const otherId = slotEntries2[i][0];
        const otherSlot = slotEntries2[i][1];
        if (otherId !== deviceId && otherSlot === slot) {
          isSharedSlotDevice = true;
          break;
        }
      }
      
      // 清理状态
      this.gcDeviceStates.delete(deviceId);
      this.gcDeviceInfoCache.delete(deviceId);
      this.gcDeviceIdToSlot.delete(deviceId);
      this.gcDpadAxisActive.delete(deviceId);
      
      if (isSharedSlotDevice) {
        console.info(`[GAMEPAD-GC] 副本设备断开: deviceId=${deviceId}, 主设备仍在，不通知断开`);
        return;
      }
      
      // 释放槽位
      this.releaseSlotForGCDevice(deviceId);
      // 通知监听器
      if (this.listener) {
        this.listener.onGamepadDisconnected(slot);
      }

      // 无手柄时暂停 GCK Monitor，减轻键鼠场景下对鼠标轮询的干扰（避免返回菜单后约 1～2 秒鼠标掉回 30Hz）
      if (this.gcDeviceIdToSlot.size === 0) {
        gameControllerService.stopMonitor();
        console.info('[GAMEPAD] 无手柄连接，暂停 GCK Monitor（键鼠场景保持高鼠标轮询率）');
      }
    }
  }
  
  /**
   * 异步验证 GCK 报告的设备是否真的是手柄
   *
   * 当设备名称通过了品牌匹配（如 "rapoo"）但同时包含强非手柄关键词（如 "keyboard"）时，
   * 通过 InputDevice API 查询实际设备源类型来确认：
   * - 有 joystick 源 → 是带键盘功能的手柄（如 Gamesir G8+ keyboard）→ 注册
   * - 无 joystick 源 → 是手柄品牌的键盘产品（如 RAPOO Keyboard-1）→ 跳过
   */
  private async verifyAndRegisterGCDevice(deviceId: string, info: GameControllerDeviceInfo): Promise<void> {
    try {
      // 通过名称或 vendor/product 匹配 InputDevice
      const deviceIds = await inputDevice.getDeviceIds();
      let hasJoystickSource = false;

      for (const id of deviceIds) {
        const devInfo = await inputDevice.getDeviceInfo(id);
        // 按名称匹配（GCK 和 InputDevice 通常报告相同名称）
        // 同时匹配 product 以提高准确性
        const nameMatch = devInfo.name === info?.name;
        const productMatch = info?.product !== undefined &&
          devInfo.product === info.product;

        if (nameMatch || productMatch) {
          hasJoystickSource = devInfo.sources.some(
            (s: inputDevice.SourceType) => s === 'joystick'
          );
          if (hasJoystickSource) break;
        }
      }

      if (hasJoystickSource) {
        // 设备确实是手柄（带键盘功能），正常注册
        console.info(`[GAMEPAD-GC] 设备 "${info?.name}" 验证通过（有 joystick 源），继续注册`);
        this.continueGCDeviceRegistration(deviceId, info);
      } else {
        // 设备不是手柄（如 RAPOO Keyboard-1），跳过
        console.info(`[GAMEPAD-GC] 设备 "${info?.name}" 无 joystick 源，跳过（不是手柄）`);
      }
    } catch (err) {
      // 查询失败，安全起见跳过（避免误注册键盘为手柄）
      console.warn(`[GAMEPAD-GC] 验证设备 "${info?.name}" 失败，跳过: ${err}`);
    }
  }

  /**
   * 继续 GCK 设备注册流程（在异步验证通过后调用）
   * 包含去重检查和槽位分配
   */
  private continueGCDeviceRegistration(deviceId: string, info: GameControllerDeviceInfo): void {
    // 防止异步期间已有其他路径注册了此设备
    if (this.gcDeviceIdToSlot.has(deviceId)) {
      return;
    }

    const hadNoGcDevices = this.gcDeviceIdToSlot.size === 0;

    const slot = this.allocateSlotForGCDevice(deviceId);
    if (slot < 0) {
      console.warn(`[GAMEPAD-GC] 无法分配槽位，忽略设备: ${info?.name}`);
      return;
    }

    if (info) {
      this.gcDeviceInfoCache.set(deviceId, info);
    }

    this.gcDeviceStates.set(deviceId, this.createEmptyState());

    if (this.listener) {
      const ctrlType = MoonlightControllerType.fromDeviceName(info?.name || '');
      console.info(`[GAMEPAD-GC] 通知手柄连接(验证后): slot=${slot}, name=${info?.name || `Controller ${slot}`}, type=${ctrlType}`);
      this.listener.onGamepadConnected(slot, info?.name || `Controller ${slot}`, ctrlType);
    }

    if (hadNoGcDevices) {
      gameControllerService.startMonitor();
      console.info('[GAMEPAD] 检测到手柄连接，恢复 GCK Monitor');
    }
  }

  /**
   * 处理 Game Controller Kit 按键事件
   */
  private handleGCButtonEvent(deviceId: string, buttonCode: number, isPressed: boolean): void {
    // 获取或创建设备状态
    let state = this.gcDeviceStates.get(deviceId);
    if (!state) {
      state = this.createEmptyState();
      this.gcDeviceStates.set(deviceId, state);
    }
    
    // 长按 Start 检测 (2312 = BUTTON_MENU/Start)
    if (buttonCode === 2312 && this.handleStartLongPress(isPressed)) {
      return;
    }
    
    // 映射按键码到按钮标志
    const buttonFlag = gcButtonMap.get(buttonCode);
    if (buttonFlag !== undefined) {
      // D-pad 按键去重：如果该设备已经通过 Axis 通道报告了 D-pad，
      // 则丢弃 Button 通道的 D-pad 事件，避免双发（蓝牙手柄 Axis + Button 同时上报）
      if ((buttonFlag & MoonlightButton.DPAD_MASK) !== 0 && this.gcDpadAxisActive.has(deviceId)) {
        return;
      }
      this.updateButtonState(state, buttonFlag, isPressed);
      this.notifyGCStateChange(this.getSlotForGCDevice(deviceId), state);
    } else {
      GamepadManager.DEBUG && console.info(`[GAMEPAD-GC] 未映射的按键: buttonCode=${buttonCode}`);
    }
  }
  
  /** 已记录过首次轴事件日志的设备集合（避免日志洪泛） */
  private gcAxisFirstEventLogged = new Set<string>();

  /**
   * 处理 Game Controller Kit 轴事件
   */
  private handleGCAxisEvent(deviceId: string, axisType: number, x: number, y: number): void {
    // 首次轴事件诊断日志（每设备仅一次）
    if (!this.gcAxisFirstEventLogged.has(deviceId)) {
      this.gcAxisFirstEventLogged.add(deviceId);
      const registered = this.gcDeviceIdToSlot.has(deviceId);
      const slot = this.getSlotForGCDevice(deviceId);
      console.info(`[GAMEPAD-GC] 首次轴事件: deviceId=${deviceId}, axisType=${axisType}, registered=${registered}, slot=${slot}, listener=${!!this.listener}`);
    }
    let state = this.gcDeviceStates.get(deviceId);
    if (!state) {
      state = this.createEmptyState();
      this.gcDeviceStates.set(deviceId, state);
    }
    
    switch (axisType) {
      case AxisType.LEFT_THUMBSTICK:
        state.leftStickX = Math.floor(x * AXIS_MAX);
        state.leftStickY = Math.floor(-y * AXIS_MAX);  // Y轴取负与Android一致
        break;
        
      case AxisType.RIGHT_THUMBSTICK:
        state.rightStickX = Math.floor(x * AXIS_MAX);
        state.rightStickY = Math.floor(-y * AXIS_MAX);
        break;
        
      case AxisType.DPAD:
        // 标记此设备的D-pad由Axis通道提供，Button/KeyEvent通道将静默丢弃D-pad事件
        this.gcDpadAxisActive.add(deviceId);
        state.buttons &= ~MoonlightButton.DPAD_MASK;
        if (y < -0.5) state.buttons |= MoonlightButton.UP;
        if (y > 0.5) state.buttons |= MoonlightButton.DOWN;
        if (x < -0.5) state.buttons |= MoonlightButton.LEFT;
        if (x > 0.5) state.buttons |= MoonlightButton.RIGHT;
        break;
        
      case AxisType.LEFT_TRIGGER:
        state.leftTrigger = Math.floor(x * TRIGGER_MAX);
        break;
        
      case AxisType.RIGHT_TRIGGER:
        state.rightTrigger = Math.floor(x * TRIGGER_MAX);
        break;
    }
    
    const slot = this.getSlotForGCDevice(deviceId);
    this.gcAxisFlushPending.add(slot);
    this.scheduleGCAxisFlush();
  }

  /** 调度一次轴状态合并发送（同一 event loop tick 内多次轴回调只发 1 次，与 Android 一次 MotionEvent 一发一致） */
  private scheduleGCAxisFlush(): void {
    if (this.gcAxisFlushTimerId !== -1) {
      return;
    }
    this.gcAxisFlushTimerId = setTimeout(() => {
      this.gcAxisFlushTimerId = -1;
      this.flushGCAxisPending();
    }, 0);
  }

  private flushGCAxisPending(): void {
    if (this.gcAxisFlushPending.size === 0 || !this.listener) {
      if (this.gcAxisFlushPending.size > 0 && !this.listener) {
        console.warn(`[GAMEPAD-GC] 轴事件丢弃: listener 为空, pending slots=${this.gcAxisFlushPending.size}`);
      }
      this.gcAxisFlushPending.clear();
      return;
    }
    this.gcDeviceIdToSlot.forEach((slot: number, deviceId: string) => {
      if (!this.gcAxisFlushPending.has(slot)) {
        return;
      }
      const state = this.gcDeviceStates.get(deviceId);
      if (state) {
        this.notifyGCStateChange(slot, state);
      }
    });
    this.gcAxisFlushPending.clear();
  }
  
  /**
   * 通知 Game Controller Kit 状态变化
   */
  private notifyGCStateChange(slot: number, state: GamepadState): void {
    const copy = this.copyState(state);
    // 鼠标模拟拦截
    if (this.interceptForMouseEmulation(slot, copy)) {
      return;
    }
    if (this.listener) {
      this.listener.onGamepadInput(slot, copy);
    }
  }
  
  // ==================== 传统 InputKit 事件处理 ====================
  
  /**
   * 处理按键事件 (InputKit KeyEvent)
   * 
   * GCK 模式下：
   *   GCK 原生回调已覆盖所有手柄按键（除 2313）。
   *   此处仅处理 2313 和 Start 长按，其余静默丢弃。
   * 
   * 传统模式下：
   *   所有 KeyEvent 通过 buttonMap 映射并更新设备状态。
   */
  handleKeyEvent(deviceId: number, keyCode: number, isPressed: boolean): void {
    // 输入模式尚未确定（异步初始化中），丢弃按键事件避免传统路径创建幽灵设备
    if (!this.modeInitialized) return;
    
    GamepadManager.DEBUG && console.info(`[GAMEPAD-KEY] handleKeyEvent: deviceId=${deviceId}, keyCode=${keyCode}, isPressed=${isPressed}`);
    
    // 特殊处理 2313 按键（可自定义动作）- 无论是否使用 GC Kit 都处理
    if (keyCode === 2313) {
      if (isPressed && this.handleGCButton2313Action()) {
        return;  // 自定义动作已处理（toggle_mouse, toggle_perf, show_menu, none）
      }
      // 'guide'/'select' 映射：通过映射表发送按钮状态
      // 某些手柄的 Home/Guide 键仅通过 KeyEvent 到达（不经过 GCK Button 回调），
      // 如果依赖 GCK Button 回调处理会导致按键丢失
      if (this.useGameControllerKit) {
        const mappedButton = gcButtonMap.get(2313);
        if (mappedButton !== undefined) {
          const firstDeviceId = this.gcDeviceStates.keys().next().value as string;
          if (firstDeviceId) {
            const state = this.gcDeviceStates.get(firstDeviceId);
            if (state) {
              this.updateButtonState(state, mappedButton, isPressed);
              this.notifyGCStateChange(this.getSlotForGCDevice(firstDeviceId), state);
            }
          }
        }
        return;
      }
    }

    // 长按 Start 检测 (108 = KEYCODE_BUTTON_START, 2312 = GCK Start)
    if ((keyCode === 108 || keyCode === 2312) && this.handleStartLongPress(isPressed)) {
      return;
    }
    
    // GCK 模式：KeyEvent 通道完全冗余
    // GCK 原生回调（Axis + Button）已覆盖所有手柄按键（除 2313，已在上方处理）。
    // 所有 KeyEvent 在此静默丢弃，避免与 GCK 回调双通道竞争导致双按。
    if (this.useGameControllerKit) {
      return;
    }
    
    // 传统 InputKit 路径
    const isSpecialKey = this.isSpecialKeyCode(keyCode);
    const resolvedDeviceId = this.resolveDeviceIdForKeyEvent(deviceId, keyCode, isSpecialKey);
    if (resolvedDeviceId === -1) return;
    
    const state = this.deviceStates.get(resolvedDeviceId);
    if (!state) {
      console.warn(`[GAMEPAD-KEY] 无法获取设备 ${resolvedDeviceId} 的状态`);
      return;
    }
    
    const buttonFlag = buttonMap.get(keyCode);
    if (buttonFlag !== undefined) {
      // 通道级D-pad去重：如果Axis通道已提供D-pad，KeyEvent通道静默丢弃
      if ((buttonFlag & MoonlightButton.DPAD_MASK) !== 0 && this.dpadAxisActive.has(resolvedDeviceId)) {
        GamepadManager.DEBUG && console.info(`[GAMEPAD-KEY] D-pad通道去重: keyCode=${keyCode} (Axis通道已处理)`);
        return;
      }
      GamepadManager.DEBUG && console.info(`[GAMEPAD-KEY] 映射按键: keyCode=${keyCode} -> 0x${buttonFlag.toString(16)}`);
      this.updateButtonState(state, buttonFlag, isPressed);
      this.notifyStateChange(resolvedDeviceId, state);
    } else {
      GamepadManager.DEBUG && console.info(`[GAMEPAD-KEY] 未映射的按键: keyCode=${keyCode}`);
    }
  }
  
  /**
   * 解析按键事件的目标设备 ID
   * @returns 解析后的设备 ID，-1 表示无法处理
   */
  private resolveDeviceIdForKeyEvent(deviceId: number, keyCode: number, isSpecialKey: boolean): number {
    if (this.connectedDevices.has(deviceId)) {
      return deviceId;
    }
    
    // 特殊按键：路由到第一个已连接设备
    if (isSpecialKey) {
      const existingDevices = Array.from(this.connectedDevices.keys());
      if (existingDevices.length > 0) {
        GamepadManager.DEBUG && console.info(`[GAMEPAD-KEY] 特殊按键 ${keyCode} 路由到设备 ${existingDevices[0]}`);
        return existingDevices[0];
      }
      console.warn(`[GAMEPAD-KEY] 特殊按键 ${keyCode} 无可用设备处理`);
      return -1;
    }
    
    // 普通按键：动态注册设备
    if (!this.deviceStates.has(deviceId)) {
      this.deviceStates.set(deviceId, this.createEmptyState());
      this.connectedDevices.set(deviceId, `Unknown Controller ${deviceId}`);
      // 分配正确的槽位 (0-3)，避免原始 deviceId 溢出
      const deviceKey = `inputkit_${deviceId}`;
      const slot = this.allocateSlotForDevice(deviceKey);
      if (slot >= 0) {
        this.controllerIdToDeviceKey.set(deviceId, deviceKey);
      }
      const effectiveSlot = slot >= 0 ? slot : 0;
      console.info(`[GAMEPAD-KEY] 动态注册设备 ${deviceId} -> Slot ${effectiveSlot}`);
      this.listener?.onGamepadConnected(effectiveSlot, `Controller ${effectiveSlot}`, MoonlightControllerType.XBOX);
    }
    return deviceId;
  }
  
  /**
   * 处理轴事件 (InputKit)
   */
  handleAxisEvent(deviceId: number, axisCode: number, value: number): void {
    if (!this.connectedDevices.has(deviceId)) return;
    
    const state = this.deviceStates.get(deviceId);
    if (!state) return;
    
    const intValue = Math.floor(value * AXIS_MAX);
    
    switch (axisCode) {
      case 0: // ABS_X - 左摇杆 X
        state.leftStickX = intValue;
        break;
      case 1: // ABS_Y - 左摇杆 Y
        state.leftStickY = intValue;
        break;
      case 2: // ABS_Z - 右摇杆 X
        state.rightStickX = intValue;
        break;
      case 5: // ABS_RZ - 右摇杆 Y
        state.rightStickY = intValue;
        break;
      case 17: // ABS_HAT0X - D-Pad X
        this.dpadAxisActive.add(deviceId);
        this.updateDpadHorizontal(state, value);
        break;
      case 18: // ABS_HAT0Y - D-Pad Y
        this.dpadAxisActive.add(deviceId);
        this.updateDpadVertical(state, value);
        break;
      case 9: // ABS_GAS - 右扳机
        state.rightTrigger = Math.floor((value + 1) * (TRIGGER_MAX / 2));
        break;
      case 10: // ABS_BRAKE - 左扳机
        state.leftTrigger = Math.floor((value + 1) * (TRIGGER_MAX / 2));
        break;
    }
    
    this.notifyStateChange(deviceId, state);
  }
  
  /**
   * 更新 D-Pad 水平方向按钮
   */
  private updateDpadHorizontal(state: GamepadState, value: number): void {
    if (value < 0) {
      state.buttons |= MoonlightButton.LEFT;
      state.buttons &= ~MoonlightButton.RIGHT;
    } else if (value > 0) {
      state.buttons |= MoonlightButton.RIGHT;
      state.buttons &= ~MoonlightButton.LEFT;
    } else {
      state.buttons &= ~(MoonlightButton.LEFT | MoonlightButton.RIGHT);
    }
  }
  
  /**
   * 更新 D-Pad 垂直方向按钮
   */
  private updateDpadVertical(state: GamepadState, value: number): void {
    if (value < 0) {
      state.buttons |= MoonlightButton.UP;
      state.buttons &= ~MoonlightButton.DOWN;
    } else if (value > 0) {
      state.buttons |= MoonlightButton.DOWN;
      state.buttons &= ~MoonlightButton.UP;
    } else {
      state.buttons &= ~(MoonlightButton.UP | MoonlightButton.DOWN);
    }
  }
  
  // ==================== 槽位管理 ====================
  
  /**
   * 为 USB 设备分配槽位
   */
  private allocateSlotForDevice(deviceKey: string): number {
    return this.allocateSlot(deviceKey, this.deviceKeyToSlot, 'GAMEPAD');
  }
  
  /**
   * 释放 USB 设备槽位
   */
  private releaseSlotForDevice(deviceKey: string): void {
    this.releaseSlot(deviceKey, this.deviceKeyToSlot, 'GAMEPAD');
  }
  
  /**
   * 获取 controllerId 对应的槽位
   */
  getControllerSlot(controllerId: number): number {
    const deviceKey = this.controllerIdToDeviceKey.get(controllerId);
    if (deviceKey) {
      const slot = this.deviceKeyToSlot.get(deviceKey);
      if (slot !== undefined) return slot;
    }
    // 回退：钳位到 0，避免原始 controllerId (可能 ≥1000) 溢出
    return 0;
  }
  
  /**
   * 通知监听器状态变化
   */
  private notifyStateChange(deviceId: number, state: GamepadState): void {
    const slot = this.getControllerSlot(deviceId);
    const copy = this.copyState(state);
    // 鼠标模拟拦截
    if (this.interceptForMouseEmulation(slot, copy)) {
      return;
    }
    this.listener?.onGamepadInput(slot, copy);
  }

  /**
   * 检查是否有 USB 手柄连接
   * 用于 UI 决定是否显示 USB 驱动相关选项
   */
  hasUsbGamepad(): boolean {
    return this.usbDriverService.getControllerCount() > 0;
  }

  /**
   * 获取已连接的手柄列表（已去重）
   */
  getConnectedGamepads(): GamepadInfo[] {
    if (this.useGameControllerKit) {
      // Game Controller Kit 模式下从设备列表构建，按槽位去重
      const devices = gameControllerService.getAllDevices();
      const slotSeen = new Set<number>();
      const result: GamepadInfo[] = [];
      for (const d of devices) {
        const slot = this.getSlotForGCDevice(d.deviceId);
        if (slotSeen.has(slot)) continue;  // 同一物理设备的另一个接口，跳过
        slotSeen.add(slot);
        const info: GamepadInfo = {
          id: slot,
          name: d.name,
          isUsb: false,
          isBluetooth: false
        };
        result.push(info);
      }
      return result;
    }
    // 传统模式下直接返回 deviceInfoMap 的值
    return Array.from(this.deviceInfoMap.values());
  }
  
  /**
   * 重置会话状态（串流结束时调用）
   * 与 cleanup() 不同，此方法保留单例和驱动生命周期，只重置会话相关状态
   * 同时清理设备缓存，避免下次进入串流时先重放旧连接再扫描导致重复识别
   */
  resetSession(): void {
    console.info('[GAMEPAD] 重置会话状态');
    
    // 停止鼠标模拟 & 震动
    this.mouseEmulationService.cleanup();
    this.vibrationService.stopAll();

    if (this.gcAxisFlushTimerId !== -1) {
      clearTimeout(this.gcAxisFlushTimerId);
      this.gcAxisFlushTimerId = -1;
    }
    this.gcAxisFlushPending.clear();

    // 重置槽位管理状态
    this.slotOccupied = [false, false, false, false];
    this.deviceKeyToSlot.clear();
    this.gcDeviceIdToSlot.clear();
    this.gcPhysicalAddressToDeviceId.clear();
    this.gcDeviceInfoCache.clear();
    this.controllerIdToDeviceKey.clear();
    this.usbDeviceKeyToId.clear();
    
    // 清空传统路径设备缓存，下一会话由真实扫描/驱动事件重建
    this.connectedDevices.clear();
    this.deviceStates.clear();
    this.deviceInfoMap.clear();
    this.dpadAxisActive.clear();
    
    // 重置 GC Kit 设备状态
    this.gcDeviceStates.forEach((state, _deviceId) => {
      state.buttons = 0;
      state.leftStickX = 0;
      state.leftStickY = 0;
      state.rightStickX = 0;
      state.rightStickY = 0;
      state.leftTrigger = 0;
      state.rightTrigger = 0;
    });
    
    console.info('[GAMEPAD] 会话状态已重置');
  }
  
  /**
   * 清理
   */
  cleanup(): void {
    // 停止鼠标模拟 & 震动
    this.mouseEmulationService.cleanup();
    this.vibrationService.stopAll();

    if (this.gcAxisFlushTimerId !== -1) {
      clearTimeout(this.gcAxisFlushTimerId);
      this.gcAxisFlushTimerId = -1;
    }
    this.gcAxisFlushPending.clear();

    // 清理 Game Controller Kit
    if (this.useGameControllerKit) {
      gameControllerService.stopMonitor();
      gameControllerService.setDeviceCallback(null);
      gameControllerService.setButtonCallback(null);
      gameControllerService.setAxisCallback(null);
      gameControllerService.uninit();
      this.gcDeviceStates.clear();
      this.gcDeviceIdToSlot.clear();
      this.gcPhysicalAddressToDeviceId.clear();
      this.gcDeviceInfoCache.clear();
      this.gcDpadAxisActive.clear();
    }
    
    // 清理传统输入
    try {
      inputDevice.off('change');
    } catch (err) {
      // ignore
    }
    
    // 停止 USB 驱动服务
    this.usbDriverService.stop();
    
    this.connectedDevices.clear();
    this.deviceStates.clear();
    this.deviceInfoMap.clear();
    this.dpadAxisActive.clear();
    this.usbDeviceKeyToId.clear();
    this.deviceKeyToSlot.clear();
    this.controllerIdToDeviceKey.clear();
    this.slotOccupied = [false, false, false, false];
    this.listener = null;
  }
  
  // ==================== UsbDriverListener 实现 ====================
  
  /**
   * USB 控制器状态报告
   * 
   * 混合模式下（GCK + USB 驱动），GCK 已处理所有输入，
   * USB 驱动的状态报告仅用于设备震动/附加功能的状态同步，不重复发送到主机。
   */
  reportControllerState(
    controllerId: number,
    buttonFlags: number,
    leftStickX: number,
    leftStickY: number,
    rightStickX: number,
    rightStickY: number,
    leftTrigger: number,
    rightTrigger: number
  ): void {
    // 混合模式：GCK 已处理输入，跳过 USB 驱动的输入报告避免双重发送
    if (this.useGameControllerKit) {
      return;
    }
    
    let state = this.deviceStates.get(controllerId);
    if (!state) {
      state = this.createEmptyState();
      this.deviceStates.set(controllerId, state);
    }
    
    const clampAxis = (v: number) => Math.max(-AXIS_MAX, Math.min(AXIS_MAX, Math.floor(v * AXIS_MAX)));
    
    state.buttons = buttonFlags;
    state.leftStickX = clampAxis(leftStickX);
    state.leftStickY = clampAxis(-leftStickY);  // Y轴取负与Android一致
    state.rightStickX = clampAxis(rightStickX);
    state.rightStickY = clampAxis(-rightStickY);
    state.leftTrigger = Math.floor(leftTrigger * TRIGGER_MAX);
    state.rightTrigger = Math.floor(rightTrigger * TRIGGER_MAX);
    
    this.notifyStateChange(controllerId, state);
  }
  
  /**
   * USB 控制器运动数据报告（陀螺仪/加速度计）
   * 当 USB 手柄自带 IMU 时，直接转发数据到串流
   */
  reportControllerMotion(
    controllerId: number,
    motionType: number,
    x: number,
    y: number,
    z: number
  ): void {
    const slot = this.getControllerSlot(controllerId);
    if (this.sensorDataCallback) {
      this.sensorDataCallback(slot, motionType, x, y, z);
    }
  }

  // ==================== 设备传感器回退 ====================

  /**
   * 加载传感器相关设置
   */
  private async loadSensorSettings(): Promise<void> {
    try {
      const results = await Promise.all([
        PreferencesUtil.get<boolean>(SettingsKeys.GAMEPAD_MOTION_SENSORS, true),
        PreferencesUtil.get<boolean>(SettingsKeys.GAMEPAD_MOTION_FALLBACK, false)
      ]);
      this.gamepadMotionSensorsEnabled = results[0];
      this.sensorFallbackEnabled = results[1];
      console.info(`[GAMEPAD] 设备传感器回退设置: ${results[1]}`);
    } catch (e) {
      this.gamepadMotionSensorsEnabled = true;
      this.sensorFallbackEnabled = false;
    }
  }

  /**
   * 设置传感器数据回调
   * 由 StreamingSession 调用，用于将传感器数据发送到串流
   */
  setSensorDataCallback(callback: ((controllerNumber: number, motionType: number, x: number, y: number, z: number) => void) | null): void {
    this.sensorDataCallback = callback;

    // 同时设置设备传感器服务的回调
    if (callback) {
      this.deviceSensorService.setDataCallback((controllerNumber, motionType, x, y, z) => {
        if (this.sensorDataCallback) {
          this.sensorDataCallback(controllerNumber, motionType, x, y, z);
        }
      });
    } else {
      this.deviceSensorService.setDataCallback(null);
      this.deviceSensorService.disableAll();
      this.usingDeviceSensorFallback = false;
    }
  }

  /**
   * 处理主机请求的运动传感器状态变更
   * 由 StreamingSession 的 setMotionEventState 回调触发
   * 
   * 逻辑参照 Android ControllerHandler.handleSetMotionEventState():
   * 1. 如果手柄自带传感器 → 使用手柄传感器（USB 控制器 IMU）
   * 2. 如果手柄无传感器且用户启用了回退 → 使用设备传感器
   * 3. 如果均不可用 → 忽略
   * 
   * @param controllerNumber 控制器编号
   * @param motionType LI_MOTION_TYPE_ACCEL (0x01) 或 LI_MOTION_TYPE_GYRO (0x02)
   * @param reportRateHz 报告频率，0 表示停止
   */
  handleSetMotionEventState(controllerNumber: number, motionType: number, reportRateHz: number): void {
    console.info(`[GAMEPAD] 主机请求传感器: ctrl=${controllerNumber}, type=${motionType}, rate=${reportRateHz}Hz`);

    if (!this.gamepadMotionSensorsEnabled) {
      console.info('[GAMEPAD] 传感器功能已被用户禁用');
      return;
    }

    // TODO: 当 USB 驱动支持 IMU 时，优先使用手柄自带传感器

    // 回退到设备传感器
    if (!this.sensorFallbackEnabled) {
      console.info('[GAMEPAD] 设备传感器回退未启用');
      return;
    }

    // 仅对控制器 0 使用设备传感器回退（和 Android 一致）
    if (controllerNumber !== 0) {
      console.info(`[GAMEPAD] 仅控制器 0 支持设备传感器回退 (当前: ${controllerNumber})`);
      return;
    }

    // 检查设备传感器可用性
    if (motionType === LI_MOTION_TYPE_GYRO && !this.deviceSensorService.hasGyroscope()) {
      console.warn('[GAMEPAD] 设备没有陀螺仪');
      return;
    }
    if (motionType === LI_MOTION_TYPE_ACCEL && !this.deviceSensorService.hasAccelerometer()) {
      console.warn('[GAMEPAD] 设备没有加速度计');
      return;
    }

    // 设置设备传感器的控制器编号
    this.deviceSensorService.setControllerNumber(controllerNumber);

    // 启用/禁用设备传感器
    this.deviceSensorService.setMotionEventState(motionType, reportRateHz);

    this.usingDeviceSensorFallback = reportRateHz > 0;
    console.info(`[GAMEPAD] 设备传感器回退: ${this.usingDeviceSensorFallback ? '启用' : '禁用'}`);
  }

  /**
   * 检查是否需要在控制器到达事件中报告传感器能力
   * @returns 传感器能力标志位 (LI_CCAP_ACCEL | LI_CCAP_GYRO)
   */
  getSensorCapabilities(): number {
    if (!this.gamepadMotionSensorsEnabled) {
      return 0;
    }

    let capabilities = 0;

    // 检查 USB 手柄传感器
    // TODO: 从 USB 驱动获取手柄传感器信息

    // 检查设备传感器回退
    if (this.sensorFallbackEnabled) {
      if (this.deviceSensorService.hasAccelerometer()) {
        capabilities |= 0x10;  // LI_CCAP_ACCEL
      }
      if (this.deviceSensorService.hasGyroscope()) {
        capabilities |= 0x20;  // LI_CCAP_GYRO
      }
    }

    return capabilities;
  }

  /**
   * 停止所有传感器（串流断开时调用）
   */
  stopAllSensors(): void {
    this.deviceSensorService.disableAll();
    this.usingDeviceSensorFallback = false;
    this.sensorDataCallback = null;
    console.info('[GAMEPAD] 所有传感器已停止');
  }
  
  /**
   * USB 设备移除
   */
  deviceRemoved(controller: AbstractController): void {
    const controllerId = controller.getControllerId();
    const deviceKey = controller.getDeviceKey();
    console.info(`[GAMEPAD-USB] 设备移除: ID=${controllerId}, Key=${deviceKey}`);

    // 混合模式：GCK 管理设备生命周期，这里只清理震动路由记录
    if (this.useGameControllerKit) {
      this.usbDeviceKeyToId.delete(deviceKey);
      this.controllerIdToDeviceKey.delete(controllerId);
      console.info(`[GAMEPAD-USB] 混合模式: 清理震动路由记录`);
      return;
    }

    if (!this.connectedDevices.has(controllerId)) return;
    
    const slot = this.getControllerSlot(controllerId);
    
    // 清理所有相关状态
    this.connectedDevices.delete(controllerId);
    this.deviceStates.delete(controllerId);
    this.deviceInfoMap.delete(controllerId);
    this.usbDeviceKeyToId.delete(deviceKey);
    this.controllerIdToDeviceKey.delete(controllerId);
    this.releaseSlotForDevice(deviceKey);
    this.dpadAxisActive.delete(controllerId);

    this.listener?.onGamepadDisconnected(slot);
  }
  
  /**
   * USB 设备添加
   */
  deviceAdded(controller: AbstractController): void {
    const controllerId = controller.getControllerId();
    const vendorId = controller.getVendorId();
    const productId = controller.getProductId();
    const deviceKey = controller.getDeviceKey();
    
    // 混合模式：GCK 处理设备管理和输入，USB 驱动只提供震动/附加功能
    // 不注册设备、不分配槽位、不通知 listener（避免与 GCK 双重注册）
    if (this.useGameControllerKit) {
      const name = this.getControllerFriendlyName(vendorId, productId);
      // 仅记录 USB 设备 key → 用于震动路由
      this.usbDeviceKeyToId.set(deviceKey, controllerId);
      this.controllerIdToDeviceKey.set(controllerId, deviceKey);
      console.info(`[GAMEPAD-USB] 混合模式: 记录 USB 设备用于震动: ${name} (ID=${controllerId})`);
      return;
    }
    
    // 防止重复添加
    if (this.connectedDevices.has(controllerId)) {
      GamepadManager.DEBUG && console.info(`[GAMEPAD-USB] 控制器 ID=${controllerId} 已存在，跳过`);
      return;
    }
    
    // 处理设备重连（同一物理设备，不同 controllerId）
    this.handleDeviceReconnect(deviceKey, controllerId);
    
    // 获取友好名称
    const name = this.getControllerFriendlyName(vendorId, productId);
    
    // 分配槽位
    const slot = this.allocateSlotForDevice(deviceKey);
    if (slot < 0) {
      console.warn(`[GAMEPAD-USB] 无法分配槽位，设备被忽略: ${name}`);
      return;
    }
    
    // 注册设备
    this.registerUsbDevice(controllerId, deviceKey, name, vendorId, productId);
    const ddkTag = controller.isDdkPolling() ? ' [DDK]' : '';
    console.info(`[GAMEPAD-USB] 设备添加: ${name}${ddkTag} (ID=${controllerId}, Slot=${slot})`);
    
    const ctrlType = MoonlightControllerType.fromVendorProduct(vendorId, productId);
    this.listener?.onGamepadConnected(slot, `${name}${ddkTag}`, ctrlType);
  }
  
  /**
   * 处理设备重连
   */
  private handleDeviceReconnect(deviceKey: string, newControllerId: number): void {
    const existingControllerId = this.usbDeviceKeyToId.get(deviceKey);
    if (existingControllerId !== undefined && existingControllerId !== newControllerId) {
      console.info(`[GAMEPAD-USB] 设备重连: Key=${deviceKey}, 旧ID=${existingControllerId}, 新ID=${newControllerId}`);
      // 清理旧记录但保留槽位
      this.connectedDevices.delete(existingControllerId);
      this.deviceStates.delete(existingControllerId);
      this.deviceInfoMap.delete(existingControllerId);
      this.controllerIdToDeviceKey.delete(existingControllerId);
    }
  }
  
  /**
   * 获取控制器友好名称
   */
  private getControllerFriendlyName(vendorId: number, productId: number): string {
    if (vendorId === VendorId.MICROSOFT) {
      return 'Xbox Controller';
    }
    if (vendorId === VendorId.SONY) {
      if (productId === ProductId.DUALSENSE || productId === ProductId.DUALSENSE_EDGE) {
        return 'DualSense Controller';
      }
      return 'DualShock 4 Controller';
    }
    if (vendorId === VendorId.NINTENDO) {
      if (productId === ProductId.SWITCH_PRO) {
        return 'Switch Pro Controller';
      }
      return 'Nintendo Joy-Con';
    }
    return `USB Controller (VID:0x${vendorId.toString(16)}, PID:0x${productId.toString(16)})`;
  }
  
  /**
   * 注册 USB 设备
   */
  private registerUsbDevice(
    controllerId: number, 
    deviceKey: string, 
    name: string, 
    vendorId: number, 
    productId: number
  ): void {
    this.connectedDevices.set(controllerId, name);
    this.deviceStates.set(controllerId, this.createEmptyState());
    this.usbDeviceKeyToId.set(deviceKey, controllerId);
    this.controllerIdToDeviceKey.set(controllerId, deviceKey);
    
    this.deviceInfoMap.set(controllerId, {
      id: controllerId,
      name, vendor: vendorId, product: productId,
      isUsb: true, bus: DeviceBusType.BUS_USB
    });
  }
  
  /**
   * 刷新 USB 设备
   */
  // ==================== 震动处理（委托 GamepadVibrationService） ====================

  /** 处理震动反馈 */
  handleRumble(controllerNumber: number, lowFreqMotor: number, highFreqMotor: number): void {
    this.vibrationService.handleRumble(controllerNumber, lowFreqMotor, highFreqMotor);
  }

  /** 处理扳机震动 */
  handleRumbleTriggers(controllerNumber: number, leftTrigger: number, rightTrigger: number): void {
    this.vibrationService.handleRumbleTriggers(controllerNumber, leftTrigger, rightTrigger);
  }

  /** 仅向 USB 控制器发送振动（跳过设备马达和模式路由） */
  rumbleUsbControllers(controllerNumber: number, lowFreqMotor: number, highFreqMotor: number): void {
    this.vibrationService.rumbleUsbControllersOnly(controllerNumber, lowFreqMotor, highFreqMotor);
  }

  /** 检查是否有 USB 控制器连接 */
  hasUsbControllers(): boolean {
    return this.vibrationService.hasUsbControllers();
  }

  /** 立即停止所有振动（设备马达 + USB 控制器马达） */
  stopAllVibration(): void {
    this.vibrationService.stopAll();
  }
}
