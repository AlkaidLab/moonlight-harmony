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
import { Logger } from '../../common/Logger';

// =============================================================================
// 常量定义
// =============================================================================

/** 运动类型（与 moonlight-common-c LI_MOTION_TYPE_* 一致） */
export const LI_MOTION_TYPE_ACCEL = 0x01;
export const LI_MOTION_TYPE_GYRO = 0x02;

/** 弧度转角度系数 */
const RAD_TO_DEG = 57.2957795;

/** HarmonyOS Sensor Service Kit 的 interval 单位为纳秒 */
const NANOSECONDS_PER_SECOND = 1000000000;

/** 传感器最小上报间隔为 5 ms，对应最高 200 Hz */
const MAX_SENSOR_REPORT_RATE_HZ = 200;

/**
 * 传感器数据回调
 */
export type SensorDataCallback = (
  controllerNumber: number,
  motionType: number,
  x: number,
  y: number,
  z: number
) => number;

export type SensorStopCallback = (controllerNumber: number) => void;
export type LocalGyroCallback = (controllerNumber: number, motionType: number,
  x: number, y: number, z: number) => boolean;

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
  private stopCallback: SensorStopCallback | null = null;
  private localGyroCallback: LocalGyroCallback | null = null;
  private localGyroRateHz: number = 0;
  private gyroSamplingRateHz: number = 0;
  private gyroGeneration: number = 0;
  private accelGeneration: number = 0;

  // 最近的原始读数，仅用于调试展示
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
    Logger.info('DeviceSensorService', `[DeviceSensor] 可用性检查: gyro=${this.gyroAvailable}, accel=${this.accelAvailable}`);
  }

  /**
   * 设置数据回调
   */
  setDataCallback(callback: SensorDataCallback | null, stopCallback: SensorStopCallback | null = null): void {
    this.dataCallback = callback;
    this.stopCallback = stopCallback;
  }

  /** Local acquisition demand and consumer are independent of host forwarding. */
  setLocalGyroConsumer(callback: LocalGyroCallback | null, rateHz: number): void {
    this.localGyroCallback = callback;
    this.localGyroRateHz = callback ? rateHz : 0;
    this.updateGyroSubscription();
  }

  stopRemoteGyro(): void {
    if (this.stopCallback) this.stopCallback(this.controllerNumber);
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
    this.gyroReportRateHz = Math.max(0, reportRateHz);
    if (reportRateHz === 0) this.stopRemoteGyro();
    this.updateGyroSubscription();
  }

  private updateGyroSubscription(): void {
    const rateHz = Math.min(MAX_SENSOR_REPORT_RATE_HZ,
      Math.max(this.gyroReportRateHz, this.localGyroRateHz));
    if (this.gyroEnabled && rateHz === this.gyroSamplingRateHz) return;
    const generation = ++this.gyroGeneration;
    if (this.gyroEnabled) {
      try {
        sensor.off(sensor.SensorId.GYROSCOPE);
      } catch (err) {
        Logger.warn('DeviceSensorService', `[DeviceSensor] 取消陀螺仪订阅失败: ${err}`);
      }
      this.gyroEnabled = false;
    }
    this.gyroSamplingRateHz = rateHz;
    if (rateHz === 0) return;
    const intervalNs = Math.floor(NANOSECONDS_PER_SECOND / rateHz);
    try {
      sensor.on(sensor.SensorId.GYROSCOPE, (data: sensor.GyroscopeResponse) => {
        if (generation !== this.gyroGeneration || !this.gyroEnabled) return;
        this.lastGyroValues[0] = data.x;
        this.lastGyroValues[1] = data.y;
        this.lastGyroValues[2] = data.z;
        const corrected = this.correctOrientation(data.x * RAD_TO_DEG,
          data.y * RAD_TO_DEG, data.z * RAD_TO_DEG);
        const consumed = this.localGyroCallback
          ? this.localGyroCallback(this.controllerNumber, LI_MOTION_TYPE_GYRO,
            corrected[0], corrected[1], corrected[2]) : false;
        if (consumed) {
          this.stopRemoteGyro();
        } else if (this.gyroReportRateHz > 0 && this.dataCallback) {
          this.dataCallback(this.controllerNumber, LI_MOTION_TYPE_GYRO,
            corrected[0], corrected[1], corrected[2]);
        }
      }, { interval: intervalNs });
      this.gyroEnabled = true;
    } catch (err) {
      Logger.error('DeviceSensorService', `[DeviceSensor] 启用陀螺仪失败: ${err}`);
      this.gyroAvailable = false;
    }
  }

  /**
   * 启用/禁用加速度计
   */
  private setAccelState(reportRateHz: number): void {
    const generation = ++this.accelGeneration;
    if (this.accelEnabled) {
      try {
        sensor.off(sensor.SensorId.ACCELEROMETER);
      } catch (err) {
        Logger.warn('DeviceSensorService', `[DeviceSensor] 取消加速度计订阅失败: ${err}`);
      }
      this.accelEnabled = false;
    }
    this.accelReportRateHz = Math.max(0, reportRateHz);
    if (reportRateHz === 0) return;
    const intervalNs = Math.floor(NANOSECONDS_PER_SECOND /
      Math.min(MAX_SENSOR_REPORT_RATE_HZ, reportRateHz));
    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        if (generation !== this.accelGeneration || !this.accelEnabled) return;
        this.lastAccelValues[0] = data.x;
        this.lastAccelValues[1] = data.y;
        this.lastAccelValues[2] = data.z;
        const corrected = this.correctOrientation(data.x, data.y, data.z);
        if (this.dataCallback) this.dataCallback(this.controllerNumber, LI_MOTION_TYPE_ACCEL,
          corrected[0], corrected[1], corrected[2]);
      }, { interval: intervalNs });
      this.accelEnabled = true;
    } catch (err) {
      Logger.error('DeviceSensorService', `[DeviceSensor] 启用加速度计失败: ${err}`);
      this.accelAvailable = false;
    }
  }

  /**
   * 禁用所有传感器
   */
  disableAll(): void {
    this.localGyroCallback = null;
    this.localGyroRateHz = 0;
    this.setGyroState(0);
    this.setAccelState(0);
    this.dataCallback = null;
    this.stopCallback = null;
    Logger.info('DeviceSensorService', '[DeviceSensor] 所有传感器已禁用');
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
