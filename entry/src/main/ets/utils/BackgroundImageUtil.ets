/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * 背景图工具类
 * 提供背景图加载和管理功能
 */
import { PreferencesUtil } from './PreferencesUtil';
import { display, promptAction } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

const BACKGROUND_IMAGE_URL_KEY = 'settings_background_image_url';
const BACKGROUND_IMAGE_TYPE_KEY = 'settings_background_image_type';
// 本地缓存文件名
const CACHED_BACKGROUND_FILENAME = 'cached_background.jpg';

/**
 * 背景图 API 源配置
 */
interface BackgroundApiSource {
  name: string;
  description: string;
  landscape: string;
  portrait: string;
}

/**
 * 背景图 API 源集合
 */
interface BackgroundApiSourceCollection {
  picsum: BackgroundApiSource;
  pipw: BackgroundApiSource;
}

/**
 * 可用的背景图 API 源
 * - picsum: Lorem Picsum (基于 Unsplash，免费商用授权)
 * - pipw: Pipw Team 二次元壁纸 API (第三方服务，需自行评估版权风险)
 */
export const BACKGROUND_API_SOURCES: BackgroundApiSourceCollection = {
  picsum: {
    name: 'Lorem Picsum',
    description: '摄影壁纸 (Unsplash授权)',
    landscape: 'https://picsum.photos/1920/1080',
    portrait: 'https://picsum.photos/1080/1920',
  } as BackgroundApiSource,
  pipw: {
    name: 'Pipw 二次元',
    description: '二次元壁纸 (第三方)',
    landscape: 'https://img-api.pipw.top',
    portrait: 'https://img-api.pipw.top/?phone=true',
  } as BackgroundApiSource
};

// 背景图类型
export enum BackgroundImageType {
  DEFAULT = 'default',  // 使用默认 API (Lorem Picsum)
  PIPW = 'pipw',        // 使用 Pipw 二次元壁纸 API
  API = 'api',          // 自定义 API URL
  LOCAL = 'local',      // 本地图片（暂不支持）
  NONE = 'none'         // 不使用背景图
}

/**
 * 背景图配置
 */
export interface BackgroundConfig {
  /** 背景图 URL，空字符串表示使用纯色背景 */
  imageUrl: string;
  /** 背景图透明度 0-1 */
  opacity: number;
  /** 是否启用模糊效果 */
  enableBlur: boolean;
  /** 模糊半径 */
  blurRadius: number;
}

/**
 * HTTP 下载结果
 */
interface DownloadResult {
  code: number;
  data: ArrayBuffer | null;
  redirectUrl: string;
}

/**
 * 背景图工具类
 */
export class BackgroundImageUtil {
  private static instance: BackgroundImageUtil;
  private cachedUrl: string = '';
  private cachedType: BackgroundImageType = BackgroundImageType.DEFAULT;
  private isLoaded: boolean = false;
  private refreshTimestamp: number = 0;
  // 缓存当前显示的图片数据（用于下载）
  private cachedImageData: ArrayBuffer | null = null;
  // 本地缓存文件路径
  private localCachePath: string = '';
  // 应用上下文（用于获取沙盒路径）
  private context: common.Context | null = null;

  private constructor() {}

  static getInstance(): BackgroundImageUtil {
    if (!BackgroundImageUtil.instance) {
      BackgroundImageUtil.instance = new BackgroundImageUtil();
    }
    return BackgroundImageUtil.instance;
  }

  /**
   * 设置应用上下文（必须在使用前调用）
   */
  setContext(context: common.Context): void {
    this.context = context;
    this.localCachePath = `${context.cacheDir}/${CACHED_BACKGROUND_FILENAME}`;
  }

  /**
   * 获取本地缓存的图片路径
   */
  getLocalCachePath(): string {
    return this.localCachePath;
  }

  /**
   * 下载图片到本地缓存，返回本地文件路径
   * 如果已有缓存且不强制刷新，直接返回缓存路径
   */
  async downloadToLocalCache(forceRefresh: boolean = false): Promise<string> {
    if (!this.context) {
      return '';
    }
    
    // 检查是否已有本地缓存
    if (!forceRefresh && this.localCachePath) {
      try {
        const stat = fileIo.statSync(this.localCachePath);
        if (stat && stat.size > 0) {
          // 已有缓存，同时读取到内存缓存
          const file = fileIo.openSync(this.localCachePath, fileIo.OpenMode.READ_ONLY);
          this.cachedImageData = new ArrayBuffer(stat.size);
          fileIo.readSync(file.fd, this.cachedImageData);
          fileIo.closeSync(file.fd);
          return this.localCachePath;
        }
      } catch (e) {
        // 文件不存在，继续下载
      }
    }
    
    // 获取 API URL
    const apiUrl = this.getDefaultApiUrl();
    
    // 下载图片数据
    const imageData = await this.downloadImage(apiUrl);
    if (!imageData) {
      return '';
    }
    
    // 保存到本地缓存
    try {
      const file = fileIo.openSync(this.localCachePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, imageData);
      fileIo.closeSync(file.fd);
      
      // 同时保存到内存缓存
      this.cachedImageData = imageData;
      
      return this.localCachePath;
    } catch (err) {
      console.error('BackgroundImageUtil: 保存本地缓存失败', err);
      return '';
    }
  }

  /**
   * 获取背景图 URL
   * 注意：使用缓存避免频繁刷新背景图
   * @returns 背景图 URL
   */
  async getBackgroundImageUrl(): Promise<string> {
    // 如果已加载，直接返回缓存的 URL（包括 DEFAULT 类型）
    if (this.isLoaded && this.cachedUrl) {
      return this.cachedUrl;
    }
    
    try {
      this.cachedType = await PreferencesUtil.get<string>(
        BACKGROUND_IMAGE_TYPE_KEY, 
        BackgroundImageType.DEFAULT
      ) as BackgroundImageType;
      
      switch (this.cachedType) {
        case BackgroundImageType.API:
          this.cachedUrl = await PreferencesUtil.get<string>(BACKGROUND_IMAGE_URL_KEY, '');
          if (!this.cachedUrl) {
            // 如果自定义 URL 为空，回退到默认 API
            this.cachedType = BackgroundImageType.DEFAULT;
            await this.setBackgroundImageType(BackgroundImageType.DEFAULT);
            return this.getDefaultApiUrl();
          }
          break;
          
        case BackgroundImageType.PIPW:
          this.cachedUrl = this.getPipwApiUrl();
          break;
          
        case BackgroundImageType.NONE:
          this.cachedUrl = '';
          break;
          
        case BackgroundImageType.DEFAULT:
        default:
          this.cachedUrl = this.getDefaultApiUrl();
          break;
      }
      
      this.isLoaded = true;
      return this.cachedUrl;
    } catch (err) {
      console.error('BackgroundImageUtil: 加载背景图设置失败', err);
      return this.getDefaultApiUrl();
    }
  }

  /**
   * 获取 Pipw 二次元壁纸 API URL（根据屏幕方向）
   */
  getPipwApiUrl(): string {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      const isPortrait = displayInfo.height > displayInfo.width;
      if (this.refreshTimestamp === 0) {
        this.refreshTimestamp = Date.now();
      }
      const source = BACKGROUND_API_SOURCES.pipw;
      const baseUrl = isPortrait ? source.portrait : source.landscape;
      return `${baseUrl}${baseUrl.includes('?') ? '&' : '?'}t=${this.refreshTimestamp}`;
    } catch (err) {
      if (this.refreshTimestamp === 0) {
        this.refreshTimestamp = Date.now();
      }
      return `${BACKGROUND_API_SOURCES.pipw.landscape}?t=${this.refreshTimestamp}`;
    }
  }

  /**
   * 获取默认 API URL（根据屏幕方向）- 使用 Lorem Picsum
   * 注意：只在首次加载或明确刷新时更新时间戳，避免频繁刷新
   */
  getDefaultApiUrl(): string {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      const isPortrait = displayInfo.height > displayInfo.width;
      // 仅在明确调用刷新时更新时间戳，否则保持稳定的URL
      // 如果 refreshTimestamp 为 0，设置一个初始值，之后保持不变
      if (this.refreshTimestamp === 0) {
        this.refreshTimestamp = Date.now();
      }
      const source = BACKGROUND_API_SOURCES.picsum;
      const baseUrl = isPortrait ? source.portrait : source.landscape;
      // Lorem Picsum 使用 random 参数来获取随机图片
      return `${baseUrl}?random=${this.refreshTimestamp}`;
    } catch (err) {
      if (this.refreshTimestamp === 0) {
        this.refreshTimestamp = Date.now();
      }
      return `${BACKGROUND_API_SOURCES.picsum.landscape}?random=${this.refreshTimestamp}`;
    }
  }

  /**
   * 设置背景图类型
   */
  async setBackgroundImageType(type: BackgroundImageType): Promise<void> {
    try {
      await PreferencesUtil.put(BACKGROUND_IMAGE_TYPE_KEY, type);
      this.cachedType = type;
      this.isLoaded = false;
    } catch (err) {
      console.error('BackgroundImageUtil: 保存背景图类型失败', err);
    }
  }

  /**
   * 设置自定义背景图 URL
   * @param url 背景图 URL
   */
  async setBackgroundImageUrl(url: string): Promise<void> {
    try {
      await PreferencesUtil.put(BACKGROUND_IMAGE_URL_KEY, url);
      this.cachedUrl = url;
      
      if (url) {
        await this.setBackgroundImageType(BackgroundImageType.API);
      } else {
        await this.setBackgroundImageType(BackgroundImageType.DEFAULT);
      }
      
      this.isLoaded = true;
    } catch (err) {
      console.error('BackgroundImageUtil: 保存背景图设置失败', err);
    }
  }

  /**
   * 清除背景图（使用默认 API）
   */
  async clearBackgroundImage(): Promise<void> {
    await this.setBackgroundImageUrl('');
    await this.setBackgroundImageType(BackgroundImageType.DEFAULT);
  }

  /**
   * 禁用背景图
   */
  async disableBackgroundImage(): Promise<void> {
    await this.setBackgroundImageType(BackgroundImageType.NONE);
    this.cachedUrl = '';
    this.isLoaded = true;
  }

  /**
   * 刷新背景图（生成新的时间戳以获取新图片）
   */
  async refreshBackgroundImage(): Promise<string> {
    this.refreshTimestamp = Date.now();
    this.isLoaded = false;
    return await this.getBackgroundImageUrl();
  }

  /**
   * 重新加载背景图设置
   */
  async reload(): Promise<string> {
    this.isLoaded = false;
    return await this.getBackgroundImageUrl();
  }

  /**
   * 获取当前背景图类型
   */
  async getBackgroundImageType(): Promise<BackgroundImageType> {
    if (!this.isLoaded) {
      await this.getBackgroundImageUrl();
    }
    return this.cachedType;
  }

  /**
   * 获取默认背景图配置
   */
  getDefaultConfig(): BackgroundConfig {
    return {
      imageUrl: this.cachedUrl,
      opacity: 0.15,
      enableBlur: true,
      blurRadius: 20
    };
  }
  
  /**
   * 预加载并缓存当前背景图数据
   * 优先从本地缓存文件读取，确保下载保存的图片与显示的一致
   */
  async preloadAndCacheImage(): Promise<void> {
    try {
      // 优先从本地缓存文件读取
      if (this.localCachePath) {
        try {
          const stat = fileIo.statSync(this.localCachePath);
          if (stat && stat.size > 0) {
            const file = fileIo.openSync(this.localCachePath, fileIo.OpenMode.READ_ONLY);
            const imageData = new ArrayBuffer(stat.size);
            fileIo.readSync(file.fd, imageData);
            fileIo.closeSync(file.fd);
            this.cachedImageData = imageData;
            return;
          }
        } catch (e) {
          // 本地缓存文件不存在，继续尝试从 URL 下载
        }
      }
      
      // 如果没有本地缓存，从在线 URL 下载
      if (this.cachedUrl) {
        this.cachedImageData = await this.downloadImage(this.cachedUrl);
      }
    } catch (err) {
      // 忽略错误
    }
  }

  /**
   * 获取缓存的图片数据
   */
  getCachedImageData(): ArrayBuffer | null {
    return this.cachedImageData;
  }

  /**
   * 清除缓存的图片数据
   */
  clearCachedImageData(): void {
    this.cachedImageData = null;
  }

  /**
   * 下载图片数据（公共方法，供 SaveButton 使用）
   * @param imageUrl 图片 URL
   * @returns 图片二进制数据
   */
  async downloadImageData(imageUrl: string): Promise<ArrayBuffer | null> {
    if (!imageUrl || imageUrl.length === 0) {
      return null;
    }
    
    try {
      // 如果是 file:// 路径，直接读取本地文件
      if (imageUrl.startsWith('file://')) {
        const filePath = imageUrl.replace('file://', '');
        try {
          const stat = fileIo.statSync(filePath);
          if (stat && stat.size > 0) {
            const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
            const imageData = new ArrayBuffer(stat.size);
            fileIo.readSync(file.fd, imageData);
            fileIo.closeSync(file.fd);
            return imageData;
          }
        } catch (e) {
          console.warn('BackgroundImageUtil: 读取本地文件失败');
        }
      }
      
      // 尝试使用缓存数据
      if (this.cachedImageData) {
        return this.cachedImageData;
      }
      
      // 重新下载
      return await this.downloadImage(imageUrl);
    } catch (err) {
      console.error('BackgroundImageUtil: 下载图片数据失败', err);
      return null;
    }
  }

  /**
   * 验证 URL 是否为有效的图片 URL
   */
  isValidImageUrl(url: string): boolean {
    if (!url) return false;
    
    // 检查是否为 http/https URL
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return false;
    }
    
    return true;
  }

  /**
   * 直接将本地缓存文件保存到相册
   * @param context 应用上下文
   * @returns 是否保存成功
   */
  async saveLocalCacheToGallery(context: common.UIAbilityContext): Promise<boolean> {
    if (!this.localCachePath) {
      promptAction.showToast({ message: '没有可保存的图片' });
      return false;
    }
    
    try {
      // 检查缓存文件是否存在
      const stat = fileIo.statSync(this.localCachePath);
      if (!stat || stat.size === 0) {
        promptAction.showToast({ message: '缓存图片不存在' });
        return false;
      }
      
      promptAction.showToast({ message: '正在保存图片...' });
      
      // 读取本地缓存文件
      const file = fileIo.openSync(this.localCachePath, fileIo.OpenMode.READ_ONLY);
      const imageData = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, imageData);
      fileIo.closeSync(file.fd);
      
      // 创建相册访问助手
      const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      
      // 创建图片资源
      const createOption: photoAccessHelper.CreateOptions = {
        title: `moonlight_bg_${Date.now()}`,
        subtype: photoAccessHelper.PhotoSubtype.DEFAULT
      };
      
      const photoUri = await phAccessHelper.createAsset(
        photoAccessHelper.PhotoType.IMAGE,
        'jpg',
        createOption
      );
      
      // 写入图片数据
      const photoFile = fileIo.openSync(photoUri, fileIo.OpenMode.READ_WRITE);
      fileIo.writeSync(photoFile.fd, imageData);
      fileIo.closeSync(photoFile.fd);
      
      promptAction.showToast({ message: '图片已保存到相册' });
      return true;
    } catch (err) {
      console.error('BackgroundImageUtil: 保存本地缓存到相册失败', err);
      const error = err as Error;
      if (error.message?.includes('permission')) {
        promptAction.showToast({ message: '没有保存图片的权限，请在设置中授权' });
      } else {
        promptAction.showToast({ message: `保存失败: ${error.message || '未知错误'}` });
      }
      return false;
    }
  }

  /**
   * 保存背景图到相册
   * @param imageUrl 图片 URL
   * @param context 应用上下文
   * @returns 是否保存成功
   */
  async saveImageToGallery(imageUrl: string, context: common.UIAbilityContext): Promise<boolean> {
    if (!imageUrl || imageUrl.length === 0) {
      promptAction.showToast({ message: '没有可保存的图片' });
      return false;
    }

    try {
      promptAction.showToast({ message: '正在保存图片...' });
      
      let imageData: ArrayBuffer | null = null;
      
      // 1. 如果是 file:// 路径，优先直接读取本地文件
      if (imageUrl.startsWith('file://')) {
        const filePath = imageUrl.replace('file://', '');
        try {
          const stat = fileIo.statSync(filePath);
          if (stat && stat.size > 0) {
            const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
            imageData = new ArrayBuffer(stat.size);
            fileIo.readSync(file.fd, imageData);
            fileIo.closeSync(file.fd);
            console.info('BackgroundImageUtil: 从本地文件读取图片数据');
          }
        } catch (e) {
          console.warn('BackgroundImageUtil: 读取本地文件失败，尝试使用缓存数据');
        }
      }
      
      // 2. 如果本地文件读取失败，使用缓存的图片数据
      if (!imageData) {
        imageData = this.cachedImageData;
      }
      
      // 3. 如果缓存数据也没有，重新下载
      if (!imageData && !imageUrl.startsWith('file://')) {
        promptAction.showToast({ message: '正在下载图片...' });
        imageData = await this.downloadImage(imageUrl);
      }
      
      if (!imageData) {
        promptAction.showToast({ message: '图片数据获取失败' });
        return false;
      }
      
      // 4. 创建相册访问助手
      const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      
      // 5. 创建图片资源
      const createOption: photoAccessHelper.CreateOptions = {
        title: `moonlight_bg_${Date.now()}`,
        subtype: photoAccessHelper.PhotoSubtype.DEFAULT
      };
      
      const photoUri = await phAccessHelper.createAsset(
        photoAccessHelper.PhotoType.IMAGE,
        'jpg',
        createOption
      );
      
      // 6. 写入图片数据
      const file = fileIo.openSync(photoUri, fileIo.OpenMode.READ_WRITE);
      fileIo.writeSync(file.fd, imageData);
      fileIo.closeSync(file.fd);
      
      promptAction.showToast({ message: '图片已保存到相册' });
      return true;
    } catch (err) {
      console.error('BackgroundImageUtil: 保存图片失败', err);
      const error = err as Error;
      if (error.message?.includes('permission')) {
        promptAction.showToast({ message: '没有保存图片的权限，请在设置中授权' });
      } else {
        promptAction.showToast({ message: `保存失败: ${error.message || '未知错误'}` });
      }
      return false;
    }
  }

  /**
   * 下载图片数据
   * @param url 图片 URL
   * @returns 图片二进制数据
   */
  private async downloadImage(url: string): Promise<ArrayBuffer | null> {
    try {
      // 处理 URL，移除可能的时间戳参数以获取稳定的图片
      let cleanUrl = url;
      let redirectCount = 0;
      const maxRedirects = 5;
      
      // 循环处理重定向
      while (redirectCount < maxRedirects) {
        const httpRequest = http.createHttp();
        
        const result = await new Promise<DownloadResult>((resolve) => {
          httpRequest.request(
            cleanUrl,
            {
              method: http.RequestMethod.GET,
              expectDataType: http.HttpDataType.ARRAY_BUFFER,
              connectTimeout: 30000,
              readTimeout: 60000
            },
            (err, data) => {
              httpRequest.destroy();
              
              if (err) {
                console.error('BackgroundImageUtil: 下载图片请求失败', err);
                const errorResult: DownloadResult = { code: 0, data: null, redirectUrl: '' };
                resolve(errorResult);
                return;
              }
              
              // 处理重定向 (301, 302, 303, 307, 308)
              if (data.responseCode >= 300 && data.responseCode < 400) {
                const headers = data.header as Record<string, string>;
                const location = headers['Location'] || headers['location'];
                if (location) {
                  const redirectResult: DownloadResult = { code: data.responseCode, data: null, redirectUrl: location };
                  resolve(redirectResult);
                  return;
                }
              }
              
              if (data.responseCode === 200 && data.result) {
                const successResult: DownloadResult = { code: data.responseCode, data: data.result as ArrayBuffer, redirectUrl: '' };
                resolve(successResult);
              } else {
                console.error('BackgroundImageUtil: 下载图片响应错误', data.responseCode);
                const failResult: DownloadResult = { code: data.responseCode, data: null, redirectUrl: '' };
                resolve(failResult);
              }
            }
          );
        });
        
        if (result.data) {
          return result.data;
        }
        
        if (result.redirectUrl) {
          console.info(`BackgroundImageUtil: 重定向到 ${result.redirectUrl}`);
          cleanUrl = result.redirectUrl;
          redirectCount++;
          continue;
        }
        
        // 非重定向且无数据，返回 null
        return null;
      }
      
      console.error('BackgroundImageUtil: 重定向次数超限');
      return null;
    } catch (err) {
      console.error('BackgroundImageUtil: 下载图片失败', err);
      return null;
    }
  }
}
