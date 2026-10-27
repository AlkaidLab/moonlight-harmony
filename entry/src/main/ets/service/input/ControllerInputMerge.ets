/*
 * Moonlight for HarmonyOS
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

export interface ControllerInputState {
  buttonFlags: number;
  leftTrigger: number;
  rightTrigger: number;
  leftStickX: number;
  leftStickY: number;
  rightStickX: number;
  rightStickY: number;
}

/** 自定义按键作为附加来源，不能用自身的零值清空默认虚拟手柄/物理手柄。 */
export function mergeControllerInput(base: ControllerInputState, custom: ControllerInputState): ControllerInputState {
  return {
    buttonFlags: base.buttonFlags | custom.buttonFlags,
    leftTrigger: Math.max(base.leftTrigger, custom.leftTrigger),
    rightTrigger: Math.max(base.rightTrigger, custom.rightTrigger),
    leftStickX: custom.leftStickX !== 0 ? custom.leftStickX : base.leftStickX,
    leftStickY: custom.leftStickY !== 0 ? custom.leftStickY : base.leftStickY,
    rightStickX: custom.rightStickX !== 0 ? custom.rightStickX : base.rightStickX,
    rightStickY: custom.rightStickY !== 0 ? custom.rightStickY : base.rightStickY,
  };
}
