/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { TouchMode } from '../viewmodel/StreamViewModel';

/** Shared labels and descriptions for every touch-mode picker. */
export interface TouchModeMenuOption {
  key: TouchMode;
  title: string;
  subtitle: string;
}

export const TOUCH_MODE_MENU_OPTIONS: TouchModeMenuOption[] = [
  {
    key: TouchMode.TRACKPAD,
    title: '触控板',
    subtitle: '像笔记本触控板一样操作'
  },
  {
    key: TouchMode.DIRECT,
    title: '多点触控',
    subtitle: '直接点击屏幕位置'
  },
  {
    key: TouchMode.MOUSE,
    title: '触摸鼠标',
    subtitle: '模拟鼠标移动和点击'
  },
  {
    key: TouchMode.DS5_TOUCHPAD_ZONE,
    title: 'DS5 区域触控板',
    subtitle: '仅使用屏幕底部区域，区域外保留普通多点触控'
  }
];

export function getTouchModeMenuTitle(mode: TouchMode): string {
  for (const option of TOUCH_MODE_MENU_OPTIONS) {
    if (option.key === mode) return option.title;
  }
  return mode;
}
