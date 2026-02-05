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
import { VirtualController } from '../components/VirtualController';
import { PerformanceOverlay } from '../components/PerformanceOverlay';
import { OptionPickerDialog, OptionPickerDialogConfig } from '../components/OptionPickerDialog';
import { GameMenuDialog, GameMenuCallbacks } from '../components/GameMenuDialog';
import { StreamMenuManager } from '../components/StreamMenuManager';
import { StreamViewModel, StreamConnectionState, TouchMode } from '../viewmodel/StreamViewModel';
import { TouchInputHandler, TouchInputMode } from '../service/TouchInputHandler';
import { StreamWindowManager } from '../service/StreamWindowManager';
import { ShortcutManager, Shortcut } from '../components/ShortcutManager';
import { ShortcutEditorDialog, ShortcutEditorCallbacks, ShortcutEditData } from '../components/ShortcutEditorDialog';
import { GamepadManager, GamepadInputListener, GamepadState } from '../service/GamepadManager';
import { AppStateService, AppState } from '../service/AppStateService';
import { MoonBridge } from '../service/MoonBridge';
import { SuperCmd } from '../service/NvHttp';

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
  private appStateService: AppStateService = AppStateService.getInstance();
  
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
      onGamepadConnected: (deviceId: number, name: string) => {
        console.info(`手柄已连接: ${name} (ID: ${deviceId})`);
        promptAction.showToast({ message: `手柄已连接: ${name}` });
      },
      onGamepadDisconnected: (deviceId: number) => {
        console.info(`手柄已断开: ID ${deviceId}`);
        promptAction.showToast({ message: '手柄已断开' });
      },
      onGamepadInput: (deviceId: number, state: GamepadState) => {
        this.handleGamepadInput(deviceId, state);
      }
    });
  }
  
  /**
   * 处理手柄输入
   */
  private handleGamepadInput(deviceId: number, state: GamepadState): void {
    if (!this.viewModel.isConnected) {
      return;
    }
    
    // 直接发送完整的手柄状态
    this.viewModel.sendGamepadState(
      deviceId,
      state.buttons,
      state.leftStickX,
      state.leftStickY,
      state.rightStickX,
      state.rightStickY,
      state.leftTrigger,
      state.rightTrigger
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
    
    // 清理手柄监听并重置会话状态（防止内存泄漏和重复绑定）
    this.gamepadManager.setListener(null);
    this.gamepadManager.resetSession();
    
    // 恢复窗口设置
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
      
      // 获取 surfaceId 并开始串流
      const surfaceId = this.xComponentController.getXComponentSurfaceId();
      await this.viewModel.startStreaming(this.computerId, this.appId, surfaceId, this.context, this.displayGuid, this.useVdd);
      
    } catch (err) {
      console.error('开始串流失败:', err);
    }
  }
  
  async stopStreaming(): Promise<void> {
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
      if (this.viewModel.isConnected && this.viewModel.showController) {
        VirtualController({
          onInput: (input) => {
            this.viewModel.sendInput(input);
          }
        })
      }

      // 移除悬浮菜单按钮，改用返回手势触发菜单
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
      // 调试：打印鼠标/指针事件（可能包含手柄摇杆）
      console.info(`[GAMEPAD-MOUSE] MouseEvent: button=${event.button}, action=${event.action}, x=${event.x}, y=${event.y}`);
    })
  }

  // ==================== UI Builders ====================

  @Builder
  ConnectingOverlay() {
    Column() {
      LoadingProgress()
        .width(64)
        .height(64)
        .color($r('app.color.primary'))
      Text($r('app.string.connecting'))
        .fontSize(18)
        .fontColor(Color.White)
        .margin({ top: 16 })
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
