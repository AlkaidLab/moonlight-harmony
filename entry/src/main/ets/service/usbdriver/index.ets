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
 * USB Driver 模块导出
 */

export { AbstractController } from './AbstractController';
export { UsbDriverListener, UsbDriverStateListener } from './UsbDriverListener';
export { UsbDriverService } from './UsbDriverService';
export { Xbox360Controller } from './Xbox360Controller';
export { XboxOneController } from './XboxOneController';
export { Dualshock4Controller } from './Dualshock4Controller';
export { DualSenseController } from './DualSenseController';
export { SwitchProController } from './SwitchProController';
export { NativeHidController } from './NativeHidController';
export { 
  ButtonFlags, 
  ControllerType, 
  ControllerCapabilities, 
  MotionType,
  DPadDirection,
  Xbox360,
  XboxOne,
  DualShock4,
  DualSense,
  SwitchPro
} from './ControllerConstants';

// 原生 HID 解析器
export { NativeHidParserService } from './NativeHidParserService';
export { NativeButtonFlags, NativeGamepadType } from './NativeGamepad';
export type { NativeGamepadState } from './NativeGamepad';

/**
 * 协议类型枚举
 * 用于 NativeHidController.setForceProtocolType()
 */
export enum ProtocolType {
  AUTO = 0,        // 自动检测
  XBOX = 1,        // Xbox 协议
  DS4 = 2,         // DualShock 4 协议
  SWITCH = 3,      // Switch Pro 协议
  GENERIC = 4,     // 通用 HID 协议
  DUALSENSE = 5    // DualSense (PS5) 协议
}
