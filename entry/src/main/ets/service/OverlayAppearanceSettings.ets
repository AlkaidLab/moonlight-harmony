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

class AppearanceField {
  key: string;
  min: number;
  max: number;
  defaultValue: number;
  saved: number;
  latest: number;
  revision: number = 0;
  pending: boolean = false;
  known: boolean = false;
  onFailure: (saved: number) => void = (_saved: number): void => {};

  constructor(key: string, initial: number, min: number, max: number) {
    this.key = key;
    this.min = min;
    this.max = max;
    this.defaultValue = initial;
    this.saved = initial;
    this.latest = initial;
  }

  clamp(value: number, fallback: number): number {
    return Number.isFinite(value) ? Math.max(this.min, Math.min(this.max, value)) : fallback;
  }
}

/** Serializes writes and restores the last confirmed value on failure. */
export class AppearanceSettingsWriter {
  private static instance: AppearanceSettingsWriter | null = null;
  private queue: Promise<void> = Promise.resolve();
  private padding: AppearanceField;
  private font: AppearanceField;
  private resetRevision: number = 0;
  private resetsPending: number = 0;
  private ownerRevision: number = 0;
  private ownerDetached: boolean = false;
  private savedCallback: () => void = (): void => {};
  private write: (key: string, value: number) => Promise<void>;
  private read: (key: string, fallback: number) => Promise<number>;

  constructor(padding: number, fontSize: number,
    write: (key: string, value: number) => Promise<void>,
    read: (key: string, fallback: number) => Promise<number>) {
    this.write = write;
    this.read = read;
    this.padding = new AppearanceField(OVERLAY_PADDING_KEY, padding, 0, 32);
    this.font = new AppearanceField(OVERLAY_FONT_SIZE_KEY, fontSize, 8, 24);
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
    const value = await prefs.get(key, fallback);
    if (typeof value === 'number') return Number.isFinite(value) ? value : fallback;
    if (typeof value === 'string' && value.trim().length > 0) {
      const parsed = Number(value);
      return Number.isFinite(parsed) ? parsed : fallback;
    }
    return fallback;
  }

  private async readField(field: AppearanceField): Promise<number> {
    try {
      const fallback = field.known ? field.saved : field.defaultValue;
      return field.clamp(await this.read(field.key, fallback), fallback);
    } catch (error) {
      if (!field.known) throw new Error('Failed to read overlay appearance: ' + String(error));
      return field.saved;
    }
  }

  async load(): Promise<OverlayAppearanceValues> {
    while (true) {
      while (this.resetsPending > 0) await this.queue;
      const paddingRevision = this.padding.revision;
      const fontRevision = this.font.revision;
      const paddingPending = this.padding.pending;
      const fontPending = this.font.pending;
      const resetRevision = this.resetRevision;
      let padding: number;
      let font: number;
      try {
        padding = await this.readField(this.padding);
        font = await this.readField(this.font);
      } catch (error) {
        if (this.resetsPending > 0 || resetRevision !== this.resetRevision) continue;
        throw new Error('Failed to load overlay appearance: ' + String(error));
      }
      if (this.resetsPending > 0 || resetRevision !== this.resetRevision) continue;
      if (!paddingPending && !this.padding.pending && paddingRevision === this.padding.revision) {
        this.confirm(this.padding, padding);
        this.padding.latest = padding;
      }
      if (!fontPending && !this.font.pending && fontRevision === this.font.revision) {
        this.confirm(this.font, font);
        this.font.latest = font;
      }
      return this.snapshot();
    }
  }

  snapshot(): OverlayAppearanceValues {
    return { padding: this.padding.latest, fontSize: this.font.latest };
  }

  attach(onPaddingFailure: (saved: number) => void, onFontFailure: (saved: number) => void,
    onSaved: () => void): number {
    this.padding.onFailure = onPaddingFailure;
    this.font.onFailure = onFontFailure;
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
    if (this.ownerDetached && !this.padding.pending && !this.font.pending) {
      this.padding.onFailure = (_saved: number): void => {};
      this.font.onFailure = (_saved: number): void => {};
      this.savedCallback = (): void => {};
    }
  }

  savePadding(value: number): void { this.save(this.padding, value); }
  saveFontSize(value: number): void { this.save(this.font, value); }

  private confirm(field: AppearanceField, value: number): void {
    field.saved = value;
    field.known = true;
  }

  private save(field: AppearanceField, value: number): void {
    const revision = ++field.revision;
    field.latest = value;
    field.pending = true;
    const onSaved = this.savedCallback;
    this.queue = this.queue.then(async (): Promise<void> => {
      if (revision !== field.revision) return;
      try {
        // A failed read or partially applied replacement leaves no safe value
        // to restore if the following put updates the cache but flush fails.
        if (!field.known) {
          const saved = await this.readField(field);
          this.confirm(field, saved);
          if (revision !== field.revision) return;
        }
        await this.write(field.key, value);
        this.confirm(field, value);
        try { onSaved(); } catch (_) {}
      } catch (_) {
        if (revision !== field.revision) return;
        // put may have changed the preferences cache before flush failed.
        if (field.known) {
          try { await this.write(field.key, field.saved); } catch (_) {}
        }
        if (revision !== field.revision) return;
        field.latest = field.saved;
        try { field.onFailure(field.saved); } catch (_) {}
      }
      if (revision === field.revision) {
        field.pending = false;
        this.releaseDetachedOwner();
      }
    });
  }

  async replacePreferences(replace: () => Promise<void>, restored?: OverlayAppearanceValues): Promise<void> {
    const paddingRevision = this.padding.revision;
    const fontRevision = this.font.revision;
    this.resetRevision++;
    this.resetsPending++;
    const reset = this.queue.then(async (): Promise<void> => {
      try {
        await replace();
        const padding = this.padding.clamp(restored ? restored.padding : await this.read(this.padding.key, 12), 12);
        const font = this.font.clamp(restored ? restored.fontSize : await this.read(this.font.key, 12), 12);
        this.confirm(this.padding, padding);
        this.confirm(this.font, font);
        if (paddingRevision === this.padding.revision) this.padding.latest = padding;
        if (fontRevision === this.font.revision) this.font.latest = font;
      } catch (error) {
        // Replacement may already have changed the preferences cache.
        this.padding.known = false;
        this.font.known = false;
        throw new Error('Failed to replace settings: ' + String(error));
      } finally {
        this.resetsPending--;
        this.resetRevision++;
      }
    });
    this.queue = reset.catch((): void => {});
    await reset;
  }
}
