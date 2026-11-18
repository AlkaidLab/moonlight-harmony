/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/** A touchpad zone expressed in the normalized stream coordinate space. */
export interface TouchpadZoneRect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

export interface TouchpadZonePoint {
  x: number;
  y: number;
}

/**
 * Geometry shared by touch routing and the visual zone overlay.
 * Keeping the values normalized makes the zone stable across resolutions,
 * letterboxing and device orientation changes.
 */
export class TouchpadZoneGeometry {
  static readonly DEFAULT_ZONE_RECT: string = '0.18,0.74,0.82,0.94';
  static readonly MIN_ZONE_WIDTH: number = 0.12;
  static readonly MIN_ZONE_HEIGHT: number = 0.06;

  static width(zone: TouchpadZoneRect): number {
    return zone.right - zone.left;
  }

  static height(zone: TouchpadZoneRect): number {
    return zone.bottom - zone.top;
  }

  static parseZoneRect(raw: string): TouchpadZoneRect {
    const values: number[] = raw.split(',').map((value: string): number => Number(value.trim()));
    if (values.length !== 4 || values.some((value: number): boolean => !Number.isFinite(value))) {
      return TouchpadZoneGeometry.parseZoneRect(TouchpadZoneGeometry.DEFAULT_ZONE_RECT);
    }
    const left = Math.max(0, Math.min(1, values[0]));
    const top = Math.max(0, Math.min(1, values[1]));
    const right = Math.max(0, Math.min(1, values[2]));
    const bottom = Math.max(0, Math.min(1, values[3]));
    if (right - left < TouchpadZoneGeometry.MIN_ZONE_WIDTH ||
      bottom - top < TouchpadZoneGeometry.MIN_ZONE_HEIGHT) {
      return TouchpadZoneGeometry.parseZoneRect(TouchpadZoneGeometry.DEFAULT_ZONE_RECT);
    }
    return { left, top, right, bottom };
  }

  static contains(zone: TouchpadZoneRect, x: number, y: number): boolean {
    return x >= zone.left && x <= zone.right && y >= zone.top && y <= zone.bottom;
  }

  /** Map a normalized screen coordinate into the normalized zone coordinate space. */
  static normalizeToZone(x: number, y: number, zone: TouchpadZoneRect): TouchpadZonePoint {
    const zoneWidth = TouchpadZoneGeometry.width(zone);
    const zoneHeight = TouchpadZoneGeometry.height(zone);
    if (zoneWidth <= 0 || zoneHeight <= 0) {
      return { x: 0, y: 0 };
    }
    return {
      x: Math.max(0, Math.min(1, (x - zone.left) / zoneWidth)),
      y: Math.max(0, Math.min(1, (y - zone.top) / zoneHeight))
    };
  }

}
