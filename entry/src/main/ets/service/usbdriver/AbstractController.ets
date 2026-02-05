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
 * USB 控制器抽象基类
 * 
 * 参考 Android moonlight-android AbstractController
 */

import { UsbDriverListener } from './UsbDriverListener';
import { ControllerType, ControllerCapabilities, ButtonFlags } from './ControllerConstants';

/**
 * 所有 USB 控制器的抽象基类
 */
export abstract class AbstractController {
  protected deviceId: number;
  protected vendorId: number;
  protected productId: number;
  protected listener: UsbDriverListener;
  protected deviceName: string = 'Unknown Controller';
  
  // 设备唯一标识（用于区分同型号多个设备）
  protected busNum: number = 0;
  protected devAddress: number = 0;
  protected serial: string = '';
  
  // 配置选项
  protected ignoreDisconnect: boolean = false;  // 忽略断开信号
  
  // 输入状态
  protected buttonFlags: number = 0;
  protected supportedButtonFlags: number = 0;
  protected leftTrigger: number = 0;
  protected rightTrigger: number = 0;
  protected leftStickX: number = 0;
  protected leftStickY: number = 0;
  protected rightStickX: number = 0;
  protected rightStickY: number = 0;
  
  // 控制器属性
  protected capabilities: number = 0;
  protected type: number = ControllerType.UNKNOWN;
  
  constructor(deviceId: number, listener: UsbDriverListener, vendorId: number, productId: number) {
    this.deviceId = deviceId;
    this.listener = listener;
    this.vendorId = vendorId;
    this.productId = productId;
  }
  
  /**
   * 设置设备物理位置信息（用于唯一标识）
   */
  setDeviceLocation(busNum: number, devAddress: number, serial: string): void {
    this.busNum = busNum;
    this.devAddress = devAddress;
    this.serial = serial;
  }
  
  /**
   * 设置是否忽略断开信号
   * @param ignore true 表示忽略断开信号
   */
  setIgnoreDisconnect(ignore: boolean): void {
    this.ignoreDisconnect = ignore;
  }
  
  /**
   * 获取是否忽略断开信号
   */
  getIgnoreDisconnect(): boolean {
    return this.ignoreDisconnect;
  }
  
  /**
   * 获取设备唯一标识 Key
   * 使用 VID:PID:busNum:devAddress 组合，确保唯一性
   */
  getDeviceKey(): string {
    return `${this.vendorId}:${this.productId}:${this.busNum}:${this.devAddress}`;
  }
  
  /**
   * 获取控制器名称
   */
  getName(): string {
    return this.deviceName;
  }
  
  /**
   * 获取设备 ID
   */
  getDeviceId(): number {
    return this.deviceId;
  }
  
  /**
   * 获取控制器 ID (别名)
   */
  getControllerId(): number {
    return this.deviceId;
  }
  
  /**
   * 获取厂商 ID
   */
  getVendorId(): number {
    return this.vendorId;
  }
  
  /**
   * 获取产品 ID
   */
  getProductId(): number {
    return this.productId;
  }
  
  /**
   * 获取支持的按钮标志
   */
  getSupportedButtonFlags(): number {
    return this.supportedButtonFlags;
  }
  
  /**
   * 获取控制器能力
   */
  getCapabilities(): number {
    return this.capabilities;
  }
  
  /**
   * 获取控制器类型
   */
  getType(): number {
    return this.type;
  }
  
  /**
   * 获取控制器类型 (别名)
   */
  getControllerType(): number {
    return this.type;
  }
  
  /**
   * 设置按钮状态标志
   * @param buttonFlag 按钮标志位
   * @param data 如果非零则设置，否则清除
   */
  protected setButtonFlag(buttonFlag: number, data: number): void {
    if (data !== 0) {
      this.buttonFlags |= buttonFlag;
    } else {
      this.buttonFlags &= ~buttonFlag;
    }
  }
  
  /**
   * 报告输入状态给监听器
   */
  protected reportInput(): void {
    if (this.listener) {
      this.listener.reportControllerState(
        this.deviceId,
        this.buttonFlags,
        this.leftStickX,
        this.leftStickY,
        this.rightStickX,
        this.rightStickY,
        this.leftTrigger,
        this.rightTrigger
      );
    }
  }
  
  /**
   * 通知设备已移除
   */
  protected notifyDeviceRemoved(): void {
    if (this.listener) {
      this.listener.deviceRemoved(this);
    }
  }
  
  /**
   * 通知设备已添加
   */
  protected notifyDeviceAdded(): void {
    if (this.listener) {
      this.listener.deviceAdded(this);
    }
  }
  
  /**
   * 报告运动数据
   */
  protected notifyControllerMotion(motionType: number, x: number, y: number, z: number): void {
    if (this.listener) {
      this.listener.reportControllerMotion(this.deviceId, motionType, x, y, z);
    }
  }
  
  /**
   * 启动控制器
   * @returns 是否启动成功
   */
  abstract start(): boolean;
  
  /**
   * 停止控制器
   */
  abstract stop(): void;
  
  /**
   * 检查控制器是否已连接
   * @returns 是否已连接
   */
  abstract isConnected(): boolean;
  
  /**
   * 获取最后活动时间戳
   * 用于检测静默断开
   * @returns 最后活动的时间戳（毫秒），未实现的返回 0
   */
  getLastActivityTime(): number {
    return 0;  // 默认实现，子类可覆盖
  }
  
  /**
   * 检查控制器是否可能已静默断开
   * @param inactivityThresholdMs 不活动阈值（毫秒），默认 30 秒
   * @returns true 表示可能已断开
   */
  mayBeSilentlyDisconnected(inactivityThresholdMs: number = 30000): boolean {
    // 默认实现：如果没有实现活动时间跟踪，返回 false
    return false;
  }
  
  /**
   * 震动反馈
   * @param lowFreqMotor 低频马达强度 (0-65535)
   * @param highFreqMotor 高频马达强度 (0-65535)
   */
  abstract rumble(lowFreqMotor: number, highFreqMotor: number): void;
  
  /**
   * 扳机震动反馈
   * @param leftTrigger 左扳机震动强度 (0-65535)
   * @param rightTrigger 右扳机震动强度 (0-65535)
   */
  abstract rumbleTriggers(leftTrigger: number, rightTrigger: number): void;
}
