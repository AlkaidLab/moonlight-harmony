import image from '@ohos.multimedia.image';

declare namespace generateBarcode {
  enum ErrorCorrectionLevel {
    LEVEL_L = 0,
    LEVEL_M = 1,
    LEVEL_Q = 2,
    LEVEL_H = 3,
  }
  interface CreateOptions {
    scanType: number;
    width: number;
    height: number;
    margin?: number;
    level?: ErrorCorrectionLevel;
  }
  function createBarcode(content: string, options: CreateOptions): Promise<image.PixelMap>;
}
export default generateBarcode;
