/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { PreferencesUtil } from '../utils/PreferencesUtil';

export const OVERLAY_PADDING_KEY: string = 'settings_perf_overlay_vertical_padding';
export const OVERLAY_FONT_SIZE_KEY: string = 'settings_perf_overlay_font_size';

export interface OverlayAppearanceValues {
  padding: number;
  fontSize: number;
}

/** Serialize appearance writes and retain the last successfully flushed values. */
export class AppearanceSettingsWriter {
  private static instance: AppearanceSettingsWriter | null = null;
  private queue: Promise<void> = Promise.resolve();
  private paddingRevision: number = 0;
  private fontRevision: number = 0;
  private savedPadding: number;
  private savedFontSize: number;
  private paddingKnown: boolean = false;
  private fontKnown: boolean = false;
  private latestPadding: number;
  private latestFontSize: number;
  private paddingPending: boolean = false;
  private fontPending: boolean = false;
  private resetRevision: number = 0;
  private resetsPending: number = 0;
  private ownerRevision: number = 0;
  private ownerDetached: boolean = false;
  private paddingFailure: (saved: number) => void = (_saved: number): void => {};
  private fontFailure: (saved: number) => void = (_saved: number): void => {};
  private write: (key: string, value: number) => Promise<void>;
  private read: (key: string, fallback: number) => Promise<number>;
  private savedCallback: () => void = (): void => {};

  constructor(padding: number, fontSize: number, write: (key: string, value: number) => Promise<void>,
    read: (key: string, fallback: number) => Promise<number>) {
    this.savedPadding = padding;
    this.savedFontSize = fontSize;
    this.latestPadding = padding;
    this.latestFontSize = fontSize;
    this.write = write;
    this.read = read;
  }

  static getInstance(): AppearanceSettingsWriter {
    if (!AppearanceSettingsWriter.instance) {
      AppearanceSettingsWriter.instance = new AppearanceSettingsWriter(12, 12,
        (key: string, value: number): Promise<void> => PreferencesUtil.put(key, value),
        (key: string, fallback: number): Promise<number> => AppearanceSettingsWriter.readPreference(key, fallback));
    }
    return AppearanceSettingsWriter.instance;
  }

  private static async readPreference(key: string, fallback: number): Promise<number> {
    const prefs = await PreferencesUtil.getPreferences();
    const rawValue = await prefs.get(key, fallback);
    if (typeof rawValue === 'number') {
      return Number.isFinite(rawValue) ? rawValue : fallback;
    }
    if (typeof rawValue === 'string' && rawValue.trim().length > 0) {
      const parsed = Number(rawValue);
      return Number.isFinite(parsed) ? parsed : fallback;
    }
    return fallback;
  }

  private clamp(value: number, fallback: number, min: number, max: number): number {
    return Number.isFinite(value) ? Math.max(min, Math.min(max, value)) : fallback;
  }

  private async readPadding(): Promise<number> {
    try {
      return this.clamp(await this.read(OVERLAY_PADDING_KEY, this.savedPadding), this.savedPadding, 0, 32);
    } catch (error) {
      if (!this.paddingKnown) throw new Error('Failed to read overlay padding: ' + String(error));
      return this.savedPadding;
    }
  }

  private async readFontSize(): Promise<number> {
    try {
      return this.clamp(await this.read(OVERLAY_FONT_SIZE_KEY, this.savedFontSize), this.savedFontSize, 8, 24);
    } catch (error) {
      if (!this.fontKnown) throw new Error('Failed to read overlay font size: ' + String(error));
      return this.savedFontSize;
    }
  }

  async load(): Promise<OverlayAppearanceValues> {
    while (true) {
      // A replacement can begin before or during the asynchronous reads.
      // Wait for it and retry so a new screen sees the restored values.
      while (this.resetsPending > 0) {
        await this.queue;
      }
      const paddingRevision = this.paddingRevision;
      const fontRevision = this.fontRevision;
      const paddingWasPending = this.paddingPending;
      const fontWasPending = this.fontPending;
      const resetRevision = this.resetRevision;
      let padding: number;
      let fontSize: number;
      try {
        padding = await this.readPadding();
        fontSize = await this.readFontSize();
      } catch (error) {
        if (this.resetsPending > 0 || resetRevision !== this.resetRevision) continue;
        throw new Error('Failed to load overlay appearance: ' + String(error));
      }
      if (this.resetsPending > 0 || resetRevision !== this.resetRevision) continue;
      if (!paddingWasPending && !this.paddingPending && paddingRevision === this.paddingRevision) {
        this.savedPadding = padding;
        this.latestPadding = padding;
        this.paddingKnown = true;
      }
      if (!fontWasPending && !this.fontPending && fontRevision === this.fontRevision) {
        this.savedFontSize = fontSize;
        this.latestFontSize = fontSize;
        this.fontKnown = true;
      }
      return this.snapshot();
    }
  }

  snapshot(): OverlayAppearanceValues {
    return { padding: this.latestPadding, fontSize: this.latestFontSize };
  }

  attach(onPaddingFailure: (saved: number) => void, onFontFailure: (saved: number) => void,
    onSaved: () => void): number {
    this.paddingFailure = onPaddingFailure;
    this.fontFailure = onFontFailure;
    this.savedCallback = onSaved;
    this.ownerDetached = false;
    return ++this.ownerRevision;
  }

  detach(owner: number): void {
    if (owner !== this.ownerRevision) return;
    this.ownerDetached = true;
    this.releaseDetachedOwner();
  }

  private releaseDetachedOwner(): void {
    if (this.ownerDetached && !this.paddingPending && !this.fontPending) {
      this.paddingFailure = (_saved: number): void => {};
      this.fontFailure = (_saved: number): void => {};
      this.savedCallback = (): void => {};
    }
  }

  savePadding(value: number): void {
    const revision = ++this.paddingRevision;
    this.latestPadding = value;
    this.paddingPending = true;
    this.enqueue(OVERLAY_PADDING_KEY, value,
      () => revision === this.paddingRevision, () => this.savedPadding,
      (saved: number) => { this.savedPadding = saved; this.paddingKnown = true; },
      () => { this.paddingPending = false; this.releaseDetachedOwner(); },
      (saved: number) => { this.latestPadding = saved; this.paddingFailure(saved); });
  }

  saveFontSize(value: number): void {
    const revision = ++this.fontRevision;
    this.latestFontSize = value;
    this.fontPending = true;
    this.enqueue(OVERLAY_FONT_SIZE_KEY, value,
      () => revision === this.fontRevision, () => this.savedFontSize,
      (saved: number) => { this.savedFontSize = saved; this.fontKnown = true; },
      () => { this.fontPending = false; this.releaseDetachedOwner(); },
      (saved: number) => { this.latestFontSize = saved; this.fontFailure(saved); });
  }

  async replacePreferences(replace: () => Promise<void>): Promise<void> {
    const paddingRevision = this.paddingRevision;
    const fontRevision = this.fontRevision;
    this.resetRevision++;
    this.resetsPending++;
    const reset = this.queue.then(async (): Promise<void> => {
      try {
        await replace();
        const padding = this.clamp(await this.read(OVERLAY_PADDING_KEY, 12), 12, 0, 32);
        const fontSize = this.clamp(await this.read(OVERLAY_FONT_SIZE_KEY, 12), 12, 8, 24);
        this.savedPadding = padding;
        this.savedFontSize = fontSize;
        this.paddingKnown = true;
        this.fontKnown = true;
        if (paddingRevision === this.paddingRevision) this.latestPadding = padding;
        if (fontRevision === this.fontRevision) this.latestFontSize = fontSize;
      } finally {
        this.resetsPending--;
        this.resetRevision++;
      }
    });
    this.queue = reset.catch((): void => {});
    await reset;
  }

  private enqueue(key: string, value: number, isCurrent: () => boolean, getSaved: () => number,
    confirm: (saved: number) => void, settle: () => void, onFailure: (saved: number) => void): void {
    const onSaved = this.savedCallback;
    this.queue = this.queue.then(async (): Promise<void> => {
      // Skip obsolete slider positions, but never reorder writes that have started.
      if (!isCurrent()) return;
      try {
        await this.write(key, value);
        confirm(value);
        try { onSaved(); } catch (_) {}
        if (isCurrent()) settle();
      } catch (_) {
        if (!isCurrent()) return;
        const saved = getSaved();
        // A failed flush may still have changed the preferences cache. Restore it
        // before handling the error; if restoration also fails, inform the user.
        try {
          await this.write(key, saved);
        } catch (_) {
          // No further recovery is possible here; the next change can retry.
        }
        if (isCurrent()) {
          try {
            onFailure(saved);
          } catch (_) {
            // A UI callback must not permanently block subsequent saves.
          } finally {
            settle();
          }
        }
      }
    });
  }
}
