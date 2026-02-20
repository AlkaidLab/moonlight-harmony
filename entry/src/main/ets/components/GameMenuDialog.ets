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
import { LengthMetrics, ColorMetrics } from '@kit.ArkUI';
import { StreamViewModel } from '../viewmodel/StreamViewModel';
import { VirtualKey } from './StreamMenuManager';
import { ShortcutManager, Shortcut } from './ShortcutManager';
import { ActionDialog, ActionDialogConfig, ConfirmDialog, ConfirmDialogConfig } from './ConfirmDialog';
import { SuperCmd } from '../service/NvHttp';
import { GyroAssistService, GYRO_ACTIVATION_ALWAYS, GYRO_ACTIVATION_LT, GYRO_ACTIVATION_RT } from '../service/GyroAssistService';
import { SettingsKeys } from '../service/SettingsService';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { DeviceSensorService } from '../service/DeviceSensorService';

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
  onClose?: () => void;
  onUnlockOverlay?: () => void;
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
const CARD_WIDTH = 280;
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

  // 屏幕方向
  @State private isLandscape: boolean = true;

  // 弹窗控制器
  private exitDialogController?: CustomDialogController;
  private touchModeDialogController?: CustomDialogController;
  private usbDriverDialogController?: CustomDialogController;

  aboutToAppear(): void {
    this.shortcuts = this.shortcutManager.getShortcuts();
    this.currentBitrate = this.viewModel.getCurrentBitrate();
    this.bitrateSliderValue = this.bitrateToSliderValue(this.currentBitrate);
    this.loadGyroSettings();
    this.detectScreenOrientation();
    this.animateIn();
  }

  private detectScreenOrientation(): void {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      this.isLandscape = displayInfo.width > displayInfo.height;
    } catch (_) {}
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
    if (shortcut.keySequence?.length) {
      shortcut.keySequence.forEach((keys: number[], index: number) => {
        setTimeout(() => this.sendKeys(keys), index * 200);
      });
    } else if (shortcut.keys.length) {
      this.sendKeys(shortcut.keys);
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
    const actions: ActionItem[] = [
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
    ];
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
      message: '切换到 USB 驱动模式后，将直接与手柄通信，获得更低延迟和更多功能。\n\n当前连接的手柄会短暂断开并重新连接。',
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
      if (this.isLandscape) {
        this.LandscapeLayout()
      } else {
        this.PortraitLayout()
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
  }

  @Builder
  LandscapeLayout() {
    Row({ space: 12 }) {
      Column({ space: 12 }) {
        if (this.shortcuts.length > 0) this.ShortcutCard()
        if (this.superCmds.length > 0) this.SuperCmdCard()
      }
      .alignItems(HorizontalAlign.Start)

      Column({ space: 12 }) {
        this.BitrateCard()
        if (this.hasGyroscope) this.GyroAssistCard()
        if (this.viewModel.overlayState.config.isLocked) this.UnlockOverlayCard()
      }
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(VerticalAlign.Top)
    .padding({ top: 20, bottom: 20, left: 16, right: 16 })
    .constraintSize({ maxHeight: '85%' })
    .position({ x: 16, y: '50%' })
    .translate({ y: '-50%' })
  }

  @Builder
  PortraitLayout() {
    Column({ space: 12 }) {
      if (this.shortcuts.length > 0) this.ShortcutCard()
      if (this.superCmds.length > 0) this.SuperCmdCard()
      this.BitrateCard()
      if (this.hasGyroscope) this.GyroAssistCard()
      if (this.viewModel.overlayState.config.isLocked) this.UnlockOverlayCard()
    }
    .alignItems(HorizontalAlign.Start)
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
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E0FFFFFF')
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
    .backgroundColor('#25FFFFFF')
    .backdropBlur(40)
    .borderRadius(20)
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 20, color: '#20000000', offsetY: 4 })
    .onClick(() => {
      this.callbacks.onUnlockOverlay?.();
      this.callbacks.onClose?.();
    })
  }

  @Builder
  BitrateCard() {
    Column() {
      Row() {
        Text('📊').fontSize(13)
        Text(' 码率调整')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E0FFFFFF')
        Blank()
        Text(this.formatBitrate(this.currentBitrate))
          .fontSize(12)
          .fontColor('#FFB7C5')
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 4 })

      Text('实时调整串流画质，需 Foundation Sunshine 支持')
        .fontSize(10)
        .fontColor('#60FFFFFF')
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
          .blockColor('#FFB7C5')
          .trackColor('#30FFFFFF')
          .selectedColor('#FFB7C5')
          .showSteps(false)
          .showTips(false)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.bitrateSliderValue = value;
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.applyBitrateChange();
            }
          })

        Row() {
          Text('0.5').fontSize(10).fontColor('#80FFFFFF')
          Blank()
          Text(this.isAdjustingBitrate ? '调整中...' : this.formatBitrate(this.sliderValueToBitrate(this.bitrateSliderValue)))
            .fontSize(11)
            .fontColor(this.isAdjustingBitrate ? '#80FFFFFF' : '#FFB7C5')
            .fontWeight(FontWeight.Bold)
          Blank()
          Text('200').fontSize(10).fontColor('#80FFFFFF')
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 14, right: 14, bottom: 12 })
    }
    .width(CARD_WIDTH)
    .backgroundColor('#25FFFFFF')
    .backdropBlur(40)
    .borderRadius(20)
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 20, color: '#20000000', offsetY: 4 })
  }

  @Builder
  GyroAssistCard() {
    Column() {
      Row() {
        Text('🎮').fontSize(13)
        Text(' 体感助手')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E0FFFFFF')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.gyroEnabled })
          .selectedColor('#A8D8EA')
          .switchPointColor('#FFFFFF')
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
        .fontSize(10)
        .fontColor(this.hasGyroscope ? '#60FFFFFF' : '#FFB7C5')
        .width('100%')
        .padding({ left: 16, right: 16, bottom: this.gyroEnabled ? 8 : 14 })

      if (this.gyroEnabled) {
        Row().width('85%').height(1).backgroundColor('#15FFFFFF')

        Column() {
          Row() {
            Text('灵敏度').fontSize(11).fontColor('#B0FFFFFF')
            Blank()
            Text(`${this.gyroSensitivity.toFixed(1)}x`)
              .fontSize(11)
              .fontColor('#A8D8EA')
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
            .blockColor('#A8D8EA')
            .trackColor('#30FFFFFF')
            .selectedColor('#A8D8EA')
            .showSteps(false)
            .showTips(false)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.gyroSensitivity = Math.round(value * 10) / 10;
              GyroAssistService.getInstance().setSensitivity(this.gyroSensitivity);
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.saveGyroSetting(SettingsKeys.GYRO_SENSITIVITY, this.gyroSensitivity);
              }
            })

          Row() {
            Text('0.5x').fontSize(9).fontColor('#60FFFFFF')
            Blank()
            Text('3.0x').fontSize(9).fontColor('#60FFFFFF')
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

        Row().width('85%').height(1).backgroundColor('#15FFFFFF')

        Column() {
          Text('激活方式').fontSize(11).fontColor('#B0FFFFFF').width('100%').padding({ bottom: 6 })
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
    .width(CARD_WIDTH)
    .backgroundColor('#25FFFFFF')
    .backdropBlur(40)
    .borderRadius(20)
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 20, color: '#20000000', offsetY: 4 })
  }

  @Builder
  GyroToggleRow(label: string, isOn: boolean, onChange: (isOn: boolean) => void) {
    Row() {
      Text(label).fontSize(11).fontColor('#B0FFFFFF')
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor('#A8D8EA')
        .switchPointColor('#FFFFFF')
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
      .fontSize(11)
      .fontWeight(this.gyroActivationKey === key ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.gyroActivationKey === key ? '#FFFFFF' : '#80FFFFFF')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor(this.gyroActivationKey === key ? '#50A8D8EA' : '#15FFFFFF')
      .border({ width: 1, color: this.gyroActivationKey === key ? '#A8D8EA' : '#20FFFFFF' })
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
        Text('🎯').fontSize(13)
        Text(' 服务端指令')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E0FFFFFF')
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 4 })

      Text('执行 Sunshine 预设脚本')
        .fontSize(10)
        .fontColor('#60FFFFFF')
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
    .width(CARD_WIDTH)
    .backgroundColor('#25FFFFFF')
    .backdropBlur(40)
    .borderRadius(20)
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 20, color: '#20000000', offsetY: 4 })
  }

  @Builder
  ShortcutCard() {
    Column() {
      Row() {
        Text('⚡').fontSize(13)
        Text(' 快捷键')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E0FFFFFF')
        Blank()
        Text('＋')
          .fontSize(14)
          .fontColor('#FFFFFF')
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
    .width(CARD_WIDTH)
    .backgroundColor('#25FFFFFF')
    .backdropBlur(40)
    .borderRadius(20)
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 20, color: '#20000000', offsetY: 4 })
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
        Text(shortcut.icon).fontSize(11).margin({ right: 4 })
      }
      Text(shortcut.name).fontSize(11).fontColor('#F0FFFFFF')
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
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
        .backgroundColor('#60A5FA')
        .borderRadius(10)
        .margin({ right: 6 })
      Text(cmd.name).fontSize(11).fontColor('#F0FFFFFF')
    }
    .padding({ left: 6, right: 12, top: 6, bottom: 6 })
    .backgroundColor('#20FFFFFF')
    .border({ width: 1, color: '#30FFFFFF' })
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
