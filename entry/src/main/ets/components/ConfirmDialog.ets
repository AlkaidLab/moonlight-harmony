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
 * 确认弹窗和信息弹窗组件
 * 
 * 使用 CustomDialogController 实现的弹窗
 */
import { AppColors, AppSizes, AppSpacing, AppAnimation } from '../common/Theme';

/**
 * 确认弹窗按钮配置
 */
export interface DialogButton {
  /** 按钮文字 */
  text: string;
  /** 按钮颜色（可选）*/
  color?: ResourceColor;
  /** 点击回调 */
  onClick: () => void;
}

/**
 * 确认弹窗配置
 */
export interface ConfirmDialogConfig {
  /** 弹窗标题 */
  title: string;
  /** 弹窗消息 */
  message: string;
  /** 取消按钮（可选，默认显示"取消"）*/
  cancelButton?: DialogButton;
  /** 确认按钮 */
  confirmButton: DialogButton;
}

/**
 * 确认弹窗组件
 */
@CustomDialog
export struct ConfirmDialog {
  controller: CustomDialogController;
  config: ConfirmDialogConfig = {
    title: '',
    message: '',
    confirmButton: { text: '确定', onClick: () => {} }
  };
  
  build() {
    Column() {
      // 标题
      Text(this.config.title)
        .fontSize(AppSizes.FontTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.TextPrimary)
        .margin({ bottom: AppSpacing.Medium })
      
      // 消息内容
      Text(this.config.message)
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .textAlign(TextAlign.Center)
        .margin({ bottom: AppSpacing.Large })
      
      // 按钮区域
      Row({ space: AppSpacing.Medium }) {
        // 取消按钮
        Button(this.config.cancelButton?.text ?? '取消')
          .layoutWeight(1)
          .height(48)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextSecondary)
          .backgroundColor(AppColors.Surface)
          .borderRadius(12)
          .onClick(() => {
            if (this.config.cancelButton?.onClick) {
              this.config.cancelButton.onClick();
            }
            this.controller.close();
          })
        
        // 确认按钮
        // 如果指定了颜色（如 Error 红色），使用该颜色作为背景，文字始终为白色
        Button(this.config.confirmButton.text)
          .layoutWeight(1)
          .height(48)
          .fontSize(AppSizes.FontBody)
          .fontColor(Color.White)
          .backgroundColor(this.config.confirmButton.color ?? AppColors.Primary)
          .borderRadius(12)
          .onClick(() => {
            this.config.confirmButton.onClick();
            this.controller.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(AppSpacing.Large)
    .backgroundColor(AppColors.Background)
    .borderRadius(16)
  }
}

/**
 * 信息弹窗配置
 */
export interface InfoDialogConfig {
  /** 弹窗标题 */
  title: string;
  /** 弹窗内容 */
  content: string;
  /** 关闭按钮文字（可选，默认"知道了"）*/
  closeButtonText?: string;
  /** 关闭回调（可选）*/
  onClose?: () => void;
}

/**
 * 信息弹窗组件
 */
@CustomDialog
export struct InfoDialog {
  controller: CustomDialogController;
  config: InfoDialogConfig = {
    title: '',
    content: ''
  };
  
  build() {
    Column() {
      // 标题
      Text(this.config.title)
        .fontSize(AppSizes.FontTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.TextPrimary)
        .margin({ bottom: AppSpacing.Medium })
      
      // 内容
      Scroll() {
        Text(this.config.content)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextSecondary)
          .textAlign(TextAlign.Start)
      }
      .scrollBar(BarState.Auto)
      .constraintSize({ maxHeight: 300 })
      .width('100%')
      .margin({ bottom: AppSpacing.Large })
      
      // 关闭按钮
      Button(this.config.closeButtonText ?? '知道了')
        .width('100%')
        .height(48)
        .fontSize(AppSizes.FontBody)
        .fontColor(Color.White)
        .backgroundColor(AppColors.Primary)
        .borderRadius(12)
        .onClick(() => {
          if (this.config.onClose) {
            this.config.onClose();
          }
          this.controller.close();
        })
    }
    .width('100%')
    .padding(AppSpacing.Large)
    .backgroundColor(AppColors.Background)
    .borderRadius(16)
  }
}

/**
 * 选项按钮配置（带副标题）
 */
export interface ActionButton {
  /** 按钮主文字 */
  text: string;
  /** 副标题说明（可选） */
  subtitle?: string;
  /** 按钮文字颜色（可选）*/
  color?: ResourceColor;
  /** 按钮背景颜色（可选）*/
  backgroundColor?: ResourceColor;
  /** 点击回调 */
  onClick: () => void;
}

/**
 * 操作选择弹窗配置
 */
export interface ActionDialogConfig {
  /** 弹窗标题 */
  title: string;
  /** 弹窗消息（可选） */
  message?: string;
  /** 操作按钮列表 */
  actions: ActionButton[];
  /** 取消按钮文字（可选，默认"取消"）*/
  cancelText?: string;
  /** 取消回调（可选）*/
  onCancel?: () => void;
}

/**
 * 操作选择弹窗组件
 * 支持多个带副标题的操作按钮
 */
@CustomDialog
export struct ActionDialog {
  controller: CustomDialogController;
  config: ActionDialogConfig = {
    title: '',
    actions: []
  };
  
  build() {
    Column() {
      // 标题
      Text(this.config.title)
        .fontSize(AppSizes.FontTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.TextPrimary)
        .margin({ bottom: this.config.message ? AppSpacing.Small : AppSpacing.Medium })
      
      // 消息内容（可选）
      if (this.config.message) {
        Text(this.config.message)
          .fontSize(AppSizes.FontBody)
          .fontColor(AppColors.TextSecondary)
          .textAlign(TextAlign.Center)
          .margin({ bottom: AppSpacing.Medium })
      }
      
      // 操作按钮列表
      ForEach(this.config.actions, (action: ActionButton) => {
        Button() {
          Column() {
            Text(action.text)
              .fontSize(AppSizes.FontBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(action.color ?? AppColors.TextPrimary)
            if (action.subtitle) {
              Text(action.subtitle)
                .fontSize(AppSizes.FontCaption)
                .fontColor(AppColors.TextTertiary)
                .margin({ top: 2 })
            }
          }
        }
        .width('100%')
        .height(action.subtitle ? 56 : 48)
        .backgroundColor(action.backgroundColor ?? AppColors.Surface)
        .borderRadius(12)
        .margin({ bottom: AppSpacing.Small })
        .onClick(() => {
          action.onClick();
          this.controller.close();
        })
      })
      
      // 取消按钮
      Button(this.config.cancelText ?? '取消')
        .width('100%')
        .height(48)
        .fontSize(AppSizes.FontBody)
        .fontColor(AppColors.TextSecondary)
        .backgroundColor(AppColors.Surface)
        .borderRadius(12)
        .margin({ top: AppSpacing.Small })
        .onClick(() => {
          if (this.config.onCancel) {
            this.config.onCancel();
          }
          this.controller.close();
        })
    }
    .width('100%')
    .padding(AppSpacing.Large)
    .backgroundColor(AppColors.Background)
    .borderRadius(16)
  }
}
