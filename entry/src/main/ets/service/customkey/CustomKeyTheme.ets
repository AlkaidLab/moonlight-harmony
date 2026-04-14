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
 * 自定义按键配色主题工具
 *
 * 包含配色主题定义、预设主题、颜色解析与生成函数。
 */

// =============================================================================
// 配色主题定义
// =============================================================================

/** 配色主题定义 */
export interface ColorTheme {
  /** 主题名称 */
  name: string;
  /** 预览色环颜色（用于主题选择 UI） */
  preview: string;
  /** 按键背景色 */
  bgColor: string;
  /** 文字颜色 */
  textColor: string;
  /** 按压时颜色 */
  pressedColor: string;
  /** 常态边框色 */
  normalColor: string;
}

/** 预设配色主题 */
export const COLOR_THEMES: ColorTheme[] = [
  { name: '冰蓝', preview: '#A8D8EA', bgColor: '#301A3050', textColor: '#E0A8D8EA', pressedColor: '#80A8D8EA', normalColor: '#60A8D8EA' },
  { name: '暗夜', preview: '#808080', bgColor: '#301A1A2E', textColor: '#C0FFFFFF', pressedColor: '#60808090', normalColor: '#40FFFFFF' },
  { name: '翠绿', preview: '#50C080', bgColor: '#30204030', textColor: '#E050C080', pressedColor: '#8050C080', normalColor: '#6050C080' },
  { name: '烈焰', preview: '#FF6B6B', bgColor: '#30401A1A', textColor: '#E0FF6B6B', pressedColor: '#80FF6B6B', normalColor: '#60FF6B6B' },
  { name: '金辉', preview: '#FFD700', bgColor: '#30403010', textColor: '#E0FFD700', pressedColor: '#80FFD700', normalColor: '#60FFD700' },
  { name: '紫韵', preview: '#B070E0', bgColor: '#302A1A40', textColor: '#E0B070E0', pressedColor: '#80B070E0', normalColor: '#60B070E0' },
  { name: '暖橙', preview: '#FF8C00', bgColor: '#30402A10', textColor: '#E0FF8C00', pressedColor: '#80FF8C00', normalColor: '#60FF8C00' },
  { name: '樱粉', preview: '#FFB7C5', bgColor: '#30401A28', textColor: '#E0FFB7C5', pressedColor: '#80FFB7C5', normalColor: '#60FFB7C5' },
  { name: '青碧', preview: '#00CED1', bgColor: '#30103030', textColor: '#E000CED1', pressedColor: '#8000CED1', normalColor: '#6000CED1' },
  { name: '赤金', preview: '#CD7F32', bgColor: '#30302010', textColor: '#E0CD7F32', pressedColor: '#80CD7F32', normalColor: '#60CD7F32' },
  { name: '纯白', preview: '#FFFFFF', bgColor: '#25FFFFFF', textColor: '#E0FFFFFF', pressedColor: '#60FFFFFF', normalColor: '#40FFFFFF' },
  { name: '隐形', preview: '#404040', bgColor: '#10FFFFFF', textColor: '#40FFFFFF', pressedColor: '#30FFFFFF', normalColor: '#20FFFFFF' },
];

// =============================================================================
// 颜色工具函数
// =============================================================================

/**
 * 从 ARGB 十六进制色值中提取 RGB 分量 (0-255)
 */
export function parseHexRGB(hex: string): [number, number, number] {
  const clean = hex.replace('#', '');
  // 支持 AARRGGBB (8位) 和 RRGGBB (6位)
  let r: number, g: number, b: number;
  if (clean.length === 8) {
    r = parseInt(clean.substring(2, 4), 16);
    g = parseInt(clean.substring(4, 6), 16);
    b = parseInt(clean.substring(6, 8), 16);
  } else {
    r = parseInt(clean.substring(0, 2), 16);
    g = parseInt(clean.substring(2, 4), 16);
    b = parseInt(clean.substring(4, 6), 16);
  }
  return [r || 0, g || 0, b || 0];
}

/**
 * 从 RGB 值生成带 alpha 的十六进制颜色字符串 (#AARRGGBB)
 */
export function toHexARGB(a: number, r: number, g: number, b: number): string {
  const clamp = (v: number): number => Math.max(0, Math.min(255, Math.round(v)));
  const toHex = (v: number): string => clamp(v).toString(16).padStart(2, '0').toUpperCase();
  return `#${toHex(a)}${toHex(r)}${toHex(g)}${toHex(b)}`;
}

/**
 * 从主色调 RGB 自动生成完整配色方案
 * 背景: 低透明度主色 | 文字: 高亮度主色 | 按压: 中透明度主色 | 边框: 中透明度主色
 */
export function generateThemeFromAccent(r: number, g: number, b: number): ColorTheme {
  // 计算感知亮度 (0~1)
  const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;

  // 文字色：如果主色太暗，提亮；如果太亮，直接用
  let textR = r, textG = g, textB = b;
  if (luminance < 0.4) {
    // 提亮 40%
    const boost = 1.4;
    textR = Math.min(255, r * boost + 40);
    textG = Math.min(255, g * boost + 40);
    textB = Math.min(255, b * boost + 40);
  }

  return {
    name: '智能',
    preview: toHexARGB(255, r, g, b),
    bgColor: toHexARGB(0x30, r, g, b),
    textColor: toHexARGB(0xE0, textR, textG, textB),
    pressedColor: toHexARGB(0x80, r, g, b),
    normalColor: toHexARGB(0x60, r, g, b),
  };
}

// =============================================================================
// K-means++ 主色调提取
// =============================================================================

/** RGB 像素点 */
export interface RGBPixel {
  r: number;
  g: number;
  b: number;
}

/** 聚类结果 */
export interface KMeansCluster {
  center: RGBPixel;
  count: number;
}

/**
 * 使用 K-means++ 从像素样本中提取主导颜色聚类
 *
 * @param samples - RGB 像素样本数组
 * @param k - 聚类数量（推荐 5）
 * @param maxIter - 最大迭代次数（推荐 20）
 * @returns 按像素数量降序排列的聚类结果
 */
export function kMeansPlusPlus(samples: RGBPixel[], k: number, maxIter: number = 20): KMeansCluster[] {
  if (samples.length === 0) return [];
  const n = samples.length;
  const actualK = Math.min(k, n);

  // ── K-means++ 初始化 ──
  const centers: RGBPixel[] = [];
  // 第一个中心随机选取
  centers.push(samples[Math.floor(Math.random() * n)]);

  const distSq = new Float64Array(n);
  for (let c = 1; c < actualK; c++) {
    // 计算每个样本到最近中心的距离平方
    let totalDist = 0;
    for (let i = 0; i < n; i++) {
      let minD = Number.MAX_VALUE;
      for (let j = 0; j < c; j++) {
        const dr = samples[i].r - centers[j].r;
        const dg = samples[i].g - centers[j].g;
        const db = samples[i].b - centers[j].b;
        const d = dr * dr + dg * dg + db * db;
        if (d < minD) minD = d;
      }
      distSq[i] = minD;
      totalDist += minD;
    }
    // 按距离加权随机选下一个中心
    let r = Math.random() * totalDist;
    for (let i = 0; i < n; i++) {
      r -= distSq[i];
      if (r <= 0) {
        centers.push(samples[i]);
        break;
      }
    }
    if (centers.length === c) {
      // 容错：未选中则取最远点
      let maxIdx = 0;
      for (let i = 1; i < n; i++) {
        if (distSq[i] > distSq[maxIdx]) maxIdx = i;
      }
      centers.push(samples[maxIdx]);
    }
  }

  // ── 迭代聚类 ──
  const assignments = new Int32Array(n);
  for (let iter = 0; iter < maxIter; iter++) {
    // 分配
    for (let i = 0; i < n; i++) {
      let minD = Number.MAX_VALUE;
      let bestC = 0;
      for (let c = 0; c < actualK; c++) {
        const dr = samples[i].r - centers[c].r;
        const dg = samples[i].g - centers[c].g;
        const db = samples[i].b - centers[c].b;
        const d = dr * dr + dg * dg + db * db;
        if (d < minD) { minD = d; bestC = c; }
      }
      assignments[i] = bestC;
    }

    // 更新中心
    let changed = false;
    for (let c = 0; c < actualK; c++) {
      let sumR = 0, sumG = 0, sumB = 0, cnt = 0;
      for (let i = 0; i < n; i++) {
        if (assignments[i] === c) {
          sumR += samples[i].r; sumG += samples[i].g; sumB += samples[i].b;
          cnt++;
        }
      }
      if (cnt > 0) {
        const newR = Math.round(sumR / cnt);
        const newG = Math.round(sumG / cnt);
        const newB = Math.round(sumB / cnt);
        if (newR !== centers[c].r || newG !== centers[c].g || newB !== centers[c].b) {
          centers[c] = { r: newR, g: newG, b: newB };
          changed = true;
        }
      }
    }
    if (!changed) break;
  }

  // 统计每个簇的像素数
  const counts = new Array<number>(actualK).fill(0);
  for (let i = 0; i < n; i++) {
    counts[assignments[i]]++;
  }

  // 构建结果并按数量降序排列
  const result: KMeansCluster[] = [];
  for (let c = 0; c < actualK; c++) {
    result.push({ center: centers[c], count: counts[c] });
  }
  result.sort((a, b) => b.count - a.count);
  return result;
}

/**
 * 从 K-means 聚类结果中选择最佳主题色
 *
 * 策略：在数量占比 >= 5% 的簇中，选饱和度最高的作为主题色
 */
export function pickAccentFromClusters(clusters: KMeansCluster[], totalSamples: number): RGBPixel {
  // 过滤掉太小的簇和接近纯黑的簇
  const viable = clusters.filter(c => {
    const ratio = c.count / totalSamples;
    const brightness = c.center.r + c.center.g + c.center.b;
    return ratio >= 0.05 && brightness > 30;
  });

  if (viable.length === 0) {
    // 退回最大簇
    return clusters[0]?.center ?? { r: 128, g: 128, b: 128 };
  }

  // 选饱和度最高的簇
  let best = viable[0];
  let bestSaturation = 0;
  for (const c of viable) {
    const max = Math.max(c.center.r, c.center.g, c.center.b);
    const min = Math.min(c.center.r, c.center.g, c.center.b);
    const saturation = max > 0 ? (max - min) / max : 0;
    // 加权：饱和度 × 数量占比^0.3（优先大簇，但饱和度更重要）
    const score = saturation * Math.pow(c.count / totalSamples, 0.3);
    if (score > bestSaturation) {
      bestSaturation = score;
      best = c;
    }
  }
  return best.center;
}
