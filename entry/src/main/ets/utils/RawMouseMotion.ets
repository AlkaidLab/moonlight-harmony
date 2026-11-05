/** Converts ArkUI relative motion to integral mouse hardware counts. */
export class MouseMotion {
  x: number = 0;
  y: number = 0;
}

export class RawMouseMotion {
  private remainderX: number = 0;
  private remainderY: number = 0;

  reset(): void {
    this.remainderX = 0;
    this.remainderY = 0;
  }

  consume(rawX: number, rawY: number, apiVersion: number, pixelsPerVp: number): MouseMotion {
    const motion: MouseMotion = new MouseMotion();
    if (!Number.isFinite(rawX) || !Number.isFinite(rawY)) {
      return motion;
    }
    // API 26 fixes rawDelta to return hardware counts. Earlier releases divide
    // by display scaling; undo that scaling using the originating UIContext.
    const scale: number = apiVersion < 26 && Number.isFinite(pixelsPerVp) && pixelsPerVp > 0 ?
      pixelsPerVp : 1;
    this.remainderX += rawX * scale;
    this.remainderY += rawY * scale;
    motion.x = Math.trunc(this.remainderX);
    motion.y = Math.trunc(this.remainderY);
    this.remainderX -= motion.x;
    this.remainderY -= motion.y;
    return motion;
  }
}
