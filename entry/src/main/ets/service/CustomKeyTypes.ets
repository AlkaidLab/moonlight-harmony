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

/** 手柄摇杆方向动作（按下推满、释放归零） */
export interface GamepadStickAction {
  type: 'gamepadStick';
  /** 摇杆：'left' = 左摇杆, 'right' = 右摇杆 */
  stick: 'left' | 'right';
  /** 方向 */
  direction: 'up' | 'down' | 'left' | 'right';
}

/** 组合键动作：同时发送多个按键 */
export interface ComboAction {
  type: 'combo';
  actions: KeyAction[];
}

/**
 * 快捷键动作：一次性发送组合键或多步按键序列
 * 与 keyboard 类型（持续按住/释放）不同，shortcut 在按下时一次性触发完整序列
 * 复用 ShortcutManager 的 Shortcut 数据模型
 */
export interface ShortcutAction {
  type: 'shortcut';
  /** 同时按下的虚拟键码数组 */
  keys: number[];
  /** 多步按键序列（依次执行，每步间隔 200ms） */
  keySequence?: number[][];
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
  | GamepadStickAction
  | ComboAction
  | ShortcutAction
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
// 统一的 Windows 虚拟键码常量
// =============================================================================

/**
 * Windows Virtual-Key Codes（统一常量表）
 *
 * 所有 VK 码定义的唯一来源，供快捷键、自定义按键、菜单等共用。
 * 原先分散在 StreamMenuManager.VirtualKey / MoonBridge.VK_* 中。
 */
export class VirtualKey {
  // 修饰键
  static readonly VK_SHIFT = 0x10;
  static readonly VK_CONTROL = 0x11;
  static readonly VK_MENU = 0x12;        // Alt
  static readonly VK_LWIN = 0x5B;
  static readonly VK_RWIN = 0x5C;
  static readonly VK_LSHIFT = 0xA0;
  static readonly VK_RSHIFT = 0xA1;
  static readonly VK_LCONTROL = 0xA2;
  static readonly VK_RCONTROL = 0xA3;
  static readonly VK_LMENU = 0xA4;
  static readonly VK_RMENU = 0xA5;
  // 控制键
  static readonly VK_ESCAPE = 0x1B;
  static readonly VK_TAB = 0x09;
  static readonly VK_RETURN = 0x0D;
  static readonly VK_BACK = 0x08;        // Backspace
  static readonly VK_SPACE = 0x20;
  static readonly VK_DELETE = 0x2E;
  static readonly VK_INSERT = 0x2D;
  static readonly VK_HOME = 0x24;
  static readonly VK_END = 0x23;
  static readonly VK_PRIOR = 0x21;       // Page Up
  static readonly VK_NEXT = 0x22;        // Page Down
  static readonly VK_CAPITAL = 0x14;     // Caps Lock
  static readonly VK_SNAPSHOT = 0x2C;    // Print Screen
  static readonly VK_SCROLL = 0x91;      // Scroll Lock
  static readonly VK_PAUSE = 0x13;
  static readonly VK_NUMLOCK = 0x90;
  // 方向键
  static readonly VK_LEFT = 0x25;
  static readonly VK_UP = 0x26;
  static readonly VK_RIGHT = 0x27;
  static readonly VK_DOWN = 0x28;
  // 功能键
  static readonly VK_F1 = 0x70;
  static readonly VK_F2 = 0x71;
  static readonly VK_F3 = 0x72;
  static readonly VK_F4 = 0x73;
  static readonly VK_F5 = 0x74;
  static readonly VK_F6 = 0x75;
  static readonly VK_F7 = 0x76;
  static readonly VK_F8 = 0x77;
  static readonly VK_F9 = 0x78;
  static readonly VK_F10 = 0x79;
  static readonly VK_F11 = 0x7A;
  static readonly VK_F12 = 0x7B;
  // 字母 (用于组合键引用，如 VK_B = Ctrl+B)
  static readonly VK_A = 0x41;
  static readonly VK_B = 0x42;
  static readonly VK_C = 0x43;
  static readonly VK_D = 0x44;
  static readonly VK_E = 0x45;
  static readonly VK_F = 0x46;
  static readonly VK_G = 0x47;
  static readonly VK_H = 0x48;
  static readonly VK_I = 0x49;
  static readonly VK_J = 0x4A;
  static readonly VK_K = 0x4B;
  static readonly VK_L = 0x4C;
  static readonly VK_M = 0x4D;
  static readonly VK_N = 0x4E;
  static readonly VK_O = 0x4F;
  static readonly VK_P = 0x50;
  static readonly VK_Q = 0x51;
  static readonly VK_R = 0x52;
  static readonly VK_S = 0x53;
  static readonly VK_T = 0x54;
  static readonly VK_U = 0x55;
  static readonly VK_V = 0x56;
  static readonly VK_W = 0x57;
  static readonly VK_X = 0x58;
  static readonly VK_Y = 0x59;
  static readonly VK_Z = 0x5A;
  // 媒体键
  static readonly VK_VOLUME_MUTE = 0xAD;
  static readonly VK_VOLUME_DOWN = 0xAE;
  static readonly VK_VOLUME_UP = 0xAF;
  static readonly VK_MEDIA_NEXT_TRACK = 0xB0;
  static readonly VK_MEDIA_PREV_TRACK = 0xB1;
  static readonly VK_MEDIA_STOP = 0xB2;
  static readonly VK_MEDIA_PLAY_PAUSE = 0xB3;
}

// =============================================================================
// 统一的手柄按钮掩码常量
// =============================================================================

/**
 * 手柄按钮位掩码（统一常量表）
 *
 * 所有手柄按钮掩码定义的唯一来源，供自定义按键、显示名称、预设等共用。
 * 值与 moonlight-common-c/Limelight.h 保持一致。
 * 原先分散在 MoonBridge / GamepadTypes.MoonlightButton / ControllerConstants.ButtonFlags 中。
 */
export class GamepadButton {
  // D-Pad
  static readonly UP = 0x0001;
  static readonly DOWN = 0x0002;
  static readonly LEFT = 0x0004;
  static readonly RIGHT = 0x0008;
  // 功能键
  static readonly START = 0x0010;        // Play/Menu
  static readonly BACK = 0x0020;         // Select/View
  // 摇杆按下
  static readonly LS = 0x0040;           // Left Stick Click (L3)
  static readonly RS = 0x0080;           // Right Stick Click (R3)
  // 肩键
  static readonly LB = 0x0100;
  static readonly RB = 0x0200;
  // 特殊
  static readonly GUIDE = 0x0400;        // Xbox/PS/Home 按钮
  // 面板键
  static readonly A = 0x1000;
  static readonly B = 0x2000;
  static readonly X = 0x4000;
  static readonly Y = 0x8000;
  // 扩展按钮（值必须与 moonlight-common-c/Limelight.h 一致）
  static readonly PADDLE1 = 0x010000;
  static readonly PADDLE2 = 0x020000;
  static readonly PADDLE3 = 0x040000;
  static readonly PADDLE4 = 0x080000;
  static readonly TOUCHPAD = 0x100000;   // 触摸板按钮 (DualShock4/DualSense)
  static readonly MISC = 0x200000;       // 杂项按钮 (Capture/Mute 等)
  // 组合掩码
  static readonly DPAD_MASK = 0x000F;    // UP | DOWN | LEFT | RIGHT
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
  0x10: 'Shift', 0x11: 'Ctrl', 0x12: 'Alt',
  0xA0: 'LShift', 0xA1: 'RShift', 0xA2: 'LCtrl', 0xA3: 'RCtrl',
  0xA4: 'LAlt', 0xA5: 'RAlt', 0x5B: 'LWin', 0x5C: 'RWin',
  // 符号
  0xC0: '`', 0xBD: '-', 0xBB: '=', 0xDB: '[', 0xDD: ']',
  0xDC: '\\', 0xBA: ';', 0xDE: "'", 0xBC: ',', 0xBE: '.', 0xBF: '/',
  // 截图/锁定
  0x2C: 'PrtSc', 0x91: 'ScrLk', 0x13: 'Pause', 0x90: 'NumLk',
  // 小键盘
  0x60: 'Num0', 0x61: 'Num1', 0x62: 'Num2', 0x63: 'Num3', 0x64: 'Num4',
  0x65: 'Num5', 0x66: 'Num6', 0x67: 'Num7', 0x68: 'Num8', 0x69: 'Num9',
  0x6A: 'Num*', 0x6B: 'Num+', 0x6D: 'Num-', 0x6E: 'Num.', 0x6F: 'Num/',
  // 媒体键
  0xAD: '🔇', 0xAE: '🔉', 0xAF: '🔊',
  0xB0: '⏭', 0xB1: '⏮', 0xB2: '⏹', 0xB3: '⏯',
};

/** 获取 VK 码的显示名称 */
export function getVkDisplayName(vk: number): string {
  return VK_DISPLAY_NAMES[vk] ?? `0x${vk.toString(16).toUpperCase()}`;
}

/** 手柄按键掩码 → 显示名称 */
export const GAMEPAD_DISPLAY_NAMES: Record<number, string> = {
  [GamepadButton.A]: 'A', [GamepadButton.B]: 'B',
  [GamepadButton.X]: 'X', [GamepadButton.Y]: 'Y',
  [GamepadButton.LB]: 'LB', [GamepadButton.RB]: 'RB',
  [GamepadButton.START]: 'Start', [GamepadButton.BACK]: 'Back',
  [GamepadButton.LS]: 'L3', [GamepadButton.RS]: 'R3',
  [GamepadButton.GUIDE]: 'Guide',
  [GamepadButton.UP]: 'D↑', [GamepadButton.DOWN]: 'D↓',
  [GamepadButton.LEFT]: 'D←', [GamepadButton.RIGHT]: 'D→',
  // 扩展按钮
  [GamepadButton.PADDLE1]: 'P1', [GamepadButton.PADDLE2]: 'P2',
  [GamepadButton.PADDLE3]: 'P3', [GamepadButton.PADDLE4]: 'P4',
  [GamepadButton.TOUCHPAD]: 'Touchpad', [GamepadButton.MISC]: 'Misc',
};

/** 获取手柄按钮掩码的显示名称 */
export function getGamepadDisplayName(mask: number): string {
  return GAMEPAD_DISPLAY_NAMES[mask] ?? `手柄0x${mask.toString(16)}`;
}

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
      return getGamepadDisplayName(action.mask);
    case 'gamepadTrigger':
      return action.trigger === 'left' ? 'LT' : 'RT';
    case 'gamepadStick': {
      const stickName = action.stick === 'left' ? 'LS' : 'RS';
      const dirMap: Record<string, string> = { 'up': '↑', 'down': '↓', 'left': '←', 'right': '→' };
      return `${stickName}${dirMap[action.direction] ?? action.direction}`;
    }
    case 'combo':
      return action.actions.map(a => getActionDisplayName(a)).join('+');
    case 'shortcut': {
      // 快捷键：显示组合键码名称
      if (action.keySequence && action.keySequence.length > 0) {
        return action.keySequence.map(step =>
          step.map(vk => getVkDisplayName(vk)).join('+')
        ).join(' → ');
      }
      return action.keys.map(vk => getVkDisplayName(vk)).join('+');
    }
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
      { label: 'A', action: { type: 'gamepadButton', mask: GamepadButton.A } },
      { label: 'B', action: { type: 'gamepadButton', mask: GamepadButton.B } },
      { label: 'X', action: { type: 'gamepadButton', mask: GamepadButton.X } },
      { label: 'Y', action: { type: 'gamepadButton', mask: GamepadButton.Y } },
      { label: 'LB', action: { type: 'gamepadButton', mask: GamepadButton.LB } },
      { label: 'RB', action: { type: 'gamepadButton', mask: GamepadButton.RB } },
      { label: 'LT', action: { type: 'gamepadTrigger', trigger: 'left' } as GamepadTriggerAction },
      { label: 'RT', action: { type: 'gamepadTrigger', trigger: 'right' } as GamepadTriggerAction },
      { label: 'Start', action: { type: 'gamepadButton', mask: GamepadButton.START } },
      { label: 'Back', action: { type: 'gamepadButton', mask: GamepadButton.BACK } },
      { label: 'L3', action: { type: 'gamepadButton', mask: GamepadButton.LS } },
      { label: 'R3', action: { type: 'gamepadButton', mask: GamepadButton.RS } },
      { label: 'Guide', action: { type: 'gamepadButton', mask: GamepadButton.GUIDE } },
      { label: 'D↑', action: { type: 'gamepadButton', mask: GamepadButton.UP } },
      { label: 'D↓', action: { type: 'gamepadButton', mask: GamepadButton.DOWN } },
      { label: 'D←', action: { type: 'gamepadButton', mask: GamepadButton.LEFT } },
      { label: 'D→', action: { type: 'gamepadButton', mask: GamepadButton.RIGHT } },
      { label: 'P1', action: { type: 'gamepadButton', mask: GamepadButton.PADDLE1 } },
      // 摇杆方向
      { label: 'LS↑', action: { type: 'gamepadStick', stick: 'left', direction: 'up' } as GamepadStickAction },
      { label: 'LS↓', action: { type: 'gamepadStick', stick: 'left', direction: 'down' } as GamepadStickAction },
      { label: 'LS←', action: { type: 'gamepadStick', stick: 'left', direction: 'left' } as GamepadStickAction },
      { label: 'LS→', action: { type: 'gamepadStick', stick: 'left', direction: 'right' } as GamepadStickAction },
      { label: 'RS↑', action: { type: 'gamepadStick', stick: 'right', direction: 'up' } as GamepadStickAction },
      { label: 'RS↓', action: { type: 'gamepadStick', stick: 'right', direction: 'down' } as GamepadStickAction },
      { label: 'RS←', action: { type: 'gamepadStick', stick: 'right', direction: 'left' } as GamepadStickAction },
      { label: 'RS→', action: { type: 'gamepadStick', stick: 'right', direction: 'right' } as GamepadStickAction },
      { label: 'P2', action: { type: 'gamepadButton', mask: GamepadButton.PADDLE2 } },
      { label: 'P3', action: { type: 'gamepadButton', mask: GamepadButton.PADDLE3 } },
      { label: 'P4', action: { type: 'gamepadButton', mask: GamepadButton.PADDLE4 } },
      { label: 'Touchpad', action: { type: 'gamepadButton', mask: GamepadButton.TOUCHPAD } },
      { label: 'Misc', action: { type: 'gamepadButton', mask: GamepadButton.MISC } },
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
  {
    name: '快捷键',
    presets: [
      { label: 'Alt+Tab', action: { type: 'shortcut', keys: [0x12, 0x09], keySequence: undefined } as ShortcutAction },
      { label: 'Alt+F4', action: { type: 'shortcut', keys: [0x12, 0x73], keySequence: undefined } as ShortcutAction },
      { label: 'Ctrl+C', action: { type: 'shortcut', keys: [0x11, 0x43], keySequence: undefined } as ShortcutAction },
      { label: 'Ctrl+V', action: { type: 'shortcut', keys: [0x11, 0x56], keySequence: undefined } as ShortcutAction },
      { label: 'Ctrl+Z', action: { type: 'shortcut', keys: [0x11, 0x5A], keySequence: undefined } as ShortcutAction },
      { label: 'Ctrl+A', action: { type: 'shortcut', keys: [0x11, 0x41], keySequence: undefined } as ShortcutAction },
      { label: 'Ctrl+S', action: { type: 'shortcut', keys: [0x11, 0x53], keySequence: undefined } as ShortcutAction },
      { label: 'Win', action: { type: 'shortcut', keys: [0x5B], keySequence: undefined } as ShortcutAction },
      { label: 'Win+D', action: { type: 'shortcut', keys: [0x5B, 0x44], keySequence: undefined } as ShortcutAction },
      { label: 'Win+E', action: { type: 'shortcut', keys: [0x5B, 0x45], keySequence: undefined } as ShortcutAction },
      { label: 'Ctrl+Alt+Del', action: { type: 'shortcut', keys: [0x11, 0x12, 0x2E], keySequence: undefined } as ShortcutAction },
      { label: '休眠', action: { type: 'shortcut', keys: [], keySequence: [[0x5B, 0x58], [0x55], [0x53]] } as ShortcutAction },
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

// =============================================================================
// 统一快捷键执行引擎
// =============================================================================

/**
 * 统一的快捷键执行函数
 *
 * 支持单次组合键和多步按键序列（每步间隔 200ms）。
 * 使用回调参数避免 ArkTS 结构化类型限制。
 *
 * @param sendKeysFn 发送按键组合的回调（通常是 session.sendKeys）
 * @param keys       同时按下的键码数组
 * @param keySequence 可选的多步按键序列
 */
export function sendShortcutKeys(
  sendKeysFn: (keyCodes: number[]) => void,
  keys: number[],
  keySequence?: number[][],
): void {
  if (keySequence && keySequence.length > 0) {
    keySequence.forEach((stepKeys: number[], index: number) => {
      setTimeout(() => {
        sendKeysFn(stepKeys);
      }, index * 200);
    });
  } else if (keys.length > 0) {
    sendKeysFn(keys);
  }
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
