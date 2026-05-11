/**
 * Clipboard sync configuration and data structures.
 * Based on Sunshine clipboard sync protocol (moonlight-common-c PR #5, control packet 0x5508)
 */

/**
 * Configuration for clipboard synchronization.
 */
export class ClipboardSyncConfig {
  /** Sync changes to local clipboard text with the host */
  enableSyncText: boolean = false

  /** Sync local clipboard images (PNG) with the host */
  enableSyncImage: boolean = false

  /** TTL for echo suppression token history (ms) */
  echoTtlMs: number = 5000

  /** Maximum number of recent sent tokens to track */
  maxTokenHistory: number = 16

  constructor(partial?: Partial<ClipboardSyncConfig>) {
    if (!partial) {
      return
    }

    if (partial.enableSyncText !== undefined) {
      this.enableSyncText = partial.enableSyncText
    }
    if (partial.enableSyncImage !== undefined) {
      this.enableSyncImage = partial.enableSyncImage
    }
    if (partial.echoTtlMs !== undefined) {
      this.echoTtlMs = partial.echoTtlMs
    }
    if (partial.maxTokenHistory !== undefined) {
      this.maxTokenHistory = partial.maxTokenHistory
    }
  }
}

/**
 * Entry in the recent sent tokens queue for echo suppression.
 */
export class TokenEntry {
  token: number
  timestamp: number

  constructor(token: number, timestamp: number) {
    this.token = token
    this.timestamp = timestamp
  }
}

/**
 * Wire format for clipboard sync (v1).
 * Layout (little-endian):
 * - Offset 0: u8 version (= 0x01)
 * - Offset 1: u8 kind (0x01 = TEXT, 0x02 = PNG)
 * - Offset 2-5: u32 token (32-bit random for echo suppression)
 * - Offset 6-9: u32 length (payload size)
 * - Offset 10+: payload (UTF-8 text or PNG bytes)
 */
export interface ClipboardWireParseResult {
  kind: number
  token: number
  payload: Uint8Array
}

export class ClipboardWireFrame {
  static readonly WIRE_VERSION = 1
  static readonly HEADER_SIZE = 10  // version(1) + kind(1) + token(4) + length(4)

  static readonly KIND_TEXT = 1
  static readonly KIND_PNG = 2

  /**
   * Build a wire frame for sending clipboard data.
   * @param kind Clipboard data type (KIND_TEXT or KIND_PNG)
   * @param token Echo suppression token
   * @param payload Data to send
   * @returns Wire frame bytes
   */
  static build(kind: number, token: number, payload: Uint8Array): Uint8Array {
    const totalLen = ClipboardWireFrame.HEADER_SIZE + payload.length
    const frame = new Uint8Array(totalLen)
    const view = new DataView(frame.buffer, frame.byteOffset, totalLen)

    // Version
    view.setUint8(0, ClipboardWireFrame.WIRE_VERSION)

    // Kind
    view.setUint8(1, kind)

    // Token (little-endian u32)
    view.setUint32(2, token, true)

    // Length (little-endian u32)
    view.setUint32(6, payload.length, true)

    // Payload
    frame.set(payload, ClipboardWireFrame.HEADER_SIZE)

    return frame
  }

  /**
   * Parse a wire frame received from the host.
   * @param frame Wire frame bytes
   * @returns { kind, token, payload } or null if invalid
   */
  static parse(frame: Uint8Array): ClipboardWireParseResult | null {
    if (frame.length < ClipboardWireFrame.HEADER_SIZE) {
      return null
    }

    const view = new DataView(frame.buffer, frame.byteOffset, frame.length)

    // Check version
    const version = view.getUint8(0)
    if (version !== ClipboardWireFrame.WIRE_VERSION) {
      return null
    }

    const kind = view.getUint8(1)
    const token = view.getUint32(2, true)
    const length = view.getUint32(6, true)

    if (ClipboardWireFrame.HEADER_SIZE + length !== frame.length) {
      return null
    }

    const payload = frame.slice(ClipboardWireFrame.HEADER_SIZE, ClipboardWireFrame.HEADER_SIZE + length)

    const result: ClipboardWireParseResult = {
      kind: kind,
      token: token,
      payload: payload
    }
    return result
  }
}

/**
 * Callback interface for clipboard sync events.
 */
export interface ClipboardSyncListener {
  /**
   * Called when clipboard data is received from the host.
   * @param kind Data type (KIND_TEXT or KIND_PNG)
   * @param token Echo suppression token
   * @param payload Data bytes
   */
  onClipboardData(kind: number, token: number, payload: Uint8Array): void

  /**
   * Called when clipboard sync encounters an error.
   * @param error Error message
   */
  onError?(error: string): void
}
