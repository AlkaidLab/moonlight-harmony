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
 * 设置服务
 * 
 * 统一管理应用设置的读取和转换
 * 将设置值转换为串流配置
 */
import { PreferencesUtil } from '../utils/PreferencesUtil';
import {
  StreamConfig,
  AudioConfiguration,
  ColorRange,
  HdrMode,
  RemoteConfig,
  ScreenCombinationMode,
  PerfOverlayOrientation,
  PerfOverlayPosition,
  getRecommendedBitrate
} from '../model/StreamConfig';

/**
 * 设置键名常量类（与 SettingsPageV2 保持同步）
 */
export class SettingsKeys {
  // 视频设置
  static readonly RESOLUTION: string = 'settings_resolution';
  static readonly FPS: string = 'settings_fps';
  static readonly BITRATE: string = 'settings_bitrate';
  static readonly HOST_SCALE: string = 'settings_host_scale';
  static readonly ENABLE_HDR: string = 'settings_enable_hdr';
  static readonly HDR_MODE: string = 'settings_hdr_mode';  // 'HDR10' or 'HLG'
  static readonly ENABLE_HDR_HIGH_BRIGHTNESS: string = 'settings_enable_hdr_high_brightness';
  static readonly VIDEO_FORMAT: string = 'settings_video_format';
  static readonly STRETCH_VIDEO: string = 'settings_stretch_video';
  static readonly FULL_RANGE: string = 'settings_full_range';
  static readonly REVERSE_RESOLUTION: string = 'settings_reverse_resolution';
  static readonly ROTABLE_SCREEN: string = 'settings_rotable_screen';

  // 音频设置
  static readonly AUDIO_CONFIG: string = 'settings_audio_config';
  static readonly ENABLE_LOCAL_AUDIO: string = 'settings_enable_local_audio';
  static readonly ENABLE_SPATIALIZER: string = 'settings_enable_spatializer';
  static readonly CONTROL_ONLY: string = 'settings_control_only';
  static readonly ENABLE_MIC: string = 'settings_enable_mic';
  static readonly MIC_BITRATE: string = 'settings_mic_bitrate';

  // 输入 - 手柄设置
  static readonly ENABLE_VIBRATION: string = 'settings_enable_vibration';
  static readonly VIBRATION_MODE: string = 'settings_vibration_mode';  // 震动模式：自动/仅手柄/仅设备/同时
  static readonly VIBRATE_FALLBACK_STRENGTH: string = 'settings_vibrate_fallback_strength';
  static readonly MULTI_CONTROLLER: string = 'settings_multi_controller';
  static readonly FLIP_FACE_BUTTONS: string = 'settings_flip_face_buttons';
  static readonly DEADZONE: string = 'settings_deadzone';
  static readonly GAMEPAD_MOTION_SENSORS: string = 'settings_gamepad_motion_sensors';
  static readonly GAMEPAD_MOTION_FALLBACK: string = 'settings_gamepad_motion_fallback';
  static readonly GAMEPAD_TOUCHPAD_MOUSE: string = 'settings_gamepad_touchpad_mouse';
  static readonly ENABLE_START_KEY_MENU: string = 'settings_enable_start_key_menu';
  static readonly IGNORE_DEVICE_DISCONNECT: string = 'settings_ignore_device_disconnect';  // 忽略手柄断开信号（用于电源管理问题的手柄）
  static readonly GC_BUTTON_HOME_MAPPING: string = 'settings_gc_button_home_mapping';  // Game Controller Kit 2313按键映射

  // 输入 - 屏幕控制器
  static readonly ENABLE_ONSCREEN_CONTROLS: string = 'settings_enable_onscreen_controls';
  static readonly ENABLE_ONSCREEN_KEYBOARD: string = 'settings_enable_onscreen_keyboard';
  static readonly ONLY_L3_R3: string = 'settings_only_l3_r3';
  static readonly SHOW_GUIDE_BUTTON: string = 'settings_show_guide_button';
  static readonly HALF_HEIGHT_OSC_PORTRAIT: string = 'settings_half_height_osc_portrait';
  static readonly OSC_OPACITY: string = 'settings_osc_opacity';
  static readonly VIBRATE_OSC: string = 'settings_vibrate_osc';

  // 输入 - 鼠标/触控
  static readonly MOUSE_EMULATION: string = 'settings_mouse_emulation';
  static readonly ABSOLUTE_MOUSE_MODE: string = 'settings_absolute_mouse_mode';
  static readonly TOUCHSCREEN_TRACKPAD: string = 'settings_touchscreen_trackpad';
  static readonly ENABLE_DOUBLE_CLICK_DRAG: string = 'settings_enable_double_click_drag';
  static readonly DOUBLE_TAP_TIME_THRESHOLD: string = 'settings_double_tap_time_threshold';
  static readonly ENABLE_LOCAL_CURSOR: string = 'settings_enable_local_cursor';
  static readonly ANALOG_SCROLLING: string = 'settings_analog_scrolling';
  static readonly MOUSE_NAV_BUTTONS: string = 'settings_mouse_nav_buttons';

  // 增强触控设置
  static readonly ENABLE_ENHANCED_TOUCH: string = 'settings_enable_enhanced_touch';
  static readonly ENHANCED_TOUCH_ON_RIGHT: string = 'settings_enhanced_touch_on_right';
  static readonly ENHANCED_TOUCH_ZONE_DIVIDER: string = 'settings_enhanced_touch_zone_divider';
  static readonly POINTER_VELOCITY_FACTOR: string = 'settings_pointer_velocity_factor';
  static readonly LONG_PRESS_FLAT_REGION: string = 'settings_long_press_flat_region';

  // 主机设置
  static readonly ENABLE_SOPS: string = 'settings_enable_sops';
  static readonly SCREEN_COMBINATION_MODE: string = 'settings_screen_combination_mode';
  static readonly LOCK_SCREEN_AFTER_DISCONNECT: string = 'settings_lock_screen_after_disconnect';
  static readonly SWAP_QUIT_AND_DISCONNECT: string = 'settings_swap_quit_and_disconnect';

  // 高级设置
  static readonly DECODER_BUFFER_COUNT: string = 'settings_decoder_buffer_count';
  static readonly ENABLE_SYNC_DECODE: string = 'settings_enable_sync_decode';  // 同步解码模式
  static readonly ENABLE_VRR: string = 'settings_enable_vrr';  // VRR 可变刷新率模式
  static readonly ENABLE_VSYNC: string = 'settings_enable_vsync';
  static readonly ENABLE_PERF_OVERLAY: string = 'settings_enable_perf_overlay';
  static readonly PERF_OVERLAY_ORIENTATION: string = 'settings_perf_overlay_orientation';
  static readonly PERF_OVERLAY_POSITION: string = 'settings_perf_overlay_position';
  static readonly PERF_OVERLAY_LOCKED: string = 'settings_perf_overlay_locked';
  static readonly PERF_OVERLAY_ITEMS: string = 'settings_perf_overlay_items';
  static readonly LATENCY_TOAST: string = 'settings_latency_toast';
  static readonly DISABLE_WARNINGS: string = 'settings_disable_warnings';
  static readonly REDUCE_REFRESH_RATE: string = 'settings_reduce_refresh_rate';
  static readonly ENABLE_STUN: string = 'settings_enable_stun';
  static readonly ENABLE_ESC_MENU: string = 'settings_enable_esc_menu';
  static readonly ESC_MENU_KEY: string = 'settings_esc_menu_key';

  // UI 设置
  static readonly SMALL_ICON_MODE: string = 'settings_small_icon_mode';
  static readonly LANGUAGE: string = 'settings_language';
  static readonly BACKGROUND_IMAGE_URL: string = 'settings_background_image_url';
  static readonly RESUME_STREAM: string = 'settings_resume_stream';
  
  // 开发者模式
  static readonly DEVELOPER_MODE: string = 'settings_developer_mode';
  
  // 性能模式
  static readonly PERFORMANCE_MODE: string = 'settings_performance_mode';
}

/**
 * 输入设置
 */
export interface InputSettings {
  // 手柄
  enableVibration: boolean;
  vibrationMode: string;  // 自动/仅手柄/仅设备/同时
  vibrateFallbackStrength: number;
  multiController: boolean;
  flipFaceButtons: boolean;
  deadzone: number;
  gamepadMotionSensors: boolean;
  gamepadMotionFallback: boolean;
  gamepadTouchpadMouse: boolean;
  enableStartKeyMenu: boolean;
  ignoreDeviceDisconnect: boolean;  // 忽略手柄断开信号

  // 屏幕控制器
  enableOnscreenControls: boolean;
  enableOnscreenKeyboard: boolean;
  onlyL3R3: boolean;
  showGuideButton: boolean;
  halfHeightOscPortrait: boolean;
  oscOpacity: number;
  vibrateOsc: boolean;

  // 鼠标/触控
  mouseEmulation: boolean;
  absoluteMouseMode: boolean;
  touchscreenTrackpad: boolean;
  enableDoubleClickDrag: boolean;
  doubleTapTimeThreshold: number;
  enableLocalCursor: boolean;
  analogScrolling: string;
  mouseNavButtons: boolean;

  // 增强触控
  enableEnhancedTouch: boolean;
  enhancedTouchOnRight: boolean;
  enhancedTouchZoneDivider: number;
  pointerVelocityFactor: number;
  longPressFlatRegion: number;
}

/**
 * 主机设置
 */
export interface HostSettings {
  enableSops: boolean;
  screenCombinationMode: string;
  lockScreenAfterDisconnect: boolean;
  swapQuitAndDisconnect: boolean;
}

/**
 * 显示设置
 */
export interface DisplaySettings {
  stretchVideo: boolean;
  reverseResolution: boolean;
  rotableScreen: boolean;
  enableHdrHighBrightness: boolean;
  enablePerfOverlay: boolean;
  perfOverlayOrientation: string;
  perfOverlayPosition: string;
  perfOverlayLocked?: boolean;       // 是否锁定覆盖层
  perfOverlayItems?: string[];       // 启用的性能项目
}

/**
 * 高级设置
 */
export interface AdvancedSettings {
  decoderBufferCount: number;
  enableSyncDecode: boolean;  // 同步解码模式（API 20+，减少回调延迟）
  enableVrr: boolean;  // VRR 可变刷新率模式
  latencyToast: boolean;
  disableWarnings: boolean;
  reduceRefreshRate: boolean;
  enableStun: boolean;
  enableEscMenu: boolean;
  escMenuKey: string;
  performanceMode: boolean;  // 性能模式：优化线程优先级和系统资源
}

/**
 * 音频设置
 */
export interface AudioSettings {
  audioConfig: string;
  enableLocalAudio: boolean;
  enableSpatializer: boolean;
  controlOnly: boolean;
  enableMic: boolean;
  micBitrate: number;
}

/**
 * 分辨率接口
 */
interface Resolution {
  width: number;
  height: number;
}

/**
 * 设置服务单例
 */
export class SettingsService {
  private static instance: SettingsService | null = null;

  private constructor() {}

  static getInstance(): SettingsService {
    if (!SettingsService.instance) {
      SettingsService.instance = new SettingsService();
    }
    return SettingsService.instance;
  }

  /**
   * 解析分辨率字符串
   * 支持预设格式(如 "1080p", "4K")和自定义格式(如 "2560x1080")
   */
  private parseResolution(resolutionStr: string): Resolution {
    // 预设分辨率
    switch (resolutionStr) {
      case '720p':
        return { width: 1280, height: 720 } as Resolution;
      case '1080p':
        return { width: 1920, height: 1080 } as Resolution;
      case '1440p':
        return { width: 2560, height: 1440 } as Resolution;
      case '4K':
        return { width: 3840, height: 2160 } as Resolution;
      case '360p':
        return { width: 640, height: 360 } as Resolution;
      case '480p':
        return { width: 854, height: 480 } as Resolution;
    }
    
    // 尝试解析自定义格式: WIDTHxHEIGHT
    const match = resolutionStr.match(/^(\d+)x(\d+)$/);
    if (match) {
      const width = parseInt(match[1]);
      const height = parseInt(match[2]);
      if (width >= 320 && width <= 7680 && height >= 240 && height <= 4320) {
        return { width, height } as Resolution;
      }
    }
    
    // 默认 1080p
    return { width: 1920, height: 1080 } as Resolution;
  }

  /**
   * 解析帧率字符串
   */
  private parseFps(fpsStr: string): number {
    // 检查是否是自定义帧率
    if (fpsStr.startsWith('自定义:')) {
      const customFps = parseInt(fpsStr.split(':')[1]);
      return isNaN(customFps) ? 60 : customFps;
    }
    
    switch (fpsStr) {
      case '30 FPS':
        return 30;
      case '60 FPS':
        return 60;
      case '90 FPS':
        return 90;
      case '119.88 FPS':
        return 120; // 使用 120 作为 fps，实际帧率由 clientRefreshRateX100 控制
      case '120 FPS':
        return 120;
      default:
        return 60;
    }
  }

  /**
   * 解析帧率字符串并返回 clientRefreshRateX100
   * 用于 NTSC 帧率支持 (如 119.88 Hz)
   */
  private parseClientRefreshRateX100(fpsStr: string): number {
    // 检查是否是自定义帧率
    if (fpsStr.startsWith('自定义:')) {
      const customFps = parseInt(fpsStr.split(':')[1]);
      return isNaN(customFps) ? 6000 : customFps * 100;
    }
    
    switch (fpsStr) {
      case '30 FPS':
        return 3000;
      case '60 FPS':
        return 6000;
      case '90 FPS':
        return 9000;
      case '119.88 FPS':
        return 11988;  // NTSC 标准: 120000/1001 ≈ 119.88 Hz
      case '120 FPS':
        return 12000;
      default:
        return 6000;
    }
  }

  /**
   * 解析音频配置字符串
   */
  private parseAudioConfig(configStr: string): AudioConfiguration {
    switch (configStr) {
      case '立体声':
        return AudioConfiguration.STEREO;
      case '5.1 环绕声':
        return AudioConfiguration.SURROUND_51;
      case '7.1 环绕声':
        return AudioConfiguration.SURROUND_71;
      default:
        return AudioConfiguration.STEREO;
    }
  }

  /**
   * 解析视频编码格式
   */
  private parseVideoFormat(formatStr: string): 'H.264' | 'HEVC' {
    switch (formatStr) {
      case '自动':
      case 'HEVC (H.265)':
        return 'HEVC';
      case 'H.264':
        return 'H.264';
      default:
        return 'HEVC';
    }
  }

  /**
   * 解析屏幕组合模式
   */
  private parseScreenCombinationMode(modeStr: string): ScreenCombinationMode {
    switch (modeStr) {
      case '自动':
        return ScreenCombinationMode.AUTO;
      case '仅主显示器':
        return ScreenCombinationMode.PRIMARY_ONLY;
      case '扩展模式':
        return ScreenCombinationMode.EXTEND;
      case '复制模式':
        return ScreenCombinationMode.DUPLICATE;
      default:
        return ScreenCombinationMode.AUTO;
    }
  }

  /**
   * 解析性能覆盖层方向
   */
  private parsePerfOverlayOrientation(orientationStr: string): PerfOverlayOrientation {
    switch (orientationStr) {
      case '水平':
        return PerfOverlayOrientation.HORIZONTAL;
      case '垂直':
        return PerfOverlayOrientation.VERTICAL;
      default:
        return PerfOverlayOrientation.HORIZONTAL;
    }
  }

  /**
   * 解析性能覆盖层位置
   */
  private parsePerfOverlayPosition(positionStr: string): PerfOverlayPosition {
    switch (positionStr) {
      case '顶部':
        return PerfOverlayPosition.TOP;
      case '底部':
        return PerfOverlayPosition.BOTTOM;
      case '左上角':
        return PerfOverlayPosition.TOP_LEFT;
      case '右上角':
        return PerfOverlayPosition.TOP_RIGHT;
      case '左下角':
        return PerfOverlayPosition.BOTTOM_LEFT;
      case '右下角':
        return PerfOverlayPosition.BOTTOM_RIGHT;
      default:
        return PerfOverlayPosition.TOP;
    }
  }

  /**
   * 获取布尔值设置
   */
  private async getBoolean(key: string, defaultValue: boolean): Promise<boolean> {
    const value = await PreferencesUtil.get<string | boolean>(key, defaultValue.toString());
    if (typeof value === 'boolean') {
      return value;
    }
    return value === 'true';
  }

  /**
   * 获取数值设置
   */
  private async getNumber(key: string, defaultValue: number): Promise<number> {
    const value = await PreferencesUtil.get<number | string>(key, defaultValue.toString());
    if (typeof value === 'number') {
      return value;
    }
    return parseInt(value) || defaultValue;
  }

  /**
   * 获取字符串设置
   */
  private async getString(key: string, defaultValue: string): Promise<string> {
    return await PreferencesUtil.get<string>(key, defaultValue);
  }

  /**
   * 从设置生成 StreamConfig
   */
  async getStreamConfig(): Promise<StreamConfig> {
    // 获取基础视频设置
    const resolutionStr = await this.getString(SettingsKeys.RESOLUTION, '1080p');
    const fpsStr = await this.getString(SettingsKeys.FPS, '60 FPS');
    const bitrateRaw = await this.getNumber(SettingsKeys.BITRATE, 0);  // 默认 0 表示自动计算
    const hostScale = await this.getNumber(SettingsKeys.HOST_SCALE, 100);
    const enableHdr = await this.getBoolean(SettingsKeys.ENABLE_HDR, false);
    const hdrModeStr = await this.getString(SettingsKeys.HDR_MODE, 'HDR10');
    const videoFormatStr = await this.getString(SettingsKeys.VIDEO_FORMAT, '自动');
    const fullRange = await this.getBoolean(SettingsKeys.FULL_RANGE, false);
    const reverseResolution = await this.getBoolean(SettingsKeys.REVERSE_RESOLUTION, false);

    // 解析分辨率和帧率
    let resolution: Resolution = this.parseResolution(resolutionStr);
    const fps = this.parseFps(fpsStr);

    // 应用分辨率缩放
    if (hostScale !== 100) {
      const scaledWidth = Math.round(resolution.width * hostScale / 100);
      const scaledHeight = Math.round(resolution.height * hostScale / 100);
      resolution = { width: scaledWidth, height: scaledHeight } as Resolution;
    }

    // 反转分辨率
    if (reverseResolution) {
      const temp = resolution.width;
      resolution.width = resolution.height;
      resolution.height = temp;
    }

    // 计算码率（Mbps -> Kbps）
    let bitrate = bitrateRaw * 1000;
    if (bitrateRaw <= 0) {
      // 如果码率设置为 0 或无效，使用推荐值
      bitrate = getRecommendedBitrate(resolution.width, resolution.height, fps);
    }

    // 获取音频设置
    const audioConfigStr = await this.getString(SettingsKeys.AUDIO_CONFIG, '立体声');
    const enableLocalAudio = await this.getBoolean(SettingsKeys.ENABLE_LOCAL_AUDIO, false);
    const developerMode = await this.getBoolean(SettingsKeys.DEVELOPER_MODE, false);
    const enableMic = developerMode && await this.getBoolean(SettingsKeys.ENABLE_MIC, false);  // 非开发者模式下强制禁用
    const micBitrate = await this.getNumber(SettingsKeys.MIC_BITRATE, 64);
    const controlOnly = await this.getBoolean(SettingsKeys.CONTROL_ONLY, false);
    const enableSpatializer = await this.getBoolean(SettingsKeys.ENABLE_SPATIALIZER, false);

    // 获取主机设置
    const enableSops = await this.getBoolean(SettingsKeys.ENABLE_SOPS, true);
    const multiController = await this.getBoolean(SettingsKeys.MULTI_CONTROLLER, true);
    const lockScreenAfterDisconnect = await this.getBoolean(SettingsKeys.LOCK_SCREEN_AFTER_DISCONNECT, false);
    const screenCombinationModeStr = await this.getString(SettingsKeys.SCREEN_COMBINATION_MODE, '自动');

    // 获取输入设置
    const enableVibration = await this.getBoolean(SettingsKeys.ENABLE_VIBRATION, true);
    const vibrationMode = await this.getString(SettingsKeys.VIBRATION_MODE, '自动');
    const vibrateFallbackStrength = await this.getNumber(SettingsKeys.VIBRATE_FALLBACK_STRENGTH, 100);
    const deadzone = await this.getNumber(SettingsKeys.DEADZONE, 7);
    const flipFaceButtons = await this.getBoolean(SettingsKeys.FLIP_FACE_BUTTONS, false);

    // 获取鼠标/触控设置
    const mouseEmulation = await this.getBoolean(SettingsKeys.MOUSE_EMULATION, true);
    const absoluteMouseMode = await this.getBoolean(SettingsKeys.ABSOLUTE_MOUSE_MODE, true);  // 默认启用绝对触摸模式
    const touchscreenTrackpad = await this.getBoolean(SettingsKeys.TOUCHSCREEN_TRACKPAD, false);
    const enableDoubleClickDrag = await this.getBoolean(SettingsKeys.ENABLE_DOUBLE_CLICK_DRAG, false);
    const doubleTapTimeThreshold = await this.getNumber(SettingsKeys.DOUBLE_TAP_TIME_THRESHOLD, 125);
    const enableLocalCursor = await this.getBoolean(SettingsKeys.ENABLE_LOCAL_CURSOR, false);

    // 获取增强触控设置
    const enableEnhancedTouch = await this.getBoolean(SettingsKeys.ENABLE_ENHANCED_TOUCH, true);
    const enhancedTouchOnRight = await this.getBoolean(SettingsKeys.ENHANCED_TOUCH_ON_RIGHT, false);
    const enhancedTouchZoneDivider = await this.getNumber(SettingsKeys.ENHANCED_TOUCH_ZONE_DIVIDER, 50);
    const pointerVelocityFactor = await this.getNumber(SettingsKeys.POINTER_VELOCITY_FACTOR, 100);
    const longPressFlatRegion = await this.getNumber(SettingsKeys.LONG_PRESS_FLAT_REGION, 0);

    // 获取高级设置
    const decoderBufferCount = await this.getNumber(SettingsKeys.DECODER_BUFFER_COUNT, 0);
    const enableSyncDecode = await this.getBoolean(SettingsKeys.ENABLE_SYNC_DECODE, false);  // 默认禁用
    const enableVrr = await this.getBoolean(SettingsKeys.ENABLE_VRR, false);  // VRR 默认禁用
    const enableVsync = await this.getBoolean(SettingsKeys.ENABLE_VSYNC, false);
    const enableStun = await this.getBoolean(SettingsKeys.ENABLE_STUN, false);
    const stretchVideo = await this.getBoolean(SettingsKeys.STRETCH_VIDEO, false);
    const hdrHighBrightness = await this.getBoolean(SettingsKeys.ENABLE_HDR_HIGH_BRIGHTNESS, false);

    // 获取显示设置
    const enablePerfOverlay = await this.getBoolean(SettingsKeys.ENABLE_PERF_OVERLAY, false);
    const perfOverlayOrientationStr = await this.getString(SettingsKeys.PERF_OVERLAY_ORIENTATION, '垂直');
    const perfOverlayPositionStr = await this.getString(SettingsKeys.PERF_OVERLAY_POSITION, '右上角');
    const enableOnscreenControls = await this.getBoolean(SettingsKeys.ENABLE_ONSCREEN_CONTROLS, false);
    const oscOpacity = await this.getNumber(SettingsKeys.OSC_OPACITY, 90);
    const enableEscMenu = await this.getBoolean(SettingsKeys.ENABLE_ESC_MENU, true);

    // 构建 StreamConfig
    const config: StreamConfig = {
      // 视频设置
      width: resolution.width,
      height: resolution.height,
      fps: fps,
      clientRefreshRateX100: this.parseClientRefreshRateX100(fpsStr),
      bitrate: bitrate,
      codec: this.parseVideoFormat(videoFormatStr),
      hdr: enableHdr,
      hdrMode: hdrModeStr === 'HLG' ? HdrMode.HLG : HdrMode.HDR10,
      hdrHighBrightness: hdrHighBrightness,
      stretchVideo: stretchVideo,

      // 音频设置
      audioEnabled: !controlOnly,
      microphoneEnabled: enableMic,
      micBitrate: micBitrate,
      audioConfig: this.parseAudioConfig(audioConfigStr),
      enableSpatializer: enableSpatializer,

      // 主机设置
      sops: enableSops,
      playLocalAudio: enableLocalAudio,
      screenCombinationMode: this.parseScreenCombinationMode(screenCombinationModeStr),
      lockScreenAfterDisconnect: lockScreenAfterDisconnect,

      // 输入设置
      multiController: multiController,
      attachedGamepadMask: 0,
      enableVibration: enableVibration,
      vibrationMode: vibrationMode,
      vibrateFallbackStrength: vibrateFallbackStrength,
      deadzone: deadzone,
      flipFaceButtons: flipFaceButtons,

      // 鼠标/触控设置
      mouseEmulation: mouseEmulation,
      absoluteMouseMode: absoluteMouseMode,
      touchscreenTrackpad: touchscreenTrackpad,
      enableDoubleClickDrag: enableDoubleClickDrag,
      doubleTapTimeThreshold: doubleTapTimeThreshold,
      enableLocalCursor: enableLocalCursor,

      // 增强触控设置
      enableEnhancedTouch: enableEnhancedTouch,
      enhancedTouchOnRight: enhancedTouchOnRight,
      enhancedTouchZoneDivider: enhancedTouchZoneDivider,
      pointerVelocityFactor: pointerVelocityFactor,
      longPressFlatRegion: longPressFlatRegion,

      // 高级选项
      packetSize: 1024,
      encryptionFlags: 0,
      colorRange: fullRange ? ColorRange.FULL : ColorRange.LIMITED,
      decoderBufferCount: decoderBufferCount,
      enableSyncDecode: enableSyncDecode,
      enableVrr: enableVrr,
      enableVsync: enableVsync,
      enableStun: enableStun,
      performanceMode: await this.getBoolean(SettingsKeys.PERFORMANCE_MODE, false),

      // 运行时选项
      remote: RemoteConfig.AUTO,

      // 显示选项
      showPerfOverlay: enablePerfOverlay,
      perfOverlayOrientation: this.parsePerfOverlayOrientation(perfOverlayOrientationStr),
      perfOverlayPosition: this.parsePerfOverlayPosition(perfOverlayPositionStr),
      showOnscreenControls: enableOnscreenControls,
      onscreenControlsOpacity: oscOpacity,
      enableEscMenu: enableEscMenu
    };

    return config;
  }

  /**
   * 获取输入设置
   */
  async getInputSettings(): Promise<InputSettings> {
    return {
      // 手柄
      enableVibration: await this.getBoolean(SettingsKeys.ENABLE_VIBRATION, true),
      vibrationMode: await this.getString(SettingsKeys.VIBRATION_MODE, '自动'),
      vibrateFallbackStrength: await this.getNumber(SettingsKeys.VIBRATE_FALLBACK_STRENGTH, 100),
      multiController: await this.getBoolean(SettingsKeys.MULTI_CONTROLLER, true),
      flipFaceButtons: await this.getBoolean(SettingsKeys.FLIP_FACE_BUTTONS, false),
      deadzone: await this.getNumber(SettingsKeys.DEADZONE, 7),
      gamepadMotionSensors: await this.getBoolean(SettingsKeys.GAMEPAD_MOTION_SENSORS, true),
      gamepadMotionFallback: await this.getBoolean(SettingsKeys.GAMEPAD_MOTION_FALLBACK, false),
      gamepadTouchpadMouse: await this.getBoolean(SettingsKeys.GAMEPAD_TOUCHPAD_MOUSE, false),
      enableStartKeyMenu: await this.getBoolean(SettingsKeys.ENABLE_START_KEY_MENU, true),
      ignoreDeviceDisconnect: await this.getBoolean(SettingsKeys.IGNORE_DEVICE_DISCONNECT, false),

      // 屏幕控制器
      enableOnscreenControls: await this.getBoolean(SettingsKeys.ENABLE_ONSCREEN_CONTROLS, false),
      enableOnscreenKeyboard: await this.getBoolean(SettingsKeys.ENABLE_ONSCREEN_KEYBOARD, false),
      onlyL3R3: await this.getBoolean(SettingsKeys.ONLY_L3_R3, false),
      showGuideButton: await this.getBoolean(SettingsKeys.SHOW_GUIDE_BUTTON, true),
      halfHeightOscPortrait: await this.getBoolean(SettingsKeys.HALF_HEIGHT_OSC_PORTRAIT, true),
      oscOpacity: await this.getNumber(SettingsKeys.OSC_OPACITY, 90),
      vibrateOsc: await this.getBoolean(SettingsKeys.VIBRATE_OSC, true),

      // 鼠标/触控
      mouseEmulation: await this.getBoolean(SettingsKeys.MOUSE_EMULATION, true),
      absoluteMouseMode: await this.getBoolean(SettingsKeys.ABSOLUTE_MOUSE_MODE, true),  // 默认启用绝对触摸模式
      touchscreenTrackpad: await this.getBoolean(SettingsKeys.TOUCHSCREEN_TRACKPAD, false),
      enableDoubleClickDrag: await this.getBoolean(SettingsKeys.ENABLE_DOUBLE_CLICK_DRAG, false),
      doubleTapTimeThreshold: await this.getNumber(SettingsKeys.DOUBLE_TAP_TIME_THRESHOLD, 125),
      enableLocalCursor: await this.getBoolean(SettingsKeys.ENABLE_LOCAL_CURSOR, false),
      analogScrolling: await this.getString(SettingsKeys.ANALOG_SCROLLING, '右摇杆'),
      mouseNavButtons: await this.getBoolean(SettingsKeys.MOUSE_NAV_BUTTONS, false),

      // 增强触控
      enableEnhancedTouch: await this.getBoolean(SettingsKeys.ENABLE_ENHANCED_TOUCH, true),
      enhancedTouchOnRight: await this.getBoolean(SettingsKeys.ENHANCED_TOUCH_ON_RIGHT, false),
      enhancedTouchZoneDivider: await this.getNumber(SettingsKeys.ENHANCED_TOUCH_ZONE_DIVIDER, 50),
      pointerVelocityFactor: await this.getNumber(SettingsKeys.POINTER_VELOCITY_FACTOR, 100),
      longPressFlatRegion: await this.getNumber(SettingsKeys.LONG_PRESS_FLAT_REGION, 0)
    };
  }

  /**
   * 获取主机设置
   */
  async getHostSettings(): Promise<HostSettings> {
    return {
      enableSops: await this.getBoolean(SettingsKeys.ENABLE_SOPS, true),
      screenCombinationMode: await this.getString(SettingsKeys.SCREEN_COMBINATION_MODE, '自动'),
      lockScreenAfterDisconnect: await this.getBoolean(SettingsKeys.LOCK_SCREEN_AFTER_DISCONNECT, false),
      swapQuitAndDisconnect: await this.getBoolean(SettingsKeys.SWAP_QUIT_AND_DISCONNECT, false)
    };
  }

  /**
   * 获取显示设置
   */
  async getDisplaySettings(): Promise<DisplaySettings> {
    const itemsStr = await this.getString(SettingsKeys.PERF_OVERLAY_ITEMS, 'resolution,decoder,render_fps,packet_loss,bitrate,network_latency,decode_latency');
    const items = itemsStr.split(',').filter(item => item.length > 0);
    
    return {
      stretchVideo: await this.getBoolean(SettingsKeys.STRETCH_VIDEO, false),
      reverseResolution: await this.getBoolean(SettingsKeys.REVERSE_RESOLUTION, false),
      rotableScreen: await this.getBoolean(SettingsKeys.ROTABLE_SCREEN, false),
      enableHdrHighBrightness: await this.getBoolean(SettingsKeys.ENABLE_HDR_HIGH_BRIGHTNESS, false),
      enablePerfOverlay: await this.getBoolean(SettingsKeys.ENABLE_PERF_OVERLAY, false),
      perfOverlayOrientation: await this.getString(SettingsKeys.PERF_OVERLAY_ORIENTATION, '垂直'),
      perfOverlayPosition: await this.getString(SettingsKeys.PERF_OVERLAY_POSITION, '右上角'),
      perfOverlayLocked: await this.getBoolean(SettingsKeys.PERF_OVERLAY_LOCKED, false),
      perfOverlayItems: items
    };
  }

  /**
   * 获取高级设置
   */
  async getAdvancedSettings(): Promise<AdvancedSettings> {
    return {
      decoderBufferCount: await this.getNumber(SettingsKeys.DECODER_BUFFER_COUNT, 0),
      enableSyncDecode: await this.getBoolean(SettingsKeys.ENABLE_SYNC_DECODE, false),  // 默认禁用
      enableVrr: await this.getBoolean(SettingsKeys.ENABLE_VRR, false),  // VRR 默认禁用
      latencyToast: await this.getBoolean(SettingsKeys.LATENCY_TOAST, false),
      disableWarnings: await this.getBoolean(SettingsKeys.DISABLE_WARNINGS, false),
      reduceRefreshRate: await this.getBoolean(SettingsKeys.REDUCE_REFRESH_RATE, false),
      enableStun: await this.getBoolean(SettingsKeys.ENABLE_STUN, false),
      enableEscMenu: await this.getBoolean(SettingsKeys.ENABLE_ESC_MENU, true),
      escMenuKey: await this.getString(SettingsKeys.ESC_MENU_KEY, 'ESC'),
      performanceMode: await this.getBoolean(SettingsKeys.PERFORMANCE_MODE, false)  // 性能模式默认禁用
    };
  }

  /**
   * 获取音频设置
   */
  async getAudioSettings(): Promise<AudioSettings> {
    return {
      audioConfig: await this.getString(SettingsKeys.AUDIO_CONFIG, '立体声'),
      enableLocalAudio: await this.getBoolean(SettingsKeys.ENABLE_LOCAL_AUDIO, false),
      enableSpatializer: await this.getBoolean(SettingsKeys.ENABLE_SPATIALIZER, false),
      controlOnly: await this.getBoolean(SettingsKeys.CONTROL_ONLY, false),
      enableMic: await this.getBoolean(SettingsKeys.ENABLE_MIC, false),
      micBitrate: await this.getNumber(SettingsKeys.MIC_BITRATE, 64)
    };
  }

  /**
   * 是否显示性能覆盖层
   */
  async shouldShowPerfOverlay(): Promise<boolean> {
    return await this.getBoolean(SettingsKeys.ENABLE_PERF_OVERLAY, false);
  }

  /**
   * 是否显示屏幕控制器
   */
  async shouldShowOnscreenControls(): Promise<boolean> {
    return await this.getBoolean(SettingsKeys.ENABLE_ONSCREEN_CONTROLS, false);
  }

  /**
   * 获取屏幕控制器透明度
   */
  async getOscOpacity(): Promise<number> {
    return await this.getNumber(SettingsKeys.OSC_OPACITY, 90);
  }

  /**
   * 是否恢复上次串流
   */
  async shouldResumeStream(): Promise<boolean> {
    return await this.getBoolean(SettingsKeys.RESUME_STREAM, false);
  }

  /**
   * 是否交换退出和断开按钮
   */
  async shouldSwapQuitAndDisconnect(): Promise<boolean> {
    return await this.getBoolean(SettingsKeys.SWAP_QUIT_AND_DISCONNECT, false);
  }
}
