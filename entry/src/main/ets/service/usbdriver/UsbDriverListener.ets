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
 * USB 驱动监听器接口
 * 
 * 参考 Android moonlight-android UsbDriverListener
 */

import { AbstractController } from './AbstractController';

/**
 * 控制器状态回调接口
 */
export interface UsbDriverListener {
  /**
   * 报告控制器输入状态
   * @param controllerId 控制器 ID
   * @param buttonFlags 按钮状态位标志
   * @param leftStickX 左摇杆 X 轴 (-1.0 到 1.0)
   * @param leftStickY 左摇杆 Y 轴 (-1.0 到 1.0)
   * @param rightStickX 右摇杆 X 轴 (-1.0 到 1.0)
   * @param rightStickY 右摇杆 Y 轴 (-1.0 到 1.0)
   * @param leftTrigger 左扳机 (0.0 到 1.0)
   * @param rightTrigger 右扳机 (0.0 到 1.0)
   */
  reportControllerState(
    controllerId: number,
    buttonFlags: number,
    leftStickX: number,
    leftStickY: number,
    rightStickX: number,
    rightStickY: number,
    leftTrigger: number,
    rightTrigger: number
  ): void;

  /**
   * 报告控制器运动数据（陀螺仪/加速度计）
   * @param controllerId 控制器 ID
   * @param motionType 运动类型
   * @param x X 轴数据
   * @param y Y 轴数据
   * @param z Z 轴数据
   */
  reportControllerMotion(
    controllerId: number,
    motionType: number,
    x: number,
    y: number,
    z: number
  ): void;

  /**
   * 设备移除回调
   * @param controller 被移除的控制器
   */
  deviceRemoved(controller: AbstractController): void;

  /**
   * 设备添加回调
   * @param controller 新添加的控制器
   */
  deviceAdded(controller: AbstractController): void;
}

/**
 * USB 驱动状态监听器接口
 */
export interface UsbDriverStateListener {
  /**
   * USB 权限请求对话框即将显示
   */
  onUsbPermissionPromptStarting(): void;

  /**
   * USB 权限请求对话框已关闭
   */
  onUsbPermissionPromptCompleted(): void;
}
