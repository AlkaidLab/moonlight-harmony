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
  
  constructor(context: common.UIAbilityContext) {
    this.context = context;
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
  
  /**
   * 配置窗口（全屏、保持常亮）
   */
  async configureWindow(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      // 保持屏幕常亮
      win.setWindowKeepScreenOn(true);
      // 隐藏状态栏和导航栏
      win.setWindowSystemBarEnable([]);
      console.info('StreamWindowManager: 已配置窗口基本设置');
    } catch (err) {
      console.error('配置窗口失败:', err);
    }
  }
  
  /**
   * 根据串流分辨率设置屏幕方向
   */
  async configureOrientation(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      
      if (this.streamWidth > this.streamHeight) {
        // 横屏分辨率 → 横屏模式
        await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
        console.info(`StreamWindowManager: 设置横屏模式 (${this.streamWidth}x${this.streamHeight})`);
      } else if (this.streamHeight > this.streamWidth) {
        // 竖屏分辨率 → 竖屏模式
        await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_PORTRAIT);
        console.info(`StreamWindowManager: 设置竖屏模式 (${this.streamWidth}x${this.streamHeight})`);
      } else {
        // 正方形分辨率 → 自动旋转
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
      // 短暂延迟，确保系统完成旋转
      await new Promise<void>((resolve) => setTimeout(resolve, 100));
      
      const displayInfo = display.getDefaultDisplaySync();
      
      // 根据当前串流方向确定正确的宽高
      if (this.streamWidth > this.streamHeight) {
        // 横屏模式：宽 > 高
        this.screenWidth = Math.max(displayInfo.width, displayInfo.height) / displayInfo.densityPixels;
        this.screenHeight = Math.min(displayInfo.width, displayInfo.height) / displayInfo.densityPixels;
      } else {
        // 竖屏模式：高 > 宽
        this.screenWidth = Math.min(displayInfo.width, displayInfo.height) / displayInfo.densityPixels;
        this.screenHeight = Math.max(displayInfo.width, displayInfo.height) / displayInfo.densityPixels;
      }
      
      console.info(`StreamWindowManager: 更新屏幕尺寸 ${this.screenWidth}x${this.screenHeight}`);
    } catch (err) {
      console.error('更新屏幕尺寸失败:', err);
    }
    
    return this.getScreenSize();
  }
  
  /**
   * 恢复窗口设置
   */
  async restoreWindow(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      // 恢复屏幕常亮设置
      win.setWindowKeepScreenOn(false);
      // 恢复系统栏
      win.setWindowSystemBarEnable(['status', 'navigation']);
      // 恢复自动旋转
      await win.setPreferredOrientation(window.Orientation.UNSPECIFIED);
      console.info('StreamWindowManager: 已恢复窗口设置');
    } catch (err) {
      console.error('恢复窗口设置失败:', err);
    }
  }
  
  /**
   * 计算 XComponent 尺寸以保持视频宽高比
   * 
   * @param stretchVideo 是否拉伸视频填满全屏
   * @returns XComponent 尺寸
   */
  calculateXComponentSize(stretchVideo: boolean = false): XComponentSize {
    if (stretchVideo) {
      return {
        width: '100%',
        height: '100%'
      };
    }
    
    try {
      const displayInfo = display.getDefaultDisplaySync();
      const screenWidth = displayInfo.width;
      const screenHeight = displayInfo.height;
      const videoAspectRatio = this.streamWidth / this.streamHeight;
      const screenAspectRatio = screenWidth / screenHeight;
      
      let measuredWidth: number;
      let measuredHeight: number;
      
      if (screenAspectRatio > videoAspectRatio) {
        // 屏幕更宽，以高度为基准，添加左右黑边（pillarbox）
        measuredHeight = screenHeight;
        measuredWidth = Math.floor(measuredHeight * videoAspectRatio);
      } else {
        // 屏幕更高，以宽度为基准，添加上下黑边（letterbox）
        measuredWidth = screenWidth;
        measuredHeight = Math.floor(measuredWidth / videoAspectRatio);
      }
      
      // 转换为 vp 单位
      const density = displayInfo.densityPixels;
      const widthVp = measuredWidth / density;
      const heightVp = measuredHeight / density;
      
      console.info(`StreamWindowManager: 视频尺寸计算 - 屏幕=${screenWidth}x${screenHeight}, 视频=${this.streamWidth}x${this.streamHeight}, XComponent=${widthVp}x${heightVp}vp`);
      
      return {
        width: widthVp,
        height: heightVp
      };
    } catch (err) {
      console.error('计算视频尺寸失败:', err);
      return {
        width: '100%',
        height: '100%'
      };
    }
  }
  
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
