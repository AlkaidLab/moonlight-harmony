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
 * 串流页面
 * 
 * 显示远程游戏画面并处理用户输入
 */
import { router, promptAction } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { VirtualControllerV2, VirtualControllerConfig } from '../components/VirtualControllerV2';
import { PerformanceOverlay } from '../components/PerformanceOverlay';
import { OptionPickerDialog, OptionPickerDialogConfig } from '../components/OptionPickerDialog';
import { GameMenuDialog, GameMenuCallbacks } from '../components/GameMenuDialog';
import { StreamMenuManager } from '../components/StreamMenuManager';
import { StreamViewModel, StreamConnectionState, TouchMode } from '../viewmodel/StreamViewModel';
import { TouchInputHandler, TouchInputMode } from '../service/TouchInputHandler';
import { StreamWindowManager } from '../service/StreamWindowManager';
import { ShortcutManager, Shortcut } from '../components/ShortcutManager';
import { ShortcutEditorDialog, ShortcutEditorCallbacks, ShortcutEditData } from '../components/ShortcutEditorDialog';
import { GamepadManager, GamepadInputListener, GamepadState, MoonlightControllerType, MouseEmulationCallback } from '../service/GamepadManager';
import { GyroAssistService } from '../service/GyroAssistService';
import { AppStateService, AppState } from '../service/AppStateService';
import { MoonBridge, BUTTON_ACTION_PRESS, BUTTON_ACTION_RELEASE, BUTTON_LEFT, BUTTON_RIGHT } from '../service/MoonBridge';
import { SuperCmd } from '../service/NvHttp';
import { AbsoluteMouseManager } from '../service/LocalCursorManager';
import { VirtualKey } from '../components/StreamMenuManager';
import { InputInterceptorService } from '../service/InputInterceptorService';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { SettingsKeys } from '../service/SettingsService';
import { inputMethod } from '@kit.IMEKit';
import { window } from '@kit.ArkUI';

/** MouseEmulationCallback 的具体实现，桥接 MoonBridge 鼠标 API */
class MoonBridgeMouseCallback implements MouseEmulationCallback {
  sendMouseMove(deltaX: number, deltaY: number): void {
    MoonBridge.sendMouseMove(deltaX, deltaY);
  }
  sendMouseButtonDown(button: number): void {
    MoonBridge.sendMouseButton(BUTTON_ACTION_PRESS, button);
  }
  sendMouseButtonUp(button: number): void {
    MoonBridge.sendMouseButton(BUTTON_ACTION_RELEASE, button);
  }
  sendMouseHighResScroll(scrollAmount: number): void {
    MoonBridge.sendMouseHighResScroll(scrollAmount);
  }
  sendMouseHighResHScroll(scrollAmount: number): void {
    MoonBridge.sendMouseHighResHScroll(scrollAmount);
  }
}

interface StreamPageParams {
  computerId: string;
  appId: number;
  appName?: string;
  cmdList?: string;       // JSON 字符串格式的超级指令列表
  displayGuid?: string;   // 指定的显示器 GUID
  useVdd?: boolean;       // 是否使用虚拟显示器
}

@Entry
@Component
struct StreamPage {
  // ViewModel
  @State viewModel: StreamViewModel = new StreamViewModel();
  
  // UI 状态
  @State xComponentWidth: Length = '100%';
  @State xComponentHeight: Length = '100%';
  @State showKeyboardPanel: boolean = false;  // 系统键盘输入面板
  @State keyboardHeight: number = 0;  // IME 键盘高度 (vp)
  private imeController: inputMethod.InputMethodController | null = null;  // 输入法控制器
  
  // 绝对鼠标管理器
  private absoluteMouseManager: AbsoluteMouseManager | null = null;
  
  // 对话框控制器
  private gameMenuDialogController: CustomDialogController | null = null;
  private shortcutEditorController: CustomDialogController | null = null;
  private optionPickerDialogController: CustomDialogController | null = null;
  private optionPickerDialogConfig: OptionPickerDialogConfig = {
    title: '',
    options: [],
    onSelect: () => {}
  };
  
  // 组件控制器和服务
  private xComponentController: XComponentController = new XComponentController();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private touchInputHandler: TouchInputHandler = new TouchInputHandler();
  private windowManager: StreamWindowManager | null = null;
  private menuManager: StreamMenuManager | null = null;
  private shortcutManager: ShortcutManager = ShortcutManager.getInstance();
  private gamepadManager: GamepadManager = GamepadManager.getInstance();
  private controllerTypes: Map<number, number> = new Map();  // slot → MoonlightControllerType
  private latencyToastEnabled: boolean = false;  // 串流后延迟提示
  private appStateService: AppStateService = AppStateService.getInstance();
  
  // 应用音频音量回退（当 C++ 层无法回注音量键到系统时，用 OH_AudioRenderer 应用级音量补偿）
  private appVolume: number = 1.0;      // 当前音量 0.0 ~ 1.0
  private preMuteVolume: number = 1.0;  // 静音前的音量（用于恢复）
  private static readonly VOLUME_STEP: number = 0.1;   // 每次调节步长 10%
  
  // 应用状态相关
  private appStateListener: ((state: AppState) => void) | null = null;
  private wasInBackground: boolean = false;
  
  // 屏幕方向变化监听相关
  private displayChangeCallback: ((displayId: number) => void) | null = null;
  private lastDisplayOrientation: boolean | null = null;  // null=未初始化, true=横屏, false=竖屏
  
  // 页面参数
  private computerId: string = '';
  private appId: number = 0;
  private displayGuid: string = '';
  private useVdd: boolean = false;
  private cmdList: SuperCmd[] = [];  // 超级指令列表
  
  aboutToAppear(): void {
    const params = router.getParams() as StreamPageParams;
    if (params) {
      this.computerId = params.computerId;
      this.appId = params.appId;
      this.displayGuid = params.displayGuid || '';
      this.useVdd = params.useVdd || false;
      // 解析超级指令列表
      if (params.cmdList) {
        try {
          this.cmdList = JSON.parse(params.cmdList) as SuperCmd[];
        } catch {
          this.cmdList = [];
        }
      }
    }
    
    // 初始化窗口管理器
    this.windowManager = new StreamWindowManager(this.context);
    
    // 初始化快捷键管理器
    this.shortcutManager.initialize(this.context);
    
    // 初始化菜单管理器
    this.menuManager = new StreamMenuManager(this.viewModel, {
      onResume: () => {
        // 继续游戏 - 不做任何事情
      },
      onDisconnect: () => {
        this.stopStreaming();
      },
      onQuitGame: () => {
        this.quitGameAndReturn();
      },
      onTouchModeChanged: (mode: string) => {
        this.setTouchMode(mode);
      },
      onShowTouchModeMenu: () => {
        setTimeout(() => {
          this.showTouchModeMenu();
        }, 100);
      }
    });
    
    // 初始化手柄管理器
    this.initializeGamepad();
    
    // 获取屏幕尺寸
    this.initializeDisplay();
    
    // 注册应用状态监听
    this.registerAppStateListener();
    
    // 注册屏幕方向变化监听
    this.registerDisplayChangeListener();
  }
    /**
   * 初始化手柄输入
   */
  private initializeGamepad(): void {
    this.gamepadManager.setListener({
      onGamepadConnected: (deviceId: number, name: string, controllerType: number) => {
        console.info(`手柄已连接: ${name} (ID: ${deviceId}, Type: ${controllerType})`);
        this.controllerTypes.set(deviceId, controllerType);
        promptAction.showToast({ message: `手柄已连接: ${name}` });
      },
      onGamepadDisconnected: (deviceId: number) => {
        console.info(`手柄已断开: ID ${deviceId}`);
        this.controllerTypes.delete(deviceId);
        promptAction.showToast({ message: '手柄已断开' });
      },
      onGamepadInput: (deviceId: number, state: GamepadState) => {
        this.handleGamepadInput(deviceId, state);
      }
    });

    // 设置鼠标模拟回调 — 手柄摇杆→鼠标移动/按键→鼠标按键
    this.gamepadManager.setMouseEmulationCallback(new MoonBridgeMouseCallback());

    // 设置长按 Start 显示菜单的回调
    this.gamepadManager.setShowGameMenuCallback(() => {
      this.showStreamMenu();
    });
  }
  
  /**
   * 初始化体感助手
   * 从设置加载配置，如果已启用则自动开始监听陀螺仪
   */
  private initializeGyroAssist(): void {
    const settings = this.viewModel.inputSettings;
    if (!settings) return;

    const gyroAssist = GyroAssistService.getInstance();
    gyroAssist.loadSettings({
      sensitivity: settings.gyroSensitivity,
      invertX: settings.gyroInvertX,
      invertY: settings.gyroInvertY,
      activationKey: settings.gyroActivationKey
    });

    // 设置即时发送回调（对齐 Android 的 updateContextWithGyroData → sendControllerInputPacket）
    // 陀螺仪每次数据更新（120Hz）都会通过此回调立即发送融合后的手柄状态
    gyroAssist.setSendCallback((
      deviceId: number,
      buttons: number,
      leftStickX: number,
      leftStickY: number,
      rightStickX: number,
      rightStickY: number,
      leftTrigger: number,
      rightTrigger: number,
      controllerType: number
    ) => {
      if (this.viewModel.isConnected) {
        this.viewModel.sendGamepadState(
          deviceId, buttons, leftStickX, leftStickY,
          rightStickX, rightStickY,
          leftTrigger, rightTrigger, controllerType
        );
      }
    });

    if (settings.gyroAssistEnabled) {
      gyroAssist.setEnabled(true);
    }
  }
  
  /**
   * 处理手柄输入
   */
  private handleGamepadInput(deviceId: number, state: GamepadState): void {
    if (!this.viewModel.isConnected) {
      return;
    }
    
    // 获取控制器类型（默认 Xbox）
    const controllerType = this.controllerTypes.get(deviceId) ?? MoonlightControllerType.XBOX;
    
    // 体感助手：更新激活状态并融合右摇杆
    const gyroAssist = GyroAssistService.getInstance();
    let rsX = state.rightStickX;
    let rsY = state.rightStickY;
    if (gyroAssist.enabled) {
      gyroAssist.updateActivation(state.leftTrigger, state.rightTrigger);
      // 更新存储的手柄状态，供陀螺仪即时发送使用
      gyroAssist.updateGamepadState(
        deviceId,
        state.buttons,
        state.leftStickX,
        state.leftStickY,
        state.rightStickX,
        state.rightStickY,
        state.leftTrigger,
        state.rightTrigger,
        controllerType
      );
      const fused = gyroAssist.fuseRightStick(state.rightStickX, state.rightStickY);
      rsX = fused.x;
      rsY = fused.y;
    }
    
    // 直接发送完整的手柄状态
    this.viewModel.sendGamepadState(
      deviceId,
      state.buttons,
      state.leftStickX,
      state.leftStickY,
      rsX,
      rsY,
      state.leftTrigger,
      state.rightTrigger,
      controllerType
    );
  }
  
  private async initializeDisplay(): Promise<void> {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      const screenWidth = displayInfo.width / displayInfo.densityPixels;
      const screenHeight = displayInfo.height / displayInfo.densityPixels;
      
      // 更新 ViewModel 显示信息
      this.viewModel.displayInfo.screenWidth = screenWidth;
      this.viewModel.displayInfo.screenHeight = screenHeight;
      
      // 配置窗口
      await this.windowManager?.configureWindow();
    } catch (err) {
      console.error('初始化显示失败:', err);
    }
  }
  
  aboutToDisappear(): void {
    console.info('StreamPage aboutToDisappear - cleaning up');
    
    // 取消应用状态监听
    this.unregisterAppStateListener();
    
    // 取消屏幕方向变化监听
    this.unregisterDisplayChangeListener();
    
    // 清理 ViewModel
    this.viewModel.dispose();
    
    // 清理触摸处理器
    this.touchInputHandler.dispose();
    
    // 停止按键拦截器
    InputInterceptorService.getInstance().stop();
    
    // 停止体感助手
    GyroAssistService.getInstance().dispose();
    
    // 清理手柄监听并重置会话状态（防止内存泄漏和重复绑定）
    this.gamepadManager.setListener(null);
    this.gamepadManager.resetSession();
    
    // 恢复窗口设置
    this.hideIMEKeyboard();
    this.windowManager?.restoreWindow();
  }
  
  /**
   * 注册应用前后台状态监听
   */
  private registerAppStateListener(): void {
    this.appStateListener = (state: AppState) => {
      if (state === AppState.BACKGROUND) {
        console.info('[StreamPage] 应用进入后台');
        this.wasInBackground = true;
      } else if (state === AppState.FOREGROUND && this.wasInBackground) {
        console.info('[StreamPage] 应用从后台恢复');
        this.wasInBackground = false;
        this.handleAppResume();
      }
    };
    this.appStateService.addListener(this.appStateListener);
  }
  
  /**
   * 取消应用状态监听
   */
  private unregisterAppStateListener(): void {
    if (this.appStateListener) {
      this.appStateService.removeListener(this.appStateListener);
      this.appStateListener = null;
    }
  }
  
  /**
   * 注册屏幕方向变化监听
   * 使用 display.on('change') 监听屏幕变化
   */
  private registerDisplayChangeListener(): void {
    try {
      this.displayChangeCallback = (displayId: number): void => {
        this.handleDisplayChange(displayId);
      };
      display.on('change', this.displayChangeCallback);
      console.info('[StreamPage] 已注册屏幕方向变化监听');
    } catch (err) {
      console.warn('[StreamPage] 注册屏幕方向监听失败:', err);
    }
  }
  
  /**
   * 取消屏幕方向变化监听
   */
  private unregisterDisplayChangeListener(): void {
    if (this.displayChangeCallback) {
      try {
        display.off('change', this.displayChangeCallback);
        console.info('[StreamPage] 已取消屏幕方向变化监听');
      } catch (err) {
        console.warn('[StreamPage] 取消屏幕方向监听失败:', err);
      }
      this.displayChangeCallback = null;
    }
  }
  
  /**
   * 处理屏幕变化事件
   * @param displayId 发生变化的显示器 ID
   */
  private handleDisplayChange(displayId: number): void {
    // 只处理连接状态
    if (!this.viewModel.isConnected) {
      return;
    }
    
    try {
      const displayInfo = display.getDefaultDisplaySync();
      const isLandscape = displayInfo.width > displayInfo.height;
      
      // 只有方向真正变化时才处理
      if (this.lastDisplayOrientation !== null && this.lastDisplayOrientation === isLandscape) {
        return;
      }
      
      console.info(`[StreamPage] 屏幕方向变化: ${isLandscape ? '横屏' : '竖屏'}, displayId=${displayId}`);
      this.lastDisplayOrientation = isLandscape;
      
      // 通知 ViewModel 处理旋转
      this.viewModel.handleRotationChange(isLandscape);
      
      // 更新屏幕尺寸
      this.updateScreenSizeAfterRotation();
    } catch (err) {
      console.warn('[StreamPage] 处理屏幕变化失败:', err);
    }
  }
  
  /**
   * 屏幕旋转后更新尺寸
   */
  private async updateScreenSizeAfterRotation(): Promise<void> {
    try {
      const screenSize = await this.windowManager?.updateScreenSize();
      if (screenSize) {
        this.viewModel.displayInfo.screenWidth = screenSize.width;
        this.viewModel.displayInfo.screenHeight = screenSize.height;
        
        // 重新计算 XComponent 尺寸
        const xComponentSize = this.windowManager?.calculateXComponentSize(this.viewModel.displayInfo.stretchVideo);
        if (xComponentSize) {
          this.xComponentWidth = xComponentSize.width;
          this.xComponentHeight = xComponentSize.height;
        }
      }
    } catch (err) {
      console.warn('[StreamPage] 更新屏幕尺寸失败:', err);
    }
  }
  
  /**
   * 处理服务端分辨率变化（屏幕旋转/分辨率改变）
   * 更新窗口管理器的串流分辨率并重新计算 XComponent 尺寸
   */
  private async handleServerResolutionChanged(width: number, height: number): Promise<void> {
    console.info(`[StreamPage] 服务端分辨率变化: ${width}x${height}`);
    
    // 更新窗口管理器的串流分辨率
    this.windowManager?.setStreamResolution(width, height);
    
    // 重新配置窗口方向（可能会触发屏幕旋转）
    await this.windowManager?.configureOrientation();
    
    // 更新屏幕尺寸（等待旋转完成后获取正确的屏幕尺寸）
    const screenSize = await this.windowManager?.updateScreenSize();
    if (screenSize) {
      this.viewModel.displayInfo.screenWidth = screenSize.width;
      this.viewModel.displayInfo.screenHeight = screenSize.height;
    }
    
    // 重新计算 XComponent 尺寸以避免画面拉伸
    const xComponentSize = this.windowManager?.calculateXComponentSize(this.viewModel.displayInfo.stretchVideo);
    if (xComponentSize) {
      this.xComponentWidth = xComponentSize.width;
      this.xComponentHeight = xComponentSize.height;
      console.info(`[StreamPage] XComponent 尺寸更新: ${JSON.stringify(xComponentSize)}`);
    }
  }
  
  /**
   * 处理应用从后台恢复
   * 当应用从后台切回前台时，需要检查串流状态并尝试恢复
   */
  private handleAppResume(): void {
    console.info(`[StreamPage] 处理应用恢复, 连接状态: ${this.viewModel.connectionState}`);
    
    // 如果当前已连接，尝试恢复串流
    if (this.viewModel.isConnected) {
      console.info('[StreamPage] 尝试恢复串流...');
      // 调用 ViewModel 的恢复方法
      this.viewModel.resumeFromBackground();
    }
  }
  
  /**
   * 处理返回按键 - 显示串流菜单而不是直接返回
   * @returns true 表示已处理返回事件，阻止默认行为
   */
  onBackPress(): boolean {
    // 如果正在连接中，允许直接返回
    if (this.viewModel.isConnecting) {
      return false;
    }
    
    // 已连接时，显示串流菜单
    if (this.viewModel.isConnected) {
      this.showStreamMenu();
      return true;  // 阻止默认返回行为
    }
    
    // 其他情况允许返回
    return false;
  }
  
  /**
   * 显示串流菜单
   */
  showStreamMenu(): void {
    if (!this.menuManager) return;
    
    this.optionPickerDialogConfig = this.menuManager.getStreamMenuConfig();
    // 使用新的游戏菜单对话框
    this.gameMenuDialogController = new CustomDialogController({
      builder: GameMenuDialog({
        viewModel: this.viewModel,
        superCmds: this.cmdList,  // 传递超级指令列表
        isUsbDriverMode: !this.gamepadManager.isUsingGameControllerKit(),
        isMouseEmulationActive: this.gamepadManager.isMouseEmulationActive(),
        isMouseEmulationEnabled: this.gamepadManager.isMouseEmulationEnabled(),
        callbacks: {
          onDismiss: () => {},
          onDisconnect: () => {
            this.stopStreaming();
          },
          onQuitGame: () => {
            this.quitGameAndReturn();
          },
          onTouchModeChanged: (mode: string) => {
            this.setTouchMode(mode);
          },
          onOpenShortcutEditor: () => {
            // 关闭游戏菜单后打开快捷键编辑器
            this.gameMenuDialogController?.close();
            setTimeout(() => {
              this.showShortcutEditor();
            }, 300);
          },
          onEditShortcut: (shortcut) => {
            // 关闭游戏菜单后打开快捷键编辑器（编辑模式）
            this.gameMenuDialogController?.close();
            setTimeout(() => {
              this.showShortcutEditor(shortcut);
            }, 300);
          },
          onDeleteShortcut: async (shortcut) => {
            // 删除快捷键
            const success = await this.shortcutManager.deleteShortcut(shortcut.id);
            if (success) {
              promptAction.showToast({ message: `快捷键 "${shortcut.name}" 已删除` });
            }
          },
          onSendSuperCmd: (cmdId: string) => {
            this.sendSuperCmd(cmdId);
          },
          onForceUsbDriver: () => {
            this.forceUsbDriverMode();
          },
          onToggleKeyboard: () => {
            this.showIMEKeyboard();
          },
          onToggleMouseEmulation: () => {
            this.gamepadManager.toggleMouseEmulation();
            const active = this.gamepadManager.isMouseEmulationActive();
            promptAction.showToast({
              message: active ? '手柄鼠标模拟已开启' : '手柄鼠标模拟已关闭',
              duration: 2000
            });
          },
          onClose: () => {
            this.gameMenuDialogController?.close();
          }
        }
      }),
      alignment: DialogAlignment.CenterEnd,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.gameMenuDialogController.open();
  }
  
  /**
   * 显示快捷键编辑器
   * @param editingShortcut 如果传入，则为编辑模式
   */
  showShortcutEditor(editingShortcut?: Shortcut): void {
    this.shortcutEditorController = new CustomDialogController({
      builder: ShortcutEditorDialog({
        editingShortcut: editingShortcut,
        callbacks: {
          onSave: async (data: ShortcutEditData) => {
            if (editingShortcut) {
              // 编辑模式
              await this.shortcutManager.updateShortcut(
                editingShortcut.id,
                data.name,
                data.keys,
                data.icon,
                data.color
              );
              promptAction.showToast({ message: `快捷键 "${data.name}" 已更新` });
            } else {
              // 添加模式
              await this.shortcutManager.addShortcut(data.name, data.keys, data.icon, data.color);
              promptAction.showToast({ message: `快捷键 "${data.name}" 已添加` });
            }
          },
          onCancel: () => {}
        }
      }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.shortcutEditorController.open();
  }
  
  /**
   * 显示触摸模式菜单 (保留用于其他地方调用)
   */
  showTouchModeMenu(): void {
    if (!this.menuManager) return;
    
    this.optionPickerDialogConfig = this.menuManager.getTouchModeMenuConfig();
    this.optionPickerDialogController = new CustomDialogController({
      builder: OptionPickerDialog({
        config: this.optionPickerDialogConfig
      }),
      alignment: DialogAlignment.Bottom,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.optionPickerDialogController.open();
  }
  
  async startStreaming(): Promise<void> {
    try {
      // 加载设置
      await this.viewModel.loadSettings();
      this.latencyToastEnabled = await PreferencesUtil.get<boolean>(SettingsKeys.LATENCY_TOAST, false);
      await this.gamepadManager.reloadSettings();
      
      // 设置串流分辨率
      this.windowManager?.setStreamResolution(
        this.viewModel.displayInfo.streamWidth,
        this.viewModel.displayInfo.streamHeight
      );
      
      // 配置屏幕方向
      await this.windowManager?.configureOrientation();
      
      // 更新屏幕尺寸
      const screenSize = await this.windowManager?.updateScreenSize();
      if (screenSize) {
        this.viewModel.displayInfo.screenWidth = screenSize.width;
        this.viewModel.displayInfo.screenHeight = screenSize.height;
      }
      
      // 计算 XComponent 尺寸
      const xComponentSize = this.windowManager?.calculateXComponentSize(this.viewModel.displayInfo.stretchVideo);
      if (xComponentSize) {
        this.xComponentWidth = xComponentSize.width;
        this.xComponentHeight = xComponentSize.height;
      }
      
      // 设置触摸输入模式
      const touchModeStr = this.viewModel.touchMode as string;
      this.touchInputHandler.setMode(touchModeStr as TouchInputMode);
      
      // 初始化绝对鼠标模式
      this.initializeAbsoluteMouseMode();
      
      // 设置连接终止回调
      this.viewModel.setConnectionTerminatedCallback((errorCode: number) => {
        this.handleConnectionTerminated(errorCode);
      });

      // 设置分辨率变化回调（服务端屏幕旋转/分辨率变化时同步客户端布局）
      this.viewModel.setResolutionChangedCallback((width: number, height: number) => {
        this.handleServerResolutionChanged(width, height);
      });

      // 获取 surfaceId 并开始串流
      const surfaceId = this.xComponentController.getXComponentSurfaceId();
      await this.viewModel.startStreaming(this.computerId, this.appId, surfaceId, this.context, this.displayGuid, this.useVdd);

      // 启动按键拦截器（拦截被系统劫持的手柄按键，如蓝牙手柄 Home 键）
      if (this.viewModel.inputSettings?.enableKeyInterceptor) {
        this.startKeyInterceptor();
      }

      // 初始化体感助手
      this.initializeGyroAssist();

      // 绝对鼠标模式下自动隐藏远端光标
      // 发送 Ctrl+Alt+Shift+N 切换 Sunshine display_cursor
      if (this.viewModel.absoluteMouseMode) {
        setTimeout(() => {
          const session = this.viewModel.getSession();
          session?.sendKeys([VirtualKey.VK_CONTROL, VirtualKey.VK_MENU, VirtualKey.VK_SHIFT, VirtualKey.VK_N]);
          console.info('StreamPage: 绝对鼠标模式 - 已发送隐藏远端光标指令');
        }, 500); // 延迟 500ms 确保连接稳定
      }
      
    } catch (err) {
      console.error('开始串流失败:', err);
    }
  }
  
  async stopStreaming(): Promise<void> {
    // 显示延迟统计 toast（在停止串流之前获取数据）
    this.showLatencyToastIfEnabled();
    
    // 先恢复窗口设置并返回菜单（立即响应）
    await this.windowManager?.restoreWindow();
    router.back();
    
    // 后台停止串流
    this.viewModel.stopStreaming();
  }
  
  /**
   * 使用 InputMethod API 直接显示系统键盘（无需 TextInput 组件）
   * 节省屏幕空间，串流画面完整可见
   */
  private async showIMEKeyboard(): Promise<void> {
    const session = this.viewModel.getSession();
    if (!session) return;

    try {
      // 监听键盘高度变化
      const win = await window.getLastWindow(getContext(this));
      win.on('keyboardHeightChange', (height: number) => {
        this.keyboardHeight = px2vp(height);
      });

      const controller = inputMethod.getController();
      this.imeController = controller;

      // 先绑定输入法（必须先 attach 才能注册回调）
      const textConfig: inputMethod.TextConfig = {
        inputAttribute: {
          textInputType: inputMethod.TextInputType.TEXT,
          enterKeyType: inputMethod.EnterKeyType.SEND
        }
      };
      await controller.attach(true, textConfig);

      // attach 成功后注册输入回调
      controller.on('insertText', (text: string) => {
        session.sendUtf8Text(text);
      });

      controller.on('deleteLeft', (length: number) => {
        for (let i = 0; i < length; i++) {
          session.sendKeyboardInput(0x08, 0x03); // VK_BACK DOWN
          session.sendKeyboardInput(0x08, 0x04); // VK_BACK UP
        }
      });

      controller.on('sendFunctionKey', (key: inputMethod.FunctionKey) => {
        // 回车键
        session.sendKeyboardInput(0x0D, 0x03); // VK_RETURN DOWN
        session.sendKeyboardInput(0x0D, 0x04); // VK_RETURN UP
      });

      controller.on('sendKeyboardStatus', (status: inputMethod.KeyboardStatus) => {
        if (status === inputMethod.KeyboardStatus.HIDE) {
          this.hideIMEKeyboard();
        }
      });

      this.showKeyboardPanel = true;
    } catch (err) {
      console.error(`[StreamPage] Failed to show IME: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 关闭系统键盘并清理回调
   */
  private hideIMEKeyboard(): void {
    try {
      if (this.imeController) {
        this.imeController.off('insertText');
        this.imeController.off('deleteLeft');
        this.imeController.off('sendFunctionKey');
        this.imeController.off('sendKeyboardStatus');
        this.imeController.detach();
        this.imeController = null;
      }
      // 取消键盘高度监听
      window.getLastWindow(getContext(this)).then((win) => {
        win.off('keyboardHeightChange');
      });
    } catch (err) {
      console.error(`[StreamPage] Failed to hide IME: ${JSON.stringify(err)}`);
    }
    this.showKeyboardPanel = false;
    this.keyboardHeight = 0;
  }

  /**
   * 串流结束后显示延迟统计 Toast
   * 对齐 Android: Game.connectionTerminated() 中 enableLatencyToast 逻辑
   */
  private showLatencyToastIfEnabled(): void {
    console.info(`[StreamPage] showLatencyToast: enabled=${this.latencyToastEnabled}`);
    if (!this.latencyToastEnabled) {
      return;
    }
    
    // 使用 getSummaryStats 获取有效数据（断连后 native 数据可能已清零）
    const session = this.viewModel.getSession();
    const stats = session ? session.getSummaryStats() : this.viewModel.performanceStats;
    console.info(`[StreamPage] stats: net=${stats.networkLatency}, decode=${stats.latency}, host=${stats.hostLatency}, fps=${stats.renderedFps}`);
    const parts: string[] = [];
    
    // 网络延迟 (RTT)
    if (stats.networkLatency > 0) {
      parts.push(`网络: ${stats.networkLatency}ms`);
    }
    // 解码延迟 - 使用全局累计平均值（真实平均，非 EMA）
    const decodeLatency = stats.globalAvgDecodeLatency > 0 ? stats.globalAvgDecodeLatency : stats.latency;
    if (decodeLatency > 0) {
      parts.push(`解码: ${decodeLatency.toFixed(1)}ms`);
    }
    // 主机延迟 - 使用全局累计平均值
    const hostLatency = stats.globalAvgHostLatency > 0 ? stats.globalAvgHostLatency : stats.hostLatency;
    if (hostLatency > 0) {
      parts.push(`主机: ${hostLatency.toFixed(1)}ms`);
    }
    // 帧率 - 使用全局平均帧率（真实平均，非瞬时窗口值）
    const avgFps = stats.globalAvgFps > 0 ? Math.round(stats.globalAvgFps) : stats.renderedFps;
    if (avgFps > 0) {
      parts.push(`帧率: ${avgFps}fps`);
    }
    
    const message = parts.length > 0 ? parts.join(' | ') : '串流已结束';
    promptAction.showToast({
      message: message,
      duration: 3500
    });
  }
  
  /**
   * 处理服务器断开连接
   * errorCode: 0 = 正常关闭（如用户在服务器端退出游戏）
   *           -100 = 无视频流量（端口问题）
   *           -101 = 无完整帧（网络不稳定）
   *           -102 = 意外提前终止
   *           -103 = 受保护内容
   *           -104 = 帧转换错误
   */
  private handleConnectionTerminated(errorCode: number): void {
    console.info(`StreamPage: 连接终止, errorCode=${errorCode}`);
    
    const ML_ERROR_GRACEFUL_TERMINATION = 0;
    const ML_ERROR_NO_VIDEO_TRAFFIC = -100;
    const ML_ERROR_NO_VIDEO_FRAME = -101;
    const ML_ERROR_UNEXPECTED_EARLY_TERMINATION = -102;
    const ML_ERROR_PROTECTED_CONTENT = -103;
    const ML_ERROR_FRAME_CONVERSION = -104;
    
    if (errorCode === ML_ERROR_GRACEFUL_TERMINATION) {
      // 服务器正常关闭（用户在服务器端退出游戏），stopStreaming 内部会显示延迟统计
      this.stopStreaming();
    } else {
      // 连接异常终止，显示错误信息
      let message: string;
      switch (errorCode) {
        case ML_ERROR_NO_VIDEO_TRAFFIC:
          message = '未收到视频数据。请检查防火墙或端口转发规则（UDP 47998）。';
          break;
        case ML_ERROR_NO_VIDEO_FRAME:
          message = '未收到完整视频帧。网络可能不稳定或码率设置过高。';
          break;
        case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
        case ML_ERROR_PROTECTED_CONTENT:
          message = '串流意外终止。可能是受保护内容或编码器无法捕获视频。';
          break;
        case ML_ERROR_FRAME_CONVERSION:
          message = '帧转换错误。请尝试调整分辨率或关闭 HDR。';
          break;
        default:
          const errorHex = Math.abs(errorCode) > 1000 ? `0x${errorCode.toString(16)}` : errorCode.toString();
          message = `连接已断开 (错误码: ${errorHex})`;
          break;
      }
      
      promptAction.showDialog({
        title: '连接已断开',
        message: message,
        buttons: [{ text: '确定', color: '#3B82F6' }]
      }).then(() => {
        this.stopStreaming();
      }).catch(() => {
        this.stopStreaming();
      });
    }
  }
  
  /**
   * 退出游戏并返回
   * 与断开连接不同，这会请求服务器退出当前游戏
   * 优化：先返回菜单立即响应用户，后台处理退出请求
   */
  async quitGameAndReturn(): Promise<void> {
    // 显示延迟统计 toast（在退出前获取数据）
    this.showLatencyToastIfEnabled();
    
    // 先恢复窗口设置并返回菜单（立即响应）
    await this.windowManager?.restoreWindow();
    router.back();
    
    // 后台退出游戏（不阻塞 UI）
    this.viewModel.quitGame().then(()=> {
    }).catch((err: Error) => {
    });
  }
  
  /**
   * 发送超级指令 (Sunshine 功能)
   */
  async sendSuperCmd(cmdId: string): Promise<void> {
    try {
      const success = await this.viewModel.sendSuperCmd(cmdId);
      if (success) {
        promptAction.showToast({ message: '指令已发送' });
      } else {
        promptAction.showToast({ message: '指令发送失败' });
      }
    } catch (err) {
      promptAction.showToast({ message: `指令发送失败: ${(err as Error).message}` });
    }
  }
  
  /**
   * 获取触摸模式的中文名称
   */
  getTouchModeName(): string {
    switch (this.viewModel.touchMode) {
      case 'trackpad':
        return '触控板模式';
      case 'direct':
        return '多点触控模式';
      case 'mouse':
        return '鼠标模式';
      default:
        return this.viewModel.touchMode;
    }
  }
  
  /**
   * 处理触摸事件
   */
  handleTouch(event: TouchEvent): void {
    if (!this.viewModel.isConnected) {
      return;
    }
    // 虚拟手柄显示时不处理触摸输入，避免与虚拟按键手势竞争
    if (this.viewModel.showController) {
      return;
    }
    this.touchInputHandler.handleTouchEvent(event);
  }
  
  /**
   * 初始化绝对鼠标模式
   */
  private initializeAbsoluteMouseMode(): void {
    const absoluteMouseMode = this.viewModel.absoluteMouseMode;
    
    if (absoluteMouseMode) {
      // 初始化绝对鼠标管理器
      this.absoluteMouseManager = AbsoluteMouseManager.getInstance();
      
      const viewWidth = this.viewModel.displayInfo.screenWidth;
      const viewHeight = this.viewModel.displayInfo.screenHeight;
      
      this.absoluteMouseManager.initialize(MoonBridge, viewWidth, viewHeight);
      this.absoluteMouseManager.setAbsoluteMouseMode(true);
      
      // 同步到 TouchInputHandler
      this.touchInputHandler.setAbsoluteMouseMode(true);
      this.touchInputHandler.updateViewSize(viewWidth, viewHeight);
      
      console.info(`StreamPage: 绝对鼠标模式已初始化 ${viewWidth}x${viewHeight}`);
    }
  }

  /**
   * 启动按键事件拦截器
   * 拦截被系统劫持的手柄按键和特殊键盘按键，转发给 GamepadManager / StreamingSession 处理
   */
  private startKeyInterceptor(): void {
    const result = InputInterceptorService.getInstance().start((event) => {
      if (!this.viewModel.isConnected) {
        return;
      }
      const keyCode = event.keyCode;
      // action: 1=KEY_DOWN, 2=KEY_UP
      const isPressed = event.action === 1;

      // 1. 手柄按键范围 (2300-2320 GC Kit / 110 标准 Mode) - 转发给 GamepadManager
      if ((keyCode >= 2300 && keyCode <= 2320) || keyCode === 110) {
        this.gamepadManager.handleKeyEvent(0, keyCode, isPressed);
        return;
      }

      // 2. 音量键 (16=VOLUME_UP, 17=VOLUME_DOWN, 22=VOLUME_MUTE)
      //    C++ 层已优先尝试回注到系统；到达这里说明回注失败，用应用级音量补偿
      if (keyCode === 16 || keyCode === 17 || keyCode === 22) {
        if (isPressed) {
          this.handleVolumeKey(keyCode);
        }
        return;
      }

      // 3. 容易被系统劫持的特殊键盘按键 - 转发到主机
      //    Home(1), Back(2), 多任务(3),
      //    媒体键: Play/Pause(10), Stop(11), Next(12), Previous(13)
      const SYSTEM_HIJACKED_KEYS: Set<number> = new Set([
        1, 2, 3,                   // Home, Back, Recent
        10, 11, 12, 13             // Media keys
      ]);

      if (SYSTEM_HIJACKED_KEYS.has(keyCode)) {
        const session = this.viewModel.getSession();
        if (session) {
          // HarmonyOS keyCode -> Windows VK 映射
          const vkCode = this.mapSystemKeyToVK(keyCode);
          if (vkCode > 0) {
            const keyAction = isPressed ? 0x03 : 0x04; // KEY_DOWN : KEY_UP
            session.sendKeyboardInput(vkCode, keyAction, 0);
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
   * 处理音量键事件（回退路径）
   * C++ 层优先尝试 OH_Input_InjectKeyEvent 回注到系统；
   * 如果回注失败（无权限/API 不可用），音量键事件到达这里，
   * 用 OH_AudioRenderer 的应用级音量补偿。
   */
  private handleVolumeKey(keyCode: number): void {
    const session = this.viewModel.getSession();
    if (!session) {
      return;
    }

    if (keyCode === 16) {
      this.appVolume = Math.min(1.0, this.appVolume + StreamPage.VOLUME_STEP);
    } else if (keyCode === 17) {
      this.appVolume = Math.max(0.0, this.appVolume - StreamPage.VOLUME_STEP);
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
  
  /**
   * 设置触摸模式
   */
  setTouchMode(mode: string): void {
    this.viewModel.setTouchMode(mode as TouchMode);
    this.touchInputHandler.setMode(mode as TouchInputMode);
    console.info(`StreamPage: 触摸模式切换为 ${mode}`);
  }
  
  /**
   * 强制切换到 USB 驱动模式
   */
  async forceUsbDriverMode(): Promise<void> {
    try {
      const success = await this.gamepadManager.forceUsbDriverMode();
      if (success) {
        const modeDesc = this.gamepadManager.getInputModeDescription();
        promptAction.showToast({ 
          message: `已切换到: ${modeDesc}`,
          duration: 3000
        });
        console.info(`StreamPage: 已切换输入模式 -> ${modeDesc}`);
      } else {
        promptAction.showToast({ 
          message: '切换失败，请重试',
          duration: 2000
        });
      }
    } catch (err) {
      console.error('强制 USB 驱动模式切换失败:', err);
      promptAction.showToast({ 
        message: '切换失败: ' + (err as Error).message,
        duration: 2000
      });
    }
  }

  /**
   * 处理键盘/手柄按键事件
   * @param event 按键事件
   * @returns 是否已处理该事件
   */
  handleKeyEvent(event: KeyEvent): boolean {
    // 手柄相关按键（2300-2320 范围）总是拦截，防止系统默认行为
    const keyCode = event.keyCode;
    const isGamepadKey = keyCode >= 2300 && keyCode <= 2320;
    
    if (!this.viewModel.isConnected) {
      // 即使未连接，也要拦截手柄按键，防止触发系统导航
      return isGamepadKey;
    }
    
    // 获取设备ID，如果没有则使用默认值0
    const deviceId = event.deviceId ?? 0;
    
    // 转发给 GamepadManager 处理
    this.gamepadManager.handleKeyEvent(
      deviceId, 
      keyCode, 
      event.type === KeyType.Down
    );
    
    // 返回 true 表示事件已处理，防止默认行为
    return true;
  }

  build() {
    Stack() {
      // 视频渲染层
      XComponent({
        id: 'streamSurface',
        type: XComponentType.SURFACE,
        controller: this.xComponentController
      })
        .onLoad(() => {
          console.info('XComponent 加载完成');
          this.startStreaming();
        })
        .onDestroy(() => {
          console.info('XComponent 销毁');
        })
        .width(this.xComponentWidth)
        .height(this.xComponentHeight)
        .hitTestBehavior(this.viewModel.showController ? HitTestMode.None : HitTestMode.Default)
        .onTouch((event: TouchEvent) => {
          this.handleTouch(event);
        })

      // 连接状态层
      if (this.viewModel.isConnecting) {
        this.ConnectingOverlay()
      }

      // 错误提示层
      if (this.viewModel.hasError) {
        this.ErrorOverlay()
      }

      // 性能监控层
      if (this.viewModel.isConnected && this.viewModel.showOverlay) {
        PerformanceOverlay({
          viewModel: this.viewModel,
          screenWidth: this.viewModel.displayInfo.screenWidth,
          screenHeight: this.viewModel.displayInfo.screenHeight
        })
      }

      // 虚拟控制器层
      // 使用 flex 布局 (Column+Row)，HitTestMode.Default 阻塞 XComponent 兄弟节点的触摸
      if (this.viewModel.isConnected && this.viewModel.showController) {
        VirtualControllerV2({
          config: {
            opacity: 0.75,
            scale: 1.0,
            deadzone: 0.15,
            showLeftStick: true,
            showRightStick: true,
            showDpad: true,
            showButtons: true,
            showShoulder: true,
            showCenter: true,
            showL3R3: false,
            enableVibration: true
          } as VirtualControllerConfig,
          onInput: (input) => {
            this.viewModel.sendInput(input);
          }
        })
      }

      // 移除悬浮菜单按钮，改用返回手势触发菜单

      // 系统键盘输入面板
      if (this.showKeyboardPanel) {
        this.KeyboardInputPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      return this.handleKeyEvent(event);
    })
    .onMouse((event: MouseEvent) => {
      // 物理鼠标事件处理
      if (this.viewModel.isConnected && this.absoluteMouseManager && event.action === MouseAction.Move) {
        // 绝对鼠标模式：发送鼠标绝对位置
        this.absoluteMouseManager.handleMouseEvent(event.x, event.y);
      }
    })
  }

  // ==================== UI Builders ====================

  @Builder
  KeyboardInputPanel() {
    // 紧贴 IME 上方、右对齐的浮动胶囊工具条
    Row({ space: 10 }) {
      // 键盘指示
      Text('⌨')
        .fontSize(17)
        .fontColor('#D0FFFFFF')

      Divider()
        .vertical(true)
        .height(16)
        .color('#33FFFFFF')
        .strokeWidth(1)

      // 主机键盘 — 唤起远程桌面键盘并收起 IME
      Button('主机键盘')
        .fontSize(12)
        .fontColor('#FFFFFF')
        .backgroundColor('#3B82F6')
        .height(28)
        .borderRadius(14)
        .padding({ left: 12, right: 12 })
        .onClick(() => {
          this.viewModel.getSession()?.sendKeys([VirtualKey.VK_LWIN, VirtualKey.VK_CONTROL, VirtualKey.VK_O]);
          this.hideIMEKeyboard();
        })

      // 关闭
      Text('✕')
        .fontSize(15)
        .fontColor('#99FFFFFF')
        .width(28)
        .height(28)
        .textAlign(TextAlign.Center)
        .borderRadius(14)
        .backgroundColor('#1AFFFFFF')
        .onClick(() => {
          this.hideIMEKeyboard();
        })
    }
    .padding({ left: 14, right: 8, top: 7, bottom: 7 })
    .backgroundColor('#CC1A1A2E')
    .backdropBlur(40)
    .borderRadius(20)
    .shadow({ radius: 12, color: '#40000000', offsetY: 2 })
    .position({ right: 12, bottom: this.keyboardHeight + 8 })
  }

  @Builder
  ConnectingOverlay() {
    Column() {
      LoadingProgress()
        .width(48)
        .height(48)
        .color(Color.White)

      Text(this.viewModel.connectionStageText || '正在连接...')
        .fontSize(14)
        .fontColor('#B0FFFFFF')
        .margin({ top: 16 })
        .textAlign(TextAlign.Center)
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#CC000000')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorOverlay() {
    Column() {
      Image($r('app.media.ic_error'))
        .width(64)
        .height(64)
        .fillColor($r('app.color.error_red'))
      Text(this.viewModel.errorMessage)
        .fontSize(16)
        .fontColor(Color.White)
        .margin({ top: 16 })
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })

      Button('返回')
        .fontSize(16)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.primary'))
        .width(120)
        .height(44)
        .borderRadius(12)
        .margin({ top: 24 })
        .onClick(() => {
          router.back();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#CC000000')
    .justifyContent(FlexAlign.Center)
  }
}
