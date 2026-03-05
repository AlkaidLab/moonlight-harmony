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
 * 游戏覆盖层公共常量
 *
 * 用于所有渲染在游戏画面上的 UI 组件（GameMenuDialog、PerformanceOverlay、
 * ShortcutEditorDialog、CustomKeyOverlay、VirtualKeyboard 等）。
 *
 * 这些组件不能使用 AppColors 主题色（主题色针对 app 背景设计），
 * 而需要在任何游戏画面上都可读的半透明配色。
 */

// =============================================================================
// 颜色
// =============================================================================

/** 覆盖层强调色 */
export const OV_ACCENT_BLUE = '#A8D8EA';        // 主强调色 - 浅蓝
export const OV_ACCENT_PINK = '#FFB7C5';        // 辅助强调色 - 粉
export const OV_ACCENT_GOLD = '#FFD700';        // 金色强调
export const OV_ACCENT_RED = '#EF4444';         // 危险/退出

/** 覆盖层文字色（白色 + 不同透明度） */
export const OV_TEXT_BRIGHT = '#E0FFFFFF';       // 标题/重要文字
export const OV_TEXT_MEDIUM = '#B0FFFFFF';       // 正文/标签
export const OV_TEXT_DIM = '#80FFFFFF';          // 辅助/提示
export const OV_TEXT_FAINT = '#60FFFFFF';        // 范围标记/极弱提示
export const OV_TEXT_WHITE = '#FFFFFF';          // 纯白（图标、按钮文字）
export const OV_TEXT_ULTRA = '#F0FFFFFF';        // 接近纯白
export const OV_TEXT_SUBTLE = '#CCFFFFFF';       // 偏弱白

/** 覆盖层背景色 */
export const OV_BG_TRACK = '#30FFFFFF';          // Slider 轨道/输入框背景
export const OV_BG_CARD_LIGHT = '#25FFFFFF';     // 浅色卡片背景
export const OV_BG_CARD_LIGHTER = '#20FFFFFF';   // 更浅卡片背景
export const OV_BG_DIVIDER = '#15FFFFFF';        // 分割线
export const OV_BG_CARD_DARK = '#20000000';      // 深色卡片背景
export const OV_BG_CARD_DARKER = '#15000000';    // 更深卡片背景

/** 覆盖层阴影色 */
export const OV_SHADOW_MEDIUM = '#10000000';     // 标准阴影
export const OV_SHADOW_LIGHT = '#08000000';      // 浅阴影

/** 覆盖层蓝色透明变体 */
export const OV_BLUE_20 = '#20A8D8EA';           // 蓝色 20% - 选中态背景
export const OV_BLUE_40 = '#40A8D8EA';           // 蓝色 40% - 发光/阴影
export const OV_BLUE_50 = '#50A8D8EA';           // 蓝色 50% - 选中边框
export const OV_BLUE_80 = '#80A8D8EA';           // 蓝色 80% - 强调边框

/** 覆盖层粉色透明变体 */
export const OV_PINK_40 = '#40FFB7C5';           // 粉色 40% - 发光

// =============================================================================
// 字体大小
// =============================================================================

/** 覆盖层字体大小 */
export const OV_FONT_XS = 9;                    // 范围标记、极小说明
export const OV_FONT_SM = 10;                   // 辅助说明、副标题
export const OV_FONT_MD = 11;                   // 正文/卡片标签
export const OV_FONT_LG = 13;                   // 标题/菜单项
export const OV_FONT_XL = 15;                   // 大标题

// =============================================================================
// 卡片尺寸
// =============================================================================

/** 标准卡片宽度 (vp) */
export const OV_CARD_WIDTH = 280;
/** 标准卡片圆角 */
export const OV_CARD_RADIUS = 20;
/** 标准毛玻璃模糊度 */
export const OV_CARD_BLUR = 40;
/** 标准分割线高度 */
export const OV_DIVIDER_HEIGHT = 1;
/** 分割线标准宽度比例 */
export const OV_DIVIDER_WIDTH = '85%';
