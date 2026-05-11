import { pasteboard, BusinessError } from '@kit.BasicServicesKit'
import { image } from '@kit.ImageKit'
import { StringUtil } from '../../utils/StringUtil'
import { MoonBridge } from '../jni/ClipboardBridge'
import { ClipboardBlobTransport } from './ClipboardBlobTransport'
import {
  ClipboardSyncConfig,
  ClipboardWireFrame,
  ClipboardBlobRef,
  TokenEntry,
  ClipboardSyncListener
} from './ClipboardSyncConfig'

const TAG = 'ClipboardSyncService'
const MAX_CLIPBOARD_FRAME_BYTES = 65500 - ClipboardWireFrame.HEADER_SIZE
const CLIPBOARD_TEXT_MIME = 'text/plain;charset=utf-8'
const CLIPBOARD_PNG_MIME = 'image/png'

type PasteboardUpdateListener = () => void

interface PasteDataRecordAccessor {
  mimeType?: string
  plainText?: string
  pixelMap?: image.PixelMap
  toPlainText?(): string
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
  private blobTransport: ClipboardBlobTransport | null = null
  private recentSentTokens: TokenEntry[] = []
  private pendingSelfWrites: number = 0
  private pasteboardEventListener: PasteboardUpdateListener | null = null
  private isRunning: boolean = false

  constructor(config?: ClipboardSyncConfig, observer?: ClipboardSyncObserver, blobTransport?: ClipboardBlobTransport | null) {
    this.config = config ? config : new ClipboardSyncConfig()
    this.observer = observer ? observer : null
    this.blobTransport = blobTransport ? blobTransport : null
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
      const recordCount = pasteData.getRecordCount()
      const text = this.config.enableSyncText ? this.tryGetPrimaryText(pasteData, recordCount) : ''

      if (this.config.enableSyncText && text && text.length > 0) {
        logInfo(`Local clipboard changed: recordCount=${recordCount}, textLength=${text.length}`)
        await this.sendTextPayload(text)
        return
      }

      if (this.config.enableSyncImage) {
        const primaryPixelMap = this.tryGetPrimaryPixelMap(pasteData, recordCount)
        if (primaryPixelMap) {
          logInfo(`Local clipboard changed: recordCount=${recordCount}, detected pixelMap image`)
          await this.sendImagePayload(primaryPixelMap)
          return
        }
      }

      logInfo(`Local clipboard changed: recordCount=${recordCount}, no supported text/image payload`)
    } catch (err) {
      const message = formatError(err as Object)
      logError(`Failed to read local clipboard: ${message}`)
      this.observer?.onError?.(`读取本地剪贴板失败：${message}`)
    }
  }

  private async sendTextPayload(text: string): Promise<void> {
    const payload = StringUtil.stringToUint8Array(text)
    await this.sendPayloadOrBlob(ClipboardWireFrame.KIND_TEXT, CLIPBOARD_TEXT_MIME, payload, '文本')
  }

  private tryGetPrimaryText(pasteData: pasteboard.PasteData, recordCount: number): string {
    try {
      const primaryText = pasteData.getPrimaryText()
      if (primaryText && primaryText.length > 0) {
        return primaryText
      }
    } catch (_err) {
    }

    for (let i = 0; i < recordCount; i++) {
      try {
        const record = pasteData.getRecord(i) as PasteDataRecordAccessor
        if (typeof record.plainText === 'string' && record.plainText.length > 0) {
          return record.plainText
        }
        if (record.toPlainText) {
          const text = record.toPlainText()
          if (text && text.length > 0) {
            return text
          }
        }
      } catch (_err) {
      }
    }

    return ''
  }

  private tryGetPrimaryPixelMap(pasteData: pasteboard.PasteData, recordCount: number): image.PixelMap | null {
    try {
      for (let i = 0; i < recordCount; i++) {
        const record = pasteData.getRecord(i) as PasteDataRecordAccessor
        const pixelMap = record.pixelMap
        if (pixelMap) {
          return pixelMap
        }
      }
    } catch (_err) {
    }

    return null
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

      await this.sendPayloadOrBlob(ClipboardWireFrame.KIND_PNG, CLIPBOARD_PNG_MIME, payload, '图片')
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

  private async sendPayloadOrBlob(kind: number, mime: string, payload: Uint8Array, displayName: string): Promise<void> {
    if (payload.length === 0) {
      return
    }

    if (payload.length <= MAX_CLIPBOARD_FRAME_BYTES) {
      this.sendPayload(kind, this.generateToken(), payload)
      return
    }

    if (!this.blobTransport) {
      logWarn(`Clipboard ${displayName} payload size=${payload.length} exceeds limit and blob transport is unavailable`)
      this.observer?.onError?.(`剪贴板${displayName}过大，已跳过同步`)
      return
    }

    try {
      const ref = await this.blobTransport.uploadBlob(mime, payload)
      const refPayload = ClipboardWireFrame.buildRefPayload(ref)
      if (refPayload.length > MAX_CLIPBOARD_FRAME_BYTES) {
        logWarn(`Clipboard REF payload size=${refPayload.length} exceeds limit, dropping`)
        this.observer?.onError?.(`剪贴板${displayName}引用过大，已跳过同步`)
        return
      }

      logInfo(`Uploaded clipboard ${displayName} blob id=${ref.id} size=${ref.size}`)
      this.sendPayload(ClipboardWireFrame.KIND_REF, this.generateToken(), refPayload)
    } catch (err) {
      const message = formatError(err as Object)
      logError(`Failed to upload clipboard ${displayName} blob: ${message}`)
      this.observer?.onError?.(`上传剪贴板${displayName}失败：${message}`)
    }
  }

  private async decodePngPayload(payload: Uint8Array): Promise<image.PixelMap> {
    // ImageSource 需要一份独立的 ArrayBuffer。OHOS 对 buffer 所有权语义
    // 文档不明，为避免 use-after-free / use-after-release 风险，始终拷贝。
    const copy = new Uint8Array(payload.length)
    copy.set(payload)
    const imageSource: image.ImageSource = image.createImageSource(copy.buffer)
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

    if (kind === ClipboardWireFrame.KIND_REF) {
      await this.applyRemoteBlobReference(payload)
      return
    }

    if (kind === ClipboardWireFrame.KIND_PNG) {
      if (!this.config.enableSyncImage) {
        return
      }
      await this.writeRemoteImagePayload(payload, '直接帧')
      return
    }

    if (kind !== ClipboardWireFrame.KIND_TEXT || !this.config.enableSyncText) {
      return
    }

    await this.writeRemoteTextPayload(payload, '直接帧')
  }

  private async applyRemoteBlobReference(payload: Uint8Array): Promise<void> {
    const ref = ClipboardWireFrame.parseRefPayload(payload)
    if (!ref) {
      logWarn('Ignoring malformed clipboard REF payload')
      return
    }

    if (!this.shouldDownloadBlobRef(ref)) {
      return
    }

    const blobData = await this.downloadClipboardBlob(ref)
    if (!blobData) {
      return
    }

    if (this.isTextMime(ref.mime)) {
      await this.writeRemoteTextPayload(blobData, `blob id=${ref.id}`)
      return
    }

    if (this.isPngMime(ref.mime)) {
      await this.writeRemoteImagePayload(blobData, `blob id=${ref.id}`)
      return
    }

    logInfo(`Ignoring unsupported clipboard blob mime=${ref.mime}`)
  }

  private shouldDownloadBlobRef(ref: ClipboardBlobRef): boolean {
    if (this.isTextMime(ref.mime)) {
      return this.config.enableSyncText
    }
    if (this.isPngMime(ref.mime)) {
      return this.config.enableSyncImage
    }
    return false
  }

  private async downloadClipboardBlob(ref: ClipboardBlobRef): Promise<Uint8Array | null> {
    if (!this.blobTransport) {
      logWarn(`Clipboard blob transport unavailable for ref id=${ref.id}`)
      this.observer?.onError?.('当前会话未配置剪贴板大文件传输')
      return null
    }

    try {
      const data = await this.blobTransport.downloadBlob(ref.id)
      if (ref.size > 0 && data.length !== ref.size) {
        logWarn(`Clipboard blob size mismatch id=${ref.id} expected=${ref.size} actual=${data.length}`)
      }
      return data
    } catch (err) {
      const message = formatError(err as Object)
      logError(`Failed to download clipboard blob id=${ref.id}: ${message}`)
      this.observer?.onError?.(`下载远端剪贴板内容失败：${message}`)
      return null
    }
  }

  /**
   * 解码并写入远端文本 payload 到本地剪贴板。统一处理 KIND_TEXT 直接帧
   * 与 KIND_REF 下载后的文本 blob。
   */
  private async writeRemoteTextPayload(payload: Uint8Array, source: string): Promise<void> {
    let claimedSelfWrite = false
    try {
      const text = StringUtil.uint8ArrayToString(payload)
      if (text.length === 0) {
        return
      }
      this.pendingSelfWrites++
      claimedSelfWrite = true
      this.writeTextToPasteboard(text)
    } catch (err) {
      if (claimedSelfWrite && this.pendingSelfWrites > 0) {
        this.pendingSelfWrites--
      }
      const message = formatError(err as Object)
      logError(`Failed to set local clipboard text (${source}): ${message}`)
      this.observer?.onError?.(`写入本地剪贴板失败：${message}`)
    }
  }

  /**
   * 解码并写入远端图片 payload 到本地剪贴板。统一处理 KIND_PNG 直接帧
   * 与 KIND_REF 下载后的图片 blob。
   */
  private async writeRemoteImagePayload(payload: Uint8Array, source: string): Promise<void> {
    let claimedSelfWrite = false
    try {
      const pixelMap = await this.decodePngPayload(payload)
      this.pendingSelfWrites++
      claimedSelfWrite = true
      this.writePixelMapToPasteboard(pixelMap)
    } catch (err) {
      if (claimedSelfWrite && this.pendingSelfWrites > 0) {
        this.pendingSelfWrites--
      }
      const message = formatError(err as Object)
      logError(`Failed to set local clipboard image (${source}): ${message}`)
      this.observer?.onError?.(`写入本地剪贴板图片失败：${message}`)
    }
  }

  private writeTextToPasteboard(text: string): void {
    const sysBoard = pasteboard.getSystemPasteboard()
    const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
    sysBoard.setDataSync(pasteData)
  }

  private isTextMime(mime: string): boolean {
    // Sunshine 仅会发 'text/plain;charset=utf-8'。接受任意 text/* + utf-8
    // charset 或未指定 charset 的 text/plain（默认 ASCII⊆UTF-8）。拒绝
    // text/csv;charset=gbk 之类，避免 StringUtil.uint8ArrayToString 按 UTF-8
    // 解码造成乱码。
    if (!mime.startsWith('text/')) {
      return false
    }
    const charsetMatch = mime.toLowerCase().match(/;\s*charset=([^;\s]+)/)
    if (!charsetMatch) {
      return true
    }
    const charset = charsetMatch[1].replace(/^"|"$/g, '')
    return charset === 'utf-8' || charset === 'utf8' || charset === 'us-ascii'
  }

  private isPngMime(mime: string): boolean {
    return mime === CLIPBOARD_PNG_MIME
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
