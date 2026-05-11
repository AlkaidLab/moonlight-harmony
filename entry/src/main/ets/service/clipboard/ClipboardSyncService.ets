import { pasteboard, BusinessError } from '@kit.BasicServicesKit'
import { image } from '@kit.ImageKit'
import { StringUtil } from '../../utils/StringUtil'
import { MoonBridge } from '../jni/ClipboardBridge'
import {
  ClipboardSyncConfig,
  ClipboardWireFrame,
  TokenEntry,
  ClipboardSyncListener
} from './ClipboardSyncConfig'

const TAG = 'ClipboardSyncService'
const MAX_CLIPBOARD_FRAME_BYTES = 65500 - ClipboardWireFrame.HEADER_SIZE

type PasteboardUpdateListener = () => void

interface PasteDataPixelMapAccessor {
  getPrimaryPixelMap(): image.PixelMap
}

export interface ClipboardSyncObserver {
  onError?(error: string): void
}

function logInfo(message: string): void {
  console.info(`[${TAG}] ${message}`)
}

function logWarn(message: string): void {
  console.warn(`[${TAG}] ${message}`)
}

function logError(message: string): void {
  console.error(`[${TAG}] ${message}`)
}

function formatError(err: Object): string {
  const businessError = err as BusinessError
  const error = err as Error
  if (businessError && businessError.message) {
    return businessError.message
  }
  if (error && error.message) {
    return error.message
  }
  return 'unknown error'
}

/**
 * Manages clipboard synchronization between HarmonyOS and Sunshine host.
 */
export class ClipboardSyncService implements ClipboardSyncListener {
  private config: ClipboardSyncConfig
  private observer: ClipboardSyncObserver | null = null
  private recentSentTokens: TokenEntry[] = []
  private pendingSelfWrites: number = 0
  private pasteboardEventListener: PasteboardUpdateListener | null = null
  private isRunning: boolean = false

  constructor(config?: ClipboardSyncConfig, observer?: ClipboardSyncObserver) {
    this.config = config ? config : new ClipboardSyncConfig()
    this.observer = observer ? observer : null
  }

  start(): void {
    if (this.isRunning) {
      return
    }

    if (!this.config.enableSyncText && !this.config.enableSyncImage) {
      logInfo('Clipboard sync disabled in config')
      return
    }

    this.setupPasteboardListener()
    this.registerWithMoonBridge()
    this.isRunning = true

    logInfo(`Clipboard sync started (text=${this.config.enableSyncText}, image=${this.config.enableSyncImage})`)
  }

  stop(): void {
    if (!this.isRunning) {
      return
    }

    this.unregisterFromMoonBridge()
    this.removePasteboardListener()
    this.recentSentTokens = []
    this.pendingSelfWrites = 0
    this.isRunning = false

    logInfo('Clipboard sync stopped')
  }

  private setupPasteboardListener(): void {
    try {
      const sysBoard = pasteboard.getSystemPasteboard()
      if (!this.pasteboardEventListener) {
        this.pasteboardEventListener = (): void => {
          void this.onPasteboardChanged()
        }
      } else {
        sysBoard.off('update', this.pasteboardEventListener)
      }
      sysBoard.on('update', this.pasteboardEventListener)
    } catch (err) {
      const message = formatError(err as Object)
      logError(`Failed to setup pasteboard listener: ${message}`)
      this.observer?.onError?.(`无法监听剪贴板：${message}`)
    }
  }

  private removePasteboardListener(): void {
    if (!this.pasteboardEventListener) {
      return
    }

    try {
      const sysBoard = pasteboard.getSystemPasteboard()
      sysBoard.off('update', this.pasteboardEventListener)
      this.pasteboardEventListener = null
    } catch (err) {
      logError(`Failed to remove pasteboard listener: ${formatError(err as Object)}`)
    }
  }

  private registerWithMoonBridge(): void {
    MoonBridge.setClipboardListener(this)
  }

  private unregisterFromMoonBridge(): void {
    MoonBridge.setClipboardListener(null)
  }

  private async onPasteboardChanged(): Promise<void> {
    if (this.pendingSelfWrites > 0) {
      this.pendingSelfWrites--
      return
    }

    if (!this.config.enableSyncText && !this.config.enableSyncImage) {
      return
    }

    try {
      const sysBoard = pasteboard.getSystemPasteboard()
      const pasteData = await sysBoard.getData()
      const text = this.config.enableSyncText ? pasteData.getPrimaryText() : ''

      if (this.config.enableSyncText && text && text.length > 0) {
        this.sendPayload(
          ClipboardWireFrame.KIND_TEXT,
          this.generateToken(),
          StringUtil.stringToUint8Array(text)
        )
        return
      }

      if (this.config.enableSyncImage) {
        const primaryPixelMap = this.tryGetPrimaryPixelMap(pasteData)
        if (primaryPixelMap) {
          await this.sendImagePayload(primaryPixelMap)
          return
        }
      }

      if (!this.config.enableSyncText) {
        return
      }
    } catch (err) {
      const message = formatError(err as Object)
      logError(`Failed to read local clipboard: ${message}`)
      this.observer?.onError?.(`读取本地剪贴板失败：${message}`)
    }
  }

  private tryGetPrimaryPixelMap(pasteData: pasteboard.PasteData): image.PixelMap | null {
    try {
      const accessor = pasteData as PasteDataPixelMapAccessor
      const pixelMap = accessor.getPrimaryPixelMap()
      return pixelMap ? pixelMap : null
    } catch (_err) {
      return null
    }
  }

  private async sendImagePayload(pixelMap: image.PixelMap): Promise<void> {
    let packer: image.ImagePacker | null = null
    try {
      packer = image.createImagePacker()
      const packed = await packer.packing(pixelMap, { format: 'image/png', quality: 100 }) as ArrayBuffer
      const payload = new Uint8Array(packed)

      if (payload.length === 0) {
        return
      }

      if (payload.length > MAX_CLIPBOARD_FRAME_BYTES) {
        logWarn(`Clipboard PNG payload size=${payload.length} exceeds limit, dropping`)
        this.observer?.onError?.('剪贴板图片过大，已跳过同步')
        return
      }

      this.sendPayload(
        ClipboardWireFrame.KIND_PNG,
        this.generateToken(),
        payload
      )
    } catch (err) {
      const message = formatError(err as Object)
      logError(`Failed to encode clipboard image: ${message}`)
      this.observer?.onError?.(`读取本地剪贴板图片失败：${message}`)
    } finally {
      if (packer) {
        packer.release()
      }
    }
  }

  private toExactArrayBuffer(data: Uint8Array): ArrayBuffer {
    const copy = new Uint8Array(data.length)
    copy.set(data)
    return copy.buffer
  }

  private async decodePngPayload(payload: Uint8Array): Promise<image.PixelMap> {
    const imageSource: image.ImageSource = image.createImageSource(this.toExactArrayBuffer(payload))
    try {
      return await imageSource.createPixelMap({})
    } finally {
      imageSource.release()
    }
  }

  private writePixelMapToPasteboard(pixelMap: image.PixelMap): void {
    const createPixelMapData = pasteboard.createData as (mimeType: string, value: image.PixelMap) => pasteboard.PasteData
    const sysBoard = pasteboard.getSystemPasteboard()
    const pasteData = createPixelMapData(pasteboard.MIMETYPE_PIXELMAP, pixelMap)
    sysBoard.setDataSync(pasteData)
  }

  private sendPayload(kind: number, token: number, payload: Uint8Array): void {
    if (payload.length > MAX_CLIPBOARD_FRAME_BYTES) {
      logWarn(`Clipboard payload kind=${kind} size=${payload.length} exceeds limit, dropping`)
      return
    }

    this.recordSentToken(token)
    const frame = ClipboardWireFrame.build(kind, token, payload)

    try {
      const result = MoonBridge.sendClipboardData(frame)
      if (result !== 0) {
        logWarn(`sendClipboardData kind=${kind} size=${payload.length} rc=${result}`)
      }
    } catch (err) {
      const message = formatError(err as Object)
      logError(`Failed to send clipboard data: ${message}`)
      this.observer?.onError?.(`发送剪贴板失败：${message}`)
    }
  }

  onClipboardData(kind: number, token: number, payload: Uint8Array): void {
    void this.applyRemoteClipboardData(kind, token, payload)
  }

  private async applyRemoteClipboardData(kind: number, token: number, payload: Uint8Array): Promise<void> {
    if (this.isHostEcho(token)) {
      return
    }

    if (kind === ClipboardWireFrame.KIND_PNG) {
      if (!this.config.enableSyncImage) {
        return
      }

      try {
        const pixelMap = await this.decodePngPayload(payload)
        this.pendingSelfWrites++
        this.writePixelMapToPasteboard(pixelMap)
      } catch (err) {
        if (this.pendingSelfWrites > 0) {
          this.pendingSelfWrites--
        }
        const message = formatError(err as Object)
        logError(`Failed to set local clipboard image: ${message}`)
        this.observer?.onError?.(`写入本地剪贴板图片失败：${message}`)
      }
      return
    }

    if (kind !== ClipboardWireFrame.KIND_TEXT || !this.config.enableSyncText) {
      return
    }

    try {
      const text = StringUtil.uint8ArrayToString(payload)
      if (text.length === 0) {
        return
      }

      this.pendingSelfWrites++
      const sysBoard = pasteboard.getSystemPasteboard()
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      sysBoard.setDataSync(pasteData)
    } catch (err) {
      if (this.pendingSelfWrites > 0) {
        this.pendingSelfWrites--
      }
      const message = formatError(err as Object)
      logError(`Failed to set local clipboard: ${message}`)
      this.observer?.onError?.(`写入本地剪贴板失败：${message}`)
    }
  }

  private isHostEcho(token: number): boolean {
    const now = Date.now()
    this.recentSentTokens = this.recentSentTokens.filter((entry: TokenEntry): boolean => {
      return now - entry.timestamp <= this.config.echoTtlMs
    })

    const index = this.recentSentTokens.findIndex((entry: TokenEntry): boolean => {
      return entry.token === token
    })
    if (index >= 0) {
      this.recentSentTokens.splice(index, 1)
      return true
    }

    return false
  }

  private recordSentToken(token: number): void {
    this.recentSentTokens.push(new TokenEntry(token, Date.now()))
    if (this.recentSentTokens.length > this.config.maxTokenHistory) {
      this.recentSentTokens.shift()
    }
  }

  private generateToken(): number {
    return Math.floor(Math.random() * 0x100000000) >>> 0
  }
}
