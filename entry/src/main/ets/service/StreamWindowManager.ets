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
 * 串流窗口管理器
 * 
 * 管理串流页面的窗口配置、屏幕方向和视频尺寸计算
 */
import { window, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

/**
 * 显示尺寸信息
 */
export interface DisplaySize {
  width: number;
  height: number;
}

/**
 * XComponent 尺寸
 */
export interface XComponentSize {
  width: Length;
  height: Length;
}

/**
 * StreamWindowManager - 串流窗口管理器
 */
export class StreamWindowManager {
  private context: common.UIAbilityContext;
  private streamWidth: number = 1920;
  private streamHeight: number = 1080;
  private screenWidth: number = 1920;
  private screenHeight: number = 1080;
  /** 当前是否处于全屏沉浸模式（串流开始时默认进入全屏） */
  private _isFullscreen: boolean = true;
  /** 窗口大小变化回调（窗口模式拖拽缩放时触发） */
  private onWindowSizeChanged: (() => void) | null = null;
  /** windowSizeChange 监听器回调引用（用于 off 取消注册） */
  private windowSizeChangeHandler: ((size: window.Size) => void) | null = null;

  /** 查询当前是否全屏 */
  get isFullscreen(): boolean {
    return this._isFullscreen;
  }
  
  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /**
   * 设置窗口大小变化回调（窗口模式下用户拖拽缩放时触发 XComponent 重算）
   */
  setOnWindowSizeChanged(callback: (() => void) | null): void {
    this.onWindowSizeChanged = callback;
  }
  
  /**
   * 设置串流分辨率
   */
  setStreamResolution(width: number, height: number): void {
    this.streamWidth = width;
    this.streamHeight = height;
  }
  
  /**
   * 获取屏幕尺寸
   */
  getScreenSize(): DisplaySize {
    return {
      width: this.screenWidth,
      height: this.screenHeight
    };
  }
  
  /**
   * 初始化屏幕尺寸
   */
  async initScreenSize(): Promise<DisplaySize> {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      this.screenWidth = displayInfo.width / displayInfo.densityPixels;
      this.screenHeight = displayInfo.height / displayInfo.densityPixels;
      
      console.info(`StreamWindowManager: 屏幕尺寸 ${this.screenWidth}x${this.screenHeight}`);
    } catch (err) {
      console.error('获取屏幕尺寸失败:', err);
    }
    
    return this.getScreenSize();
  }

  // ==================== 窗口配置核心方法 ====================
  
  /**
   * 配置窗口进入串流模式（全屏+常亮+沉浸式）
   */
  async configureWindow(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      win.setWindowKeepScreenOn(true);
      await this.enterImmersiveFullscreen(win);

      // 横屏多窗支持
      if (this.streamWidth > this.streamHeight) {
        try { await win.enableLandscapeMultiWindow(); } catch (_e) {}
      }

      this._isFullscreen = true;
      console.info('StreamWindowManager: 已配置窗口基本设置（全屏+沉浸式+装饰栏隐藏）');
    } catch (err) {
      console.error('配置窗口失败:', err);
    }
  }
  
  /**
   * 恢复窗口设置（串流结束时调用）
   */
  async restoreWindow(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      this.unregisterWindowSizeListener(win);
      win.setWindowKeepScreenOn(false);
      await this.exitImmersiveFullscreen(win);

      // 恢复全屏布局：重新显示系统栏后系统可能收回了全屏布局，
      // 导致内容区缩进出现黑边，此处再次设为 true 使内容延伸到系统栏下
      try { await win.setWindowLayoutFullScreen(true); } catch (_e) {}

      // 退出横屏多窗模式
      try { await win.disableLandscapeMultiWindow(); } catch (_e) {}
      await win.setPreferredOrientation(window.Orientation.UNSPECIFIED);
      win.setWindowBrightness(-1);

      this._isFullscreen = false;
      console.info('StreamWindowManager: 已恢复窗口设置');
    } catch (err) {
      console.error('恢复窗口设置失败:', err);
    }
  }

  /**
   * 切换窗口/全屏模式（2in1 设备）
   *
   * 全屏 → 窗口化：退出沉浸式 + recover() 恢复悬浮窗
   * 窗口化 → 全屏：隐藏装饰栏 + 沉浸式最大化
   */
  async toggleWindowMode(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);

      if (this._isFullscreen) {
        await this.exitImmersiveFullscreen(win);
        try {
          await win.recover();
        } catch (_e) {
          console.info('StreamWindowManager: recover() 不可用，保持最大化');
        }
        this._isFullscreen = false;
        // 注册窗口大小变化监听（窗口模式下用户可能拖拽缩放）
        this.registerWindowSizeListener(win);
        console.info('StreamWindowManager: 已切换到窗口模式');
      } else {
        // 取消窗口大小变化监听
        this.unregisterWindowSizeListener(win);
        await this.enterImmersiveFullscreen(win);
        this._isFullscreen = true;
        console.info('StreamWindowManager: 已切换到全屏模式');
      }
    } catch (err) {
      console.error('StreamWindowManager: 窗口模式切换失败:', err);
    }
  }

  /**
   * 注册窗口大小变化监听器
   */
  private registerWindowSizeListener(win: window.Window): void {
    this.unregisterWindowSizeListener(win);
    let debounceTimer: number = -1;
    this.windowSizeChangeHandler = (_size: window.Size) => {
      // 防抖：拖拽缩放时高频触发，200ms 后才真正回调
      if (debounceTimer !== -1) {
        clearTimeout(debounceTimer);
      }
      debounceTimer = Number(setTimeout(() => {
        debounceTimer = -1;
        this.onWindowSizeChanged?.();
      }, 200));
    };
    try {
      win.on('windowSizeChange', this.windowSizeChangeHandler);
    } catch (_e) {}
  }

  /**
   * 取消窗口大小变化监听器
   */
  private unregisterWindowSizeListener(win: window.Window): void {
    if (this.windowSizeChangeHandler) {
      try {
        win.off('windowSizeChange', this.windowSizeChangeHandler);
      } catch (_e) {}
      this.windowSizeChangeHandler = null;
    }
  }

  // ==================== 沉浸式全屏辅助方法 ====================

  /**
   * 进入沉浸式全屏：隐藏装饰栏 → 最大化(禁用Dock悬停) → 全屏布局 → 隐藏系统栏 → 沉浸式
   */
  private async enterImmersiveFullscreen(win: window.Window): Promise<void> {
    // 1. 隐藏装饰栏（必须在 maximize 之前，避免闪现）
    this.setDecorVisible(win, false);

    // 2. 最大化 + 沉浸式 + 禁用 Dock 悬停（3 级回退）
    await this.maximizeImmersive(win);

    // 3. 全屏布局（内容延伸到系统栏区域）
    try { await win.setWindowLayoutFullScreen(true); } catch (_e) {}

    // 4. 隐藏系统栏
    await this.setSystemBarsVisible(win, false);

    // 5. 沉浸式模式：抑制系统导航手势 (API 12+)
    try { win.setImmersiveModeEnabledState(true); } catch (_e) {}
  }

  /**
   * 退出沉浸式全屏：退出沉浸式 → 显示系统栏 → 显示装饰栏 → 退出沉浸式最大化
   */
  private async exitImmersiveFullscreen(win: window.Window): Promise<void> {
    // 1. 退出沉浸式模式
    try { win.setImmersiveModeEnabledState(false); } catch (_e) {}

    // 2. 显示系统栏（不恢复 navigationIndicator，避免白色不透明样式）
    await this.setSystemBarsVisible(win, true);

    // 3. 显示装饰栏
    this.setDecorVisible(win, true);

    // 4. 退出沉浸式最大化
    try {
      await win.maximize(window.MaximizePresentation.EXIT_IMMERSIVE);
    } catch (_e) {
      try { win.setTitleAndDockHoverShown(true); } catch (_e2) {}
    }
  }

  /**
   * 最大化窗口并进入沉浸式，禁用标题栏和 Dock 悬停（3 级回退链）
   *
   * 优先级：
   * 1. ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER (API 14+) — 彻底禁用 Dock 悬停
   * 2. ENTER_IMMERSIVE (API 12+) + setTitleAndDockHoverShown(false)
   * 3. maximize() + setTitleAndDockHoverShown(false)
   */
  private async maximizeImmersive(win: window.Window): Promise<void> {
    try {
      await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER);
    } catch (_e) {
      try {
        await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
      } catch (_e2) {
        try { await win.maximize(); } catch (_e3) {}
      }
      try { win.setTitleAndDockHoverShown(false); } catch (_e2) {}
    }
  }

  /**
   * 设置系统栏（状态栏 + 导航栏）可见性
   */
  private async setSystemBarsVisible(win: window.Window, visible: boolean): Promise<void> {
    try {
      await win.setSpecificSystemBarEnabled('status', visible);
      await win.setSpecificSystemBarEnabled('navigation', visible);
      if (!visible) {
        await win.setSpecificSystemBarEnabled('navigationIndicator', false);
      }
    } catch (_e) {
      try {
        win.setWindowSystemBarEnable(visible ? ['status', 'navigation'] : []);
      } catch (_e2) {}
    }
  }

  /**
   * 设置窗口装饰栏（标题栏：放大/缩小/关闭按钮）可见性
   */
  private setDecorVisible(win: window.Window, visible: boolean): void {
    try { win.setWindowDecorVisible(visible); } catch (_e) {}
  }

  // ==================== 屏幕方向 ====================

  /**
   * 根据串流分辨率设置屏幕方向
   */
  async configureOrientation(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);

      if (this.streamWidth > this.streamHeight) {
        await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
        console.info(`StreamWindowManager: 设置横屏模式 (${this.streamWidth}x${this.streamHeight})`);
      } else if (this.streamHeight > this.streamWidth) {
        await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_PORTRAIT);
        console.info(`StreamWindowManager: 设置竖屏模式 (${this.streamWidth}x${this.streamHeight})`);
      } else {
        await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
        console.info(`StreamWindowManager: 设置自动旋转模式 (${this.streamWidth}x${this.streamHeight})`);
      }
    } catch (err) {
      console.error('设置屏幕方向失败:', err);
    }
  }

  /**
   * 更新屏幕尺寸（在屏幕旋转后调用）
   */
  async updateScreenSize(): Promise<DisplaySize> {
    try {
      await new Promise<void>((resolve) => setTimeout(resolve, 100));
      const displayInfo = display.getDefaultDisplaySync();

      if (this.streamWidth > this.streamHeight) {
        this.screenWidth = Math.max(displayInfo.width, displayInfo.height) / displayInfo.densityPixels;
        this.screenHeight = Math.min(displayInfo.width, displayInfo.height) / displayInfo.densityPixels;
      } else {
        this.screenWidth = Math.min(displayInfo.width, displayInfo.height) / displayInfo.densityPixels;
        this.screenHeight = Math.max(displayInfo.width, displayInfo.height) / displayInfo.densityPixels;
      }

      console.info(`StreamWindowManager: 更新屏幕尺寸 ${this.screenWidth}x${this.screenHeight}`);
    } catch (err) {
      console.error('更新屏幕尺寸失败:', err);
    }
    return this.getScreenSize();
  }

  // ==================== 显示设置 ====================

  /**
   * 设置 HDR 高亮度模式
   * 当 HDR 开启且用户启用高亮度选项时，将屏幕亮度调至最大
   *
   * @param enableHdr 是否启用 HDR
   * @param hdrHighBrightness 是否启用 HDR 高亮度模式
   */
  async setHdrBrightness(enableHdr: boolean, hdrHighBrightness: boolean): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      if (enableHdr && hdrHighBrightness) {
        // HDR 高亮度模式：将屏幕亮度调至最大 (1.0)
        win.setWindowBrightness(1.0);
        console.info('StreamWindowManager: HDR 高亮度模式已启用 (brightness=1.0)');
      } else {
        // 使用系统默认亮度 (-1)
        win.setWindowBrightness(-1);
        console.info('StreamWindowManager: 使用系统默认屏幕亮度');
      }
    } catch (err) {
      console.warn('StreamWindowManager: 设置 HDR 亮度失败:', JSON.stringify(err));
    }
  }
  
  // ==================== 视频尺寸计算 ====================

  /**
   * 计算 XComponent 尺寸以保持视频宽高比（全屏模式下使用屏幕尺寸计算 letterbox/pillarbox）
   *
   * 窗口模式下应直接使用 '100%' 填满窗口，无需调用此方法。
   *
   * @param stretchVideo 是否拉伸视频填满全屏
   * @returns XComponent 尺寸
   */
  calculateXComponentSize(stretchVideo: boolean = false): XComponentSize {
    if (stretchVideo) {
      return { width: '100%', height: '100%' };
    }

    try {
      const displayInfo = display.getDefaultDisplaySync();
      const screenWidth = displayInfo.width;
      const screenHeight = displayInfo.height;
      const density = displayInfo.densityPixels;
      const videoAspectRatio = this.streamWidth / this.streamHeight;
      const screenAspectRatio = screenWidth / screenHeight;

      let measuredWidth: number;
      let measuredHeight: number;

      if (screenAspectRatio > videoAspectRatio) {
        measuredHeight = screenHeight;
        measuredWidth = Math.floor(measuredHeight * videoAspectRatio);
      } else {
        measuredWidth = screenWidth;
        measuredHeight = Math.floor(measuredWidth / videoAspectRatio);
      }

      const widthVp = measuredWidth / density;
      const heightVp = measuredHeight / density;

      console.info(`StreamWindowManager: 视频尺寸计算 - 屏幕=${screenWidth}x${screenHeight}px, ` +
        `视频=${this.streamWidth}x${this.streamHeight}, XComponent=${widthVp.toFixed(1)}x${heightVp.toFixed(1)}vp`);

      return { width: widthVp, height: heightVp };
    } catch (err) {
      console.error('计算视频尺寸失败:', err);
      return { width: '100%', height: '100%' };
    }
  }

  // ==================== 初始化 ====================

  /**
   * 完整的窗口初始化流程
   * 
   * @returns 屏幕尺寸
   */
  async initialize(): Promise<DisplaySize> {
    await this.initScreenSize();
    await this.configureWindow();
    await this.configureOrientation();
    const size = await this.updateScreenSize();
    return size;
  }
}
