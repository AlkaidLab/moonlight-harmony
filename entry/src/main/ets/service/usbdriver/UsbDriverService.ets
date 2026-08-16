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
import nativeLib from 'libmoonlight_nativelib.so';

/**
 * Native USB Helper 接口
 */
interface NativeUsbHelper {
  reattachKernelDriver(fd: number, interfaceNumber: number): number;
}

interface NativeLibWithUsbHelper {
  UsbHelper?: NativeUsbHelper;
}

const usbHelper = (nativeLib as NativeLibWithUsbHelper).UsbHelper;

const TAG = '[USB-SERVICE]';

// USB 设备事件常量
const USB_DEVICE_ATTACHED = 'usual.event.hardware.usb.action.USB_DEVICE_ATTACHED';
const USB_DEVICE_DETACHED = 'usual.event.hardware.usb.action.USB_DEVICE_DETACHED';

/**
 * 已识别的 USB 手柄简要信息（仅用于检测，无副作用）
 */
export interface KnownUsbGamepadInfo {
  name: string;
  vendorId: number;
  productId: number;
  deviceKey: string;
}

/**
 * USB 驱动服务
 * 管理所有 USB 控制器设备
 */
export class UsbDriverService implements UsbDriverListener {
  private static instance: UsbDriverService;
  
  private started: boolean = false;
  // start()/stop() may overlap while USB teardown or event subscription awaits.
  private startRequested: boolean = false;
  private lifecycleGeneration: number = 0;
  private pendingStart: Promise<void> | null = null;
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
  // DualSense output teardown may wait for an in-flight USB report (bounded by
  // its 500ms transfer timeout, plus the final coalesced report).
  private static readonly USB_RESET_DELAY_MS: number = 1500;
  // DDK 高速轮询是否启用（缓存，用于 stop() 决定是否重绑内核驱动）
  private ddkEnabled: boolean = false;
  // 内核驱动重绑定定时器 ID（用于在重新启动时取消）
  private resetTimerId: number | null = null;
  // stop() keeps DualSense transports alive while the final Off report drains.
  private pendingControllerStops: Promise<void> | null = null;
  private pendingResetWait: Promise<void> | null = null;
  // Device keys awaiting kernel HID rebind after a controller release.
  private pendingResetDeviceKeys: Set<string> = new Set();
  
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
    
    // 仅通知已就绪的控制器（状态机保证 Ready 意味着初始化完成）
    if (listener) {
      for (const controller of this.controllers) {
        if (controller.isReady()) {
          listener.deviceAdded(controller);
        }
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
    const requestGeneration: number = this.lifecycleGeneration;
    if (!this.isLifecycleActive(requestGeneration)) {
      return;
    }
    console.info(`${TAG} 手动触发设备重新扫描`);
    // 清空已处理设备列表，强制重新枚举所有设备
    this.processedDevices.clear();
    await this.enumerateDevices(requestGeneration);
  }
  
  /**
   * 启动服务
   */
  async start(): Promise<void> {
    if (!this.startRequested) {
      this.startRequested = true;
      this.lifecycleGeneration++;
    }
    const requestGeneration = this.lifecycleGeneration;

    // All callers share the active transition. If stop() cancels it and a later
    // start() requests a new generation, that generation starts after this one.
    while (this.pendingStart !== null) {
      const activeStart = this.pendingStart;
      await activeStart;
      if (!this.isStartRequestCurrent(requestGeneration)) {
        return;
      }
    }

    if (!this.isStartRequestCurrent(requestGeneration)) {
      return;
    }
    if (this.started) {
      console.info(`${TAG} 服务已启动`);
      return;
    }

    const activeStart = this.startInternal(requestGeneration);
    this.pendingStart = activeStart;
    try {
      await activeStart;
    } finally {
      if (this.pendingStart === activeStart) {
        this.pendingStart = null;
      }
    }
  }

  private isStartRequestCurrent(requestGeneration: number): boolean {
    return this.startRequested && this.lifecycleGeneration === requestGeneration;
  }

  private isLifecycleActive(requestGeneration: number): boolean {
    return this.started && this.isStartRequestCurrent(requestGeneration);
  }

  private async startInternal(requestGeneration: number): Promise<void> {
    if (this.pendingControllerStops !== null) {
      const pendingStops = this.pendingControllerStops;
      await pendingStops;
      if (this.pendingControllerStops === pendingStops) {
        this.pendingControllerStops = null;
      }
    }

    if (!this.isStartRequestCurrent(requestGeneration)) {
      return;
    }

    console.info(`${TAG} 启动 USB 驱动服务`);
    
    // 订阅 USB 设备插拔事件
    await this.subscribeUsbEvents(requestGeneration);
    if (!this.isStartRequestCurrent(requestGeneration)) {
      this.unsubscribeUsbEvents();
      return;
    }

    this.started = true;

    // 枚举已连接的设备
    await this.enumerateDevices(requestGeneration);
    if (!this.isLifecycleActive(requestGeneration)) {
      return;
    }

    if (this.pendingResetDeviceKeys.size === 0) {
      this.cancelResetTimer();
    }

    // 启动定期重新扫描定时器
    this.startRescanTimer(requestGeneration);
  }
  
  /**
   * 启动定期重新扫描定时器
   * 用于检测从省电模式唤醒或重新连接的设备
   */
  private startRescanTimer(requestGeneration: number): void {
    if (this.rescanTimerId !== null) {
      return;
    }
    
    console.info(`${TAG} 启动设备重新扫描定时器，间隔 ${UsbDriverService.RESCAN_INTERVAL_MS}ms`);
    this.rescanTimerId = setInterval(() => {
      this.checkAndRescanDevices(requestGeneration);
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
  private async checkAndRescanDevices(requestGeneration: number): Promise<void> {
    if (!this.isLifecycleActive(requestGeneration)) {
      return;
    }

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
        await this.enumerateDevices(requestGeneration);
      }
    } catch (err) {
      console.error(`${TAG} 检查设备状态失败:`, err);
    }
  }
  
  /**
   * 订阅 USB 设备插拔事件
   */
  private async subscribeUsbEvents(requestGeneration: number): Promise<void> {
    try {
      const subscribeInfo: commonEventManager.CommonEventSubscribeInfo = {
        events: [USB_DEVICE_ATTACHED, USB_DEVICE_DETACHED]
      };
      
      const subscriber: commonEventManager.CommonEventSubscriber =
        await commonEventManager.createSubscriber(subscribeInfo);
      if (!this.isStartRequestCurrent(requestGeneration)) {
        return;
      }
      this.usbSubscriber = subscriber;
      
      commonEventManager.subscribe(subscriber, (err, data) => {
        if (err) {
          console.error(`${TAG} USB 事件接收错误:`, err);
          return;
        }
        if (!this.isLifecycleActive(requestGeneration)) {
          return;
        }
        
        console.info(`${TAG} 收到 USB 事件: ${data.event}`);
        
        if (data.event === USB_DEVICE_ATTACHED) {
          // 设备插入，延迟处理以等待系统稳定
          console.info(`${TAG} USB 设备已插入，延迟 500ms 后枚举设备`);
          setTimeout(() => {
            this.enumerateDevices(requestGeneration);
          }, 500);
        } else if (data.event === USB_DEVICE_DETACHED) {
          // 设备拔出，检查控制器状态
          console.info(`${TAG} USB 设备已拔出，检查控制器状态`);
          this.checkDetachedControllers(requestGeneration);
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
  private checkDetachedControllers(requestGeneration: number): void {
    if (!this.isLifecycleActive(requestGeneration)) {
      return;
    }

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
    this.startRequested = false;
    this.lifecycleGeneration++;
    this.cancelResetTimer();

    if (!this.started) {
      this.schedulePendingReset();
      return;
    }
    
    const controllerCount = this.controllers.length;
    console.info(`${TAG} 停止 USB 驱动服务，需释放 ${controllerCount} 个控制器`);
    this.started = false;
    
    // 停止定期重新扫描定时器
    this.stopRescanTimer();
    
    // 取消订阅 USB 事件
    this.unsubscribeUsbEvents();
    
    // 保存已处理设备的键值，用于后续内核驱动重绑定
    const releasedDeviceKeys = new Set(this.processedDevices);
    releasedDeviceKeys.forEach((deviceKey: string): void => {
      this.pendingResetDeviceKeys.add(deviceKey);
    });
    
    // 停止所有控制器（释放 USB 接口独占 + 关闭管道）。DualSense 的
    // stop() 会异步等待最终 Off 报告，因此保存完成 Promise 供下一次 start() 等待。
    let stoppedCount = 0;
    const stopPromises: Promise<void>[] = [];
    while (this.controllers.length > 0) {
      const controller = this.controllers.shift();
      if (controller) {
        console.info(`${TAG} 释放控制器: ${controller.getName()} (VID=0x${controller.getVendorId().toString(16)}, PID=0x${controller.getProductId().toString(16)})`);
        controller.stop();
        stopPromises.push(controller.waitForStop());
        stoppedCount++;
      }
    }
    this.pendingControllerStops = Promise.all(stopPromises).then((): void => {});
    
    this.processedDevices.clear();
    console.info(`${TAG} USB 驱动服务已停止，已释放 ${stoppedCount} 个控制器的 USB 独占`);
    
    // 尝试触发内核 HID 驱动重新绑定。DDK 模式下跳过重绑定，避免下次
    // 启动时 ClaimInterface 竞争；待后续非 DDK 停止时再处理保留的 key。
    if (!this.ddkEnabled) {
      this.schedulePendingReset();
    } else {
      console.info(`${TAG} DDK 模式，跳过内核 HID 驱动重绑定`);
    }
    
    this.ddkEnabled = false;
  }

  private schedulePendingReset(): void {
    const pendingStops: Promise<void> | null = this.pendingControllerStops;
    if (pendingStops !== null) {
      if (this.pendingResetWait === pendingStops) {
        return;
      }
      this.pendingResetWait = pendingStops;
      pendingStops.then((): void => {
        if (this.pendingControllerStops === pendingStops) {
          this.pendingControllerStops = null;
        }
        if (this.pendingResetWait === pendingStops) {
          this.pendingResetWait = null;
        }
        this.schedulePendingReset();
      });
      return;
    }

    this.cancelResetTimer();
    if (this.ddkEnabled || this.pendingResetDeviceKeys.size === 0) {
      return;
    }

    const releasedKeys: Set<string> = new Set(this.pendingResetDeviceKeys);
    this.resetTimerId = setTimeout(() => {
      this.resetTimerId = null;
      const completedKeys: Set<string> = this.resetReleasedUsbDevices(releasedKeys);
      completedKeys.forEach((deviceKey: string): void => {
        this.pendingResetDeviceKeys.delete(deviceKey);
      });
    }, UsbDriverService.USB_RESET_DELAY_MS);
  }

  private cancelResetTimer(): void {
    if (this.resetTimerId !== null) {
      clearTimeout(this.resetTimerId);
      this.resetTimerId = null;
    }
  }
  
  /**
   * 尝试重置已释放的 USB 设备，使系统 HID 驱动重新绑定
   * 
   * 工作原理：
   * 1. 重新连接设备获取文件描述符
   * 2. 通过 ioctl(USBDEVFS_IOCTL + USBDEVFS_CONNECT) 通知内核重绑定接口驱动
   *    等价于 libusb_attach_kernel_driver()
   * 3. 如果 CONNECT 失败，后备方案使用 USBDEVFS_RESET 重置设备
   */
  private resetReleasedUsbDevices(releasedKeys: Set<string>): Set<string> {
    const completedKeys: Set<string> = new Set();
    if (!usbHelper) {
      console.warn(`${TAG} UsbHelper native 模块不可用，无法重绑定内核驱动`);
      return completedKeys;
    }
    
    try {
      const devices: usbManager.USBDevice[] = usbManager.getDevices();
      const presentKeys: Set<string> = new Set();
      let resetCount = 0;
      
      for (let i = 0; i < devices.length; i++) {
        const device = devices[i];
        const key = `${device.vendorId}:${device.productId}:${device.busNum}:${device.devAddress}`;
        presentKeys.add(key);
        
        if (!releasedKeys.has(key)) continue;
        if (!this.deviceHasHidInterface(device)) continue;

        // A new lifecycle may already own this device. Rebinding it here would
        // race the active controller, so only finish the pending bookkeeping.
        const activeController = this.controllers.find(
          (controller: AbstractController): boolean =>
            controller.getDeviceKey() === key && controller.isConnected()
        );
        if (activeController) {
          completedKeys.add(key);
          continue;
        }
        
        try {
          // 检查权限（之前已授权，应该仍然有效）
          if (!usbManager.hasRight(device.name)) {
            console.warn(`${TAG} 设备重置跳过（无权限）: ${device.name}`);
            continue;
          }
          
          // 重新连接设备
          const pipe = usbManager.connectDevice(device);
          
          // 获取文件描述符并重绑定内核驱动
          const fd = usbManager.getFileDescriptor(pipe);
          
          // 对每个 HID 接口调用 native ioctl 重绑定内核驱动
          if (fd >= 0 && device.configs) {
            for (let ci = 0; ci < device.configs.length; ci++) {
              const config = device.configs[ci];
              if (!config.interfaces) continue;
              for (let ii = 0; ii < config.interfaces.length; ii++) {
                const iface = config.interfaces[ii];
                if (iface.clazz === 3) { // USB_CLASS_HID
                  usbHelper.reattachKernelDriver(fd, iface.id);
                }
              }
            }
          }
          
          // 关闭连接
          usbManager.closePipe(pipe);
          resetCount++;
          completedKeys.add(key);
          console.info(`${TAG} USB 设备内核驱动重绑定完成: ${device.name}`);
        } catch (e) {
          console.warn(`${TAG} USB 设备重置失败 (${device.name}):`, e);
        }
      }
      
      if (resetCount > 0) {
        console.info(`${TAG} 已尝试重绑定 ${resetCount} 个 USB 设备的内核 HID 驱动`);
      }
      releasedKeys.forEach((deviceKey: string): void => {
        if (!presentKeys.has(deviceKey)) {
          completedKeys.add(deviceKey);
        }
      });
    } catch (e) {
      console.warn(`${TAG} resetReleasedUsbDevices 异常:`, e);
    }
    return completedKeys;
  }
  
  /**
   * 检查设备是否包含 HID 接口
   */
  private deviceHasHidInterface(device: usbManager.USBDevice): boolean {
    if (!device.configs) return false;
    for (let ci = 0; ci < device.configs.length; ci++) {
      const config = device.configs[ci];
      if (!config.interfaces) continue;
      for (let ii = 0; ii < config.interfaces.length; ii++) {
        if (config.interfaces[ii].clazz === 3) return true; // USB_CLASS_HID
      }
    }
    return false;
  }
  
  /**
   * 枚举 USB 设备
   */
  private async enumerateDevices(requestGeneration: number): Promise<void> {
    if (!this.isLifecycleActive(requestGeneration)) {
      return;
    }

    try {
      const devices: usbManager.USBDevice[] = usbManager.getDevices();
      console.info(`${TAG} 发现 ${devices.length} 个 USB 设备`);
      
      for (let i: number = 0; i < devices.length; i++) {
        if (!this.isLifecycleActive(requestGeneration)) {
          return;
        }
        const device: usbManager.USBDevice = devices[i];
        await this.handleUsbDevice(device, requestGeneration);
      }
    } catch (err) {
      console.error(`${TAG} 枚举设备失败:`, err);
    }
  }
  
  /**
   * 处理 USB 设备
   */
  private async handleUsbDevice(device: usbManager.USBDevice, requestGeneration: number): Promise<void> {
    if (!this.isLifecycleActive(requestGeneration)) {
      return;
    }

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
        // 控制器已断开；等待异步输出复位和 pipe 释放后再重建。
        console.info(`${TAG} 检测到旧控制器已断开，等待释放后重新创建: ${deviceKey}`);
        existingController.stop();
        await existingController.waitForStop();
        if (!this.isLifecycleActive(requestGeneration)) return;
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

        if (!this.isLifecycleActive(requestGeneration)) {
          return;
        }
        
        if (!granted) {
          console.warn(`${TAG} 用户拒绝了 USB 权限: ${device.name}`);
          // 标记为已处理，避免 rescan 反复弹出权限对话框
          this.processedDevices.add(deviceKey);
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
    
    // 异步操作后检查服务是否已停止（权限弹窗期间用户可能退出）
    if (!this.isLifecycleActive(requestGeneration)) {
      console.info(`${TAG} 服务已停止，放弃处理设备: ${device.name}`);
      return;
    }

    // Read settings before opening the pipe so cancellation or a settings error
    // cannot strand a locally owned USB transport.
    const inputSettings = await SettingsService.getInstance().getInputSettings();
    if (!this.isLifecycleActive(requestGeneration)) {
      return;
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
      controller.setDeviceLocation(device.busNum, device.devAddress, device.serial || '', device.name || '');

      // 应用 DDK 高速轮询设置
      console.info(`${TAG} DDK 高速轮询设置: ${inputSettings.ddkHighSpeedPolling}`);
      if (inputSettings.ddkHighSpeedPolling) {
        this.ddkEnabled = true;
        controller.setDdkPollingEnabled(true);
        console.info(`${TAG} 设备 ${device.name} 已启用 DDK 高速轮询`);
      }
      
      console.info(`${TAG} 使用驱动 [${driverName}] 处理设备: ${device.name}, Key=${controller.getDeviceKey()}`);
    } else {
      console.warn(`${TAG} 无法为设备创建控制器: ${device.name}`);
      usbManager.closePipe(pipe);
      return;
    }
    
    // 先加入列表和已处理集合（确保 start() 内的同步通知能在列表中找到控制器）
    this.processedDevices.add(deviceKey);
    this.controllers.push(controller);
    
    // 启动控制器
    if (!controller.start()) {
      console.error(`${TAG} 启动控制器失败`);
      this.controllers.pop();
      this.processedDevices.delete(deviceKey);
      usbManager.closePipe(pipe);
      return;
    }

    this.pendingResetDeviceKeys.delete(deviceKey);
    
    console.info(`${TAG} 控制器已启动: ID=${controller.getControllerId()}, Key=${deviceKey}`);
  }
  
  /**
   * 检查是否应该驱动该设备
   */
  private shouldClaimDevice(device: usbManager.USBDevice): boolean {
    return UsbDriverService.identifyKnownGamepad(device) !== null;
  }

  /**
   * 识别已知 USB 手柄类型（不副作用，仅 VID/PID/接口判定）
   * @returns 友好名称（如 "Xbox One Controller"），不识别时返回 null
   */
  static identifyKnownGamepad(device: usbManager.USBDevice): string | null {
    if (XboxOneController.canClaimDevice(device)) return 'Xbox One Controller';
    if (Xbox360Controller.canClaimDevice(device)) return 'Xbox 360 Controller';
    if (SwitchProController.canClaimDevice(device)) return 'Switch Pro Controller';
    if (DualSenseController.canClaimDevice(device)) return 'DualSense Controller';
    if (Dualshock4Controller.canClaimDevice(device)) return 'DualShock 4 Controller';
    if (NativeHidController.canClaimDevice(device)) return device.name || 'HID Controller';
    return null;
  }

  /**
   * 列出所有可识别的 USB 手柄（不修改服务状态）
   */
  static listKnownUsbGamepads(): KnownUsbGamepadInfo[] {
    const result: KnownUsbGamepadInfo[] = [];
    try {
      // 模拟器/无 USB 权限场景下 getDevices() 可能返回 undefined
      const devices: usbManager.USBDevice[] | undefined = usbManager.getDevices();
      if (!devices || devices.length === 0) {
        return result;
      }
      for (let i = 0; i < devices.length; i++) {
        const d = devices[i];
        const name = UsbDriverService.identifyKnownGamepad(d);
        if (name !== null) {
          result.push({
            name,
            vendorId: d.vendorId,
            productId: d.productId,
            deviceKey: `${d.vendorId}:${d.productId}:${d.busNum}:${d.devAddress}`,
          });
        }
      }
    } catch (err) {
      console.warn(`${TAG} listKnownUsbGamepads 异常:`, err);
    }
    return result;
  }

  /**
   * 当前已驱动控制器的 deviceKey 集合
   */
  getActiveDeviceKeys(): Set<string> {
    const keys = new Set<string>();
    for (const c of this.controllers) {
      if (c.isConnected()) {
        keys.add(c.getDeviceKey());
      }
    }
    return keys;
  }
  
  /**
   * 刷新设备列表
   */
  async refreshDevices(): Promise<void> {
    const requestGeneration: number = this.lifecycleGeneration;
    if (!this.isLifecycleActive(requestGeneration)) {
      return;
    }
    
    console.info(`${TAG} 刷新 USB 设备列表`);
    await this.enumerateDevices(requestGeneration);
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

  reportTouchpadInput(
    controllerId: number,
    active: boolean,
    x: number,
    y: number
  ): void {
    if (this.listener) {
      this.listener.reportTouchpadInput(controllerId, active, x, y);
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
