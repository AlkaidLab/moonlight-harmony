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
 * 体感助手服务 — 将陀螺仪角速度映射到右摇杆
 *
 * 移植自 Android Moonlight ControllerHandler.applyGyroToRightStick()
 *
 * 数据流:
 *   DeviceSensorService (deg/s) → GyroAssistService.onGyroData()
 *   → 灵敏度缩放 + 轴反转 → gyroStickX/Y (±32766)
 *   → StreamPage.handleGamepadInput() 中与物理摇杆叠加
 *
 * 轴映射 (与 Android 一致):
 *   陀螺仪 Z轴 (Yaw/偏航)  → 右摇杆 X (水平瞄准)
 *   陀螺仪 X轴 (Pitch/俯仰) → 右摇杆 Y (垂直瞄准)
 *
 * 灵敏度模型:
 *   effectiveSensitivity = 180° / multiplier
 *   旋转速度达到 effectiveSensitivity deg/s 时摇杆满偏
 *   multiplier=1.0 → 180°/s 满偏; multiplier=3.0 → 60°/s 满偏
 */

import { DeviceSensorService, LI_MOTION_TYPE_GYRO, SensorDataCallback } from './DeviceSensorService';

// ==================== 常量 ====================

/** 摇杆值范围 */
const STICK_MAX: number = 0x7FFE; // 32766

/** 激活模式 */
export const GYRO_ACTIVATION_ALWAYS: number = -1;
export const GYRO_ACTIVATION_LT: number = 0;
export const GYRO_ACTIVATION_RT: number = 1;

/** 模拟触发器激活阈值 (0~255 中的 20%) */
const TRIGGER_ACTIVATE_THRESHOLD: number = 51; // 255 * 0.2

/** 默认灵敏度倍率 */
const DEFAULT_SENSITIVITY: number = 2.0;

/** 默认报告频率 */
const GYRO_REPORT_RATE_HZ: number = 120;

/**
 * 物理摇杆去噪阈值 (对齐 Android ControllerHandler.PHYS_EPSILON)
 * ~1.6% of full scale，消除微小抖动，避免陀螺仪融合时引入噪声
 */
const PHYS_EPSILON: number = 512;

/**
 * 即时发送回调类型
 * 当陀螺仪数据更新时，GyroAssist 会通过此回调立即发送融合后的手柄状态
 * 参数含义与 sendGamepadState 一致
 */
export type GyroSendCallback = (
  deviceId: number,
  buttons: number,
  leftStickX: number,
  leftStickY: number,
  rightStickX: number,
  rightStickY: number,
  leftTrigger: number,
  rightTrigger: number,
  controllerType: number
) => void;

// ==================== 服务 ====================

export class GyroAssistService {
  private static instance: GyroAssistService | null = null;

  // —— 配置 ——
  private _enabled: boolean = false;
  private _sensitivityMultiplier: number = DEFAULT_SENSITIVITY;
  private _invertX: boolean = false;
  private _invertY: boolean = false;
  private _activationKey: number = GYRO_ACTIVATION_ALWAYS;

  // —— 运行时状态 ——
  private gyroStickX: number = 0;
  private gyroStickY: number = 0;
  private holdActive: boolean = false;
  private sensorListening: boolean = false;
  private controllerNumber: number = 0;

  // —— 即时发送状态（对齐 Android updateContextWithGyroData） ——
  // 存储最近一次手柄完整状态，以便陀螺仪更新时能立即构造并发送融合后的数据包
  private lastDeviceId: number = 0;
  private lastButtons: number = 0;
  private lastLeftStickX: number = 0;
  private lastLeftStickY: number = 0;
  private lastPhysRightStickX: number = 0;
  private lastPhysRightStickY: number = 0;
  private lastLeftTrigger: number = 0;
  private lastRightTrigger: number = 0;
  private lastControllerType: number = 1; // Xbox
  private sendCallback: GyroSendCallback | null = null;

  // —— 依赖 ——
  private sensorService: DeviceSensorService;

  // —— 原始传感器回调（保存引用以便解除） ——
  private originalSensorCallback: SensorDataCallback | null = null;

  private constructor() {
    this.sensorService = DeviceSensorService.getInstance();
  }

  static getInstance(): GyroAssistService {
    if (!GyroAssistService.instance) {
      GyroAssistService.instance = new GyroAssistService();
    }
    return GyroAssistService.instance;
  }

  // ==================== 属性访问器 ====================

  get enabled(): boolean {
    return this._enabled;
  }

  get sensitivityMultiplier(): number {
    return this._sensitivityMultiplier;
  }

  get invertX(): boolean {
    return this._invertX;
  }

  get invertY(): boolean {
    return this._invertY;
  }

  get activationKey(): number {
    return this._activationKey;
  }

  // ==================== 配置方法 ====================

  /**
   * 启用/禁用体感助手
   */
  setEnabled(enabled: boolean): void {
    if (this._enabled === enabled) return;
    this._enabled = enabled;

    if (enabled) {
      this.startListening();
    } else {
      this.stopListening();
    }
  }

  /**
   * 设置灵敏度倍率 (0.5 ~ 3.0)
   * 倍率越高，越小的旋转幅度即可让摇杆满偏
   */
  setSensitivity(multiplier: number): void {
    this._sensitivityMultiplier = Math.max(0.5, Math.min(10.0, multiplier));
  }

  /**
   * 设置 X 轴反转
   */
  setInvertX(invert: boolean): void {
    this._invertX = invert;
  }

  /**
   * 设置 Y 轴反转
   */
  setInvertY(invert: boolean): void {
    this._invertY = invert;
  }

  /**
   * 设置激活键
   * @param key GYRO_ACTIVATION_ALWAYS / GYRO_ACTIVATION_LT / GYRO_ACTIVATION_RT
   */
  setActivationKey(key: number): void {
    this._activationKey = key;
    // 更新 hold 状态
    if (key === GYRO_ACTIVATION_ALWAYS) {
      this.holdActive = true;
    } else {
      this.holdActive = false;
      // 切换激活键时清零当前陀螺仪数据
      this.gyroStickX = 0;
      this.gyroStickY = 0;
    }
  }

  /**
   * 从设置加载配置
   */
  loadSettings(settings: GyroAssistSettings): void {
    this._sensitivityMultiplier = settings.sensitivity;
    this._invertX = settings.invertX;
    this._invertY = settings.invertY;
    this._activationKey = settings.activationKey;

    if (this._activationKey === GYRO_ACTIVATION_ALWAYS) {
      this.holdActive = true;
    }
  }

  // ==================== 核心逻辑 ====================

  /**
   * 处理陀螺仪数据 — 映射为右摇杆值
   *
   * 与 Android ControllerHandler.applyGyroToRightStick() 对齐:
   *   - gyroZ (yaw/偏航) → 右摇杆 X
   *   - gyroX (pitch/俯仰) → 右摇杆 Y
   *   - 灵敏度: effectiveSensitivity = 180 / multiplier
   *   - scaledX = -clamp(gz / sensitivity, -1, 1) → 左转为负
   *   - scaledY = clamp(gx / sensitivity, -1, 1) → 抬头为正
   */
  private onGyroData(controllerNumber: number, motionType: number,
    gx: number, gy: number, gz: number): void {
    if (motionType !== LI_MOTION_TYPE_GYRO) return;
    if (!this._enabled || !this.holdActive) {
      this.gyroStickX = 0;
      this.gyroStickY = 0;
      return;
    }

    const effectiveSensitivity = 180.0 / this._sensitivityMultiplier;

    // 轴映射: Z(yaw) → 水平, X(pitch) → 垂直
    // 与 Android applyGyroToRightStick(gz, gx) 一致:
    //   scaledX = -clamp(gz / sensitivity)  → 左偏航为负(视角左移)
    //   scaledY =  clamp(gx / sensitivity)  → 俯仰向上为正
    let scaledX = -this.clampFloat(gz / effectiveSensitivity, -1.0, 1.0);
    let scaledY = this.clampFloat(gx / effectiveSensitivity, -1.0, 1.0);

    // 轴反转
    if (this._invertX) scaledX = -scaledX;
    if (this._invertY) scaledY = -scaledY;

    // 映射到摇杆值范围
    this.gyroStickX = Math.round(scaledX * STICK_MAX);
    this.gyroStickY = Math.round(scaledY * STICK_MAX);

    // 即时发送（对齐 Android updateContextWithGyroData → sendControllerInputPacket）
    // 每次陀螺仪数据更新时立即构造融合后的手柄状态并发送，以实现 120Hz 的响应率
    if (this.sendCallback !== null) {
      const px = this.denoisePhys(this.lastPhysRightStickX);
      const py = this.denoisePhys(this.lastPhysRightStickY);
      const fusedX = this.clampShort(px + this.gyroStickX);
      const fusedY = this.clampShort(py + this.gyroStickY);
      this.sendCallback(
        this.lastDeviceId,
        this.lastButtons,
        this.lastLeftStickX,
        this.lastLeftStickY,
        fusedX,
        fusedY,
        this.lastLeftTrigger,
        this.lastRightTrigger,
        this.lastControllerType
      );
    }
  }

  /**
   * 更新激活状态（根据当前手柄扳机值）
   * 在 handleGamepadInput 中每帧调用
   */
  updateActivation(leftTrigger: number, rightTrigger: number): void {
    if (this._activationKey === GYRO_ACTIVATION_ALWAYS) {
      this.holdActive = true;
      return;
    }

    const wasActive = this.holdActive;

    if (this._activationKey === GYRO_ACTIVATION_LT) {
      this.holdActive = leftTrigger >= TRIGGER_ACTIVATE_THRESHOLD;
    } else if (this._activationKey === GYRO_ACTIVATION_RT) {
      this.holdActive = rightTrigger >= TRIGGER_ACTIVATE_THRESHOLD;
    }

    // 释放时清零陀螺仪数据
    if (wasActive && !this.holdActive) {
      this.gyroStickX = 0;
      this.gyroStickY = 0;
    }
  }

  /**
   * 将物理摇杆值与陀螺仪值融合
   * 与 Android 一致：按轴叠加 + 限幅
   *
   * @param physRsX 物理右摇杆 X (-32768~32767)
   * @param physRsY 物理右摇杆 Y (-32768~32767)
   * @returns 融合后的右摇杆值
   */
  fuseRightStick(physRsX: number, physRsY: number): StickXY {
    const result: StickXY = { x: physRsX, y: physRsY };
    if (!this._enabled || !this.holdActive) {
      return result;
    }

    result.x = this.clampShort(this.denoisePhys(physRsX) + this.gyroStickX);
    result.y = this.clampShort(this.denoisePhys(physRsY) + this.gyroStickY);
    return result;
  }

  /**
   * 更新最近一次手柄完整状态（每次手柄事件时由 StreamPage 调用）
   * 陀螺仪即时发送时使用此状态来构造完整的数据包
   */
  updateGamepadState(
    deviceId: number,
    buttons: number,
    leftStickX: number,
    leftStickY: number,
    physRightStickX: number,
    physRightStickY: number,
    leftTrigger: number,
    rightTrigger: number,
    controllerType: number
  ): void {
    this.lastDeviceId = deviceId;
    this.lastButtons = buttons;
    this.lastLeftStickX = leftStickX;
    this.lastLeftStickY = leftStickY;
    this.lastPhysRightStickX = physRightStickX;
    this.lastPhysRightStickY = physRightStickY;
    this.lastLeftTrigger = leftTrigger;
    this.lastRightTrigger = rightTrigger;
    this.lastControllerType = controllerType;
  }

  /**
   * 设置即时发送回调
   * 当陀螺仪数据更新时会通过此回调立即发送融合后的手柄状态
   * 对齐 Android 的 updateContextWithGyroData → sendControllerInputPacket 流程
   */
  setSendCallback(callback: GyroSendCallback | null): void {
    this.sendCallback = callback;
  }

  /**
   * 获取当前陀螺仪映射的摇杆值（调试用）
   */
  getGyroStickValues(): StickXY {
    const values: StickXY = { x: this.gyroStickX, y: this.gyroStickY };
    return values;
  }

  /**
   * 是否处于激活状态
   */
  isHoldActive(): boolean {
    return this.holdActive;
  }

  // ==================== 传感器管理 ====================

  /**
   * 开始监听陀螺仪（作为 DeviceSensorService 的数据消费者）
   * 注意：这里直接启动设备传感器，不依赖主机请求
   */
  private startListening(): void {
    if (this.sensorListening) return;
    if (!this.sensorService.hasGyroscope()) {
      console.warn('[GyroAssist] 设备没有陀螺仪');
      return;
    }

    // 保存并设置数据回调
    this.sensorService.setControllerNumber(this.controllerNumber);
    this.sensorService.setDataCallback(
      (cn: number, mt: number, x: number, y: number, z: number) => {
        this.onGyroData(cn, mt, x, y, z);
        // 同时转发给原始回调（如果存在），保持 motion event 直通
        if (this.originalSensorCallback) {
          this.originalSensorCallback(cn, mt, x, y, z);
        }
      }
    );

    // 启动陀螺仪
    this.sensorService.setMotionEventState(LI_MOTION_TYPE_GYRO, GYRO_REPORT_RATE_HZ);
    this.sensorListening = true;

    if (this._activationKey === GYRO_ACTIVATION_ALWAYS) {
      this.holdActive = true;
    }

    console.info(`[GyroAssist] 体感助手已启动 (灵敏度: ${this._sensitivityMultiplier}x, ` +
      `激活键: ${this._activationKey === GYRO_ACTIVATION_ALWAYS ? '始终' :
        this._activationKey === GYRO_ACTIVATION_LT ? 'LT' : 'RT'})`);
  }

  /**
   * 停止监听陀螺仪
   */
  private stopListening(): void {
    if (!this.sensorListening) return;

    this.sensorService.setMotionEventState(LI_MOTION_TYPE_GYRO, 0);
    this.sensorListening = false;
    this.holdActive = false;
    this.gyroStickX = 0;
    this.gyroStickY = 0;

    console.info('[GyroAssist] 体感助手已停止');
  }

  /**
   * 设置原始传感器回调（用于 motion event 直通）
   * 当体感助手活跃时，传感器数据同时发给助手和此回调
   */
  setOriginalSensorCallback(callback: SensorDataCallback | null): void {
    this.originalSensorCallback = callback;
  }

  /**
   * 设置绑定的控制器编号
   */
  setControllerNumber(num: number): void {
    this.controllerNumber = num;
  }

  /**
   * 清理资源
   */
  dispose(): void {
    this.stopListening();
    this.originalSensorCallback = null;
    this.sendCallback = null;
  }

  // ==================== 工具方法 ====================

  private clampFloat(value: number, min: number, max: number): number {
    return Math.max(min, Math.min(max, value));
  }

  private clampShort(value: number): number {
    return Math.max(-32767, Math.min(32767, Math.round(value)));
  }

  /**
   * 物理摇杆去噪（对齐 Android ControllerHandler.denoisePhys）
   * 消除微小抖动，避免物理摇杆的细微噪声干扰陀螺仪瞄准
   */
  private denoisePhys(v: number): number {
    return Math.abs(v) <= PHYS_EPSILON ? 0 : v;
  }
}

// ==================== 配置接口 ====================

export interface GyroAssistSettings {
  sensitivity: number;     // 灵敏度倍率 (0.5 ~ 10.0)
  invertX: boolean;        // X轴反转
  invertY: boolean;        // Y轴反转
  activationKey: number;   // 激活键 (-1=始终, 0=LT, 1=RT)
}

/** 摇杆 XY 值对 */
export interface StickXY {
  x: number;
  y: number;
}
