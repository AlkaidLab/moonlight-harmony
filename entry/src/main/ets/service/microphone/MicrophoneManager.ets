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
 * 麦克风管理器
 * 负责管理麦克风的权限、状态和生命周期
 */
import { common, abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import { MoonBridge, MoonBridgeClass } from '../MoonBridge';
import { MicrophoneConfig, MicrophoneState, MicrophoneStateListener } from './MicrophoneConfig';
import { MicrophoneStream } from './MicrophoneStream';

const TAG = '[MicManager]';

/**
 * 麦克风管理器
 * 提供麦克风功能的高层封装
 */
export class MicrophoneManager implements MicrophoneStateListener {
  private context: common.UIAbilityContext;
  private moonBridge: MoonBridgeClass;
  private microphoneStream: MicrophoneStream | null = null;
  private enableMic: boolean = false;
  
  // 状态
  private state: MicrophoneState = MicrophoneState.STOPPED;
  private hasPermission: boolean = false;
  
  // 外部监听器
  private externalListener: MicrophoneStateListener | null = null;
  
  constructor(context: common.UIAbilityContext, moonBridge: MoonBridgeClass, enableMic: boolean) {
    this.context = context;
    this.moonBridge = moonBridge;
    this.enableMic = enableMic;
    console.info(TAG, `初始化麦克风管理器, enableMic=${enableMic}`);
  }
  
  /**
   * 设置状态监听器
   */
  setStateListener(listener: MicrophoneStateListener): void {
    this.externalListener = listener;
  }
  
  /**
   * MicrophoneStateListener 实现
   */
  onMicrophoneStateChanged(state: MicrophoneState): void {
    this.state = state;
    if (this.externalListener) {
      this.externalListener.onMicrophoneStateChanged(state);
    }
  }
  
  onMicrophoneError(error: string): void {
    this.state = MicrophoneState.ERROR;
    if (this.externalListener) {
      this.externalListener.onMicrophoneError(error);
    }
  }
  
  /**
   * 获取当前状态
   */
  getState(): MicrophoneState {
    return this.state;
  }
  
  /**
   * 检查是否有麦克风权限
   */
  async hasMicrophonePermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const bundleInfo = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId = bundleInfo.appInfo.accessTokenId;
      
      const permission: Permissions = 'ohos.permission.MICROPHONE';
      const grantStatus = atManager.checkAccessTokenSync(tokenId, permission);
      
      this.hasPermission = grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      return this.hasPermission;
    } catch (error) {
      console.error(TAG, `检查麦克风权限失败: ${error}`);
      return false;
    }
  }
  
  /**
   * 请求麦克风权限
   */
  async requestMicrophonePermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const permission: Permissions = 'ohos.permission.MICROPHONE';
      
      const result = await atManager.requestPermissionsFromUser(this.context, [permission]);
      
      if (result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        this.hasPermission = true;
        console.info(TAG, '麦克风权限已授予');
        return true;
      } else {
        console.warn(TAG, '麦克风权限被拒绝');
        return false;
      }
    } catch (error) {
      console.error(TAG, `请求麦克风权限失败: ${error}`);
      return false;
    }
  }
  
  /**
   * 初始化麦克风流
   */
  async initializeMicrophoneStream(): Promise<boolean> {
    if (!this.enableMic) {
      console.info(TAG, '麦克风功能已禁用');
      return false;
    }
    
    if (this.microphoneStream !== null) {
      console.info(TAG, '麦克风流已存在');
      return true;
    }
    
    // 检查权限
    if (!await this.hasMicrophonePermission()) {
      console.warn(TAG, '需要麦克风权限');
      // 尝试请求权限
      if (!await this.requestMicrophonePermission()) {
        return false;
      }
    }
    
    try {
      // 更新比特率配置
      const settingsService = (await import('../SettingsService')).SettingsService.getInstance();
      const audioSettings = await settingsService.getAudioSettings();
      MicrophoneConfig.setOpusBitrate(audioSettings.micBitrate);

      // 创建麦克风流
      this.microphoneStream = new MicrophoneStream(this.moonBridge);
      this.microphoneStream.setStateListener(this);

      // 检查主机是否支持麦克风
      if (!this.microphoneStream.isMicrophoneAvailable()) {
        console.info(TAG, '主机不支持麦克风功能');
        return true; // 初始化成功，但主机不支持
      }

      // 延迟启动模式：只创建流对象，不启动捕获
      // 用户需要主动调用 startMicrophone() 来启动
      console.info(TAG, '麦克风流已初始化，等待用户启动');

      return true;

    } catch (error) {
      console.error(TAG, `初始化麦克风流失败: ${error}`);
      this.onMicrophoneError(`初始化失败: ${error}`);
      return false;
    }
  }
  
  /**
   * 检查主机是否支持麦克风
   */
  isMicrophoneAvailable(): boolean {
    return this.microphoneStream?.isMicrophoneAvailable() || false;
  }
  
  /**
   * 麦克风是否活跃
   */
  isMicrophoneActive(): boolean {
    return this.microphoneStream?.isRunning() || false;
  }
  
  /**
   * 切换麦克风状态
   */
  async toggleMicrophone(): Promise<boolean> {
    if (!this.microphoneStream) {
      // 尝试初始化
      if (!await this.initializeMicrophoneStream()) {
        return false;
      }
    }
    
    if (this.microphoneStream) {
      return this.microphoneStream.toggle();
    }
    
    return false;
  }
  
  /**
   * 启动麦克风
   */
  async startMicrophone(): Promise<boolean> {
    if (!this.microphoneStream) {
      if (!await this.initializeMicrophoneStream()) {
        return false;
      }
    }
    
    if (this.microphoneStream) {
      await this.microphoneStream.resume();
      return true;
    }
    
    return false;
  }
  
  /**
   * 停止麦克风
   */
  async stopMicrophone(): Promise<void> {
    if (this.microphoneStream) {
      await this.microphoneStream.pause();
    }
  }
  
  /**
   * 清理资源
   */
  async cleanup(): Promise<void> {
    if (this.microphoneStream) {
      await this.microphoneStream.stop();
      this.microphoneStream = null;
    }
    
    this.state = MicrophoneState.STOPPED;
    console.info(TAG, '麦克风管理器已清理');
  }
}
