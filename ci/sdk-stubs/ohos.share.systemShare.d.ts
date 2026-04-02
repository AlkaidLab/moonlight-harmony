declare namespace systemShare {
  enum SelectionMode {
    SINGLE = 0,
    BATCH = 1,
  }
  enum SharePreviewMode {
    DEFAULT = 0,
    DETAIL = 1,
  }
  interface SharedDataRecord {
    utd: string;
    content?: string;
    uri?: string;
    data?: ArrayBuffer;
    title?: string;
    description?: string;
    thumbnail?: object;
  }
  class SharedData {
    constructor(record: SharedDataRecord);
    addRecord(record: SharedDataRecord): void;
  }
  interface ShareControllerOptions {
    selectionMode?: SelectionMode;
    previewMode?: SharePreviewMode;
  }
  class ShareController {
    constructor(data: SharedData);
    show(context: object, options?: ShareControllerOptions): Promise<void>;
  }
}
export default systemShare;
