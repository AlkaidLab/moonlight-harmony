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
 * USB 驱动服务
 * 
 * 参考 Android moonlight-android UsbDriverService
 * 管理 USB 手柄设备的枚举、权限请求和驱动实例化
 */

import { usbManager } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { AbstractController } from './AbstractController';
import { UsbDriverListener, UsbDriverStateListener } from './UsbDriverListener';
import { Xbox360Controller } from './Xbox360Controller';
import { XboxOneController } from './XboxOneController';
import { Dualshock4Controller } from './Dualshock4Controller';
import { DualSenseController } from './DualSenseController';
import { SwitchProController } from './SwitchProController';
import { NativeHidController } from './NativeHidController';
import { SettingsService } from '../../service/SettingsService';

const TAG = '[USB-SERVICE]';

// USB 设备事件常量
const USB_DEVICE_ATTACHED = 'usual.event.hardware.usb.action.USB_DEVICE_ATTACHED';
const USB_DEVICE_DETACHED = 'usual.event.hardware.usb.action.USB_DEVICE_DETACHED';

/**
 * USB 驱动服务
 * 管理所有 USB 控制器设备
 */
export class UsbDriverService implements UsbDriverListener {
  private static instance: UsbDriverService;
  
  private started: boolean = false;
  private controllers: AbstractController[] = [];
  private listener: UsbDriverListener | null = null;
  private stateListener: UsbDriverStateListener | null = null;
  private nextDeviceId: number = 1000;  // USB 设备 ID 从 1000 开始，避免与系统设备冲突
  
  // 已处理的设备（避免重复处理）
  private processedDevices: Set<string> = new Set();
  
  // USB 事件订阅者
  private usbSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  
  // 定期重新扫描设备的定时器 ID
  private rescanTimerId: number | null = null;
  // 重新扫描间隔（毫秒）- 每 5 秒检查一次
  private static readonly RESCAN_INTERVAL_MS: number = 5000;
  
  private constructor() {
    console.info(`${TAG} 创建 USB 驱动服务实例`);
  }
  
  /**
   * 获取单例实例
   */
  static getInstance(): UsbDriverService {
    if (!UsbDriverService.instance) {
      UsbDriverService.instance = new UsbDriverService();
    }
    return UsbDriverService.instance;
  }
  
  /**
   * 设置输入监听器
   */
  setListener(listener: UsbDriverListener | null): void {
    this.listener = listener;
    
    // 通知已连接的控制器
    if (listener) {
      for (const controller of this.controllers) {
        listener.deviceAdded(controller);
      }
    }
  }
  
  /**
   * 设置状态监听器
   */
  setStateListener(stateListener: UsbDriverStateListener | null): void {
    this.stateListener = stateListener;
  }

  /**
   * 设置指定控制器的强制协议类型
   * @param controllerId 控制器 ID
   * @param protocolType 协议类型 (0=自动, 1=Xbox, 2=DS4, 3=Switch, 4=Generic, 5=DualSense)
   * @returns 是否设置成功
   */
  setControllerProtocolType(controllerId: number, protocolType: number): boolean {
    const controller = this.controllers.find(c => c.getControllerId() === controllerId);
    if (controller && controller instanceof NativeHidController) {
      controller.setForceProtocolType(protocolType);
      return true;
    }
    console.warn(`${TAG} 未找到控制器 ID=${controllerId} 或不支持协议切换`);
    return false;
  }
  
  /**
   * 手动触发设备重新扫描
   * 可用于在设备空闲断开后手动重连
   */
  async rescanDevices(): Promise<void> {
    console.info(`${TAG} 手动触发设备重新扫描`);
    // 清空已处理设备列表，强制重新枚举所有设备
    this.processedDevices.clear();
    await this.enumerateDevices();
  }
  
  /**
   * 启动服务
   */
  async start(): Promise<void> {
    if (this.started) {
      console.info(`${TAG} 服务已启动`);
      return;
    }
    
    console.info(`${TAG} 启动 USB 驱动服务`);
    this.started = true;
    
    // 订阅 USB 设备插拔事件
    await this.subscribeUsbEvents();
    
    // 枚举已连接的设备
    await this.enumerateDevices();
    
    // 启动定期重新扫描定时器
    this.startRescanTimer();
  }
  
  /**
   * 启动定期重新扫描定时器
   * 用于检测从省电模式唤醒或重新连接的设备
   */
  private startRescanTimer(): void {
    if (this.rescanTimerId !== null) {
      return;
    }
    
    console.info(`${TAG} 启动设备重新扫描定时器，间隔 ${UsbDriverService.RESCAN_INTERVAL_MS}ms`);
    this.rescanTimerId = setInterval(() => {
      this.checkAndRescanDevices();
    }, UsbDriverService.RESCAN_INTERVAL_MS);
  }
  
  /**
   * 停止定期重新扫描定时器
   */
  private stopRescanTimer(): void {
    if (this.rescanTimerId !== null) {
      clearInterval(this.rescanTimerId);
      this.rescanTimerId = null;
      console.info(`${TAG} 停止设备重新扫描定时器`);
    }
  }
  
  /**
   * 检查并重新扫描设备
   * 如果有控制器断开但设备仍然连接，尝试重新初始化
   */
  private async checkAndRescanDevices(): Promise<void> {
    // 检查是否有断开的控制器但设备仍然存在
    try {
      const currentDevices = usbManager.getDevices();
      
      // 检查已处理的设备是否有断开的控制器
      for (const device of currentDevices) {
        // 使用完整的物理位置 key
        const deviceKey = `${device.vendorId}:${device.productId}:${device.busNum}:${device.devAddress}`;
        
        // 检查是否已处理此设备
        if (this.processedDevices.has(deviceKey)) {
          // 查找对应的控制器
          const controller = this.controllers.find(c => c.getDeviceKey() === deviceKey);
          
          // 如果控制器不存在或已断开，从已处理列表中移除以便重新枚举
          const shouldReenumerate = !controller || !controller.isConnected();
          
          if (shouldReenumerate) {
            console.info(`${TAG} 检测到设备存在但控制器已断开，准备重新枚举: ${deviceKey}`);
            this.processedDevices.delete(deviceKey);
          }
        }
      }
      
      // 检查是否有新设备可以枚举
      const hasUnprocessedDevices = currentDevices.some(device => {
        const deviceKey = `${device.vendorId}:${device.productId}:${device.busNum}:${device.devAddress}`;
        return !this.processedDevices.has(deviceKey);
      });
      
      if (hasUnprocessedDevices) {
        console.info(`${TAG} 检测到未处理的设备，执行重新枚举`);
        await this.enumerateDevices();
      }
    } catch (err) {
      console.error(`${TAG} 检查设备状态失败:`, err);
    }
  }
  
  /**
   * 订阅 USB 设备插拔事件
   */
  private async subscribeUsbEvents(): Promise<void> {
    try {
      const subscribeInfo: commonEventManager.CommonEventSubscribeInfo = {
        events: [USB_DEVICE_ATTACHED, USB_DEVICE_DETACHED]
      };
      
      this.usbSubscriber = await commonEventManager.createSubscriber(subscribeInfo);
      
      commonEventManager.subscribe(this.usbSubscriber, (err, data) => {
        if (err) {
          console.error(`${TAG} USB 事件接收错误:`, err);
          return;
        }
        
        console.info(`${TAG} 收到 USB 事件: ${data.event}`);
        
        if (data.event === USB_DEVICE_ATTACHED) {
          // 设备插入，延迟处理以等待系统稳定
          console.info(`${TAG} USB 设备已插入，延迟 500ms 后枚举设备`);
          setTimeout(() => {
            this.enumerateDevices();
          }, 500);
        } else if (data.event === USB_DEVICE_DETACHED) {
          // 设备拔出，检查控制器状态
          console.info(`${TAG} USB 设备已拔出，检查控制器状态`);
          this.checkDetachedControllers();
        }
      });
      
      console.info(`${TAG} 已订阅 USB 设备插拔事件`);
    } catch (err) {
      console.error(`${TAG} 订阅 USB 事件失败:`, err);
    }
  }
  
  /**
   * 取消订阅 USB 事件
   */
  private unsubscribeUsbEvents(): void {
    if (this.usbSubscriber) {
      try {
        commonEventManager.unsubscribe(this.usbSubscriber);
        console.info(`${TAG} 已取消订阅 USB 事件`);
      } catch (err) {
        console.error(`${TAG} 取消订阅 USB 事件失败:`, err);
      }
      this.usbSubscriber = null;
    }
  }
  
  /**
   * 检查已断开的控制器
   */
  private checkDetachedControllers(): void {
    // 获取当前已连接的 USB 设备列表
    try {
      const currentDevices = usbManager.getDevices();
      const currentDeviceKeys = new Set<string>();
      
      // 使用完整的 deviceKey (VID:PID:busNum:devAddress) 进行匹配
      for (const device of currentDevices) {
        const key = `${device.vendorId}:${device.productId}:${device.busNum}:${device.devAddress}`;
        currentDeviceKeys.add(key);
      }
      
      // 检查每个控制器是否仍然连接
      const controllersToRemove: AbstractController[] = [];
      for (const controller of this.controllers) {
        const deviceKey = controller.getDeviceKey();
        if (!currentDeviceKeys.has(deviceKey)) {
          console.info(`${TAG} 检测到控制器已断开: ${deviceKey}`);
          controllersToRemove.push(controller);
        }
      }
      
      // 停止并移除断开的控制器
      for (const controller of controllersToRemove) {
        controller.stop();
      }
    } catch (err) {
      console.error(`${TAG} 检查断开设备失败:`, err);
    }
  }
  
  /**
   * 停止服务
   */
  stop(): void {
    if (!this.started) {
      return;
    }
    
    console.info(`${TAG} 停止 USB 驱动服务`);
    this.started = false;
    
    // 停止定期重新扫描定时器
    this.stopRescanTimer();
    
    // 取消订阅 USB 事件
    this.unsubscribeUsbEvents();
    
    // 停止所有控制器
    while (this.controllers.length > 0) {
      const controller = this.controllers.shift();
      if (controller) {
        controller.stop();
      }
    }
    
    this.processedDevices.clear();
  }
  
  /**
   * 枚举 USB 设备
   */
  private async enumerateDevices(): Promise<void> {
    try {
      const devices: usbManager.USBDevice[] = usbManager.getDevices();
      console.info(`${TAG} 发现 ${devices.length} 个 USB 设备`);
      
      for (let i: number = 0; i < devices.length; i++) {
        const device: usbManager.USBDevice = devices[i];
        await this.handleUsbDevice(device);
      }
    } catch (err) {
      console.error(`${TAG} 枚举设备失败:`, err);
    }
  }
  
  /**
   * 处理 USB 设备
   */
  private async handleUsbDevice(device: usbManager.USBDevice): Promise<void> {
    // 使用 busNum:devAddress 作为物理位置唯一标识
    const deviceKey = `${device.vendorId}:${device.productId}:${device.busNum}:${device.devAddress}`;
    
    // 检查是否已处理此物理位置的设备
    if (this.processedDevices.has(deviceKey)) {
      return;
    }
    
    // 检查是否已有相同物理位置的控制器（不太可能，但防御性编程）
    const existingController = this.controllers.find(
      c => c.getDeviceKey() === deviceKey
    );
    
    if (existingController) {
      if (existingController.isConnected()) {
        // 控制器仍然连接，跳过
        console.info(`${TAG} 设备已有活跃控制器，跳过: ${deviceKey}`);
        return;
      } else {
        // 控制器已断开，移除旧控制器
        console.info(`${TAG} 检测到旧控制器已断开，移除后重新创建: ${deviceKey}`);
        existingController.stop();
        // deviceRemoved 会在 stop 时被调用
      }
    }
    
    // 检查是否可以驱动
    if (!this.shouldClaimDevice(device)) {
      return;
    }
    
    console.info(`${TAG} 检测到可驱动的设备: ${device.name} (VID=0x${device.vendorId.toString(16)}, PID=0x${device.productId.toString(16)})`);
    
    // 检查权限
    const hasPermission = usbManager.hasRight(device.name);
    
    if (!hasPermission) {
      console.info(`${TAG} 请求 USB 设备权限: ${device.name}`);
      
      if (this.stateListener) {
        this.stateListener.onUsbPermissionPromptStarting();
      }
      
      try {
        const granted = await usbManager.requestRight(device.name);
        
        if (this.stateListener) {
          this.stateListener.onUsbPermissionPromptCompleted();
        }
        
        if (!granted) {
          console.warn(`${TAG} 用户拒绝了 USB 权限: ${device.name}`);
          return;
        }
      } catch (err) {
        console.error(`${TAG} 请求权限失败:`, err);
        if (this.stateListener) {
          this.stateListener.onUsbPermissionPromptCompleted();
        }
        return;
      }
    }
    
    // 打开设备
    let pipe: usbManager.USBDevicePipe;
    try {
      pipe = usbManager.connectDevice(device);
      console.info(`${TAG} 成功连接设备: ${device.name}`);
    } catch (err) {
      console.error(`${TAG} 连接设备失败:`, err);
      return;
    }
    
    // 创建控制器实例
    let controller: AbstractController | null = null;
    let driverName: string = '';
    
    if (XboxOneController.canClaimDevice(device)) {
      driverName = 'XboxOneController';
      controller = new XboxOneController(device, pipe, this.nextDeviceId++, this);
    } else if (Xbox360Controller.canClaimDevice(device)) {
      driverName = 'Xbox360Controller';
      controller = new Xbox360Controller(device, pipe, this.nextDeviceId++, this);
    } else if (SwitchProController.canClaimDevice(device)) {
      driverName = 'SwitchProController';
      controller = new SwitchProController(device, pipe, this.nextDeviceId++, this);
    } else if (DualSenseController.canClaimDevice(device)) {
      driverName = 'DualSenseController';
      controller = new DualSenseController(device, pipe, this.nextDeviceId++, this);
    } else if (Dualshock4Controller.canClaimDevice(device)) {
      driverName = 'Dualshock4Controller';
      controller = new Dualshock4Controller(device, pipe, this.nextDeviceId++, this);
    } else if (NativeHidController.canClaimDevice(device)) {
      // 使用原生 HID 解析器（支持更多手柄）
      driverName = 'NativeHidController';
      controller = new NativeHidController(device, pipe, this.nextDeviceId++, this);
    }
    
    if (controller) {
      // 设置设备物理位置信息（用于唯一标识）
      controller.setDeviceLocation(device.busNum, device.devAddress, device.serial || '');
      
      // 应用忽略断开信号设置
      const inputSettings = await SettingsService.getInstance().getInputSettings();
      if (inputSettings.ignoreDeviceDisconnect) {
        controller.setIgnoreDisconnect(true);
        console.info(`${TAG} 设备 ${device.name} 已启用忽略断开信号`);
      }
      
      console.info(`${TAG} 使用驱动 [${driverName}] 处理设备: ${device.name}, Key=${controller.getDeviceKey()}`);
    } else {
      console.warn(`${TAG} 无法为设备创建控制器: ${device.name}`);
      usbManager.closePipe(pipe);
      return;
    }
    
    // 启动控制器
    if (!controller.start()) {
      console.error(`${TAG} 启动控制器失败`);
      usbManager.closePipe(pipe);
      return;
    }
    
    // 记录已处理的设备（deviceKey 已在函数开头定义）
    this.processedDevices.add(deviceKey);
    
    // 添加到控制器列表
    this.controllers.push(controller);
    console.info(`${TAG} 控制器已启动: ID=${controller.getControllerId()}, Key=${deviceKey}`);
  }
  
  /**
   * 检查是否应该驱动该设备
   */
  private shouldClaimDevice(device: usbManager.USBDevice): boolean {
    return XboxOneController.canClaimDevice(device) ||
           Xbox360Controller.canClaimDevice(device) ||
           SwitchProController.canClaimDevice(device) ||
           DualSenseController.canClaimDevice(device) ||
           Dualshock4Controller.canClaimDevice(device) ||
           NativeHidController.canClaimDevice(device);
  }
  
  /**
   * 刷新设备列表
   */
  async refreshDevices(): Promise<void> {
    if (!this.started) {
      return;
    }
    
    console.info(`${TAG} 刷新 USB 设备列表`);
    await this.enumerateDevices();
  }
  
  /**
   * 获取已连接的控制器数量
   */
  getControllerCount(): number {
    return this.controllers.length;
  }
  
  /**
   * 获取所有控制器
   */
  getControllers(): AbstractController[] {
    return [...this.controllers];
  }
  
  // ==================== UsbDriverListener 实现 ====================
  
  reportControllerState(
    controllerId: number,
    buttonFlags: number,
    leftStickX: number,
    leftStickY: number,
    rightStickX: number,
    rightStickY: number,
    leftTrigger: number,
    rightTrigger: number
  ): void {
    if (this.listener) {
      this.listener.reportControllerState(
        controllerId,
        buttonFlags,
        leftStickX,
        leftStickY,
        rightStickX,
        rightStickY,
        leftTrigger,
        rightTrigger
      );
    }
  }
  
  reportControllerMotion(
    controllerId: number,
    motionType: number,
    x: number,
    y: number,
    z: number
  ): void {
    if (this.listener) {
      this.listener.reportControllerMotion(controllerId, motionType, x, y, z);
    }
  }
  
  deviceRemoved(controller: AbstractController): void {
    // 从列表中移除
    const index = this.controllers.indexOf(controller);
    if (index >= 0) {
      this.controllers.splice(index, 1);
    }
    
    // 从已处理设备中移除（使用精确的 deviceKey）
    const deviceKey = controller.getDeviceKey();
    if (this.processedDevices.has(deviceKey)) {
      this.processedDevices.delete(deviceKey);
    }
    
    console.info(`${TAG} 控制器已移除: ID=${controller.getControllerId()}, Key=${deviceKey}`);
    
    if (this.listener) {
      this.listener.deviceRemoved(controller);
    }
  }
  
  deviceAdded(controller: AbstractController): void {
    console.info(`${TAG} 控制器已添加: ID=${controller.getControllerId()}, Key=${controller.getDeviceKey()}`);
    
    if (this.listener) {
      this.listener.deviceAdded(controller);
    }
  }
}
