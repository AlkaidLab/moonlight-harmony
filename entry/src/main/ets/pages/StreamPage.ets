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
import { MoonBridge, BUTTON_ACTION_PRESS, BUTTON_ACTION_RELEASE } from '../service/MoonBridge';
import { SuperCmd } from '../service/NvHttp';
import { AbsoluteMouseManager } from '../service/LocalCursorManager';
import { VirtualKey } from '../components/StreamMenuManager';
import { pointer } from '@kit.InputKit';
import { InputInterceptorService } from '../service/InputInterceptorService';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { SettingsKeys } from '../service/SettingsService';
import { StreamInputHandler } from './StreamInputHandler';
import { StreamLifecycleManager } from './StreamLifecycleManager';
import { StreamIMEManager } from './StreamIMEManager';

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
  
  // 绝对鼠标管理器
  private absoluteMouseManager: AbsoluteMouseManager | null = null;
  
  // ── 解耦的处理器/管理器 ──
  private inputHandler: StreamInputHandler = new StreamInputHandler();
  private lifecycleManager: StreamLifecycleManager = new StreamLifecycleManager();
  private imeManager: StreamIMEManager = new StreamIMEManager(getContext(this) as common.UIAbilityContext);
  
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
    
    // 初始化输入处理器
    this.inputHandler.initialize(this.viewModel, this.gamepadManager);
    
    // 初始化生命周期管理器
    this.lifecycleManager.initialize(this.viewModel, this.windowManager, {
      updateXComponentSize: (width: Length, height: Length) => {
        this.xComponentWidth = width;
        this.xComponentHeight = height;
      },
      stopStreaming: () => {
        this.stopStreaming();
      }
    });
    
    // 初始化 IME 管理器
    this.imeManager.initialize(this.viewModel, {
      onKeyboardVisibilityChanged: (visible: boolean) => {
        this.showKeyboardPanel = visible;
      },
      onKeyboardHeightChanged: (height: number) => {
        this.keyboardHeight = height;
      }
    });
    
    // 获取屏幕尺寸
    this.initializeDisplay();
    
    // 注册应用状态监听
    this.lifecycleManager.registerAppStateListener();
    
    // 注册屏幕方向变化监听
    this.lifecycleManager.registerDisplayChangeListener();
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
    
    // 取消生命周期监听
    this.lifecycleManager.unregisterAppStateListener();
    this.lifecycleManager.unregisterDisplayChangeListener();
    
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
    this.imeManager.hide();
    this.windowManager?.restoreWindow();

    // 恢复系统鼠标光标显示
    try {
      pointer.setPointerVisibleSync(true);
    } catch (_) {}
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

    // IME 键盘正在显示时，优先收起键盘（排除弹出瞬间的误触发）
    if (this.showKeyboardPanel && Date.now() - this.imeManager.readyTime > 500) {
      this.imeManager.hide();
      return true;
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
        hasConnectedGamepad: this.gamepadManager.getConnectedGamepads().length > 0,
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
            this.imeManager.show();
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
                data.color,
                data.keySequence
              );
              promptAction.showToast({ message: `快捷键 "${data.name}" 已更新` });
            } else {
              // 添加模式
              await this.shortcutManager.addShortcut(data.name, data.keys, data.icon, data.color, data.keySequence);
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
      this.lifecycleManager.setLatencyToastEnabled(
        await PreferencesUtil.get<boolean>(SettingsKeys.LATENCY_TOAST, false)
      );
      await this.gamepadManager.reloadSettings();
      
      // 设置串流分辨率
      this.windowManager?.setStreamResolution(
        this.viewModel.displayInfo.streamWidth,
        this.viewModel.displayInfo.streamHeight
      );
      
      // 配置屏幕方向
      await this.windowManager?.configureOrientation();

      // 设置 HDR 高亮度（如果启用）
      const streamConfig = this.viewModel.streamConfig;
      if (streamConfig) {
        await this.windowManager?.setHdrBrightness(streamConfig.hdr, streamConfig.hdrHighBrightness);
      }
      
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
        this.lifecycleManager.handleConnectionTerminated(errorCode);
      });

      // 设置分辨率变化回调（服务端屏幕旋转/分辨率变化时同步客户端布局）
      this.viewModel.setResolutionChangedCallback((width: number, height: number) => {
        this.lifecycleManager.handleServerResolutionChanged(width, height);
      });

      // 获取 surfaceId 并开始串流
      const surfaceId = this.xComponentController.getXComponentSurfaceId();
      await this.viewModel.startStreaming(this.computerId, this.appId, surfaceId, this.context, this.displayGuid, this.useVdd);

      // 启动按键拦截器（拦截被系统劫持的手柄按键，如蓝牙手柄 Home 键）
      if (this.viewModel.inputSettings?.enableKeyInterceptor) {
        this.inputHandler.startKeyInterceptor();
      }

      // 初始化体感助手
      this.initializeGyroAssist();

      // 隐藏本地系统鼠标光标（串流时由远端/本地光标管理器接管）
      try {
        pointer.setPointerVisibleSync(false);
        console.info('StreamPage: 已隐藏本地系统鼠标光标');
      } catch (e) {
        console.warn('StreamPage: 隐藏鼠标光标失败:', JSON.stringify(e));
      }

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
    this.lifecycleManager.showLatencyToastIfEnabled();

    // 重置输入状态
    this.inputHandler.resetState();

    // 恢复系统鼠标光标显示
    try {
      pointer.setPointerVisibleSync(true);
    } catch (_) {}

    // 先恢复窗口设置并返回菜单（立即响应）
    await this.windowManager?.restoreWindow();
    router.back();
    
    // 后台停止串流
    this.viewModel.stopStreaming();
  }
  
  /**
   * 退出游戏并返回
   * 与断开连接不同，这会请求服务器退出当前游戏
   * 优化：先返回菜单立即响应用户，后台处理退出请求
   */
  async quitGameAndReturn(): Promise<void> {
    // 显示延迟统计 toast（在退出前获取数据）
    this.lifecycleManager.showLatencyToastIfEnabled();
    
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
   * 执行快捷键（支持单次组合或多步序列）
   */
  sendShortcut(shortcut: Shortcut): void {
    const session = this.viewModel.getSession();
    if (!session) return;

    if (shortcut.keySequence && shortcut.keySequence.length > 0) {
      // 多步按键序列：依次发送每组键，间隔 200ms
      shortcut.keySequence.forEach((keys: number[], index: number) => {
        setTimeout(() => {
          session.sendKeys(keys);
        }, index * 200);
      });
    } else if (shortcut.keys.length > 0) {
      session.sendKeys(shortcut.keys);
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
      
      // 同步到 TouchInputHandler 和 InputHandler
      this.touchInputHandler.setAbsoluteMouseMode(true);
      this.touchInputHandler.updateViewSize(viewWidth, viewHeight);
      this.inputHandler.setAbsoluteMouseManager(this.absoluteMouseManager);
      
      console.info(`StreamPage: 绝对鼠标模式已初始化 ${viewWidth}x${viewHeight}`);
    }
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
          // 过滤鼠标源触摸事件：物理鼠标点击会同时触发 .onMouse 和 .onTouch，
          // 鼠标事件已在 .onMouse 中处理，此处跳过避免重复发送为触摸
          if (event.source === SourceType.Mouse) return;
          this.handleTouch(event);
        })
        .onMouse((event: MouseEvent) => {
          // 物理鼠标事件处理 → 委托给输入处理器
          this.inputHandler.handleMouseEvent(event);
        })
        .onAxisEvent((event: AxisEvent) => {
          // 鼠标滚轮事件处理 → 委托给输入处理器
          this.inputHandler.handleAxisEvent(event);
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
      return this.inputHandler.handleKeyEvent(event);
    })
  }

  // ==================== UI Builders ====================

  @Builder
  KeyboardInputPanel() {
    // 紧贴 IME 上方的浮动工具条：快捷键 + 服务端指令 + 主机键盘
    Column({ space: 0 }) {
      // 横向滚动工具条
      Scroll() {
        Row({ space: 6 }) {
          // ── 键盘指示 + 主机键盘 ──
          Text('⌨')
            .fontSize(17)
            .fontColor('#D0FFFFFF')

          Button('主机键盘')
            .fontSize(11)
            .fontColor('#FFFFFF')
            .backgroundColor('#3B82F6')
            .height(26)
            .borderRadius(13)
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.viewModel.getSession()?.sendKeys([VirtualKey.VK_LWIN, VirtualKey.VK_CONTROL, VirtualKey.VK_O]);
              this.imeManager.hide();
            })

          Divider()
            .vertical(true)
            .height(16)
            .color('#33FFFFFF')
            .strokeWidth(1)

          // ── 快捷键按钮（与菜单卡片中 ShortcutPill 一致的颜色方案）──
          ForEach(this.shortcutManager.getShortcuts(), (shortcut: Shortcut) => {
            Row() {
              if (shortcut.icon) {
                Text(shortcut.icon)
                  .fontSize(11)
                  .margin({ right: 3 })
              }
              Text(shortcut.name)
                .fontSize(11)
                .fontColor('#F0FFFFFF')
            }
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(`#50${(shortcut.color || '#9DABB2').replace('#', '')}`)
            .border({ width: 1, color: `#80${(shortcut.color || '#9DABB2').replace('#', '')}` })
            .borderRadius(13)
            .onClick(() => {
              this.sendShortcut(shortcut);
            })
          }, (shortcut: Shortcut) => shortcut.id)

          // ── 服务端指令按钮 ──
          if (this.cmdList.length > 0) {
            Divider()
              .vertical(true)
              .height(16)
              .color('#33FFFFFF')
              .strokeWidth(1)

            ForEach(this.cmdList, (cmd: SuperCmd) => {
              Row() {
                Text('⚡')
                  .fontSize(11)
                  .margin({ right: 3 })
                Text(cmd.name)
                  .fontSize(11)
                  .fontColor('#F0FFFFFF')
              }
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor('#50D97706')
              .border({ width: 1, color: '#80D97706' })
              .borderRadius(13)
              .onClick(() => {
                this.sendSuperCmd(cmd.id);
              })
            }, (cmd: SuperCmd) => cmd.id)
          }
        }
        .padding({ left: 10, right: 6 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Start)
    }
    .direction(Direction.Ltr)
    .width('100%')
    .height(40)
    .backgroundColor('#CC1A1A2E')
    .backdropBlur(40)
    .borderRadius({ topLeft: 16, topRight: 16 })
    .shadow({ radius: 12, color: '#40000000', offsetY: -2 })
    .position({ left: 0, bottom: this.keyboardHeight })

    // 右上角关闭按钮（悬浮在工具条上方）
    Text('✕')
      .fontSize(13)
      .fontColor('#99FFFFFF')
      .width(24)
      .height(24)
      .textAlign(TextAlign.Center)
      .borderRadius(12)
      .backgroundColor('#661A1A2E')
      .backdropBlur(20)
      .onClick(() => {
        this.imeManager.hide();
      })
      .position({ right: 8, bottom: this.keyboardHeight + 44 })
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
