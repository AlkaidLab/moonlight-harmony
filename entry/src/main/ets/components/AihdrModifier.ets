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
 * AIHDR 修饰器
 *
 * 通过 attributeModifier 隔离 XComponent.hdrBrightness(brightness) 调用。
 * 使用 @Available 注解将 @since 24 API 在 compatibleSdkVersion < 24 时从编译错误降级为警告，
 * 并在运行时通过 deviceInfo.sdkApiVersion 守卫，确保低版本设备不会执行该路径。
 */
import { deviceInfo, Available } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';

/** hdrCapability.HDRFormat.VIDEO_AIHDR 的枚举值 (@since 24)，用字面量避免编译期 @since 门控 */
const HDR_FORMAT_VIDEO_AIHDR: number = 8;

/**
 * 查询当前设备是否支持 AIHDR。
 * 需同时满足：系统 API 版本 >= 24 且默认显示屏支持的 HDR 格式包含 VIDEO_AIHDR。
 */
export function isAihdrSupported(): boolean {
  if (deviceInfo.sdkApiVersion < 24) {
    return false;
  }
  try {
    const formats: Array<number> = display.getDefaultDisplaySync().hdrFormats as Array<number>;
    return formats?.some((f: number): boolean => f === HDR_FORMAT_VIDEO_AIHDR) ?? false;
  } catch (e) {
    return false;
  }
}

export class AihdrModifier implements AttributeModifier<XComponentAttribute> {
  /** 是否启用 AIHDR */
  public enabled: boolean = false;
  /** HDR 峰值亮度系数 (1.0 = 系统默认) */
  public brightness: number = 1.0;

  @Available({ minApiVersion: '24' })
  applyNormalAttribute(instance: XComponentAttribute): void {
    if (this.enabled && deviceInfo.sdkApiVersion >= 24) {
      instance.hdrBrightness(this.brightness);
    }
  }
}
