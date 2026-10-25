/** Thin platform bridge. Ordering, demand and stop state belong to moonlight-common-c. */
export interface ControllerMotionSink {
  sendControllerMotionEvent: (controller: number, type: number, x: number, y: number, z: number) => number;
  sendControllerMotionFrame: (controller: number, gx: number, gy: number, gz: number,
    ax: number, ay: number, az: number) => number;
  stopControllerMotionEvent: (controller: number) => number;
  resetControllerMotionEvents: (controller: number, clearDemand: boolean) => number;
}
