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
 * 选项选择器弹窗组件
 * 
 * 使用 CustomDialogController 实现的底部弹窗选择器
 * 选项高度更大，更易于点击
 */
import { AppColors, AppSizes, AppSpacing, AppAnimation } from '../common/Theme';

/**
 * 选项配置
 */
export interface OptionItem {
  /** 显示标题 */
  title: string;
  /** 副标题（可选）*/
  subtitle?: string;
  /** 选项值 */
  value: string | number;
  /** 图标（可选）*/
  icon?: Resource;
}

/**
 * 选择器配置
 */
export interface OptionPickerDialogConfig {
  /** 弹窗标题 */
  title: string;
  /** 副标题（可选）*/
  subtitle?: string;
  /** 选项列表 */
  options: OptionItem[];
  /** 当前选中值 */
  selectedValue?: string | number;
  /** 选中回调 */
  onSelect: (option: OptionItem) => void;
  /** 取消回调（可选）*/
  onCancel?: () => void;
}

/**
 * 选项选择器弹窗
 */
@CustomDialog
export struct OptionPickerDialog {
  controller: CustomDialogController;
  config: OptionPickerDialogConfig = {
    title: '',
    options: [],
    onSelect: () => {}
  };
  
  build() {
    Column() {
      // 标题栏
      Column() {
        Text(this.config.title)
          .fontSize(AppSizes.FontTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.TextPrimary)
          .margin({ bottom: 4 })
        
        if (this.config.subtitle) {
          Text(this.config.subtitle)
            .fontSize(AppSizes.FontCaption)
            .fontColor(AppColors.TextSecondary)
        }
      }
      .width('100%')
      .padding({ top: AppSpacing.Large, bottom: AppSpacing.Medium })
      .alignItems(HorizontalAlign.Center)
      
      // 分割线
      Divider()
        .strokeWidth(0.5)
        .color(AppColors.Divider)
      
      // 选项列表
      Scroll() {
        Column() {
          ForEach(this.config.options, (option: OptionItem, index: number) => {
            Row() {
              // 图标（如果有）
              if (option.icon) {
                Image(option.icon)
                  .width(24)
                  .height(24)
                  .fillColor(AppColors.TextPrimary)
                  .margin({ right: AppSpacing.Medium })
              }
              
              // 文本内容
              Column() {
                Text(option.title)
                  .fontSize(AppSizes.FontBody)
                  .fontColor(AppColors.TextPrimary)
                  .fontWeight(this.config.selectedValue === option.value ? FontWeight.Bold : FontWeight.Normal)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                
                if (option.subtitle) {
                  Text(option.subtitle)
                    .fontSize(AppSizes.FontCaption)
                    .fontColor(AppColors.TextSecondary)
                    .margin({ top: 2 })
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              
              // 选中标记
              if (this.config.selectedValue === option.value) {
                Image($r('sys.media.ohos_ic_public_ok'))
                  .width(24)
                  .height(24)
                  .fillColor(AppColors.Primary)
              }
            }
            .width('100%')
            .constraintSize({ minHeight: 56 })  // 最小高度，内容多时自动扩展
            .padding({ left: AppSpacing.Medium, right: AppSpacing.Medium, top: 10, bottom: 10 })
            .backgroundColor(this.config.selectedValue === option.value ? AppColors.Surface : Color.Transparent)
            .borderRadius(12)
            .margin({ top: index === 0 ? AppSpacing.Small : 4 })
            .onClick(() => {
              this.config.onSelect(option);
              this.controller.close();
            })
          }, (option: OptionItem, index: number) => `option_${index}_${option.value}`)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .constraintSize({ maxHeight: 400 })
      
      // 取消按钮
      Button('取消')
        .width('100%')
        .height(52)
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .backgroundColor(AppColors.Surface)
        .borderRadius(12)
        .margin({ top: AppSpacing.Medium })
        .onClick(() => {
          if (this.config.onCancel) {
            this.config.onCancel();
          }
          this.controller.close();
        })
    }
    .width('100%')
    .padding({ left: AppSpacing.Large, right: AppSpacing.Large, bottom: AppSpacing.Large })
    .backgroundColor(AppColors.Background)
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
