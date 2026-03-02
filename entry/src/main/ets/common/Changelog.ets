/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * 更新日志 - Markdown 解析器
 *
 * 维护说明：
 * - 更新日志数据存储在 resources/rawfile/CHANGELOG.md
 * - 格式：## [版本号] - YYYY-MM-DD + ### 新增/优化/修复/移除 + - 条目
 * - 最新版本放在文件最前面
 * - 本模块负责将 Markdown 解析为结构化数据供 UI 使用
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

/**
 * 单条变更项
 */
export interface ChangeItem {
  /** 变更类型 */
  type: 'added' | 'improved' | 'fixed' | 'removed';
  /** 变更描述 */
  text: string;
}

/**
 * 单个版本的更新日志
 */
export interface ChangelogEntry {
  /** 版本号 */
  version: string;
  /** 发布日期 (YYYY-MM-DD) */
  date: string;
  /** 版本摘要（可选，一句话概括） */
  summary?: string;
  /** 变更列表 */
  changes: ChangeItem[];
}

/**
 * 变更类型的显示配置
 */
export interface ChangeTypeConfig {
  label: string;
  color: string;
}

/**
 * 获取变更类型的标签和颜色
 */
export function getChangeTypeConfig(type: string): ChangeTypeConfig {
  switch (type) {
    case 'added':
      return { label: '新增', color: '#34C759' } as ChangeTypeConfig;
    case 'improved':
      return { label: '优化', color: '#007AFF' } as ChangeTypeConfig;
    case 'fixed':
      return { label: '修复', color: '#FF9500' } as ChangeTypeConfig;
    case 'removed':
      return { label: '移除', color: '#FF3B30' } as ChangeTypeConfig;
    default:
      return { label: '其他', color: '#8E8E93' } as ChangeTypeConfig;
  }
}

/**
 * 中文类型标题 → 内部 type 映射
 */
const TYPE_MAP: Record<string, string> = {
  '新增': 'added',
  '优化': 'improved',
  '改进': 'improved',
  '修复': 'fixed',
  '移除': 'removed',
  '删除': 'removed',
};

/**
 * 解析 CHANGELOG.md 文本为结构化数据
 */
export function parseChangelog(markdown: string): ChangelogEntry[] {
  const entries: ChangelogEntry[] = [];
  const lines = markdown.split('\n');

  let currentEntry: ChangelogEntry | null = null;
  let currentType: string = 'added';
  let summaryLines: string[] = [];
  let collectingSummary = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // 匹配版本标题：## [1.0.0] - 2025-01-01
    if (line.startsWith('## [')) {
      // 保存上一个 entry 的摘要
      if (currentEntry !== null && summaryLines.length > 0) {
        currentEntry.summary = summaryLines.join(' ').trim();
      }

      const bracketEnd = line.indexOf(']');
      const dashIdx = line.indexOf(' - ', bracketEnd);
      if (bracketEnd > 4 && dashIdx > bracketEnd) {
        const version = line.substring(4, bracketEnd);
        const date = line.substring(dashIdx + 3).trim();
        currentEntry = {
          version: version,
          date: date,
          summary: undefined,
          changes: []
        } as ChangelogEntry;
        entries.push(currentEntry);
        summaryLines = [];
        collectingSummary = true;
        currentType = 'added';
      }
      continue;
    }

    // 匹配类型标题：### 新增
    if (line.startsWith('### ') && currentEntry !== null) {
      // 摘要收集结束
      if (collectingSummary && summaryLines.length > 0) {
        currentEntry.summary = summaryLines.join(' ').trim();
        summaryLines = [];
      }
      collectingSummary = false;

      const typeName = line.substring(4).trim();
      const mapped = TYPE_MAP[typeName];
      if (mapped !== undefined) {
        currentType = mapped;
      }
      continue;
    }

    // 匹配变更条目：- xxx
    if (line.startsWith('- ') && currentEntry !== null) {
      collectingSummary = false;
      const text = line.substring(2).trim();
      if (text.length > 0) {
        currentEntry.changes.push({ type: currentType, text: text } as ChangeItem);
      }
      continue;
    }

    // 收集摘要行（版本标题和第一个 ### 之间的非空行）
    if (collectingSummary && currentEntry !== null) {
      const trimmed = line.trim();
      if (trimmed.length > 0 && !trimmed.startsWith('<!--') && !trimmed.startsWith('-->')) {
        summaryLines.push(trimmed);
      }
    }
  }

  // 处理最后一个 entry 的摘要
  if (currentEntry !== null && summaryLines.length > 0) {
    currentEntry.summary = summaryLines.join(' ').trim();
  }

  return entries;
}

/**
 * 从 rawfile 加载并解析更新日志
 *
 * @param context 应用上下文
 * @returns 解析后的更新日志条目数组
 */
export async function loadChangelog(context: common.Context): Promise<ChangelogEntry[]> {
  try {
    const resourceManager = context.resourceManager;
    const rawData: Uint8Array = resourceManager.getRawFileContentSync('CHANGELOG.md');
    const decoder = util.TextDecoder.create('utf-8');
    const markdown = decoder.decodeToString(rawData);
    return parseChangelog(markdown);
  } catch (err) {
    console.error('加载更新日志失败:', err);
    return [];
  }
}
