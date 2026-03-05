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
 * 串流游戏菜单弹窗 - 奶油风格 + 透明玻璃效果
 */
import { display, promptAction } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { LengthMetrics, ColorMetrics } from '@kit.ArkUI';
import { StreamViewModel } from '../viewmodel/StreamViewModel';
import { VirtualKey, sendShortcutKeys } from '../service/CustomKeyTypes';
import { ShortcutManager, Shortcut } from './ShortcutManager';
import { ActionDialog, ActionDialogConfig, ConfirmDialog, ConfirmDialogConfig } from './ConfirmDialog';
import { SuperCmd } from '../service/NvHttp';
import { GyroAssistService, GYRO_ACTIVATION_ALWAYS, GYRO_ACTIVATION_LT, GYRO_ACTIVATION_RT } from '../service/GyroAssistService';
import { SettingsKeys } from '../service/SettingsService';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { DeviceSensorService } from '../service/DeviceSensorService';
import {
  OV_ACCENT_BLUE, OV_ACCENT_PINK, OV_ACCENT_RED,
  OV_TEXT_BRIGHT, OV_TEXT_MEDIUM, OV_TEXT_DIM, OV_TEXT_FAINT, OV_TEXT_WHITE, OV_TEXT_ULTRA,
  OV_BG_TRACK, OV_BG_CARD_LIGHT, OV_BG_CARD_LIGHTER, OV_BG_DIVIDER,
  OV_BG_CARD_DARK, OV_BG_CARD_DARKER, OV_SHADOW_MEDIUM, OV_SHADOW_LIGHT,
  OV_BLUE_40, OV_BLUE_50,
  OV_FONT_XS, OV_FONT_SM, OV_FONT_MD, OV_FONT_LG,
  OV_CARD_WIDTH, OV_CARD_RADIUS, OV_CARD_BLUR,
} from '../common/OverlayConstants';

/** 菜单回调接口 */
export interface GameMenuCallbacks {
  onDismiss: () => void;
  onDisconnect: () => void;
  onQuitGame: () => void;
  onTouchModeChanged: (mode: string) => void;
  onOpenShortcutEditor?: () => void;
  onEditShortcut?: (shortcut: Shortcut) => void;
  onDeleteShortcut?: (shortcut: Shortcut) => void;
  onSendSuperCmd?: (cmdId: string) => void;
  onForceUsbDriver?: () => void;
  onToggleKeyboard?: () => void;
  onToggleMouseEmulation?: () => void;
  onControllerOpacityChange?: (opacity: number) => void;
  onControllerScaleChange?: (scale: number) => void;
  onTouchPassthroughChange?: (enabled: boolean) => void;
  onClose?: () => void;
  onUnlockOverlay?: () => void;
  onToggleWindowMode?: () => void;
  onToggleCustomKeys?: () => void;
  onEditCustomKeys?: () => void;
  onExportCustomKeys?: () => void;
  onImportCustomKeys?: () => void;
}

/** 菜单项配置 */
interface MenuItem {
  icon: string;
  label: string;
  bgColor: string;
  borderColor: string;
}

/** 触摸模式选项 */
interface TouchModeOption {
  key: string;
  text: string;
  subtitle: string;
}

/** 动作项配置 */
interface ActionItem {
  text: string;
  subtitle: string;
  color?: string;
  backgroundColor?: string;
  onClick: () => void;
}

// 常量定义
const BUTTON_CARD_SIZE = 70;
const ANIMATION_STAGGER_DELAY = 50;
const ANIMATION_DURATION_IN = 200;
const ANIMATION_DURATION_OUT = 200;
const BITRATE_DEBOUNCE_MS = 500;
const MENU_ITEM_COUNT = 7;

// 马卡龙色系菜单配置
const MENU_ITEMS: MenuItem[] = [
  { icon: '✦', label: 'HDR', bgColor: '#F7EBC7', borderColor: '#D0A850' },
  { icon: '◎', label: 'USB驱动', bgColor: '#F7D1D1', borderColor: '#D87070' },
  { icon: '⌨', label: '键盘', bgColor: '#C7F7E0', borderColor: '#50C080' },
  { icon: '☝', label: '触控', bgColor: '#E0D4F7', borderColor: '#9080C0' },
  { icon: '🎮', label: '手柄', bgColor: '#D4E8F7', borderColor: '#6098C0' },
  { icon: '🖱', label: '鼠标', bgColor: '#F7E0C7', borderColor: '#C08050' },
  { icon: '✕', label: '退出', bgColor: '#F7CFCF', borderColor: '#D06060' }
];

const MENU_OFFSETS: number[] = [25, 55, 70, 35, 45, 30, 50];

// 激活色
const ACTIVE_BG_COLOR = '#C7F7D4';
const ACTIVE_BORDER_COLOR = '#50A860';

@CustomDialog
export struct GameMenuDialog {
  controller: CustomDialogController;
  viewModel: StreamViewModel = new StreamViewModel();
  callbacks: GameMenuCallbacks = {
    onDismiss: () => {},
    onDisconnect: () => {},
    onQuitGame: () => {},
    onTouchModeChanged: () => {}
  };
  superCmds: SuperCmd[] = [];
  isUsbDriverMode: boolean = false;
  hasUsbGamepad: boolean = false;
  isMouseEmulationActive: boolean = false;
  hasConnectedGamepad: boolean = false;
  isFullscreen: boolean = true;
  controllerOpacity: number = 0.75;
  controllerScale: number = 1.0;
  touchPassthrough: boolean = false;
  showCustomKeys: boolean = false;

  // 动画状态
  @State private positions: number[] = Array(MENU_ITEM_COUNT).fill(200);
  @State private scales: number[] = Array(MENU_ITEM_COUNT).fill(1.0);

  // 二级菜单状态
  @State private expandedMenu: string = '';

  // 快捷键
  @State private shortcuts: Shortcut[] = [];
  private shortcutManager = ShortcutManager.getInstance();

  // 码率调整状态
  @State private currentBitrate: number = 0;
  @State private bitrateSliderValue: number = 0;
  @State private isAdjustingBitrate: boolean = false;
  private bitrateDebounceTimer: number = -1;

  // 体感助手状态
  @State private gyroEnabled: boolean = false;
  @State private gyroSensitivity: number = 1.0;
  @State private gyroInvertX: boolean = false;
  @State private gyroInvertY: boolean = false;
  @State private gyroActivationKey: number = GYRO_ACTIVATION_ALWAYS;
  private hasGyroscope: boolean = false;

  // 关闭动画状态
  private isClosing: boolean = false;

  // 布局判断：屏幕 2/3 宽度能否放下两列卡片
  @State private useTwoColumns: boolean = true;
  // 深浅主题（自动跟随系统切换）
  @StorageProp('colorMode') currentColorMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;

  // 虚拟手柄设置本地状态（拖动 Slider 时实时回调）
  @State private controllerOpacityLocal: number = 0.75;
  @State private controllerScaleLocal: number = 1.0;
  @State private touchPassthroughLocal: boolean = false;

  // 弹窗控制器
  private exitDialogController?: CustomDialogController;
  private touchModeDialogController?: CustomDialogController;
  private usbDriverDialogController?: CustomDialogController;

  aboutToAppear(): void {
    this.shortcuts = this.shortcutManager.getShortcuts();
    this.currentBitrate = this.viewModel.getCurrentBitrate();
    this.bitrateSliderValue = this.bitrateToSliderValue(this.currentBitrate);
    this.controllerOpacityLocal = this.controllerOpacity;
    this.controllerScaleLocal = this.controllerScale;
    this.touchPassthroughLocal = this.touchPassthrough;
    this.loadGyroSettings();
    this.detectLayoutMode();
    this.animateIn();
  }

  /**
   * 根据屏幕宽度的 2/3 是否能容纳两列卡片来决定布局
   * 两列所需宽度 = OV_CARD_WIDTH * 2 + 间距 + 内边距
   */
  private detectLayoutMode(): void {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      const vpWidth = displayInfo.width / displayInfo.densityPixels;
      const twoColumnMinWidth = (OV_CARD_WIDTH * 2 + 12 + 32); // 两列卡片 + 间距 + 左右内边距
      this.useTwoColumns = (vpWidth * 2 / 3) >= twoColumnMinWidth;
    } catch (_) {}
  }

  /** 当前是否深色主题，直接在布局中使用以确保 ArkTS 响应式更新 */
  // COLOR_MODE_LIGHT = 1; 深色时黑透卡片，浅色时白透卡片
  isCurrentDark(): boolean {
    return this.currentColorMode !== 1;
  }

  private animateIn(): void {
    for (let i = 0; i < MENU_ITEM_COUNT; i++) {
      setTimeout(() => {
        animateTo({
          duration: ANIMATION_DURATION_IN,
          curve: Curve.FastOutSlowIn,
        }, () => {
          this.positions[i] = 0;
        });
      }, i * ANIMATION_STAGGER_DELAY);
    }
  }

  private animateOut(): void {
    if (this.isClosing) return;
    this.isClosing = true;

    const callbacks = this.callbacks;

    animateTo({
      duration: ANIMATION_DURATION_OUT,
      curve: Curve.FastOutLinearIn
    }, () => {
      for (let i = 0; i < MENU_ITEM_COUNT; i++) {
        this.positions[i] = 200;
      }
    });

    setTimeout(() => {
      callbacks.onClose?.();
      callbacks.onDismiss();
    }, ANIMATION_DURATION_OUT + 50);
  }

  private sendKeys(keys: number[]): void {
    this.viewModel.getSession()?.sendKeys(keys);
  }

  private sendShortcut(shortcut: Shortcut): void {
    const session = this.viewModel.getSession();
    if (session) {
      sendShortcutKeys((keys: number[]) => session.sendKeys(keys), shortcut.keys, shortcut.keySequence);
    }
  }

  // 码率辅助方法
  private bitrateToSliderValue(bitrate: number): number {
    return Math.max(0, Math.min(1995, Math.round((bitrate - 500) / 100)));
  }

  private sliderValueToBitrate(value: number): number {
    return value * 100 + 500;
  }

  private formatBitrate(kbps: number): string {
    return kbps >= 1000 ? `${(kbps / 1000).toFixed(0)} Mbps` : `${kbps} kbps`;
  }

  private applyBitrateChange(): void {
    if (this.bitrateDebounceTimer !== -1) {
      clearTimeout(this.bitrateDebounceTimer);
    }

    this.bitrateDebounceTimer = setTimeout(async () => {
      const newBitrate = this.sliderValueToBitrate(this.bitrateSliderValue);
      this.isAdjustingBitrate = true;

      try {
        const success = await this.viewModel.setBitrate(newBitrate);
        if (success) {
          this.currentBitrate = newBitrate;
          promptAction.showToast({ message: `码率已调整为 ${this.formatBitrate(newBitrate)}`, duration: 2000 });
        } else {
          this.bitrateSliderValue = this.bitrateToSliderValue(this.currentBitrate);
          promptAction.showToast({ message: '码率调整失败', duration: 2000 });
        }
      } catch (err) {
        this.bitrateSliderValue = this.bitrateToSliderValue(this.currentBitrate);
        promptAction.showToast({ message: `码率调整失败: ${(err as Error).message}`, duration: 2000 });
      } finally {
        this.isAdjustingBitrate = false;
        this.bitrateDebounceTimer = -1;
      }
    }, BITRATE_DEBOUNCE_MS);
  }

  private showExitDialog(): void {
    const callbacks = this.callbacks;
    const actions: ActionItem[] = [];

    // 窗口/全屏切换 - 仅在 2in1 设备（支持自由窗口模式）上显示
    if (deviceInfo.deviceType === '2in1') {
      actions.push({
        text: this.isFullscreen ? '窗口模式' : '全屏模式',
        subtitle: this.isFullscreen ? '切换到悬浮窗口，方便多任务' : '切换到沉浸式全屏',
        color: '#8B5CF6',
        backgroundColor: '#F5F3FF',
        onClick: () => {
          callbacks.onToggleWindowMode?.();
          callbacks.onClose?.();
        }
      });
    }

    actions.push(
      {
        text: '断开连接',
        subtitle: '游戏继续在主机上运行',
        color: '#3B82F6',
        backgroundColor: '#EFF6FF',
        onClick: () => {
          callbacks.onDisconnect();
          callbacks.onClose?.();
        }
      },
      {
        text: '退出游戏',
        subtitle: '关闭主机上的游戏',
        color: '#EF4444',
        backgroundColor: '#FEF2F2',
        onClick: () => {
          callbacks.onQuitGame();
          callbacks.onClose?.();
        }
      }
    );
    const config: ActionDialogConfig = {
      title: '离开串流',
      actions: actions,
      cancelText: '继续游戏',
      onCancel: () => {}
    };

    this.exitDialogController = new CustomDialogController({
      builder: ActionDialog({ config }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.exitDialogController.open();
  }

  private showTouchModeDialog(): void {
    const currentMode = this.viewModel.touchMode;
    const modes: TouchModeOption[] = [
      { key: 'trackpad', text: '触控板', subtitle: '像笔记本触控板一样操作' },
      { key: 'direct', text: '多点触控', subtitle: '直接点击屏幕位置' },
      { key: 'mouse', text: '鼠标模式', subtitle: '模拟鼠标移动和点击' }
    ];

    const actions: ActionItem[] = modes.map((mode: TouchModeOption): ActionItem => {
      const item: ActionItem = {
        text: mode.text,
        subtitle: currentMode === mode.key ? '✓ 当前模式' : mode.subtitle,
        color: currentMode === mode.key ? '#10B981' : undefined,
        backgroundColor: currentMode === mode.key ? '#D1FAE5' : undefined,
        onClick: () => this.callbacks.onTouchModeChanged(mode.key)
      };
      return item;
    });

    const config: ActionDialogConfig = {
      title: '选择触摸模式',
      actions: actions,
      cancelText: '取消',
      onCancel: () => {}
    };

    this.touchModeDialogController = new CustomDialogController({
      builder: ActionDialog({ config }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.touchModeDialogController.open();
  }

  private showUsbDriverDialog(): void {
    const config: ConfirmDialogConfig = {
      title: '强制 USB 驱动接管',
      message: '放弃系统手柄接口 (GCK)，改由 USB 驱动直接处理手柄输入。\n\n仅在手柄输入异常或需要 USB 低延迟时使用。蓝牙手柄不受此选项影响。\n\n当前连接的 USB 手柄会短暂断开并重新连接。',
      cancelButton: { text: '取消', onClick: () => {} },
      confirmButton: {
        text: '接管',
        color: '#3B82F6',
        onClick: () => {
          this.callbacks.onForceUsbDriver?.();
          this.animateOut();
        }
      }
    };

    this.usbDriverDialogController = new CustomDialogController({
      builder: ConfirmDialog({ config }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.usbDriverDialogController.open();
  }

  private handleMenuClick(index: number): void {
    switch (index) {
      case 0:
        this.sendKeys([VirtualKey.VK_LWIN, VirtualKey.VK_MENU, VirtualKey.VK_B]);
        this.animateOut();
        break;
      case 1:
        if (this.isUsbDriverMode) {
          promptAction.showToast({ message: '当前已是 USB 驱动模式', duration: 2000 });
        } else {
          this.showUsbDriverDialog();
        }
        break;
      case 2:
        this.callbacks.onToggleKeyboard?.();
        this.animateOut();
        break;
      case 3:
        this.showTouchModeDialog();
        break;
      case 4:
        this.viewModel.toggleController();
        this.animateOut();
        break;
      case 5:
        this.callbacks.onToggleMouseEmulation?.();
        this.animateOut();
        break;
      case 6:
        this.showExitDialog();
        break;
    }
  }

  private getMenuLabel(index: number): string {
    if (index === 1 && this.isUsbDriverMode) return 'USB驱动 ✓';
    if (index === 5 && this.isMouseEmulationActive) return '鼠标 ✓';
    return MENU_ITEMS[index].label;
  }

  private getMenuBgColor(index: number): string {
    if ((index === 1 && this.isUsbDriverMode) || (index === 5 && this.isMouseEmulationActive)) {
      return ACTIVE_BG_COLOR;
    }
    return MENU_ITEMS[index].bgColor;
  }

  private getMenuBorderColor(index: number): string {
    if ((index === 1 && this.isUsbDriverMode) || (index === 5 && this.isMouseEmulationActive)) {
      return ACTIVE_BORDER_COLOR;
    }
    return MENU_ITEMS[index].borderColor;
  }

  private async loadGyroSettings(): Promise<void> {
    this.hasGyroscope = DeviceSensorService.getInstance().hasGyroscope();
    const gyroAssist = GyroAssistService.getInstance();
    this.gyroEnabled = gyroAssist.enabled;
    this.gyroSensitivity = gyroAssist.sensitivityMultiplier;
    this.gyroInvertX = gyroAssist.invertX;
    this.gyroInvertY = gyroAssist.invertY;
    this.gyroActivationKey = gyroAssist.activationKey;
  }

  private async saveGyroSetting(key: string, value: string | boolean | number): Promise<void> {
    try {
      await PreferencesUtil.put(key, value);
    } catch (error) {
      console.error('[GyroAssist] 保存设置失败:', error);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 背景可点击关闭
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          if (this.expandedMenu === '') {
            this.animateOut();
          } else {
            this.expandedMenu = '';
          }
        })

      // 右侧菜单按钮
      Column() {
        this.SockButton(0)
        if (this.hasUsbGamepad) this.SockButton(1)
        this.SockButton(2)
        this.SockButton(3)
        if (this.viewModel.inputSettings?.enableOnscreenControls) this.SockButton(4)
        if (this.hasConnectedGamepad) this.SockButton(5)
        this.SockButton(6)
      }
      .alignItems(HorizontalAlign.End)
      .justifyContent(FlexAlign.Center)
      .padding({ top: 20, bottom: 20 })
      .position({ x: '100%', y: '50%' })
      .translate({ x: '-100%', y: '-50%' })

      // 左侧面板
      if (this.useTwoColumns) {
        this.TwoColumnLayout()
      } else {
        this.SingleColumnLayout()
      }

      // 二级菜单遮罩
      if (this.expandedMenu !== '') {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000099')
          .onClick(() => { this.expandedMenu = ''; })
      }
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.OPACITY.animation({ duration: ANIMATION_DURATION_IN, curve: Curve.EaseOut })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }).animation({ duration: ANIMATION_DURATION_IN, curve: Curve.EaseOut })))
  }

  @Builder
  TwoColumnLayout() {
    Scroll() {
      Row({ space: 12 }) {
        Column({ space: 12 }) {
          if (this.shortcuts.length > 0) this.ShortcutCard()
          if (this.superCmds.length > 0) this.SuperCmdCard()
        }
        .alignItems(HorizontalAlign.Start)

        Column({ space: 12 }) {
          this.BitrateCard()
          this.CustomKeyCard()
          if (this.viewModel.inputSettings?.enableOnscreenControls) this.VirtualControllerCard()
          if (this.hasGyroscope) this.GyroAssistCard()
          if (this.viewModel.overlayState.config.isLocked) this.UnlockOverlayCard()
        }
        .alignItems(HorizontalAlign.Start)
      }
      .alignItems(VerticalAlign.Top)
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Vertical)
    .edgeEffect(EdgeEffect.Spring)
    .padding({ top: 20, bottom: 20, left: 16, right: 16 })
    .constraintSize({ maxHeight: '85%' })
    .position({ x: 16, y: '50%' })
    .translate({ y: '-50%' })
  }

  @Builder
  SingleColumnLayout() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.shortcuts.length > 0) this.ShortcutCard()
        if (this.superCmds.length > 0) this.SuperCmdCard()
        this.BitrateCard()
        this.CustomKeyCard()
        if (this.viewModel.inputSettings?.enableOnscreenControls) this.VirtualControllerCard()
        if (this.hasGyroscope) this.GyroAssistCard()
        if (this.viewModel.overlayState.config.isLocked) this.UnlockOverlayCard()
      }
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Vertical)
    .edgeEffect(EdgeEffect.Spring)
    .padding({ top: 20, bottom: 20, left: 16, right: 16 })
    .constraintSize({ maxHeight: '85%' })
    .position({ x: 16, y: '50%' })
    .translate({ y: '-50%' })
  }

  @Builder
  ButtonCardContent(icon: string, label: string) {
    Column() {
      Text(icon).fontSize(20)
      Text(label)
        .fontSize(OV_FONT_MD)
        .fontWeight(FontWeight.Medium)
        .fontColor(OV_TEXT_BRIGHT)
        .margin({ top: 4 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  UnlockOverlayCard() {
    Column() {
      this.ButtonCardContent('🔓', '解锁性能覆盖层')
    }
    .width(BUTTON_CARD_SIZE)
    .height(BUTTON_CARD_SIZE)
    .padding(10)
    .backgroundColor(this.isCurrentDark() ? OV_BG_CARD_DARK : OV_BG_CARD_LIGHT)
    .backdropBlur(OV_CARD_BLUR)
    .borderRadius(OV_CARD_RADIUS)
    .border({ width: 1, color: this.isCurrentDark() ? OV_BG_CARD_DARKER : OV_BG_CARD_LIGHTER })
    .shadow({ radius: 12, color: this.isCurrentDark() ? OV_SHADOW_MEDIUM : OV_SHADOW_LIGHT, offsetY: 2 })
    .onClick(() => {
      this.callbacks.onUnlockOverlay?.();
      this.callbacks.onClose?.();
    })
  }

  @Builder
  CustomKeyCard() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.crown'))
          .fontSize(14).fontColor([Color.Orange])
        Text(' 自定义按键')
          .fontSize(OV_FONT_LG)
          .fontWeight(FontWeight.Medium)
          .fontColor(OV_TEXT_BRIGHT)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.showCustomKeys })
          .selectedColor(OV_ACCENT_PINK)
          .switchPointColor(OV_TEXT_WHITE)
          .width(40)
          .height(22)
          .onChange((isOn: boolean) => {
            if (isOn !== this.showCustomKeys) {
              this.showCustomKeys = isOn;
              this.callbacks.onToggleCustomKeys?.();
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 4 })

      Text('自由放置的屏幕虚拟按键')
        .fontSize(OV_FONT_SM)
        .fontColor(OV_TEXT_FAINT)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 10 })

      Row({ space: 8 }) {
        Text('编辑布局')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(OV_ACCENT_PINK)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(14)
          .backgroundColor('#20FFB7C5')
          .border({ width: 1, color: '#40FFB7C5' })
          .onClick(() => {
            this.callbacks.onEditCustomKeys?.();
            this.animateOut();
          })
        Text('导出')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(OV_ACCENT_BLUE)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(14)
          .backgroundColor('#20A8D8EA')
          .border({ width: 1, color: OV_BLUE_40 })
          .onClick(() => {
            this.callbacks.onExportCustomKeys?.();
            this.animateOut();
          })
        Text('导入')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(OV_ACCENT_BLUE)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(14)
          .backgroundColor('#20A8D8EA')
          .border({ width: 1, color: OV_BLUE_40 })
          .onClick(() => {
            this.callbacks.onImportCustomKeys?.();
            this.animateOut();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ bottom: 14 })
    }
    .width(OV_CARD_WIDTH)
    .backgroundColor(this.isCurrentDark() ? OV_BG_CARD_DARK : OV_BG_CARD_LIGHT)
    .backdropBlur(OV_CARD_BLUR)
    .borderRadius(OV_CARD_RADIUS)
    .border({ width: 1, color: this.isCurrentDark() ? OV_BG_CARD_DARKER : OV_BG_CARD_LIGHTER })
    .shadow({ radius: 12, color: this.isCurrentDark() ? OV_SHADOW_MEDIUM : OV_SHADOW_LIGHT, offsetY: 2 })
  }

  @Builder
  VirtualControllerCard() {
    Column() {
      Row() {
        Text('🎮').fontSize(OV_FONT_LG)
        Text(' 虚拟手柄')
          .fontSize(OV_FONT_LG)
          .fontWeight(FontWeight.Medium)
          .fontColor(OV_TEXT_BRIGHT)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.showController })
          .selectedColor(OV_ACCENT_BLUE)
          .switchPointColor(OV_TEXT_WHITE)
          .width(40)
          .height(22)
          .onChange((isOn: boolean) => {
            if (isOn !== this.viewModel.showController) {
              this.viewModel.toggleController();
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 4 })

      Text('屏幕虚拟手柄叠加层')
        .fontSize(OV_FONT_SM)
        .fontColor(OV_TEXT_FAINT)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: this.viewModel.showController ? 8 : 14 })

      if (this.viewModel.showController) {
        Row().width('85%').height(1).backgroundColor(OV_BG_DIVIDER)

        // 触摸穿透开关
        Row() {
          Text('触摸穿透').fontSize(OV_FONT_MD).fontColor(OV_TEXT_MEDIUM)
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.touchPassthroughLocal })
            .selectedColor(OV_ACCENT_BLUE)
            .switchPointColor(OV_TEXT_WHITE)
            .width(36)
            .height(20)
            .onChange((isOn: boolean) => {
              this.touchPassthroughLocal = isOn;
              this.callbacks.onTouchPassthroughChange?.(isOn);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 10, bottom: 4 })

        Text('允许触摸穿透手柄操控画面')
          .fontSize(OV_FONT_XS)
          .fontColor('#50FFFFFF')
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 4 })

        Row().width('85%').height(1).backgroundColor(OV_BG_DIVIDER)

        // 透明度
        Column() {
          Row() {
            Text('透明度').fontSize(OV_FONT_MD).fontColor(OV_TEXT_MEDIUM)
            Blank()
            Text(`${Math.round(this.controllerOpacityLocal * 100)}%`)
              .fontSize(OV_FONT_MD)
              .fontColor(OV_ACCENT_BLUE)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .padding({ bottom: 4 })

          Slider({
            value: this.controllerOpacityLocal * 100,
            min: 20,
            max: 100,
            step: 5,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .blockColor(OV_ACCENT_BLUE)
            .blockSize({ width: 12, height: 12 })
            .trackColor(OV_BG_TRACK)
            .selectedColor(OV_ACCENT_BLUE)
            .showSteps(false)
            .showTips(false)
            .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.controllerOpacityLocal = value / 100;
              this.callbacks.onControllerOpacityChange?.(this.controllerOpacityLocal);
            })

          Row() {
            Text('20%').fontSize(OV_FONT_XS).fontColor(OV_TEXT_FAINT)
            Blank()
            Text('100%').fontSize(OV_FONT_XS).fontColor(OV_TEXT_FAINT)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 4 })

        Row().width('85%').height(1).backgroundColor(OV_BG_DIVIDER)

        // 大小调整
        Column() {
          Row() {
            Text('大小').fontSize(OV_FONT_MD).fontColor(OV_TEXT_MEDIUM)
            Blank()
            Text(`${Math.round(this.controllerScaleLocal * 100)}%`)
              .fontSize(OV_FONT_MD)
              .fontColor(OV_ACCENT_BLUE)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .padding({ bottom: 4 })

          Slider({
            value: this.controllerScaleLocal * 100,
            min: 50,
            max: 200,
            step: 10,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .blockColor(OV_ACCENT_BLUE)
            .blockSize({ width: 12, height: 12 })
            .trackColor(OV_BG_TRACK)
            .selectedColor(OV_ACCENT_BLUE)
            .showSteps(false)
            .showTips(false)
            .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.controllerScaleLocal = Math.round(value) / 100;
              this.callbacks.onControllerScaleChange?.(this.controllerScaleLocal);
            })

          Row() {
            Text('50%').fontSize(OV_FONT_XS).fontColor(OV_TEXT_FAINT)
            Blank()
            Text('200%').fontSize(OV_FONT_XS).fontColor(OV_TEXT_FAINT)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 12 })
      }
    }
    .width(OV_CARD_WIDTH)
    .backgroundColor(this.isCurrentDark() ? OV_BG_CARD_DARK : OV_BG_CARD_LIGHT)
    .backdropBlur(OV_CARD_BLUR)
    .borderRadius(OV_CARD_RADIUS)
    .border({ width: 1, color: this.isCurrentDark() ? OV_BG_CARD_DARKER : OV_BG_CARD_LIGHTER })
    .shadow({ radius: 12, color: this.isCurrentDark() ? OV_SHADOW_MEDIUM : OV_SHADOW_LIGHT, offsetY: 2 })
  }

  @Builder
  BitrateCard() {
    Column() {
      Row() {
        Text('📊').fontSize(OV_FONT_LG)
        Text(' 码率调整')
          .fontSize(OV_FONT_LG)
          .fontWeight(FontWeight.Medium)
          .fontColor(OV_TEXT_BRIGHT)
        Blank()
        Text(this.formatBitrate(this.currentBitrate))
          .fontSize(12)
          .fontColor(OV_ACCENT_PINK)
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 4 })

      Text('实时调整串流画质，需 Foundation Sunshine 支持')
        .fontSize(OV_FONT_SM)
        .fontColor(OV_TEXT_FAINT)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

      Column() {
        Slider({
          value: this.bitrateSliderValue,
          min: 0,
          max: 1995,
          step: 1,
          style: SliderStyle.OutSet
        })
          .width('100%')
          .blockColor(OV_ACCENT_PINK)
          .trackColor(OV_BG_TRACK)
          .selectedColor(OV_ACCENT_PINK)
          .showSteps(false)
          .showTips(false)
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.bitrateSliderValue = value;
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.applyBitrateChange();
            }
          })

        Row() {
          Text('0.5').fontSize(OV_FONT_SM).fontColor(OV_TEXT_DIM)
          Blank()
          Text(this.isAdjustingBitrate ? '调整中...' : this.formatBitrate(this.sliderValueToBitrate(this.bitrateSliderValue)))
            .fontSize(OV_FONT_MD)
            .fontColor(this.isAdjustingBitrate ? OV_TEXT_DIM : OV_ACCENT_PINK)
            .fontWeight(FontWeight.Bold)
          Blank()
          Text('200').fontSize(OV_FONT_SM).fontColor(OV_TEXT_DIM)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 14, right: 14, bottom: 12 })
    }
    .width(OV_CARD_WIDTH)
    .backgroundColor(this.isCurrentDark() ? OV_BG_CARD_DARK : OV_BG_CARD_LIGHT)
    .backdropBlur(OV_CARD_BLUR)
    .borderRadius(OV_CARD_RADIUS)
    .border({ width: 1, color: this.isCurrentDark() ? OV_BG_CARD_DARKER : OV_BG_CARD_LIGHTER })
    .shadow({ radius: 12, color: this.isCurrentDark() ? OV_SHADOW_MEDIUM : OV_SHADOW_LIGHT, offsetY: 2 })
  }

  @Builder
  GyroAssistCard() {
    Column() {
      Row() {
        Text('🎮').fontSize(OV_FONT_LG)
        Text(' 体感助手')
          .fontSize(OV_FONT_LG)
          .fontWeight(FontWeight.Medium)
          .fontColor(OV_TEXT_BRIGHT)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.gyroEnabled })
          .selectedColor(OV_ACCENT_BLUE)
          .switchPointColor(OV_TEXT_WHITE)
          .width(40)
          .height(22)
          .onChange((isOn: boolean) => {
            this.gyroEnabled = isOn;
            GyroAssistService.getInstance().setEnabled(isOn);
            this.saveGyroSetting(SettingsKeys.GYRO_ASSIST_ENABLED, isOn);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 4 })

      Text(this.hasGyroscope ? '陀螺仪 → 右摇杆映射' : '⚠ 设备无陀螺仪')
        .fontSize(OV_FONT_SM)
        .fontColor(this.hasGyroscope ? OV_TEXT_FAINT : OV_ACCENT_PINK)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: this.gyroEnabled ? 8 : 14 })

      if (this.gyroEnabled) {
        Row().width('85%').height(1).backgroundColor(OV_BG_DIVIDER)

        Column() {
          Row() {
            Text('灵敏度').fontSize(OV_FONT_MD).fontColor(OV_TEXT_MEDIUM)
            Blank()
            Text(`${this.gyroSensitivity.toFixed(1)}x`)
              .fontSize(OV_FONT_MD)
              .fontColor(OV_ACCENT_BLUE)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .padding({ bottom: 4 })

          Slider({
            value: this.gyroSensitivity,
            min: 0.5,
            max: 10.0,
            step: 0.1,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .blockColor(OV_ACCENT_BLUE)
            .trackColor(OV_BG_TRACK)
            .selectedColor(OV_ACCENT_BLUE)
            .showSteps(false)
            .showTips(false)
            .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.gyroSensitivity = Math.round(value * 10) / 10;
              GyroAssistService.getInstance().setSensitivity(this.gyroSensitivity);
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.saveGyroSetting(SettingsKeys.GYRO_SENSITIVITY, this.gyroSensitivity);
              }
            })

          Row() {
            Text('0.5x').fontSize(OV_FONT_XS).fontColor(OV_TEXT_FAINT)
            Blank()
            Text('3.0x').fontSize(OV_FONT_XS).fontColor(OV_TEXT_FAINT)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 4 })

        this.GyroToggleRow('X轴反转', this.gyroInvertX, (isOn: boolean) => {
          this.gyroInvertX = isOn;
          GyroAssistService.getInstance().setInvertX(isOn);
          this.saveGyroSetting(SettingsKeys.GYRO_INVERT_X, isOn);
        })

        this.GyroToggleRow('Y轴反转', this.gyroInvertY, (isOn: boolean) => {
          this.gyroInvertY = isOn;
          GyroAssistService.getInstance().setInvertY(isOn);
          this.saveGyroSetting(SettingsKeys.GYRO_INVERT_Y, isOn);
        })

        Row().width('85%').height(1).backgroundColor(OV_BG_DIVIDER)

        Column() {
          Text('激活方式').fontSize(OV_FONT_MD).fontColor(OV_TEXT_MEDIUM).width('100%').padding({ bottom: 6 })
          Row({ space: 8 }) {
            this.ActivationButton('始终', GYRO_ACTIVATION_ALWAYS)
            this.ActivationButton('LT', GYRO_ACTIVATION_LT)
            this.ActivationButton('RT', GYRO_ACTIVATION_RT)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 14 })
      }
    }
    .width(OV_CARD_WIDTH)
    .backgroundColor(this.isCurrentDark() ? OV_BG_CARD_DARK : OV_BG_CARD_LIGHT)
    .backdropBlur(OV_CARD_BLUR)
    .borderRadius(OV_CARD_RADIUS)
    .border({ width: 1, color: this.isCurrentDark() ? OV_BG_CARD_DARKER : OV_BG_CARD_LIGHTER })
    .shadow({ radius: 12, color: this.isCurrentDark() ? OV_SHADOW_MEDIUM : OV_SHADOW_LIGHT, offsetY: 2 })
  }

  @Builder
  GyroToggleRow(label: string, isOn: boolean, onChange: (isOn: boolean) => void) {
    Row() {
      Text(label).fontSize(OV_FONT_MD).fontColor(OV_TEXT_MEDIUM)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(OV_ACCENT_BLUE)
        .switchPointColor(OV_TEXT_WHITE)
        .width(36)
        .height(20)
        .onChange(onChange)
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 4, bottom: 4 })
  }

  @Builder
  ActivationButton(label: string, key: number) {
    Text(label)
      .fontSize(OV_FONT_MD)
      .fontWeight(this.gyroActivationKey === key ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.gyroActivationKey === key ? '#FFFFFF' : (this.isCurrentDark() ? '#80000000' : OV_TEXT_DIM))
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor(this.gyroActivationKey === key ? OV_BLUE_50 : (this.isCurrentDark() ? OV_SHADOW_MEDIUM : OV_BG_DIVIDER))
      .border({ width: 1, color: this.gyroActivationKey === key ? OV_ACCENT_BLUE : (this.isCurrentDark() ? OV_BG_CARD_DARKER : OV_BG_CARD_LIGHTER) })
      .onClick(() => {
        this.gyroActivationKey = key;
        GyroAssistService.getInstance().setActivationKey(key);
        this.saveGyroSetting(SettingsKeys.GYRO_ACTIVATION_KEY, key);
      })
  }

  @Builder
  SuperCmdCard() {
    Column() {
      Row() {
        Text('🎯').fontSize(OV_FONT_LG)
        Text(' 服务端指令')
          .fontSize(OV_FONT_LG)
          .fontWeight(FontWeight.Medium)
          .fontColor(OV_TEXT_BRIGHT)
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 4 })

      Text('执行 Sunshine 预设脚本')
        .fontSize(OV_FONT_SM)
        .fontColor(OV_TEXT_FAINT)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 6 })

      Scroll() {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
          ForEach(this.superCmds, (cmd: SuperCmd) => {
            this.SuperCmdPill(cmd)
          })
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 100 })
      .scrollBar(BarState.Off)
      .padding({ left: 14, right: 14, top: 10, bottom: 14 })
    }
    .width(OV_CARD_WIDTH)
    .backgroundColor(this.isCurrentDark() ? OV_BG_CARD_DARK : OV_BG_CARD_LIGHT)
    .backdropBlur(OV_CARD_BLUR)
    .borderRadius(OV_CARD_RADIUS)
    .border({ width: 1, color: this.isCurrentDark() ? OV_BG_CARD_DARKER : OV_BG_CARD_LIGHTER })
    .shadow({ radius: 12, color: this.isCurrentDark() ? OV_SHADOW_MEDIUM : OV_SHADOW_LIGHT, offsetY: 2 })
  }

  @Builder
  ShortcutCard() {
    Column() {
      Row() {
        Text('⚡').fontSize(OV_FONT_LG)
        Text(' 快捷键')
          .fontSize(OV_FONT_LG)
          .fontWeight(FontWeight.Medium)
          .fontColor(OV_TEXT_BRIGHT)
        Blank()
        Text('＋')
          .fontSize(14)
          .fontColor(OV_TEXT_WHITE)
          .fontWeight(FontWeight.Bold)
          .width(24)
          .height(24)
          .textAlign(TextAlign.Center)
          .borderRadius(12)
          .backgroundColor('#40A8E8B0')
          .onClick(() => this.callbacks.onOpenShortcutEditor?.())
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14 })

      Scroll() {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
          ForEach(this.shortcuts, (shortcut: Shortcut) => {
            this.ShortcutPill(shortcut)
          })
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 120 })
      .scrollBar(BarState.Off)
      .padding({ left: 14, right: 14, top: 10, bottom: 14 })
    }
    .width(OV_CARD_WIDTH)
    .backgroundColor(this.isCurrentDark() ? OV_BG_CARD_DARK : OV_BG_CARD_LIGHT)
    .backdropBlur(OV_CARD_BLUR)
    .borderRadius(OV_CARD_RADIUS)
    .border({ width: 1, color: this.isCurrentDark() ? OV_BG_CARD_DARKER : OV_BG_CARD_LIGHTER })
    .shadow({ radius: 12, color: this.isCurrentDark() ? OV_SHADOW_MEDIUM : OV_SHADOW_LIGHT, offsetY: 2 })
  }

  @Builder
  SockButton(index: number) {
    Row() {
      Column()
        .width(22)
        .height(36)
        .backgroundColor(this.getMenuBorderColor(index))
        .borderRadius({ topLeft: 18, bottomLeft: 18 })

      Row() {
        Text(this.getMenuLabel(index))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.getMenuBorderColor(index))
      }
      .width(75)
      .height(36)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(this.getMenuBgColor(index))

      Column() {
        ForEach([0, 1, 2, 3, 4], () => {
          Row()
            .width(10)
            .height(5)
            .backgroundColor(this.getMenuBorderColor(index))
            .borderRadius({ topLeft: 5, topRight: 5 })
            .margin({ top: 2 })
        })
      }
      .height(36)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.getMenuBgColor(index))
    }
    .height(40)
    .padding(2)
    .scale({ x: this.scales[index], y: this.scales[index] })
    .translate({ x: this.positions[index] })
    .margin({ right: MENU_OFFSETS[index], bottom: 4 })
    .focusable(true)
    .focusOnTouch(true)
    .focusBox({
      margin: LengthMetrics.vp(2),
      strokeColor: ColorMetrics.rgba(74, 222, 128, 1),
      strokeWidth: LengthMetrics.vp(2)
    })
    .onKeyEvent((event: KeyEvent) => {
      if (event.type === KeyType.Down) {
        if (event.keyCode === 2054 || event.keyCode === 2050) {
          this.handleMenuClick(index);
          return true;
        }
        if (event.keyCode === 2070 || event.keyCode === 2012) {
          this.animateOut();
          return true;
        }
      }
      return false;
    })
    .onClick(() => this.handleMenuClick(index))
  }

  @Builder
  ShortcutPill(shortcut: Shortcut) {
    Row() {
      if (shortcut.icon) {
        Text(shortcut.icon).fontSize(OV_FONT_MD).margin({ right: 4 })
      }
      Text(shortcut.name).fontSize(OV_FONT_MD).fontColor(OV_TEXT_ULTRA)
    }
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .backgroundColor(`#50${(shortcut.color || '#9DABB2').replace('#', '')}`)
    .border({ width: 1, color: `#80${(shortcut.color || '#9DABB2').replace('#', '')}` })
    .borderRadius(14)
    .margin({ right: 6, bottom: 6 })
    .focusable(true)
    .focusOnTouch(true)
    .focusBox({
      margin: LengthMetrics.vp(1),
      strokeColor: ColorMetrics.rgba(74, 222, 128, 0.8),
      strokeWidth: LengthMetrics.vp(1.5)
    })
    .onKeyEvent((event: KeyEvent) => {
      if (event.type === KeyType.Down) {
        if (event.keyCode === 2054 || event.keyCode === 2050) {
          this.sendShortcut(shortcut);
          this.animateOut();
          return true;
        }
        if (event.keyCode === 2051 && !shortcut.isBuiltin) {
          this.showShortcutOptions(shortcut);
          return true;
        }
      }
      return false;
    })
    .onClick(() => {
      this.sendShortcut(shortcut);
      this.animateOut();
    })
    .gesture(
      LongPressGesture({ duration: 500 })
        .onAction(() => {
          if (!shortcut.isBuiltin) this.showShortcutOptions(shortcut);
        })
    )
  }

  private showShortcutOptions(shortcut: Shortcut): void {
    promptAction.showDialog({
      title: shortcut.name,
      message: '选择操作',
      buttons: [
        { text: '编辑', color: '#10B981' },
        { text: '删除', color: '#EF4444' },
        { text: '取消', color: '#6B7280' }
      ]
    }).then((result) => {
      if (result.index === 0) {
        this.callbacks.onEditShortcut?.(shortcut);
      } else if (result.index === 1) {
        this.confirmDeleteShortcut(shortcut);
      }
    });
  }

  private confirmDeleteShortcut(shortcut: Shortcut): void {
    promptAction.showDialog({
      title: '删除快捷键',
      message: `确定要删除快捷键"${shortcut.name}"吗？`,
      buttons: [
        { text: '删除', color: '#EF4444' },
        { text: '取消', color: '#6B7280' }
      ]
    }).then((result) => {
      if (result.index === 0) {
        this.callbacks.onDeleteShortcut?.(shortcut);
      }
    });
  }

  @Builder
  SuperCmdPill(cmd: SuperCmd) {
    Row() {
      Text(cmd.name.charAt(0) || '?')
        .fontSize(OV_FONT_MD)
        .fontWeight(FontWeight.Bold)
        .fontColor(OV_TEXT_WHITE)
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
        .backgroundColor('#60A5FA')
        .borderRadius(10)
        .margin({ right: 6 })
      Text(cmd.name).fontSize(OV_FONT_MD).fontColor(OV_TEXT_ULTRA)
    }
    .padding({ left: 6, right: 12, top: 6, bottom: 6 })
    .backgroundColor(this.isCurrentDark() ? OV_BG_CARD_DARKER : OV_BG_CARD_LIGHTER)
    .border({ width: 1, color: this.isCurrentDark() ? OV_BG_CARD_DARK : OV_BG_TRACK })
    .borderRadius(16)
    .margin({ right: 6, bottom: 6 })
    .focusable(true)
    .focusOnTouch(true)
    .focusBox({
      margin: LengthMetrics.vp(1),
      strokeColor: ColorMetrics.rgba(96, 165, 250, 0.8),
      strokeWidth: LengthMetrics.vp(1.5)
    })
    .onKeyEvent((event: KeyEvent) => {
      if (event.type === KeyType.Down && (event.keyCode === 2054 || event.keyCode === 2050)) {
        this.callbacks.onSendSuperCmd?.(cmd.id);
        this.animateOut();
        return true;
      }
      return false;
    })
    .onClick(() => {
      this.callbacks.onSendSuperCmd?.(cmd.id);
      this.animateOut();
    })
  }
}
