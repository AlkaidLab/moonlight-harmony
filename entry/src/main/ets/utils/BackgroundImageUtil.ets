/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import { PreferencesUtil } from './PreferencesUtil';
import { display } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { StringUtil } from './StringUtil';
import { ToastQueue } from './ToastQueue';
import { Logger } from '../common/Logger';
import { SuppressWarnings, SuppressWarningsType } from '@ohos.annotation';
import { PipwReviewIndex, PipwPool, PIPW_MAX_BYTES } from './PipwReviewIndex';
import { PipwImageLoader, PipwUrlPolicy, PipwDownloadOperation } from './PipwImageLoader';

const URL_KEY = 'settings_background_image_url';
const TYPE_KEY = 'settings_background_image_type';
const DISCLAIMER_KEY = 'settings_background_disclaimer_accepted';
const CACHE_EXPIRE_MS = 24 * 60 * 60 * 1000;

interface BackgroundApiSource {
  name: string;
  description: string;
  landscape: string;
  portrait: string;
}

interface BackgroundApiSources {
  picsum: BackgroundApiSource;
  pipw: BackgroundApiSource;
}

export const BACKGROUND_API_SOURCES: BackgroundApiSources = {
  picsum: {
    name: 'Lorem Picsum', description: '摄影壁纸 (Unsplash授权)',
    landscape: 'https://picsum.photos/1920/1080', portrait: 'https://picsum.photos/1080/1920'
  },
  pipw: {
    name: 'Pipw 二次元', description: '二次元壁纸 (第三方)',
    landscape: 'https://img-api.pipw.top', portrait: 'https://img-api.pipw.top/?phone=true'
  }
};

export enum BackgroundImageType {
  DEFAULT = 'default',
  PICSUM = 'picsum',
  PIPW = 'pipw',
  API = 'api',
  LOCAL = 'local',
  NONE = 'none'
}

interface BackgroundRequest {
  type: BackgroundImageType;
  apiUrl: string;
  identity: string;
  key: string;
  pool: PipwPool;
  filtered: boolean;
  poolSensitive: boolean;
}

interface BackgroundCacheEntry {
  identity: string;
  filename: string;
}

export class BackgroundImageUtil {
  private static instance: BackgroundImageUtil;
  private context: common.Context | null = null;
  private directory: string = '';
  private index: PipwReviewIndex | null = null;
  private cachedType: BackgroundImageType = BackgroundImageType.DEFAULT;
  private cachedImageData: ArrayBuffer | null = null;
  private cachedImageUrl: string = '';
  private localCachePath: string = '';
  private activeIdentity: string = '';
  private currentRequest: BackgroundRequest | null = null;
  private refreshTimestamp: number = 0;
  private generation: number = 0;
  private pending: Promise<string> | null = null;
  private operation: PipwDownloadOperation | null = null;
  private pendingTypeChange: boolean = false;
  private exportSequence: number = 0;
  private activeKey: string = '';
  private ordinaryRequest: http.HttpRequest | null = null;
  private displayListener: ((displayId: number) => void) | null = null;

  private constructor() {}

  static getInstance(): BackgroundImageUtil {
    if (!BackgroundImageUtil.instance) BackgroundImageUtil.instance = new BackgroundImageUtil();
    return BackgroundImageUtil.instance;
  }

  setContext(context: common.Context): void {
    this.context = context;
    this.directory = `${context.cacheDir}/vplus-backgrounds`;
    try {
      if (!fileIo.accessSync(this.directory)) fileIo.mkdirSync(this.directory);
    } catch (e) {
      this.directory = '';
      Logger.warn('BackgroundImageUtil', '背景图缓存目录不可用', e);
      return;
    }
    this.cleanupTemporaryFiles();
    this.registerDisplayListener();
  }

  /** Stream downloads killed mid-flight leave pipw-*.tmp behind; sweep on startup. */
  private cleanupTemporaryFiles(): void {
    if (!this.directory) return;
    try {
      for (const name of fileIo.listFileSync(this.directory)) {
        if (/^pipw-.+\.tmp$/.test(name)) {
          try { fileIo.unlinkSync(`${this.directory}/${name}`); } catch (e) {}
        }
      }
    } catch (e) {}
  }

  /** Keep StreamPage's shared background correct across rotation even when PcListPage is hidden. */
  private registerDisplayListener(): void {
    if (this.displayListener) return;
    this.displayListener = (): void => {
      this.handleDisplayChange();
    };
    try {
      display.on('change', this.displayListener);
    } catch (e) {
      Logger.warn('BackgroundImageUtil', '屏幕方向监听不可用', e);
    }
  }

  private async handleDisplayChange(): Promise<void> {
    try {
      // Before the first accepted load the page flow owns background startup.
      if (!this.activeIdentity || this.pending) return;
      const request = await this.resolveRequest();
      if (request.identity === this.activeIdentity) return;
      const path = await this.downloadToLocalCache();
      if (path) AppStorage.setOrCreate<string>('globalBackgroundImageUrl', `file://${path}`);
    } catch (e) {}
  }

  private getPool(): PipwPool {
    try {
      const screen = display.getDefaultDisplaySync();
      return screen.height > screen.width ? 'phone' : 'pc';
    } catch (e) {
      return 'pc';
    }
  }

  private getIndex(): PipwReviewIndex {
    if (!this.index) {
      if (!this.context) throw new Error('Background context unavailable');
      const raw = this.context.resourceManager.getRawFileContentSync('pipw_review_index.json');
      this.index = new PipwReviewIndex(StringUtil.uint8ArrayToString(raw));
    }
    return this.index;
  }

  private invalidate(): void {
    this.generation++;
    if (this.operation) this.operation.cancel();
    this.operation = null;
    if (this.ordinaryRequest) {
      try { this.ordinaryRequest.destroy(); } catch (e) {}
      this.ordinaryRequest = null;
    }
    this.pending = null;
    this.cachedImageData = null;
    this.cachedImageUrl = '';
    this.localCachePath = '';
    this.currentRequest = null;
  }

  cancelPendingLoad(): void {
    if (this.pending) this.invalidate();
    else this.generation++;
  }

  private async resolveRequest(): Promise<BackgroundRequest> {
    let type = await PreferencesUtil.get<string>(TYPE_KEY, BackgroundImageType.DEFAULT) as BackgroundImageType;
    const pool = this.getPool();
    let base = '';
    if (type === BackgroundImageType.API) {
      base = await PreferencesUtil.get<string>(URL_KEY, '');
      if (!base) type = BackgroundImageType.DEFAULT;
    }
    if (type !== BackgroundImageType.API && type !== BackgroundImageType.NONE) {
      const source = type === BackgroundImageType.PICSUM ? BACKGROUND_API_SOURCES.picsum : BACKGROUND_API_SOURCES.pipw;
      base = pool === 'phone' ? source.portrait : source.landscape;
    }
    const filtered = !!base && PipwUrlPolicy.isOfficial(base);
    if (filtered) base = PipwUrlPolicy.api(base, pool);
    if (this.refreshTimestamp === 0) this.refreshTimestamp = Date.now();
    let apiUrl = base;
    if (filtered || type === BackgroundImageType.PICSUM) {
      apiUrl = `${base}${base.includes('?') ? '&' : '?'}${filtered ? 't' : 'random'}=${this.refreshTimestamp}`;
    }
    // Custom URLs and the off switch are orientation-independent; tying their
    // cache identity to a device pool would force a reload on every rotation.
    const poolSensitive = type === BackgroundImageType.DEFAULT || type === BackgroundImageType.PIPW ||
      type === BackgroundImageType.PICSUM;
    const version = filtered ? this.getIndex().version : 'ordinary-v1';
    const identity = `${type}|${base}|${poolSensitive ? pool : 'any'}|${version}`;
    return {
      type: type, apiUrl: apiUrl, identity: identity, key: PipwReviewIndex.cacheKey(identity),
      pool: pool, filtered: filtered, poolSensitive: poolSensitive
    };
  }

  async getBackgroundImageType(): Promise<BackgroundImageType> {
    return await PreferencesUtil.get<string>(TYPE_KEY, BackgroundImageType.DEFAULT) as BackgroundImageType;
  }

  /** One load attempt; a rejected Pipw image never starts another random API request as a UI fallback. */
  async loadBackgroundImageUrl(forceRefresh: boolean = false): Promise<string> {
    const path = await this.downloadToLocalCache(forceRefresh);
    if (path) return `file://${path}`;
    try {
      const request = await this.resolveRequest();
      if (request.filtered) return '';
      // Online fallback: hold the request identity so save and preload target
      // the exact URL the Image component is showing instead of re-fetching a
      // different random image.
      this.currentRequest = request;
      this.cachedImageUrl = request.apiUrl;
      this.localCachePath = '';
      return request.apiUrl;
    } catch (e) {
      return '';
    }
  }

  async downloadToLocalCache(forceRefresh: boolean = false): Promise<string> {
    if (!this.context || !this.directory) return '';
    if (forceRefresh) {
      this.refreshTimestamp = Date.now();
      this.invalidate();
    }
    const beforeResolve = this.generation;
    try {
      const request = await this.resolveRequest();
      if (beforeResolve !== this.generation) {
        if (!forceRefresh && request.identity === this.activeIdentity && this.pending) return await this.pending;
        return '';
      }
      if (request.identity !== this.activeIdentity) {
        this.invalidate();
        this.activeIdentity = request.identity;
        this.activeKey = request.key;
      }
      this.cachedType = request.type;
      if (!request.apiUrl) {
        this.invalidate();
        return '';
      }
      if (this.pending) return await this.pending;
      const generation = this.generation;
      const pending = this.load(request, generation, forceRefresh);
      this.pending = pending;
      try {
        return await pending;
      } finally {
        if (generation === this.generation) {
          this.pending = null;
          this.operation = null;
        }
      }
    } catch (e) {
      Logger.warn('BackgroundImageUtil', '背景图加载失败', e);
      return '';
    }
  }

  private isCurrent(request: BackgroundRequest, generation: number): boolean {
    return generation === this.generation && request.identity === this.activeIdentity &&
      (!request.poolSensitive || request.pool === this.getPool());
  }

  private pointerPath(key: string): string {
    return `${this.directory}/background-${key}.json`;
  }

  private contentName(key: string, digest: string, extension: string): string {
    return `background-${key}-${digest}.${extension}`;
  }

  private isContentFilename(name: string, key: string): boolean {
    return new RegExp(`^background-${key}-[0-9a-f]{32}\\.(jpg|png|webp|gif|bmp|avif)$`).test(name);
  }

  /** Drop pointers and content from superseded identities once a new image is live. */
  private collectStaleCache(activeKey: string, currentFilename: string): void {
    if (!this.directory) return;
    try {
      for (const name of fileIo.listFileSync(this.directory)) {
        if (name === this.pointerPath(activeKey).substring(this.directory.length + 1) || name === currentFilename) continue;
        if (/^background-[0-9a-f]{32}(\.json|-[0-9a-f]{32}\.(jpg|png|webp|gif|bmp|avif))$/.test(name)) {
          try { fileIo.unlinkSync(`${this.directory}/${name}`); } catch (e) {}
        }
      }
    } catch (e) {}
  }

  private async load(request: BackgroundRequest, generation: number, force: boolean): Promise<string> {
    const pointer = this.pointerPath(request.key);
    let writtenPath = '';
    try {
      if (!force) {
        const cachedPath = this.readCachePath(pointer, request, false);
        if (cachedPath && this.isCurrent(request, generation)) {
          this.publish(cachedPath, null, request);
          this.collectStaleCache(request.key, cachedPath.substring(this.directory.length + 1));
          return cachedPath;
        }
      }
      let data: ArrayBuffer | null = null;
      let extension = 'jpg';
      if (request.filtered) {
        const operation = new PipwDownloadOperation();
        this.operation = operation;
        const result = await new PipwImageLoader(this.getIndex(), this.directory).load(request.apiUrl, request.pool, operation);
        data = result.data;
        extension = result.extension;
      } else {
        data = await this.downloadOrdinaryImage(request.apiUrl);
        if (data) extension = PipwImageLoader.extension(data);
      }
      if (!this.isCurrent(request, generation)) return '';
      if (!data) throw new Error('Background download returned no image');
      // Immutable content files ensure an export never reads a refreshed image at an old URL.
      const filename = this.contentName(request.key, PipwReviewIndex.md5(new Uint8Array(data)), extension);
      const path = `${this.directory}/${filename}`;
      writtenPath = path;
      this.writeFile(path, data);
      const entry: BackgroundCacheEntry = { identity: request.identity, filename: filename };
      this.writeFile(pointer, StringUtil.stringToUint8Array(JSON.stringify(entry)).buffer as ArrayBuffer);
      this.publish(path, data, request);
      this.collectStaleCache(request.key, filename);
      return path;
    } catch (e) {
      if (this.isCurrent(request, generation)) {
        if (writtenPath) {
          try { fileIo.unlinkSync(writtenPath); } catch (ignored) {}
        }
        // Offline or rejected refreshes keep serving the last verified image;
        // a blank background is only correct when no reviewed file exists.
        const fallbackPath = this.readCachePath(pointer, request, true);
        if (fallbackPath) {
          this.publish(fallbackPath, null, request);
          return fallbackPath;
        }
        this.cachedImageData = null;
        this.cachedImageUrl = '';
        this.localCachePath = '';
        this.currentRequest = null;
      }
      Logger.warn('BackgroundImageUtil', '背景图下载或审核失败', e);
      return '';
    }
  }

  /**
   * Validates the pointer and the content-addressed filename without reading
   * image bytes: the private cacheDir file name already embeds the content
   * digest, so a hit needs no UI-thread 20 MiB read or extra MD5 pass.
   */
  private readCachePath(pointer: string, request: BackgroundRequest, ignoreExpiry: boolean): string {
    try {
      if (!fileIo.accessSync(pointer)) return '';
      const entry = JSON.parse(StringUtil.arrayBufferToString(this.readFile(pointer, 4096))) as BackgroundCacheEntry;
      if (entry.identity !== request.identity || !this.isContentFilename(entry.filename, request.key)) return '';
      const path = `${this.directory}/${entry.filename}`;
      const stat = fileIo.statSync(path);
      if (!ignoreExpiry && Date.now() - stat.mtime * 1000 > CACHE_EXPIRE_MS) {
        this.refreshTimestamp = Date.now();
        request.apiUrl = request.apiUrl.replace(/([?&])(t|random)=[0-9]+$/, `$1$2=${this.refreshTimestamp}`);
        return '';
      }
      return path;
    } catch (e) {
      return '';
    }
  }

  private publish(path: string, data: ArrayBuffer | null, request: BackgroundRequest): void {
    this.localCachePath = path;
    this.cachedImageUrl = `file://${path}`;
    this.cachedImageData = data;
    this.currentRequest = request;
  }

  private readFile(path: string, limit: number = PIPW_MAX_BYTES): ArrayBuffer {
    const stat = fileIo.statSync(path);
    if (stat.size <= 0 || stat.size > limit) throw new Error('Invalid background file size');
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const data = new ArrayBuffer(stat.size);
      if (fileIo.readSync(file.fd, data) !== stat.size) throw new Error('Incomplete background file');
      return data;
    } finally {
      fileIo.closeSync(file.fd);
    }
  }

  private writeFile(path: string, data: ArrayBuffer): void {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      if (fileIo.writeSync(file.fd, data) !== data.byteLength) throw new Error('Incomplete background write');
    } finally {
      fileIo.closeSync(file.fd);
    }
  }

  async downloadImageData(imageUrl: string): Promise<ArrayBuffer | null> {
    try {
      if (!imageUrl) return null;
      if (imageUrl.startsWith('file://')) {
        const clean = imageUrl.split('?')[0];
        if (clean !== this.cachedImageUrl || !this.currentRequest) return null;
        const data = this.readFile(clean.substring(7));
        if (this.currentRequest.filtered && !this.getIndex().accepts(this.currentRequest.pool, data)) return null;
        return data;
      }
      // Memory-first: an online random-URL fallback must save the exact image
      // on screen instead of fetching a fresh random one.
      if (imageUrl === this.cachedImageUrl && this.cachedImageData) return this.cachedImageData;
      if (PipwUrlPolicy.isOfficial(imageUrl)) return null;
      return await this.downloadOrdinaryImage(imageUrl);
    } catch (e) {
      Logger.warn('BackgroundImageUtil', '当前背景图片数据不可用', e);
      return null;
    }
  }

  async preloadAndCacheImage(imageUrl: string = this.cachedImageUrl): Promise<void> {
    // file:// backgrounds are read lazily at save time; only online fallback
    // URLs need bytes held in memory so later saves match the display.
    if (imageUrl.startsWith('file://')) return;
    if (this.cachedImageData && imageUrl === this.cachedImageUrl) return;
    const generation = this.generation;
    const data = await this.downloadImageData(imageUrl);
    if (generation === this.generation && imageUrl === this.cachedImageUrl) this.cachedImageData = data;
  }

  async setBackgroundImageType(type: BackgroundImageType): Promise<void> {
    if (this.cachedType !== type) {
      this.invalidate();
      this.activeIdentity = '';
      this.pendingTypeChange = true;
      this.refreshTimestamp = Date.now();
    }
    this.cachedType = type;
    await PreferencesUtil.put(TYPE_KEY, type);
  }

  async setBackgroundImageUrl(value: string): Promise<void> {
    this.invalidate();
    this.activeIdentity = '';
    this.pendingTypeChange = true;
    this.refreshTimestamp = Date.now();
    await PreferencesUtil.put(URL_KEY, value);
    await this.setBackgroundImageType(value ? BackgroundImageType.API : BackgroundImageType.DEFAULT);
  }

  async disableBackgroundImage(): Promise<void> {
    await this.setBackgroundImageType(BackgroundImageType.NONE);
    this.invalidate();
    await this.clearLocalCache();
  }

  async clearLocalCache(): Promise<void> {
    this.invalidate();
    if (!this.directory) return;
    for (const name of fileIo.listFileSync(this.directory)) {
      if (/^(background-[0-9a-f]{32}(\.json|-[0-9a-f]{32}\.(jpg|png|webp|gif|bmp|avif))|pipw-.+\.tmp)$/.test(name)) {
        try { fileIo.unlinkSync(`${this.directory}/${name}`); } catch (e) {}
      }
    }
  }

  /**
   * Pure change probe: callers that abandon the reload (page hidden mid-await)
   * must not leave wiped state behind. Identity switching is owned by the next
   * downloadToLocalCache call.
   */
  async reload(): Promise<boolean> {
    const request = await this.resolveRequest();
    const changed = this.pendingTypeChange || (!!this.activeIdentity && request.identity !== this.activeIdentity);
    this.pendingTypeChange = false;
    this.cachedType = request.type;
    return changed;
  }

  async isDisclaimerAccepted(): Promise<boolean> {
    return await PreferencesUtil.get<boolean>(DISCLAIMER_KEY, false);
  }
  async setDisclaimerAccepted(): Promise<void> { await PreferencesUtil.put(DISCLAIMER_KEY, true); }
  getDisclaimerText(): string {
    return '背景壁纸功能说明\n\n' +
      '本应用的背景壁纸来自互联网公开资源（Pipw API），图片版权归原作者所有。\n\n' +
      '• 本应用仅提供技术链接，不存储、不拥有这些图片的版权\n' +
      '• 如有侵权，请联系原图片来源方\n' +
      '• 您可以在设置中随时关闭壁纸功能或切换为其他来源\n\n' +
      '继续使用即表示您知悉并同意上述条款。';
  }

  @SuppressWarnings({ rules: [SuppressWarningsType.PERMISSION] })
  async saveImageToGallery(imageUrl: string, context: common.UIAbilityContext): Promise<boolean> {
    try {
      const data = await this.downloadImageData(imageUrl);
      if (!data) {
        ToastQueue.show({ message: '当前图片不可保存，请重新加载' });
        return false;
      }
      const extension = PipwImageLoader.extension(data);
      ToastQueue.show({ message: '正在保存图片...' });
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const options: photoAccessHelper.CreateOptions = {
        title: `vplus_${Date.now()}_${++this.exportSequence}`,
        subtype: photoAccessHelper.PhotoSubtype.DEFAULT
      };
      const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, extension, options);
      const file = await fileIo.open(uri, fileIo.OpenMode.READ_WRITE);
      try {
        if (await fileIo.write(file.fd, data) !== data.byteLength) throw new Error('图片写入不完整');
      } finally {
        await fileIo.close(file.fd);
      }
      ToastQueue.show({ message: '图片已保存到相册' });
      return true;
    } catch (e) {
      Logger.error('BackgroundImageUtil', '保存图片失败', e);
      ToastQueue.show({ message: `保存失败: ${(e as Error).message || '未知错误'}` });
      return false;
    }
  }

  private async downloadOrdinaryImage(value: string): Promise<ArrayBuffer | null> {
    const request = http.createHttp();
    this.ordinaryRequest = request;
    try {
      const result = await request.request(value, {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 30000, readTimeout: 60000, maxLimit: PIPW_MAX_BYTES
      });
      return result.responseCode === 200 ? result.result as ArrayBuffer : null;
    } catch (e) {
      return null;
    } finally {
      if (this.ordinaryRequest === request) this.ordinaryRequest = null;
      request.destroy();
    }
  }
}
