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
 * 
 * 设计理念：
 * - 马卡龙配色的长筒袜形状按钮
 * - 从右边依次弹出的动画效果
 * - 二级菜单全屏居中显示
 * - 奶油风卡片：半透明毛玻璃 + 淡雅配色
 * - 超级指令面板 (Sunshine 功能)
 */
import { promptAction } from '@kit.ArkUI';
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

/**
 * 菜单回调接口
 */
export interface GameMenuCallbacks {
  onDismiss: () => void;
  onDisconnect: () => void;
  onQuitGame: () => void;
  onTouchModeChanged: (mode: string) => void;
  onOpenShortcutEditor?: () => void;
  onEditShortcut?: (shortcut: Shortcut) => void;     // 编辑快捷键
  onDeleteShortcut?: (shortcut: Shortcut) => void;   // 删除快捷键
  onSendSuperCmd?: (cmdId: string) => void;  // 发送超级指令
  onForceUsbDriver?: () => void;  // 强制 USB 驱动接管
  onToggleKeyboard?: () => void;  // 弹出系统键盘
  onToggleMouseEmulation?: () => void;  // 切换手柄鼠标模拟
  onClose?: () => void; // 用于关闭对话框
}

/**
 * 菜单项配置
 */
interface MenuItem {
  icon: string;
  label: string;
  bgColor: string;      // 袜筒颜色（浅）
  borderColor: string;  // 袜头和蕾丝颜色（深）
}

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
  superCmds: SuperCmd[] = [];  // 超级指令列表 (Sunshine 功能)
  isUsbDriverMode: boolean = false;  // 当前是否处于 USB 驱动模式
  isMouseEmulationActive: boolean = false;  // 当前是否处于手柄鼠标模拟模式
  hasConnectedGamepad: boolean = false;  // 是否有手柄连接
  
  // 菜单项配置（马卡龙色系 - 优化配色和图标）
  private readonly menuItems: MenuItem[] = [
    { icon: '✦', label: 'HDR', bgColor: '#F7EBC7', borderColor: '#D0A850' },       // HDR
    { icon: '◎', label: 'USB驱动', bgColor: '#F7D1D1', borderColor: '#D87070' },   // USB 驱动接管
    { icon: '⌨', label: '键盘', bgColor: '#C7F7E0', borderColor: '#50C080' },      // 键盘
    { icon: '☝', label: '触控', bgColor: '#E0D4F7', borderColor: '#9080C0' },      // 触控
    { icon: '🎮', label: '手柄', bgColor: '#D4E8F7', borderColor: '#6098C0' },      // 虚拟手柄
    { icon: '🖱', label: '鼠标', bgColor: '#F7E0C7', borderColor: '#C08050' },      // 手柄鼠标模拟
    { icon: '✕', label: '退出', bgColor: '#F7CFCF', borderColor: '#D06060' }       // 退出
  ];
  
  // 菜单项水平偏移（不规则排列）
  private readonly offsets: number[] = [25, 55, 70, 35, 45, 30, 50];
  
  // 动画状态：translateX 位置（正值向右，负值向左）
  @State private pos0: number = 200;  // 初始在屏幕右边外面
  @State private pos1: number = 200;
  @State private pos2: number = 200;
  @State private pos3: number = 200;
  @State private pos4: number = 200;
  @State private pos5: number = 200;
  @State private pos6: number = 200;
  
  // 动画状态：缩放（初始为 1.0，不缩小）
  @State private scale0: number = 1.0;
  @State private scale1: number = 1.0;
  @State private scale2: number = 1.0;
  @State private scale3: number = 1.0;
  @State private scale4: number = 1.0;
  @State private scale5: number = 1.0;
  @State private scale6: number = 1.0;
  
  // 二级菜单状态
  @State private expandedMenu: string = '';
  
  // 快捷键
  @State private shortcuts: Shortcut[] = [];
  private shortcutManager = ShortcutManager.getInstance();
  
  // 码率调整状态
  @State private currentBitrate: number = 0;  // 当前码率 (kbps)
  @State private bitrateSliderValue: number = 0;  // 滑块值
  @State private isAdjustingBitrate: boolean = false;  // 是否正在调整中
  private bitrateDebounceTimer: number = -1;  // 防抖定时器
  
  // 体感助手状态
  @State private gyroEnabled: boolean = false;
  @State private gyroSensitivity: number = 1.0;
  @State private gyroInvertX: boolean = false;
  @State private gyroInvertY: boolean = false;
  @State private gyroActivationKey: number = GYRO_ACTIVATION_ALWAYS;
  private hasGyroscope: boolean = false;
  
  // 关闭动画状态
  private isClosing: boolean = false;
  
  // 弹窗控制器
  private exitDialogController?: CustomDialogController;
  private touchModeDialogController?: CustomDialogController;
  private usbDriverDialogController?: CustomDialogController;
  
  aboutToAppear(): void {
    this.shortcuts = this.shortcutManager.getShortcuts();
    // 加载当前码率
    this.currentBitrate = this.viewModel.getCurrentBitrate();
    this.bitrateSliderValue = this.bitrateToSliderValue(this.currentBitrate);
    // 加载体感助手状态
    this.loadGyroSettings();
    // 依次弹出动画（交错启动，间隔更短）
    this.animateInStaggered();
  }
  
  /**
   * 交错执行进入动画（每个按钮间隔 50ms 启动，而不是等前一个完成）
   */
  private animateInStaggered(): void {
    const staggerDelay = 50;  // 每个按钮启动间隔 50ms
    
    for (let i = 0; i < 7; i++) {
      setTimeout(() => {
        animateTo({ 
          duration: 200,  // 单个动画时长
          curve: Curve.FastOutSlowIn,
        }, () => {
          this.setPos(i, 0);
        });
      }, i * staggerDelay);
    }
  }
  
  /**
   * 递归执行进入动画（备用方案）
   */
  private animateInSequence(index: number): void {
    if (index >= 7) return;
    
    animateTo({ 
      duration: 280,  // 稍快的动画
      curve: Curve.FastOutSlowIn,  // 更流畅的曲线
      onFinish: () => {
        // 动画完成后触发下一个
        if (index < 6) {
          this.animateInSequence(index + 1);
        }
      }
    }, () => {
      this.setPos(index, 0);
    });
  }
  
  /**
   * 执行关闭动画并关闭对话框
   */
  private animateOut(): void {
    // 防止重复调用
    if (this.isClosing) {
      return;
    }
    this.isClosing = true;
    
    // 保存回调引用，避免闭包中上下文丢失
    const callbacks = this.callbacks;
    
    // 同时执行所有滑出动画（更快的退出）
    animateTo({ 
      duration: 200, 
      curve: Curve.FastOutLinearIn 
    }, () => {
      for (let i = 0; i < 7; i++) {
        this.setPos(i, 200);
      }
    });
    
    // 动画完成后关闭对话框
    setTimeout(() => {
      // 使用外部传入的 onClose 回调关闭对话框
      if (callbacks.onClose) {
        callbacks.onClose();
      }
      callbacks.onDismiss();
    }, 250);
  }
  
  private setPos(i: number, v: number): void {
    if (i === 0) this.pos0 = v;
    else if (i === 1) this.pos1 = v;
    else if (i === 2) this.pos2 = v;
    else if (i === 3) this.pos3 = v;
    else if (i === 4) this.pos4 = v;
    else if (i === 5) this.pos5 = v;
    else if (i === 6) this.pos6 = v;
  }
  
  private getPos(i: number): number {
    if (i === 0) return this.pos0;
    if (i === 1) return this.pos1;
    if (i === 2) return this.pos2;
    if (i === 3) return this.pos3;
    if (i === 4) return this.pos4;
    if (i === 5) return this.pos5;
    if (i === 6) return this.pos6;
    return 0;
  }
  
  private setScale(i: number, v: number): void {
    if (i === 0) this.scale0 = v;
    else if (i === 1) this.scale1 = v;
    else if (i === 2) this.scale2 = v;
    else if (i === 3) this.scale3 = v;
    else if (i === 4) this.scale4 = v;
    else if (i === 5) this.scale5 = v;
    else if (i === 6) this.scale6 = v;
  }
  
  private getScale(i: number): number {
    if (i === 0) return this.scale0;
    if (i === 1) return this.scale1;
    if (i === 2) return this.scale2;
    if (i === 3) return this.scale3;
    if (i === 4) return this.scale4;
    if (i === 5) return this.scale5;
    if (i === 6) return this.scale6;
    return 1;
  }
  
  private sendKeys(keys: number[]): void {
    this.viewModel.getSession()?.sendKeys(keys);
  }

  /**
   * 执行快捷键（支持单次组合或多步序列）
   */
  private sendShortcut(shortcut: Shortcut): void {
    if (shortcut.keySequence && shortcut.keySequence.length > 0) {
      shortcut.keySequence.forEach((keys: number[], index: number) => {
        setTimeout(() => {
          this.sendKeys(keys);
        }, index * 200);
      });
    } else if (shortcut.keys.length > 0) {
      this.sendKeys(shortcut.keys);
    }
  }

  // ==================== 码率调整辅助方法 ====================
  
  /**
   * 码率转滑块值 (500-200000 kbps -> 0-1995)
   */
  private bitrateToSliderValue(bitrate: number): number {
    return Math.max(0, Math.min(1995, Math.round((bitrate - 500) / 100)));
  }
  
  /**
   * 滑块值转码率 (0-1995 -> 500-200000 kbps)
   */
  private sliderValueToBitrate(value: number): number {
    return (value * 100) + 500;
  }
  
  /**
   * 格式化码率显示
   */
  private formatBitrate(kbps: number): string {
    if (kbps >= 1000) {
      return `${(kbps / 1000).toFixed(0)} Mbps`;
    }
    return `${kbps} kbps`;
  }
  
  /**
   * 应用码率调整（带防抖）
   */
  private applyBitrateChange(): void {
    if (this.bitrateDebounceTimer !== -1) {
      clearTimeout(this.bitrateDebounceTimer);
    }
    
    this.bitrateDebounceTimer = setTimeout(() => {
      const newBitrate = this.sliderValueToBitrate(this.bitrateSliderValue);
      this.isAdjustingBitrate = true;
      
      this.viewModel.setBitrate(newBitrate).then((success) => {
        this.isAdjustingBitrate = false;
        if (success) {
          this.currentBitrate = newBitrate;
          const message = `码率已调整为 ${this.formatBitrate(newBitrate)}`;
          console.info(message);
          promptAction.showToast({
            message: message,
            duration: 2000
          });
        } else {
          // 恢复原来的滑块位置
          this.bitrateSliderValue = this.bitrateToSliderValue(this.currentBitrate);
          console.warn('码率调整失败');
          promptAction.showToast({
            message: '码率调整失败',
            duration: 2000
          });
        }
      }).catch((err: Error) => {
        this.isAdjustingBitrate = false;
        this.bitrateSliderValue = this.bitrateToSliderValue(this.currentBitrate);
        console.error('码率调整失败:', err);
        promptAction.showToast({
          message: '码率调整失败: ' + err.message,
          duration: 2000
        });
      });
      
      this.bitrateDebounceTimer = -1;
    }, 500);
  }
  
  /**
   * 显示退出确认弹窗
   */
  private showExitDialog(): void {
    // 保存引用
    const callbacks = this.callbacks;
    
    const config: ActionDialogConfig = {
      title: '离开串流',
      actions: [
        {
          text: '断开连接',
          subtitle: '游戏继续在主机上运行',
          color: '#3B82F6',
          backgroundColor: '#EFF6FF',
          onClick: () => {
            callbacks.onDisconnect();
            // 使用外部 onClose 回调关闭对话框
            if (callbacks.onClose) {
              callbacks.onClose();
            }
          }
        },
        {
          text: '退出游戏',
          subtitle: '关闭主机上的游戏',
          color: '#EF4444',
          backgroundColor: '#FEF2F2',
          onClick: () => {
            callbacks.onQuitGame();
            // 使用外部 onClose 回调关闭对话框
            if (callbacks.onClose) {
              callbacks.onClose();
            }
          }
        }
      ],
      cancelText: '继续游戏',
      onCancel: () => {}
    };
    
    this.exitDialogController = new CustomDialogController({
      builder: ActionDialog({ config: config }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.exitDialogController.open();
  }
  
  /**
   * 显示触控模式选择弹窗
   */
  private showTouchModeDialog(): void {
    const currentMode = this.viewModel.touchMode;
    const config: ActionDialogConfig = {
      title: '选择触摸模式',
      actions: [
        {
          text: '触控板',
          subtitle: currentMode === 'trackpad' ? '✓ 当前模式' : '像笔记本触控板一样操作',
          color: currentMode === 'trackpad' ? '#10B981' : undefined,
          backgroundColor: currentMode === 'trackpad' ? '#D1FAE5' : undefined,
          onClick: () => {
            this.callbacks.onTouchModeChanged('trackpad');
          }
        },
        {
          text: '多点触控',
          subtitle: currentMode === 'direct' ? '✓ 当前模式' : '直接点击屏幕位置',
          color: currentMode === 'direct' ? '#10B981' : undefined,
          backgroundColor: currentMode === 'direct' ? '#D1FAE5' : undefined,
          onClick: () => {
            this.callbacks.onTouchModeChanged('direct');
          }
        },
        {
          text: '鼠标模式',
          subtitle: currentMode === 'mouse' ? '✓ 当前模式' : '模拟鼠标移动和点击',
          color: currentMode === 'mouse' ? '#10B981' : undefined,
          backgroundColor: currentMode === 'mouse' ? '#D1FAE5' : undefined,
          onClick: () => {
            this.callbacks.onTouchModeChanged('mouse');
          }
        }
      ],
      cancelText: '取消',
      onCancel: () => {}
    };
    
    this.touchModeDialogController = new CustomDialogController({
      builder: ActionDialog({ config: config }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.touchModeDialogController.open();
  }
  
  /**
   * 显示 USB 驱动接管确认弹窗
   */
  private showUsbDriverDialog(): void {
    const config: ConfirmDialogConfig = {
      title: '强制 USB 驱动接管',
      message: '切换到 USB 驱动模式后，将直接与手柄通信，获得更低延迟和更多功能（如震动调节）。\n\n当前连接的手柄会短暂断开并重新连接。\n\n如果手柄出现问题，重启应用可恢复默认模式。',
      cancelButton: {
        text: '取消',
        onClick: () => {}
      },
      confirmButton: {
        text: '接管',
        color: '#3B82F6',
        onClick: () => {
          if (this.callbacks.onForceUsbDriver) {
            this.callbacks.onForceUsbDriver();
          }
          this.animateOut();
        }
      }
    };
    
    this.usbDriverDialogController = new CustomDialogController({
      builder: ConfirmDialog({ config: config }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.usbDriverDialogController.open();
  }
  
  private handleMenuClick(index: number): void {
    switch (index) {
      case 0: // HDR
        this.sendKeys([VirtualKey.VK_LWIN, VirtualKey.VK_MENU, VirtualKey.VK_B]);
        this.animateOut();
        break;
      case 1: // USB 驱动接管
        if (this.isUsbDriverMode) {
          promptAction.showToast({ message: '当前已是 USB 驱动模式', duration: 2000 });
        } else {
          this.showUsbDriverDialog();
        }
        break;
      case 2: // 键盘 - 直接弹出系统 IME
        this.callbacks.onToggleKeyboard?.();
        this.animateOut();
        break;
      case 3: // 触控
        this.showTouchModeDialog();
        break;
      case 4: // 虚拟手柄
        this.viewModel.toggleController();
        this.animateOut();
        break;
      case 5: // 手柄鼠标模拟
        this.callbacks.onToggleMouseEmulation?.();
        this.animateOut();
        break;
      case 6: // 退出
        this.showExitDialog();
        break;
    }
  }
  
  build() {
    Stack({ alignContent: Alignment.Center }) {
      // ==================== 背景可点击关闭 ====================
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
      
      // ==================== 一级菜单（右侧袜子按钮）====================
      Column() {
        this.SockButton(0)
        this.SockButton(1)
        this.SockButton(2)
        this.SockButton(3)
        // 虚拟手柄按钮仅在设置启用时显示
        if (this.viewModel.inputSettings?.enableOnscreenControls) {
          this.SockButton(4)
        }
        // 鼠标模拟按钮仅在有手柄连接时显示
        if (this.hasConnectedGamepad) {
          this.SockButton(5)
        }
        this.SockButton(6)
      }
      .alignItems(HorizontalAlign.End)
      .justifyContent(FlexAlign.Center)
      .padding({ top: 20, bottom: 20 })
      .position({ x: '100%', y: '50%' })
      .translate({ x: '-100%', y: '-50%' })
      
      // ==================== 中央面板区域 ====================
      Scroll() {
        Column({ space: 12 }) {
          // 码率调整卡片
          this.BitrateCard()
          
          // 体感助手卡片（有陀螺仪时显示）
          if (this.hasGyroscope) {
            this.GyroAssistCard()
          }
          
          // 快捷键卡片
          if (this.shortcuts.length > 0) {
            this.ShortcutCard()
          }

          // 超级指令卡片
          if (this.superCmds.length > 0) {
            this.SuperCmdCard()
          }
        }
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Start)
        .padding({ top: 20, bottom: 20 })
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .constraintSize({ maxHeight: '80%' })
      .position({ x: '50%', y: '50%' })
      .translate({ x: '-50%', y: '-50%' })
      
      // ==================== 二级菜单遮罩 ====================
      if (this.expandedMenu !== '') {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000099')
          .onClick(() => { this.expandedMenu = ''; })
          .transition({ type: TransitionType.Insert, opacity: 0 })
          .transition({ type: TransitionType.Delete, opacity: 0 })
      }
    }
    .width('100%')
    .height('100%')
  }
  
  /**
   * 码率调整卡片 - 奶油风格
   */
  @Builder
  BitrateCard() {
    Column() {
      // 标题栏
      Row() {
        Text('📊')
          .fontSize(13)
        Text(' 码率调整')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E0FFFFFF')
        Blank()
        Text(this.formatBitrate(this.currentBitrate))
          .fontSize(12)
          .fontColor('#FFB7C5')  // 樱花粉
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 4 })
      
      // 提示说明
      Text('实时调整串流画质，需 Foundation Sunshine 支持')
        .fontSize(10)
        .fontColor('#60FFFFFF')
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
      
      // 滑块
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
        
        // 范围标签
        Row() {
          Text('0.5')
            .fontSize(10)
            .fontColor('#80FFFFFF')
          Blank()
          Text(this.isAdjustingBitrate ? '调整中...' : this.formatBitrate(this.sliderValueToBitrate(this.bitrateSliderValue)))
            .fontSize(11)
            .fontColor(this.isAdjustingBitrate ? '#80FFFFFF' : '#FFB7C5')
            .fontWeight(FontWeight.Bold)
          Blank()
          Text('200')
            .fontSize(10)
            .fontColor('#80FFFFFF')
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 14, right: 14, bottom: 12 })
    }
    .width(280)
    .backgroundColor('#25FFFFFF')  // 半透明白色
    .backdropBlur(40)  // 毛玻璃效果
    .borderRadius(20)
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 20, color: '#20000000', offsetY: 4 })
  }
  
  /**
   * 加载体感助手设置
   */
  private async loadGyroSettings(): Promise<void> {
    this.hasGyroscope = DeviceSensorService.getInstance().hasGyroscope();
    const gyroAssist = GyroAssistService.getInstance();
    this.gyroEnabled = gyroAssist.enabled;
    this.gyroSensitivity = gyroAssist.sensitivityMultiplier;
    this.gyroInvertX = gyroAssist.invertX;
    this.gyroInvertY = gyroAssist.invertY;
    this.gyroActivationKey = gyroAssist.activationKey;
  }

  /**
   * 保存体感助手设置项
   */
  private async saveGyroSetting(key: string, value: string | boolean | number): Promise<void> {
    try {
      await PreferencesUtil.put(key, value);
    } catch (error) {
      console.error('[GyroAssist] 保存设置失败:', error);
    }
  }

  /**
   * 体感助手卡片 - 奶油风格
   * 陀螺仪 → 右摇杆映射，支持灵敏度、轴反转、激活方式
   */
  @Builder
  GyroAssistCard() {
    Column() {
      // ===== 标题栏 + 主开关 =====
      Row() {
        Text('🎮')
          .fontSize(13)
        Text(' 体感助手')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E0FFFFFF')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.gyroEnabled })
          .selectedColor('#A8D8EA')  // 婴儿蓝
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

      // 提示说明
      Text(this.hasGyroscope ? '陀螺仪 → 右摇杆映射' : '⚠ 设备无陀螺仪')
        .fontSize(10)
        .fontColor(this.hasGyroscope ? '#60FFFFFF' : '#FFB7C5')
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

      if (this.gyroEnabled) {
        // ===== 分割线 =====
        Row()
          .width('85%')
          .height(1)
          .backgroundColor('#15FFFFFF')

        // ===== 灵敏度滑块 =====
        Column() {
          Row() {
            Text('灵敏度')
              .fontSize(11)
              .fontColor('#B0FFFFFF')
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
              this.gyroSensitivity = Math.round(value * 10) / 10;  // 保留1位小数
              GyroAssistService.getInstance().setSensitivity(this.gyroSensitivity);
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.saveGyroSetting(SettingsKeys.GYRO_SENSITIVITY, this.gyroSensitivity);
              }
            })

          Row() {
            Text('0.5x')
              .fontSize(9)
              .fontColor('#60FFFFFF')
            Blank()
            Text('3.0x')
              .fontSize(9)
              .fontColor('#60FFFFFF')
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 4 })

        // ===== 轴反转开关 =====
        Row() {
          Text('X轴反转')
            .fontSize(11)
            .fontColor('#B0FFFFFF')
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.gyroInvertX })
            .selectedColor('#A8D8EA')
            .switchPointColor('#FFFFFF')
            .width(36)
            .height(20)
            .onChange((isOn: boolean) => {
              this.gyroInvertX = isOn;
              GyroAssistService.getInstance().setInvertX(isOn);
              this.saveGyroSetting(SettingsKeys.GYRO_INVERT_X, isOn);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 6, bottom: 2 })

        Row() {
          Text('Y轴反转')
            .fontSize(11)
            .fontColor('#B0FFFFFF')
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.gyroInvertY })
            .selectedColor('#A8D8EA')
            .switchPointColor('#FFFFFF')
            .width(36)
            .height(20)
            .onChange((isOn: boolean) => {
              this.gyroInvertY = isOn;
              GyroAssistService.getInstance().setInvertY(isOn);
              this.saveGyroSetting(SettingsKeys.GYRO_INVERT_Y, isOn);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 2, bottom: 6 })

        // ===== 分割线 =====
        Row()
          .width('85%')
          .height(1)
          .backgroundColor('#15FFFFFF')

        // ===== 激活方式选择 =====
        Column() {
          Text('激活方式')
            .fontSize(11)
            .fontColor('#B0FFFFFF')
            .width('100%')
            .padding({ bottom: 6 })

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
    .width(280)
    .backgroundColor('#25FFFFFF')
    .backdropBlur(40)
    .borderRadius(20)
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 20, color: '#20000000', offsetY: 4 })
  }

  /**
   * 激活方式按钮 (胶囊型)
   */
  @Builder
  ActivationButton(label: string, key: number) {
    Text(label)
      .fontSize(11)
      .fontWeight(this.gyroActivationKey === key ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.gyroActivationKey === key ? '#FFFFFF' : '#80FFFFFF')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor(this.gyroActivationKey === key ? '#50A8D8EA' : '#15FFFFFF')
      .border({
        width: 1,
        color: this.gyroActivationKey === key ? '#A8D8EA' : '#20FFFFFF'
      })
      .onClick(() => {
        this.gyroActivationKey = key;
        GyroAssistService.getInstance().setActivationKey(key);
        this.saveGyroSetting(SettingsKeys.GYRO_ACTIVATION_KEY, key);
      })
  }

  /**
   * 超级指令卡片 - 奶油风格（独立卡片）
   */
  @Builder
  SuperCmdCard() {
    Column() {
      Row() {
        Text('🎯')
          .fontSize(13)
        Text(' 服务端指令')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E0FFFFFF')
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 4 })
      
      // 提示说明
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
    .width(280)
    .backgroundColor('#25FFFFFF')
    .backdropBlur(40)
    .borderRadius(20)
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 20, color: '#20000000', offsetY: 4 })
  }
  
  /**
   * 快捷键卡片 - 奶油风格（独立卡片）
   */
  @Builder
  ShortcutCard() {
    Column() {
      Row() {
        Text('⚡')
          .fontSize(13)
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
          .backgroundColor('#40A8E8B0')  // 薄荷绿半透明
          .onClick(() => {
            if (this.callbacks.onOpenShortcutEditor) {
              this.callbacks.onOpenShortcutEditor();
            }
          })
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
    .width(280)
    .backgroundColor('#25FFFFFF')
    .backdropBlur(40)
    .borderRadius(20)
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 20, color: '#20000000', offsetY: 4 })
  }
  
  /**
   * 快捷键/超级指令面板 - 奶油风格（保留用于兼容，但不再使用）
   */
  @Builder
  ShortcutPanel() {
    Column() {
      // 超级指令区域 (Sunshine 功能)
      if (this.superCmds.length > 0) {
        Row() {
          Text('🎯')
            .fontSize(13)
          Text(' 服务端指令')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#E0FFFFFF')
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 14 })
        
        Scroll() {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
            ForEach(this.superCmds, (cmd: SuperCmd) => {
              this.SuperCmdPill(cmd)
            })
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 80 })
        .scrollBar(BarState.Off)
        .padding({ left: 14, right: 14, top: 10, bottom: this.shortcuts.length > 0 ? 8 : 14 })
      }
      
      // 分割线
      if (this.superCmds.length > 0 && this.shortcuts.length > 0) {
        Row()
          .width('85%')
          .height(1)
          .backgroundColor('#15FFFFFF')
      }
      
      // 快捷键区域
      if (this.shortcuts.length > 0) {
        Row() {
          Text('⚡')
            .fontSize(13)
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
            .backgroundColor('#40A8E8B0')  // 薄荷绿半透明
            .onClick(() => {
              if (this.callbacks.onOpenShortcutEditor) {
                this.callbacks.onOpenShortcutEditor();
              }
            })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: this.superCmds.length > 0 ? 8 : 14 })
        
        Scroll() {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
            ForEach(this.shortcuts, (shortcut: Shortcut) => {
              this.ShortcutPill(shortcut)
            })
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 100 })
        .scrollBar(BarState.Off)
        .padding({ left: 14, right: 14, top: 10, bottom: 14 })
      }
    }
    .width(280)
    .backgroundColor('#25FFFFFF')  // 半透明白色
    .backdropBlur(40)  // 毛玻璃效果
    .borderRadius(20)
    .border({ width: 1, color: '#20FFFFFF' })
    .shadow({ radius: 20, color: '#20000000', offsetY: 4 })
  }
  
  // ==================== 子组件 ====================
  
  /**
   * 长筒袜按钮
   */
  // 获取菜单项的显示标签（USB 驱动 / 鼠标模拟项根据状态动态显示）
  private getMenuLabel(index: number): string {
    if (index === 1 && this.isUsbDriverMode) {
      return 'USB驱动 ✓';
    }
    if (index === 5 && this.isMouseEmulationActive) {
      return '鼠标 ✓';
    }
    return this.menuItems[index].label;
  }

  // 获取菜单项的背景色（USB 驱动 / 鼠标模拟已激活时使用绿色系）
  private getMenuBgColor(index: number): string {
    if (index === 1 && this.isUsbDriverMode) {
      return '#C7F7D4';  // 浅绿 - 已激活
    }
    if (index === 5 && this.isMouseEmulationActive) {
      return '#C7F7D4';
    }
    return this.menuItems[index].bgColor;
  }

  // 获取菜单项的边框色（USB 驱动 / 鼠标模拟已激活时使用绿色系）
  private getMenuBorderColor(index: number): string {
    if (index === 1 && this.isUsbDriverMode) {
      return '#50A860';  // 深绿 - 已激活
    }
    if (index === 5 && this.isMouseEmulationActive) {
      return '#50A860';
    }
    return this.menuItems[index].borderColor;
  }

  @Builder
  SockButton(index: number) {
    Row() {
      // 袜头（深色圆头）
      Column()
        .width(22)
        .height(36)
        .backgroundColor(this.getMenuBorderColor(index))
        .borderRadius({ topLeft: 18, bottomLeft: 18 })
      
      // 袜筒（浅色主体）
      Row() {
        Text(this.getMenuLabel(index))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.getMenuBorderColor(index))  // 使用边框色作为文字色
      }
      .width(75)
      .height(36)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(this.getMenuBgColor(index))
      
      // 蕾丝边（波浪装饰）
      Column() {
        Row()
          .width(10)
          .height(5)
          .backgroundColor(this.getMenuBorderColor(index))
          .borderRadius({ topLeft: 5, topRight: 5 })
        Row()
          .width(10)
          .height(5)
          .backgroundColor(this.getMenuBorderColor(index))
          .borderRadius({ bottomLeft: 5, bottomRight: 5 })
          .margin({ top: 2 })
        Row()
          .width(10)
          .height(5)
          .backgroundColor(this.getMenuBorderColor(index))
          .borderRadius({ topLeft: 5, topRight: 5 })
          .margin({ top: 2 })
        Row()
          .width(10)
          .height(5)
          .backgroundColor(this.getMenuBorderColor(index))
          .borderRadius({ bottomLeft: 5, bottomRight: 5 })
          .margin({ top: 2 })
        Row()
          .width(10)
          .height(5)
          .backgroundColor(this.getMenuBorderColor(index))
          .borderRadius({ topLeft: 5, topRight: 5 })
          .margin({ top: 2 })
      }
      .height(36)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.getMenuBgColor(index))
    }
    .height(40)
    .padding(2)
    .scale({ x: this.getScale(index), y: this.getScale(index) })
    .translate({ x: this.getPos(index) })  // 使用 translateX 控制水平滑动
    .margin({ right: this.offsets[index], bottom: 4 })  // offsets 用于不规则排列
    .focusable(true)
    .focusOnTouch(true)
    .focusBox({
      margin: LengthMetrics.vp(2),
      strokeColor: ColorMetrics.rgba(74, 222, 128, 1),
      strokeWidth: LengthMetrics.vp(2)
    })
    .onKeyEvent((event: KeyEvent) => {
      if (event.type === KeyType.Down) {
        // A键确认
        if (event.keyCode === 2054 || event.keyCode === 2050) {
          this.handleMenuClick(index);
          return true;
        }
        // B键/ESC关闭菜单
        if (event.keyCode === 2070 || event.keyCode === 2012) {
          this.animateOut();
          return true;
        }
      }
      return false;
    })
    .onClick(() => this.handleMenuClick(index))
  }
  
  /**
   * 快捷键药丸 - 奶油风格
   */
  @Builder
  ShortcutPill(shortcut: Shortcut) {
    Row() {
      if (shortcut.icon) {
        Text(shortcut.icon)
          .fontSize(11)
          .margin({ right: 4 })
      }
      Text(shortcut.name)
        .fontSize(11)
        .fontColor('#F0FFFFFF')
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
          // 长按显示编辑/删除菜单（仅用户自定义快捷键）
          if (!shortcut.isBuiltin) {
            this.showShortcutOptions(shortcut);
          }
        })
    )
  }
  
  /**
   * 显示快捷键编辑/删除选项
   */
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
        // 编辑
        if (this.callbacks.onEditShortcut) {
          this.callbacks.onEditShortcut(shortcut);
        }
      } else if (result.index === 1) {
        // 删除
        this.confirmDeleteShortcut(shortcut);
      }
    });
  }
  
  /**
   * 确认删除快捷键
   */
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
        if (this.callbacks.onDeleteShortcut) {
          this.callbacks.onDeleteShortcut(shortcut);
        }
      }
    });
  }
  
  /**
   * 超级指令药丸 - 奶油风格 (Sunshine 功能)
   */
  @Builder
  SuperCmdPill(cmd: SuperCmd) {
    Row() {
      // 用首字作为图标
      Text(cmd.name.length > 0 ? cmd.name.charAt(0) : '?')
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
        .backgroundColor('#60A5FA')  // 天蓝色
        .borderRadius(10)
        .margin({ right: 6 })
      Text(cmd.name)
        .fontSize(11)
        .fontColor('#F0FFFFFF')
    }
    .padding({ left: 6, right: 12, top: 6, bottom: 6 })
    .backgroundColor('#20FFFFFF')  // 半透明白色
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
        if (this.callbacks.onSendSuperCmd) {
          this.callbacks.onSendSuperCmd(cmd.id);
        }
        this.animateOut();
        return true;
      }
      return false;
    })
    .onClick(() => {
      if (this.callbacks.onSendSuperCmd) {
        this.callbacks.onSendSuperCmd(cmd.id);
      }
      this.animateOut();
    })
  }
}
