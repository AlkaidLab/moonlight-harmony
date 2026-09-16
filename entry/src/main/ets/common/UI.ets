/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License, version 3 only,
 * as published by the Free Software Foundation.
 */

import { UIContext } from '@kit.ArkUI';

/**
 * 全局 UIContext 载体。
 *
 * 全局 animateTo/px2vp 等无上下文 API 已废弃，官方要求改用 UIContext 作用域版本。
 * 组件内用 this.getUIContext()；service 等非组件代码通过 UI.get() 取 EntryAbility
 * 在窗口创建时注入的实例。
 */
export class UI {
  private static ctx: UIContext | undefined = undefined;

  /** EntryAbility 中调用：onWindowStageCreate 时尽早注入（部分设备此时抛错），
   *  loadContent 完成后重试。幂等，重复调用安全 */
  static init(ctx: UIContext): void {
    UI.ctx = ctx;
  }

  static isReady(): boolean {
    return UI.ctx !== undefined;
  }

  static get(): UIContext {
    if (UI.ctx === undefined) {
      throw new Error('UI context not initialized: UI.init() must be called in EntryAbility');
    }
    return UI.ctx;
  }
}
