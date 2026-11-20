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

/** Zone borders currently controlled by a resize gesture. */
export interface TouchpadZoneEdges {
  left: boolean;
  top: boolean;
  right: boolean;
  bottom: boolean;
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
  private static readonly DIMENSION_EPSILON: number = 1e-9;

  static width(zone: TouchpadZoneRect): number {
    return zone.right - zone.left;
  }

  static height(zone: TouchpadZoneRect): number {
    return zone.bottom - zone.top;
  }

  static formatZoneRect(zone: TouchpadZoneRect): string {
    return zone.left.toFixed(4) + ',' + zone.top.toFixed(4) + ',' +
      zone.right.toFixed(4) + ',' + zone.bottom.toFixed(4);
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
    if (right - left + TouchpadZoneGeometry.DIMENSION_EPSILON < TouchpadZoneGeometry.MIN_ZONE_WIDTH ||
      bottom - top + TouchpadZoneGeometry.DIMENSION_EPSILON < TouchpadZoneGeometry.MIN_ZONE_HEIGHT) {
      return TouchpadZoneGeometry.parseZoneRect(TouchpadZoneGeometry.DEFAULT_ZONE_RECT);
    }
    return { left, top, right, bottom };
  }

  static contains(zone: TouchpadZoneRect, x: number, y: number): boolean {
    return x >= zone.left && x <= zone.right && y >= zone.top && y <= zone.bottom;
  }

  /** Find borders within the normalized resize band around a visible zone. */
  static edgeHitTest(zone: TouchpadZoneRect, x: number, y: number,
    bandX: number, bandY: number): TouchpadZoneEdges | null {
    const nearLeft = Math.abs(x - zone.left) <= bandX;
    const nearRight = Math.abs(x - zone.right) <= bandX;
    const nearTop = Math.abs(y - zone.top) <= bandY;
    const nearBottom = Math.abs(y - zone.bottom) <= bandY;
    const withinX = x >= zone.left - bandX && x <= zone.right + bandX;
    const withinY = y >= zone.top - bandY && y <= zone.bottom + bandY;
    const edges: TouchpadZoneEdges = {
      left: nearLeft && withinY,
      top: nearTop && withinX,
      right: nearRight && withinY,
      bottom: nearBottom && withinX
    };
    if (!edges.left && !edges.top && !edges.right && !edges.bottom) return null;
    return edges;
  }

  /** Move the selected borders while preserving the minimum size and bounds. */
  static resizeEdges(zone: TouchpadZoneRect, edges: TouchpadZoneEdges,
    x: number, y: number): TouchpadZoneRect {
    let left = edges.left ? x : zone.left;
    let top = edges.top ? y : zone.top;
    let right = edges.right ? x : zone.right;
    let bottom = edges.bottom ? y : zone.bottom;
    if (right - left < TouchpadZoneGeometry.MIN_ZONE_WIDTH) {
      if (edges.left && !edges.right) {
        left = right - TouchpadZoneGeometry.MIN_ZONE_WIDTH;
      } else {
        right = left + TouchpadZoneGeometry.MIN_ZONE_WIDTH;
      }
    }
    if (bottom - top < TouchpadZoneGeometry.MIN_ZONE_HEIGHT) {
      if (edges.top && !edges.bottom) {
        top = bottom - TouchpadZoneGeometry.MIN_ZONE_HEIGHT;
      } else {
        bottom = top + TouchpadZoneGeometry.MIN_ZONE_HEIGHT;
      }
    }
    return TouchpadZoneGeometry.clampZoneRect(left, top, right, bottom);
  }

  static clampZoneRect(left: number, top: number, right: number, bottom: number): TouchpadZoneRect {
    let nextLeft = Math.max(0, Math.min(1, left));
    let nextTop = Math.max(0, Math.min(1, top));
    let nextRight = Math.max(0, Math.min(1, right));
    let nextBottom = Math.max(0, Math.min(1, bottom));

    if (nextRight - nextLeft < TouchpadZoneGeometry.MIN_ZONE_WIDTH) {
      const center = (nextLeft + nextRight) / 2;
      nextLeft = center - TouchpadZoneGeometry.MIN_ZONE_WIDTH / 2;
      nextRight = center + TouchpadZoneGeometry.MIN_ZONE_WIDTH / 2;
      if (nextLeft < 0) {
        nextLeft = 0;
        nextRight = TouchpadZoneGeometry.MIN_ZONE_WIDTH;
      } else if (nextRight > 1) {
        nextRight = 1;
        nextLeft = 1 - TouchpadZoneGeometry.MIN_ZONE_WIDTH;
      }
    }

    if (nextBottom - nextTop < TouchpadZoneGeometry.MIN_ZONE_HEIGHT) {
      const center = (nextTop + nextBottom) / 2;
      nextTop = center - TouchpadZoneGeometry.MIN_ZONE_HEIGHT / 2;
      nextBottom = center + TouchpadZoneGeometry.MIN_ZONE_HEIGHT / 2;
      if (nextTop < 0) {
        nextTop = 0;
        nextBottom = TouchpadZoneGeometry.MIN_ZONE_HEIGHT;
      } else if (nextBottom > 1) {
        nextBottom = 1;
        nextTop = 1 - TouchpadZoneGeometry.MIN_ZONE_HEIGHT;
      }
    }

    return { left: nextLeft, top: nextTop, right: nextRight, bottom: nextBottom };
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
