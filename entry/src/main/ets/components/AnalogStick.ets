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
 * 模拟摇杆组件
 * 支持 360 度方向输入和 L3/R3 点击
 */
import { ControllerAxis, ControllerAxisEvent, InputType, ControllerButton, ControllerButtonEvent, InputEvent } from '../model/InputEvent';

/**
 * 摇杆配置
 */
export interface AnalogStickConfig {
  /** 摇杆类型：左摇杆或右摇杆 */
  isLeftStick: boolean;
  /** 外圈半径 */
  outerRadius?: number;
  /** 内圈（摇杆头）半径 */
  innerRadius?: number;
  /** 死区比例 (0-1) */
  deadzone?: number;
  /** 透明度 */
  opacity?: number;
  /** 启用 L3/R3 点击 */
  enableClick?: boolean;
}

@Component
export struct AnalogStick {
  // 配置
  @Prop config: AnalogStickConfig = { isLeftStick: true };
  
  // 回调
  onAxisChange: (xAxis: ControllerAxis, xValue: number, yAxis: ControllerAxis, yValue: number) => void = () => {};
  onStickClick: (button: ControllerButton) => void = () => {};
  onInput: (event: InputEvent) => void = () => {};
  
  // 状态
  @State stickX: number = 0;  // -1 到 1
  @State stickY: number = 0;  // -1 到 1
  @State isPressed: boolean = false;
  @State showClickFeedback: boolean = false;
  
  // 配置值
  private stickOuterRadius: number = 60;
  private stickInnerRadius: number = 28;
  private stickDeadzone: number = 0.15;
  private stickOpacity: number = 0.8;
  
  // 双击检测
  private lastTapTime: number = 0;
  private doubleTapThreshold: number = 300; // ms
  
  aboutToAppear(): void {
    // 应用配置
    if (this.config.outerRadius) {
      this.stickOuterRadius = this.config.outerRadius;
    }
    if (this.config.innerRadius) {
      this.stickInnerRadius = this.config.innerRadius;
    }
    if (this.config.deadzone !== undefined) {
      this.stickDeadzone = this.config.deadzone;
    }
    if (this.config.opacity !== undefined) {
      this.stickOpacity = this.config.opacity;
    }
  }

  build() {
    Stack() {
      // 外圈背景
      Circle()
        .width(this.stickOuterRadius * 2)
        .height(this.stickOuterRadius * 2)
        .fill('transparent')
        .stroke('#FFFFFF')
        .strokeWidth(2)
        .strokeOpacity(0.3)
      
      // 死区指示圈
      Circle()
        .width(this.stickOuterRadius * 2 * this.stickDeadzone)
        .height(this.stickOuterRadius * 2 * this.stickDeadzone)
        .fill('transparent')
        .stroke('#FFFFFF')
        .strokeWidth(1)
        .strokeOpacity(0.15)
      
      // 摇杆头
      Circle()
        .width(this.stickInnerRadius * 2)
        .height(this.stickInnerRadius * 2)
        .fill(this.isPressed ? '#5090FF' : '#FFFFFF')
        .fillOpacity(this.isPressed ? 0.9 : 0.6)
        .shadow({
          radius: 8,
          color: this.isPressed ? '#5090FF' : '#000000',
          offsetX: 0,
          offsetY: 2
        })
        .translate({
          x: this.stickX * (this.stickOuterRadius - this.stickInnerRadius),
          y: this.stickY * (this.stickOuterRadius - this.stickInnerRadius)
        })
        .animation({
          duration: this.isPressed ? 0 : 100,
          curve: Curve.EaseOut
        })
      
      // 点击反馈
      if (this.showClickFeedback) {
        Circle()
          .width(this.stickInnerRadius * 2 + 16)
          .height(this.stickInnerRadius * 2 + 16)
          .fill('transparent')
          .stroke('#5090FF')
          .strokeWidth(3)
          .opacity(0.8)
          .translate({
            x: this.stickX * (this.stickOuterRadius - this.stickInnerRadius),
            y: this.stickY * (this.stickOuterRadius - this.stickInnerRadius)
          })
      }
      
      // L3/R3 标签
      Text(this.config.isLeftStick ? 'L' : 'R')
        .fontSize(12)
        .fontColor('#FFFFFF')
        .fontWeight(FontWeight.Bold)
        .opacity(0.4)
        .translate({
          x: this.stickX * (this.stickOuterRadius - this.stickInnerRadius),
          y: this.stickY * (this.stickOuterRadius - this.stickInnerRadius)
        })
    }
    .width(this.stickOuterRadius * 2)
    .height(this.stickOuterRadius * 2)
    .opacity(this.stickOpacity)
    .hitTestBehavior(HitTestMode.Block) // 阻止触摸事件穿透到下层（游戏画面）
    .onTouch((event) => this.handleTouch(event))
  }

  private handleTouch(event: TouchEvent): void {
    const touches = event.touches;
    if (touches.length === 0) return;
    
    const touch = touches[0];
    const centerX = this.stickOuterRadius;
    const centerY = this.stickOuterRadius;
    
    switch (event.type) {
      case TouchType.Down:
        this.isPressed = true;
        this.updateStickPosition(touch.x - centerX, touch.y - centerY);
        this.checkDoubleTap();
        break;
        
      case TouchType.Move:
        if (this.isPressed) {
          this.updateStickPosition(touch.x - centerX, touch.y - centerY);
        }
        break;
        
      case TouchType.Up:
      case TouchType.Cancel:
        this.isPressed = false;
        this.resetStick();
        break;
    }
  }
  
  private updateStickPosition(dx: number, dy: number): void {
    const maxDistance = this.stickOuterRadius - this.stickInnerRadius;
    
    // 计算距离和角度
    let distance = Math.sqrt(dx * dx + dy * dy);
    const angle = Math.atan2(dy, dx);
    
    // 限制在圆内
    if (distance > maxDistance) {
      distance = maxDistance;
    }
    
    // 归一化到 -1 到 1
    let normalizedX = (distance / maxDistance) * Math.cos(angle);
    let normalizedY = (distance / maxDistance) * Math.sin(angle);
    
    // 应用死区
    const magnitude = Math.sqrt(normalizedX * normalizedX + normalizedY * normalizedY);
    if (magnitude < this.stickDeadzone) {
      normalizedX = 0;
      normalizedY = 0;
    } else {
      // 重新映射死区外的值
      const remapScale = (magnitude - this.stickDeadzone) / (1 - this.stickDeadzone);
      const normalizedMagnitude = magnitude > 0 ? remapScale / magnitude : 0;
      normalizedX *= normalizedMagnitude;
      normalizedY *= normalizedMagnitude;
    }
    
    // 更新状态（用于显示，不应用死区）
    this.stickX = (distance / maxDistance) * Math.cos(angle);
    this.stickY = (distance / maxDistance) * Math.sin(angle);
    
    // 发送轴事件
    const xAxis = this.config.isLeftStick ? ControllerAxis.LEFT_X : ControllerAxis.RIGHT_X;
    const yAxis = this.config.isLeftStick ? ControllerAxis.LEFT_Y : ControllerAxis.RIGHT_Y;
    
    // 转换为 -32768 到 32767
    const xValue = Math.round(normalizedX * 32767);
    const yValue = Math.round(normalizedY * 32767);
    
    this.onAxisChange(xAxis, xValue, yAxis, yValue);
    
    // 发送 InputEvent
    const xEvent: ControllerAxisEvent = {
      type: InputType.CONTROLLER_AXIS,
      timestamp: Date.now(),
      controllerIndex: 0,
      axis: xAxis,
      value: xValue
    };
    const yEvent: ControllerAxisEvent = {
      type: InputType.CONTROLLER_AXIS,
      timestamp: Date.now(),
      controllerIndex: 0,
      axis: yAxis,
      value: yValue
    };
    this.onInput(xEvent);
    this.onInput(yEvent);
  }
  
  private resetStick(): void {
    this.stickX = 0;
    this.stickY = 0;
    
    // 发送归零事件
    const xAxis = this.config.isLeftStick ? ControllerAxis.LEFT_X : ControllerAxis.RIGHT_X;
    const yAxis = this.config.isLeftStick ? ControllerAxis.LEFT_Y : ControllerAxis.RIGHT_Y;
    
    this.onAxisChange(xAxis, 0, yAxis, 0);
    
    // 发送 InputEvent
    const xEvent: ControllerAxisEvent = {
      type: InputType.CONTROLLER_AXIS,
      timestamp: Date.now(),
      controllerIndex: 0,
      axis: xAxis,
      value: 0
    };
    const yEvent: ControllerAxisEvent = {
      type: InputType.CONTROLLER_AXIS,
      timestamp: Date.now(),
      controllerIndex: 0,
      axis: yAxis,
      value: 0
    };
    this.onInput(xEvent);
    this.onInput(yEvent);
  }
  
  private checkDoubleTap(): void {
    if (!this.config.enableClick) return;
    
    const now = Date.now();
    if (now - this.lastTapTime < this.doubleTapThreshold) {
      // 双击触发 L3/R3
      const button = this.config.isLeftStick ? ControllerButton.LS : ControllerButton.RS;
      this.onStickClick(button);
      
      // 发送按下和释放事件
      const pressEvent: ControllerButtonEvent = {
        type: InputType.CONTROLLER_BUTTON,
        timestamp: Date.now(),
        controllerIndex: 0,
        button: button,
        isPressed: true
      };
      this.onInput(pressEvent);
      
      // 短暂延迟后释放
      setTimeout(() => {
        const releaseEvent: ControllerButtonEvent = {
          type: InputType.CONTROLLER_BUTTON,
          timestamp: Date.now(),
          controllerIndex: 0,
          button: button,
          isPressed: false
        };
        this.onInput(releaseEvent);
      }, 50);
      
      // 显示点击反馈
      this.showClickFeedback = true;
      setTimeout(() => {
        this.showClickFeedback = false;
      }, 200);
      
      this.lastTapTime = 0;
    } else {
      this.lastTapTime = now;
    }
  }
}
