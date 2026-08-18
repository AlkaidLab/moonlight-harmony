import { display } from '@kit.ArkUI';

/**
 * HDR 亮度采样与聚合
 *
 * 通过 display.getBrightnessInfo 窗口采样估算真实显示能力:
 * - sdrNits: SDR 参考白 (nits)
 * - currentHeadroom / maxHeadroom: 相对 sdrNits 的倍率,峰值 = sdrNits × maxHeadroom
 *
 * 聚合逻辑为纯函数,不依赖 display,便于未来补单元测试。
 */

export interface BrightnessSample {
  sdrNits: number;
  currentHeadroom: number;
  maxHeadroom: number;
}

export interface MeasuredBrightnessProfile {
  sdrNits: number;
  maxBrightness: number;
  maxAverageBrightness: number;
}

/** a13fcce 校验阈值:低于此值视为系统未就绪/瞬态干扰 */
const MIN_RELIABLE_SDR_NITS = 50;
const MIN_RELIABLE_PEAK_NITS = 100;
/** 样本间 sdrNits 最大波动比,超过视为瞬态(自动亮度正在调整) */
const MAX_SDR_VARIANCE_RATIO = 1.5;
const MIN_AGGREGATE_SAMPLES = 3;

function median(values: number[]): number {
  const sorted = values.slice().sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function percentile75(values: number[]): number {
  const sorted = values.slice().sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.75) - 1);
  return sorted[idx];
}

function clampRound(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, Math.round(value)));
}

/** 峰值吸附标准档,避免逐会话微变触发宿主 VDD 重建 */
const MAX_BRIGHTNESS_TIERS: number[] = [400, 600, 800, 1000, 1200, 1600, 2000, 2600, 4000];

function snapToTier(value: number, tiers: number[]): number {
  let best = tiers[0];
  for (const tier of tiers) {
    if (Math.abs(tier - value) < Math.abs(best - value)) {
      best = tier;
    }
  }
  return best;
}

/**
 * 聚合采样并校验可靠性,不可靠返回 null(调用方回退静态 profile)。
 */
export function aggregateBrightnessSamples(samples: BrightnessSample[]): MeasuredBrightnessProfile | null {
  const valid = samples.filter(s =>
    Number.isFinite(s.sdrNits) && Number.isFinite(s.currentHeadroom) && Number.isFinite(s.maxHeadroom) &&
    s.sdrNits >= MIN_RELIABLE_SDR_NITS && s.maxHeadroom > 0 && s.currentHeadroom > 0);
  if (valid.length < MIN_AGGREGATE_SAMPLES) {
    return null;
  }

  const sdrValues = valid.map(s => s.sdrNits);
  const minSdr = Math.min(...sdrValues);
  const maxSdr = Math.max(...sdrValues);
  if (minSdr <= 0 || maxSdr / minSdr > MAX_SDR_VARIANCE_RATIO) {
    return null;
  }

  const sdrNits = median(sdrValues);
  const peak = sdrNits * Math.max(...valid.map(s => s.maxHeadroom));
  if (!(peak >= MIN_RELIABLE_PEAK_NITS) || peak < sdrNits) {
    return null;
  }

  // 峰值先取整钳位,再吸附标准档;吸附跳变超过 ±30% 时保留原值(避免低峰值被拉高太多)
  const clampedPeak = clampRound(peak, MIN_RELIABLE_PEAK_NITS, 10000);
  const snappedPeak = snapToTier(clampedPeak, MAX_BRIGHTNESS_TIERS);
  const maxBrightness = Math.abs(snappedPeak - clampedPeak) <= clampedPeak * 0.3 ? snappedPeak : clampedPeak;
  const maxAverageBrightness = Math.min(maxBrightness,
    Math.round(clampRound(sdrNits * percentile75(valid.map(s => s.currentHeadroom)), 50, 10000) / 50) * 50);

  return { sdrNits: Math.round(sdrNits), maxBrightness, maxAverageBrightness };
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>(resolve => setTimeout(resolve, ms));
}

/**
 * 窗口采样:count 次读取、intervalMs 间隔(默认 5×250ms ≈ 1s)。
 * 单次读取失败跳过,聚合结果不可靠时返回 null。
 */
export async function sampleDisplayBrightness(
  displayId: number = 0,
  count: number = 5,
  intervalMs: number = 250
): Promise<MeasuredBrightnessProfile | null> {
  const samples: BrightnessSample[] = [];
  for (let i = 0; i < count; i++) {
    if (i > 0) {
      await sleep(intervalMs);
    }
    try {
      const info = display.getBrightnessInfo(displayId);
      samples.push({ sdrNits: info.sdrNits, currentHeadroom: info.currentHeadroom, maxHeadroom: info.maxHeadroom });
    } catch (err) {
      console.warn(`[Brightness] getBrightnessInfo 不可用: ${err}`);
    }
  }
  if (samples.length === 0) {
    return null;
  }
  return aggregateBrightnessSamples(samples);
}
