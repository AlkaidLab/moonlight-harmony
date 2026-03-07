
declare namespace display {
  interface BrightnessInfo {
    sdrNits: number;
    currentHeadroom: number;
    maxHeadroom: number;
  }
  function getBrightnessInfo(displayId: number): BrightnessInfo;
}
