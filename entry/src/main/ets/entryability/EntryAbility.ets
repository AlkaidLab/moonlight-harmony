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
import { window } from '@kit.ArkUI';
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
      // 设置全屏显示
      win.setWindowLayoutFullScreen(true);
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
