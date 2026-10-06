export type GameMouseDeviceKind = 'mouse' | 'touchpad' | 'unknown';

export function gameTouchpadUsesAcceleration(kind: GameMouseDeviceKind, mode: string): boolean {
  return kind === 'touchpad' && mode === 'accelerated';
}

export function gameMouseGain(kind: GameMouseDeviceKind, mouseGain: number,
  touchpadEnabled: boolean, touchpadGain: number): number {
  if (kind === 'mouse') return mouseGain;
  if (kind === 'touchpad' && touchpadEnabled) return touchpadGain;
  return 1.0;
}

export interface GameMouseDeviceInfo {
  id: number;
  sources: string[];
  bus: number;
  vendor: number;
  product: number;
  phys: string;
}

export function classifyGameMouseDevice(devices: GameMouseDeviceInfo[], deviceId: number): GameMouseDeviceKind {
  const device = devices.find((item: GameMouseDeviceInfo) => item.id === deviceId);
  if (!device) return 'unknown';
  if (device.sources.includes('touchpad')) return 'touchpad';
  if (!device.sources.includes('mouse')) return 'unknown';
  // A touchpad can expose a second HID collection named "Mouse". Preserve
  // its original speed too; do not classify devices by their display names.
  if (device.phys.length > 0 && devices.some((item: GameMouseDeviceInfo) =>
    item.sources.includes('touchpad') && item.phys === device.phys &&
    item.bus === device.bus && item.vendor === device.vendor && item.product === device.product)) {
    return 'touchpad';
  }
  return 'mouse';
}
