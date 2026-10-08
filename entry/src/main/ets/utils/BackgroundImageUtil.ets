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
import { PipwReviewIndex, PipwPool, PIPW_REVIEW_VERSION, PIPW_MAX_BYTES } from './PipwReviewIndex';
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

export interface BackgroundConfig {
  imageUrl: string;
  opacity: number;
  enableBlur: boolean;
  blurRadius: number;
}

interface BackgroundRequest {
  type: BackgroundImageType;
  apiUrl: string;
  identity: string;
  key: string;
  pool: PipwPool;
  filtered: boolean;
}

interface BackgroundCacheEntry {
  identity: string;
  filename: string;
}

interface BackgroundCachedImage {
  path: string;
  data: ArrayBuffer;
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
    }
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
    const identity = `${type}|${base}|${pool}|${filtered ? PIPW_REVIEW_VERSION : 'ordinary-v1'}`;
    return { type: type, apiUrl: apiUrl, identity: identity, key: PipwReviewIndex.cacheKey(identity), pool: pool, filtered: filtered };
  }

  async getBackgroundImageType(): Promise<BackgroundImageType> {
    return await PreferencesUtil.get<string>(TYPE_KEY, BackgroundImageType.DEFAULT) as BackgroundImageType;
  }

  /** Pipw never exposes its unverified network URL to Image components. */
  async getBackgroundImageUrl(): Promise<string> {
    try {
      const request = await this.resolveRequest();
      if (request.filtered) {
        const path = await this.downloadToLocalCache();
        return path ? `file://${path}` : '';
      }
      return request.apiUrl;
    } catch (e) {
      Logger.warn('BackgroundImageUtil', '背景图地址不可用');
      return '';
    }
  }

  /** One load attempt; a rejected Pipw image never starts another random API request as a UI fallback. */
  async loadBackgroundImageUrl(forceRefresh: boolean = false): Promise<string> {
    const path = await this.downloadToLocalCache(forceRefresh);
    if (path) return `file://${path}`;
    try {
      const request = await this.resolveRequest();
      return request.filtered ? '' : request.apiUrl;
    } catch (e) {
      return '';
    }
  }

  getPipwApiUrl(): string {
    if (!this.refreshTimestamp) this.refreshTimestamp = Date.now();
    const base = this.getPool() === 'phone' ? BACKGROUND_API_SOURCES.pipw.portrait : BACKGROUND_API_SOURCES.pipw.landscape;
    return `${base}${base.includes('?') ? '&' : '?'}t=${this.refreshTimestamp}`;
  }

  getPicsumApiUrl(): string {
    if (!this.refreshTimestamp) this.refreshTimestamp = Date.now();
    const source = BACKGROUND_API_SOURCES.picsum;
    return `${this.getPool() === 'phone' ? source.portrait : source.landscape}?random=${this.refreshTimestamp}`;
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
      }
      this.cachedType = request.type;
      if (!request.apiUrl) return '';
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
    return generation === this.generation && request.identity === this.activeIdentity && request.pool === this.getPool();
  }

  private async load(request: BackgroundRequest, generation: number, force: boolean): Promise<string> {
    const pointer = `${this.directory}/background-${request.key}.json`;
    let previousPath = '';
    let writtenPath = '';
    try {
      if (!force) {
        const cached = this.readCache(pointer, request);
        if (cached && this.isCurrent(request, generation)) {
          this.publish(cached.path, cached.data, request);
          return cached.path;
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
      const filename = `background-${request.key}-${PipwReviewIndex.md5(new Uint8Array(data))}.${extension}`;
      const path = `${this.directory}/${filename}`;
      previousPath = this.previousContentPath(pointer, request.key);
      writtenPath = path;
      this.writeFile(path, data);
      const entry: BackgroundCacheEntry = { identity: request.identity, filename: filename };
      this.writeFile(pointer, StringUtil.stringToUint8Array(JSON.stringify(entry)).buffer as ArrayBuffer);
      this.publish(path, data, request);
      if (previousPath && previousPath !== path) {
        try { fileIo.unlinkSync(previousPath); } catch (e) {}
      }
      return path;
    } catch (e) {
      if (this.isCurrent(request, generation)) {
        this.cachedImageData = null;
        this.cachedImageUrl = '';
        this.localCachePath = '';
        this.currentRequest = null;
        const stale = previousPath || this.previousContentPath(pointer, request.key);
        try { if (fileIo.accessSync(pointer)) fileIo.unlinkSync(pointer); } catch (ignored) {}
        if (stale) {
          try { fileIo.unlinkSync(stale); } catch (ignored) {}
        }
        if (writtenPath && writtenPath !== stale) {
          try { fileIo.unlinkSync(writtenPath); } catch (ignored) {}
        }
      }
      Logger.warn('BackgroundImageUtil', '背景图下载或审核失败', e);
      return '';
    }
  }

  private previousContentPath(pointer: string, key: string): string {
    try {
      const entry = JSON.parse(StringUtil.arrayBufferToString(this.readFile(pointer, 4096))) as BackgroundCacheEntry;
      const pattern = new RegExp(`^background-${key}-[0-9a-f]{32}\\.(jpg|png|webp|gif|bmp|avif)$`);
      return pattern.test(entry.filename) ? `${this.directory}/${entry.filename}` : '';
    } catch (e) {
      return '';
    }
  }

  private readCache(pointer: string, request: BackgroundRequest): BackgroundCachedImage | null {
    try {
      if (!fileIo.accessSync(pointer)) return null;
      const entry = JSON.parse(StringUtil.arrayBufferToString(this.readFile(pointer, 4096))) as BackgroundCacheEntry;
      const pattern = new RegExp(`^background-${request.key}-[0-9a-f]{32}\\.(jpg|png|webp|gif|bmp|avif)$`);
      if (entry.identity !== request.identity || !pattern.test(entry.filename)) return null;
      const path = `${this.directory}/${entry.filename}`;
      const stat = fileIo.statSync(path);
      if (Date.now() - stat.mtime * 1000 > CACHE_EXPIRE_MS) {
        this.refreshTimestamp = Date.now();
        request.apiUrl = request.apiUrl.replace(/([?&])(t|random)=[0-9]+$/, `$1$2=${this.refreshTimestamp}`);
        return null;
      }
      const data = this.readFile(path);
      if (request.filtered && !this.getIndex().accepts(request.pool, data)) return null;
      return { path: path, data: data };
    } catch (e) {
      return null;
    }
  }

  private publish(path: string, data: ArrayBuffer, request: BackgroundRequest): void {
    this.localCachePath = path;
    this.cachedImageUrl = `file://${path}`;
    this.cachedImageData = data;
    this.currentRequest = request;
  }

  getLocalCachePath(): string { return this.localCachePath; }
  getCachedImageData(): ArrayBuffer | null { return this.cachedImageData; }
  clearCachedImageData(): void { this.cachedImageData = null; }

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
      if (PipwUrlPolicy.isOfficial(imageUrl)) return null;
      return await this.downloadOrdinaryImage(imageUrl);
    } catch (e) {
      Logger.warn('BackgroundImageUtil', '当前背景图片数据不可用', e);
      return null;
    }
  }

  async preloadAndCacheImage(imageUrl: string = this.cachedImageUrl): Promise<void> {
    if (this.cachedImageData && imageUrl.split('?')[0] === this.cachedImageUrl) return;
    const generation = this.generation;
    const data = await this.downloadImageData(imageUrl);
    if (generation === this.generation && imageUrl.split('?')[0] === this.cachedImageUrl) this.cachedImageData = data;
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

  async clearBackgroundImage(): Promise<void> { await this.setBackgroundImageUrl(''); }

  async disableBackgroundImage(): Promise<void> {
    await this.setBackgroundImageType(BackgroundImageType.NONE);
    this.invalidate();
    await this.clearLocalCache();
  }

  async clearLocalCache(): Promise<void> {
    this.invalidate();
    if (!this.directory) return;
    for (const name of fileIo.listFileSync(this.directory)) {
      if (/^background-[0-9a-f]{32}(\.json|-[0-9a-f]{32}\.(jpg|png|webp|gif|bmp|avif))$/.test(name)) {
        try { fileIo.unlinkSync(`${this.directory}/${name}`); } catch (e) {}
      }
    }
  }

  async refreshBackgroundImage(): Promise<string> {
    const path = await this.downloadToLocalCache(true);
    return path ? `file://${path}` : '';
  }

  async reload(): Promise<boolean> {
    const generation = this.generation;
    const request = await this.resolveRequest();
    if (generation !== this.generation) return false;
    const changed = this.pendingTypeChange || (!!this.activeIdentity && request.identity !== this.activeIdentity);
    this.pendingTypeChange = false;
    this.cachedType = request.type;
    if (changed) {
      this.invalidate();
      this.activeIdentity = '';
    }
    return changed;
  }

  getDefaultConfig(): BackgroundConfig {
    return { imageUrl: this.cachedImageUrl, opacity: 0.15, enableBlur: true, blurRadius: 20 };
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

  isValidImageUrl(value: string): boolean { return /^https?:\/\//.test(value); }

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

  async saveLocalCacheToGallery(context: common.UIAbilityContext): Promise<boolean> {
    return await this.saveImageToGallery(this.cachedImageUrl, context);
  }

  private async downloadOrdinaryImage(value: string): Promise<ArrayBuffer | null> {
    const request = http.createHttp();
    try {
      const result = await request.request(value, {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 30000, readTimeout: 60000, maxLimit: PIPW_MAX_BYTES
      });
      return result.responseCode === 200 ? result.result as ArrayBuffer : null;
    } catch (e) {
      return null;
    } finally {
      request.destroy();
    }
  }
}
