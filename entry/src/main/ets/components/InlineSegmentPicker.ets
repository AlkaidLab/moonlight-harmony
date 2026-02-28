/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { SegmentButton, SegmentButtonOptions, SegmentButtonTextItem } from '@kit.ArkUI';

/**
 * 内联分段选择器 - 包装 HarmonyOS SegmentButton
 * 用于选项数量在 2-5 个之间的设置项，替代弹窗式选择器
 */
@Component
export struct InlineSegmentPicker {
  /** 选项显示文字数组（初始化时设置，不可动态修改） */
  labels: string[] = []
  /** 初始选中值（仅在 aboutToAppear 读取，之后由组件内部管理） */
  selectedValue: string = ''
  /** 选项实际值数组（可选，默认与 labels 相同） */
  values: string[] = []
  /** 是否禁用 */
  @Prop disabled: boolean = false
  /** 选择变化回调 */
  onValueChange?: (value: string) => void

  @State @Watch('onSelectedIndexesChange') selectedIndexes: number[] = [0]
  @State segmentOptions: SegmentButtonOptions | undefined = undefined
  private isInitialized: boolean = false

  aboutToAppear(): void {
    this.buildOptions()
    this.initSelectedIndex()
    this.isInitialized = true
  }

  /**
   * 构建 SegmentButtonOptions（仅在 aboutToAppear 调用一次）
   */
  private buildOptions(): void {
    const len = this.labels.length
    if (len < 2 || len > 5) {
      return
    }
    // 创建 SegmentButtonTextItem 数组
    const items: SegmentButtonTextItem[] = []
    for (let i = 0; i < len; i++) {
      const item: SegmentButtonTextItem = { text: this.labels[i] } as SegmentButtonTextItem
      items.push(item)
    }
    // 按选项数量直接构建 SegmentButtonOptions，元组字面量传入 capsule()
    if (len === 2) {
      this.segmentOptions = SegmentButtonOptions.capsule({
        buttons: [items[0], items[1]],
        multiply: false
      })
    } else if (len === 3) {
      this.segmentOptions = SegmentButtonOptions.capsule({
        buttons: [items[0], items[1], items[2]],
        multiply: false
      })
    } else if (len === 4) {
      this.segmentOptions = SegmentButtonOptions.capsule({
        buttons: [items[0], items[1], items[2], items[3]],
        multiply: false
      })
    } else {
      this.segmentOptions = SegmentButtonOptions.capsule({
        buttons: [items[0], items[1], items[2], items[3], items[4]],
        multiply: false
      })
    }
  }

  private initSelectedIndex(): void {
    const actualValues: string[] = this.values.length > 0 ? this.values : this.labels
    const idx: number = actualValues.indexOf(this.selectedValue)
    this.selectedIndexes = [idx >= 0 ? idx : 0]
  }

  private onSelectedIndexesChange(): void {
    if (!this.isInitialized) {
      return
    }
    const callback: ((value: string) => void) | undefined = this.onValueChange
    if (callback === undefined) {
      return
    }
    if (this.selectedIndexes.length > 0) {
      const actualValues: string[] = this.values.length > 0 ? this.values : this.labels
      const selectedIdx: number = this.selectedIndexes[0]
      if (selectedIdx >= 0 && selectedIdx < actualValues.length) {
        const newValue: string = actualValues[selectedIdx]
        // 仅当值实际变化时才触发回调，避免 prop 更新引起的循环
        if (newValue !== this.selectedValue) {
          // 延迟回调，避免父组件 re-render 中断 SegmentButton 的内部动画
          setTimeout(() => {
            callback(newValue)
          }, 0)
        }
      }
    }
  }

  build() {
    if (this.segmentOptions) {
      // SegmentButton 不支持通用属性，必须通过容器应用 width/enabled/opacity 等
      Column() {
        SegmentButton({
          options: this.segmentOptions,
          selectedIndexes: $selectedIndexes
        })
      }
      .width('100%')
      .constraintSize({ maxWidth: 448 })
      .enabled(!this.disabled)
      .opacity(this.disabled ? 0.5 : 1.0)
    }
  }
}
