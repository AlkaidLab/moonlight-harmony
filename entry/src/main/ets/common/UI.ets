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

  /** EntryAbility.onWindowStageCreate 中调用，早于任何页面加载 */
  static init(ctx: UIContext): void {
    UI.ctx = ctx;
  }

  static get(): UIContext {
    if (UI.ctx === undefined) {
      throw new Error('UI context not initialized: UI.init() must be called in EntryAbility');
    }
    return UI.ctx;
  }
}
