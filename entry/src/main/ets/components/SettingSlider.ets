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
 * 设置页面专用滑块组件
 * 
 * 特性：
 * - 跟手拖动（拖动时不更新状态）
 * - 支持对数刻度（适合大范围值如码率）
 * - 支持吸附关键值
 * - 自定义格式化显示
 */
import { AppColors, AppSizes } from '../common/Theme';

/**
 * 对数滑块转换工具类
 * 用于将大范围值（如1-150 Mbps码率）映射到滑块的线性位置
 */
export class LogarithmicSlider {
  /**
   * 将线性滑块位置 (0-100) 转换为对数分布的实际值
   * @param linearValue 滑块的线性位置 (0-100)
   * @param min 最小实际值
   * @param max 最大实际值
   * @returns 对数缩放后的实际值
   */
  static linearToLog(linearValue: number, min: number, max: number): number {
    if (linearValue <= 0 || min <= 0) return min;
    if (linearValue >= 100) return max;

    const minLog = Math.log(min);
    const maxLog = Math.log(max);
    const logRange = maxLog - minLog;

    // 线性位置 (0-100) -> 对数值
    const normalizedValue = linearValue / 100;
    const result = Math.exp(minLog + normalizedValue * logRange);
    return Math.round(result);
  }
  
  /**
   * 将实际值转换为线性滑块位置 (0-100)
   * @param logValue 实际值（对数缩放的）
   * @param min 最小实际值
   * @param max 最大实际值
   * @returns 线性滑块位置 (0-100)
   */
  static logToLinear(logValue: number, min: number, max: number): number {
    if (logValue <= min) return 0;
    if (logValue >= max) return 100;

    const minLog = Math.log(min);
    const maxLog = Math.log(max);
    const logRange = maxLog - minLog;

    // 对数值 -> 线性位置 (0-100)
    const normalizedValue = (Math.log(logValue) - minLog) / logRange;
    return Math.round(normalizedValue * 100);
  }
}

/**
 * 滑块配置接口
 */
export interface SettingSliderConfig {
  /** 当前值 */
  value: number;
  /** 最小值 */
  min: number;
  /** 最大值 */
  max: number;
  /** 步进值（普通滑块有效）*/
  step?: number;
  /** 单位（如 Mbps、%）*/
  unit?: string;
  /** 是否使用对数刻度 */
  isLogarithmic?: boolean;
  /** 吸附关键值数组 */
  snapValues?: number[];
  /** 吸附阈值 */
  snapThreshold?: number;
  /** 自定义格式化函数 */
  formatValue?: (value: number) => string;
  /** 值改变回调（松手时触发）*/
  onChange: (value: number) => void;
}

/**
 * 设置滑块组件
 * 
 * 使用示例：
 * ```
 * SettingSlider({
 *   config: {
 *     value: this.bitrate,
 *     min: 1,
 *     max: 150,
 *     isLogarithmic: true,
 *     unit: ' Mbps',
 *     snapValues: [5, 10, 20, 50, 100],
 *     snapThreshold: 3,
 *     formatValue: (v) => v === 0 ? '自动' : `${v} Mbps`,
 *     onChange: (value) => { this.bitrate = value; }
 *   }
 * })
 * ```
 */
@Component
export struct SettingSlider {
  @Prop config: SettingSliderConfig;
  // 拖动时的临时显示值（用于气泡和右侧Text）
  @State private draggingValue: number = 0;
  @State private isDragging: boolean = false;
  
  build() {
    Row() {
      Slider({
        value: this.getSliderValue(),
        min: this.config.isLogarithmic ? 0 : this.config.min,
        max: this.config.isLogarithmic ? 100 : this.config.max,
        step: this.config.isLogarithmic ? 1 : (this.config.step ?? 1),
        style: SliderStyle.OutSet
      })
        .layoutWeight(1)
        .selectedColor(AppColors.Primary)
        .trackColor(AppColors.SurfaceDark)
        .blockSize({ width: 28, height: 28 })  // 稍大一些，更易于控制器选中
        .trackThickness(8)  // 稍粗一些
        .showTips(this.isDragging, this.formatValue(this.draggingValue))
        .focusable(true)  // 确保可以获得焦点
        .defaultFocus(false)
        .focusOnTouch(true)  // 触摸时获取焦点
        .onChange((value: number, mode: SliderChangeMode) => {
          // 计算实际值
          let actualValue = this.calculateActualValue(value);
          
          // 拖动时更新临时显示值
          if (mode === SliderChangeMode.Moving || mode === SliderChangeMode.Begin) {
            this.draggingValue = actualValue;
            this.isDragging = true;
            return;  // 不触发onChange回调
          }
          
          // 松手或点击时
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.isDragging = false;
            
            // 应用吸附
            let finalValue = this.applySnap(actualValue);
            
            // 触发回调
            this.config.onChange(finalValue);
          }
        })

      // 显示当前值（拖动时显示临时值，否则显示保存值）
      Text(this.isDragging ? this.formatValue(this.draggingValue) : this.formatDisplayValue())
        .fontSize(AppSizes.FontCaption)
        .fontColor(AppColors.TextSecondary)
        .width(70)
        .textAlign(TextAlign.End)
    }
    .width('100%')
  }
  
  /**
   * 获取滑块当前位置值
   */
  private getSliderValue(): number {
    if (this.config.isLogarithmic) {
      // 对数滑块：将实际值转换为 0-100 线性位置
      if (this.config.value === 0) {
        return 0;  // 特殊值（如"自动"）
      }
      return LogarithmicSlider.logToLinear(
        this.config.value, 
        this.config.min, 
        this.config.max
      );
    }
    return this.config.value;
  }
  
  /**
   * 将滑块位置转换为实际值
   */
  private calculateActualValue(sliderValue: number): number {
    if (this.config.isLogarithmic) {
      if (sliderValue === 0) {
        return 0;  // 特殊值
      }
      return LogarithmicSlider.linearToLog(
        sliderValue, 
        this.config.min, 
        this.config.max
      );
    }
    return sliderValue;
  }
  
  /**
   * 应用吸附逻辑
   */
  private applySnap(value: number): number {
    if (!this.config.snapValues || this.config.snapValues.length === 0) {
      return value;
    }
    
    const threshold = this.config.snapThreshold ?? 
      (this.config.isLogarithmic ? 2 : (this.config.step ?? 1));
    
    for (const snapValue of this.config.snapValues) {
      if (Math.abs(value - snapValue) <= threshold) {
        return snapValue;
      }
    }
    
    return value;
  }
  
  /**
   * 格式化任意值（用于拖动时的气泡显示）
   */
  private formatValue(value: number): string {
    if (this.config.formatValue) {
      return this.config.formatValue(value);
    }
    return `${Math.round(value)}${this.config.unit ?? ''}`;
  }
  
  /**
   * 格式化当前值（用于右侧显示）
   */
  private formatDisplayValue(): string {
    if (this.config.formatValue) {
      return this.config.formatValue(this.config.value);
    }
    return `${this.config.value}${this.config.unit ?? ''}`;
  }
}
