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
import { LengthMetrics, ColorMetrics } from '@kit.ArkUI';

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
  /** 选中状态（设置后显示系统复选框）*/
  checked?: boolean;
}

/**
 * 滑块配置（可选，显示在选项列表底部）
 */
export interface SliderConfig {
  /** 滑块标签 */
  title: string;
  /** 当前值 (0-100) */
  value: number;
  /** 最小值 */
  min: number;
  /** 最大值 */
  max: number;
  /** 步进 */
  step: number;
  /** 值变化回调 */
  onChange: (value: number) => void;
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
  /** 滑块配置（可选，显示在选项列表底部）*/
  sliderConfig?: SliderConfig;
  /** 选中后是否关闭弹窗（默认 true）*/
  closeOnSelect?: boolean;
  /** 选中后刷新选项列表（closeOnSelect=false 时使用）*/
  refreshOptions?: () => OptionItem[];
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
  
  /** 内部响应式选项列表（支持实时刷新） */
  @State liveOptions: OptionItem[] = [];
  /** 内部响应式滑块值 */
  @State sliderValue: number = 0;
  /** 是否显示滑块 */
  @State showSlider: boolean = false;
  /** 滑块标签 */
  @State sliderTitle: string = '';
  /** 滑块最小值 */
  @State sliderMin: number = 0;
  /** 滑块最大值 */
  @State sliderMax: number = 100;
  /** 滑块步进 */
  @State sliderStep: number = 5;
  
  aboutToAppear(): void {
    this.liveOptions = [...this.config.options];
    if (this.config.sliderConfig) {
      this.sliderValue = this.config.sliderConfig.value;
      this.sliderTitle = this.config.sliderConfig.title;
      this.sliderMin = this.config.sliderConfig.min;
      this.sliderMax = this.config.sliderConfig.max;
      this.sliderStep = this.config.sliderConfig.step;
      this.showSlider = true;
    }
  }
  
  build() {
    Column() {
      // 标题栏（左侧标题 + 右上角关闭按钮）
      Row() {
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
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        
        Text('✕')
          .fontSize(20)
          .fontColor(AppColors.TextSecondary)
          .padding(8)
          .borderRadius(20)
          .backgroundColor(AppColors.Surface)
          .onClick(() => {
            if (this.config.onCancel) {
              this.config.onCancel();
            }
            this.controller.close();
          })
      }
      .width('100%')
      .padding({ top: AppSpacing.Large, bottom: AppSpacing.Medium, left: AppSpacing.Medium, right: AppSpacing.Medium })
      .alignItems(VerticalAlign.Top)
      
      // 分割线
      Divider()
        .strokeWidth(0.5)
        .color(AppColors.Divider)
      
      // 选项列表（使用响应式 liveOptions）
      Scroll() {
        Column() {
          ForEach(this.liveOptions, (option: OptionItem, index: number) => {
            Row() {
              // 复选框（当 checked 已定义时显示系统 Checkbox）
              if (option.checked !== undefined) {
                Checkbox()
                  .select(option.checked)
                  .width(20)
                  .height(20)
                  .margin({ right: AppSpacing.Medium })
                  .onChange(() => {
                    this.config.onSelect(option);
                    if (this.config.closeOnSelect === false && this.config.refreshOptions) {
                      this.liveOptions = this.config.refreshOptions();
                    }
                  })
              }
              
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
            .constraintSize({ minHeight: 56 })
            .padding({ left: AppSpacing.Medium, right: AppSpacing.Medium, top: 10, bottom: 10 })
            .backgroundColor(this.config.selectedValue === option.value ? AppColors.Surface : Color.Transparent)
            .borderRadius(12)
            .margin({ top: index === 0 ? AppSpacing.Small : 4 })
            .focusable(true)
            .focusOnTouch(true)
            .focusBox({
              margin: LengthMetrics.vp(1),
              strokeColor: ColorMetrics.rgba(74, 222, 128, 0.8),
              strokeWidth: LengthMetrics.vp(1.5)
            })
            .onKeyEvent((event: KeyEvent) => {
              if (event.type === KeyType.Down) {
                // A键确认选择
                if (event.keyCode === 2054 || event.keyCode === 2050) {
                  this.config.onSelect(option);
                  if (this.config.closeOnSelect !== false) {
                    this.controller.close();
                  } else if (this.config.refreshOptions) {
                    this.liveOptions = this.config.refreshOptions();
                  }
                  return true;
                }
                // B键关闭
                if (event.keyCode === 2070 || event.keyCode === 2012) {
                  if (this.config.onCancel) {
                    this.config.onCancel();
                  }
                  this.controller.close();
                  return true;
                }
              }
              return false;
            })
            .onClick(() => {
              this.config.onSelect(option);
              if (this.config.closeOnSelect === false) {
                // 保持弹窗打开，刷新选项列表
                if (this.config.refreshOptions) {
                  this.liveOptions = this.config.refreshOptions();
                }
              } else {
                this.controller.close();
              }
            })
          }, (option: OptionItem, index: number) => `option_${index}_${option.title}`)
          
          // 滑块区域（在选项列表末尾，滚动区域内）
          if (this.showSlider) {
            Divider()
              .strokeWidth(0.5)
              .color(AppColors.Divider)
              .margin({ top: AppSpacing.Small, bottom: AppSpacing.Small })
            
            Row() {
              Text(this.sliderTitle)
                .fontSize(AppSizes.FontBody)
                .fontColor(AppColors.TextPrimary)
              Blank()
              Text(`${Math.round(this.sliderValue)}%`)
                .fontSize(AppSizes.FontBody)
                .fontColor(AppColors.Primary)
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            .padding({ left: AppSpacing.Medium, right: AppSpacing.Medium })
            
            Slider({
              value: this.sliderValue,
              min: this.sliderMin,
              max: this.sliderMax,
              step: this.sliderStep,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .blockColor(AppColors.Primary)
              .trackColor(AppColors.Surface)
              .selectedColor(AppColors.Primary)
              .showSteps(false)
              .showTips(false)
              .padding({ left: AppSpacing.Medium, right: AppSpacing.Medium })
              .onChange((value: number) => {
                this.sliderValue = value;
                this.config.sliderConfig?.onChange(value);
              })
          }
        }
        .width('100%')
      }
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
      .constraintSize({ maxHeight: '60%' })
      
    }
    .width('100%')
    .padding({ left: AppSpacing.Large, right: AppSpacing.Large, bottom: AppSpacing.Large })
    .backgroundColor(AppColors.Background)
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
