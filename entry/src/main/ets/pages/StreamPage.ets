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
import { router, promptAction, LengthMetrics } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { displaySync } from '@kit.ArkGraphics2D';
import { VirtualControllerOverlay } from '../components/virtual/VirtualController';
import { PerformanceOverlay } from '../components/PerformanceOverlay';
import { OptionPickerDialog, OptionPickerDialogConfig } from '../components/dialogs/OptionPickerDialog';
import { GameMenuDialog, GameMenuCallbacks } from '../components/dialogs/GameMenuDialog';
import { StreamMenuManager } from '../components/StreamMenuManager';
import { StreamViewModel, TouchMode } from '../viewmodel/StreamViewModel';
import { TouchInputHandler, TouchInputMode } from '../service/TouchInputHandler';
import { StreamWindowManager } from '../service/StreamWindowManager';
import { ShortcutManager, Shortcut } from '../components/ShortcutManager';
import { ShortcutEditorDialog, ShortcutEditData } from '../components/dialogs/ShortcutEditorDialog';
import { GamepadManager, GamepadState, MoonlightControllerType, MouseEmulationCallback } from '../service/GamepadManager';
import { GyroAssistService } from '../service/GyroAssistService';
import { MoonBridge, BUTTON_ACTION_PRESS, BUTTON_ACTION_RELEASE } from '../service/MoonBridge';
import { SuperCmd, NvHttp } from '../service/NvHttp';
import { VirtualKey, KeyAction, sendShortcutKeys } from '../service/CustomKeyTypes';
import { pointer } from '@kit.InputKit';
import { InputInterceptorService } from '../service/InputInterceptorService';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { SettingsKeys } from '../service/SettingsService';
import { StreamInputHandler } from '../service/StreamInputHandler';
import { StreamLifecycleManager } from '../service/StreamLifecycleManager';
import { StreamIMEManager } from '../service/StreamIMEManager';
import { VirtualKeyboard } from '../components/virtual/VirtualKeyboard';
import { CustomKeyOverlay } from '../components/CustomKeyOverlay';
import { CustomKeyManager, CustomKeyManagerHost, SessionLike } from '../service/CustomKeyManager';
import { CustomKeyStore } from '../service/CustomKeyStore';
import { PanZoomHandler, PanZoomState, PointXY } from '../service/PanZoomHandler';
import { AiKeyService, AiKeyRecommendation } from '../service/AiKeyService';
import { selectBestAddress } from '../model/ComputerInfo';
import { ComputerManager } from '../service/ComputerManager';

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

/** StreamPage 对 CustomKeyManager 的宿主回调实现 */
class CustomKeyManagerHostImpl implements CustomKeyManagerHost {
  getSessionFn: () => SessionLike | null = () => null;
  toggleVirtualKeyboardFn: () => void = () => {};
  showIMEFn: () => void = () => {};
  openGameMenuFn: () => void = () => {};
  toggleMouseModeFn: () => void = () => {};
  switchProfileFn: () => void = () => {};
  toggleEditModeFn: () => void = () => {};
  hideCustomKeysFn: () => void = () => {};
  onCustomKeysImportedFn: () => void = () => {};

  getSession(): SessionLike | null {
    return this.getSessionFn();
  }

  toggleVirtualKeyboard(): void {
    this.toggleVirtualKeyboardFn();
  }

  showIME(): void {
    this.showIMEFn();
  }

  openGameMenu(): void {
    this.openGameMenuFn();
  }

  toggleMouseMode(): void {
    this.toggleMouseModeFn();
  }

  switchProfile(): void {
    this.switchProfileFn();
  }

  toggleEditMode(): void {
    this.toggleEditModeFn();
  }

  hideCustomKeys(): void {
    this.hideCustomKeysFn();
  }

  onCustomKeysImported(): void {
    this.onCustomKeysImportedFn();
  }
}

@Entry
@Component
struct StreamPage {
  // ViewModel
  @State viewModel: StreamViewModel = new StreamViewModel();
  
  // 网络质量警告（通过 AppStorage 跨 NAPI 边界可靠同步）
  @StorageLink('connectionPoor') connectionPoor: boolean = false;
  
  // UI 状态
  @State xComponentWidth: Length = '100%';
  @State xComponentHeight: Length = '100%';
  @State xComponentAlignment: Alignment = Alignment.Center;  // 画面位置（9 宫格）
  @State xComponentOffsetX: number = 0;  // 画面水平偏移 (vp)
  @State xComponentOffsetY: number = 0;  // 画面垂直偏移 (vp)
  @State showKeyboardPanel: boolean = false;  // 系统键盘输入面板
  @State keyboardHeight: number = 0;  // IME 键盘高度 (vp)
  @State showVirtualKeyboard: boolean = false;  // PC 虚拟键盘
  @State showCustomKeys: boolean = false;  // 自定义按键覆盖层
  @State customKeyEditMode: boolean = false;  // 自定义按键编辑模式
  @State customKeyProfileVersion: number = 0;  // 配置切换信号（递增触发 Overlay 重载）
  /**
   * 自定义按键命中测试刷新触发器。
   * ArkUI 首次渲染时 .position() 子组件的命中测试区域可能未正确建立，
   * 通过在父层触发一次重渲染来刷新命中测试树（参见 ARKUI_TOUCH_HANDLING_LESSONS.md）。
   */
  @State private customKeyHitReady: number = 0;
  /** 用户设置：优先使用虚拟键盘 */
  private useVirtualKeyboard: boolean = false;
  /** 待对话框关闭后显示 IME */
  private pendingShowIME: boolean = false;
  /** 虚拟手柄+触摸共存 */
  @State touchPassthrough: boolean = false;
  /** 虚拟手柄缩放比例 */
  @State controllerScaleValue: number = 1.0;
  /** 虚拟手柄透明度 */
  @State controllerOpacityValue: number = 0.75;
  /** 双指缩放模式开关（启用后触摸用于缩放/平移，不发送给远端） */
  @State isTouchOverrideEnabled: boolean = false;
  /** 视频缩放倍数 */
  @State videoScale: number = 1.0;
  /** 视频水平平移 (vp) */
  @State videoTranslateX: number = 0;
  /** 视频垂直平移 (vp) */
  @State videoTranslateY: number = 0;
  
  // 鼠标高帧率保持（C++ Monitor 不可用时的 fallback）
  // 使用 DisplaySync 直接向系统合成器请求高刷新率，
  // 解决无触摸时 ArkUI .onMouse 降至 ~30Hz 的问题
  private mouseDisplaySync: displaySync.DisplaySync | null = null;
  
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
  
  // XComponent 实际渲染尺寸缓存（由 onAreaChange 回调更新）
  // 窗口模式下 xComponentWidth/Height='100%'，实际 vp 尺寸需从 onAreaChange 获取
  private xComponentActualWidthVp: number = 0;
  private xComponentActualHeightVp: number = 0;

  // 组件控制器和服务
  private xComponentController: XComponentController = new XComponentController();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private touchInputHandler: TouchInputHandler = new TouchInputHandler();
  private windowManager: StreamWindowManager | null = null;
  private menuManager: StreamMenuManager | null = null;
  private shortcutManager: ShortcutManager = ShortcutManager.getInstance();
  private gamepadManager: GamepadManager = GamepadManager.getInstance();
  private customKeyManager: CustomKeyManager | null = null;
  private panZoomHandler: PanZoomHandler = new PanZoomHandler();
  private controllerTypes: Map<number, number> = new Map();  // slot → MoonlightControllerType
  private aiKeyService: AiKeyService | null = null;
  
  // 页面参数
  private computerId: string = '';
  private appId: number = 0;
  private appName: string = '';
  private displayGuid: string = '';
  private useVdd: boolean = false;
  private cmdList: SuperCmd[] = [];  // 超级指令列表
  private enableBackgroundTask: boolean = true;  // 后台保活开关
  
  aboutToAppear(): void {
    const params = router.getParams() as StreamPageParams;
    if (params) {
      this.computerId = params.computerId;
      this.appId = params.appId;
      this.appName = params.appName || '';
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

    // 自动加载游戏关联的自定义按键配置
    if (this.appId > 0) {
      CustomKeyStore.loadGameProfile(this.appId).then((profile) => {
        if (profile) {
          this.customKeyProfileVersion++;
          console.info(`[StreamPage] 自动加载游戏配置: ${profile.name}`);
        }
      });
    }
    
    // 初始化 AI 按键推荐服务
    if (this.computerId) {
      try {
        const computer = ComputerManager.getInstance().getComputer(this.computerId);
        if (computer) {
          const nvHttp = new NvHttp(selectBestAddress(computer), computer.serverCert, this.context, computer.httpPort);
          this.aiKeyService = new AiKeyService(nvHttp);

          // 异步探测 AI 可用性，延迟显示避免与手柄连接等 toast 冲突
          nvHttp.checkAiAvailable().then((available: boolean) => {
            if (available) {
              setTimeout(() => {
                promptAction.showToast({
                  message: '✨ AI LLM 已连接，可使用 AIV+ 功能',
                  duration: 2500
                });
              }, 3000);
            }
          });
        }
      } catch (err) {
        console.warn(`[StreamPage] AI 服务初始化失败: ${err}`);
      }
    }

    // 初始化窗口管理器
    this.windowManager = new StreamWindowManager(this.context);
    this.windowManager.setOnWindowSizeChanged(() => this.recalculateXComponentSize());
    
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

    // 初始化自定义按键管理器
    const customKeyHost = new CustomKeyManagerHostImpl();
    customKeyHost.getSessionFn = (): SessionLike | null => this.viewModel.getSession();
    customKeyHost.toggleVirtualKeyboardFn = (): void => {
      if (this.useVirtualKeyboard) {
        this.showVirtualKeyboard = !this.showVirtualKeyboard;
      } else {
        this.imeManager.show();
      }
    };
    customKeyHost.showIMEFn = (): void => { this.imeManager.show(); };
    customKeyHost.openGameMenuFn = (): void => { this.showStreamMenu(); };
    customKeyHost.toggleMouseModeFn = (): void => {
      // 切换鼠标模式（复用菜单管理器提供的触摸模式切换）
      this.showTouchModeMenu();
    };
    customKeyHost.switchProfileFn = (): void => {
      this.cycleCustomKeyProfile();
    };
    customKeyHost.toggleEditModeFn = (): void => {
      this.customKeyEditMode = !this.customKeyEditMode;
    };
    customKeyHost.hideCustomKeysFn = (): void => {
      this.showCustomKeys = false;
    };
    customKeyHost.onCustomKeysImportedFn = (): void => { this.showCustomKeys = true; };
    this.customKeyManager = new CustomKeyManager(customKeyHost);
    
    // 初始化输入处理器
    this.inputHandler.initialize(this.viewModel, this.gamepadManager);
    this.inputHandler.setOnShowStreamMenu(() => this.showStreamMenu());

    // 初始化双指缩放处理器
    this.panZoomHandler.setOnStateChanged((state: PanZoomState) => {
      this.videoScale = state.scale;
      this.videoTranslateX = state.translateX;
      this.videoTranslateY = state.translateY;
      // 缩放状态下设置坐标逆变换，确保触摸坐标映射到正确的游戏画面位置
      if (this.panZoomHandler.isZoomed()) {
        this.touchInputHandler.setCoordinateTransform((x: number, y: number): PointXY => {
          return this.panZoomHandler.inverseTransform(x, y);
        });
      } else {
        this.touchInputHandler.setCoordinateTransform(null);
      }
    });
    
    // 初始化生命周期管理器
    this.lifecycleManager.initialize(this.viewModel, this.windowManager, {
      updateXComponentSize: (width: Length, height: Length) => {
        this.xComponentWidth = width;
        this.xComponentHeight = height;
      },
      stopStreaming: () => {
        this.stopStreaming();
      },
      reconnectStreaming: () => {
        this.reconnectStreaming();
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

    // 设置触摸板鼠标回调 — DualSense/DS4 触摸板→鼠标移动
    this.gamepadManager.setTouchpadMouseCallback((deltaX: number, deltaY: number) => {
      MoonBridge.sendMouseMove(deltaX, deltaY);
    });

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

      // 更新缩放处理器容器尺寸
      this.panZoomHandler.setParentSize(screenWidth, screenHeight);
      
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

    // 停止后台保活（安全兜底）
    this.lifecycleManager.stopBackgroundTask();
    
    // 清理 ViewModel
    this.viewModel.dispose();
    
    // 清理触摸处理器
    this.touchInputHandler.dispose();
    
    // 停止按键拦截器、鼠标 Monitor 和 DisplaySync
    InputInterceptorService.getInstance().stop();
    this.inputHandler.stopMouseInterceptor();
    this.stopMouseKeepAlive();

    // 停止体感助手
    GyroAssistService.getInstance().dispose();
    
    // 清理手柄监听并重置会话状态（防止内存泄漏和重复绑定）
    this.gamepadManager.setListener(null);
    this.gamepadManager.resetSession();
    
    // 重置自定义按键状态（防止虚拟按键残留）
    this.customKeyManager?.reset();
    
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
    // 释放所有通过 onKeyEvent 按下但未释放的物理键（防止 ESC 等键卡住）
    this.inputHandler.releaseAllKeys();

    // 如果正在连接中，允许直接返回
    if (this.viewModel.isConnecting) {
      return false;
    }

    // 虚拟 PC 键盘正在显示时，优先收起
    if (this.showVirtualKeyboard) {
      this.showVirtualKeyboard = false;
      return true;
    }

    // 自定义按键编辑模式时，优先退出编辑
    if (this.customKeyEditMode) {
      this.customKeyEditMode = false;
      return true;
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
   * 构建游戏菜单回调（从 showStreamMenu 提取，减少嵌套层级）
   */
  private buildGameMenuCallbacks(): GameMenuCallbacks {
    return {
      onDismiss: () => {
        this.resumeMouseInterceptor();
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
      onOpenShortcutEditor: () => {
        this.gameMenuDialogController?.close();
        setTimeout(() => this.showShortcutEditor(), 300);
      },
      onEditShortcut: (shortcut) => {
        this.gameMenuDialogController?.close();
        setTimeout(() => this.showShortcutEditor(shortcut), 300);
      },
      onDeleteShortcut: (shortcut) => {
        promptAction.showToast({ message: `快捷键 "${shortcut.name}" 已删除` });
      },
      onSendSuperCmd: (cmdId: string) => {
        this.sendSuperCmd(cmdId);
      },
      onForceUsbDriver: () => {
        this.forceUsbDriverMode();
      },
      onToggleKeyboard: () => {
        if (this.useVirtualKeyboard) {
          this.showVirtualKeyboard = !this.showVirtualKeyboard;
        } else {
          this.pendingShowIME = true;
        }
      },
      onToggleCustomKeys: () => {
        this.showCustomKeys = !this.showCustomKeys;
        if (this.showCustomKeys) {
          // 延迟刷新命中测试区域（参见 ARKUI_TOUCH_HANDLING_LESSONS.md）
          setTimeout(() => { this.customKeyHitReady += 1; }, 100);
        }
      },
      onEditCustomKeys: () => {
        this.showCustomKeys = true;
        this.customKeyEditMode = true;
        // 延迟刷新命中测试区域
        setTimeout(() => { this.customKeyHitReady += 1; }, 100);
      },
      onExportCustomKeys: () => {
        this.customKeyManager?.exportProfile();
      },
      onImportCustomKeys: () => {
        this.customKeyManager?.importProfile();
      },
      onToggleMouseEmulation: () => {
        this.gamepadManager.toggleMouseEmulation();
        const active = this.gamepadManager.isMouseEmulationActive();
        promptAction.showToast({
          message: active ? '手柄鼠标模拟已开启' : '手柄鼠标模拟已关闭',
          duration: 2000
        });
      },
      onControllerOpacityChange: (opacity: number) => {
        this.controllerOpacityValue = opacity;
        VirtualControllerOverlay.saveOpacity(opacity);
      },
      onControllerScaleChange: (scale: number) => {
        this.controllerScaleValue = scale;
        VirtualControllerOverlay.saveScale(scale);
      },
      onTouchPassthroughChange: (enabled: boolean) => {
        this.touchPassthrough = enabled;
      },
      onClose: () => {
        this.gameMenuDialogController?.close();
        if (this.pendingShowIME) {
          this.pendingShowIME = false;
          setTimeout(() => this.imeManager.show(), 300);
        }
      },
      onUnlockOverlay: () => {
        this.viewModel.overlayState.config.isLocked = false;
        this.viewModel.overlayState.configVersion++;
        AppStorage.setOrCreate('perf_overlay_locked', false);
        PreferencesUtil.put(SettingsKeys.PERF_OVERLAY_LOCKED, false);
        promptAction.showToast({ message: '已解锁覆盖层', duration: 1500 });
        this.gameMenuDialogController?.close();
      },
      onToggleWindowMode: async () => {
        await this.windowManager?.toggleWindowMode();
        this.recalculateXComponentSize();
      },
      onTogglePanZoom: () => {
        this.isTouchOverrideEnabled = !this.isTouchOverrideEnabled;
        promptAction.showToast({
          message: this.isTouchOverrideEnabled ? '画面缩放已开启，双指捏合缩放画面' : '画面缩放已关闭',
          duration: 2000
        });
      },
      onResetPanZoom: () => {
        this.panZoomHandler.reset();
        promptAction.showToast({ message: '缩放已重置', duration: 1500 });
      },
      onSwitchCustomKeyProfile: async (name: string) => {
        this.customKeyManager?.reset();
        const profile = await CustomKeyStore.switchProfile(name);
        if (profile) {
          this.customKeyProfileVersion++;
          // 保存游戏→配置关联
          if (this.appId > 0) {
            CustomKeyStore.setGameProfile(this.appId, profile.name);
          }
        }
      }
    };
  }

  /**
   * 显示串流菜单
   */
  showStreamMenu(): void {
    if (!this.menuManager) return;

    // 暂停鼠标全速轮询（Monitor 暂停 + DisplaySync 停止）
    this.inputHandler.stopMouseInterceptor();
    this.stopMouseKeepAlive();
    
    this.gameMenuDialogController = new CustomDialogController({
      builder: GameMenuDialog({
        viewModel: this.viewModel,
        superCmds: this.cmdList,
        isUsbDriverMode: !this.gamepadManager.isUsingGameControllerKit(),
        hasUsbGamepad: this.gamepadManager.hasUsbGamepad(),
        isMouseEmulationActive: this.gamepadManager.isMouseEmulationActive(),
        hasConnectedGamepad: this.gamepadManager.getConnectedGamepads().length > 0,
        isFullscreen: this.windowManager?.isFullscreen ?? true,
        controllerOpacity: this.controllerOpacityValue,
        controllerScale: this.controllerScaleValue,
        touchPassthrough: this.touchPassthrough,
        showCustomKeys: this.showCustomKeys,
        isPanZoomActive: this.isTouchOverrideEnabled,
        callbacks: this.buildGameMenuCallbacks()
      }),
      alignment: DialogAlignment.CenterEnd,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.gameMenuDialogController.open();
  }
  
  /**
   * 获取 XComponent 实际渲染宽度（vp）
   * 解析 Length 类型（'100%' 或数字）为实际 vp 值
   */
  private getXComponentWidthVp(): number {
    if (typeof this.xComponentWidth === 'string') {
      // '100%' 模式 — 优先使用 onAreaChange 缓存的实际尺寸
      return this.xComponentActualWidthVp > 0
        ? this.xComponentActualWidthVp
        : this.viewModel.displayInfo.screenWidth;
    }
    return this.xComponentWidth as number;
  }

  /**
   * 获取 XComponent 实际渲染高度（vp）
   */
  private getXComponentHeightVp(): number {
    if (typeof this.xComponentHeight === 'string') {
      return this.xComponentActualHeightVp > 0
        ? this.xComponentActualHeightVp
        : this.viewModel.displayInfo.screenHeight;
    }
    return this.xComponentHeight as number;
  }

  /**
   * 根据位置名称获取 ArkUI Alignment 枚举
   */
  private getAlignmentFromPosition(position: string): Alignment {
    switch (position) {
      case '左上': return Alignment.TopStart;
      case '上': return Alignment.Top;
      case '右上': return Alignment.TopEnd;
      case '左': return Alignment.Start;
      case '居中': return Alignment.Center;
      case '右': return Alignment.End;
      case '左下': return Alignment.BottomStart;
      case '下': return Alignment.Bottom;
      case '右下': return Alignment.BottomEnd;
      default: return Alignment.Center;
    }
  }

  /**
   * 更新画面位置和偏移（从 displayInfo 中读取设置）
   */
  private updateDisplayPosition(): void {
    this.xComponentAlignment = this.getAlignmentFromPosition(
      this.viewModel.displayInfo.screenPosition
    );
    // 将百分比偏移转换为 vp（基于 XComponent 实际尺寸）
    const baseWidth = this.getXComponentWidthVp();
    const baseHeight = this.getXComponentHeightVp();
    this.xComponentOffsetX = baseWidth * this.viewModel.displayInfo.screenOffsetX / 100;
    this.xComponentOffsetY = baseHeight * this.viewModel.displayInfo.screenOffsetY / 100;
  }

  /**
   * 重新计算 XComponent 尺寸（窗口模式切换/窗口大小变化后调用）
   */
  private async recalculateXComponentSize(): Promise<void> {
    if (!this.windowManager) return;

    if (this.windowManager.isFullscreen) {
      // 全屏：按屏幕尺寸精确计算 letterbox/pillarbox
      const size = this.windowManager.calculateXComponentSize(
        this.viewModel.displayInfo.stretchVideo
      );
      this.xComponentWidth = size.width;
      this.xComponentHeight = size.height;
    } else {
      // 窗口模式：直接填满窗口，视频缩放由 Surface 处理
      this.xComponentWidth = '100%';
      this.xComponentHeight = '100%';
    }
    // 更新画面位置和偏移
    this.updateDisplayPosition();
  }

  /**
   * 恢复鼠标全速轮询（对话框关闭后调用）
   */
  private resumeMouseInterceptor(): void {
    if (!this.viewModel.isConnected) return;
    const monitorOk = this.inputHandler.startMouseInterceptor(
      this.getXComponentWidthVp(),
      this.getXComponentHeightVp()
    );
    if (!monitorOk) {
      this.startMouseKeepAlive();
    }
  }

  /**
   * 启动鼠标高帧率保持
   *
   * 使用 DisplaySync 直接向系统合成器请求高刷新率，
   * 保持 ArkUI 渲染循环高帧率，使 .onMouse 以屏幕刷新率投递。
   * 仅在 C++ Mouse Monitor 不可用时使用。
   */
  private startMouseKeepAlive(): void {
    if (this.mouseDisplaySync) return;
    try {
      let deviceRefreshRate = 120;
      try {
        const displayInfo = display.getDefaultDisplaySync();
        deviceRefreshRate = Math.max(Math.round(displayInfo.refreshRate || 120), 60);
      } catch (_) {}

      this.mouseDisplaySync = displaySync.create();
      this.mouseDisplaySync.setExpectedFrameRateRange({
        min: 60,
        max: deviceRefreshRate,
        expected: deviceRefreshRate,
      });
      this.mouseDisplaySync.start();
      console.info(`StreamPage: DisplaySync 已启动（请求 60-${deviceRefreshRate}Hz 高刷新率）`);
    } catch (e) {
      console.warn('StreamPage: DisplaySync 创建失败:', JSON.stringify(e));
      this.mouseDisplaySync = null;
    }
  }

  /**
   * 停止鼠标高帧率保持
   */
  private stopMouseKeepAlive(): void {
    if (this.mouseDisplaySync) {
      try {
        this.mouseDisplaySync.stop();
      } catch (_) {}
      this.mouseDisplaySync = null;
      console.info('StreamPage: DisplaySync 已停止');
    }
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
              await this.shortcutManager.addShortcut(data.name, data.keys, data.icon, data.color, data.keySequence);
              promptAction.showToast({ message: `快捷键 "${data.name}" 已添加` });
            }
            this.resumeMouseInterceptor();
          },
          onCancel: () => {
            this.resumeMouseInterceptor();
          }
        }
      }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.shortcutEditorController.open();
  }
  
  /**
   * 循环切换自定义按键配置（SpecialAction 触发）
   */
  async cycleCustomKeyProfile(): Promise<void> {
    this.customKeyManager?.reset();
    const profile = await CustomKeyStore.cycleNextProfile();
    if (profile) {
      this.customKeyProfileVersion++;
      // 保存游戏→配置关联
      if (this.appId > 0) {
        CustomKeyStore.setGameProfile(this.appId, profile.name);
      }
      promptAction.showToast({ message: `已切换到: ${profile.name}`, duration: 1500 });
    } else {
      promptAction.showToast({ message: '仅有一个配置', duration: 1500 });
    }
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
  
  /**
   * 配置串流窗口（分辨率 → 窗口全屏 → 方向 → 屏幕尺寸 → XComponent 尺寸）
   * 初次连接和重连均需调用，避免遗漏步骤导致画面缩小/黑边
   */
  private async configureStreamWindow(): Promise<void> {
    // 设置串流分辨率
    this.windowManager?.setStreamResolution(
      this.viewModel.displayInfo.streamWidth,
      this.viewModel.displayInfo.streamHeight
    );

    // 确保窗口处于全屏沉浸模式
    await this.windowManager?.configureWindow();

    // 配置屏幕方向
    await this.windowManager?.configureOrientation();

    // 更新屏幕尺寸
    const screenSize = await this.windowManager?.updateScreenSize();
    if (screenSize) {
      this.viewModel.displayInfo.screenWidth = screenSize.width;
      this.viewModel.displayInfo.screenHeight = screenSize.height;
    }

    // 计算 XComponent 尺寸（letterbox/pillarbox）
    const xComponentSize = this.windowManager?.calculateXComponentSize(this.viewModel.displayInfo.stretchVideo);
    if (xComponentSize) {
      this.xComponentWidth = xComponentSize.width;
      this.xComponentHeight = xComponentSize.height;
      console.info(`StreamPage: XComponent 尺寸 = ${JSON.stringify(xComponentSize)}`);
    }

    // 应用画面位置和偏移
    this.updateDisplayPosition();
  }

  /**
   * 超分辨率状态 Toast：启动后提示用户超分是否生效
   */
  private showUpscaleToast(): void {
    const config = this.viewModel.streamConfig;
    if (!config || config.upscaleMode === 0) return;

    try {
      const d = display.getDefaultDisplaySync();
      const screenW = d.width;
      const screenH = d.height;
      const streamW = config.width;
      const streamH = config.height;

      // 计算 XComponent 实际像素尺寸（保持视频宽高比的 letterbox 区域）
      const videoAspectRatio = streamW / streamH;
      const screenAspectRatio = screenW / screenH;
      let outW: number, outH: number;
      if (screenAspectRatio > videoAspectRatio) {
        outH = screenH;
        outW = Math.floor(outH * videoAspectRatio);
      } else {
        outW = screenW;
        outH = Math.floor(outW / videoAspectRatio);
      }

      const activeNames: Record<number, string> = { 1: 'XEngine', 2: 'FSR 1' };
      const modeName = activeNames[this.viewModel.activeUpscaleMode] ?? '超分辨率';

      if (streamW < outW || streamH < outH) {
        promptAction.showToast({
          message: `${modeName} 超分已启用: ${streamW}×${streamH} → ${outW}×${outH}`,
          duration: 2500
        });
      } else {
        promptAction.showToast({
          message: `超分辨率未生效: 串流 ${streamW}×${streamH} ≥ 屏幕 ${outW}×${outH}`,
          duration: 2500
        });
      }
    } catch (_) {}
  }

  /**
   * 设置 XComponent 帧率 + 获取 surfaceId + 启动串流
   */
  private async launchStream(): Promise<void> {
    const surfaceId = this.xComponentController.getXComponentSurfaceId();

    // 设置 XComponent 期望帧率（通过 FrameNode → ArkUI_NodeHandle）
    // 解决 MatePad 等设备渲染帧率被锁定在 60fps 的问题
    const streamConfig = this.viewModel.streamConfig;
    if (streamConfig && streamConfig.fps > 60) {
      try {
        const frameNode = this.getUIContext().getFrameNodeById('streamSurface');
        if (frameNode) {
          MoonBridge.setXComponentFrameRate(frameNode, streamConfig.fps);
          console.info(`XComponent 帧率已设置为 ${streamConfig.fps} fps`);
        }
      } catch (e) {
        console.warn(`设置 XComponent 帧率失败: ${e}`);
      }
    }

    await this.viewModel.startStreaming(this.computerId, this.appId, surfaceId, this.context, this.displayGuid, this.useVdd);
  }

  async startStreaming(): Promise<void> {
    try {
      // 加载设置
      await this.viewModel.loadSettings();
      this.lifecycleManager.setLatencyToastEnabled(
        await PreferencesUtil.get<boolean>(SettingsKeys.LATENCY_TOAST, false)
      );
      this.lifecycleManager.setDisableWarnings(
        await PreferencesUtil.get<boolean>(SettingsKeys.DISABLE_WARNINGS, false)
      );
      this.enableBackgroundTask = await PreferencesUtil.get<boolean>(SettingsKeys.ENABLE_BACKGROUND_TASK, true);
      this.lifecycleManager.setEnableBackgroundTask(this.enableBackgroundTask);
      this.useVirtualKeyboard = await PreferencesUtil.get<boolean>(SettingsKeys.ENABLE_ONSCREEN_KEYBOARD, false);
      this.controllerScaleValue = await VirtualControllerOverlay.loadScale();
      this.controllerOpacityValue = await VirtualControllerOverlay.loadOpacity();
      await this.gamepadManager.reloadSettings();

      // 配置 ESC 菜单按键（可替换为 F1/F12/~ 等）
      const escMenuKey = await PreferencesUtil.get<string>(SettingsKeys.ESC_MENU_KEY, 'ESC');
      this.inputHandler.setMenuKey(escMenuKey);
      const enableEscMenu = await PreferencesUtil.get<boolean>(SettingsKeys.ENABLE_ESC_MENU, true);
      this.inputHandler.setEscMenuEnabled(enableEscMenu);

      // 初始化自定义按键存储
      await this.customKeyManager?.init();

      // 配置窗口（分辨率→全屏→方向→屏幕尺寸→XComponent 尺寸）
      await this.configureStreamWindow();

      // 设置 HDR 高亮度（如果启用）
      const streamConfig = this.viewModel.streamConfig;
      if (streamConfig) {
        await this.windowManager?.setHdrBrightness(streamConfig.hdr, streamConfig.hdrHighBrightness);
      }
      
      // 设置触摸输入模式
      const touchModeStr = this.viewModel.touchMode as string;
      this.touchInputHandler.setMode(touchModeStr as TouchInputMode);
      // 配置双击时间阈值和双击拖动
      if (streamConfig) {
        this.touchInputHandler.setDoubleTapTimeThreshold(streamConfig.doubleTapTimeThreshold);
        this.touchInputHandler.setEnableDoubleClickDrag(streamConfig.enableDoubleClickDrag);
      }
      
      // 设置连接终止回调
      this.viewModel.setConnectionTerminatedCallback((errorCode: number) => {
        this.lifecycleManager.handleConnectionTerminated(errorCode);
      });

      // 设置分辨率变化回调（服务端屏幕旋转/分辨率变化时同步客户端布局）
      this.viewModel.setResolutionChangedCallback((width: number, height: number) => {
        this.lifecycleManager.handleServerResolutionChanged(width, height);
      });

      // 获取 surfaceId → 设置帧率 → 启动串流
      await this.launchStream();

      // 超分辨率状态 Toast
      this.showUpscaleToast();

      // 启动后台保活（AVSession + 长时任务），防止退到后台时进程被冻结
      if (this.enableBackgroundTask) {
        await this.lifecycleManager.startBackgroundTask(this.context, this.appName || undefined);
      }

      // 启动按键拦截器（拦截被系统劫持的手柄按键，如蓝牙手柄 Home 键）
      if (this.viewModel.inputSettings?.enableKeyInterceptor) {
        this.inputHandler.startKeyInterceptor();
      }

      // 启动鼠标全速轮询：优先 C++ Monitor，不可用时 DisplaySync 兜底
      const monitorOk = this.inputHandler.startMouseInterceptor(
        this.getXComponentWidthVp(),
        this.getXComponentHeightVp()
      );
      if (!monitorOk) {
        this.startMouseKeepAlive();
      }

      // 初始化体感助手
      this.initializeGyroAssist();

      // 本地光标显示控制
      // showLocalCursor=true 时保持本地系统光标可见（双光标模式，需配合绝对鼠标模式使用）
      // showLocalCursor=false 时隐藏本地系统光标，仅显示远端视频流中的光标
      if (!this.viewModel.showLocalCursor) {
        try {
          pointer.setPointerVisibleSync(false);
          console.info('StreamPage: 已隐藏本地系统鼠标光标');
        } catch (e) {
          console.warn('StreamPage: 隐藏鼠标光标失败:', JSON.stringify(e));
        }
      } else {
        console.info('StreamPage: 本地光标模式已启用，保持系统光标可见');
      }
      
    } catch (err) {
      console.error('开始串流失败:', err);
    }
  }
  
  /**
   * 收归的退出串流并返回：恢复窗口、延迟、router.back()。
   * 供 stopStreaming / quitGameAndReturn 复用，避免重复逻辑。
   */
  private async exitStreamAndReturn(): Promise<void> {
    await this.windowManager?.restoreWindow();
    await new Promise<void>((resolve) => setTimeout(resolve, 150));
    router.back();
  }

  async stopStreaming(): Promise<void> {
    this.lifecycleManager.showLatencyToastIfEnabled();
    await this.lifecycleManager.stopBackgroundTask();
    this.inputHandler.resetState();
    this.stopMouseKeepAlive();
    try {
      pointer.setPointerVisibleSync(true);
    } catch (_) {}
    await this.exitStreamAndReturn();
    this.viewModel.stopStreaming();
  }

  /**
   * 退出游戏并返回（请求服务器退出当前游戏，先返回菜单再后台发退出请求）
   */
  async quitGameAndReturn(): Promise<void> {
    this.lifecycleManager.showLatencyToastIfEnabled();
    await this.lifecycleManager.stopBackgroundTask();

    // 退出前发送 Win+L 锁定主机屏幕，延迟确保命令送达
    if (this.viewModel.streamConfig?.lockScreenAfterDisconnect) {
      this.viewModel.getSession()?.sendKeys([0x5B, 0x4C]); // VK_LWIN + VK_L
      await new Promise<void>((resolve) => setTimeout(resolve, 500));
    }

    await this.exitStreamAndReturn();
    this.viewModel.quitGame().then(() => {}).catch((_err: Error) => {});
  }

  /**
   * 重连串流（后台保活关闭时从后台恢复使用）
   * 静默停止当前会话，然后重新启动串流，不导航离开页面
   */
  async reconnectStreaming(): Promise<void> {
    console.info('[StreamPage] 开始重连串流...');
    try {
      // 先停止当前会话（静默，不导航不显示 toast）
      await this.viewModel.stopStreaming();
      console.info('[StreamPage] 旧会话已停止，开始重新连接...');

      // 重新配置窗口和尺寸（与初次连接共用同一流程，避免画面缩小/黑边）
      await this.configureStreamWindow();

      // 获取 surfaceId → 设置帧率 → 启动串流
      await this.launchStream();
      console.info('[StreamPage] 重连串流成功');

      promptAction.showToast({ message: '已重新连接' });
    } catch (err) {
      console.error('[StreamPage] 重连串流失败:', err);
      promptAction.showToast({ message: '重连失败，请手动重试' });
    }
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
    sendShortcutKeys((keys: number[]) => session.sendKeys(keys), shortcut.keys, shortcut.keySequence);
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
    // 虚拟手柄显示时，默认不处理触摸输入（避免与虚拟按键手势竞争）
    // touchPassthrough 开启时允许共存
    if (this.viewModel.showController && !this.touchPassthrough) {
      return;
    }
    this.touchInputHandler.handleTouchEvent(event);
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
      // 视频渲染层 — 包裹在独立 Stack 中实现 9 宫格定位 + 偏移
      Stack() {
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
          .offset({ x: this.xComponentOffsetX, y: this.xComponentOffsetY })
          .hitTestBehavior((this.viewModel.showController && !this.touchPassthrough) ? HitTestMode.None : HitTestMode.Default)
          .onTouch((event: TouchEvent) => {
            // 过滤鼠标源触摸事件：物理鼠标点击会同时触发 .onMouse 和 .onTouch，
            // 鼠标事件已在 .onMouse 中处理，此处跳过避免重复发送为触摸
            if (event.source === SourceType.Mouse) return;
            // 双指缩放模式：触摸事件完全由 PanZoomHandler 消费
            if (this.isTouchOverrideEnabled) {
              this.panZoomHandler.handleTouchEvent(event);
              return;
            }
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
          .onAreaChange((_oldArea: Area, newArea: Area) => {
            // 更新 XComponent 实际渲染尺寸（窗口模式下 '100%' 的实际 vp 值）
            const w = newArea.width as number;
            const h = newArea.height as number;
            if (w > 0 && h > 0) {
              this.xComponentActualWidthVp = w;
              this.xComponentActualHeightVp = h;
              this.inputHandler.updateXComponentActualSize(w, h);
            }
            // 获取 XComponent 在屏幕上的精确位置，用于绝对模式鼠标坐标转换
            const globalPos = newArea.globalPosition;
            if (globalPos) {
              const screenX = globalPos.x as number;
              const screenY = globalPos.y as number;
              this.inputHandler.updateXComponentScreenPosition(screenX, screenY);
            }
          })
      }
      .width('100%')
      .height('100%')
      .alignContent(this.xComponentAlignment)
      .clip(true)
      .scale({
        x: this.videoScale,
        y: this.videoScale,
        centerX: 0,
        centerY: 0
      })
      .translate({
        x: this.videoTranslateX,
        y: this.videoTranslateY
      })

      // 连接状态层
      if (this.viewModel.isConnecting) {
        this.ConnectingOverlay()
      }

      // 错误提示层
      if (this.viewModel.hasError) {
        Column() {
          this.ErrorOverlay()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .position({ bottom: 48 })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 网络质量警告层（对齐 Android connectionStatusUpdate 行为）
      if (this.viewModel.isConnected && this.connectionPoor) {
        Column() {
          this.ConnectionWarningOverlay()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .position({ bottom: 48 })
        .hitTestBehavior(HitTestMode.None)
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
      if (this.viewModel.isConnected && this.viewModel.showController) {
        VirtualControllerOverlay({
          touchPassthrough: $touchPassthrough,
          controllerScale: $controllerScaleValue,
          controllerOpacity: $controllerOpacityValue,
          onlyL3R3: this.viewModel.inputSettings?.onlyL3R3 ?? false,
          showGuideButton: this.viewModel.inputSettings?.showGuideButton ?? true,
          vibrateOsc: this.viewModel.inputSettings?.vibrateOsc ?? true,
          halfHeightPortrait: this.viewModel.inputSettings?.halfHeightOscPortrait ?? true,
          onInput: (input) => {
            this.viewModel.sendInput(input);
          }
        })
      }

      // 自定义按键覆盖层
      if (this.showCustomKeys && this.viewModel.isConnected) {
        Column() {
          CustomKeyOverlay({
            editMode: $customKeyEditMode,
            profileVersion: this.customKeyProfileVersion,
            onKeyAction: (action: KeyAction, isDown: boolean): void => {
              this.customKeyManager?.handleAction(action, isDown);
            },
            onAnalogStickMovement: (stick: string, x: number, y: number): void => {
              this.customKeyManager?.handleAnalogStickMovement(stick, x, y);
            },
            onAnalogStickClick: (stick: string): void => {
              this.customKeyManager?.handleAnalogStickClick(stick);
            },
            onDPadDirectionChange: (direction: number): void => {
              this.customKeyManager?.handleDPadDirectionChange(direction);
            },
            onEditModeChanged: (editing: boolean): void => {
              this.customKeyEditMode = editing;
            },
            onProfileSwitched: (): void => {
              this.customKeyProfileVersion++;
              // 保存游戏→配置关联
              if (this.appId > 0) {
                CustomKeyStore.getActiveProfileName().then((name) => {
                  CustomKeyStore.setGameProfile(this.appId, name);
                });
              }
            },
            onAiRecommend: async (gameName: string): Promise<AiKeyRecommendation> => {
              if (!this.aiKeyService) {
                throw new Error('AI 服务不可用（未连接到 Sunshine）');
              }
              return this.aiKeyService.getRecommendation(gameName);
            },
          })
        }
          .width('100%')
          .height('100%')
          // 编辑模式: Default — 子组件正常交互，不穿透到游戏流
          // 游玩模式: Transparent — 空白区域穿透给 XComponent（按键自身 Block 阻断）
          .hitTestBehavior(this.customKeyEditMode ? HitTestMode.Default : HitTestMode.Transparent)
          .opacity(this.customKeyHitReady > 0 ? 1 : 0.99) // 父层刷新命中测试区域
      }

      // 移除悬浮菜单按钮，改用返回手势触发菜单

      // 系统键盘输入面板
      if (this.showKeyboardPanel) {
        this.KeyboardInputPanel()
      }

      // PC 虚拟键盘
      if (this.showVirtualKeyboard && this.viewModel.isConnected) {
        VirtualKeyboard({
          onVirtualKeyEvent: (vk: number, isDown: boolean): void => {
            const session = this.viewModel.getSession();
            if (session) {
              session.sendKeyboardInput(vk, isDown ? 0x03 : 0x04);
            }
          },
          onClose: (): void => {
            this.showVirtualKeyboard = false;
          },
        })
          .width('100%')
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
          Image($r('app.media.ic_keyboard'))
            .width(17)
            .height(17)
            .fillColor('#D0FFFFFF')

          Button('主机键盘')
            .fontSize(11)
            .fontColor('#FFFFFF')
            .backgroundColor('#3B82F6')
            .height(26)
            .borderRadius(13)
            .padding({ left: 10, right: 10 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => {
              this.viewModel.getSession()?.sendKeys([VirtualKey.VK_LWIN, VirtualKey.VK_CONTROL, VirtualKey.VK_O]);
              this.imeManager.hide();
            })

          // ── 切换到虚拟键盘 ──
          Button('虚拟键盘')
            .fontSize(11)
            .fontColor('#FFFFFF')
            .backgroundColor('#8B5CF6')
            .height(26)
            .borderRadius(13)
            .padding({ left: 10, right: 10 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => {
              this.imeManager.hide();
              this.showVirtualKeyboard = true;
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
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
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
                Image($r('app.media.ic_lightning'))
                  .width(11)
                  .height(11)
                  .fillColor('#F0FFFFFF')
                  .margin({ right: 3 })
                Text(cmd.name)
                  .fontSize(11)
                  .fontColor('#F0FFFFFF')
              }
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor('#50D97706')
              .border({ width: 1, color: '#80D97706' })
              .borderRadius(13)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .onClick(() => {
                this.sendSuperCmd(cmd.id);
              })
            }, (cmd: SuperCmd) => cmd.id)
          }
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Start)
      .padding({ left: 14, right: 16 })
      .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(20) })
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
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.85 })
      .onClick(() => {
        this.imeManager.hide();
      })
      .position({ right: 8, bottom: this.keyboardHeight + 44 })
  }

  @Builder
  ConnectionWarningOverlay() {
    Row({ space: 8 }) {
      Text('⚠')
        .fontSize(16)
        .fontColor('#FFFFB74D')
      Text(this.viewModel.streamConfig && this.viewModel.streamConfig.bitrate > 5000
        ? '网速慢，请尝试降低码率或使用有线连接'
        : '网络连接不稳定')
        .fontSize(13)
        .fontColor('#EEFFFFFF')
    }
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .borderRadius(20)
    .backgroundColor('#B01A1A2E')
    .backdropBlur(30)
    .border({ width: 1, color: '#18FFFFFF' })
    .shadow({ radius: 12, color: '#40000000', offsetY: 4 })
    .hitTestBehavior(HitTestMode.None)
    .transition(TransitionEffect.OPACITY.animation({ duration: 300 }))
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
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('✕')
          .fontSize(16)
          .fontColor('#FFEF5350')
        Text(this.viewModel.errorMessage)
          .fontSize(13)
          .fontColor('#EEFFFFFF')
          .constraintSize({ maxWidth: 280 })
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Text('返回')
        .fontSize(12)
        .fontColor('#EEFFFFFF')
        .padding({ left: 20, right: 20, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor('#30FFFFFF')
        .onClick(() => {
          router.back();
        })
    }
    .padding({ left: 20, right: 20, top: 14, bottom: 14 })
    .borderRadius(20)
    .backgroundColor('#B01A1A2E')
    .backdropBlur(30)
    .border({ width: 1, color: '#18FFFFFF' })
    .shadow({ radius: 12, color: '#40000000', offsetY: 4 })
    .transition(TransitionEffect.OPACITY.animation({ duration: 300 }))
  }
}
