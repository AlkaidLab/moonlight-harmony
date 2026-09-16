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
 * 全局导航栈（Navigation 迁移）。
 *
 * 旧版基于 @ohos.router（官方已停止演进），现统一为 Navigation + 系统路由表：
 * Index 作为 Navigation 宿主绑定 AppNav.stack，其余页面经 route_map.json 注册，
 * 任何组件/service（包括非组件的 PcListActions）都可通过 AppNav 路由。
 *
 * 参数读取：目标页在 aboutToAppear 中用
 *   AppNav.stack.getParamByIndex(AppNav.stack.size() - 1) as XxxPageParams
 * 取本次跳转参数（push 时参数同步入栈，时机与旧 router.getParams() 一致）。
 *
 * NavPathStack 为 ArkUI 全局声明，无需 import。
 */
export class AppNav {
  static readonly stack: NavPathStack = new NavPathStack();

  /** 等价于旧 router.pushUrl({ url: 'pages/<name>', params }) */
  static push(name: string, param?: Object): void {
    AppNav.stack.pushPathByName(name, param);
  }

  /** 等价于旧 router.back() */
  static pop(): void {
    AppNav.stack.pop();
  }
}
