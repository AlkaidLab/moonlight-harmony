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
 * 自定义按键覆盖层常量与工具函数
 *
 * 编辑模式相关的颜色常量、预设色板、辅助接口和振动反馈函数。
 */

import { DeviceVibrationCoordinator } from '../service/input/DeviceVibrationCoordinator';

// =============================================================================
// 接口
// =============================================================================

/** 数字摇杆每个按键的四方向按下状态 */
export interface DigitalDirState {
  up: boolean;
  down: boolean;
  left: boolean;
  right: boolean;
}

/** 吸附计算结果 */
export interface SnapResult {
  /** 吸附后的 vp 偏移 X */
  dx: number;
  /** 吸附后的 vp 偏移 Y */
  dy: number;
}

// =============================================================================
// 常量
// =============================================================================

export const EDIT_BORDER_COLOR = '#80FF6B6B';
export const SELECT_BORDER_COLOR = '#FFFFD700';
export const EDIT_TOOLBAR_HEIGHT = 48;
export const DRAG_THRESHOLD = 5;

/** 预设颜色：背景色 */
export const BG_COLOR_PRESETS: string[] = [
  '#401A1A2E', '#40A8D8EA', '#40FF6B6B', '#4050C080',
  '#40FFD700', '#40D06060', '#406098C0', '#40FF8C00',
];

/** 预设颜色：文字色 */
export const TEXT_COLOR_PRESETS: string[] = [
  '#E0FFFFFF', '#FFFFD700', '#FFA8D8EA', '#FFFF6B6B',
  '#FF50C080', '#FFFF8C00', '#FFD06060', '#FF6098C0',
];

/** 预设颜色：按压色 */
export const PRESSED_COLOR_PRESETS: string[] = [
  '#80A8D8EA', '#80FF6B6B', '#8050C080', '#80FFD700',
  '#80D06060', '#806098C0', '#80FF8C00', '#80E070E0',
];

/** 振动等级选项 */
export const HAPTIC_OPTIONS: Array<[string, string]> = [
  ['none', '无'], ['light', '轻'], ['medium', '中'], ['heavy', '重'],
];

// =============================================================================
// 工具函数
// =============================================================================

/** 根据 haptic 等级触发振动 */
export function doKeyHaptic(level: string): void {
  let duration = 0;
  switch (level) {
    case 'light': duration = 15; break;
    case 'medium': duration = 40; break;
    case 'heavy': duration = 80; break;
    default: return;
  }
  DeviceVibrationCoordinator.getInstance().playTouchHaptic(duration);
}

// =============================================================================
// 按钮图标预设（Phosphor Bold SVG）
// =============================================================================

/** 按钮图标预设项 */
export interface ButtonIconPreset {
  /** 存储标识 */
  key: string;
  /** 显示名称 */
  label: string;
  /** 资源引用 */
  resource: Resource;
}

/** 按钮图标预设列表 */
export const BUTTON_ICON_PRESETS: ButtonIconPreset[] = [
  { key: 'crosshair', label: '准星', resource: $r('app.media.ic_crosshair') },
  { key: 'sword', label: '武器', resource: $r('app.media.ic_sword') },
  { key: 'shield', label: '盾牌', resource: $r('app.media.ic_shield') },
  { key: 'heart', label: '血量', resource: $r('app.media.ic_heart') },
  { key: 'star', label: '技能', resource: $r('app.media.ic_star') },
  { key: 'lightning', label: '闪电', resource: $r('app.media.ic_lightning') },
  { key: 'eye', label: '视野', resource: $r('app.media.ic_eye') },
  { key: 'map_pin', label: '标记', resource: $r('app.media.ic_map_pin') },
  { key: 'bag', label: '背包', resource: $r('app.media.ic_bag') },
  { key: 'crown', label: '王冠', resource: $r('app.media.ic_crown') },
  { key: 'gamepad', label: '手柄', resource: $r('app.media.ic_gamepad') },
  { key: 'keyboard', label: '键盘', resource: $r('app.media.ic_keyboard') },
  { key: 'mouse', label: '鼠标', resource: $r('app.media.ic_mouse') },
  { key: 'touch', label: '触控', resource: $r('app.media.ic_touch') },
  { key: 'settings', label: '设置', resource: $r('app.media.ic_settings') },
  { key: 'play', label: '播放', resource: $r('app.media.ic_play') },
  { key: 'refresh', label: '刷新', resource: $r('app.media.ic_refresh') },
  { key: 'arrow_clockwise', label: '循环', resource: $r('app.media.ic_arrow_clockwise') },
  { key: 'list', label: '列表', resource: $r('app.media.ic_list') },
  { key: 'visibility_off', label: '隐藏', resource: $r('app.media.ic_visibility_off') },
  { key: 'lightbulb', label: '灯泡', resource: $r('app.media.ic_lightbulb') },
  { key: 'scan', label: '扫描', resource: $r('app.media.ic_scan') },
  { key: 'microphone', label: '麦克风', resource: $r('app.media.ic_microphone') },
  { key: 'audio', label: '音频', resource: $r('app.media.ic_audio') },
];

/** 按 key 查找图标资源（返回 undefined 表示不是预设图标） */
export function getButtonIconResource(key: string): Resource | undefined {
  for (const preset of BUTTON_ICON_PRESETS) {
    if (preset.key === key) return preset.resource;
  }
  return undefined;
}
