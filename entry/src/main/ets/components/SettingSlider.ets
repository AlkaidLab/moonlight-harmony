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
 * - 支持吸附关键值（拖动时磁性吸附 + 触觉反馈）
 * - 自定义格式化显示
 */
import { AppColors, AppSizes } from '../common/Theme';
import { vibrator } from '@kit.SensorServiceKit';

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
  config: SettingSliderConfig = {
    value: 0,
    min: 0,
    max: 100,
    onChange: (_v: number) => {}
  };
  // 滑块当前位置（使用 $$ 双向绑定让 Slider 可读写）
  @State private sliderPosition: number = 0;
  // 拖动时的临时显示值（用于气泡和右侧Text）
  @State private draggingValue: number = 0;
  @State private isDragging: boolean = false;
  // 当前已确认的值（@State 确保松手后文本即刻更新）
  @State private committedValue: number = 0;
  // 上一次吸附到的值（用于避免重复触觉反馈）
  private lastSnappedValue: number = -1;

  aboutToAppear(): void {
    // 初始化滑块位置和已确认值
    this.committedValue = this.config.value;
    this.sliderPosition = this.valueToPosition(this.config.value);
  }

  /**
   * 吸附时触发轻微触觉反馈
   * 使用 20ms 短促振动以获得清晰的"咔嗒"手感
   */
  private triggerSnapHaptic(): void {
    try {
      vibrator.startVibration({
        type: 'time',
        duration: 20
      }, {
        id: 0,
        usage: 'touch'
      })
    } catch (_e) {
      // 忽略振动失败
    }
  }

  /**
   * 将实际值转换为滑块位置
   */
  private valueToPosition(value: number): number {
    if (this.config.isLogarithmic) {
      if (value === 0) return 0;
      return LogarithmicSlider.logToLinear(value, this.config.min, this.config.max);
    }
    return value;
  }
  
  build() {
    Row() {
      Slider({
        value: $$this.sliderPosition,
        min: this.config.isLogarithmic ? 0 : this.config.min,
        max: this.config.isLogarithmic ? 100 : this.config.max,
        step: this.config.isLogarithmic ? 1 : (this.config.step ?? 1),
        style: SliderStyle.OutSet
      })
        .layoutWeight(1)
        .selectedColor(AppColors.Primary)
        .trackColor(AppColors.SurfaceDark)
        .blockSize({ width: 28, height: 28 })
        .trackThickness(8)
        .showTips(this.isDragging, this.formatValue(this.draggingValue))
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
        .focusable(true)
        .defaultFocus(false)
        .focusOnTouch(true)
        .onChange((value: number, mode: SliderChangeMode) => {
          // 计算实际值
          let actualValue = this.calculateActualValue(value);
          
          // 拖动时：显示预览 + 触觉提示（不改变滑块位置，避免与 $$ 双向绑定冲突）
          if (mode === SliderChangeMode.Moving || mode === SliderChangeMode.Begin) {
            // 检查是否进入吸附范围
            let snappedValue: number = this.applySnap(actualValue);
            if (snappedValue !== actualValue) {
              // 在吸附区域内 - 显示吸附后的值，触觉提示
              this.draggingValue = snappedValue;
              if (this.lastSnappedValue !== snappedValue) {
                this.lastSnappedValue = snappedValue;
                this.triggerSnapHaptic();
              }
            } else {
              // 不在吸附区域 - 显示实际拖动值
              this.draggingValue = actualValue;
              this.lastSnappedValue = -1;
            }
            this.isDragging = true;
            return;  // 不触发onChange回调
          }
          
          // 松手或点击时：应用吸附并跳转
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.isDragging = false;
            
            // 应用吸附
            let finalValue = this.applySnap(actualValue);
            
            // 将滑块位置更新到吸附后的精确位置
            this.sliderPosition = this.valueToPosition(finalValue);
            
            // 更新已确认值（@State → 立刻刷新右侧文本）
            this.committedValue = finalValue;
            
            // 触发回调
            this.config.onChange(finalValue);
          }
        })

      // 显示当前值（拖动时显示临时值，否则显示已确认值）
      Text(this.isDragging ? this.formatValue(this.draggingValue) : this.formatValue(this.committedValue))
        .fontSize(AppSizes.FontCaption)
        .fontColor(AppColors.TextSecondary)
        .width(70)
        .textAlign(TextAlign.End)
    }
    .width('100%')
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
    // 根据步进值四舍五入，避免 Slider 浮点精度问题（如 60.00001 → 60）
    const step: number = this.config.step ?? 1;
    return Math.round(sliderValue / step) * step;
  }
  
  /**
   * 应用吸附逻辑
   * 对数滑块使用比例阈值（默认 ±8% 的值比例），确保高低两端吸附感受一致
   * 线性滑块使用绝对阈值
   */
  private applySnap(value: number): number {
    if (!this.config.snapValues || this.config.snapValues.length === 0) {
      return value;
    }
    
    if (this.config.isLogarithmic) {
      // 对数滑块：使用比例阈值，高低端体验一致
      const ratio: number = this.config.snapThreshold !== undefined
        ? this.config.snapThreshold / 100
        : 0.08;  // 默认 8%
      for (const snapValue of this.config.snapValues) {
        const dynamicThreshold: number = Math.max(snapValue * ratio, 1);
        if (Math.abs(value - snapValue) <= dynamicThreshold) {
          return snapValue;
        }
      }
    } else {
      // 线性滑块：使用绝对阈值
      const threshold: number = this.config.snapThreshold ?? (this.config.step ?? 1);
      for (const snapValue of this.config.snapValues) {
        if (Math.abs(value - snapValue) <= threshold) {
          return snapValue;
        }
      }
    }
    
    return value;
  }
  
  /**
   * 格式化任意值（用于气泡和右侧显示）
   */
  private formatValue(value: number): string {
    if (this.config.formatValue) {
      return this.config.formatValue(value);
    }
    return `${Math.round(value)}${this.config.unit ?? ''}`;
  }
}
