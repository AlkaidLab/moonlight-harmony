/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
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
  /** v2 schema：内部推理（仅日志使用，不展示） */
  _thinking?: string;
  /** v2 schema：游戏品类，例 FPS / 动作 / MOBA */
  genre?: string;
  /** v2 schema：控制方案，例 键鼠 / 手柄 / 混合 */
  scheme?: string;
}

// System prompt 存放在 resources/rawfile/ai_key_prompt.md
const PROMPT_RAWFILE = 'ai_key_prompt.md';
/** 进程级缓存：prompt 是不变的纯文本，加载一次即可 */
let cachedPrompt: string | null = null;

/**
 * AI 按键布局推荐服务
 *
 * 通过 Sunshine 的 LLM 代理端点获取游戏按键布局推荐。
 * System prompt 从 rawfile/ai_key_prompt.md 加载（首次调用时同步读取并缓存）。
 */
export class AiKeyService {
  private nvHttp: NvHttp;
  private context: common.Context;

  constructor(nvHttp: NvHttp, context: common.Context) {
    this.nvHttp = nvHttp;
    this.context = context;
  }

  /** 加载并缓存 system prompt */
  private loadSystemPrompt(): string {
    if (cachedPrompt !== null) return cachedPrompt;
    const raw: Uint8Array = this.context.resourceManager.getRawFileContentSync(PROMPT_RAWFILE);
    const decoder = util.TextDecoder.create('utf-8');
    cachedPrompt = decoder.decodeToString(raw);
    return cachedPrompt;
  }

  /**
   * 根据游戏名称获取推荐的按键布局
   * @param gameName 游戏名称
   * @returns 推荐的按键定义列表和说明
   */
  async getRecommendation(gameName: string): Promise<AiKeyRecommendation> {
    const messages: AiMessage[] = [
      { role: 'system', content: this.loadSystemPrompt() },
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
      { role: 'system', content: this.loadSystemPrompt() },
      { role: 'user', content: prompt },
    ];

    const responseText = await this.nvHttp.aiCompletion(messages, 4096);

    return this.parseResponse(responseText);
  }

  private parseResponse(responseText: string): AiKeyRecommendation {
    // 尝试提取 JSON（AI 可能返回 markdown 代码块包裹或夹杂解释文字）
    let jsonStr = responseText.trim();

    // 0. 剥掉 reasoning 模型可能输出的 <think>...</think> 推理标签
    jsonStr = jsonStr.replace(/<think>[\s\S]*?<\/think>/gi, '').trim();

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

    // 3. 容错：JSON 不支持 0x 十六进制字面量；若 LLM 误输出 0xABCD，
    //    转换成十进制再解析。仅替换 :/[/, 后紧跟的 0x... 数值，避免误伤字符串内容。
    jsonStr = jsonStr.replace(/([:\[,]\s*)(0x[0-9A-Fa-f]+)/g,
      (_match, prefix: string, hex: string) => `${prefix}${parseInt(hex, 16)}`);

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

    // 拼装最终展示给用户的 description：优先 description，
    // 否则用 v2 schema 的 genre/scheme 兜底；_thinking 仅打印到日志（这里直接丢弃）
    let description = parsed.description ?? '';
    if (!description && (parsed.genre || parsed.scheme)) {
      const parts: string[] = [];
      if (parsed.genre) parts.push(parsed.genre);
      if (parsed.scheme) parts.push(parsed.scheme);
      description = parts.join(' · ');
    }
    if (parsed._thinking) {
      console.info(`[AiKeyService] LLM thinking: ${parsed._thinking}`);
    }

    return {
      keys,
      description,
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
