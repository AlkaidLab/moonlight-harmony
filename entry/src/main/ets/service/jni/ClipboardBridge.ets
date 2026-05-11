/**
 * JNI bridge to native moonlight-common-c for clipboard synchronization.
 * 
 * This module provides native bindings for sending and receiving clipboard data
 * through the Sunshine control stream (message type 0x5508).
 */

import nativeLib from 'libmoonlight_nativelib.so'
import { ClipboardSyncListener } from '../clipboard/ClipboardSyncConfig'

/**
 * Clipboard-related native bindings and constants.
 */
export namespace MoonBridge {
  /**
   * Clipboard data kinds (from ClipboardSyncManager.kt).
   */
  export enum ClipboardKind {
    TEXT = 1,
    PNG = 2
  }

  /**
   * Wire frame header size in bytes (version + kind + token + length).
   */
  export const CLIPBOARD_WIRE_HEADER = 10

  /**
   * Maximum clipboard payload size (one ENet control packet - header).
   */
  export const MAX_CLIPBOARD_PAYLOAD = 65500 - CLIPBOARD_WIRE_HEADER

  // Error codes from LiSendClipboardData
  export enum SendErrorCode {
    SUCCESS = 0,
    INVALID_PAYLOAD = -1,      // payload null, <= 0 bytes, or > 65535 bytes
    NOT_SUPPORTED = -2,        // Not Sunshine + Gen5+, or server doesn't support clipboard
    DISCONNECTED = -3,         // Peer not connected
    SEND_FAILED = -4           // ENet send failed
  }

  /**
   * Global clipboard listener (singleton).
   */
  let clipboardListener: ClipboardSyncListener | null = null

  /**
   * Register a listener for inbound clipboard data from host.
   */
  export function setClipboardListener(listener: ClipboardSyncListener | null): void {
    clipboardListener = listener
  }

  /**
   * Send clipboard data to the host.
   * 
   * Builds a v1 wire frame and sends it via the control stream.
   * 
   * Wire format (little-endian):
   * - Offset 0: u8 version (= 0x01)
   * - Offset 1: u8 kind
   * - Offset 2-5: u32 token
   * - Offset 6-9: u32 length
   * - Offset 10+: payload
   * 
   * @param frame Complete wire frame including header and payload
   * @returns 0 on success, negative error code on failure
   */
  export function sendClipboardData(frame: Uint8Array): number {
    if (frame.length < CLIPBOARD_WIRE_HEADER) {
      return SendErrorCode.INVALID_PAYLOAD
    }

    if (frame.length > 65535) {
      return SendErrorCode.INVALID_PAYLOAD
    }

    // Call native method exported by libmoonlight_nativelib.so
    return nativeLib.sendClipboardData(frame) as number
  }

  /**
   * Called from native code when clipboard data arrives from the host.
   * The caller must ensure the payload is properly framed.
   * 
   * @param kind Clipboard data type (KIND_TEXT or KIND_PNG)
   * @param token Echo suppression token
   * @param payload Data bytes
   * @internal
   */
  export function onClipboardDataReceived(kind: number, token: number, payload: Uint8Array): void {
    if (clipboardListener) {
      try {
        clipboardListener.onClipboardData(kind, token, payload)
      } catch (error) {
        console.error(`ClipboardSyncListener.onClipboardData threw: ${error}`)
      }
    }
  }

}

/**
 * Native clipboard callback interface.
 * 
 * When the control stream thread receives a 0x5508 clipboard packet,
 * it calls this Java interface method to route the data to the active listener.
 */
export interface IClipboardCallback {
  /**
   * Invoked by native code when clipboard data arrives from the host.
   */
  onClipboardData(kind: number, token: number, payload: Uint8Array): void
}
