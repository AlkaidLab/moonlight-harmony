/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { router, promptAction, display } from '@kit.ArkUI';
import { LengthMetrics, ColorMetrics } from '@kit.ArkUI';
import { common, Want, bundleManager } from '@kit.AbilityKit';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { AppColors, AppSizes, AppSpacing, AppAnimation, AppShadows } from '../common/Theme';
import { StreamingSession, DecoderCapabilities } from '../service/StreamingSession';
import { getRecommendedBitrate } from '../model/StreamConfig';
import { PerfIcons, PerfLabels } from '../components/PerformanceOverlayManager';
import { SettingSlider, SettingSliderConfig, LogarithmicSlider } from '../components/SettingSlider';
import { OptionPickerDialog, OptionPickerDialogConfig, OptionItem as DialogOptionItem } from '../components/OptionPickerDialog';
import { MultiOptionPickerDialog, MultiOptionPickerDialogConfig, MultiOptionItem as DialogMultiOptionItem } from '../components/MultiOptionPickerDialog';
import { BackgroundImageUtil, BackgroundImageType } from '../utils/BackgroundImageUtil';
import { InputInterceptorService } from '../service/InputInterceptorService';
import { SettingsKeys } from '../service/SettingsService';
import { loadChangelog, ChangelogEntry, ChangeItem, getChangeTypeConfig } from '../common/Changelog';
import { InlineSegmentPicker } from '../components/InlineSegmentPicker';

/**
 * 选择器选项接口
 */
interface PickerOption {
  title: string;
  subtitle?: string;
  value: string | number;
}

/**
 * 性能覆盖层项目选项
 */
class PerfOverlayItemOption {
  key: string;
  title: string;
  
  constructor(key: string, title: string) {
    this.key = key;
    this.title = title;
  }
}

class ResolutionPreset {
  label: string;
  w: string;
  h: string;
  constructor(label: string, w: string, h: string) {
    this.label = label;
    this.w = w;
    this.h = h;
  }
}

/**
 * 选择器配置接口
 */
interface PickerConfig {
  title: string;
  subtitle?: string;
  options: PickerOption[];
  selectedValue: string | number;
  onSelect: (option: PickerOption) => void;
}

/**
 * 设置项数据
 */
interface SettingItem {
  title: string;
  subtitle?: string;
  type: 'toggle' | 'select' | 'input' | 'action' | 'slider' | 'segment';
  key?: string;
  value?: string | boolean | number;
  options?: string[];
  action?: () => void;
  disabled?: boolean;  // 是否禁用
  isPro?: boolean;     // 是否为 Pro 功能（需要开发者模式）
  visible?: boolean;   // 是否可见（用于条件显示子选项，默认 true）
  // Slider 专用属性
  min?: number;
  max?: number;
  step?: number;
  unit?: string;
  onSliderChange?: (value: number) => void;
  snapValues?: number[];  // 吸附的关键数值
  snapThreshold?: number; // 吸附阈值，默认为 step 的一半
  isLogarithmic?: boolean; // 是否使用对数刻度（适用于大范围值如码率）
  formatValue?: (value: number) => string;  // 自定义值格式化函数
  // Segment 分段按钮专用属性
  segmentLabels?: string[];   // 分段按钮显示文字
  segmentValues?: string[];   // 分段按钮对应的实际值（可选，默认与 labels 相同）
  onSegmentChange?: (value: string) => void;  // 选择变化回调
}

/**
 * 设置分组
 */
interface SettingGroup {
  id: string;      // 分组唯一标识
  icon: Resource;  // 分组图标
  useSymbol?: boolean;  // 是否使用 HarmonyOS Symbol，默认 true
  title: string;
  items: SettingItem[];
}

/**
 * 侧边栏分组元数据（用于宽屏侧边导航）
 */
interface SidebarGroupMeta {
  id: string;
  icon: Resource;
  title: string;
  useSymbol: boolean;
}

/**
 * 设置页面 (现代化版本)
 */
@Entry
@Component
struct SettingsPageV2 {
  @StorageProp('topSafeHeight') topSafeHeight: number = 56;  // 动态状态栏安全区高度
  // 视频设置
  @State resolution: string = '1080p';
  @State customResolutions: string[] = [];  // 自定义分辨率列表，格式如 "1920x1080"
  @State fps: string = '60 FPS';
  @State customFps: number = 0;  // 自定义帧率值 (0 表示使用预设)
  @State bitrate: number = 20;
  @State hostScale: number = 100;
  @State enableHdr: boolean = false;
  @State hdrMode: string = 'HDR10';  // 'HDR10' or 'HLG'
  @State enableHdrHighBrightness: boolean = false;
  @State videoFormat: string = '自动';
  @State stretchVideo: boolean = false;
  @State fullRange: boolean = false;
  @State reverseResolution: boolean = false;
  @State rotableScreen: boolean = false;
  
  // 音频设置
  @State audioConfig: string = '立体声';
  @State enableLocalAudio: boolean = false;
  @State enableSpatializer: boolean = false;
  @State controlOnly: boolean = false;
  @State enableMic: boolean = false;
  @State micBitrate: number = 64;
  
  // 输入 - 手柄设置
  @State enableVibration: boolean = true;
  @State vibrationMode: string = '自动';  // 自动/仅手柄/仅设备/同时
  @State vibrateFallbackStrength: number = 100;
  @State enableAudioVibration: boolean = false;
  @State audioVibrationStrength: number = 60;
  @State audioVibrationSceneMode: string = '游戏/电影';
  @State multiController: boolean = true;
  @State flipFaceButtons: boolean = false;
  @State deadzone: number = 7;
  @State gamepadMotionSensors: boolean = true;
  @State gamepadMotionFallback: boolean = false;
  @State gamepadTouchpadMouse: boolean = false;
  @State enableStartKeyMenu: boolean = true;
  @State ignoreDeviceDisconnect: boolean = false;
  @State enableKeyInterceptor: boolean = false;
  @State keyInterceptorAvailable: boolean = false;  // 按键注入 API 是否可用（API 13+ 才支持反劫持）
  @State gcButtonHomeMapping: string = 'guide';  // 2313键（Home键）动作映射
  @State usbDriverEnabled: boolean = false;  // 默认关闭 USB 手柄驱动
  @State forceUsbDriverOnly: boolean = false;  // 强制纯 USB 驱动模式
  
  // 输入 - 屏幕控制器
  @State enableOnscreenControls: boolean = false;
  @State enableOnscreenKeyboard: boolean = false;
  @State onlyL3R3: boolean = false;
  @State showGuideButton: boolean = true;
  @State halfHeightOscPortrait: boolean = true;
  @State oscOpacity: number = 90;
  @State vibrateOsc: boolean = true;
  
  // 输入 - 鼠标/触控
  @State showLocalCursor: boolean = false;   // 显示本地指针（双光标模式）
  @State touchscreenTrackpad: boolean = false;
  @State enableDoubleClickDrag: boolean = false;
  @State doubleTapTimeThreshold: number = 125;
  @State analogScrolling: string = '右摇杆';
  @State mouseNavButtons: boolean = false;
  @State gameMouseMode: boolean = false;   // 游戏鼠标模式（相对模式+光标回弹）
  
  // 增强触控设置
  @State enableEnhancedTouch: boolean = true;
  @State enhancedTouchOnRight: boolean = false;
  @State enhancedTouchZoneDivider: number = 50;
  @State pointerVelocityFactor: number = 100;
  @State longPressFlatRegion: number = 0;
  
  // 主机设置
  @State enableSops: boolean = true;
  @State screenCombinationMode: string = '自动';
  @State lockScreenAfterDisconnect: boolean = false;
  @State swapQuitAndDisconnect: boolean = false;
  
  // 高级设置
  @State decoderBufferCount: number = 0;
  @State enableSyncDecode: boolean = false;  // 同步解码模式，默认禁用
  @State enableVrr: boolean = false;  // VRR 可变刷新率，默认禁用
  @State enableVsync: boolean = false;
  @State performanceMode: boolean = false;  // 性能模式，默认禁用
  @State enablePerfOverlay: boolean = false;
  @State perfOverlayOrientation: string = '垂直';
  @State perfOverlayPosition: string = '右上角';
  @State perfOverlayLocked: boolean = false;
  @State perfOverlayItems: string[] = ['resolution', 'decoder', 'render_fps', 'packet_loss', 'bitrate', 'network_latency', 'decode_latency'];
  @State latencyToast: boolean = false;
  @State disableWarnings: boolean = false;
  @State reduceRefreshRate: boolean = false;
  @State enableStun: boolean = false;
  @State enableEscMenu: boolean = true;
  @State escMenuKey: string = 'ESC';
  @State enableBackgroundTask: boolean = true;  // 后台保活，默认开启
  
  // UI 设置
  @State smallIconMode: boolean = false;
  @State language: string = '跟随系统';
  @State backgroundImageType: string = 'default';
  @State backgroundImageUrl: string = '';
  @State resumeStream: boolean = false;
  @State developerMode: boolean = false;  // 开发者模式
  
  // 应用版本
  @State appVersion: string = '';
  
  // 加载状态
  @State isLoading: boolean = true;
  
  // 当前展开的分组（默认展开视频分组）
  @State expandedGroup: string = 'video';
  
  // 宽屏模式（横屏时使用左导航+右内容布局）
  @State isWideScreen: boolean = false;
  
  // 侧边栏分组元数据
  private sidebarGroups: SidebarGroupMeta[] = [
    { id: 'video', icon: $r('sys.symbol.video_fill'), title: '视频', useSymbol: true } as SidebarGroupMeta,
    { id: 'audio', icon: $r('sys.symbol.speaker_wave_2_fill'), title: '音频', useSymbol: true } as SidebarGroupMeta,
    { id: 'gamepad', icon: $r('sys.symbol.gamecontroller_fill'), title: '手柄', useSymbol: true } as SidebarGroupMeta,
    { id: 'osc', icon: $r('sys.symbol.gamecontroller'), title: '屏幕控制器', useSymbol: true } as SidebarGroupMeta,
    { id: 'mouse', icon: $r('app.media.ic_mouse'), title: '鼠标触控', useSymbol: false } as SidebarGroupMeta,
    { id: 'enhanced_touch', icon: $r('sys.symbol.bolt_fill'), title: '增强触控', useSymbol: true } as SidebarGroupMeta,
    { id: 'host', icon: $r('app.media.ic_host'), title: '主机', useSymbol: false } as SidebarGroupMeta,
    { id: 'advanced', icon: $r('sys.symbol.gearshape_fill'), title: '高级', useSymbol: true } as SidebarGroupMeta,
    { id: 'ui', icon: $r('sys.symbol.display'), title: '界面', useSymbol: true } as SidebarGroupMeta,
    { id: 'about', icon: $r('sys.symbol.info_circle_fill'), title: '关于', useSymbol: true } as SidebarGroupMeta,
  ];
  
  // 解码器能力
  @State decoderCapabilities: DecoderCapabilities | null = null;
  
  // 文本输入弹窗状态
  @State showTextInputDialog: boolean = false;
  @State textInputTitle: string = '';
  @State textInputPlaceholder: string = '';
  @State textInputValue: string = '';
  private textInputCallback: ((value: string) => void) | null = null;
  
  // 自定义分辨率输入弹窗状态
  @State customResWidth: string = '';
  @State customResHeight: string = '';
  @State customResAspectRatio: string = '';
  
  // 底部弹窗类型: 'text' = 文本输入, 'resolution' = 自定义分辨率
  private bottomSheetType: string = 'text';
  
  // OptionPickerDialog 配置
  private optionPickerDialogConfig: OptionPickerDialogConfig = {
    title: '',
    options: [],
    onSelect: () => {}
  };
  
  // MultiOptionPickerDialog 配置
  private multiOptionPickerDialogConfig: MultiOptionPickerDialogConfig = {
    title: '',
    options: [],
    selectedKeys: [],
    minSelected: 1,
    onSelectionChange: () => {}
  };
  
  // CustomDialogController
  private optionPickerDialogController: CustomDialogController | null = null;
  private multiOptionPickerDialogController: CustomDialogController | null = null;
  private licensesDialogController: CustomDialogController | null = null;
  private privacyDialogController: CustomDialogController | null = null;
  private changelogDialogController: CustomDialogController | null = null;
  
  // 本地分辨率
  private nativeWidth: number = 0;
  private nativeHeight: number = 0;

  aboutToAppear(): void {
    this.loadVersionInfo();
    this.loadNativeResolution();
    this.loadSettings();
    this.loadDecoderCapabilities();
  }

  onBackPress(): boolean {
    router.back();
    return true;
  }

  private loadVersionInfo(): void {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = bundleInfo.versionName;
    } catch (e) {
      this.appVersion = '未知';
    }
  }
  
  /**
   * 获取设备本地分辨率（始终转换为横屏格式：宽 > 高）
   */
  private loadNativeResolution(): void {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      // 确保始终是横屏格式（宽 > 高）
      if (displayInfo.width >= displayInfo.height) {
        this.nativeWidth = displayInfo.width;
        this.nativeHeight = displayInfo.height;
      } else {
        // 竖屏状态下交换宽高
        this.nativeWidth = displayInfo.height;
        this.nativeHeight = displayInfo.width;
      }
      console.info(`本地分辨率 (横屏): ${this.nativeWidth}x${this.nativeHeight}`);
    } catch (e) {
      console.error(`获取本地分辨率失败: ${e}`);
      this.nativeWidth = 0;
      this.nativeHeight = 0;
    }
  }
  
  /**
   * 显示 Toast 提示
   * @param message 提示消息
   * @param duration 持续时间（毫秒），默认 2000ms
   */
  private showToast(message: string, duration: number = 2000): void {
    promptAction.showToast({
      message: message,
      duration: duration
    });
  }
  
  private loadDecoderCapabilities(): void {
    try {
      this.decoderCapabilities = StreamingSession.getDecoderCapabilities();
      console.info(`解码器能力: H264=${this.decoderCapabilities.supportsH264}, HEVC=${this.decoderCapabilities.supportsHEVC}, AV1=${this.decoderCapabilities.supportsAV1}`);
    } catch (e) {
      console.error(`获取解码器能力失败: ${e}`);
      // 默认假设只支持 H.264
      this.decoderCapabilities = {
        supportsH264: true,
        supportsHEVC: false,
        supportsAV1: false,
        maxWidth: 1920,
        maxHeight: 1080,
        maxFps: 60,
        supportsLowLatency: false,
        supports4K60: false,
        supports4K120: false,
        supports1080p120: false,
        maxInstances: 1
      };
    }
  }

  /**
   * 获取当前设置的推荐码率（Mbps）
   */
  private getRecommendedBitrateForCurrentSettings(): number {
    // 解析当前分辨率
    let width = 1920;
    let height = 1080;
    switch (this.resolution) {
      case '720p': width = 1280; height = 720; break;
      case '1080p': width = 1920; height = 1080; break;
      case '1440p': width = 2560; height = 1440; break;
      case '4K': width = 3840; height = 2160; break;
      default:
        // 尝试解析自定义分辨率格式 WIDTHxHEIGHT
        const match = this.resolution.match(/^(\d+)x(\d+)$/);
        if (match) {
          width = parseInt(match[1]);
          height = parseInt(match[2]);
        }
    }
    
    // 应用缩放
    if (this.hostScale !== 100) {
      width = Math.round(width * this.hostScale / 100);
      height = Math.round(height * this.hostScale / 100);
    }
    
    // 解析帧率
    let fps = 60;
    if (this.fps.startsWith('自定义:')) {
      // 自定义帧率
      fps = parseInt(this.fps.split(':')[1]) || 60;
    } else {
      switch (this.fps) {
        case '30 FPS': fps = 30; break;
        case '60 FPS': fps = 60; break;
        case '90 FPS': fps = 90; break;
        case '119.88 FPS': fps = 120; break;
        case '120 FPS': fps = 120; break;
        default: fps = 60; break;
      }
    }
    
    // 计算推荐码率（返回 Mbps）
    return Math.round(getRecommendedBitrate(width, height, fps) / 1000);
  }

  private async loadSettings(): Promise<void> {
    try {
      // 视频设置
      this.resolution = await PreferencesUtil.get<string>(SettingsKeys.RESOLUTION, '1080p');
      // 加载自定义分辨率列表
      const customResStr = await PreferencesUtil.get<string>(SettingsKeys.CUSTOM_RESOLUTIONS, '');
      this.customResolutions = customResStr ? customResStr.split(',').filter(s => s.length > 0) : [];
      this.fps = await PreferencesUtil.get<string>(SettingsKeys.FPS, '60 FPS');
      this.customFps = await PreferencesUtil.get<number>(SettingsKeys.CUSTOM_FPS, 0);
      this.bitrate = await PreferencesUtil.get<number>(SettingsKeys.BITRATE, 0);
      this.hostScale = await PreferencesUtil.get<number>(SettingsKeys.HOST_SCALE, 100);
      this.enableHdr = await this.loadBoolean(SettingsKeys.ENABLE_HDR, false);
      this.hdrMode = await PreferencesUtil.get<string>(SettingsKeys.HDR_MODE, 'HDR10');
      this.enableHdrHighBrightness = await this.loadBoolean(SettingsKeys.ENABLE_HDR_HIGH_BRIGHTNESS, false);
      this.videoFormat = await PreferencesUtil.get<string>(SettingsKeys.VIDEO_FORMAT, '自动');
      this.stretchVideo = await this.loadBoolean(SettingsKeys.STRETCH_VIDEO, false);
      this.fullRange = await this.loadBoolean(SettingsKeys.FULL_RANGE, false);
      this.reverseResolution = await this.loadBoolean(SettingsKeys.REVERSE_RESOLUTION, false);
      this.rotableScreen = await this.loadBoolean(SettingsKeys.ROTABLE_SCREEN, false);
      
      // 音频设置
      this.audioConfig = await PreferencesUtil.get<string>(SettingsKeys.AUDIO_CONFIG, '立体声');
      this.enableLocalAudio = await this.loadBoolean(SettingsKeys.ENABLE_LOCAL_AUDIO, false);
      this.enableSpatializer = await this.loadBoolean(SettingsKeys.ENABLE_SPATIALIZER, false);
      this.controlOnly = await this.loadBoolean(SettingsKeys.CONTROL_ONLY, false);
      this.enableMic = await this.loadBoolean(SettingsKeys.ENABLE_MIC, false);
      this.micBitrate = await PreferencesUtil.get<number>(SettingsKeys.MIC_BITRATE, 64);
      
      // 输入 - 手柄设置
      this.enableVibration = await this.loadBoolean(SettingsKeys.ENABLE_VIBRATION, true);
      this.vibrationMode = await PreferencesUtil.get<string>(SettingsKeys.VIBRATION_MODE, '自动');
      this.vibrateFallbackStrength = await PreferencesUtil.get<number>(SettingsKeys.VIBRATE_FALLBACK_STRENGTH, 100);
      this.enableAudioVibration = await this.loadBoolean(SettingsKeys.ENABLE_AUDIO_VIBRATION, false);
      this.audioVibrationStrength = await PreferencesUtil.get<number>(SettingsKeys.AUDIO_VIBRATION_STRENGTH, 60);
      this.audioVibrationSceneMode = await PreferencesUtil.get<string>(SettingsKeys.AUDIO_VIBRATION_SCENE_MODE, '游戏/电影');
      this.multiController = await this.loadBoolean(SettingsKeys.MULTI_CONTROLLER, true);
      this.flipFaceButtons = await this.loadBoolean(SettingsKeys.FLIP_FACE_BUTTONS, false);
      this.deadzone = await PreferencesUtil.get<number>(SettingsKeys.DEADZONE, 7);
      this.gamepadMotionSensors = await this.loadBoolean(SettingsKeys.GAMEPAD_MOTION_SENSORS, true);
      this.gamepadMotionFallback = await this.loadBoolean(SettingsKeys.GAMEPAD_MOTION_FALLBACK, false);
      this.gamepadTouchpadMouse = await this.loadBoolean(SettingsKeys.GAMEPAD_TOUCHPAD_MOUSE, false);
      this.enableStartKeyMenu = await this.loadBoolean(SettingsKeys.ENABLE_START_KEY_MENU, true);
      this.ignoreDeviceDisconnect = await this.loadBoolean(SettingsKeys.IGNORE_DEVICE_DISCONNECT, false);
      this.enableKeyInterceptor = await this.loadBoolean(SettingsKeys.ENABLE_KEY_INTERCEPTOR, false);
      // 检查按键注入 API 是否可用（API 13+），不可用则强制禁用反劫持
      this.keyInterceptorAvailable = InputInterceptorService.getInstance().isInjectApiAvailable();
      if (!this.keyInterceptorAvailable && this.enableKeyInterceptor) {
        this.enableKeyInterceptor = false;
        this.saveSetting(SettingsKeys.ENABLE_KEY_INTERCEPTOR, false);
      }
      this.gcButtonHomeMapping = await PreferencesUtil.get<string>(SettingsKeys.GC_BUTTON_HOME_MAPPING, 'guide');
      this.usbDriverEnabled = await this.loadBoolean(SettingsKeys.USB_DRIVER_ENABLED, false);
      this.forceUsbDriverOnly = await this.loadBoolean(SettingsKeys.FORCE_USB_DRIVER_ONLY, false);
      
      // 输入 - 屏幕控制器
      this.enableOnscreenControls = await this.loadBoolean(SettingsKeys.ENABLE_ONSCREEN_CONTROLS, false);
      this.enableOnscreenKeyboard = await this.loadBoolean(SettingsKeys.ENABLE_ONSCREEN_KEYBOARD, false);
      this.onlyL3R3 = await this.loadBoolean(SettingsKeys.ONLY_L3_R3, false);
      this.showGuideButton = await this.loadBoolean(SettingsKeys.SHOW_GUIDE_BUTTON, true);
      this.halfHeightOscPortrait = await this.loadBoolean(SettingsKeys.HALF_HEIGHT_OSC_PORTRAIT, true);
      this.oscOpacity = await PreferencesUtil.get<number>(SettingsKeys.OSC_OPACITY, 90);
      this.vibrateOsc = await this.loadBoolean(SettingsKeys.VIBRATE_OSC, true);
      
      // 输入 - 鼠标/触控
      this.showLocalCursor = await this.loadBoolean(SettingsKeys.SHOW_LOCAL_CURSOR, false);
      this.touchscreenTrackpad = await this.loadBoolean(SettingsKeys.TOUCHSCREEN_TRACKPAD, false);
      this.enableDoubleClickDrag = await this.loadBoolean(SettingsKeys.ENABLE_DOUBLE_CLICK_DRAG, false);
      this.doubleTapTimeThreshold = await PreferencesUtil.get<number>(SettingsKeys.DOUBLE_TAP_TIME_THRESHOLD, 125);
      this.analogScrolling = await PreferencesUtil.get<string>(SettingsKeys.ANALOG_SCROLLING, '右摇杆');
      this.mouseNavButtons = await this.loadBoolean(SettingsKeys.MOUSE_NAV_BUTTONS, false);
      this.gameMouseMode = await this.loadBoolean(SettingsKeys.GAME_MOUSE_MODE, false);
      
      // 增强触控设置
      this.enableEnhancedTouch = await this.loadBoolean(SettingsKeys.ENABLE_ENHANCED_TOUCH, true);
      this.enhancedTouchOnRight = await this.loadBoolean(SettingsKeys.ENHANCED_TOUCH_ON_RIGHT, false);
      this.enhancedTouchZoneDivider = await PreferencesUtil.get<number>(SettingsKeys.ENHANCED_TOUCH_ZONE_DIVIDER, 50);
      this.pointerVelocityFactor = await PreferencesUtil.get<number>(SettingsKeys.POINTER_VELOCITY_FACTOR, 100);
      this.longPressFlatRegion = await PreferencesUtil.get<number>(SettingsKeys.LONG_PRESS_FLAT_REGION, 0);
      
      // 主机设置
      this.enableSops = await this.loadBoolean(SettingsKeys.ENABLE_SOPS, true);
      this.screenCombinationMode = await PreferencesUtil.get<string>(SettingsKeys.SCREEN_COMBINATION_MODE, '自动');
      this.lockScreenAfterDisconnect = await this.loadBoolean(SettingsKeys.LOCK_SCREEN_AFTER_DISCONNECT, false);
      this.swapQuitAndDisconnect = await this.loadBoolean(SettingsKeys.SWAP_QUIT_AND_DISCONNECT, false);
      
      // 高级设置
      this.decoderBufferCount = await PreferencesUtil.get<number>(SettingsKeys.DECODER_BUFFER_COUNT, 0);
      this.enableSyncDecode = await this.loadBoolean(SettingsKeys.ENABLE_SYNC_DECODE, false);  // 默认禁用
      this.enableVrr = await this.loadBoolean(SettingsKeys.ENABLE_VRR, false);  // VRR 默认禁用
      this.enableVsync = await this.loadBoolean(SettingsKeys.ENABLE_VSYNC, false);
      this.performanceMode = await this.loadBoolean(SettingsKeys.PERFORMANCE_MODE, false);  // 性能模式默认禁用
      this.enablePerfOverlay = await this.loadBoolean(SettingsKeys.ENABLE_PERF_OVERLAY, false);
      this.perfOverlayOrientation = await PreferencesUtil.get<string>(SettingsKeys.PERF_OVERLAY_ORIENTATION, '垂直');
      this.perfOverlayPosition = await PreferencesUtil.get<string>(SettingsKeys.PERF_OVERLAY_POSITION, '右上角');
      this.perfOverlayLocked = await this.loadBoolean(SettingsKeys.PERF_OVERLAY_LOCKED, false);
      const itemsStr = await PreferencesUtil.get<string>(SettingsKeys.PERF_OVERLAY_ITEMS, 'resolution,decoder,render_fps,packet_loss,bitrate,network_latency,decode_latency');
      this.perfOverlayItems = itemsStr.split(',').filter(item => item.length > 0);
      this.latencyToast = await this.loadBoolean(SettingsKeys.LATENCY_TOAST, false);
      this.disableWarnings = await this.loadBoolean(SettingsKeys.DISABLE_WARNINGS, false);
      this.reduceRefreshRate = await this.loadBoolean(SettingsKeys.REDUCE_REFRESH_RATE, false);
      this.enableStun = await this.loadBoolean(SettingsKeys.ENABLE_STUN, false);
      this.enableEscMenu = await this.loadBoolean(SettingsKeys.ENABLE_ESC_MENU, true);
      this.escMenuKey = await PreferencesUtil.get<string>(SettingsKeys.ESC_MENU_KEY, 'ESC');
      this.enableBackgroundTask = await this.loadBoolean(SettingsKeys.ENABLE_BACKGROUND_TASK, true);
      
      // UI 设置
      this.smallIconMode = await this.loadBoolean(SettingsKeys.SMALL_ICON_MODE, false);
      this.language = await PreferencesUtil.get<string>(SettingsKeys.LANGUAGE, '跟随系统');
      this.backgroundImageType = await PreferencesUtil.get<string>(SettingsKeys.BACKGROUND_IMAGE_TYPE, 'default');
      this.backgroundImageUrl = await PreferencesUtil.get<string>(SettingsKeys.BACKGROUND_IMAGE_URL, '');
      this.resumeStream = await this.loadBoolean(SettingsKeys.RESUME_STREAM, false);
      this.developerMode = await this.loadBoolean(SettingsKeys.DEVELOPER_MODE, false);
    } catch (error) {
      console.error('Failed to load settings:', error);
    } finally {
      this.isLoading = false;
    }
  }
  
  /**
   * 获取 Home 键动作描述
   */
  private getHomeButtonActionDescription(): string {
    switch (this.gcButtonHomeMapping) {
      case 'guide': return '发送 Guide 键';
      case 'select': return '发送 Select 键';
      case 'toggle_mouse': return '切换鼠标模式';
      case 'toggle_perf': return '切换性能图层';
      case 'show_menu': return '显示游戏菜单';
      case 'none': return '无动作';
      default: return '发送 Guide 键';
    }
  }

  private async loadBoolean(key: string, defaultVal: boolean): Promise<boolean> {
    const val = await PreferencesUtil.get<boolean>(key, defaultVal);
    if (typeof val === 'boolean') return val;
    return String(val) === 'true';
  }

  private async saveSetting(key: string, value: string | boolean | number): Promise<void> {
    try {
      await PreferencesUtil.put(key, value);
    } catch (error) {
      console.error('Failed to save setting:', error);
      this.showToast('保存设置失败');
    }
  }
  
  /**
   * 显示自定义选择器弹窗 - 使用 CustomDialogController
   */
  private showPicker(config: PickerConfig): void {
    console.info(`SettingsPageV2: showPicker 被调用, title=${config.title}`);
    console.info(`SettingsPageV2: options count = ${config.options?.length}`);
    
    // 转换为 DialogOptionItem 格式
    const options: DialogOptionItem[] = config.options.map((option: PickerOption) => {
      return {
        title: option.title,
        subtitle: option.subtitle,
        value: option.value
      } as DialogOptionItem;
    });
    
    // 配置弹窗
    this.optionPickerDialogConfig = {
      title: config.title,
      subtitle: config.subtitle,
      options: options,
      selectedValue: config.selectedValue,
      onSelect: (option: DialogOptionItem) => {
        console.info(`SettingsPageV2: 选中了 ${option.title}`);
        const pickerOption: PickerOption = {
          title: option.title,
          subtitle: option.subtitle,
          value: option.value
        };
        config.onSelect(pickerOption);
      }
    };
    
    // 创建并打开弹窗
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
   * 统一底部弹窗内容
   */
  @Builder
  BottomSheetContent() {
    if (this.bottomSheetType === 'resolution') {
      this.CustomResolutionSheet()
    } else {
      this.TextInputSheet()
    }
  }

  /**
   * 文本输入弹窗
   */
  @Builder
  TextInputSheet() {
    Column({ space: AppSpacing.Large }) {
      // 标题栏
      Row() {
        Text(this.textInputTitle)
          .fontSize(AppSizes.FontTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.TextPrimary)
      }
      .width('100%')
      .padding({ top: AppSpacing.Large, left: AppSpacing.Large, right: AppSpacing.Large })
      
      // 输入框
      TextInput({ text: this.textInputValue, placeholder: this.textInputPlaceholder })
        .width('100%')
        .height(48)
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextPrimary)
        .backgroundColor(AppColors.Surface)
        .borderRadius(AppSizes.RadiusMedium)
        .padding({ left: AppSpacing.Medium, right: AppSpacing.Medium })
        .margin({ left: AppSpacing.Large, right: AppSpacing.Large })
        .onChange((value: string) => {
          this.textInputValue = value;
        })
      
      // 按钮行
      Row({ space: AppSpacing.Medium }) {
        Button('清除')
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.Error)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .height(48)
          .onClick(() => {
            this.textInputValue = '';
            if (this.textInputCallback) {
              this.textInputCallback('');
            }
            this.showTextInputDialog = false;
          })
        
        Button('取消')
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextSecondary)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .height(48)
          .onClick(() => {
            this.showTextInputDialog = false;
          })
        
        Button('确定')
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextOnPrimary)
          .backgroundColor(AppColors.Primary)
          .layoutWeight(1)
          .height(48)
          .borderRadius(AppSizes.RadiusMedium)
          .onClick(() => {
            if (this.textInputCallback) {
              this.textInputCallback(this.textInputValue);
            }
            this.showTextInputDialog = false;
          })
      }
      .width('100%')
      .padding({ left: AppSpacing.Large, right: AppSpacing.Large, bottom: AppSpacing.Large })
    }
    .width('100%')
    .backgroundColor(AppColors.CardBackground)
    .borderRadius(24)
  }

  /**
   * 计算宽高比的友好描述
   */
  private calcAspectRatio(w: number, h: number): string {
    if (w <= 0 || h <= 0) return '';
    const gcd = (a: number, b: number): number => b === 0 ? a : gcd(b, a % b);
    const d = gcd(w, h);
    const rw = w / d;
    const rh = h / d;
    // 常见宽高比映射
    const ratio = w / h;
    if (Math.abs(ratio - 16 / 9) < 0.02) return '16:9';
    if (Math.abs(ratio - 16 / 10) < 0.02) return '16:10';
    if (Math.abs(ratio - 21 / 9) < 0.05) return '21:9 超宽';
    if (Math.abs(ratio - 32 / 9) < 0.05) return '32:9 超超宽';
    if (Math.abs(ratio - 4 / 3) < 0.02) return '4:3';
    if (Math.abs(ratio - 3 / 2) < 0.02) return '3:2';
    if (Math.abs(ratio - 5 / 4) < 0.02) return '5:4';
    return `${rw}:${rh}`;
  }

  /**
   * 自定义分辨率输入弹窗 — 分离宽高输入 + 快捷预设
   */
  @Builder
  CustomResolutionSheet() {
    Column({ space: AppSpacing.Medium }) {
      // 标题
      Text('添加自定义分辨率')
        .fontSize(AppSizes.FontTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.TextPrimary)
        .width('100%')
        .padding({ top: AppSpacing.Large, left: AppSpacing.Large, right: AppSpacing.Large })

      // 宽度 × 高度 输入行
      Row({ space: AppSpacing.Small }) {
        TextInput({ text: this.customResWidth, placeholder: '宽度' })
          .type(InputType.Number)
          .width(0)
          .layoutWeight(1)
          .height(48)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextPrimary)
          .backgroundColor(AppColors.Surface)
          .borderRadius(AppSizes.RadiusMedium)
          .textAlign(TextAlign.Center)
          .onChange((value: string) => {
            this.customResWidth = value;
            const w = parseInt(value) || 0;
            const h = parseInt(this.customResHeight) || 0;
            this.customResAspectRatio = this.calcAspectRatio(w, h);
          })

        Text('×')
          .fontSize(20)
          .fontColor(AppColors.TextSecondary)
          .fontWeight(FontWeight.Bold)

        TextInput({ text: this.customResHeight, placeholder: '高度' })
          .type(InputType.Number)
          .width(0)
          .layoutWeight(1)
          .height(48)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextPrimary)
          .backgroundColor(AppColors.Surface)
          .borderRadius(AppSizes.RadiusMedium)
          .textAlign(TextAlign.Center)
          .onChange((value: string) => {
            this.customResHeight = value;
            const w = parseInt(this.customResWidth) || 0;
            const h = parseInt(value) || 0;
            this.customResAspectRatio = this.calcAspectRatio(w, h);
          })
      }
      .width('100%')
      .padding({ left: AppSpacing.Large, right: AppSpacing.Large })

      // 宽高比提示 + 验证提示
      if (this.customResAspectRatio.length > 0) {
        Text(`宽高比: ${this.customResAspectRatio}`)
          .fontSize(AppSizes.FontCaption)
          .fontColor(AppColors.Primary)
          .width('100%')
          .textAlign(TextAlign.Center)
      }

      // 常用分辨率快捷按钮
      Text('快速选择')
        .fontSize(AppSizes.FontCaption)
        .fontColor(AppColors.TextSecondary)
        .width('100%')
        .padding({ left: AppSpacing.Large })

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        ForEach([
          new ResolutionPreset('2K 超宽', '2560', '1080'),
          new ResolutionPreset('QHD 超宽', '3440', '1440'),
          new ResolutionPreset('1920×1200', '1920', '1200'),
          new ResolutionPreset('2560×1600', '2560', '1600'),
          new ResolutionPreset('1280×1024', '1280', '1024'),
          new ResolutionPreset('5120×1440', '5120', '1440'),
          new ResolutionPreset('5K', '5120', '2880'),
          new ResolutionPreset('8K', '7680', '4320'),
        ] as ResolutionPreset[], (item: ResolutionPreset) => {
          Button(item.label)
            .fontSize(AppSizes.FontCaption)
            .fontColor(AppColors.TextPrimary)
            .backgroundColor(AppColors.Surface)
            .height(32)
            .borderRadius(16)
            .padding({ left: 12, right: 12 })
            .onClick(() => {
              this.customResWidth = item.w;
              this.customResHeight = item.h;
              const w = parseInt(item.w);
              const h = parseInt(item.h);
              this.customResAspectRatio = this.calcAspectRatio(w, h);
            })
        })
      }
      .width('100%')
      .padding({ left: AppSpacing.Large, right: AppSpacing.Large })

      // 按钮行
      Row({ space: AppSpacing.Medium }) {
        Button('取消')
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextSecondary)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .height(48)
          .onClick(() => {
            this.showTextInputDialog = false;
          })
        
        Button('添加')
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextOnPrimary)
          .backgroundColor(AppColors.Primary)
          .layoutWeight(1)
          .height(48)
          .borderRadius(AppSizes.RadiusMedium)
          .onClick(() => {
            const w = this.customResWidth.trim();
            const h = this.customResHeight.trim();
            if (w.length > 0 && h.length > 0) {
              this.addCustomResolution(`${w}x${h}`);
            } else {
              this.showToast('请输入宽度和高度');
            }
            this.showTextInputDialog = false;
          })
      }
      .width('100%')
      .padding({ left: AppSpacing.Large, right: AppSpacing.Large, bottom: AppSpacing.Large })
    }
    .width('100%')
    .backgroundColor(AppColors.CardBackground)
    .borderRadius(24)
  }

  build() {
    Column() {
      // 标题栏
      if (this.isWideScreen) {
        this.TitleBar()
      } else {
        GridRow({ columns: 12 }) {
          GridCol({ span: { sm: 12, md: 10, lg: 8 }, offset: { sm: 0, md: 1, lg: 2 } }) {
            this.TitleBar()
          }
        }
      }
      
      // 宽屏：左导航 + 右内容 ；窄屏：垂直滚动列表
      Row() {
        if (this.isWideScreen) {
          this.SettingsSidebar()
        }
        
        // 设置列表
        Scroll() {
          GridRow({ columns: 12 }) {
            GridCol({
              span: this.isWideScreen ? 12 : { sm: 12, md: 10, lg: 8 },
              offset: this.isWideScreen ? 0 : { sm: 0, md: 1, lg: 2 }
            }) {
              Column() {
          // 视频设置
          this.SettingsGroup({
            id: 'video',
            icon: $r('sys.symbol.video_fill'),
            title: '视频',
            items: [
              {
                title: '分辨率',
                subtitle: this.resolution,
                type: 'select',
                action: () => this.showResolutionPicker()
              },
              {
                title: '帧率',
                subtitle: this.fps.startsWith('自定义:') 
                  ? `${this.fps.split(':')[1]} FPS (自定义)` 
                  : this.fps,
                type: 'select',
                action: () => this.showFpsPicker()
              },
              {
                title: '码率',
                subtitle: this.bitrate === 0 
                  ? `自动 (推荐: ${this.getRecommendedBitrateForCurrentSettings()} Mbps)` 
                  : '视频传输比特率',
                type: 'slider',
                value: this.bitrate,
                min: 1,  // 对数滑块最小值为1（0单独处理为"自动"）
                max: 800,  // 最高800 Mbps，对齐Android
                step: 1,
                unit: ' Mbps',
                isLogarithmic: true,  // 使用对数刻度，低码率精细调整，高码率粗调
                // 常用码率吸附值（会自动在对数转换后应用）
                snapValues: [5, 10, 15, 20, 30, 40, 50, 60, 80, 100, 120, 150, 200, 300, 400, 500],
                snapThreshold: 8,  // 比例阈值 8%（对数滑块自动按比例计算吸附范围）
                formatValue: (v: number) => v === 0 ? '自动' : `${Math.round(v)} Mbps`,
                onSliderChange: (value: number) => {
                  this.bitrate = value;
                  this.saveSetting(SettingsKeys.BITRATE, value);
                }
              },
              {
                title: '分辨率缩放',
                subtitle: '主机渲染分辨率比例',
                type: 'slider',
                value: this.hostScale,
                min: 50,   // Android: 50-400%, step 10
                max: 400,
                step: 10,
                unit: '%',
                // 常用缩放比例吸附值
                snapValues: [50, 75, 100, 125, 150, 200, 300, 400],
                snapThreshold: 5,
                formatValue: (v: number) => `${v}%`,
                onSliderChange: (value: number) => {
                  this.hostScale = value;
                  this.saveSetting(SettingsKeys.HOST_SCALE, value);
                }
              },
              {
                title: '视频格式',
                type: 'segment',
                value: this.videoFormat,
                segmentLabels: ['自动', 'H.264', 'HEVC', 'AV1'],
                onSegmentChange: (value: string) => {
                  if ((value === 'HEVC' && !(this.decoderCapabilities?.supportsHEVC)) ||
                      (value === 'AV1' && !(this.decoderCapabilities?.supportsAV1)) ||
                      (value === 'H.264' && !(this.decoderCapabilities?.supportsH264 ?? true))) {
                    this.showToast(`警告: 设备不支持 ${value}，串流可能失败`, 3000);
                  }
                  this.videoFormat = value;
                  this.saveSetting(SettingsKeys.VIDEO_FORMAT, value);
                  if (value === 'H.264' && this.enableHdr) {
                    this.enableHdr = false;
                    this.saveSetting(SettingsKeys.ENABLE_HDR, false);
                    this.showToast('H.264 不支持 HDR，已自动关闭');
                  }
                }
              },
              {
                title: 'HDR',
                subtitle: this.videoFormat === 'H.264' 
                  ? '❌ H.264 不支持 HDR' 
                  : '需要支持 HDR 的显示器',
                type: 'toggle',
                value: this.enableHdr,
                disabled: this.videoFormat === 'H.264',
                action: () => {
                  if (this.videoFormat === 'H.264') {
                    this.showToast('H.264 编码不支持 HDR，请选择 HEVC 或 AV1');
                    return;
                  }
                  this.enableHdr = !this.enableHdr;
                  this.saveSetting(SettingsKeys.ENABLE_HDR, this.enableHdr);
                }
              },
              {
                title: 'HDR 模式',
                subtitle: this.hdrMode === 'HLG' ? '需要 Sunshine Foundation' : undefined,
                type: 'segment',
                value: this.hdrMode,
                visible: this.enableHdr,
                disabled: this.videoFormat === 'H.264' || !this.enableHdr,
                segmentLabels: ['HDR10 (PQ)', 'HLG'],
                segmentValues: ['HDR10', 'HLG'],
                onSegmentChange: (value: string) => {
                  this.hdrMode = value;
                  this.saveSetting(SettingsKeys.HDR_MODE, value);
                }
              },
              {
                title: 'HDR 高亮度',
                subtitle: this.videoFormat === 'H.264' 
                  ? '❌ 需要 HEVC/AV1' 
                  : '使用高亮度 HDR 模式',
                type: 'toggle',
                visible: this.enableHdr,
                value: this.enableHdrHighBrightness,
                disabled: this.videoFormat === 'H.264' || !this.enableHdr,
                action: () => {
                  if (this.videoFormat === 'H.264') {
                    this.showToast('H.264 编码不支持 HDR');
                    return;
                  }
                  this.enableHdrHighBrightness = !this.enableHdrHighBrightness;
                  this.saveSetting(SettingsKeys.ENABLE_HDR_HIGH_BRIGHTNESS, this.enableHdrHighBrightness);
                }
              },
              {
                title: '画面拉伸',
                subtitle: '拉伸画面以填满屏幕',
                type: 'toggle',
                value: this.stretchVideo,
                action: () => {
                  this.stretchVideo = !this.stretchVideo;
                  this.saveSetting(SettingsKeys.STRETCH_VIDEO, this.stretchVideo);
                }
              },
              {
                title: '全范围颜色',
                subtitle: '使用完整颜色范围 (0-255)',
                type: 'toggle',
                value: this.fullRange,
                action: () => {
                  this.fullRange = !this.fullRange;
                  this.saveSetting(SettingsKeys.FULL_RANGE, this.fullRange);
                }
              },
              {
                title: '反转分辨率',
                subtitle: '交换宽度和高度',
                type: 'toggle',
                value: this.reverseResolution,
                action: () => {
                  this.reverseResolution = !this.reverseResolution;
                  this.saveSetting(SettingsKeys.REVERSE_RESOLUTION, this.reverseResolution);
                }
              },
              {
                title: '可旋转屏幕',
                subtitle: '允许屏幕旋转',
                type: 'toggle',
                value: this.rotableScreen,
                action: () => {
                  this.rotableScreen = !this.rotableScreen;
                  this.saveSetting(SettingsKeys.ROTABLE_SCREEN, this.rotableScreen);
                }
              }
            ]
          })
          
          // 音频设置
          this.SettingsGroup({
            id: 'audio',
            icon: $r('sys.symbol.speaker_wave_2_fill'),
            title: '音频',
            items: [
              {
                title: '音频配置',
                type: 'segment',
                value: this.audioConfig,
                segmentLabels: ['立体声', '5.1 环绕', '7.1 环绕'],
                onSegmentChange: (value: string) => {
                  this.audioConfig = value;
                  this.saveSetting(SettingsKeys.AUDIO_CONFIG, value);
                }
              },
              {
                title: '本地音频',
                subtitle: '同时在主机上播放音频',
                type: 'toggle',
                value: this.enableLocalAudio,
                action: () => {
                  this.enableLocalAudio = !this.enableLocalAudio;
                  this.saveSetting(SettingsKeys.ENABLE_LOCAL_AUDIO, this.enableLocalAudio);
                }
              },
              {
                title: '空间音频',
                subtitle: '启用空间音频效果（需系统支持）',
                type: 'toggle',
                value: this.enableSpatializer,
                action: () => {
                  this.enableSpatializer = !this.enableSpatializer;
                  this.saveSetting(SettingsKeys.ENABLE_SPATIALIZER, this.enableSpatializer);
                }
              },
              {
                title: '仅控制模式',
                subtitle: '禁用音视频，仅传输输入',
                type: 'toggle',
                value: this.controlOnly,
                action: () => {
                  this.controlOnly = !this.controlOnly;
                  this.saveSetting(SettingsKeys.CONTROL_ONLY, this.controlOnly);
                }
              },
              {
                title: '启用麦克风',
                subtitle: this.developerMode ? '将麦克风音频传输到主机' : '需要开发者模式',
                type: 'toggle',
                value: this.enableMic,
                isPro: true,
                disabled: !this.developerMode,
                action: () => {
                  if (this.developerMode) {
                    this.enableMic = !this.enableMic;
                    this.saveSetting(SettingsKeys.ENABLE_MIC, this.enableMic);
                  }
                }
              },
              {
                title: '麦克风码率',
                subtitle: this.developerMode ? '麦克风传输比特率' : '需要开发者模式',
                type: 'slider',
                visible: this.enableMic,
                value: this.micBitrate,
                min: 16,
                max: 256,
                step: 16,
                unit: ' kbps',
                isPro: true,
                disabled: !this.developerMode,
                onSliderChange: (value: number) => {
                  if (this.developerMode) {
                    this.micBitrate = value;
                    this.saveSetting(SettingsKeys.MIC_BITRATE, value);
                  }
                }
              },
              {
                title: '音频振动',
                subtitle: '根据游戏音频低频内容驱动振动',
                type: 'toggle',
                value: this.enableAudioVibration,
                action: () => {
                  this.enableAudioVibration = !this.enableAudioVibration;
                  this.saveSetting(SettingsKeys.ENABLE_AUDIO_VIBRATION, this.enableAudioVibration);
                }
              },
              {
                title: '音频振动强度',
                subtitle: '低频触发振动的强度',
                type: 'slider',
                visible: this.enableAudioVibration,
                value: this.audioVibrationStrength,
                min: 10,
                max: 100,
                step: 5,
                unit: '%',
                onSliderChange: (value: number) => {
                  this.audioVibrationStrength = value;
                  this.saveSetting(SettingsKeys.AUDIO_VIBRATION_STRENGTH, value);
                }
              },
              {
                title: '音频振动场景',
                type: 'segment',
                value: this.audioVibrationSceneMode,
                visible: this.enableAudioVibration,
                segmentLabels: ['游戏/电影', '音乐/节奏', '自动'],
                onSegmentChange: (value: string) => {
                  this.audioVibrationSceneMode = value;
                  this.saveSetting(SettingsKeys.AUDIO_VIBRATION_SCENE_MODE, value);
                }
              }
            ]
          })
          
          // 手柄设置
          this.SettingsGroup({
            id: 'gamepad',
            icon: $r('sys.symbol.gamecontroller_fill'),
            title: '手柄',
            items: [
              {
                title: '振动反馈',
                subtitle: '手柄振动反馈',
                type: 'toggle',
                value: this.enableVibration,
                action: () => {
                  this.enableVibration = !this.enableVibration;
                  this.saveSetting(SettingsKeys.ENABLE_VIBRATION, this.enableVibration);
                }
              },
              {
                title: '震动模式',
                type: 'segment',
                value: this.vibrationMode,
                visible: this.enableVibration,
                segmentLabels: ['自动', '仅手柄', '仅设备', '同时'],
                onSegmentChange: (value: string) => {
                  this.vibrationMode = value;
                  this.saveSetting(SettingsKeys.VIBRATION_MODE, value);
                }
              },
              {
                title: '设备振动强度',
                subtitle: '使用设备震动时的强度',
                type: 'slider',
                visible: this.enableVibration,
                value: this.vibrateFallbackStrength,
                min: 0,
                max: 100,
                step: 5,
                unit: '%',
                onSliderChange: (value: number) => {
                  this.vibrateFallbackStrength = value;
                  this.saveSetting(SettingsKeys.VIBRATE_FALLBACK_STRENGTH, value);
                }
              },
              {
                title: '多手柄支持',
                subtitle: '支持多个游戏手柄',
                type: 'toggle',
                value: this.multiController,
                action: () => {
                  this.multiController = !this.multiController;
                  this.saveSetting(SettingsKeys.MULTI_CONTROLLER, this.multiController);
                }
              },
              {
                title: '翻转 A/B X/Y',
                subtitle: '交换确认和取消按钮',
                type: 'toggle',
                value: this.flipFaceButtons,
                action: () => {
                  this.flipFaceButtons = !this.flipFaceButtons;
                  this.saveSetting(SettingsKeys.FLIP_FACE_BUTTONS, this.flipFaceButtons);
                }
              },
              {
                title: '摇杆死区',
                subtitle: '摇杆输入死区',
                type: 'slider',
                value: this.deadzone,
                min: 0,
                max: 50,
                step: 1,
                unit: '%',
                onSliderChange: (value: number) => {
                  this.deadzone = value;
                  this.saveSetting(SettingsKeys.DEADZONE, value);
                }
              },
              {
                title: '手柄运动传感器',
                subtitle: '启用陀螺仪和加速度计',
                type: 'toggle',
                value: this.gamepadMotionSensors,
                action: () => {
                  this.gamepadMotionSensors = !this.gamepadMotionSensors;
                  this.saveSetting(SettingsKeys.GAMEPAD_MOTION_SENSORS, this.gamepadMotionSensors);
                }
              },
              {
                title: '设备运动传感器回退',
                subtitle: '使用设备传感器替代手柄',
                type: 'toggle',
                visible: this.gamepadMotionSensors,
                value: this.gamepadMotionFallback,
                action: () => {
                  this.gamepadMotionFallback = !this.gamepadMotionFallback;
                  this.saveSetting(SettingsKeys.GAMEPAD_MOTION_FALLBACK, this.gamepadMotionFallback);
                }
              },
              {
                title: '触摸板作为鼠标',
                subtitle: '手柄触摸板模拟鼠标',
                type: 'toggle',
                value: this.gamepadTouchpadMouse,
                action: () => {
                  this.gamepadTouchpadMouse = !this.gamepadTouchpadMouse;
                  this.saveSetting(SettingsKeys.GAMEPAD_TOUCHPAD_MOUSE, this.gamepadTouchpadMouse);
                }
              },
              {
                title: '长按 Start 菜单',
                subtitle: '长按 Start 键显示菜单',
                type: 'toggle',
                value: this.enableStartKeyMenu,
                action: () => {
                  this.enableStartKeyMenu = !this.enableStartKeyMenu;
                  this.saveSetting(SettingsKeys.ENABLE_START_KEY_MENU, this.enableStartKeyMenu);
                }
              },
              {
                title: '忽略手柄断开',
                subtitle: '忽略手柄断开信号，适用于有电源管理问题的手柄（如 Razer）',
                type: 'toggle',
                value: this.ignoreDeviceDisconnect,
                action: () => {
                  this.ignoreDeviceDisconnect = !this.ignoreDeviceDisconnect;
                  this.saveSetting(SettingsKeys.IGNORE_DEVICE_DISCONNECT, this.ignoreDeviceDisconnect);
                }
              },
              {
                title: '按键反劫持',
                subtitle: '防止蓝牙手柄 Home 键退出 App（需系统级签名，否则可能无效）',
                type: 'toggle',
                value: this.enableKeyInterceptor,
                visible: this.keyInterceptorAvailable,
                action: () => {
                  this.enableKeyInterceptor = !this.enableKeyInterceptor;
                  this.saveSetting(SettingsKeys.ENABLE_KEY_INTERCEPTOR, this.enableKeyInterceptor);
                }
              },
              {
                title: 'Home 键动作',
                subtitle: this.getHomeButtonActionDescription(),
                type: 'select',
                value: this.gcButtonHomeMapping,
                action: () => {
                  this.showHomeButtonActionPicker();
                }
              },
              {
                title: 'USB 手柄驱动',
                subtitle: '启用 USB 手柄的震动和 LED 等高级功能。手柄输入仍由系统统一处理',
                type: 'toggle',
                value: this.usbDriverEnabled,
                action: () => {
                  this.usbDriverEnabled = !this.usbDriverEnabled;
                  this.saveSetting(SettingsKeys.USB_DRIVER_ENABLED, this.usbDriverEnabled);
                  // 关闭 USB 驱动时，同步关闭强制模式
                  if (!this.usbDriverEnabled && this.forceUsbDriverOnly) {
                    this.forceUsbDriverOnly = false;
                    this.saveSetting(SettingsKeys.FORCE_USB_DRIVER_ONLY, false);
                  }
                  promptAction.showToast({
                    message: '下次串流时生效',
                    duration: 2500
                  });
                }
              },
              {
                title: '强制 USB 驱动接管输入',
                subtitle: '禁用系统手柄服务（GCK），由 USB 驱动直接处理输入。适用于 GCK 兼容性差的手柄，也可在串流菜单中临时切换',
                type: 'toggle',
                value: this.forceUsbDriverOnly,
                visible: this.usbDriverEnabled,
                action: () => {
                  this.forceUsbDriverOnly = !this.forceUsbDriverOnly;
                  this.saveSetting(SettingsKeys.FORCE_USB_DRIVER_ONLY, this.forceUsbDriverOnly);
                  promptAction.showToast({
                    message: '下次串流时生效',
                    duration: 2500
                  });
                }
              },
              {
                title: '手柄测试',
                subtitle: '测试 USB 和蓝牙/系统手柄',
                type: 'action',
                action: () => {
                  router.pushUrl({ url: 'pages/ControllerTestPage' });
                }
              }
            ]
          })
          
          // 屏幕控制器设置
          this.SettingsGroup({
            id: 'osc',
            icon: $r('sys.symbol.gamecontroller'),
            title: '屏幕控制器',
            items: [
              {
                title: '显示屏幕控制器',
                subtitle: '显示虚拟游戏手柄',
                type: 'toggle',
                value: this.enableOnscreenControls,
                action: () => {
                  this.enableOnscreenControls = !this.enableOnscreenControls;
                  this.saveSetting(SettingsKeys.ENABLE_ONSCREEN_CONTROLS, this.enableOnscreenControls);
                }
              },
              {
                title: '显示屏幕键盘',
                subtitle: '显示虚拟键盘按钮',
                type: 'toggle',
                value: this.enableOnscreenKeyboard,
                action: () => {
                  this.enableOnscreenKeyboard = !this.enableOnscreenKeyboard;
                  this.saveSetting(SettingsKeys.ENABLE_ONSCREEN_KEYBOARD, this.enableOnscreenKeyboard);
                }
              },
              {
                title: '仅 L3/R3 按钮',
                subtitle: '只显示 L3 和 R3 按钮',
                type: 'toggle',
                visible: this.enableOnscreenControls,
                value: this.onlyL3R3,
                action: () => {
                  this.onlyL3R3 = !this.onlyL3R3;
                  this.saveSetting(SettingsKeys.ONLY_L3_R3, this.onlyL3R3);
                }
              },
              {
                title: '显示 Guide 按钮',
                subtitle: '显示主页/Guide 按钮',
                type: 'toggle',
                visible: this.enableOnscreenControls,
                value: this.showGuideButton,
                action: () => {
                  this.showGuideButton = !this.showGuideButton;
                  this.saveSetting(SettingsKeys.SHOW_GUIDE_BUTTON, this.showGuideButton);
                }
              },
              {
                title: '竖屏半高模式',
                subtitle: '竖屏时控制器显示在下半屏',
                type: 'toggle',
                visible: this.enableOnscreenControls,
                value: this.halfHeightOscPortrait,
                action: () => {
                  this.halfHeightOscPortrait = !this.halfHeightOscPortrait;
                  this.saveSetting(SettingsKeys.HALF_HEIGHT_OSC_PORTRAIT, this.halfHeightOscPortrait);
                }
              },
              {
                title: '控制器透明度',
                subtitle: '虚拟控制器不透明度',
                type: 'slider',
                visible: this.enableOnscreenControls,
                value: this.oscOpacity,
                min: 10,
                max: 100,
                step: 5,
                unit: '%',
                onSliderChange: (value: number) => {
                  this.oscOpacity = value;
                  this.saveSetting(SettingsKeys.OSC_OPACITY, value);
                }
              },
              {
                title: '屏幕控制器振动',
                subtitle: '按下按钮时振动',
                type: 'toggle',
                visible: this.enableOnscreenControls,
                value: this.vibrateOsc,
                action: () => {
                  this.vibrateOsc = !this.vibrateOsc;
                  this.saveSetting(SettingsKeys.VIBRATE_OSC, this.vibrateOsc);
                }
              }
            ]
          })
          
          // 鼠标和触控设置
          this.SettingsGroup({
            id: 'mouse',
            icon: $r('app.media.ic_mouse'),
            useSymbol: false,
            title: '鼠标和触控',
            items: [
              {
                title: '显示本地光标',
                subtitle: '保持系统光标可见',
                type: 'toggle',
                value: this.showLocalCursor,
                action: () => {
                  this.showLocalCursor = !this.showLocalCursor;
                  this.saveSetting(SettingsKeys.SHOW_LOCAL_CURSOR, this.showLocalCursor);
                }
              },
              {
                title: '触屏作为触控板',
                subtitle: '触摸屏幕模拟触控板',
                type: 'toggle',
                value: this.touchscreenTrackpad,
                action: () => {
                  this.touchscreenTrackpad = !this.touchscreenTrackpad;
                  this.saveSetting(SettingsKeys.TOUCHSCREEN_TRACKPAD, this.touchscreenTrackpad);
                }
              },
              {
                title: '双击拖动',
                subtitle: '双击并按住可拖动',
                type: 'toggle',
                value: this.enableDoubleClickDrag,
                action: () => {
                  this.enableDoubleClickDrag = !this.enableDoubleClickDrag;
                  this.saveSetting(SettingsKeys.ENABLE_DOUBLE_CLICK_DRAG, this.enableDoubleClickDrag);
                }
              },
              {
                title: '双击时间阈值',
                subtitle: '双击判定时间间隔',
                type: 'slider',
                visible: this.enableDoubleClickDrag,
                value: this.doubleTapTimeThreshold,
                min: 100,
                max: 500,
                step: 50,
                unit: ' ms',
                onSliderChange: (value: number) => {
                  this.doubleTapTimeThreshold = value;
                  this.saveSetting(SettingsKeys.DOUBLE_TAP_TIME_THRESHOLD, value);
                }
              },
              {
                title: '摇杆滚动',
                type: 'segment',
                value: this.analogScrolling,
                segmentLabels: ['禁用', '左摇杆', '右摇杆'],
                onSegmentChange: (value: string) => {
                  this.analogScrolling = value;
                  this.saveSetting(SettingsKeys.ANALOG_SCROLLING, value);
                }
              },
              {
                title: '鼠标导航按钮',
                subtitle: '启用鼠标前进/后退按钮',
                type: 'toggle',
                value: this.mouseNavButtons,
                action: () => {
                  this.mouseNavButtons = !this.mouseNavButtons;
                  this.saveSetting(SettingsKeys.MOUSE_NAV_BUTTONS, this.mouseNavButtons);
                }
              },
              {
                title: '游戏鼠标模式',
                subtitle: '相对输入+光标回弹，适合 FPS/TPS 游戏',
                type: 'toggle',
                value: this.gameMouseMode,
                action: () => {
                  this.gameMouseMode = !this.gameMouseMode;
                  this.saveSetting(SettingsKeys.GAME_MOUSE_MODE, this.gameMouseMode);
                }
              }
            ]
          })
          
          // 增强触控设置 (TODO: 功能未实现，设置值已保存但尚未接入 TouchInputHandler)
          this.SettingsGroup({
            id: 'enhanced_touch',
            icon: $r('sys.symbol.bolt_fill'),
            title: '增强触控 (TODO)',
            items: [
              {
                title: '启用增强触控',
                subtitle: '增强原生触控体验',
                type: 'toggle',
                value: this.enableEnhancedTouch,
                action: () => {
                  this.enableEnhancedTouch = !this.enableEnhancedTouch;
                  this.saveSetting(SettingsKeys.ENABLE_ENHANCED_TOUCH, this.enableEnhancedTouch);
                }
              },
              {
                title: '触控区域在右侧',
                subtitle: '将增强触控区域放在右侧',
                type: 'toggle',
                visible: this.enableEnhancedTouch,
                value: this.enhancedTouchOnRight,
                action: () => {
                  this.enhancedTouchOnRight = !this.enhancedTouchOnRight;
                  this.saveSetting(SettingsKeys.ENHANCED_TOUCH_ON_RIGHT, this.enhancedTouchOnRight);
                }
              },
              {
                title: '触控区域分割',
                subtitle: '触控区域占比',
                type: 'slider',
                visible: this.enableEnhancedTouch,
                value: this.enhancedTouchZoneDivider,
                min: 10,
                max: 90,
                step: 5,
                unit: '%',
                onSliderChange: (value: number) => {
                  this.enhancedTouchZoneDivider = value;
                  this.saveSetting(SettingsKeys.ENHANCED_TOUCH_ZONE_DIVIDER, value);
                }
              },
              {
                title: '指针速度因子',
                subtitle: '指针移动速度倍数',
                type: 'slider',
                visible: this.enableEnhancedTouch,
                value: this.pointerVelocityFactor,
                min: 10,
                max: 200,
                step: 10,
                unit: '%',
                onSliderChange: (value: number) => {
                  this.pointerVelocityFactor = value;
                  this.saveSetting(SettingsKeys.POINTER_VELOCITY_FACTOR, value);
                }
              },
              {
                title: '长按平坦区域',
                subtitle: '长按触发范围',
                type: 'slider',
                visible: this.enableEnhancedTouch,
                value: this.longPressFlatRegion,
                min: 0,
                max: 50,
                step: 5,
                unit: ' px',
                onSliderChange: (value: number) => {
                  this.longPressFlatRegion = value;
                  this.saveSetting(SettingsKeys.LONG_PRESS_FLAT_REGION, value);
                }
              }
            ]
          })
          
          // 主机设置
          this.SettingsGroup({
            id: 'host',
            icon: $r('app.media.ic_host'),
            useSymbol: false,
            title: '主机',
            items: [
              {
                title: '服务器端优化',
                subtitle: '让服务器优化游戏设置',
                type: 'toggle',
                value: this.enableSops,
                action: () => {
                  this.enableSops = !this.enableSops;
                  this.saveSetting(SettingsKeys.ENABLE_SOPS, this.enableSops);
                }
              },
              {
                title: '屏幕组合模式',
                type: 'segment',
                value: this.screenCombinationMode,
                segmentLabels: ['自动', '仅主显示器', '扩展', '复制'],
                segmentValues: ['自动', '仅主显示器', '扩展模式', '复制模式'],
                onSegmentChange: (value: string) => {
                  this.screenCombinationMode = value;
                  this.saveSetting(SettingsKeys.SCREEN_COMBINATION_MODE, value);
                }
              },
              {
                title: '断开后锁定屏幕',
                subtitle: '断开连接后锁定主机屏幕',
                type: 'toggle',
                value: this.lockScreenAfterDisconnect,
                action: () => {
                  this.lockScreenAfterDisconnect = !this.lockScreenAfterDisconnect;
                  this.saveSetting(SettingsKeys.LOCK_SCREEN_AFTER_DISCONNECT, this.lockScreenAfterDisconnect);
                }
              },
              {
                title: '交换退出和断开',
                subtitle: '交换退出游戏和断开连接',
                type: 'toggle',
                value: this.swapQuitAndDisconnect,
                action: () => {
                  this.swapQuitAndDisconnect = !this.swapQuitAndDisconnect;
                  this.saveSetting(SettingsKeys.SWAP_QUIT_AND_DISCONNECT, this.swapQuitAndDisconnect);
                }
              }
            ]
          })
          
          // 高级设置
          this.SettingsGroup({
            id: 'advanced',
            icon: $r('sys.symbol.gearshape_fill'),
            title: '高级',
            items: [
              {
                title: '解码器缓冲区',
                subtitle: '0=系统默认，2-8=指定数量',
                type: 'slider',
                value: this.decoderBufferCount,
                min: 0,
                max: 8,
                step: 1,
                unit: this.decoderBufferCount === 0 ? '(默认)' : ' 个',
                onSliderChange: (value: number) => {
                  // 跳过 1，因为单缓冲不可用
                  if (value === 1) {
                    value = this.decoderBufferCount > 1 ? 0 : 2;
                  }
                  this.decoderBufferCount = value;
                  this.saveSetting(SettingsKeys.DECODER_BUFFER_COUNT, value);
                }
              },
              {
                title: '同步解码模式 (实验性)',
                subtitle: 'API 20+，理论上帧率输出更稳定',
                type: 'toggle',
                value: this.enableSyncDecode,
                action: () => {
                  this.enableSyncDecode = !this.enableSyncDecode;
                  this.saveSetting(SettingsKeys.ENABLE_SYNC_DECODE, this.enableSyncDecode);
                }
              },
              {
                title: 'VRR 可变刷新率 (实验性)',
                subtitle: '动态调整屏幕刷新率，可能丢帧以节能',
                type: 'toggle',
                value: this.enableVrr,
                action: () => {
                  this.enableVrr = !this.enableVrr;
                  this.saveSetting(SettingsKeys.ENABLE_VRR, this.enableVrr);
                }
              },
              {
                title: 'VSync 渲染',
                subtitle: '精确帧呈现时间，减少画面撕裂',
                type: 'toggle',
                value: this.enableVsync,
                action: () => {
                  this.enableVsync = !this.enableVsync;
                  this.saveSetting(SettingsKeys.ENABLE_VSYNC, this.enableVsync);
                }
              },
              {
                title: '性能模式',
                subtitle: '优化线程优先级和系统资源调度',
                type: 'toggle',
                value: this.performanceMode,
                action: () => {
                  this.performanceMode = !this.performanceMode;
                  this.saveSetting(SettingsKeys.PERFORMANCE_MODE, this.performanceMode);
                }
              },
              {
                title: '性能覆盖层',
                subtitle: '显示帧率和延迟信息',
                type: 'toggle',
                value: this.enablePerfOverlay,
                action: () => {
                  this.enablePerfOverlay = !this.enablePerfOverlay;
                  this.saveSetting(SettingsKeys.ENABLE_PERF_OVERLAY, this.enablePerfOverlay);
                }
              },
              {
                title: '性能覆盖层方向',
                type: 'segment',
                value: this.perfOverlayOrientation,
                visible: this.enablePerfOverlay,
                segmentLabels: ['水平', '垂直'],
                onSegmentChange: (value: string) => {
                  this.perfOverlayOrientation = value;
                  this.saveSetting(SettingsKeys.PERF_OVERLAY_ORIENTATION, value);
                }
              },
              {
                title: '性能覆盖层位置',
                subtitle: this.perfOverlayPosition,
                type: 'select',
                visible: this.enablePerfOverlay,
                action: () => this.showPerfOverlayPositionPicker()
              },
              {
                title: '锁定覆盖层',
                subtitle: '锁定后不可拖动，触摸穿透',
                type: 'toggle',
                visible: this.enablePerfOverlay,
                value: this.perfOverlayLocked,
                action: () => {
                  this.perfOverlayLocked = !this.perfOverlayLocked;
                  this.saveSetting(SettingsKeys.PERF_OVERLAY_LOCKED, this.perfOverlayLocked);
                }
              },
              {
                title: '覆盖层显示项目',
                subtitle: `已选 ${this.perfOverlayItems.length} 项`,
                type: 'select',
                visible: this.enablePerfOverlay,
                action: () => this.showPerfOverlayItemsPicker()
              },
              {
                title: '串流后延迟提示',
                subtitle: '串流结束后显示延迟统计',
                type: 'toggle',
                value: this.latencyToast,
                action: () => {
                  this.latencyToast = !this.latencyToast;
                  this.saveSetting(SettingsKeys.LATENCY_TOAST, this.latencyToast);
                }
              },
              {
                title: '禁用警告',
                subtitle: '隐藏性能警告提示',
                type: 'toggle',
                value: this.disableWarnings,
                action: () => {
                  this.disableWarnings = !this.disableWarnings;
                  this.saveSetting(SettingsKeys.DISABLE_WARNINGS, this.disableWarnings);
                }
              },
              {
                title: '降低刷新率',
                subtitle: '串流时降低显示器刷新率',
                type: 'toggle',
                value: this.reduceRefreshRate,
                action: () => {
                  this.reduceRefreshRate = !this.reduceRefreshRate;
                  this.saveSetting(SettingsKeys.REDUCE_REFRESH_RATE, this.reduceRefreshRate);
                }
              },
              {
                title: '获取公网 IP',
                subtitle: '使用 STUN 获取被控端公网地址',
                type: 'toggle',
                value: this.enableStun,
                action: () => {
                  this.enableStun = !this.enableStun;
                  this.saveSetting(SettingsKeys.ENABLE_STUN, this.enableStun);
                }
              },
              {
                title: '启用 ESC 菜单',
                subtitle: '按 ESC 键显示菜单',
                type: 'toggle',
                value: this.enableEscMenu,
                action: () => {
                  this.enableEscMenu = !this.enableEscMenu;
                  this.saveSetting(SettingsKeys.ENABLE_ESC_MENU, this.enableEscMenu);
                }
              },
              {
                title: 'ESC 菜单按键',
                type: 'segment',
                value: this.escMenuKey,
                visible: this.enableEscMenu,
                segmentLabels: ['ESC', 'F1', 'F12', '~'],
                onSegmentChange: (value: string) => {
                  this.escMenuKey = value;
                  this.saveSetting(SettingsKeys.ESC_MENU_KEY, value);
                }
              },
              {
                title: '后台保活',
                subtitle: '串流时保持后台运行，防止切后台后画面冻结',
                type: 'toggle',
                value: this.enableBackgroundTask,
                action: () => {
                  this.enableBackgroundTask = !this.enableBackgroundTask;
                  this.saveSetting(SettingsKeys.ENABLE_BACKGROUND_TASK, this.enableBackgroundTask);
                }
              }
            ]
          })
          
          // UI 设置
          this.SettingsGroup({
            id: 'ui',
            icon: $r('sys.symbol.display'),
            title: '界面',
            items: [
              {
                title: '小图标模式',
                subtitle: '使用更小的应用图标',
                type: 'toggle',
                value: this.smallIconMode,
                action: () => {
                  this.smallIconMode = !this.smallIconMode;
                  this.saveSetting(SettingsKeys.SMALL_ICON_MODE, this.smallIconMode);
                }
              },
              {
                title: '语言',
                subtitle: this.language,
                type: 'select',
                action: () => this.showLanguagePicker()
              },
              {
                title: '背景图片',
                subtitle: this.getBackgroundImageTypeLabel(),
                type: 'select',
                action: () => this.showBackgroundImageTypePicker()
              },
              {
                title: '自定义背景图 URL',
                subtitle: this.backgroundImageUrl || '使用默认 API',
                type: 'action',
                action: () => this.showBackgroundImageUrlInput()
              },
              {
                title: '恢复串流',
                subtitle: '启动时恢复上次串流',
                type: 'toggle',
                value: this.resumeStream,
                action: () => {
                  this.resumeStream = !this.resumeStream;
                  this.saveSetting(SettingsKeys.RESUME_STREAM, this.resumeStream);
                }
              },
              {
                title: '开发者模式',
                subtitle: '启用实验性功能（如麦克风）',
                type: 'toggle',
                value: this.developerMode,
                action: () => {
                  this.developerMode = !this.developerMode;
                  this.saveSetting(SettingsKeys.DEVELOPER_MODE, this.developerMode);
                  if (this.developerMode) {
                    promptAction.showToast({ message: '开发者模式已启用', duration: 2000 });
                  }
                }
              }
            ]
          })
          
          // 关于
          this.SettingsGroup({
            id: 'about',
            icon: $r('sys.symbol.info_circle_fill'),
            title: '关于',
            items: [
              {
                title: '版本',
                subtitle: this.appVersion,
                type: 'action',
                action: () => {}
              },
              {
                title: '更新日志',
                subtitle: '查看版本更新历史',
                type: 'action',
                action: () => {
                  this.showChangelog();
                }
              },
              {
                title: '开源项目',
                subtitle: 'github.com/AlkaidLab/moonlight-harmony',
                type: 'action',
                action: () => {
                  this.openUrl('https://github.com/AlkaidLab/moonlight-harmony');
                }
              },
              {
                title: 'Foundation Sunshine',
                subtitle: '游戏串流服务端',
                type: 'action',
                action: () => {
                  this.openUrl('https://github.com/qiin2333/foundation-sunshine');
                }
              },
              {
                title: '反馈与建议',
                subtitle: '在 GitHub Issues 提交问题或建议',
                type: 'action',
                action: () => {
                  this.openUrl('https://github.com/AlkaidLab/moonlight-harmony/issues/new');
                }
              },
              {
                title: '开源库说明',
                subtitle: '查看使用的开源库及许可证',
                type: 'action',
                action: () => {
                  this.showOpenSourceLicenses();
                }
              },
              {
                title: '隐私政策',
                subtitle: '查看数据收集和使用说明',
                type: 'action',
                action: () => {
                  this.showPrivacyPolicy();
                }
              }
            ]
          })
          
          // 底部间距
          Column()
            .height(AppSpacing.XXLarge)
              }
              .width('100%')
              .padding({ left: AppSpacing.Large, right: AppSpacing.Large })
            }
          }
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.Background)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const width = newValue.width as number;
      this.isWideScreen = width > 840;
    })
    .bindSheet($$this.showTextInputDialog, this.BottomSheetContent(), {
      height: SheetSize.FIT_CONTENT,
      backgroundColor: Color.Transparent,
      dragBar: false,
      showClose: false,
      preferType: SheetType.BOTTOM
    } as SheetOptions)
  }

  @Builder
  TitleBar() {
    Row() {
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.ic_back'))
          .width(AppSizes.IconMedium)
          .height(AppSizes.IconMedium)
          .fillColor(AppColors.Primary)
      }
      .width(40)
      .height(40)
      .backgroundColor(AppColors.Surface)
      .borderWidth(1)
      .borderColor(AppColors.CardBorder)
      .onClick(() => router.back())

      Column() {
        Text('设置')
          .fontSize(AppSizes.FontTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.Primary)
        Text('自定义串流体验')
          .fontSize(AppSizes.FontCaption)
          .fontColor(AppColors.TextSecondary)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: AppSpacing.Medium })

      Blank()
    }
    .width('100%')
    .padding({
      left: AppSpacing.Large,
      right: AppSpacing.Large,
      top: this.topSafeHeight,
      bottom: AppSpacing.Large
    })
  }

  @Builder
  SettingsSidebar() {
    Scroll() {
      Column({ space: 4 }) {
        ForEach(this.sidebarGroups, (meta: SidebarGroupMeta) => {
          Row() {
            // 分组图标
            Column() {
              if (meta.useSymbol) {
                SymbolGlyph(meta.icon)
                  .fontSize(16)
                  .fontColor([this.expandedGroup === meta.id ? AppColors.Primary : AppColors.TextSecondary])
                  .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              } else {
                Image(meta.icon)
                  .width(16)
                  .height(16)
                  .fillColor(this.expandedGroup === meta.id ? AppColors.Primary : AppColors.TextSecondary)
              }
            }
            .width(24)
            .height(24)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)

            Text(meta.title)
              .fontSize(AppSizes.FontCaption)
              .fontWeight(this.expandedGroup === meta.id ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.expandedGroup === meta.id ? AppColors.Primary : AppColors.TextPrimary)
              .margin({ left: AppSpacing.Small })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .height(44)
          .padding({ left: AppSpacing.Medium, right: AppSpacing.Medium })
          .borderRadius(AppSizes.RadiusMedium)
          .backgroundColor(this.expandedGroup === meta.id ? AppColors.Surface : Color.Transparent)
          .borderWidth(this.expandedGroup === meta.id ? 1 : 0)
          .borderColor(this.expandedGroup === meta.id ? AppColors.CardBorder : Color.Transparent)
          .onClick(() => {
            this.expandedGroup = meta.id;
          })
        })
      }
      .width('100%')
      .padding({ left: AppSpacing.Medium, right: AppSpacing.Small, top: AppSpacing.Medium })
    }
    .width(180)
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  @Builder
  SettingsGroup(group: SettingGroup) {
    // 宽屏模式：仅渲染当前选中的分组（侧边栏负责导航），不显示分组标题
    if (this.isWideScreen) {
      if (this.expandedGroup === group.id) {
        Column() {
          // 设置项列表 - 直接展示
          Column() {
            ForEach(group.items.filter((item: SettingItem) => item.visible !== false), (item: SettingItem, index: number) => {
              this.SettingItemView(item)

              if (index < group.items.filter((i: SettingItem) => i.visible !== false).length - 1) {
                Divider()
                  .color(AppColors.CardBorder)
                  .margin({ left: AppSpacing.Medium, right: AppSpacing.Medium })
              }
            }, (item: SettingItem) => `${item.title}_${item.value}_${item.subtitle}_${item.disabled}_${item.visible}`)
          }
          .width('100%')
          .backgroundColor(AppColors.CardBackground)
          .borderRadius(AppSizes.RadiusLarge)
          .borderWidth(1)
          .borderColor(AppColors.CardBorder)
        }
        .width('100%')
      }
    } else {
      // 窄屏模式：分组标题 + 可折叠内容
      Column() {
        // 分组标题 - 带图标的霍虹风格（可点击展开/折叠）
        Row() {
          // 分组图标
          Column() {
            if (group.useSymbol !== false) {
              SymbolGlyph(group.icon)
                .fontSize(18)
                .fontColor([AppColors.Primary])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            } else {
              Image(group.icon)
                .width(18)
                .height(18)
                .fillColor(AppColors.Primary)
            }
          }
          .width(28)
          .height(28)
          .borderRadius(8)
          .backgroundColor(AppColors.Surface)
          .borderWidth(1)
          .borderColor(AppColors.CardBorder)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .margin({ right: AppSpacing.Small })

          Text(group.title.toUpperCase())
            .fontSize(AppSizes.FontCaption)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.Primary)
          
          Blank()
          
          // 展开/折叠箭头
          Image($r('app.media.ic_arrow_right'))
            .width(16)
            .height(16)
            .fillColor(AppColors.Primary)
            .rotate({ angle: this.expandedGroup === group.id ? 90 : 0 })
            .animation({ duration: AppAnimation.Fast, curve: Curve.EaseInOut })
        }
        .width('100%')
        .height(40)
        .alignItems(VerticalAlign.Center)
        .padding({ left: AppSpacing.Small, right: AppSpacing.Medium })
        .backgroundColor(this.expandedGroup === group.id ? AppColors.Surface : Color.Transparent)
        .borderRadius(AppSizes.RadiusMedium)
        .focusable(true)
        .focusOnTouch(true)
        .focusBox({
          margin: LengthMetrics.vp(1),
          strokeColor: ColorMetrics.rgba(0, 212, 255, 0.8),
          strokeWidth: LengthMetrics.vp(1.5)
        })
        .onKeyEvent((event: KeyEvent) => {
          if (event.type === KeyType.Down && (event.keyCode === 2054 || event.keyCode === 2050)) {
            if (this.expandedGroup === group.id) {
              this.expandedGroup = '';
            } else {
              this.expandedGroup = group.id;
            }
            return true;
          }
          return false;
        })
        .onClick(() => {
          if (this.expandedGroup === group.id) {
            this.expandedGroup = '';
          } else {
            this.expandedGroup = group.id;
          }
        })

        // 设置项容器 - 深色卡片（可折叠）
        if (this.expandedGroup === group.id) {
          Column() {
            ForEach(group.items.filter((item: SettingItem) => item.visible !== false), (item: SettingItem, index: number) => {
              this.SettingItemView(item)

              if (index < group.items.filter((i: SettingItem) => i.visible !== false).length - 1) {
                Divider()
                  .color(AppColors.CardBorder)
                  .margin({ left: AppSpacing.Medium, right: AppSpacing.Medium })
              }
            }, (item: SettingItem) => `${item.title}_${item.value}_${item.subtitle}_${item.disabled}_${item.visible}`)
          }
          .width('100%')
          .backgroundColor(AppColors.CardBackground)
          .borderRadius(AppSizes.RadiusLarge)
          .borderWidth(1)
          .borderColor(AppColors.CardBorder)
          .margin({ top: AppSpacing.Small })
          .transition(TransitionEffect.OPACITY.animation({ duration: AppAnimation.Fast }))
        }
      }
      .width('100%')
      .margin({ bottom: AppSpacing.Medium })
    }
  }

  @Builder
  SettingItemView(item: SettingItem) {
    if (item.type === 'segment') {
      // 分段按钮布局 - 参考系统设置风格：标题 + 居中分段按钮 + 辅助说明
      Column() {
        // 标题行
        Row() {
          Text(item.title)
            .fontSize(AppSizes.FontBody)
            .fontColor(item.disabled ? AppColors.TextSecondary : AppColors.TextPrimary)

          // Pro 标记
          if (item.isPro) {
            Text('Pro')
              .fontSize(10)
              .fontColor(AppColors.TextOnPrimary)
              .backgroundColor(AppColors.PrimaryDark)
              .borderRadius(4)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ left: 6 })
          }
        }
        .alignItems(VerticalAlign.Center)
        .width('100%')

        // 分段选择器 - 居中显示，宽屏下受 maxWidth 448vp 约束
        InlineSegmentPicker({
          labels: item.segmentLabels ?? [],
          selectedValue: item.value as string ?? '',
          values: item.segmentValues ?? [],
          disabled: item.disabled ?? false,
          onValueChange: (value: string) => {
            if (item.onSegmentChange) {
              item.onSegmentChange(value);
            }
          }
        })
          .margin({ top: AppSpacing.Medium })

        // 辅助说明文字（置于分段按钮下方，作为脚注）
        if (item.subtitle) {
          Text(item.subtitle)
            .fontSize(AppSizes.FontCaption)
            .fontColor(AppColors.TextTertiary)
            .margin({ top: AppSpacing.XSmall })
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ left: AppSpacing.Large, right: AppSpacing.Large, top: AppSpacing.Medium, bottom: AppSpacing.Medium })
    } else {
      // 原有布局：标题左侧 + 控件右侧
      Row() {
        // 文字内容
        Column() {
          Row() {
            Text(item.title)
              .fontSize(AppSizes.FontBody)
              .fontColor(item.disabled ? AppColors.TextSecondary : AppColors.TextPrimary)
            
            // Pro 标记
            if (item.isPro) {
              Text('Pro')
                .fontSize(10)
                .fontColor(AppColors.TextOnPrimary)
                .backgroundColor(AppColors.PrimaryDark)
                .borderRadius(4)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .margin({ left: 6 })
            }
          }
          .alignItems(VerticalAlign.Center)

          if (item.subtitle) {
            Text(item.subtitle)
              .fontSize(AppSizes.FontCaption)
              .fontColor(AppColors.TextSecondary)
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 右侧控件
        if (item.type === 'toggle') {
          Toggle({ type: ToggleType.Switch, isOn: item.value as boolean })
            .selectedColor(AppColors.Primary)
            .enabled(!item.disabled)
            .onChange(() => {
              if (item.action && !item.disabled) {
                item.action();
              }
            })
        } else if (item.type === 'slider') {
          // 使用公共滑块组件
          SettingSlider({
            config: {
              value: item.value as number,
              min: item.min ?? 0,
              max: item.max ?? 100,
              step: item.step,
              unit: item.unit,
              isLogarithmic: item.isLogarithmic,
              snapValues: item.snapValues,
              snapThreshold: item.snapThreshold,
              formatValue: item.formatValue,
              onChange: (value: number) => {
                if (item.onSliderChange) {
                  item.onSliderChange(value);
                }
              }
            }
          })
            .width(210)
            .opacity(item.disabled ? 0.5 : 1.0)
        } else if (item.type === 'select' || item.type === 'action') {
          Image($r('app.media.ic_arrow_right'))
            .width(16)
            .height(16)
            .fillColor(item.disabled ? AppColors.TextSecondary : AppColors.Primary)
        }
      }
      .width('100%')
      .height(item.type === 'slider' ? 70 : 60)
      .padding({ left: AppSpacing.Medium, right: AppSpacing.Medium })
      .focusable(!item.disabled)
      .focusOnTouch(true)
      .focusBox({
        margin: LengthMetrics.vp(1),
        strokeColor: ColorMetrics.rgba(74, 222, 128, 0.8),
        strokeWidth: LengthMetrics.vp(1.5)
      })
      .onKeyEvent((event: KeyEvent) => {
        if (event.type === KeyType.Down && !item.disabled) {
          // A键/回车 → 触发操作
          if (event.keyCode === 2054 || event.keyCode === 2050) {
            if (item.type === 'toggle' && item.action) {
              item.action();
            } else if (item.action) {
              item.action();
            }
            return true;
          }
        }
        return false;
      })
      .onClick(() => {
        if (item.disabled) return;
        console.info(`SettingsPageV2: 点击设置项 ${item.title}, type=${item.type}, hasAction=${!!item.action}`);
        if (item.type !== 'toggle' && item.action) {
          console.info(`SettingsPageV2: 执行 action`);
          item.action();
        }
      })
    }
  }

  private showResolutionPicker(): void {
    // 预设分辨率（对齐Android）
    const presetOptions: PickerOption[] = [
      { title: '720p', subtitle: '1280×720', value: '720p' } as PickerOption,
      { title: '1080p', subtitle: '1920×1080', value: '1080p' } as PickerOption,
      { title: '1440p', subtitle: '2560×1440', value: '1440p' } as PickerOption,
      { title: '4K', subtitle: '3840×2160', value: '4K' } as PickerOption
    ];
    
    // 添加本地分辨率选项（如果有效且不与预设重复）
    const nativeOptions: PickerOption[] = [];
    if (this.nativeWidth > 0 && this.nativeHeight > 0) {
      const nativeValue = `${this.nativeWidth}x${this.nativeHeight}`;
      // 检查是否与预设分辨率重复
      const isPreset = presetOptions.some(opt => {
        const val = opt.value as string;
        if (val === nativeValue) return true;
        // 也检查标准分辨率
        switch (val) {
          case '720p': return this.nativeWidth === 1280 && this.nativeHeight === 720;
          case '1080p': return this.nativeWidth === 1920 && this.nativeHeight === 1080;
          case '1440p': return this.nativeWidth === 2560 && this.nativeHeight === 1440;
          case '4K': return this.nativeWidth === 3840 && this.nativeHeight === 2160;
          default: return false;
        }
      });
      
      if (!isPreset) {
        nativeOptions.push({
          title: '本机分辨率',
          subtitle: `${this.nativeWidth}×${this.nativeHeight}`,
          value: nativeValue
        } as PickerOption);
      }
    }
    
    // 添加自定义分辨率
    const customOptions: PickerOption[] = this.customResolutions
      .filter(res => {
        // 排除与本地分辨率重复的自定义分辨率
        const nativeValue = `${this.nativeWidth}x${this.nativeHeight}`;
        return res !== nativeValue;
      })
      .map(res => {
        const parts = res.split('x');
        return { 
          title: res, 
          subtitle: `自定义: ${parts[0]}×${parts[1]}`, 
          value: res 
        } as PickerOption;
      });
    
    // 添加"自定义..."选项
    const customActionOption: PickerOption = {
      title: '自定义...',
      subtitle: '输入任意分辨率',
      value: 'custom_input'
    } as PickerOption;
    
    // 添加"管理自定义"选项（仅已有自定义分辨率时显示）
    const manageOptions: PickerOption[] = [];
    if (this.customResolutions.length > 0) {
      manageOptions.push({
        title: '管理自定义分辨率',
        subtitle: `已添加 ${this.customResolutions.length} 个，点击管理`,
        value: 'manage_custom'
      } as PickerOption);
    }
    
    const allOptions = [...presetOptions, ...nativeOptions, ...customOptions, customActionOption, ...manageOptions];
    
    const config: PickerConfig = {
      title: '选择分辨率',
      subtitle: '选择适合您显示器的分辨率',
      selectedValue: this.resolution,
      options: allOptions,
      onSelect: (option: PickerOption) => {
        const value = option.value as string;
        if (value === 'custom_input') {
          // 延迟打开输入框，等待 picker dialog 关闭动画完成
          setTimeout(() => this.showAddResolutionInput(), 200);
        } else if (value === 'manage_custom') {
          setTimeout(() => this.showCustomResolutionDialog(), 200);
        } else {
          this.resolution = value;
          this.saveSetting(SettingsKeys.RESOLUTION, value);
        }
      }
    };
    this.showPicker(config);
  }

  /**
   * 显示自定义分辨率管理对话框 — 支持逐个删除和添加
   */
  private showCustomResolutionDialog(): void {
    // 将已有的自定义分辨率显示为可删除的选项
    const existingOptions: PickerOption[] = this.customResolutions.map(res => {
      const parts = res.split('x');
      const w = parseInt(parts[0]) || 0;
      const h = parseInt(parts[1]) || 0;
      const ratio = this.calcAspectRatio(w, h);
      return {
        title: `${parts[0]}×${parts[1]}`,
        subtitle: ratio ? `${ratio} — 点击删除` : '点击删除',
        value: `delete:${res}`
      } as PickerOption;
    });

    // 添加操作选项
    const actionOptions: PickerOption[] = [
      { title: '➕ 添加新分辨率', subtitle: '输入宽度和高度', value: 'action:add' } as PickerOption,
    ];
    if (this.customResolutions.length > 0) {
      actionOptions.push(
        { title: '🗑️ 清空全部', subtitle: `删除所有 ${this.customResolutions.length} 个自定义分辨率`, value: 'action:clear' } as PickerOption
      );
    }

    const allOptions = [...existingOptions, ...actionOptions];
    
    const config: PickerConfig = {
      title: '自定义分辨率管理',
      subtitle: this.customResolutions.length > 0 ? `已添加 ${this.customResolutions.length} 个` : '暂无自定义分辨率',
      selectedValue: '',
      options: allOptions,
      onSelect: (option: PickerOption) => {
        const value = option.value as string;
        if (value === 'action:add') {
          // 延迟打开输入框，等待 picker dialog 关闭动画完成
          setTimeout(() => this.showAddResolutionInput(), 200);
        } else if (value === 'action:clear') {
          this.clearAllCustomResolutions();
        } else if (value.startsWith('delete:')) {
          const res = value.substring(7);
          this.removeCustomResolution(res);
        }
      }
    };
    this.showPicker(config);
  }

  /**
   * 显示添加分辨率输入框 - 使用文本输入弹窗
   */
  private showAddResolutionInput(): void {
    this.customResWidth = '';
    this.customResHeight = '';
    this.customResAspectRatio = '';
    this.bottomSheetType = 'resolution';
    this.showTextInputDialog = true;
  }

  /**
   * 显示预定义的常用自定义分辨率供选择（备用）
   */
  private showPredefinedCustomResolutions(): void {
    const predefinedResolutions: PickerOption[] = [
      { title: '21:9 超宽 2K', subtitle: '2560×1080', value: '2560x1080' } as PickerOption,
      { title: '21:9 超宽 QHD', subtitle: '3440×1440', value: '3440x1440' } as PickerOption,
      { title: '21:9 超宽 4K', subtitle: '5120×2160', value: '5120x2160' } as PickerOption,
      { title: '32:9 超超宽 1080p', subtitle: '3840×1080', value: '3840x1080' } as PickerOption,
      { title: '32:9 超超宽 1440p', subtitle: '5120×1440', value: '5120x1440' } as PickerOption,
      { title: '16:10 WUXGA', subtitle: '1920×1200', value: '1920x1200' } as PickerOption,
      { title: '16:10 WQXGA', subtitle: '2560×1600', value: '2560x1600' } as PickerOption,
      { title: '4:3 XGA', subtitle: '1024×768', value: '1024x768' } as PickerOption,
      { title: '4:3 SXGA', subtitle: '1280×1024', value: '1280x1024' } as PickerOption,
      { title: '5K', subtitle: '5120×2880', value: '5120x2880' } as PickerOption,
      { title: '8K UHD', subtitle: '7680×4320', value: '7680x4320' } as PickerOption,
    ].filter(opt => !this.customResolutions.includes(opt.value as string));

    if (predefinedResolutions.length === 0) {
      this.showToast('所有预设分辨率都已添加');
      return;
    }

    const config: PickerConfig = {
      title: '选择自定义分辨率',
      subtitle: '选择要添加的非标准分辨率',
      selectedValue: '',
      options: predefinedResolutions,
      onSelect: (option: PickerOption) => {
        this.addCustomResolution(option.value as string);
      }
    };
    this.showPicker(config);
  }

  /**
   * 添加自定义分辨率
   */
  private addCustomResolution(resolution: string): void {
    // 验证格式
    const match = resolution.match(/^(\d+)x(\d+)$/);
    if (!match) {
      this.showToast('分辨率格式无效，应为: 宽度x高度');
      return;
    }

    const width = parseInt(match[1]);
    const height = parseInt(match[2]);

    // 验证范围
    if (width < 320 || width > 7680) {
      this.showToast('宽度必须在 320-7680 之间');
      return;
    }
    if (height < 240 || height > 4320) {
      this.showToast('高度必须在 240-4320 之间');
      return;
    }
    
    // 验证偶数并提供修正建议
    if (width % 2 !== 0 || height % 2 !== 0) {
      const correctedWidth = width % 2 !== 0 ? width + 1 : width;
      const correctedHeight = height % 2 !== 0 ? height + 1 : height;
      this.showToast(`宽高必须为偶数，建议使用: ${correctedWidth}x${correctedHeight}`, 3000);
      return;
    }

    // 检查是否已存在
    if (this.customResolutions.includes(resolution)) {
      this.showToast('该分辨率已存在');
      return;
    }

    // 添加并保存
    this.customResolutions = [...this.customResolutions, resolution];
    this.saveCustomResolutions();
    this.showToast(`已添加: ${resolution}`);
  }

  /**
   * 删除单个自定义分辨率
   */
  private removeCustomResolution(resolution: string): void {
    const idx = this.customResolutions.indexOf(resolution);
    if (idx === -1) {
      this.showToast('该分辨率不存在');
      return;
    }
    this.customResolutions = this.customResolutions.filter(r => r !== resolution);
    this.saveCustomResolutions();
    // 如果当前正在使用被删除的分辨率，回退到 1080p
    if (this.resolution === resolution) {
      this.resolution = '1080p';
      this.saveSetting(SettingsKeys.RESOLUTION, '1080p');
      this.showToast(`已删除 ${resolution}，分辨率已回退为 1080p`);
    } else {
      this.showToast(`已删除: ${resolution}`);
    }
  }

  /**
   * 清空所有自定义分辨率
   */
  private clearAllCustomResolutions(): void {
    if (this.customResolutions.length === 0) {
      this.showToast('没有自定义分辨率需要清空');
      return;
    }

    promptAction.showDialog({
      title: '确认清空',
      message: `确定要清空所有 ${this.customResolutions.length} 个自定义分辨率吗？`,
      buttons: [
        { text: '确定', color: AppColors.Error },
        { text: '取消', color: AppColors.TextSecondary }
      ]
    }).then((result) => {
      if (result.index === 0) {
        this.customResolutions = [];
        this.saveCustomResolutions();
        this.showToast('已清空所有自定义分辨率');
      }
    });
  }

  /**
   * 保存自定义分辨率到存储
   */
  private saveCustomResolutions(): void {
    const resStr = this.customResolutions.join(',');
    this.saveSetting(SettingsKeys.CUSTOM_RESOLUTIONS, resStr);
  }

  private showFpsPicker(): void {
    // 检测设备屏幕刷新率
    let deviceRefreshRate = 60;
    try {
      const displayInfo = display.getDefaultDisplaySync();
      deviceRefreshRate = Math.round(displayInfo.refreshRate || 60);
    } catch (e) {
      // 检测失败，使用默认值
    }

    // 基础帧率选项（所有设备通用）
    const presetOptions: PickerOption[] = [
      { title: '30 FPS', subtitle: '流畅，低带宽', value: '30 FPS' } as PickerOption,
      { title: '60 FPS', subtitle: '推荐，平衡', value: '60 FPS' } as PickerOption,
    ];

    // 根据设备刷新率动态添加高帧率选项
    if (deviceRefreshRate >= 90) {
      presetOptions.push({ title: '90 FPS', subtitle: '高刷新率', value: '90 FPS' } as PickerOption);
    }
    if (deviceRefreshRate >= 120) {
      presetOptions.push(
        { title: '119.88 FPS', subtitle: '视频标准 (NTSC)', value: '119.88 FPS' } as PickerOption,
        { title: '120 FPS', subtitle: '极致体验', value: '120 FPS' } as PickerOption
      );
    }
    if (deviceRefreshRate >= 144) {
      presetOptions.push({ title: '144 FPS', subtitle: '高刷屏专属', value: '144 FPS' } as PickerOption);
    }
    // 如果设备刷新率不在预设中（如 165Hz, 240Hz 等），动态添加
    const knownRates = [30, 60, 90, 120, 144];
    if (deviceRefreshRate > 60 && !knownRates.includes(deviceRefreshRate)) {
      presetOptions.push({
        title: `${deviceRefreshRate} FPS`,
        subtitle: `匹配设备屏幕 (${deviceRefreshRate}Hz)`,
        value: `${deviceRefreshRate} FPS`
      } as PickerOption);
    }
    
    // 如果有自定义帧率，添加到选项中
    const customOptions: PickerOption[] = [];
    if (this.customFps > 0) {
      customOptions.push({
        title: `${this.customFps} FPS`,
        subtitle: '自定义帧率',
        value: `自定义:${this.customFps}`
      } as PickerOption);
    }
    
    // 添加"自定义..."选项
    const customActionOption: PickerOption = {
      title: '自定义...',
      subtitle: '输入任意帧率值',
      value: 'custom_input'
    } as PickerOption;
    
    const options = [...presetOptions, ...customOptions, customActionOption];
    
    const config: PickerConfig = {
      title: '选择帧率',
      subtitle: `设备屏幕 ${deviceRefreshRate}Hz · 更高帧率需要更多带宽`,
      selectedValue: this.fps,
      options: options,
      onSelect: (option: PickerOption) => {
        const value = option.value as string;
        if (value === 'custom_input') {
          // 延迟打开输入框，等待 picker dialog 关闭动画完成
          setTimeout(() => this.showCustomFpsInput(), 200);
        } else if (value.startsWith('自定义:')) {
          // 选择了已保存的自定义帧率
          this.fps = value;
          this.saveSetting(SettingsKeys.FPS, value);
        } else {
          // 选择了预设帧率
          this.fps = value;
          this.saveSetting(SettingsKeys.FPS, value);
        }
      }
    };
    this.showPicker(config);
  }

  /**
   * 显示 Home 键动作选择器
   */
  private showHomeButtonActionPicker(): void {
    const options: PickerOption[] = [
      { title: '发送 Guide 键', subtitle: 'Xbox Guide / PS Home', value: 'guide' } as PickerOption,
      { title: '发送 Select 键', subtitle: '返回/选择键', value: 'select' } as PickerOption,
      { title: '切换鼠标模式', subtitle: '切换触摸屏鼠标模拟', value: 'toggle_mouse' } as PickerOption,
      { title: '切换性能图层', subtitle: '显示/隐藏性能监控', value: 'toggle_perf' } as PickerOption,
      { title: '显示游戏菜单', subtitle: '打开 ESC 菜单', value: 'show_menu' } as PickerOption,
      { title: '无动作', subtitle: '忽略此按键', value: 'none' } as PickerOption,
    ];

    const config: PickerConfig = {
      title: 'Home 键动作',
      subtitle: '设置蓝牙/系统手柄 Home 键的动作',
      selectedValue: this.gcButtonHomeMapping,
      options: options,
      onSelect: (option: PickerOption) => {
        const value = option.value as string;
        this.gcButtonHomeMapping = value;
        this.saveSetting(SettingsKeys.GC_BUTTON_HOME_MAPPING, value);
        // 通知 GamepadManager 更新映射
        import('../service/GamepadManager').then(module => {
          module.GamepadManager.getInstance().updateGCButton2313Action(value as 'guide' | 'select' | 'toggle_mouse' | 'toggle_perf' | 'show_menu' | 'none');
        });
      }
    };
    this.showPicker(config);
  }

  /**
   * 显示自定义帧率输入框
   */
  private showCustomFpsInput(): void {
    this.textInputTitle = '自定义帧率';
    this.textInputPlaceholder = '输入帧率值 (如: 144)';
    this.textInputValue = this.customFps > 0 ? this.customFps.toString() : '';
    this.textInputCallback = (value: string) => {
      if (value && value.trim()) {
        this.setCustomFps(value.trim());
      }
    };
    this.bottomSheetType = 'text';
    this.showTextInputDialog = true;
  }

  /**
   * 设置自定义帧率
   */
  private setCustomFps(value: string): void {
    const fps = parseInt(value);
    
    // 验证帧率值
    if (isNaN(fps)) {
      this.showToast('请输入有效的数字');
      return;
    }
    
    if (fps < 10 || fps > 360) {
      this.showToast('帧率必须在 10-360 之间');
      return;
    }
    
    // 保存自定义帧率
    this.customFps = fps;
    this.fps = `自定义:${fps}`;
    this.saveSetting(SettingsKeys.CUSTOM_FPS, fps);
    this.saveSetting(SettingsKeys.FPS, this.fps);
    
    this.showToast(`已设置帧率为 ${fps} FPS`);
  }

  // 已转换为 Slider，保留空方法以防未来需要
  private showBitratePicker(): void { }

  private showAudioConfigPicker(): void {
    const options: PickerOption[] = [
      { title: '立体声', subtitle: '双声道', value: '立体声' } as PickerOption,
      { title: '5.1 环绕', subtitle: '家庭影院', value: '5.1 环绕' } as PickerOption,
      { title: '7.1 环绕', subtitle: '专业音响', value: '7.1 环绕' } as PickerOption
    ];
    const config: PickerConfig = {
      title: '选择音频配置',
      subtitle: '根据您的音响设备选择',
      selectedValue: this.audioConfig,
      options: options,
      onSelect: (option: PickerOption) => {
        this.audioConfig = option.value as string;
        this.saveSetting(SettingsKeys.AUDIO_CONFIG, option.value as string);
      }
    };
    this.showPicker(config);
  }

  private showVideoFormatPicker(): void {
    const caps = this.decoderCapabilities;
    const h264Supported = caps?.supportsH264 ?? true;
    const hevcSupported = caps?.supportsHEVC ?? false;
    const av1Supported = caps?.supportsAV1 ?? false;
    
    const options: PickerOption[] = [
      { title: '自动', subtitle: '系统自动选择', value: '自动' } as PickerOption,
      { 
        title: 'H.264', 
        subtitle: h264Supported ? '兼容性最好' : '❌ 设备不支持', 
        value: 'H.264' 
      } as PickerOption,
      { 
        title: 'HEVC', 
        subtitle: hevcSupported ? 'H.265，高效压缩' : '❌ 设备不支持（可能是模拟器）', 
        value: 'HEVC' 
      } as PickerOption,
      { 
        title: 'AV1', 
        subtitle: av1Supported ? '最新编码，高效压缩' : '❌ 设备不支持', 
        value: 'AV1' 
      } as PickerOption
    ];
    
    // 生成能力信息提示
    let supportInfo = '设备支持: ';
    const supportedCodecs: string[] = [];
    if (h264Supported) supportedCodecs.push('H.264');
    if (hevcSupported) supportedCodecs.push('HEVC');
    if (av1Supported) supportedCodecs.push('AV1');
    supportInfo += supportedCodecs.length > 0 ? supportedCodecs.join(', ') : '无硬件解码';
    
    const config: PickerConfig = {
      title: '选择视频格式',
      subtitle: supportInfo,
      selectedValue: this.videoFormat,
      options: options,
      onSelect: (option: PickerOption) => {
        const value = option.value as string;
        // 警告用户选择了不支持的编码
        if ((value === 'HEVC' && !hevcSupported) || 
            (value === 'AV1' && !av1Supported) ||
            (value === 'H.264' && !h264Supported)) {
          this.showToast(`警告: 设备不支持 ${value}，串流可能失败`, 3000);
        }
        this.videoFormat = value;
        this.saveSetting(SettingsKeys.VIDEO_FORMAT, value);
        // H.264 不支持 HDR，自动禁用
        if (value === 'H.264' && this.enableHdr) {
          this.enableHdr = false;
          this.saveSetting(SettingsKeys.ENABLE_HDR, false);
          promptAction.showToast({
            message: 'H.264 不支持 HDR，已自动关闭',
            duration: 2000
          });
        }
      }
    };
    this.showPicker(config);
  }

  private showHdrModePicker(): void {
    const options: PickerOption[] = [
      { 
        title: 'HDR10 (PQ)', 
        subtitle: '标准 HDR10，使用 ST.2084 传输函数', 
        value: 'HDR10' 
      } as PickerOption,
      { 
        title: 'HLG', 
        subtitle: '需要 Sunshine Foundation 版本，适用于 HDR Vivid', 
        value: 'HLG' 
      } as PickerOption
    ];
    
    const config: PickerConfig = {
      title: '选择 HDR 模式',
      subtitle: 'HLG 模式需要 Sunshine Foundation 版本支持',
      selectedValue: this.hdrMode,
      options: options,
      onSelect: (option: PickerOption) => {
        const value = option.value as string;
        this.hdrMode = value;
        this.saveSetting(SettingsKeys.HDR_MODE, value);
      }
    };
    this.showPicker(config);
  }

  /**
   * 显示开源库说明对话框
   */
  private showOpenSourceLicenses(): void {
    this.licensesDialogController = new CustomDialogController({
      builder: OpenSourceLicensesDialog(),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.licensesDialogController.open();
  }

  /**
   * 显示更新日志对话框
   */
  private async showChangelog(): Promise<void> {
    const context = getContext(this) as common.Context;
    const entries = await loadChangelog(context);
    this.changelogDialogController = new CustomDialogController({
      builder: ChangelogDialog({ entries: entries }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.changelogDialogController.open();
  }

  /**
   * 显示隐私政策对话框
   */
  private showPrivacyPolicy(): void {
    this.privacyDialogController = new CustomDialogController({
      builder: PrivacyPolicyDialog(),
      alignment: DialogAlignment.Center,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.privacyDialogController.open();
  }

  /**
   * 使用系统浏览器打开 URL
   */
  private openUrl(url: string): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url
      };
      context.startAbility(want);
    } catch (err) {
      console.error('打开链接失败:', err);
      promptAction.showToast({ message: '打开链接失败', duration: 2000 });
    }
  }

  // 已转换为 Slider
  private showDeadzonePicker(): void { }
  private showOscOpacityPicker(): void { }
  
  private showAnalogScrollingPicker(): void {
    const options: PickerOption[] = [
      { title: '禁用', value: '禁用' } as PickerOption,
      { title: '左摇杆', value: '左摇杆' } as PickerOption,
      { title: '右摇杆', value: '右摇杆' } as PickerOption
    ];
    const config: PickerConfig = {
      title: '选择摇杆滚动',
      subtitle: '选择用于滚动的摇杆',
      selectedValue: this.analogScrolling,
      options: options,
      onSelect: (option: PickerOption) => {
        this.analogScrolling = option.value as string;
        this.saveSetting(SettingsKeys.ANALOG_SCROLLING, option.value as string);
      }
    };
    this.showPicker(config);
  }
  
  private showLanguagePicker(): void {
    const options: PickerOption[] = [
      { title: '跟随系统', value: '跟随系统' } as PickerOption,
      { title: '简体中文', value: '简体中文' } as PickerOption,
      { title: '繁體中文', value: '繁體中文' } as PickerOption,
      { title: 'English', value: 'English' } as PickerOption,
      { title: '日本語', value: '日本語' } as PickerOption,
      { title: '한국어', value: '한국어' } as PickerOption
    ];
    const config: PickerConfig = {
      title: '选择语言',
      subtitle: '选择应用显示语言',
      selectedValue: this.language,
      options: options,
      onSelect: (option: PickerOption) => {
        this.language = option.value as string;
        this.saveSetting(SettingsKeys.LANGUAGE, option.value as string);
      }
    };
    this.showPicker(config);
  }
  
  // 已转换为 Slider
  private showHostScalePicker(): void { }
  private showMicBitratePicker(): void { }
  private showVibrateFallbackStrengthPicker(): void { }
  private showDoubleTapThresholdPicker(): void { }
  private showEnhancedTouchZoneDividerPicker(): void { }
  private showPointerVelocityFactorPicker(): void { }
  
  /**
   * 显示震动模式选择器
   */
  private showVibrationModePicker(): void {
    const options: PickerOption[] = [
      { title: '自动', subtitle: '有手柄用手柄震动，无手柄用设备震动', value: '自动' } as PickerOption,
      { title: '仅手柄', subtitle: '只使用手柄震动', value: '仅手柄' } as PickerOption,
      { title: '仅设备', subtitle: '只使用设备震动', value: '仅设备' } as PickerOption,
      { title: '同时', subtitle: '手柄和设备同时震动', value: '同时' } as PickerOption
    ];
    const config: PickerConfig = {
      title: '选择震动模式',
      subtitle: '选择震动反馈的来源',
      selectedValue: this.vibrationMode,
      options: options,
      onSelect: (option: PickerOption) => {
        this.vibrationMode = option.value as string;
        this.saveSetting(SettingsKeys.VIBRATION_MODE, option.value as string);
      }
    };
    this.showPicker(config);
  }
  private showAudioVibrationSceneModePicker(): void {
    const options: PickerOption[] = [
      { title: '游戏/电影', subtitle: '持续低频驱动，适合爆炸、枪声、引擎等场景', value: '游戏/电影' } as PickerOption,
      { title: '音乐/节奏', subtitle: '鼓点节拍检测，按节奏脉冲振动', value: '音乐/节奏' } as PickerOption,
      { title: '自动', subtitle: '根据音频特征自动切换振动策略', value: '自动' } as PickerOption
    ];
    const config: PickerConfig = {
      title: '选择音频振动场景',
      subtitle: '不同场景使用不同的振动策略',
      selectedValue: this.audioVibrationSceneMode,
      options: options,
      onSelect: (option: PickerOption) => {
        this.audioVibrationSceneMode = option.value as string;
        this.saveSetting(SettingsKeys.AUDIO_VIBRATION_SCENE_MODE, option.value as string);
      }
    };
    this.showPicker(config);
  }
  private showLongPressFlatRegionPicker(): void { }
  
  private showScreenCombinationModePicker(): void {
    const options: PickerOption[] = [
      { title: '自动', subtitle: '系统自动选择', value: '自动' } as PickerOption,
      { title: '仅主显示器', value: '仅主显示器' } as PickerOption,
      { title: '扩展模式', subtitle: '多屏扩展', value: '扩展模式' } as PickerOption,
      { title: '复制模式', subtitle: '多屏镜像', value: '复制模式' } as PickerOption
    ];
    const config: PickerConfig = {
      title: '选择屏幕组合模式',
      subtitle: '选择多屏组合方式',
      selectedValue: this.screenCombinationMode,
      options: options,
      onSelect: (option: PickerOption) => {
        this.screenCombinationMode = option.value as string;
        this.saveSetting(SettingsKeys.SCREEN_COMBINATION_MODE, option.value as string);
      }
    };
    this.showPicker(config);
  }
  
  private showPerfOverlayOrientationPicker(): void {
    const options: PickerOption[] = [
      { title: '水平', value: '水平' } as PickerOption,
      { title: '垂直', value: '垂直' } as PickerOption
    ];
    const config: PickerConfig = {
      title: '选择性能覆盖层方向',
      subtitle: '选择显示方向',
      selectedValue: this.perfOverlayOrientation,
      options: options,
      onSelect: (option: PickerOption) => {
        this.perfOverlayOrientation = option.value as string;
        this.saveSetting(SettingsKeys.PERF_OVERLAY_ORIENTATION, option.value as string);
      }
    };
    this.showPicker(config);
  }
  
  private showPerfOverlayPositionPicker(): void {
    const options: PickerOption[] = [
      { title: '顶部', value: '顶部' } as PickerOption,
      { title: '底部', value: '底部' } as PickerOption,
      { title: '左上角', value: '左上角' } as PickerOption,
      { title: '右上角', value: '右上角' } as PickerOption,
      { title: '左下角', value: '左下角' } as PickerOption,
      { title: '右下角', value: '右下角' } as PickerOption
    ];
    const config: PickerConfig = {
      title: '选择性能覆盖层位置',
      subtitle: '选择显示位置',
      selectedValue: this.perfOverlayPosition,
      options: options,
      onSelect: (option: PickerOption) => {
        this.perfOverlayPosition = option.value as string;
        this.saveSetting(SettingsKeys.PERF_OVERLAY_POSITION, option.value as string);
      }
    };
    this.showPicker(config);
  }
  
  private showPerfOverlayItemsPicker(): void {
    // 所有可用项目 - 使用常量
    const allItems: PerfOverlayItemOption[] = [
      new PerfOverlayItemOption('resolution', `${PerfIcons.RESOLUTION} ${PerfLabels.RESOLUTION}`),
      new PerfOverlayItemOption('decoder', `${PerfIcons.DECODER} ${PerfLabels.DECODER}`),
      new PerfOverlayItemOption('render_fps', `${PerfLabels.FPS}`),
      new PerfOverlayItemOption('packet_loss', `${PerfIcons.PACKET_LOSS} ${PerfLabels.PACKET_LOSS}`),
      new PerfOverlayItemOption('bitrate', `${PerfIcons.BITRATE} ${PerfLabels.BITRATE}`),
      new PerfOverlayItemOption('network_latency', `${PerfIcons.NETWORK} ${PerfLabels.NETWORK}`),
      new PerfOverlayItemOption('decode_latency', `${PerfIcons.DECODE_NORMAL} ${PerfLabels.DECODE}`),
      new PerfOverlayItemOption('host_latency', `${PerfIcons.HOST} ${PerfLabels.HOST}`),
      new PerfOverlayItemOption('battery', `${PerfIcons.BATTERY} ${PerfLabels.BATTERY}`)
    ];
    
    // 转换为 DialogMultiOptionItem 格式
    const options: DialogMultiOptionItem[] = allItems.map((item: PerfOverlayItemOption): DialogMultiOptionItem => {
      return {
        key: item.key,
        title: item.title
      } as DialogMultiOptionItem;
    });
    
    this.multiOptionPickerDialogConfig = {
      title: '选择显示项目',
      subtitle: '点击项目切换显示/隐藏',
      options: options,
      selectedKeys: [...this.perfOverlayItems],
      minSelected: 1,
      onSelectionChange: (selectedKeys: string[]) => {
        this.perfOverlayItems = selectedKeys;
        this.saveSetting(SettingsKeys.PERF_OVERLAY_ITEMS, this.perfOverlayItems.join(','));
      }
    };
    
    // 创建并打开弹窗
    this.multiOptionPickerDialogController = new CustomDialogController({
      builder: MultiOptionPickerDialog({
        config: this.multiOptionPickerDialogConfig
      }),
      alignment: DialogAlignment.Bottom,
      customStyle: true,
      backgroundColor: Color.Transparent
    });
    this.multiOptionPickerDialogController.open();
  }
  
  private showEscMenuKeyPicker(): void {
    const options: PickerOption[] = [
      { title: 'ESC', value: 'ESC' } as PickerOption,
      { title: 'F1', value: 'F1' } as PickerOption,
      { title: 'F12', value: 'F12' } as PickerOption,
      { title: '~', value: '~' } as PickerOption
    ];
    const config: PickerConfig = {
      title: '选择 ESC 菜单按键',
      subtitle: '选择触发菜单的按键',
      selectedValue: this.escMenuKey,
      options: options,
      onSelect: (option: PickerOption) => {
        this.escMenuKey = option.value as string;
        this.saveSetting(SettingsKeys.ESC_MENU_KEY, option.value as string);
      }
    };
    this.showPicker(config);
  }
  
  private getBackgroundImageTypeLabel(): string {
    switch (this.backgroundImageType) {
      case 'default':
      case 'pipw':
        return 'Pipw 二次元 (默认)';
      case 'picsum':
        return 'Lorem Picsum (摄影)';
      case 'api':
        return '自定义 URL';
      case 'none':
        return '关闭';
      default:
        return 'Pipw 二次元 (默认)';
    }
  }
  
  private showBackgroundImageTypePicker(): void {
    const options: PickerOption[] = [
      { title: 'Pipw 二次元', subtitle: '二次元壁纸 (默认)', value: 'default' } as PickerOption,
      { title: 'Lorem Picsum', subtitle: '摄影壁纸 (Unsplash授权)', value: 'picsum' } as PickerOption,
      { title: '自定义 URL', subtitle: '使用自定义图片链接', value: 'api' } as PickerOption,
      { title: '关闭', subtitle: '不使用背景图片', value: 'none' } as PickerOption
    ];
    const config: PickerConfig = {
      title: '选择背景图片类型',
      subtitle: '选择背景图片来源',
      selectedValue: this.backgroundImageType,
      options: options,
      onSelect: async (option: PickerOption) => {
        this.backgroundImageType = option.value as string;
        const bgUtil = BackgroundImageUtil.getInstance();
        // 通过 BackgroundImageUtil 设置类型（会自动清除缓存、重置状态）
        await bgUtil.setBackgroundImageType(option.value as BackgroundImageType);
        // 选择关闭时，额外清除本地缓存文件
        if (option.value === 'none') {
          bgUtil.disableBackgroundImage();
        }
        this.showToast(`背景图片设置为: ${option.title}`);
      }
    };
    this.showPicker(config);
  }
  
  private showBackgroundImageUrlInput(): void {
    this.textInputTitle = '设置自定义背景图片 URL';
    this.textInputPlaceholder = '输入图片网址，留空使用默认 API';
    this.textInputValue = this.backgroundImageUrl;
    this.textInputCallback = (value: string) => {
      this.backgroundImageUrl = value;
      this.saveSetting(SettingsKeys.BACKGROUND_IMAGE_URL, value);
      if (value) {
        this.backgroundImageType = 'api';
        this.saveSetting(SettingsKeys.BACKGROUND_IMAGE_TYPE, 'api');
        this.showToast('自定义背景图片已设置');
      } else {
        this.backgroundImageType = 'default';
        this.saveSetting(SettingsKeys.BACKGROUND_IMAGE_TYPE, 'default');
        this.showToast('已恢复使用默认 API');
      }
    };
    this.showTextInputDialog = true;
  }
}

/**
 * 开源库信息接口
 */
interface OpenSourceLibrary {
  name: string;
  license: string;
  desc: string;
  url: string;
}

/**
 * 隐私政策章节接口
 */
interface PrivacySection {
  title: string;
  content: string;
}

/**
 * 开源库说明对话框
 */
@CustomDialog
struct OpenSourceLicensesDialog {
  controller: CustomDialogController;

  // 开源库数据
  private libraries: OpenSourceLibrary[] = [
    { name: 'Moonlight', license: 'GPLv3', desc: '游戏串流客户端核心项目', url: 'github.com/moonlight-stream' } as OpenSourceLibrary,
    { name: 'moonlight-common-c', license: 'GPLv3', desc: 'GameStream 协议实现', url: 'github.com/moonlight-stream/moonlight-common-c' } as OpenSourceLibrary,
    { name: 'ENet', license: 'MIT', desc: '可靠 UDP 网络库', url: 'github.com/lsalzman/enet' } as OpenSourceLibrary,
    { name: 'OpenSSL', license: 'Apache 2.0', desc: 'TLS/SSL 加密库', url: 'www.openssl.org' } as OpenSourceLibrary,
    { name: 'ohos-openssl', license: 'MIT', desc: 'OpenSSL HarmonyOS 移植', url: 'github.com/ohos-rs/ohos-openssl' } as OpenSourceLibrary,
    { name: 'Reed-Solomon', license: 'BSD 2-Clause', desc: '前向纠错算法', url: '' } as OpenSourceLibrary,
    { name: 'SDL GameControllerDB', license: 'zlib', desc: '手柄映射数据库', url: 'github.com/gabomdq/SDL_GameControllerDB' } as OpenSourceLibrary
  ];

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('开源库说明')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.TextPrimary)
        Blank()
        Text('关闭')
          .fontSize(14)
          .fontColor(AppColors.Primary)
          .onClick(() => {
            this.controller.close();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 12 })

      // 说明文字
      Text('本应用基于 Moonlight 开源项目开发，遵循 GPLv3 协议。以下是使用的开源库：')
        .fontSize(14)
        .fontColor(AppColors.TextSecondary)
        .padding({ left: 20, right: 20, bottom: 12 })
        .width('100%')

      // 库列表
      List({ space: 8 }) {
        ForEach(this.libraries, (lib: OpenSourceLibrary) => {
          ListItem() {
            Column({ space: 4 }) {
              Row() {
                Text(lib.name)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(AppColors.TextPrimary)
                Blank()
                Text(lib.license)
                  .fontSize(12)
                  .fontColor(AppColors.Primary)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  .backgroundColor(AppColors.PrimaryGlow)
                  .borderRadius(4)
              }
              .width('100%')

              Text(lib.desc)
                .fontSize(13)
                .fontColor(AppColors.TextSecondary)
                .width('100%')

              if (lib.url.length > 0) {
                Text(lib.url)
                  .fontSize(12)
                  .fontColor(AppColors.TextTertiary)
                  .width('100%')
              }
            }
            .width('100%')
            .padding(12)
            .backgroundColor(AppColors.CardBackground)
            .borderRadius(8)
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 20, right: 20 })
      .scrollBar(BarState.Off)

      // 底部说明
      Text('完整的开源库说明请查看项目仓库中的 OPEN_SOURCE_LICENSES.md')
        .fontSize(12)
        .fontColor(AppColors.TextTertiary)
        .padding(20)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('90%')
    .height('70%')
    .backgroundColor(AppColors.Background)
    .borderRadius(16)
    .transition(TransitionEffect.OPACITY.animation({ duration: AppAnimation.Normal, curve: Curve.EaseOut })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }).animation({ duration: AppAnimation.Normal, curve: Curve.EaseOut })))
  }
}

/**
 * 隐私政策对话框
 */
@CustomDialog
struct PrivacyPolicyDialog {
  controller: CustomDialogController;

  // 隐私政策章节
  private sections: PrivacySection[] = [
    { 
      title: '数据收集', 
      content: '本应用不会主动收集、存储或传输任何用户的个人身份信息。所有配置数据（如服务器地址、偏好设置）仅存储在您的设备本地。'
    } as PrivacySection,
    { 
      title: '网络通信', 
      content: '应用仅在您的本地网络内与电脑建立连接，用于传输游戏音视频流和输入指令。不涉及任何互联网数据传输。'
    } as PrivacySection,
    { 
      title: '权限使用', 
      content: '• 网络权限：建立与电脑的连接\n• 麦克风：语音聊天功能（可选）\n• 振动：手柄震动反馈\n• 传感器：体感控制功能（可选）'
    } as PrivacySection,
    { 
      title: '第三方服务', 
      content: '本应用不集成任何第三方分析或广告服务。'
    } as PrivacySection,
    { 
      title: '开源合规', 
      content: '本应用基于 Moonlight 项目开发，遵循 GPLv3 开源协议。源代码可在 GitHub 获取。'
    } as PrivacySection
  ];

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('隐私政策')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.TextPrimary)
        Blank()
        Text('关闭')
          .fontSize(14)
          .fontColor(AppColors.Primary)
          .onClick(() => {
            this.controller.close();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 12 })

      // 概述
      Text('Moonlight V+ 尊重并保护您的隐私。以下是我们的隐私政策摘要：')
        .fontSize(14)
        .fontColor(AppColors.TextSecondary)
        .padding({ left: 20, right: 20, bottom: 12 })
        .width('100%')

      // 政策章节列表
      List({ space: 12 }) {
        ForEach(this.sections, (section: PrivacySection) => {
          ListItem() {
            Column({ space: 8 }) {
              Text(section.title)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColors.TextPrimary)
                .width('100%')

              Text(section.content)
                .fontSize(14)
                .fontColor(AppColors.TextSecondary)
                .width('100%')
                .lineHeight(20)
            }
            .width('100%')
            .padding(12)
            .backgroundColor(AppColors.CardBackground)
            .borderRadius(8)
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 20, right: 20 })
      .scrollBar(BarState.Off)

      // 底部说明
      Text('完整隐私政策请查看项目仓库中的 PRIVACY_POLICY.md\n最后更新：2025年1月')
        .fontSize(12)
        .fontColor(AppColors.TextTertiary)
        .padding(20)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('90%')
    .height('70%')
    .backgroundColor(AppColors.Background)
    .borderRadius(16)
    .transition(TransitionEffect.OPACITY.animation({ duration: AppAnimation.Normal, curve: Curve.EaseOut })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }).animation({ duration: AppAnimation.Normal, curve: Curve.EaseOut })))
  }
}

/**
 * 更新日志对话框
 */
@CustomDialog
struct ChangelogDialog {
  controller: CustomDialogController;
  entries: ChangelogEntry[] = [];

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('更新日志')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.TextPrimary)
        Blank()
        Text('关闭')
          .fontSize(14)
          .fontColor(AppColors.Primary)
          .onClick(() => {
            this.controller.close();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 12 })

      // 版本列表
      List({ space: 16 }) {
        ForEach(this.entries, (entry: ChangelogEntry, index: number) => {
          ListItem() {
            Column({ space: 8 }) {
              // 版本号 + 日期 + 标记
              Row() {
                Text(`v${entry.version}`)
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColors.TextPrimary)
                if (index === 0) {
                  Text('最新')
                    .fontSize(11)
                    .fontColor(AppColors.Primary)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor(AppColors.PrimaryGlow)
                    .borderRadius(4)
                    .margin({ left: 8 })
                }
                Blank()
                Text(entry.date)
                  .fontSize(13)
                  .fontColor(AppColors.TextTertiary)
              }
              .width('100%')

              // 版本摘要
              if (entry.summary !== undefined && entry.summary!.length > 0) {
                Text(entry.summary!)
                  .fontSize(14)
                  .fontColor(AppColors.TextSecondary)
                  .width('100%')
              }

              // 变更列表
              Column({ space: 6 }) {
                ForEach(entry.changes, (change: ChangeItem) => {
                  Row({ space: 8 }) {
                    Text(getChangeTypeConfig(change.type).label)
                      .fontSize(11)
                      .fontColor('#FFFFFF')
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .backgroundColor(getChangeTypeConfig(change.type).color)
                      .borderRadius(4)
                      .flexShrink(0)
                    Text(change.text)
                      .fontSize(14)
                      .fontColor(AppColors.TextPrimary)
                      .layoutWeight(1)
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Top)
                })
              }
              .width('100%')
            }
            .width('100%')
            .padding(12)
            .backgroundColor(AppColors.CardBackground)
            .borderRadius(8)
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 20, right: 20 })
      .scrollBar(BarState.Off)

      // 底部提示
      Text('在 GitHub 发布页查看完整更新历史')
        .fontSize(12)
        .fontColor(AppColors.TextTertiary)
        .padding(20)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('90%')
    .height('70%')
    .backgroundColor(AppColors.Background)
    .borderRadius(16)
    .transition(TransitionEffect.OPACITY.animation({ duration: AppAnimation.Normal, curve: Curve.EaseOut })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }).animation({ duration: AppAnimation.Normal, curve: Curve.EaseOut })))
  }
}
