import { ClipboardBlobRef } from './ClipboardSyncConfig'

/**
 * Out-of-band clipboard blob transport for large clipboard payloads.
 */
export interface ClipboardBlobTransport {
  /**
   * Upload a clipboard blob and return a small reference payload that can be
   * sent over the control stream as KIND_REF.
   */
  uploadBlob(mime: string, data: Uint8Array): Promise<ClipboardBlobRef>

  /**
   * Download a previously uploaded clipboard blob by id.
   */
  downloadBlob(id: string): Promise<Uint8Array>
}
