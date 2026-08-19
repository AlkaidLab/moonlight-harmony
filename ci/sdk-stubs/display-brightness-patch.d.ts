
declare namespace display {
  interface BrightnessInfo {
    sdrNits: number;
    currentHeadroom: number;
    maxHeadroom: number;
  }
  type BrightnessCallback<T1, T2> = (data1: T1, data2: T2) => void;
  function getBrightnessInfo(displayId: number): BrightnessInfo;
  function on(type: 'brightnessInfoChange', callback: BrightnessCallback<number, BrightnessInfo>): void;
  function off(type: 'brightnessInfoChange', callback?: BrightnessCallback<number, BrightnessInfo>): void;
}
