import { inputDevice } from '@kit.InputKit';
import { Logger } from '../../common/Logger';
import { classifyGameMouseDevice, GameMouseDeviceInfo, GameMouseDeviceKind } from './GameMouseDevicePolicy';

/** Device capabilities, not SourceTool.MOUSE, distinguish single-finger touchpad motion. */
export class GameMouseDevices {
  private kinds: Map<number, GameMouseDeviceKind> = new Map<number, GameMouseDeviceKind>();
  private queriedUnknownIds: Set<number> = new Set<number>();
  private active: boolean = false;
  private watching: boolean = false;
  private ready: boolean = false;
  private generation: number = 0;
  private onChange = (_event: inputDevice.DeviceListener): void => {
    this.queriedUnknownIds.clear();
    this.refresh();
  };

  start(): void {
    this.stop();
    this.active = true;
    try {
      inputDevice.on('change', this.onChange);
      this.watching = true;
    } catch (_) {}
    this.refresh();
  }

  stop(): void {
    this.active = false;
    this.generation++;
    this.ready = false;
    this.kinds.clear();
    this.queriedUnknownIds.clear();
    if (this.watching) {
      try { inputDevice.off('change', this.onChange); } catch (_) {}
      this.watching = false;
    }
  }

  classify(deviceId: number, sourceTool: SourceTool): GameMouseDeviceKind {
    if (sourceTool === SourceTool.TOUCHPAD) return 'touchpad';
    if (!this.active || !this.ready || deviceId < 0) return 'unknown';
    const kind = this.kinds.get(deviceId);
    if (kind !== undefined) return kind;
    if (!this.queriedUnknownIds.has(deviceId)) {
      this.queriedUnknownIds.add(deviceId);
      this.refresh();
    }
    return 'unknown';
  }

  private async refresh(): Promise<void> {
    if (!this.active) return;
    const generation = ++this.generation;
    this.ready = false;
    this.kinds.clear();
    try {
      const ids = await inputDevice.getDeviceList();
      const devices: GameMouseDeviceInfo[] = [];
      for (const id of ids) {
        if (!this.active || generation !== this.generation) return;
        const info = await inputDevice.getDeviceInfo(id);
        devices.push({ id: info.id, sources: info.sources, bus: info.bus,
          vendor: info.vendor, product: info.product, phys: info.phys ?? '' });
      }
      if (!this.active || generation !== this.generation) return;
      for (const device of devices) {
        const kind = classifyGameMouseDevice(devices, device.id);
        this.kinds.set(device.id, kind);
        if (kind !== 'unknown') {
          Logger.info('GameMouseDevices', `deviceId=${device.id} sources=${device.sources.join(',')} kind=${kind}`);
        }
      }
      this.ready = true;
    } catch (error) {
      if (this.active && generation === this.generation) {
        // A partial inventory could miss a touchpad's sibling Mouse collection.
        // Keep all unidentified input at 1x until the next refresh/reconnection.
        this.ready = true;
        Logger.warn('GameMouseDevices', `设备识别失败，保持原速: ${error}`);
      }
    }
  }
}
