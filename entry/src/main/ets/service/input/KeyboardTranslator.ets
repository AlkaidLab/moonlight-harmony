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
 * KeyboardTranslator - HarmonyOS KeyCode → Windows Virtual Key Code 映射
 *
 * 参照 Android moonlight-android KeyboardTranslator.java 实现
 * HarmonyOS 按键码定义: @ohos.multimodalInput.keyCode (KeyCode enum)
 * Windows VK 码参考: https://docs.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
 *
 * HarmonyOS 按键码偏移:
 *   - 数字 0-9:       2000-2009
 *   - D-Pad:          2012-2016
 *   - 字母 A-Z:       2017-2042
 *   - 标点/修饰键:    2043-2083
 *   - F1-F12:         2090-2101
 *   - NUM_LOCK/小键盘: 2102-2120
 *   - 手柄按键:       19-22, 96-110 (传统 InputKit), 2300-2320 (GC Kit)
 */

// ==================== HarmonyOS KeyCode 常量 ====================

// 数字键
const OH_KEYCODE_0 = 2000;
const OH_KEYCODE_9 = 2009;

// 字母键
const OH_KEYCODE_A = 2017;
const OH_KEYCODE_Z = 2042;

// 功能键
const OH_KEYCODE_F1 = 2090;
const OH_KEYCODE_F12 = 2101;

// 小键盘数字
const OH_KEYCODE_NUMPAD_0 = 2103;
const OH_KEYCODE_NUMPAD_9 = 2112;

// ==================== Windows VK 常量 ====================

const VK_0 = 0x30;         // 48
const VK_A = 0x41;         // 65
const VK_F1 = 0x70;        // 112
const VK_NUMPAD0 = 0x60;   // 96

export class KeyboardTranslator {

  /**
   * 判断 HarmonyOS 按键码是否为键盘按键（非手柄按键）
   *
   * 手柄按键范围:
   *   - 19-22:    传统 InputKit DPAD
   *   - 96-110:   传统 InputKit 手柄按钮 (BUTTON_A~BUTTON_MODE)
   *   - 2300-2320: Game Controller Kit 按键
   *
   * 键盘按键范围:
   *   - 2000-2009: 数字 0-9
   *   - 2012-2016: 方向键（也可能来自手柄 D-Pad，但 GCK 手柄走独立路径）
   *   - 2017-2042: 字母 A-Z
   *   - 2043-2083: 标点、修饰键、特殊键
   *   - 2090-2101: F1-F12
   *   - 2102-2120: NUM_LOCK、小键盘
   */
  static isKeyboardKey(keyCode: number): boolean {
    // 数字 0-9
    if (keyCode >= 2000 && keyCode <= 2009) return true;
    // 方向键 (D-Pad)
    if (keyCode >= 2012 && keyCode <= 2016) return true;
    // 字母 A-Z
    if (keyCode >= 2017 && keyCode <= 2042) return true;
    // 标点、修饰键、特殊键 (COMMA 2043 ~ INSERT 2083)
    if (keyCode >= 2043 && keyCode <= 2083) return true;
    // F1-F12
    if (keyCode >= 2090 && keyCode <= 2101) return true;
    // NUM_LOCK + 小键盘 (2102 ~ NUMPAD_EQUALS 2120)
    if (keyCode >= 2102 && keyCode <= 2120) return true;
    return false;
  }

  /**
   * 判断按键码是否为手柄按键
   *
   * 包含传统 InputKit 手柄按键范围和 GC Kit 范围
   */
  static isGamepadKey(keyCode: number): boolean {
    // 传统 InputKit: DPAD 19-22
    if (keyCode >= 19 && keyCode <= 22) return true;
    // 传统 InputKit: BUTTON_A(96) ~ BUTTON_MODE(110)
    if (keyCode >= 96 && keyCode <= 110) return true;
    // Game Controller Kit: 2300-2320
    if (keyCode >= 2300 && keyCode <= 2320) return true;
    return false;
  }

  /**
   * 将 HarmonyOS 按键码翻译为 Windows 虚拟键码
   *
   * @param keyCode HarmonyOS KeyCode
   * @returns Windows VK code，未知按键返回 0
   */
  static translate(keyCode: number): number {
    // ── 范围映射 ──

    // 数字 0-9 → VK_0(0x30) ~ VK_9(0x39)
    if (keyCode >= OH_KEYCODE_0 && keyCode <= OH_KEYCODE_9) {
      return (keyCode - OH_KEYCODE_0) + VK_0;
    }

    // 字母 A-Z → VK_A(0x41) ~ VK_Z(0x5A)
    if (keyCode >= OH_KEYCODE_A && keyCode <= OH_KEYCODE_Z) {
      return (keyCode - OH_KEYCODE_A) + VK_A;
    }

    // F1-F12 → VK_F1(0x70) ~ VK_F12(0x7B)
    if (keyCode >= OH_KEYCODE_F1 && keyCode <= OH_KEYCODE_F12) {
      return (keyCode - OH_KEYCODE_F1) + VK_F1;
    }

    // 小键盘 0-9 → VK_NUMPAD0(0x60) ~ VK_NUMPAD9(0x69)
    if (keyCode >= OH_KEYCODE_NUMPAD_0 && keyCode <= OH_KEYCODE_NUMPAD_9) {
      return (keyCode - OH_KEYCODE_NUMPAD_0) + VK_NUMPAD0;
    }

    // ── 单键映射 ──
    switch (keyCode) {
      // 方向键
      case 2012: return 0x26; // KEYCODE_DPAD_UP     → VK_UP
      case 2013: return 0x28; // KEYCODE_DPAD_DOWN   → VK_DOWN
      case 2014: return 0x25; // KEYCODE_DPAD_LEFT   → VK_LEFT
      case 2015: return 0x27; // KEYCODE_DPAD_RIGHT  → VK_RIGHT
      case 2016: return 0x0D; // KEYCODE_DPAD_CENTER → VK_RETURN

      // 标点
      case 2043: return 0xBC; // KEYCODE_COMMA       → VK_OEM_COMMA
      case 2044: return 0xBE; // KEYCODE_PERIOD      → VK_OEM_PERIOD

      // 修饰键
      case 2045: return 0xA4; // KEYCODE_ALT_LEFT    → VK_LMENU
      case 2046: return 0xA5; // KEYCODE_ALT_RIGHT   → VK_RMENU
      case 2047: return 0xA0; // KEYCODE_SHIFT_LEFT  → VK_LSHIFT
      case 2048: return 0xA1; // KEYCODE_SHIFT_RIGHT → VK_RSHIFT

      // 控制键
      case 2049: return 0x09; // KEYCODE_TAB         → VK_TAB
      case 2050: return 0x20; // KEYCODE_SPACE       → VK_SPACE

      // 回车 & 退格
      case 2054: return 0x0D; // KEYCODE_ENTER       → VK_RETURN
      case 2055: return 0x08; // KEYCODE_DEL (退格)  → VK_BACK

      // 符号键
      case 2056: return 0xC0; // KEYCODE_GRAVE   (`) → VK_OEM_3
      case 2057: return 0xBD; // KEYCODE_MINUS   (-) → VK_OEM_MINUS
      case 2058: return 0xBB; // KEYCODE_EQUALS  (=) → VK_OEM_PLUS
      case 2059: return 0xDB; // KEYCODE_LEFT_BRACKET  ([) → VK_OEM_4
      case 2060: return 0xDD; // KEYCODE_RIGHT_BRACKET (]) → VK_OEM_6
      case 2061: return 0xDC; // KEYCODE_BACKSLASH     (\) → VK_OEM_5
      case 2062: return 0xBA; // KEYCODE_SEMICOLON     (;) → VK_OEM_1
      case 2063: return 0xDE; // KEYCODE_APOSTROPHE    (') → VK_OEM_7
      case 2064: return 0xBF; // KEYCODE_SLASH         (/) → VK_OEM_2

      // 其他
      case 2066: return 0xBB; // KEYCODE_PLUS    (+) → VK_OEM_PLUS
      case 2067: return 0x5D; // KEYCODE_MENU        → VK_APPS (上下文菜单键)
      case 2068: return 0x21; // KEYCODE_PAGE_UP     → VK_PRIOR
      case 2069: return 0x22; // KEYCODE_PAGE_DOWN   → VK_NEXT
      case 2070: return 0x1B; // KEYCODE_ESCAPE      → VK_ESCAPE
      case 2071: return 0x2E; // KEYCODE_FORWARD_DEL → VK_DELETE

      // Ctrl 键
      case 2072: return 0xA2; // KEYCODE_CTRL_LEFT   → VK_LCONTROL
      case 2073: return 0xA3; // KEYCODE_CTRL_RIGHT  → VK_RCONTROL

      // 锁定键
      case 2074: return 0x14; // KEYCODE_CAPS_LOCK   → VK_CAPITAL
      case 2075: return 0x91; // KEYCODE_SCROLL_LOCK → VK_SCROLL

      // Meta (Win) 键
      case 2076: return 0x5B; // KEYCODE_META_LEFT   → VK_LWIN
      case 2077: return 0x5C; // KEYCODE_META_RIGHT  → VK_RWIN

      // 系统 / 导航键
      case 2079: return 0x2C; // KEYCODE_SYSRQ       → VK_SNAPSHOT (PrintScreen)
      case 2080: return 0x13; // KEYCODE_BREAK       → VK_PAUSE
      case 2081: return 0x24; // KEYCODE_MOVE_HOME   → VK_HOME
      case 2082: return 0x23; // KEYCODE_MOVE_END    → VK_END
      case 2083: return 0x2D; // KEYCODE_INSERT      → VK_INSERT

      // 小键盘操作键
      case 2102: return 0x90; // KEYCODE_NUM_LOCK        → VK_NUMLOCK
      case 2113: return 0x6F; // KEYCODE_NUMPAD_DIVIDE   → VK_DIVIDE
      case 2114: return 0x6A; // KEYCODE_NUMPAD_MULTIPLY → VK_MULTIPLY
      case 2115: return 0x6D; // KEYCODE_NUMPAD_SUBTRACT → VK_SUBTRACT
      case 2116: return 0x6B; // KEYCODE_NUMPAD_ADD      → VK_ADD
      case 2117: return 0x6E; // KEYCODE_NUMPAD_DOT      → VK_DECIMAL
      case 2119: return 0x0D; // KEYCODE_NUMPAD_ENTER    → VK_RETURN

      default: return 0;
    }
  }
}
