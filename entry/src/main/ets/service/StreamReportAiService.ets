/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2026 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { NvHttp, AiMessage } from './streaming/NvHttp';
import {
  StreamReportData,
  StreamReportStats,
  StreamReportMetric,
  StreamReportConfigSnapshot,
  StreamReportAiStatus,
  copyStreamReportWithAiMeta
} from '../components/StreamSessionReport';

interface StreamReportAiResponse {
  title?: string;
  subtitle?: string;
  conclusion?: string;
  durationTease?: string;
  suggestions?: string[];
}

const SYSTEM_PROMPT =
  '你叫米塔，是 Moonlight V+ 的智能体，负责串流结束复盘。' +
  '你的性格是腹黑、傲娇、喜欢用“杂鱼”轻轻吐槽用户，但本质是在认真帮用户调好串流。' +
  '请根据本次串流数据写一张更鲜活的中文战报，像米塔亲自看完数据后给出的复盘。' +
  '语气要可爱、俏皮、略带坏心眼；可以使用“哼”“才不是”“杂鱼♡”等口癖。' +
  '不要辱骂、不要低俗、不要恐吓，不要把用户写得真的很差。' +
  '只输出 JSON，不要 markdown，不要解释。结构：' +
  '{"title":"8字内标题","subtitle":"16字内副标题","conclusion":"45字内总结","durationTease":"45字内时长吐槽","suggestions":["每条45字内建议，2到3条"]}。' +
  '建议必须基于数据，不要编造不存在的硬件、网络或游戏信息；人设不能盖过调参价值。';

function clampText(value: string | undefined, fallback: string, maxLength: number): string {
  if (!value) return fallback;
  const text = value.trim();
  if (!text) return fallback;
  if (text.length <= maxLength) return text;
  return text.substring(0, maxLength);
}

function stripThinkTags(text: string): string {
  return text.replace(/<think>[\s\S]*?<\/think>/gi, '').trim();
}

function extractJsonObject(text: string): string {
  let jsonText = stripThinkTags(text);
  const codeBlockMatch = jsonText.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (codeBlockMatch) {
    jsonText = codeBlockMatch[1].trim();
  }
  if (!jsonText.startsWith('{')) {
    const objectMatch = jsonText.match(/(\{[\s\S]*\})/);
    if (objectMatch) {
      jsonText = objectMatch[1].trim();
    }
  }
  return jsonText;
}

function compactMetrics(metrics: StreamReportMetric[]): string {
  const parts: string[] = [];
  for (const item of metrics) {
    parts.push(item.label + '=' + item.value + '(' + item.hint + ')');
  }
  return parts.join('; ');
}

function safeFixed(value: number | null | undefined, digits: number, fallback: string): string {
  if (value === null || value === undefined || isNaN(value)) {
    return fallback;
  }
  return value.toFixed(digits);
}

function buildReportPrompt(report: StreamReportData, stats: StreamReportStats,
  config: StreamReportConfigSnapshot | null | undefined, durationMs: number): string {
  const targetFps = config ? config.fps : 0;
  const resolution = config ? (config.width.toString() + 'x' + config.height.toString() + '@' + config.fps.toString()) : 'unknown';
  const codec = config ? config.codec : 'Auto';
  const hdr = config && config.hdr ? 'HDR' : 'SDR';
  return '请优化这张串流战报：\n' +
    '游戏=' + report.appName + '\n' +
    '本地评分=' + report.score.toString() + '/' + report.grade + '\n' +
    '本地结论=' + report.conclusion + '\n' +
    '本地建议=' + report.suggestions.join(' | ') + '\n' +
    '时长毫秒=' + durationMs.toString() + '\n' +
    '配置=' + resolution + ' ' + codec + ' ' + hdr + ' 目标fps=' + targetFps.toString() + '\n' +
    '指标=' + compactMetrics(report.metrics) + '\n' +
    '原始stats=' +
    'avgFps:' + safeFixed(stats.globalAvgFps, 1, '0.0') +
    ', renderedFps:' + safeFixed(stats.renderedFps, 1, '0.0') +
    ', bitrateBps:' + safeFixed(stats.bitrate, 0, '0') +
    ', networkMs:' + safeFixed(stats.networkLatency, 1, '0.0') +
    ', decodeMs:' + safeFixed(stats.globalAvgDecodeLatency, 1, '0.0') +
    ', hostMs:' + safeFixed(stats.globalAvgHostLatency, 1, '0.0') +
    ', packetLoss:' + safeFixed(stats.packetLoss, 2, '0.00') +
    ', droppedFrames:' + safeFixed(stats.droppedFrames, 0, '0') +
    ', decodedFrames:' + safeFixed(stats.decodedFrames, 0, '0') + '\n' +
    '请让话术比模板更自然，保留可执行调参建议。';
}

function applyAiResponse(report: StreamReportData, parsed: StreamReportAiResponse): StreamReportData {
  const next = copyStreamReportWithAiMeta(report, StreamReportAiStatus.READY, '米塔已复盘');
  next.title = clampText(parsed.title, report.title, 10);
  next.subtitle = clampText(parsed.subtitle, report.subtitle, 18);
  next.conclusion = clampText(parsed.conclusion, report.conclusion, 54);
  next.durationTease = clampText(parsed.durationTease, report.durationTease, 54);

  const suggestions: string[] = [];
  if (parsed.suggestions && Array.isArray(parsed.suggestions)) {
    for (const item of parsed.suggestions) {
      if (!item) continue;
      const text = clampText(item, '', 54);
      if (text.length > 0) {
        suggestions.push(text);
      }
      if (suggestions.length >= 3) break;
    }
  }
  if (suggestions.length > 0) {
    next.suggestions = suggestions;
  }
  return next;
}

/**
 * 串流结束战报 AI 复盘服务。
 *
 * 调用 Sunshine 的 OpenAI 兼容 LLM 代理，只返回可直接替换 UI 的短文案。
 */
export class StreamReportAiService {
  private nvHttp: NvHttp;

  constructor(nvHttp: NvHttp) {
    this.nvHttp = nvHttp;
  }

  async summarize(report: StreamReportData, stats: StreamReportStats,
    config: StreamReportConfigSnapshot | null | undefined, durationMs: number): Promise<StreamReportData> {
    const messages: AiMessage[] = [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: buildReportPrompt(report, stats, config, durationMs) }
    ];
    const responseText = await this.nvHttp.aiCompletion(messages, 900);
    const jsonText = extractJsonObject(responseText);
    const parsed: StreamReportAiResponse = JSON.parse(jsonText);
    return applyAiResponse(report, parsed);
  }
}
