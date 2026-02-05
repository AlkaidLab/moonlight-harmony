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
 * 输入事件模型
 */
export enum InputType {
  MOUSE_MOVE = 0,
  MOUSE_BUTTON = 1,
  MOUSE_SCROLL = 2,
  KEYBOARD = 3,
  CONTROLLER_BUTTON = 4,
  CONTROLLER_AXIS = 5,
  TOUCH = 6
}

export interface InputEvent {
  type: InputType;
  timestamp: number;
}

export interface MouseMoveEvent extends InputEvent {
  type: InputType.MOUSE_MOVE;
  deltaX: number;
  deltaY: number;
}

export interface MouseButtonEvent extends InputEvent {
  type: InputType.MOUSE_BUTTON;
  button: number;  // 0=左键, 1=中键, 2=右键
  isPressed: boolean;
}

export interface MouseScrollEvent extends InputEvent {
  type: InputType.MOUSE_SCROLL;
  scrollX: number;
  scrollY: number;
}

export interface KeyboardEvent extends InputEvent {
  type: InputType.KEYBOARD;
  keyCode: number;
  isPressed: boolean;
  modifiers: number;  // Ctrl, Alt, Shift, Win
}

export interface ControllerButtonEvent extends InputEvent {
  type: InputType.CONTROLLER_BUTTON;
  controllerIndex: number;
  button: ControllerButton;
  isPressed: boolean;
}

export interface ControllerAxisEvent extends InputEvent {
  type: InputType.CONTROLLER_AXIS;
  controllerIndex: number;
  axis: ControllerAxis;
  value: number;  // -32768 to 32767
}

export interface TouchEvent extends InputEvent {
  type: InputType.TOUCH;
  pointerId: number;
  action: TouchAction;
  x: number;
  y: number;
  pressure: number;
}

export enum TouchAction {
  DOWN = 0,
  UP = 1,
  MOVE = 2,
  CANCEL = 3
}

export enum ControllerButton {
  A = 0x1000,
  B = 0x2000,
  X = 0x4000,
  Y = 0x8000,
  UP = 0x0001,
  DOWN = 0x0002,
  LEFT = 0x0004,
  RIGHT = 0x0008,
  LB = 0x0100,
  RB = 0x0200,
  LS = 0x0040,
  RS = 0x0080,
  START = 0x0010,
  BACK = 0x0020,
  SPECIAL = 0x0400,
  // 扩展按钮 (Sunshine 专用)
  PADDLE1 = 0x010000,
  PADDLE2 = 0x020000,
  PADDLE3 = 0x040000,
  PADDLE4 = 0x080000,
  TOUCHPAD = 0x100000,  // Sony 控制器的触摸板按钮
  MISC = 0x200000       // Share/Mic/Capture/Mute 按钮
}

export enum ControllerAxis {
  LEFT_X = 0,
  LEFT_Y = 1,
  RIGHT_X = 2,
  RIGHT_Y = 3,
  LEFT_TRIGGER = 4,
  RIGHT_TRIGGER = 5
}
