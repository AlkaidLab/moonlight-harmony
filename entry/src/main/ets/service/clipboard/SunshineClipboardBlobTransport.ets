import { NvHttp } from '../streaming/NvHttp'
import { ClipboardBlobTransport } from './ClipboardBlobTransport'
import { ClipboardBlobRef } from './ClipboardSyncConfig'

/**
 * Clipboard blob transport backed by Sunshine HTTPS endpoints.
 */
export class SunshineClipboardBlobTransport implements ClipboardBlobTransport {
  private readonly nvHttp: NvHttp

  constructor(nvHttp: NvHttp) {
    this.nvHttp = nvHttp
  }

  async uploadBlob(mime: string, data: Uint8Array): Promise<ClipboardBlobRef> {
    const result = await this.nvHttp.uploadClipboardBlob(mime, data)
    return {
      type: 'ref',
      id: result.id,
      mime: result.mime,
      size: result.size
    }
  }

  downloadBlob(id: string): Promise<Uint8Array> {
    return this.nvHttp.downloadClipboardBlob(id)
  }
}
