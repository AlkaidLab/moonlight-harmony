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

/**
 * 背景图组件属性
 */
interface BackgroundImageProps {
  imageUrl: string;
  imageOpacity?: number;
  enableLongPressSave?: boolean;
}

@Component
export struct BackgroundImage {
  @Prop imageUrl: string = '';
  @Prop imageOpacity: number = 0.15;
  @Prop enableLongPressSave: boolean = true;
  @State showSaveDialog: boolean = false;
  
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
        promptAction.showToast({ message: '正在保存图片...' });
        
        // 获取图片数据
        let imageData = this.backgroundUtil.getCachedImageData();
        if (!imageData) {
          // 如果没有缓存数据，重新获取
          imageData = await this.backgroundUtil.downloadImageData(this.imageUrl);
        }
        
        if (!imageData) {
          promptAction.showToast({ message: '图片数据获取失败' });
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
        
        promptAction.showToast({ message: '图片已保存到相册' });
      } catch (err) {
        console.error('BackgroundImage: 保存图片失败', err);
        const e = err as BusinessError;
        promptAction.showToast({ message: `保存失败: ${e.message || '未知错误'}` });
      }
    } else if (result === SaveButtonOnClickResult.TEMPORARY_AUTHORIZATION_FAILED) {
      console.error('BackgroundImage: 授权失败', error);
      promptAction.showToast({ message: '保存授权失败' });
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

      // 网络图片背景 - 移除 blur 效果以提升性能
      if (this.imageUrl && this.imageUrl.length > 0) {
        Image(this.imageUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.imageOpacity)
          .onComplete(() => {
            // 仅在支持长按保存时预缓存图片数据
            if (this.enableLongPressSave) {
              this.backgroundUtil.preloadAndCacheImage();
            }
          })
          .onError(() => {
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
