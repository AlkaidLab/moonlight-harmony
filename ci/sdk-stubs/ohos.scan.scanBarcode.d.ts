declare namespace scanBarcode {
  interface ScanOptions {
    scanTypes?: number[];
    enableMultiMode?: boolean;
    enableAlbum?: boolean;
  }
  interface ScanResult {
    originalValue?: string;
    scanType?: number;
  }
  function startScanForResult(context: object, options?: ScanOptions): Promise<ScanResult>;
}
export default scanBarcode;
