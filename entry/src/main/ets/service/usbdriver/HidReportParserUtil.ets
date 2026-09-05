/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * 本程序基于 GPL-3.0 发布，详见 LICENSE
 */

/**
 * 共享 HID 报文解析工具
 *
 * 从 NativeHidController 抽取，供多条输入通道复用
 * （usbManager bulkTransfer / HID DDK hidraw 等）：
 * native Gamepad.parseHidReport 优先，失败时走通用布局 TS 兜底。
 */

import { ButtonFlags } from './ControllerConstants';
import { AXIS_MAX, TRIGGER_MAX } from '../input/GamepadTypes';
import { NativeHidParserService, NativeButtonFlags } from './NativeHidParserService';

const TAG = '[HID-Parser-Util]';

/**
 * 解析后的控制器状态（Moonlight 归一化格式）
 * 轴 -1.0..1.0，扳机 0.0..1.0，buttonFlags 为 Moonlight ButtonFlags
 */
export interface ParsedHidState {
  buttonFlags: number;
  leftStickX: number;
  leftStickY: number;
  rightStickX: number;
  rightStickY: number;
  leftTrigger: number;
  rightTrigger: number;
}

export class HidReportParserUtil {

  private static parser: NativeHidParserService | null = null;

  private static getParser(): NativeHidParserService {
    if (!HidReportParserUtil.parser) {
      const parser = NativeHidParserService.getInstance();
      parser.init();
      HidReportParserUtil.parser = parser;
    }
    return HidReportParserUtil.parser;
  }

  /**
   * 解析原始 HID 报文为 Moonlight 归一化状态
   *
   * @param vendorId  设备 VID
   * @param productId 设备 PID
   * @param data      原始报文字节
   * @param forceProtocolType 0=自动, 1=Xbox, 2=DS4, 3=Switch, 4=Generic, 5=DualSense
   * @returns 解析结果；两条路径都失败时返回 null
   */
  static parseToState(vendorId: number, productId: number, data: Uint8Array,
    forceProtocolType: number = 0): ParsedHidState | null {
    const state = HidReportParserUtil.getParser().parseHidReport(vendorId, productId, data, forceProtocolType);
    if (state) {
      return {
        buttonFlags: HidReportParserUtil.convertNativeButtons(state.buttons),
        leftStickX: state.leftStickX / AXIS_MAX,
        leftStickY: state.leftStickY / AXIS_MAX,
        rightStickX: state.rightStickX / AXIS_MAX,
        rightStickY: state.rightStickY / AXIS_MAX,
        leftTrigger: state.leftTrigger / TRIGGER_MAX,
        rightTrigger: state.rightTrigger / TRIGGER_MAX
      };
    }
    return HidReportParserUtil.parseFallbackLayout(data);
  }

  /**
   * 通用 HID 手柄布局兜底解析（与原 NativeHidController.fallbackParseHidReport 布局一致）
   *
   * 布局 (≥9 字节):
   * [0] Report ID  [1-4] 左/右摇杆 XY (0x80=中心)  [5] Triggers/misc
   * [6] HAT/D-Pad (0x0F=中心)  [7] 功能按钮字节  [8] 面板按钮字节
   */
  static parseFallbackLayout(data: Uint8Array): ParsedHidState | null {
    if (data.length < 9) {
      console.warn(`${TAG} HID 数据太短: ${data.length}`);
      return null;
    }

    const clamp = (v: number): number => Math.max(-1.0, Math.min(1.0, v));
    const leftStickX = clamp((data[1] - 128) / 127.0);
    const leftStickY = clamp((data[2] - 128) / 127.0);
    const rightStickX = clamp((data[3] - 128) / 127.0);
    const rightStickY = clamp((data[4] - 128) / 127.0);

    let flags = 0;
    const hat = data[6] & 0x0F;
    switch (hat) {
      case 0: flags |= ButtonFlags.UP_FLAG; break;
      case 1: flags |= ButtonFlags.UP_FLAG | ButtonFlags.RIGHT_FLAG; break;
      case 2: flags |= ButtonFlags.RIGHT_FLAG; break;
      case 3: flags |= ButtonFlags.DOWN_FLAG | ButtonFlags.RIGHT_FLAG; break;
      case 4: flags |= ButtonFlags.DOWN_FLAG; break;
      case 5: flags |= ButtonFlags.DOWN_FLAG | ButtonFlags.LEFT_FLAG; break;
      case 6: flags |= ButtonFlags.LEFT_FLAG; break;
      case 7: flags |= ButtonFlags.UP_FLAG | ButtonFlags.LEFT_FLAG; break;
      default: break; // 0x0F = center
    }

    const btn1 = data[7];
    const btn2 = data[8];
    if (btn1 & 0x01) flags |= ButtonFlags.BACK_FLAG;
    if (btn1 & 0x02) flags |= ButtonFlags.PLAY_FLAG;
    if (btn1 & 0x04) flags |= ButtonFlags.SPECIAL_BUTTON_FLAG;
    if (btn1 & 0x08) flags |= ButtonFlags.LS_CLK_FLAG;
    if (btn1 & 0x10) flags |= ButtonFlags.RS_CLK_FLAG;
    if (btn1 & 0x20) flags |= ButtonFlags.LB_FLAG;
    if (btn1 & 0x40) flags |= ButtonFlags.RB_FLAG;
    if (btn2 & 0x01) flags |= ButtonFlags.A_FLAG;
    if (btn2 & 0x02) flags |= ButtonFlags.B_FLAG;
    if (btn2 & 0x04) flags |= ButtonFlags.X_FLAG;
    if (btn2 & 0x08) flags |= ButtonFlags.Y_FLAG;

    return {
      buttonFlags: flags,
      leftStickX, leftStickY, rightStickX, rightStickY,
      leftTrigger: 0,
      rightTrigger: 0
    };
  }

  /**
   * native 按钮位 → Moonlight ButtonFlags（与原 NativeHidController.convertNativeButtons 一致）
   */
  static convertNativeButtons(nativeButtons: number): number {
    let flags = 0;

    if (nativeButtons & NativeButtonFlags.UP) flags |= ButtonFlags.UP_FLAG;
    if (nativeButtons & NativeButtonFlags.DOWN) flags |= ButtonFlags.DOWN_FLAG;
    if (nativeButtons & NativeButtonFlags.LEFT) flags |= ButtonFlags.LEFT_FLAG;
    if (nativeButtons & NativeButtonFlags.RIGHT) flags |= ButtonFlags.RIGHT_FLAG;

    if (nativeButtons & NativeButtonFlags.START) flags |= ButtonFlags.PLAY_FLAG;
    if (nativeButtons & NativeButtonFlags.BACK) flags |= ButtonFlags.BACK_FLAG;
    if (nativeButtons & NativeButtonFlags.LS_CLK) flags |= ButtonFlags.LS_CLK_FLAG;
    if (nativeButtons & NativeButtonFlags.RS_CLK) flags |= ButtonFlags.RS_CLK_FLAG;

    if (nativeButtons & NativeButtonFlags.LB) flags |= ButtonFlags.LB_FLAG;
    if (nativeButtons & NativeButtonFlags.RB) flags |= ButtonFlags.RB_FLAG;

    if (nativeButtons & NativeButtonFlags.A) flags |= ButtonFlags.A_FLAG;
    if (nativeButtons & NativeButtonFlags.B) flags |= ButtonFlags.B_FLAG;
    if (nativeButtons & NativeButtonFlags.X) flags |= ButtonFlags.X_FLAG;
    if (nativeButtons & NativeButtonFlags.Y) flags |= ButtonFlags.Y_FLAG;

    if (nativeButtons & NativeButtonFlags.HOME) flags |= ButtonFlags.SPECIAL_BUTTON_FLAG;

    return flags;
  }
}
