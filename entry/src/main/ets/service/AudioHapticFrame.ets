/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2026 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/** Flags authored by the portable audio-haptics SDK. */
export enum AudioHapticFrameFlag {
  NONE = 0,
  CONTINUOUS_CHANGED = 1 << 0,
  TRANSIENT = 1 << 1,
  STOP = 1 << 2,
  RHYTHM_PREDICTED = 1 << 4,
  MUSIC_RESTART = 1 << 5
}

/** Platform-neutral frame emitted by the portable audio-haptics SDK. */
export interface AudioHapticFrame {
  flags: AudioHapticFrameFlag;
  timestampUs: number;
  continuousAmplitude: number;
  transientAmplitude: number;
  transientDurationMs: number;
  sharpness: number;
  lowBandRatio: number;
  stereoPan: number;
  confidence: number;
  activeScene: number;
  presentationDelayMs: number;
}
