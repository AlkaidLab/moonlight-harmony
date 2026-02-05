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
 * 多选选项选择器弹窗组件
 * 
 * 使用 CustomDialogController 实现的底部弹窗多选选择器
 */
import { AppColors, AppSizes, AppSpacing, AppAnimation } from '../common/Theme';

/**
 * 多选选项配置
 */
export interface MultiOptionItem {
  /** 显示标题 */
  title: string;
  /** 选项键值 */
  key: string;
  /** 图标（可选）*/
  icon?: Resource;
}

/**
 * 多选选择器配置
 */
export interface MultiOptionPickerDialogConfig {
  /** 弹窗标题 */
  title: string;
  /** 副标题（可选）*/
  subtitle?: string;
  /** 选项列表 */
  options: MultiOptionItem[];
  /** 当前选中的键值列表 */
  selectedKeys: string[];
  /** 最小选中数量（可选，默认0）*/
  minSelected?: number;
  /** 选择变更回调 */
  onSelectionChange: (selectedKeys: string[]) => void;
  /** 取消回调（可选）*/
  onCancel?: () => void;
}

/**
 * 多选选项选择器弹窗
 */
@CustomDialog
export struct MultiOptionPickerDialog {
  controller: CustomDialogController;
  config: MultiOptionPickerDialogConfig = {
    title: '',
    options: [],
    selectedKeys: [],
    onSelectionChange: () => {}
  };
  
  // 本地选中状态
  @State localSelectedKeys: string[] = [];
  
  aboutToAppear(): void {
    // 复制初始选中状态
    this.localSelectedKeys = [...this.config.selectedKeys];
  }
  
  private toggleOption(key: string): void {
    const index = this.localSelectedKeys.indexOf(key);
    if (index >= 0) {
      // 取消选中 - 检查最小选中数量
      const minSelected = this.config.minSelected ?? 0;
      if (this.localSelectedKeys.length > minSelected) {
        this.localSelectedKeys = this.localSelectedKeys.filter(k => k !== key);
      }
    } else {
      // 选中
      this.localSelectedKeys = [...this.localSelectedKeys, key];
    }
  }
  
  private isSelected(key: string): boolean {
    return this.localSelectedKeys.includes(key);
  }
  
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
          ForEach(this.config.options, (option: MultiOptionItem, index: number) => {
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
              Text(option.title)
                .fontSize(AppSizes.FontBody)
                .fontColor(AppColors.TextPrimary)
                .fontWeight(this.isSelected(option.key) ? FontWeight.Bold : FontWeight.Normal)
                .layoutWeight(1)
              
              // 选中标记（复选框样式）
              Stack() {
                if (this.isSelected(option.key)) {
                  Image($r('sys.media.ohos_ic_public_ok'))
                    .width(16)
                    .height(16)
                    .fillColor(Color.White)
                }
              }
              .width(24)
              .height(24)
              .borderRadius(4)
              .backgroundColor(this.isSelected(option.key) ? AppColors.Primary : Color.Transparent)
              .border({
                width: this.isSelected(option.key) ? 0 : 2,
                color: AppColors.TextSecondary
              })
            }
            .width('100%')
            .height(56)
            .padding({ left: AppSpacing.Medium, right: AppSpacing.Medium })
            .backgroundColor(this.isSelected(option.key) ? AppColors.Surface : Color.Transparent)
            .borderRadius(12)
            .margin({ top: index === 0 ? AppSpacing.Small : 4 })
            .onClick(() => {
              this.toggleOption(option.key);
            })
          }, (option: MultiOptionItem, index: number) => `multi_option_${index}_${option.key}`)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .constraintSize({ maxHeight: 350 })
      
      // 按钮区域
      Row({ space: AppSpacing.Medium }) {
        // 取消按钮
        Button('取消')
          .layoutWeight(1)
          .height(48)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextSecondary)
          .backgroundColor(AppColors.Surface)
          .borderRadius(12)
          .onClick(() => {
            if (this.config.onCancel) {
              this.config.onCancel();
            }
            this.controller.close();
          })
        
        // 确认按钮
        Button('确定')
          .layoutWeight(1)
          .height(48)
          .fontSize(AppSizes.FontBody)
          .fontColor(Color.White)
          .backgroundColor(AppColors.Primary)
          .borderRadius(12)
          .onClick(() => {
            this.config.onSelectionChange(this.localSelectedKeys);
            this.controller.close();
          })
      }
      .width('100%')
      .margin({ top: AppSpacing.Medium })
    }
    .width('100%')
    .padding({ left: AppSpacing.Large, right: AppSpacing.Large, bottom: AppSpacing.Large })
    .backgroundColor(AppColors.Background)
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
