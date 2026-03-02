/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { AbilityConstant, ApplicationStateChangeCallback, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { AppStateService } from '../service/AppStateService';

const TAG = 'EntryAbility';
const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private isDarkMode: boolean = false;
  private appStateCallback: ApplicationStateChangeCallback | null = null;
  
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    
    // 初始化 PreferencesUtil
    PreferencesUtil.init(this.context);

    // 将当前颜色模式写入 AppStorage，供全局 @StorageProp('colorMode') 使用
    AppStorage.setOrCreate('colorMode', this.context.config.colorMode);
    hilog.info(DOMAIN, TAG, 'AppStorage colorMode set to: %{public}d', this.context.config.colorMode);
    
    // 获取初始深色模式状态
    this.isDarkMode = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    hilog.info(DOMAIN, TAG, 'Initial color mode: %{public}s', this.isDarkMode ? 'dark' : 'light');
    
    // 注册应用前后台状态变化监听
    this.registerAppStateCallback();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
    
    // 取消应用状态监听
    this.unregisterAppStateCallback();
  }
  
  /**
   * 注册应用前后台状态变化监听
   */
  private registerAppStateCallback(): void {
    const applicationContext = this.context.getApplicationContext();
    this.appStateCallback = {
      onApplicationForeground: () => {
        hilog.info(DOMAIN, TAG, '%{public}s', 'Application onForeground');
        AppStateService.getInstance().onForeground();
      },
      onApplicationBackground: () => {
        hilog.info(DOMAIN, TAG, '%{public}s', 'Application onBackground');
        AppStateService.getInstance().onBackground();
      }
    };
    try {
      applicationContext.on('applicationStateChange', this.appStateCallback);
      hilog.info(DOMAIN, TAG, '%{public}s', 'App state callback registered');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to register app state callback: %{public}s', String(err));
    }
  }
  
  /**
   * 取消应用状态监听
   */
  private unregisterAppStateCallback(): void {
    if (this.appStateCallback) {
      try {
        const applicationContext = this.context.getApplicationContext();
        applicationContext.off('applicationStateChange', this.appStateCallback);
        hilog.info(DOMAIN, TAG, '%{public}s', 'App state callback unregistered');
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'Failed to unregister app state callback: %{public}s', String(err));
      }
      this.appStateCallback = null;
    }
  }
  
  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(DOMAIN, TAG, 'Configuration updated: %{public}s', JSON.stringify(newConfig));
    
    // 检测深色模式变化
    const newIsDarkMode = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    // 同步到 AppStorage，触发所有 @StorageProp('colorMode') 更新
    AppStorage.setOrCreate('colorMode', newConfig.colorMode);
    if (this.isDarkMode !== newIsDarkMode) {
      this.isDarkMode = newIsDarkMode;
      hilog.info(DOMAIN, TAG, 'Color mode changed to: %{public}s', this.isDarkMode ? 'dark' : 'light');
      
      // 更新状态栏颜色
      this.updateSystemBarColors();
    }
  }
  
  private updateSystemBarColors(): void {
    // 获取主窗口并更新状态栏颜色
    const windowStage = this.context.windowStage;
    if (windowStage) {
      windowStage.getMainWindow().then((win) => {
        const statusBarContentColor = this.isDarkMode ? '#F5F0EB' : '#1A3A4A';
        const barProperties: window.SystemBarProperties = {
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: statusBarContentColor,
          navigationBarContentColor: statusBarContentColor
        };
        try {
          win.setWindowSystemBarProperties(barProperties);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'Failed to set system bar properties: %{public}s', String(e));
        }
      });
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    // 加载主页面
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading content.');
    });

    // 设置窗口属性
    windowStage.getMainWindow().then((win) => {
      // 设置全屏布局（内容延伸到系统栏区域）
      win.setWindowLayoutFullScreen(true);

      // 动态获取系统避让区域高度，供所有页面使用
      // 2in1 设备有窗口装饰栏时，状态栏高度可能为 0，避免硬编码浪费空间
      // 但保留最小间距 16vp，确保 2in1 设备上内容不紧贴装饰栏
      const MIN_TOP_SAFE_HEIGHT = 16;
      try {
        const avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const displayInfo = display.getDefaultDisplaySync();
        const density = displayInfo.densityPixels;
        // 将像素转换为 vp，并保证最小值
        const topSafeHeight = Math.max(avoidArea.topRect.height / density, MIN_TOP_SAFE_HEIGHT);
        const bottomSafeHeight = avoidArea.bottomRect.height / density;
        AppStorage.setOrCreate('topSafeHeight', topSafeHeight);
        AppStorage.setOrCreate('bottomSafeHeight', bottomSafeHeight);
        hilog.info(DOMAIN, TAG, 'Safe area: top=%{public}d vp, bottom=%{public}d vp', topSafeHeight, bottomSafeHeight);

        // 监听避让区域变化（窗口模式切换、装饰栏显隐时动态更新）
        win.on('avoidAreaChange', (data) => {
          if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
            const newTopHeight = Math.max(data.area.topRect.height / density, MIN_TOP_SAFE_HEIGHT);
            const newBottomHeight = data.area.bottomRect.height / density;
            AppStorage.setOrCreate('topSafeHeight', newTopHeight);
            AppStorage.setOrCreate('bottomSafeHeight', newBottomHeight);
            hilog.info(DOMAIN, TAG, 'Safe area updated: top=%{public}d vp, bottom=%{public}d vp',
              newTopHeight, newBottomHeight);
          }
        });
      } catch (e) {
        // 获取失败时使用默认值 56（适用于手机）
        AppStorage.setOrCreate('topSafeHeight', 56);
        AppStorage.setOrCreate('bottomSafeHeight', 0);
        hilog.warn(DOMAIN, TAG, 'Failed to get avoid area, using default: %{public}s', String(e));
      }

      // 主界面保留窗口装饰栏（2in1/平板设备可拖拽、缩放、最小化），串流时再隐藏
      // 隐藏底部导航指示器（白色横线），避免遮挡沉浸式 UI
      try {
        win.setSpecificSystemBarEnabled('navigationIndicator', false);
      } catch (e) {
        hilog.info(DOMAIN, TAG, 'setSpecificSystemBarEnabled(navigationIndicator) not available');
      }
      // 根据当前深色模式设置状态栏和导航栏颜色
      const contentColor = this.isDarkMode ? '#F5F0EB' : '#1A3A4A';
      const barProperties: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      };
      try {
        win.setWindowSystemBarProperties(barProperties);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'Failed to set system bar properties: %{public}s', String(e));
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
