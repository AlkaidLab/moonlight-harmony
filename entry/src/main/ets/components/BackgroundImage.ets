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
 * 背景图组件
 * 可复用的页面背景图组件，支持网络图片和渐变叠加
 * 使用 SaveButton 安全控件保存图片，无需申请 WRITE_IMAGEVIDEO 权限
 */
import { AppColors } from '../common/Theme';
import { BackgroundImageUtil } from '../utils/BackgroundImageUtil';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ToastQueue } from '../utils/ToastQueue';

/**
 * 背景图组件属性
 */
interface BackgroundImageProps {
  imageUrl: string;
  imageOpacity?: number;
  enableLongPressSave?: boolean;
}

// 像素地图中单个 tile
interface PixelTile {
  ch: string;        // 'V'山岩 / '+'草木
  color: string;
}

// 复古像素风地图色板（6 种地形）
const TILE_PALETTE: PixelTile[] = [
  { ch: '+', color: 'rgba(143, 203, 107, 0.85)' },  // 草绿 - 平原
  { ch: '+', color: 'rgba(229, 199, 107, 0.85)' },  // 沙黄 - 沙漠
  { ch: 'V', color: 'rgba(168, 116, 74,  0.90)' },  // 山棕 - 山岩
  { ch: 'V', color: 'rgba(91,  168, 216, 0.85)' },  // 水蓝 - 海洋
  { ch: '+', color: 'rgba(220, 110, 150, 0.80)' },  // 花粉 - 花田
  { ch: 'V', color: 'rgba(156, 107, 198, 0.85)' }   // 山紫 - 魔法地
];

// 28x42 高密度像素地图
const PIXEL_MAP_COLS = 28;
const PIXEL_MAP_ROWS = 42;
const PIXEL_TILES: PixelTile[] = (() => {
  const arr: PixelTile[] = [];
  for (let r = 0; r < PIXEL_MAP_ROWS; r++) {
    for (let c = 0; c < PIXEL_MAP_COLS; c++) {
      const h = (r * 7 + c * 13 + r * c * 3 + (r * r + c * c) % 11) % TILE_PALETTE.length;
      // 二级哈希：用于生成随机斝驳（碳化黑点 / 褐色亮点 / 缺失空位）
      const h2 = (r * 31 + c * 17 + (r ^ c) * 5 + r * c * c) % 25;
      let tile = TILE_PALETTE[h];
      if (h2 === 1) {
        tile = { ch: tile.ch, color: 'rgba(40, 30, 25, 0.90)' };       // 黑斝 - 碳化/烧焦
      } else if (h2 === 7) {
        tile = { ch: tile.ch, color: 'rgba(245, 235, 210, 0.50)' };    // 亮斝 - 褐色/反光
      } else if (h2 === 13) {
        tile = { ch: '', color: '' };                                  // 缺失 - 背景透出
      }
      arr.push(tile);
    }
  }
  return arr;
})();

@Component
export struct BackgroundImage {
  @Prop imageUrl: string = '';
  @Prop imageOpacity: number = 0.15;
  @Prop enableLongPressSave: boolean = true;
  @State showSaveDialog: boolean = false;
  // 淡入过渡效果：图片加载完成前透明度为 0
  @State currentOpacity: number = 0;
  // 标记网络壁纸是否已加载完成，用于控制默认装饰层淡出
  @State imageLoaded: boolean = false;
  // 记录上一次的 URL，检测变化时重置淡入
  private lastImageUrl: string = '';
  
  private backgroundUtil = BackgroundImageUtil.getInstance();
  
  /**
   * SaveButton 点击回调处理
   * 使用安全控件授权后保存图片到相册
   */
  handleSaveButtonClick: SaveButtonCallback = async (
    event: ClickEvent, 
    result: SaveButtonOnClickResult, 
    error?: BusinessError
  ) => {
    if (result === SaveButtonOnClickResult.SUCCESS) {
      try {
        const context = getContext(this) as common.UIAbilityContext;
        ToastQueue.show({ message: '正在保存图片...' });
        
        // 获取图片数据
        let imageData = this.backgroundUtil.getCachedImageData();
        if (!imageData) {
          // 如果没有缓存数据，重新获取
          imageData = await this.backgroundUtil.downloadImageData(this.imageUrl);
        }
        
        if (!imageData) {
          ToastQueue.show({ message: '图片数据获取失败' });
          this.showSaveDialog = false;
          return;
        }
        
        // 使用 SaveButton 授权后创建图片资源
        const helper = photoAccessHelper.getPhotoAccessHelper(context);
        const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
        
        // 写入图片数据
        const file = await fileIo.open(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        await fileIo.write(file.fd, imageData);
        await fileIo.close(file.fd);
        
        ToastQueue.show({ message: '图片已保存到相册' });
      } catch (err) {
        console.error('BackgroundImage: 保存图片失败', err);
        const e = err as BusinessError;
        ToastQueue.show({ message: `保存失败: ${e.message || '未知错误'}` });
      }
    } else if (result === SaveButtonOnClickResult.TEMPORARY_AUTHORIZATION_FAILED) {
      console.error('BackgroundImage: 授权失败', error);
      ToastQueue.show({ message: '保存授权失败' });
    }
    this.showSaveDialog = false;
  };

  build() {
    Stack() {
      // 纯色基础背景
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(AppColors.Background)

      // 默认装饰层：使用 V 和 + 两个字符摆出复古像素风游戏地图
      // 28x42 高密度网格，主色板 6 色地形（草绿/沙黄/山棕/水蓝/花粉/魔法紫）
      // 加随机斝驳：~4% 黑斝 / ~4% 亮斝 / ~4% 缺失，仿复古地图的年代感
      Grid() {
        ForEach(PIXEL_TILES, (tile: PixelTile, index: number) => {
          GridItem() {
            if (tile.ch !== '') {
              Text(tile.ch)
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .fontFamily('HarmonyOS Mono')
                .fontColor(tile.color)
            }
          }
        }, (tile: PixelTile, index: number) => `t${index}`)
      }
      .columnsTemplate('repeat(' + PIXEL_MAP_COLS + ', 1fr)')
      .rowsTemplate('repeat(' + PIXEL_MAP_ROWS + ', 1fr)')
      .width('100%')
      .height('100%')
      .opacity(this.imageLoaded ? 0 : 0.55)
      .animation({ duration: 600, curve: Curve.EaseOut })

      // 网络图片背景 - 带淡入过渡效果（加载完成后会淡入覆盖装饰层）
      if (this.imageUrl && this.imageUrl.length > 0) {
        Image(this.imageUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.currentOpacity)
          .animation({
            duration: 600,
            curve: Curve.EaseOut
          })
          .onAppear(() => {
            // URL 变化时重置透明度与加载标志
            if (this.lastImageUrl !== this.imageUrl) {
              this.currentOpacity = 0;
              this.imageLoaded = false;
              this.lastImageUrl = this.imageUrl;
            }
          })
          .onComplete(() => {
            // 图片加载完成，淡入到目标透明度，并通知装饰层淡出
            this.currentOpacity = this.imageOpacity;
            this.imageLoaded = true;
            // 仅在支持长按保存时预缓存图片数据
            if (this.enableLongPressSave) {
              this.backgroundUtil.preloadAndCacheImage();
            }
          })
          .onError(() => {
            // 加载失败保持装饰层显示
            this.imageLoaded = false;
            console.warn('BackgroundImage: 背景图加载失败', this.imageUrl);
          })
          .gesture(
            LongPressGesture({ repeat: false, duration: 800 })
              .onAction(() => {
                if (this.enableLongPressSave) {
                  this.showSaveDialog = true;
                }
              })
          )
        
        // 简化渐变叠加层 - 使用更少的颜色stops
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [
              [AppColors.Background, 0.0],
              ['rgba(0,0,0,0)', 0.4],
              [AppColors.Background, 1.0]
            ]
          })
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showSaveDialog, this.SaveImageSheet(), {
      height: SheetSize.FIT_CONTENT,
      backgroundColor: AppColors.CardBackground,
      blurStyle: BlurStyle.COMPONENT_ULTRA_THICK,
      preferType: SheetType.BOTTOM,
      title: { title: '保存背景图' }
    })
  }
  
  /**
   * 保存图片的底部弹窗
   * 使用 SaveButton 安全控件替代传统权限申请
   */
  @Builder
  SaveImageSheet() {
    Column() {
      Text('是否将当前背景图保存到相册？')
        .fontSize(14)
        .fontColor(AppColors.TextSecondary)
        .margin({ bottom: 24, top: 8 })
      
      Row({ space: 16 }) {
        Button('取消')
          .backgroundColor(AppColors.CardBackgroundHover)
          .fontColor(AppColors.TextPrimary)
          .height(44)
          .width('45%')
          .onClick(() => {
            this.showSaveDialog = false;
          })
        
        // 使用 SaveButton 安全控件
        SaveButton({ 
          icon: SaveIconStyle.FULL_FILLED, 
          text: SaveDescription.SAVE_IMAGE, 
          buttonType: ButtonType.Capsule 
        })
          .onClick(this.handleSaveButtonClick)
          .height(44)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ left: 16, right: 16, bottom: 24 })
    }
    .width('100%')
  }
}

/**
 * 简单背景图组件（无渐变）
 */
@Component
export struct SimpleBackgroundImage {
  @Prop imageUrl: string = '';
  @Prop imageOpacity: number = 0.2;

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(AppColors.Background)

      if (this.imageUrl && this.imageUrl.length > 0) {
        Image(this.imageUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.imageOpacity)
      }
    }
    .width('100%')
    .height('100%')
  }
}
