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
 * 自定义按键数据模型
 *
 * 定义自定义按键的数据结构、按键动作类型和配置档案。
 * 参考 Android 王冠功能架构，使用 TypeScript 类型系统实现类型安全。
 */

// =============================================================================
// 按键动作类型（替代 Android 的字符串前缀 "k123"/"m1" 方案）
// =============================================================================

/** 键盘按键动作 */
export interface KeyboardAction {
  type: 'keyboard';
  /** Windows Virtual-Key Code */
  vk: number;
}

/** 鼠标按键动作 */
export interface MouseButtonAction {
  type: 'mouse';
  /** 鼠标按键: 1=左键, 2=中键, 3=右键, 4=X1, 5=X2 */
  button: number;
}

/** 鼠标滚轮动作 */
export interface MouseScrollAction {
  type: 'mouseScroll';
  /** 滚动方向: 1=上, -1=下 */
  direction: number;
}

/** 手柄按钮动作 */
export interface GamepadButtonAction {
  type: 'gamepadButton';
  /** 按钮位掩码 (参照 MoonBridge 常量) */
  mask: number;
}

/** 手柄扳机动作（LT/RT 模拟量） */
export interface GamepadTriggerAction {
  type: 'gamepadTrigger';
  /** 'left' = LT, 'right' = RT */
  trigger: 'left' | 'right';
}

/** 组合键动作：同时发送多个按键 */
export interface ComboAction {
  type: 'combo';
  actions: KeyAction[];
}

/** 特殊功能动作 */
export interface SpecialAction {
  type: 'special';
  /** 功能 ID */
  id: SpecialActionId;
}

/** 特殊功能枚举 */
export type SpecialActionId =
  | 'toggleKeyboard'     // 切换 PC 键盘
  | 'toggleIME'          // 切换系统输入法
  | 'toggleMouseMode'    // 切换鼠标模式
  | 'switchProfile'      // 切换配置档案
  | 'openGameMenu'       // 打开游戏菜单
  | 'editMode'           // 进入编辑模式
  | 'none';              // 无操作

/** 所有按键动作联合类型 */
export type KeyAction =
  | KeyboardAction
  | MouseButtonAction
  | MouseScrollAction
  | GamepadButtonAction
  | GamepadTriggerAction
  | ComboAction
  | SpecialAction;

// =============================================================================
// 按键外观定义
// =============================================================================

/** 按键形态 */
export type KeyShape = 'rect' | 'circle';

/** 按键行为模式 */
export type KeyBehavior = 'momentary' | 'toggle';

// =============================================================================
// 自定义按键定义
// =============================================================================

/** 自定义按键完整定义 */
export interface CustomKeyDef {
  /** 唯一标识（UUID 或时间戳字符串） */
  id: string;
  /** 显示标签 */
  label: string;
  /** 绑定的按键动作 */
  action: KeyAction;
  /** 形态 */
  shape: KeyShape;
  /** 行为模式 */
  behavior: KeyBehavior;
  /**
   * 中心 X 坐标（百分比 0.0~1.0，相对屏幕宽度）
   * 渲染时: xVp = xPercent * screenWidthVp
   */
  xPercent: number;
  /**
   * 中心 Y 坐标（百分比 0.0~1.0，相对屏幕高度）
   * 渲染时: yVp = yPercent * screenHeightVp
   */
  yPercent: number;
  /** @deprecated 旧绝对坐标，仅用于数据迁移兼容 */
  x?: number;
  /** @deprecated 旧绝对坐标，仅用于数据迁移兼容 */
  y?: number;
  /** 宽度 (vp) — 保持绝对值，不随屏幕缩放 */
  width: number;
  /** 高度 (vp) — 保持绝对值，不随屏幕缩放 */
  height: number;
  /** 层级 (0=最底, 越大越靠前) */
  layer: number;
  /** 透明度 0-100 */
  opacity: number;
  /** 圆角 (vp) */
  borderRadius: number;
  /** 常态边框/前景色 (十六进制) */
  normalColor: string;
  /** 按下时颜色 */
  pressedColor: string;
  /** 背景色 */
  bgColor: string;
  /** 文字颜色 */
  textColor: string;
  /** 文字大小 (fp) */
  fontSize: number;
}

// =============================================================================
// 配置档案
// =============================================================================

/** 按键配置档案 */
export interface CustomKeyProfile {
  /** 配置名称 */
  name: string;
  /** 档案中的所有按键 */
  keys: CustomKeyDef[];
}

// =============================================================================
// 工厂方法
// =============================================================================

/** 生成唯一 ID */
export function generateKeyId(): string {
  return Date.now().toString(36) + Math.random().toString(36).substring(2, 6);
}

/** 浅拷贝一个 CustomKeyDef（ArkTS 不支持 spread 对象字面量） */
export function cloneKeyDef(src: CustomKeyDef): CustomKeyDef {
  const dst: CustomKeyDef = {
    id: src.id,
    label: src.label,
    action: src.action,
    shape: src.shape,
    behavior: src.behavior,
    xPercent: src.xPercent,
    yPercent: src.yPercent,
    width: src.width,
    height: src.height,
    layer: src.layer,
    opacity: src.opacity,
    borderRadius: src.borderRadius,
    normalColor: src.normalColor,
    pressedColor: src.pressedColor,
    bgColor: src.bgColor,
    textColor: src.textColor,
    fontSize: src.fontSize,
  };
  return dst;
}

/** 创建默认按键定义 */
export function createDefaultKeyDef(partial?: Partial<CustomKeyDef>): CustomKeyDef {
  const def: CustomKeyDef = {
    id: generateKeyId(),
    label: 'Key',
    action: { type: 'keyboard', vk: 0x41 } as KeyboardAction, // 默认 A 键
    shape: 'rect',
    behavior: 'momentary',
    xPercent: 0.5,
    yPercent: 0.5,
    width: 60,
    height: 60,
    layer: 0,
    opacity: 80,
    borderRadius: 12,
    normalColor: '#60FFFFFF',
    pressedColor: '#80A8D8EA',
    bgColor: '#30FFFFFF',
    textColor: '#E0FFFFFF',
    fontSize: 14,
  };
  if (partial) {
    if (partial.id !== undefined) def.id = partial.id;
    if (partial.label !== undefined) def.label = partial.label;
    if (partial.action !== undefined) def.action = partial.action;
    if (partial.shape !== undefined) def.shape = partial.shape;
    if (partial.behavior !== undefined) def.behavior = partial.behavior;
    if (partial.xPercent !== undefined) def.xPercent = partial.xPercent;
    if (partial.yPercent !== undefined) def.yPercent = partial.yPercent;
    if (partial.width !== undefined) def.width = partial.width;
    if (partial.height !== undefined) def.height = partial.height;
    if (partial.layer !== undefined) def.layer = partial.layer;
    if (partial.opacity !== undefined) def.opacity = partial.opacity;
    if (partial.borderRadius !== undefined) def.borderRadius = partial.borderRadius;
    if (partial.normalColor !== undefined) def.normalColor = partial.normalColor;
    if (partial.pressedColor !== undefined) def.pressedColor = partial.pressedColor;
    if (partial.bgColor !== undefined) def.bgColor = partial.bgColor;
    if (partial.textColor !== undefined) def.textColor = partial.textColor;
    if (partial.fontSize !== undefined) def.fontSize = partial.fontSize;
  }
  return def;
}

/** 创建空白配置档案 */
export function createDefaultProfile(name: string = '默认'): CustomKeyProfile {
  return {
    name,
    keys: [],
  };
}

// =============================================================================
// 常用按键预设
// =============================================================================

/** VK 码显示名称映射 */
export const VK_DISPLAY_NAMES: Record<number, string> = {
  // 字母 A-Z
  0x41: 'A', 0x42: 'B', 0x43: 'C', 0x44: 'D', 0x45: 'E',
  0x46: 'F', 0x47: 'G', 0x48: 'H', 0x49: 'I', 0x4A: 'J',
  0x4B: 'K', 0x4C: 'L', 0x4D: 'M', 0x4E: 'N', 0x4F: 'O',
  0x50: 'P', 0x51: 'Q', 0x52: 'R', 0x53: 'S', 0x54: 'T',
  0x55: 'U', 0x56: 'V', 0x57: 'W', 0x58: 'X', 0x59: 'Y', 0x5A: 'Z',
  // 数字 0-9
  0x30: '0', 0x31: '1', 0x32: '2', 0x33: '3', 0x34: '4',
  0x35: '5', 0x36: '6', 0x37: '7', 0x38: '8', 0x39: '9',
  // 功能键
  0x70: 'F1', 0x71: 'F2', 0x72: 'F3', 0x73: 'F4',
  0x74: 'F5', 0x75: 'F6', 0x76: 'F7', 0x77: 'F8',
  0x78: 'F9', 0x79: 'F10', 0x7A: 'F11', 0x7B: 'F12',
  // 控制键
  0x1B: 'ESC', 0x09: 'Tab', 0x14: 'Caps', 0x0D: 'Enter',
  0x08: 'Backspace', 0x20: 'Space', 0x2D: 'Insert', 0x2E: 'Delete',
  0x24: 'Home', 0x23: 'End', 0x21: 'PgUp', 0x22: 'PgDn',
  // 方向键
  0x25: '←', 0x26: '↑', 0x27: '→', 0x28: '↓',
  // 修饰键
  0xA0: 'LShift', 0xA1: 'RShift', 0xA2: 'LCtrl', 0xA3: 'RCtrl',
  0xA4: 'LAlt', 0xA5: 'RAlt', 0x5B: 'LWin', 0x5C: 'RWin',
  // 符号
  0xC0: '`', 0xBD: '-', 0xBB: '=', 0xDB: '[', 0xDD: ']',
  0xDC: '\\', 0xBA: ';', 0xDE: "'", 0xBC: ',', 0xBE: '.', 0xBF: '/',
  // 截图
  0x2C: 'PrtSc',
};

/** 获取 VK 码的显示名称 */
export function getVkDisplayName(vk: number): string {
  return VK_DISPLAY_NAMES[vk] ?? `0x${vk.toString(16).toUpperCase()}`;
}

/** 手柄按键掩码 → 显示名称 */
export const GAMEPAD_DISPLAY_NAMES: Record<number, string> = {
  0x1000: 'A', 0x2000: 'B', 0x4000: 'X', 0x8000: 'Y',
  0x0100: 'LB', 0x0200: 'RB',
  0x0010: 'Start', 0x0020: 'Back',
  0x0040: 'L3', 0x0080: 'R3',
  0x0400: 'Guide',
  0x0001: 'D↑', 0x0002: 'D↓', 0x0004: 'D←', 0x0008: 'D→',
};

/** 获取 KeyAction 的显示名称 */
export function getActionDisplayName(action: KeyAction): string {
  switch (action.type) {
    case 'keyboard':
      return getVkDisplayName(action.vk);
    case 'mouse':
      const mouseNames: Record<number, string> = {
        1: '鼠标左键', 2: '鼠标中键', 3: '鼠标右键', 4: '侧键1', 5: '侧键2',
      };
      return mouseNames[action.button] ?? `鼠标${action.button}`;
    case 'mouseScroll':
      return action.direction > 0 ? '滚轮↑' : '滚轮↓';
    case 'gamepadButton':
      return GAMEPAD_DISPLAY_NAMES[action.mask] ?? `手柄0x${action.mask.toString(16)}`;
    case 'gamepadTrigger':
      return action.trigger === 'left' ? 'LT' : 'RT';
    case 'combo':
      return action.actions.map(a => getActionDisplayName(a)).join('+');
    case 'special':
      const specialNames: Record<string, string> = {
        'toggleKeyboard': '键盘', 'toggleIME': '输入法',
        'toggleMouseMode': '鼠标模式', 'switchProfile': '切换配置',
        'openGameMenu': '菜单', 'editMode': '编辑', 'none': '无',
      };
      return specialNames[action.id] ?? action.id;
    default:
      return '未知';
  }
}

// =============================================================================
// 常用按键预设模板
// =============================================================================

/** 预设按键分类 */
export interface KeyPresetCategory {
  name: string;
  presets: KeyPreset[];
}

export interface KeyPreset {
  label: string;
  action: KeyAction;
}

/** 所有预设分类 */
export const KEY_PRESET_CATEGORIES: KeyPresetCategory[] = [
  {
    name: '常用键',
    presets: [
      { label: 'ESC', action: { type: 'keyboard', vk: 0x1B } },
      { label: 'Enter', action: { type: 'keyboard', vk: 0x0D } },
      { label: 'Space', action: { type: 'keyboard', vk: 0x20 } },
      { label: 'Tab', action: { type: 'keyboard', vk: 0x09 } },
      { label: 'Shift', action: { type: 'keyboard', vk: 0xA0 } },
      { label: 'Ctrl', action: { type: 'keyboard', vk: 0xA2 } },
      { label: 'Alt', action: { type: 'keyboard', vk: 0xA4 } },
      { label: 'Win', action: { type: 'keyboard', vk: 0x5B } },
      { label: 'Backspace', action: { type: 'keyboard', vk: 0x08 } },
      { label: 'Delete', action: { type: 'keyboard', vk: 0x2E } },
      { label: 'Insert', action: { type: 'keyboard', vk: 0x2D } },
      { label: 'Home', action: { type: 'keyboard', vk: 0x24 } },
      { label: 'End', action: { type: 'keyboard', vk: 0x23 } },
      { label: 'PgUp', action: { type: 'keyboard', vk: 0x21 } },
      { label: 'PgDn', action: { type: 'keyboard', vk: 0x22 } },
      { label: 'Caps', action: { type: 'keyboard', vk: 0x14 } },
      { label: 'PrtSc', action: { type: 'keyboard', vk: 0x2C } },
    ],
  },
  {
    name: '功能键',
    presets: [
      { label: 'F1', action: { type: 'keyboard', vk: 0x70 } },
      { label: 'F2', action: { type: 'keyboard', vk: 0x71 } },
      { label: 'F3', action: { type: 'keyboard', vk: 0x72 } },
      { label: 'F4', action: { type: 'keyboard', vk: 0x73 } },
      { label: 'F5', action: { type: 'keyboard', vk: 0x74 } },
      { label: 'F6', action: { type: 'keyboard', vk: 0x75 } },
      { label: 'F7', action: { type: 'keyboard', vk: 0x76 } },
      { label: 'F8', action: { type: 'keyboard', vk: 0x77 } },
      { label: 'F9', action: { type: 'keyboard', vk: 0x78 } },
      { label: 'F10', action: { type: 'keyboard', vk: 0x79 } },
      { label: 'F11', action: { type: 'keyboard', vk: 0x7A } },
      { label: 'F12', action: { type: 'keyboard', vk: 0x7B } },
    ],
  },
  {
    name: '鼠标',
    presets: [
      { label: '左键', action: { type: 'mouse', button: 1 } },
      { label: '中键', action: { type: 'mouse', button: 2 } },
      { label: '右键', action: { type: 'mouse', button: 3 } },
      { label: '滚轮↑', action: { type: 'mouseScroll', direction: 1 } },
      { label: '滚轮↓', action: { type: 'mouseScroll', direction: -1 } },
    ],
  },
  {
    name: '手柄',
    presets: [
      { label: 'A', action: { type: 'gamepadButton', mask: 0x1000 } },
      { label: 'B', action: { type: 'gamepadButton', mask: 0x2000 } },
      { label: 'X', action: { type: 'gamepadButton', mask: 0x4000 } },
      { label: 'Y', action: { type: 'gamepadButton', mask: 0x8000 } },
      { label: 'LB', action: { type: 'gamepadButton', mask: 0x0100 } },
      { label: 'RB', action: { type: 'gamepadButton', mask: 0x0200 } },
      { label: 'LT', action: { type: 'gamepadTrigger', trigger: 'left' } as GamepadTriggerAction },
      { label: 'RT', action: { type: 'gamepadTrigger', trigger: 'right' } as GamepadTriggerAction },
      { label: 'Start', action: { type: 'gamepadButton', mask: 0x0010 } },
      { label: 'Back', action: { type: 'gamepadButton', mask: 0x0020 } },
      { label: 'L3', action: { type: 'gamepadButton', mask: 0x0040 } },
      { label: 'R3', action: { type: 'gamepadButton', mask: 0x0080 } },
      { label: 'Guide', action: { type: 'gamepadButton', mask: 0x0400 } },
      { label: 'D↑', action: { type: 'gamepadButton', mask: 0x0001 } },
      { label: 'D↓', action: { type: 'gamepadButton', mask: 0x0002 } },
      { label: 'D←', action: { type: 'gamepadButton', mask: 0x0004 } },
      { label: 'D→', action: { type: 'gamepadButton', mask: 0x0008 } },
    ],
  },
  {
    name: '方向键',
    presets: [
      { label: '↑', action: { type: 'keyboard', vk: 0x26 } },
      { label: '↓', action: { type: 'keyboard', vk: 0x28 } },
      { label: '←', action: { type: 'keyboard', vk: 0x25 } },
      { label: '→', action: { type: 'keyboard', vk: 0x27 } },
    ],
  },
  {
    name: '字母',
    presets: buildLetterPresets(),
  },
  {
    name: '数字',
    presets: buildNumberPresets(),
  },
  {
    name: '符号',
    presets: [
      { label: '`', action: { type: 'keyboard', vk: 0xC0 } },
      { label: '-', action: { type: 'keyboard', vk: 0xBD } },
      { label: '=', action: { type: 'keyboard', vk: 0xBB } },
      { label: '[', action: { type: 'keyboard', vk: 0xDB } },
      { label: ']', action: { type: 'keyboard', vk: 0xDD } },
      { label: '\\', action: { type: 'keyboard', vk: 0xDC } },
      { label: ';', action: { type: 'keyboard', vk: 0xBA } },
      { label: "'", action: { type: 'keyboard', vk: 0xDE } },
      { label: ',', action: { type: 'keyboard', vk: 0xBC } },
      { label: '.', action: { type: 'keyboard', vk: 0xBE } },
      { label: '/', action: { type: 'keyboard', vk: 0xBF } },
    ],
  },
  {
    name: '特殊功能',
    presets: [
      { label: '键盘', action: { type: 'special', id: 'toggleKeyboard' } as SpecialAction },
      { label: '输入法', action: { type: 'special', id: 'toggleIME' } as SpecialAction },
      { label: '鼠标模式', action: { type: 'special', id: 'toggleMouseMode' } as SpecialAction },
      { label: '切换配置', action: { type: 'special', id: 'switchProfile' } as SpecialAction },
      { label: '菜单', action: { type: 'special', id: 'openGameMenu' } as SpecialAction },
      { label: '编辑', action: { type: 'special', id: 'editMode' } as SpecialAction },
    ],
  },
];

/** 构建字母 A-Z 预设列表 */
function buildLetterPresets(): KeyPreset[] {
  const list: KeyPreset[] = [];
  for (let i = 0; i < 26; i++) {
    const preset: KeyPreset = {
      label: String.fromCharCode(65 + i),
      action: { type: 'keyboard', vk: 0x41 + i } as KeyboardAction,
    };
    list.push(preset);
  }
  return list;
}

/** 构建数字 0-9 预设列表 */
function buildNumberPresets(): KeyPreset[] {
  const list: KeyPreset[] = [];
  for (let i = 0; i < 10; i++) {
    const preset: KeyPreset = {
      label: i.toString(),
      action: { type: 'keyboard', vk: 0x30 + i } as KeyboardAction,
    };
    list.push(preset);
  }
  return list;
}
