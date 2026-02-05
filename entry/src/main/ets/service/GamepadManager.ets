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
import { vibrator } from '@kit.SensorServiceKit';
import { UsbDriverService, UsbDriverListener, AbstractController, ButtonFlags } from './usbdriver/index';
import { 
  gameControllerService, 
  AxisType, 
  GameControllerDeviceInfo 
} from './GameControllerService';
import { SettingsService, SettingsKeys } from './SettingsService';
import { PreferencesUtil } from '../utils/PreferencesUtil';

// ==================== 类型定义 ====================

/**
 * 手柄状态数据结构
 */
export interface GamepadState {
  buttons: number;
  leftStickX: number;
  leftStickY: number;
  rightStickX: number;
  rightStickY: number;
  leftTrigger: number;
  rightTrigger: number;
}

/**
 * 手柄设备信息
 */
export interface GamepadInfo {
  id: number;
  name: string;
  bus?: number;
  vendor?: number;
  product?: number;
  isUsb?: boolean;
  isBluetooth?: boolean;
}

/**
 * 手柄输入事件监听器接口
 */
export interface GamepadInputListener {
  onGamepadConnected: (deviceId: number, name: string) => void;
  onGamepadDisconnected: (deviceId: number) => void;
  onGamepadInput: (deviceId: number, state: GamepadState) => void;
}

// ==================== 常量定义 ====================

/** 设备总线类型（Linux input.h BUS_* 定义） */
export class DeviceBusType {
  static readonly BUS_USB = 0x03;
  static readonly BUS_BLUETOOTH = 0x05;
}

/** Moonlight 按键标志位 */
class MoonlightButton {
  static readonly UP = 0x0001;
  static readonly DOWN = 0x0002;
  static readonly LEFT = 0x0004;
  static readonly RIGHT = 0x0008;
  static readonly START = 0x0010;
  static readonly BACK = 0x0020;
  static readonly LS = 0x0040;
  static readonly RS = 0x0080;
  static readonly LB = 0x0100;
  static readonly RB = 0x0200;
  static readonly SPECIAL = 0x0400;
  static readonly A = 0x1000;
  static readonly B = 0x2000;
  static readonly X = 0x4000;
  static readonly Y = 0x8000;
  static readonly DPAD_MASK = MoonlightButton.UP | MoonlightButton.DOWN | MoonlightButton.LEFT | MoonlightButton.RIGHT;
}

/**
 * 2313 按键动作类型
 * 'guide' - 发送 Guide/Home 键
 * 'select' - 发送 Select/Back 键
 * 'toggle_mouse' - 切换鼠标模式
 * 'toggle_perf' - 切换性能图层
 * 'show_menu' - 显示 ESC 菜单
 * 'none' - 不做任何操作
 */
export type GCButton2313Action = 'guide' | 'select' | 'toggle_mouse' | 'toggle_perf' | 'show_menu' | 'none';

/**
 * 2313 自定义动作回调接口
 */
export interface GCButton2313ActionCallback {
  onToggleMouse?: () => void;
  onTogglePerf?: () => void;
  onShowMenu?: () => void;
}

/** 摇杆轴值范围 */
const AXIS_MAX = 32767;
const TRIGGER_MAX = 255;

/** 特殊按键码范围（2311-2315）*/
const SPECIAL_KEYCODE_MIN = 2311;
const SPECIAL_KEYCODE_MAX = 2315;

/** 已知厂商 ID */
class VendorId {
  static readonly MICROSOFT = 0x045e;
  static readonly SONY = 0x054c;
  static readonly NINTENDO = 0x057e;
}

/** 已知产品 ID */
class ProductId {
  // Sony
  static readonly DUALSENSE = 0x0ce6;
  static readonly DUALSENSE_EDGE = 0x0df2;
  // Nintendo
  static readonly SWITCH_PRO = 0x2009;
}

// ==================== 按键映射表 ====================

/** InputKit 按键码到 Moonlight 按钮的映射 */
const buttonMap = new Map<number, number>([
  // D-Pad
  [19, MoonlightButton.UP],     // KEYCODE_DPAD_UP
  [20, MoonlightButton.DOWN],   // KEYCODE_DPAD_DOWN
  [21, MoonlightButton.LEFT],   // KEYCODE_DPAD_LEFT
  [22, MoonlightButton.RIGHT],  // KEYCODE_DPAD_RIGHT
  // Face buttons
  [96, MoonlightButton.A],      // KEYCODE_BUTTON_A
  [97, MoonlightButton.B],      // KEYCODE_BUTTON_B
  [99, MoonlightButton.X],      // KEYCODE_BUTTON_X
  [100, MoonlightButton.Y],     // KEYCODE_BUTTON_Y
  // Shoulder buttons
  [102, MoonlightButton.LB],    // KEYCODE_BUTTON_L1
  [103, MoonlightButton.RB],    // KEYCODE_BUTTON_R1
  // Stick buttons
  [106, MoonlightButton.LS],    // KEYCODE_BUTTON_THUMBL
  [107, MoonlightButton.RS],    // KEYCODE_BUTTON_THUMBR
  // Start/Back
  [108, MoonlightButton.START], // KEYCODE_BUTTON_START
  [109, MoonlightButton.BACK],  // KEYCODE_BUTTON_SELECT
  // Special
  [110, MoonlightButton.SPECIAL], // KEYCODE_BUTTON_MODE
  // GC Kit 按键码（某些蓝牙手柄可能通过 KeyEvent 发送这些码）
  [2311, MoonlightButton.BACK],   // KEYCODE_BUTTON_SELECT - Select 键
  [2312, MoonlightButton.START],  // KEYCODE_BUTTON_START - Start 键
  [2313, MoonlightButton.SPECIAL], // KEYCODE_BUTTON_MODE - Home 键（可自定义）
  [2314, MoonlightButton.LS],     // KEYCODE_BUTTON_THUMBL - 左摇杆按下
  [2315, MoonlightButton.RS],     // KEYCODE_BUTTON_THUMBR - 右摇杆按下
]);

/** Game Controller Kit 按键码到 Moonlight 按钮的映射 */
const gcButtonMap = new Map<number, number>([
  // Face buttons
  [2301, MoonlightButton.A],      // BUTTON_A
  [2302, MoonlightButton.B],      // BUTTON_B
  [2303, MoonlightButton.BACK],   // BUTTON_C - 映射为 Select/Back（鸿蒙不支持原生 Select 按键）
  [2304, MoonlightButton.X],      // BUTTON_X
  [2305, MoonlightButton.Y],      // BUTTON_Y
  // Shoulder buttons
  [2307, MoonlightButton.LB],     // LEFT_SHOULDER
  [2308, MoonlightButton.RB],     // RIGHT_SHOULDER
  // Thumbstick buttons
  [2314, MoonlightButton.LS],     // LEFT_THUMBSTICK
  [2315, MoonlightButton.RS],     // RIGHT_THUMBSTICK
  // Menu buttons - 根据测试调整
  [2311, MoonlightButton.BACK],   // 实测为 Select/Back 键
  [2312, MoonlightButton.START],  // BUTTON_MENU (Start)
  [2313, MoonlightButton.SPECIAL],// 默认为 Guide/Home，可用户自定义
  // D-Pad
  [2012, MoonlightButton.UP],     // DPAD_UP
  [2013, MoonlightButton.DOWN],   // DPAD_DOWN
  [2014, MoonlightButton.LEFT],   // DPAD_LEFT
  [2015, MoonlightButton.RIGHT],  // DPAD_RIGHT
]);

/** 手柄设备名称关键词（用于识别手柄） */
const GAMEPAD_NAME_KEYWORDS = [
  'controller', 'gamepad', 'joystick', 'xbox', 'playstation',
  'dualshock', 'dualsense', 'switch', 'pro controller', 'joycon', 'joy-con'
];

/** 非手柄设备关键词（用于排除） */
const NON_GAMEPAD_KEYWORDS = [
  'keyboard', '键盘', 'mouse', '鼠标', 'touchpad', 'trackpad', '触摸板'
];

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
  private usbDevices = new Set<number>();
  
  // Game Controller Kit 状态
  private useGameControllerKit = false;
  private gcDeviceIdToSlot = new Map<string, number>();
  private gcDeviceStates = new Map<string, GamepadState>();
  
  // 槽位管理（统一 GC Kit、InputKit 和 USB 驱动的槽位分配）
  private deviceKeyToSlot = new Map<string, number>();
  private slotOccupied = [false, false, false, false];
  private controllerIdToDeviceKey = new Map<number, string>();
  private usbDeviceKeyToId = new Map<string, number>();
  
  // 震动设置
  private deviceVibrateEnabled = false;
  private deviceVibrateStrength = 100;
  private vibrationMode = '自动';

  // 2313 自定义动作设置
  private gcButton2313Action: GCButton2313Action = 'guide';
  private gcButton2313ActionCallback: GCButton2313ActionCallback | null = null;
  
  private constructor() {
    this.usbDriverService = UsbDriverService.getInstance();
    this.loadGCButtonMappingSettings();
    this.initializeGameControllerKit();
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
  private loadGCButtonMappingSettings(): void {
    PreferencesUtil.get<string>(SettingsKeys.GC_BUTTON_HOME_MAPPING, 'guide').then(action => {
      this.updateGCButton2313Action(action as GCButton2313Action);
    });
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
   * 回退到传统输入方案 (InputKit + USB 驱动)
   */
  private fallbackToLegacyInput(): void {
    this.useGameControllerKit = false;
    this.initializeDeviceListener();
    this.initializeUsbDriver();
  }
  
  /**
   * 强制切换到 USB 驱动模式
   * 用于用户手动接管或 Game Controller Kit 有问题时
   * @returns 是否切换成功
   */
  async forceUsbDriverMode(): Promise<boolean> {
    console.info('[GAMEPAD] 用户请求强制切换到 USB 驱动模式');
    
    // 如果已经在使用 USB 驱动模式，直接返回
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
      // 先通知所有 GC Kit 设备断开
      this.gcDeviceIdToSlot.forEach((slot, deviceId) => {
        if (this.listener) {
          this.listener.onGamepadDisconnected(slot);
        }
      });
      this.gcDeviceIdToSlot.clear();
      this.gcDeviceStates.clear();
      
      console.info('[GAMEPAD] Game Controller Kit 已停止');
    } catch (err) {
      console.error('[GAMEPAD] 停止 Game Controller Kit 失败:', err);
    }
    
    // 切换到 USB 驱动模式
    this.fallbackToLegacyInput();
    
    console.info('[GAMEPAD] 已切换到 USB 驱动模式');
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
   * 获取当前输入模式的描述
   */
  getInputModeDescription(): string {
    if (this.useGameControllerKit) {
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
    this.deviceVibrateEnabled = enabled;
    this.deviceVibrateStrength = Math.max(0, Math.min(100, strength));
    this.vibrationMode = mode;
    console.info(`[GAMEPAD] 震动设置: enabled=${enabled}, strength=${this.deviceVibrateStrength}, mode=${mode}`);
  }

  /**
   * 设置 USB 控制器的协议类型
   * 用于手柄有多种模式（如 DS4 模拟模式）时强制使用特定协议
   * @param controllerId 控制器 ID
   * @param protocolType 协议类型 (0=自动, 1=Xbox, 2=DS4, 3=Switch, 4=Generic, 5=DualSense)
   * @returns 是否设置成功
   */
  setControllerProtocolType(controllerId: number, protocolType: number): boolean {
    return this.usbDriverService.setControllerProtocolType(controllerId, protocolType);
  }
  
  /**
   * 手动触发 USB 设备重新扫描
   * 用于设备空闲断开后重新连接
   */
  async rescanUsbDevices(): Promise<void> {
    await this.usbDriverService.rescanDevices();
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
      if (this.useGameControllerKit) {
        // Game Controller Kit 模式
        console.info(`GamepadManager: 设置监听器 (Game Controller Kit 模式)`);
        
        // 确保 GC Kit 回调已设置（可能被测试页面清空）
        this.ensureGCKitCallbacks();
        
        // 通知已连接的 Game Controller Kit 设备
        const devices = gameControllerService.getAllDevices();
        for (const device of devices) {
          const slot = this.getSlotForGCDevice(device.deviceId);
          console.info(`GamepadManager: 通知已连接手柄: ${device.name} (Slot: ${slot})`);
          listener.onGamepadConnected(slot, device.name);
        }
      } else {
        // 传统模式
        console.info(`GamepadManager: 设置监听器，已连接设备数: ${this.connectedDevices.size}`);
        this.connectedDevices.forEach((name, deviceId) => {
          console.info(`GamepadManager: 通知已连接手柄: ${name} (ID: ${deviceId})`);
          listener.onGamepadConnected(deviceId, name);
        });
        
        // 重新扫描设备，确保不遗漏
        this.scanConnectedDevices();
        
        // 刷新 USB 设备
        this.usbDriverService.refreshDevices();
      }
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
   * 获取指定设备的详细信息
   * @param deviceId 设备 ID
   * @returns 设备信息，如果设备未注册则返回 undefined
   */
  getGamepadInfo(deviceId: number): GamepadInfo | undefined {
    return this.deviceInfoMap.get(deviceId);
  }
  
  /**
   * 获取所有已连接手柄的详细信息
   * @returns 所有设备信息的数组
   */
  getAllGamepadInfo(): GamepadInfo[] {
    return Array.from(this.deviceInfoMap.values());
  }
  
  /**
   * 检查指定设备是否是蓝牙设备
   * @param deviceId 设备 ID
   * @returns 是否是蓝牙设备
   */
  isBluetoothDevice(deviceId: number): boolean {
    const info = this.deviceInfoMap.get(deviceId);
    return info?.isBluetooth === true;
  }
  
  /**
   * 检查指定设备是否是 USB 设备
   * @param deviceId 设备 ID
   * @returns 是否是 USB 设备
   */
  isUsbDevice(deviceId: number): boolean {
    const info = this.deviceInfoMap.get(deviceId);
    return info?.isUsb === true;
  }
  
  /**
   * 获取所有蓝牙手柄
   * @returns 蓝牙手柄信息数组
   */
  getBluetoothGamepads(): GamepadInfo[] {
    return Array.from(this.deviceInfoMap.values()).filter(info => info.isBluetooth === true);
  }
  
  /**
   * 获取所有 USB 手柄
   * @returns USB 手柄信息数组
   */
  getUsbGamepads(): GamepadInfo[] {
    return Array.from(this.deviceInfoMap.values()).filter(info => info.isUsb === true);
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
    const hasNonGamepadKeyword = NON_GAMEPAD_KEYWORDS.some(kw => nameLower.includes(kw));
    const hasNonGamepadSource = sources.includes('keyboard' as inputDevice.SourceType) ||
                                 sources.includes('mouse' as inputDevice.SourceType);
    return hasNonGamepadKeyword || hasNonGamepadSource;
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
    
    const connectionType = isBluetooth ? '蓝牙' : (isUsb ? 'USB' : `其他(${bus})`);
    console.info(`[GAMEPAD] ★ 注册手柄: "${deviceInfo.name}" (ID: ${deviceId}, ${connectionType})`);
    GamepadManager.DEBUG && console.info(`[GAMEPAD]   检测: joystick源=${hasJoystickSource}, 名称匹配=${nameIndicatesGamepad}`);
    
    this.listener?.onGamepadConnected(deviceId, deviceInfo.name);
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
      
      this.connectedDevices.delete(deviceId);
      this.deviceStates.delete(deviceId);
      this.deviceInfoMap.delete(deviceId);
      
      console.info(`GamepadManager: 移除手柄 ${name} (ID: ${deviceId}, 连接类型: ${connectionType})`);
      
      if (this.listener) {
        this.listener.onGamepadDisconnected(deviceId);
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
   */
  private isSpecialKeyCode(keyCode: number): boolean {
    return keyCode >= SPECIAL_KEYCODE_MIN && keyCode <= SPECIAL_KEYCODE_MAX;
  }
  
  /**
   * 将特殊按键路由到 GC Kit 设备
   * @returns true 如果已处理，false 如果无法处理
   */
  private routeSpecialKeyToGCKit(keyCode: number, isPressed: boolean): boolean {
    const gcDeviceId = Array.from(this.gcDeviceIdToSlot.keys())[0];
    if (!gcDeviceId) {
      console.warn(`[GAMEPAD-KEY] GC Kit 活跃但无设备，特殊按键 ${keyCode} 丢弃`);
      return false;
    }
    
    let state = this.gcDeviceStates.get(gcDeviceId);
    if (!state) {
      state = this.createEmptyState();
      this.gcDeviceStates.set(gcDeviceId, state);
    }
    
    const buttonFlag = gcButtonMap.get(keyCode);
    if (buttonFlag === undefined) {
      console.warn(`[GAMEPAD-KEY] GC Kit 特殊按键未映射: keyCode=${keyCode}`);
      return false;
    }
    
    this.updateButtonState(state, buttonFlag, isPressed);
    
    GamepadManager.DEBUG && console.info(`[GAMEPAD-KEY] GC Kit 特殊按键路由: keyCode=${keyCode} -> 0x${buttonFlag.toString(16)}`);
    this.notifyGCStateChange(this.getSlotForGCDevice(gcDeviceId), state);
    return true;
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
   * 处理 Game Controller Kit 设备状态变化
   */
  private handleGCDeviceChange(deviceId: string, isConnected: boolean, info: GameControllerDeviceInfo): void {
    console.info(`[GAMEPAD-GC] 设备状态变化: deviceId=${deviceId}, isConnected=${isConnected}, name=${info?.name}`);
    
    if (isConnected) {
      // 分配槽位
      const slot = this.allocateSlotForGCDevice(deviceId);
      if (slot < 0) {
        console.warn(`[GAMEPAD-GC] 无法分配槽位，忽略设备: ${info?.name}`);
        return;
      }
      
      // 创建设备状态
      this.gcDeviceStates.set(deviceId, this.createEmptyState());
      
      // 通知监听器
      if (this.listener) {
        this.listener.onGamepadConnected(slot, info?.name || `Controller ${slot}`);
      }
    } else {
      // 获取槽位（在清理之前）
      const slot = this.getSlotForGCDevice(deviceId);
      
      // 清理状态
      this.gcDeviceStates.delete(deviceId);
      this.releaseSlotForGCDevice(deviceId);
      
      // 通知监听器
      if (this.listener) {
        this.listener.onGamepadDisconnected(slot);
      }
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
    
    // 特殊处理 2313 按键（可自定义动作）
    if (buttonCode === 2313 && isPressed && this.handleGCButton2313Action()) {
      return;  // 自定义动作已处理
    }
    
    // 映射按键码到按钮标志
    const buttonFlag = gcButtonMap.get(buttonCode);
    if (buttonFlag !== undefined) {
      this.updateButtonState(state, buttonFlag, isPressed);
      this.notifyGCStateChange(this.getSlotForGCDevice(deviceId), state);
    } else {
      GamepadManager.DEBUG && console.info(`[GAMEPAD-GC] 未映射的按键: buttonCode=${buttonCode}`);
    }
  }
  
  /**
   * 处理 Game Controller Kit 轴事件
   */
  private handleGCAxisEvent(deviceId: string, axisType: number, x: number, y: number): void {
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
    this.notifyGCStateChange(slot, state);
  }
  
  /**
   * 通知 Game Controller Kit 状态变化
   */
  private notifyGCStateChange(slot: number, state: GamepadState): void {
    if (this.listener) {
      this.listener.onGamepadInput(slot, this.copyState(state));
    }
  }
  
  // ==================== 传统 InputKit 事件处理 ====================
  
  /**
   * 处理按键事件 (传统 InputKit 方案)
   * 
   * 注意：当蓝牙手柄连接时，某些按键可能只通过 KeyEvent 发送而不经过 GC Kit
   * 特别是 2313（Mode/Home）、2311（Select）、2312（Start）等
   * 这是因为 GC Kit 可能不支持所有手柄的所有按键
   */
  handleKeyEvent(deviceId: number, keyCode: number, isPressed: boolean): void {
    GamepadManager.DEBUG && console.info(`[GAMEPAD-KEY] handleKeyEvent: deviceId=${deviceId}, keyCode=${keyCode}, isPressed=${isPressed}`);
    
    const isSpecialKey = this.isSpecialKeyCode(keyCode);
    
    // 特殊处理 2313 按键（可自定义动作）- 无论是否使用 GC Kit 都处理
    if (keyCode === 2313 && isPressed && this.handleGCButton2313Action()) {
      return;  // 自定义动作已处理
    }
    
    // 如果 GC Kit 正在使用，只处理特殊按键（2311-2315）
    if (this.useGameControllerKit) {
      if (!isSpecialKey) {
        GamepadManager.DEBUG && console.info(`[GAMEPAD-KEY] GC Kit 活跃，跳过非特殊按键: ${keyCode}`);
        return;
      }
      // 路由特殊按键到 GC Kit 设备
      if (this.routeSpecialKeyToGCKit(keyCode, isPressed)) {
        return;
      }
    }
    
    // 以下是传统 InputKit 路径
    // 解析设备 ID - 特殊按键路由到已连接设备，普通按键可动态注册
    const resolvedDeviceId = this.resolveDeviceIdForKeyEvent(deviceId, keyCode, isSpecialKey);
    if (resolvedDeviceId === -1) return;
    
    const state = this.deviceStates.get(resolvedDeviceId);
    if (!state) {
      console.warn(`[GAMEPAD-KEY] 无法获取设备 ${resolvedDeviceId} 的状态`);
      return;
    }
    
    const buttonFlag = buttonMap.get(keyCode);
    if (buttonFlag !== undefined) {
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
      console.info(`[GAMEPAD-KEY] 动态注册设备 ${deviceId}`);
      this.listener?.onGamepadConnected(deviceId, `Controller ${deviceId}`);
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
        this.updateDpadHorizontal(state, value);
        break;
      case 18: // ABS_HAT0Y - D-Pad Y
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
    return controllerId;  // 回退：使用 controllerId
  }
  
  /**
   * 通知监听器状态变化
   */
  private notifyStateChange(deviceId: number, state: GamepadState): void {
    const slot = this.getControllerSlot(deviceId);
    this.listener?.onGamepadInput(slot, this.copyState(state));
  }

  /**
   * 获取已连接的手柄列表
   */
  getConnectedGamepads(): GamepadInfo[] {
    if (this.useGameControllerKit) {
      // Game Controller Kit 模式下从设备列表构建
      const devices = gameControllerService.getAllDevices();
      const result: GamepadInfo[] = [];
      for (const d of devices) {
        const info: GamepadInfo = {
          id: this.getSlotForGCDevice(d.deviceId),
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
   * 与 cleanup() 不同，此方法保留单例和设备连接，只重置会话相关状态
   * 防止重复进入串流时出现槽位分配错误或状态累积
   */
  resetSession(): void {
    console.info('[GAMEPAD] 重置会话状态');
    
    // 重置槽位管理状态
    this.slotOccupied = [false, false, false, false];
    this.deviceKeyToSlot.clear();
    this.gcDeviceIdToSlot.clear();
    this.controllerIdToDeviceKey.clear();
    this.usbDeviceKeyToId.clear();
    
    // 重置设备状态（但保留连接信息，以便重新设置监听器时可以重新通知）
    this.deviceStates.forEach((state, _deviceId) => {
      state.buttons = 0;
      state.leftStickX = 0;
      state.leftStickY = 0;
      state.rightStickX = 0;
      state.rightStickY = 0;
      state.leftTrigger = 0;
      state.rightTrigger = 0;
    });
    
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
    // 清理 Game Controller Kit
    if (this.useGameControllerKit) {
      gameControllerService.stopMonitor();
      gameControllerService.setDeviceCallback(null);
      gameControllerService.setButtonCallback(null);
      gameControllerService.setAxisCallback(null);
      gameControllerService.uninit();
      this.gcDeviceStates.clear();
      this.gcDeviceIdToSlot.clear();
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
    this.usbDevices.clear();
    this.deviceInfoMap.clear();
    this.usbDeviceKeyToId.clear();
    this.deviceKeyToSlot.clear();
    this.controllerIdToDeviceKey.clear();
    this.slotOccupied = [false, false, false, false];
    this.listener = null;
  }
  
  // ==================== UsbDriverListener 实现 ====================
  
  /**
   * USB 控制器状态报告
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
   * USB 控制器运动数据报告（陀螺仪/加速度计，暂未实现）
   */
  reportControllerMotion(
    _controllerId: number,
    _motionType: number,
    _x: number,
    _y: number,
    _z: number
  ): void {
    // TODO: 实现 IMU 数据处理
  }
  
  /**
   * USB 设备移除
   */
  deviceRemoved(controller: AbstractController): void {
    const controllerId = controller.getControllerId();
    const deviceKey = controller.getDeviceKey();
    console.info(`[GAMEPAD-USB] 设备移除: ID=${controllerId}, Key=${deviceKey}`);
    
    if (!this.connectedDevices.has(controllerId)) return;
    
    const slot = this.getControllerSlot(controllerId);
    
    // 清理所有相关状态
    this.connectedDevices.delete(controllerId);
    this.deviceStates.delete(controllerId);
    this.deviceInfoMap.delete(controllerId);
    this.usbDevices.delete(controllerId);
    this.usbDeviceKeyToId.delete(deviceKey);
    this.controllerIdToDeviceKey.delete(controllerId);
    this.releaseSlotForDevice(deviceKey);
    
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
    console.info(`[GAMEPAD-USB] 设备添加: ${name} (ID=${controllerId}, Slot=${slot})`);
    
    this.listener?.onGamepadConnected(slot, name);
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
      this.usbDevices.delete(existingControllerId);
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
    this.usbDevices.add(controllerId);
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
  async refreshUsbDevices(): Promise<void> {
    await this.usbDriverService.refreshDevices();
  }

  // ==================== 震动处理 ====================

  /**
   * 处理震动反馈
   */
  handleRumble(controllerNumber: number, lowFreqMotor: number, highFreqMotor: number): void {
    GamepadManager.DEBUG && console.info(`[GAMEPAD] 震动: ctrl=${controllerNumber}, low=${lowFreqMotor}, high=${highFreqMotor}`);

    const controllers = this.usbDriverService.getControllers();
    const hasUsbController = controllers.length > 0;
    
    switch (this.vibrationMode) {
      case '仅手柄':
        if (hasUsbController) {
          this.rumbleUsbControllers(controllers, controllerNumber, lowFreqMotor, highFreqMotor);
        }
        break;
        
      case '仅设备':
        this.triggerDeviceVibrate(lowFreqMotor, highFreqMotor);
        break;
        
      case '同时':
        if (hasUsbController) {
          this.rumbleUsbControllers(controllers, controllerNumber, lowFreqMotor, highFreqMotor);
        }
        this.triggerDeviceVibrate(lowFreqMotor, highFreqMotor);
        break;
        
      case '自动':
      default:
        if (hasUsbController) {
          this.rumbleUsbControllers(controllers, controllerNumber, lowFreqMotor, highFreqMotor);
        } else {
          this.triggerDeviceVibrate(lowFreqMotor, highFreqMotor);
        }
        break;
    }
  }

  /**
   * 根据槽位号查找控制器（带多级后备）
   */
  private findControllerBySlot(controllers: AbstractController[], slotNumber: number): AbstractController | null {
    if (controllers.length === 0) return null;
    
    // 优先：槽位精确匹配
    for (const controller of controllers) {
      if (this.deviceKeyToSlot.get(controller.getDeviceKey()) === slotNumber) {
        return controller;
      }
    }
    
    // 后备：使用索引或第一个
    if (controllers.length === 1) return controllers[0];
    if (slotNumber < controllers.length) return controllers[slotNumber];
    return controllers[0];
  }
  
  /**
   * 向 USB 控制器发送震动
   */
  private rumbleUsbControllers(controllers: AbstractController[], controllerNumber: number, lowFreqMotor: number, highFreqMotor: number): void {
    const controller = this.findControllerBySlot(controllers, controllerNumber);
    controller?.rumble(lowFreqMotor, highFreqMotor);
  }

  /**
   * 处理扳机震动
   */
  handleRumbleTriggers(controllerNumber: number, leftTrigger: number, rightTrigger: number): void {
    GamepadManager.DEBUG && console.info(`[GAMEPAD] 扳机震动: ctrl=${controllerNumber}, L=${leftTrigger}, R=${rightTrigger}`);

    const controllers = this.usbDriverService.getControllers();
    const controller = this.findControllerBySlot(controllers, controllerNumber);
    controller?.rumbleTriggers(leftTrigger, rightTrigger);
  }
  
  // 高清振动支持缓存
  private hdHapticSupported: boolean | null = null;
  // 上次震动参数缓存（用于检测变化）
  private lastLowFreq: number = 0;
  private lastHighFreq: number = 0;
  // 震动活跃标志
  private isVibrating: boolean = false;
  
  /**
   * 触发设备震动（后备方案）
   * 
   * 关键改进：
   * 1. 使用 continuous 长振（而非 transient 瞬态）实现持续震动
   * 2. 强度变化时立即停止旧震动再启动新震动
   * 3. 使用 stopVibrationSync 同步停止确保即时性
   */
  private triggerDeviceVibrate(lowFreqMotor: number, highFreqMotor: number): void {
    if (!this.deviceVibrateEnabled) return;
    
    // 停止震动
    if (lowFreqMotor === 0 && highFreqMotor === 0) {
      if (this.isVibrating) {
        this.stopVibrationImmediate();
        this.lastLowFreq = 0;
        this.lastHighFreq = 0;
      }
      return;
    }
    
    // 检查是否需要更新震动（强度变化超过阈值才更新，避免过于频繁）
    const lowDelta = Math.abs(lowFreqMotor - this.lastLowFreq);
    const highDelta = Math.abs(highFreqMotor - this.lastHighFreq);
    const threshold = 3000;  // 约 5% 的变化阈值
    
    if (this.isVibrating && lowDelta < threshold && highDelta < threshold) {
      return;  // 变化太小，不更新
    }
    
    this.lastLowFreq = lowFreqMotor;
    this.lastHighFreq = highFreqMotor;
    
    // 计算用户强度系数
    const userStrength = this.deviceVibrateStrength / 100;
    
    // 计算低频和高频马达的强度 (0-100)
    const lowIntensity = Math.floor((lowFreqMotor / 65535) * userStrength * 100);
    const highIntensity = Math.floor((highFreqMotor / 65535) * userStrength * 100);
    
    // 检查是否支持高清振动（首次检查后缓存）
    if (this.hdHapticSupported === null) {
      try {
        this.hdHapticSupported = vibrator.isHdHapticSupported();
        console.info(`[GAMEPAD] 高清振动支持: ${this.hdHapticSupported}`);
      } catch (_) {
        this.hdHapticSupported = false;
      }
    }
    
    // 先停止当前震动（确保即时切换）
    if (this.isVibrating) {
      this.stopVibrationImmediate();
    }
    
    try {
      if (this.hdHapticSupported) {
        // 使用持续震动模式
        this.triggerContinuousVibration(lowIntensity, highIntensity);
      } else {
        // 不支持高清振动，使用时长模式
        this.triggerTimeVibration(lowIntensity, highIntensity);
      }
      this.isVibrating = true;
    } catch (err) {
      console.warn(`[GAMEPAD] 设备震动异常: ${err}`);
      this.fallbackTimeVibration(Math.max(lowIntensity, highIntensity));
    }
  }
  
  /**
   * 立即停止震动（同步方式）
   */
  private stopVibrationImmediate(): void {
    try {
      // 优先使用同步停止 API (API 12+)
      vibrator.stopVibrationSync();
    } catch (_) {
      // 回退到异步停止
      try {
        vibrator.stopVibration();
      } catch (_) { /* ignore */ }
    }
    this.isVibrating = false;
  }
  
  /**
   * 使用 continuous 长振实现持续震动 (API 18+)
   * 
   * 关键：使用较长的 duration 让震动持续，
   * 当游戏发送新的震动命令时会被停止并替换
   */
  private triggerContinuousVibration(lowIntensity: number, highIntensity: number): void {
    try {
      const builder = new vibrator.VibratorPatternBuilder();
      
      // 计算混合强度
      const combinedIntensity = Math.min(100, Math.max(lowIntensity, highIntensity));
      if (combinedIntensity < 5) return;  // 强度太低不震动
      
      // 根据低频/高频比例计算频率
      let frequency: number;
      if (lowIntensity > 0 && highIntensity > 0) {
        const ratio = highIntensity / (lowIntensity + highIntensity);
        frequency = Math.floor(30 + ratio * 50);  // 30-80
      } else if (lowIntensity > 0) {
        frequency = 35;  // 低频：沉闷
      } else {
        frequency = 70;  // 高频：尖锐
      }
      
      // 使用 continuous 长振事件，持续 500ms
      // 游戏通常每 50-100ms 发送一次震动命令，所以会被持续刷新
      builder.addContinuousEvent(0, 500, {
        intensity: combinedIntensity,
        frequency: frequency,
        index: 0
      });
      
      vibrator.startVibration({
        type: 'pattern',
        pattern: builder.build()
      }, {
        id: 0,
        usage: 'physicalFeedback'
      }).catch((err: Error) => {
        this.triggerTimeVibration(lowIntensity, highIntensity);
      });
    } catch (err) {
      this.triggerTimeVibration(lowIntensity, highIntensity);
    }
  }
  
  /**
   * 使用时长模式实现持续震动
   */
  private triggerTimeVibration(lowIntensity: number, highIntensity: number): void {
    const combinedIntensity = Math.max(lowIntensity, highIntensity);
    if (combinedIntensity < 5) return;
    
    // 持续 500ms 的震动，会被后续命令刷新
    vibrator.startVibration({
      type: 'time',
      duration: 500
    }, {
      id: 0,
      usage: 'physicalFeedback'
    }).catch((err: Error) => {
      console.warn(`[GAMEPAD] 时长震动失败: ${err.message}`);
    });
  }
  
  /**
   * 回退的简单时长模式震动
   */
  private fallbackTimeVibration(intensity: number): void {
    if (intensity < 5) return;
    const duration = Math.floor(50 + intensity * 4.5);  // 50-500ms
    
    vibrator.startVibration({ type: 'time', duration }, { id: 0, usage: 'physicalFeedback' })
      .catch((err: Error) => console.warn(`[GAMEPAD] 设备震动失败: ${err.message}`));
    this.isVibrating = true;
  }
}
