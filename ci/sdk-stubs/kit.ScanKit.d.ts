declare module '@kit.ScanKit' {
  namespace scanCore {
    enum ScanType {
      QR_CODE = 0,
      BARCODE_TYPE_EAN_13 = 1,
      BARCODE_TYPE_EAN_8 = 2,
      BARCODE_TYPE_CODE_128 = 3,
    }
  }
  namespace scanBarcode {
    interface ScanOptions {
      scanTypes?: scanCore.ScanType[];
      enableMultiMode?: boolean;
      enableAlbum?: boolean;
    }
    interface ScanResult {
      originalValue?: string;
      scanType?: number;
    }
    function startScanForResult(context: object, options?: ScanOptions): Promise<ScanResult>;
  }
}
