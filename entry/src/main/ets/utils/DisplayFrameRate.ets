import { display } from '@kit.ArkUI';

// An empty capability list means unknown, not a 60 Hz hardware limit.
export function getSupportedDisplayRates(): number[] {
  try {
    const rates = display.getDefaultDisplaySync().supportedRefreshRates;
    if (rates) {
      return rates.filter((rate: number) => Number.isFinite(rate) && rate > 0);
    }
  } catch (err) {
    console.warn(`[DisplayFrameRate] 读取 supportedRefreshRates 失败: ${err}`);
  }
  return [];
}

export function getDisplayRequestHz(fps: number): number {
  if (!Number.isFinite(fps) || fps <= 0) return 60;
  const desired = Math.max(1, Math.round(fps));
  const rates = getSupportedDisplayRates();
  if (rates.length === 0) return desired;
  // Choose a supported rate at or above the stream rate when possible.
  const sorted = rates.slice().sort((a: number, b: number) => a - b);
  for (const rate of sorted) {
    if (rate >= desired) return Math.round(rate);
  }
  return Math.round(sorted[sorted.length - 1]);
}
