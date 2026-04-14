/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { NvHttp, AiMessage } from './streaming/NvHttp';
import {
  CustomKeyDef,
  KeyAction,
  AnalogStickAction,
  createDefaultKeyDef,
} from './customkey/CustomKeyTypes';

/**
 * AI 按键布局推荐结果
 */
export interface AiKeyRecommendation {
  /** 推荐的按键列表 */
  keys: CustomKeyDef[];
  /** AI 给出的说明 */
  description: string;
}

/** AI 返回的原始按键描述（从 JSON 解析） */
interface AiRawKey {
  label: string;
  action: KeyAction;
  xPercent: number;
  yPercent: number;
  width?: number;
  height?: number;
  shape?: string;
}

/** AI 返回的完整响应结构 */
interface AiLayoutResponse {
  keys: AiRawKey[];
  description?: string;
}

// 系统 prompt：指导 AI 生成按键布局 JSON
const SYSTEM_PROMPT = `你是一个游戏触屏按键布局专家。用户会提供游戏名称，你需要为手机触屏串流生成推荐的虚拟按键布局。

规则：
1. 返回纯 JSON，不要 markdown 代码块，不要额外解释
2. JSON 格式: { "keys": [...], "description": "简要说明" }
3. 每个按键包含: label, action, xPercent (0-1), yPercent (0-1)
4. 坐标系: xPercent=0 左边, xPercent=1 右边, yPercent=0 上方, yPercent=1 下方。坐标代表按键中心点
5. 手机横屏模式 (约 720×360 vp)，左侧放移动控制，右侧放视角/动作按键
6. action 类型:
   - 键盘: { "type": "keyboard", "vk": <Windows VK code> }
   - 鼠标: { "type": "mouse", "button": 1|2|3 }
   - 手柄: { "type": "gamepadButton", "mask": <bitmask> }
   - 摇杆: { "type": "analogStick", "stick": "left"|"right" }
   - 隐形摇杆(大触摸区,按下才显示): { "type": "analogStick", "stick": "left"|"right", "invisible": true }
   - 十字键: { "type": "dpad" }
   - 扳机: { "type": "gamepadTrigger", "trigger": "left"|"right" }
   - 快捷键: { "type": "shortcut", "keys": [vk1, vk2] }
7. 常用 VK: W=0x57 A=0x41 S=0x53 D=0x44 Space=0x20 Shift=0xA0 Ctrl=0xA2 E=0x45 R=0x52 F=0x46 Q=0x51 Tab=0x09 ESC=0x1B 1-9=0x31-0x39
8. 手柄 mask: A=0x1000 B=0x2000 X=0x4000 Y=0x8000 LB=0x0100 RB=0x0200 Start=0x0010 Back=0x0020
9. 尽可能多生成按键(12-16个)，完整覆盖游戏常用操作，包含移动、视角、主要动作和辅助功能键
10. FPS 游戏优先用键鼠布局（WASD + 鼠标按键），动作/平台游戏用手柄布局
11. 布局间距要求：
    - 普通按键(60vp)占屏幕约 8%宽 17%高，相邻按键中心距至少 10%
    - 摇杆(120vp)占约 17%宽 33%高，周围留足空间
    - 坐标范围安全区: xPercent [0.05, 0.95], yPercent [0.08, 0.92]
    - 右侧摇杆推荐用隐形摇杆(invisible=true)作为视角，不与动作键区域重叠
12. 键鼠 FPS 推荐布局：左侧隐形左摇杆(移动)，右侧隐形右摇杆(视角)，动作键放右侧边缘避开摇杆区域`;

/**
 * AI 按键布局推荐服务
 *
 * 通过 Sunshine 的 LLM 代理端点获取游戏按键布局推荐
 */
export class AiKeyService {
  private nvHttp: NvHttp;

  constructor(nvHttp: NvHttp) {
    this.nvHttp = nvHttp;
  }

  /**
   * 根据游戏名称获取推荐的按键布局
   * @param gameName 游戏名称
   * @returns 推荐的按键定义列表和说明
   */
  async getRecommendation(gameName: string): Promise<AiKeyRecommendation> {
    const messages: AiMessage[] = [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: `为游戏「${gameName}」生成触屏按键布局` },
    ];

    const responseText = await this.nvHttp.aiCompletion(messages, 4096);

    return this.parseResponse(responseText);
  }

  /**
   * 用户自定义提示获取推荐
   * @param prompt 用户的自定义描述
   * @returns 推荐的按键定义列表和说明
   */
  async getRecommendationByPrompt(prompt: string): Promise<AiKeyRecommendation> {
    const messages: AiMessage[] = [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: prompt },
    ];

    const responseText = await this.nvHttp.aiCompletion(messages, 4096);

    return this.parseResponse(responseText);
  }

  private parseResponse(responseText: string): AiKeyRecommendation {
    // 尝试提取 JSON（AI 可能返回 markdown 代码块包裹或夹杂解释文字）
    let jsonStr = responseText.trim();

    // 1. 尝试 markdown 代码块
    const codeBlockMatch = jsonStr.match(/```(?:json)?\s*([\s\S]*?)```/);
    if (codeBlockMatch) {
      jsonStr = codeBlockMatch[1].trim();
    }

    // 2. 如果不是以 { 开头，尝试提取第一个 {...} JSON 对象
    if (!jsonStr.startsWith('{')) {
      const jsonObjMatch = jsonStr.match(/(\{[\s\S]*\})/);
      if (jsonObjMatch) {
        jsonStr = jsonObjMatch[1].trim();
      }
    }

    const parsed = JSON.parse(jsonStr) as AiLayoutResponse;

    if (!parsed.keys || !Array.isArray(parsed.keys)) {
      throw new Error('AI 返回格式无效：缺少 keys 数组');
    }

    const keys: CustomKeyDef[] = [];
    for (const raw of parsed.keys) {
      if (!raw.label || !raw.action) continue;

      // 根据 action 类型选择默认外观
      const appearance = getAppearanceForAction(raw.action);
      // 决定形状：复合控件(摇杆/十字键)用各自默认，其余按 action 类型
      const isCircleType = raw.action.type === 'gamepadButton' || raw.action.type === 'gamepadTrigger' ||
        raw.action.type === 'gamepadStick' || raw.action.type === 'mouse' ||
        raw.action.type === 'mouseScroll' || raw.action.type === 'analogStick';
      const shape = isCircleType ? 'circle' : 'rect';

      const keyDef = createDefaultKeyDef({
        label: raw.label,
        action: raw.action,
        xPercent: clamp(raw.xPercent ?? 0.5, 0, 1),
        yPercent: clamp(raw.yPercent ?? 0.5, 0, 1),
        width: appearance.width,
        height: appearance.height,
        shape: shape as 'rect' | 'circle',
        bgColor: appearance.bgColor,
        pressedColor: appearance.pressedColor,
        textColor: appearance.textColor,
        borderRadius: appearance.borderRadius,
        fontSize: appearance.fontSize,
      });
      keys.push(keyDef);
    }

    // 防重叠后处理：检测并推开过近的按键
    resolveOverlaps(keys);

    return {
      keys,
      description: parsed.description ?? '',
    };
  }
}

/**
 * 检测并修复按键重叠
 * 基于按键尺寸计算最小安全距离，迭代推开过近的按键
 */
function resolveOverlaps(keys: CustomKeyDef[]): void {
  const SCREEN_W = 720;
  const SCREEN_H = 360;
  const MAX_ITER = 10;

  for (let iter = 0; iter < MAX_ITER; iter++) {
    let hasOverlap = false;
    for (let i = 0; i < keys.length; i++) {
      for (let j = i + 1; j < keys.length; j++) {
        const a = keys[i];
        const b = keys[j];
        // 隐形摇杆不参与碰撞检测
        if ((a.action as AnalogStickAction).invisible || (b.action as AnalogStickAction).invisible) continue;

        const minDx = (a.width + b.width) / 2 / SCREEN_W + 0.01;
        const minDy = (a.height + b.height) / 2 / SCREEN_H + 0.01;
        const dx = Math.abs(a.xPercent - b.xPercent);
        const dy = Math.abs(a.yPercent - b.yPercent);

        if (dx < minDx && dy < minDy) {
          hasOverlap = true;
          // 沿两者连线方向推开
          const pushX = (minDx - dx) / 2 + 0.01;
          const pushY = (minDy - dy) / 2 + 0.01;
          if (a.xPercent <= b.xPercent) {
            a.xPercent = clamp(a.xPercent - pushX, 0.05, 0.95);
            b.xPercent = clamp(b.xPercent + pushX, 0.05, 0.95);
          } else {
            a.xPercent = clamp(a.xPercent + pushX, 0.05, 0.95);
            b.xPercent = clamp(b.xPercent - pushX, 0.05, 0.95);
          }
          if (a.yPercent <= b.yPercent) {
            a.yPercent = clamp(a.yPercent - pushY, 0.08, 0.92);
            b.yPercent = clamp(b.yPercent + pushY, 0.08, 0.92);
          } else {
            a.yPercent = clamp(a.yPercent + pushY, 0.08, 0.92);
            b.yPercent = clamp(b.yPercent - pushY, 0.08, 0.92);
          }
        }
      }
    }
    if (!hasOverlap) break;
  }
}

function clamp(v: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, v));
}

interface KeyAppearance {
  width: number;
  height: number;
  bgColor: string;
  pressedColor: string;
  textColor: string;
  borderRadius: number;
  fontSize: number;
}

function getAppearanceForAction(action: KeyAction): KeyAppearance {
  switch (action.type) {
    case 'gamepadButton':
    case 'gamepadTrigger':
    case 'gamepadStick':
      return {
        width: 56, height: 56,
        bgColor: '#3050C080', pressedColor: '#8050C080', textColor: '#E0FFFFFF',
        borderRadius: 28, fontSize: 13
      };
    case 'analogStick': {
      const actionObj = action as AnalogStickAction;
      const isInvisible = actionObj.invisible === true;
      return {
        width: isInvisible ? 200 : 120,
        height: isInvisible ? 200 : 120,
        bgColor: '#4050C080', pressedColor: '#8070E090', textColor: '#E0FFFFFF',
        borderRadius: isInvisible ? 100 : 60, fontSize: 12
      };
    }
    case 'dpad':
      return {
        width: 120, height: 120,
        bgColor: '#3050C080', pressedColor: '#8070E090', textColor: '#E0FFFFFF',
        borderRadius: 8, fontSize: 12
      };
    case 'mouse':
    case 'mouseScroll':
      return {
        width: 52, height: 52,
        bgColor: '#30A070C0', pressedColor: '#80A070C0', textColor: '#E0FFFFFF',
        borderRadius: 26, fontSize: 14
      };
    case 'shortcut':
      return {
        width: 76, height: 44,
        bgColor: '#30C09050', pressedColor: '#80C09050', textColor: '#FFFFD080',
        borderRadius: 12, fontSize: 11
      };
    default:
      return {
        width: 60, height: 60,
        bgColor: '#30FFFFFF', pressedColor: '#80A8D8EA', textColor: '#E0FFFFFF',
        borderRadius: 12, fontSize: 14
      };
  }
}
