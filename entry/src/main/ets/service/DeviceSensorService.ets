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
 * DeviceSensorService - 设备传感器服务
 * 
 * 提供设备内置陀螺仪和加速度计的管理
 * 当手柄没有内置传感器时，回退使用设备传感器模拟手柄运动数据
 * 
 * 参照 Android ControllerHandler 的设备传感器回退机制
 */

import { sensor } from '@kit.SensorServiceKit';
import { display } from '@kit.ArkUI';

// =============================================================================
// 常量定义
// =============================================================================

/** 运动类型（与 moonlight-common-c LI_MOTION_TYPE_* 一致） */
export const LI_MOTION_TYPE_ACCEL = 0x01;
export const LI_MOTION_TYPE_GYRO = 0x02;

/** 弧度转角度系数 */
const RAD_TO_DEG = 57.2957795;

/**
 * 传感器数据回调
 */
export type SensorDataCallback = (
  controllerNumber: number,
  motionType: number,
  x: number,
  y: number,
  z: number
) => void;

/**
 * 设备传感器服务
 * 
 * 管理设备内置陀螺仪和加速度计，当手柄没有传感器时提供回退
 */
export class DeviceSensorService {
  private static instance: DeviceSensorService;

  // 传感器状态
  private gyroEnabled: boolean = false;
  private accelEnabled: boolean = false;
  private gyroReportRateHz: number = 0;
  private accelReportRateHz: number = 0;

  // 绑定的控制器编号
  private controllerNumber: number = 0;

  // 数据回调
  private dataCallback: SensorDataCallback | null = null;

  // 去重：上一次值
  private lastGyroValues: number[] = [0, 0, 0];
  private lastAccelValues: number[] = [0, 0, 0];

  // 传感器可用标志
  private gyroAvailable: boolean = false;
  private accelAvailable: boolean = false;
  private availabilityChecked: boolean = false;

  private constructor() {}

  static getInstance(): DeviceSensorService {
    if (!DeviceSensorService.instance) {
      DeviceSensorService.instance = new DeviceSensorService();
    }
    return DeviceSensorService.instance;
  }

  /**
   * 检测设备是否有陀螺仪传感器
   */
  hasGyroscope(): boolean {
    this.checkAvailability();
    return this.gyroAvailable;
  }

  /**
   * 检测设备是否有加速度计传感器
   */
  hasAccelerometer(): boolean {
    this.checkAvailability();
    return this.accelAvailable;
  }

  /**
   * 检测传感器可用性
   * 通过 sensor.once() 尝试获取单次读数来判断传感器是否存在
   */
  private checkAvailability(): void {
    if (this.availabilityChecked) {
      return;
    }

    try {
      sensor.once(sensor.SensorId.GYROSCOPE, (_data: sensor.GyroscopeResponse) => {
        // 成功获取数据说明陀螺仪可用
      });
      this.gyroAvailable = true;
    } catch {
      this.gyroAvailable = false;
    }

    try {
      sensor.once(sensor.SensorId.ACCELEROMETER, (_data: sensor.AccelerometerResponse) => {
        // 成功获取数据说明加速度计可用
      });
      this.accelAvailable = true;
    } catch {
      this.accelAvailable = false;
    }

    this.availabilityChecked = true;
    console.info(`[DeviceSensor] 可用性检查: gyro=${this.gyroAvailable}, accel=${this.accelAvailable}`);
  }

  /**
   * 设置数据回调
   */
  setDataCallback(callback: SensorDataCallback | null): void {
    this.dataCallback = callback;
  }

  /**
   * 设置绑定的控制器编号
   */
  setControllerNumber(controllerNumber: number): void {
    this.controllerNumber = controllerNumber;
  }

  /**
   * 获取设备屏幕旋转方向
   * 用于在使用设备传感器时校正坐标轴
   * @returns 旋转角度 (0, 90, 180, 270)
   */
  private getDeviceRotation(): number {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      return defaultDisplay.rotation * 90; // rotation 是 0-3, 乘90转角度
    } catch {
      return 0;
    }
  }

  /**
   * 根据设备方向校正传感器坐标轴
   * 参照 Android ControllerHandler.createSensorListener 的方向校正逻辑
   * 
   * @param rawX 原始 X 值
   * @param rawY 原始 Y 值
   * @param rawZ 原始 Z 值
   * @returns 校正后的 [x, y, z]
   */
  private correctOrientation(rawX: number, rawY: number, rawZ: number): number[] {
    const rotation = this.getDeviceRotation();
    let x: number, y: number, z: number;

    // HarmonyOS display.rotation 的旋转方向定义与 Android Surface.ROTATION_* 相反:
    // HarmonyOS rotation=1 (90°顺时针) 对应 Android ROTATION_270
    // HarmonyOS rotation=3 (270°顺时针) 对应 Android ROTATION_90
    // 因此 case 90 和 case 270 的校正逻辑需要互换
    switch (rotation) {
      case 0: // ROTATION_0 (竖屏) — 两平台一致
        x = rawX;
        y = rawZ;
        z = -rawY;
        break;
      case 90: // HarmonyOS 顺时针90° → 对应 Android ROTATION_270
        x = rawY;
        y = rawZ;
        z = rawX;
        break;
      case 180: // ROTATION_180 (倒竖屏) — 两平台一致
        x = -rawX;
        y = rawZ;
        z = rawY;
        break;
      case 270: // HarmonyOS 顺时针270° → 对应 Android ROTATION_90
        x = -rawY;
        y = rawZ;
        z = -rawX;
        break;
      default:
        x = rawX;
        y = rawY;
        z = rawZ;
        break;
    }

    return [x, y, z];
  }

  /**
   * 启用/禁用指定类型的传感器
   * 
   * @param motionType LI_MOTION_TYPE_ACCEL 或 LI_MOTION_TYPE_GYRO
   * @param reportRateHz 上报频率，0 表示停止
   */
  setMotionEventState(motionType: number, reportRateHz: number): void {
    if (motionType === LI_MOTION_TYPE_GYRO) {
      this.setGyroState(reportRateHz);
    } else if (motionType === LI_MOTION_TYPE_ACCEL) {
      this.setAccelState(reportRateHz);
    }
  }

  /**
   * 启用/禁用陀螺仪
   */
  private setGyroState(reportRateHz: number): void {
    // 先取消已有订阅
    if (this.gyroEnabled) {
      try {
        sensor.off(sensor.SensorId.GYROSCOPE);
      } catch (err) {
        console.warn(`[DeviceSensor] 取消陀螺仪订阅失败: ${err}`);
      }
      this.gyroEnabled = false;
    }

    this.gyroReportRateHz = reportRateHz;

    if (reportRateHz === 0) {
      console.info('[DeviceSensor] 陀螺仪已禁用');
      // 发送归零事件以确保虚拟控制器静止
      if (this.dataCallback) {
        this.dataCallback(this.controllerNumber, LI_MOTION_TYPE_GYRO, 0, 0, 0);
      }
      return;
    }

    // 计算采样间隔（微秒） 
    const intervalUs = Math.floor(1000000 / Math.min(200, reportRateHz));

    try {
      sensor.on(sensor.SensorId.GYROSCOPE, (data: sensor.GyroscopeResponse) => {
        // 去重
        if (data.x === this.lastGyroValues[0] &&
            data.y === this.lastGyroValues[1] &&
            data.z === this.lastGyroValues[2]) {
          return;
        }
        this.lastGyroValues[0] = data.x;
        this.lastGyroValues[1] = data.y;
        this.lastGyroValues[2] = data.z;

        // 设备传感器返回 rad/s，需要转换为 deg/s
        const rawX = data.x * RAD_TO_DEG;
        const rawY = data.y * RAD_TO_DEG;
        const rawZ = data.z * RAD_TO_DEG;

        // 方向校正
        const corrected = this.correctOrientation(rawX, rawY, rawZ);
        const cx = corrected[0];
        const cy = corrected[1];
        const cz = corrected[2];

        if (this.dataCallback) {
          this.dataCallback(this.controllerNumber, LI_MOTION_TYPE_GYRO, cx, cy, cz);
        }
      }, { interval: intervalUs });

      this.gyroEnabled = true;
      console.info(`[DeviceSensor] 陀螺仪已启用: rate=${reportRateHz}Hz, interval=${intervalUs}us`);
    } catch (err) {
      console.error(`[DeviceSensor] 启用陀螺仪失败: ${err}`);
      this.gyroAvailable = false;
    }
  }

  /**
   * 启用/禁用加速度计
   */
  private setAccelState(reportRateHz: number): void {
    // 先取消已有订阅
    if (this.accelEnabled) {
      try {
        sensor.off(sensor.SensorId.ACCELEROMETER);
      } catch (err) {
        console.warn(`[DeviceSensor] 取消加速度计订阅失败: ${err}`);
      }
      this.accelEnabled = false;
    }

    this.accelReportRateHz = reportRateHz;

    if (reportRateHz === 0) {
      console.info('[DeviceSensor] 加速度计已禁用');
      return;
    }

    const intervalUs = Math.floor(1000000 / Math.min(200, reportRateHz));

    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        // 去重
        if (data.x === this.lastAccelValues[0] &&
            data.y === this.lastAccelValues[1] &&
            data.z === this.lastAccelValues[2]) {
          return;
        }
        this.lastAccelValues[0] = data.x;
        this.lastAccelValues[1] = data.y;
        this.lastAccelValues[2] = data.z;

        // 加速度计数据单位已经是 m/s²，无需转换
        const rawX = data.x;
        const rawY = data.y;
        const rawZ = data.z;

        // 方向校正
        const corrected = this.correctOrientation(rawX, rawY, rawZ);
        const cx = corrected[0];
        const cy = corrected[1];
        const cz = corrected[2];

        if (this.dataCallback) {
          this.dataCallback(this.controllerNumber, LI_MOTION_TYPE_ACCEL, cx, cy, cz);
        }
      }, { interval: intervalUs });

      this.accelEnabled = true;
      console.info(`[DeviceSensor] 加速度计已启用: rate=${reportRateHz}Hz, interval=${intervalUs}us`);
    } catch (err) {
      console.error(`[DeviceSensor] 启用加速度计失败: ${err}`);
      this.accelAvailable = false;
    }
  }

  /**
   * 禁用所有传感器
   */
  disableAll(): void {
    this.setGyroState(0);
    this.setAccelState(0);
    this.dataCallback = null;
    console.info('[DeviceSensor] 所有传感器已禁用');
  }

  /**
   * 重新启用之前活跃的传感器（断线重连/恢复时使用）
   */
  reenableActiveSensors(): void {
    if (this.gyroReportRateHz > 0) {
      this.setGyroState(this.gyroReportRateHz);
    }
    if (this.accelReportRateHz > 0) {
      this.setAccelState(this.accelReportRateHz);
    }
  }

  /**
   * 检查是否有传感器正在活跃
   */
  isActive(): boolean {
    return this.gyroEnabled || this.accelEnabled;
  }

  /**
   * 获取陀螺仪活跃状态
   */
  isGyroActive(): boolean {
    return this.gyroEnabled;
  }

  /**
   * 获取加速度计活跃状态
   */
  isAccelActive(): boolean {
    return this.accelEnabled;
  }

  /**
   * 获取当前陀螺仪报告频率
   */
  getGyroReportRate(): number {
    return this.gyroReportRateHz;
  }

  /**
   * 获取当前加速度计报告频率
   */
  getAccelReportRate(): number {
    return this.accelReportRateHz;
  }

  /**
   * 获取最后一次陀螺仪数据（用于测试/调试UI展示）
   */
  getLastGyroValues(): number[] {
    return [...this.lastGyroValues];
  }

  /**
   * 获取最后一次加速度计数据（用于测试/调试UI展示）
   */
  getLastAccelValues(): number[] {
    return [...this.lastAccelValues];
  }

  /**
   * 获取当前屏幕旋转角度（用于测试/调试展示）
   */
  getCurrentRotation(): number {
    return this.getDeviceRotation();
  }
}
