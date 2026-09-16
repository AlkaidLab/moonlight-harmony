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
 * 页面路由参数（Navigation 迁移）。
 *
 * ArkTS 禁止未类型化对象字面量（arkts-no-untyped-obj-literals），
 * 路由跳转的参数字面量必须 cast 到这里声明的接口：
 *   AppNav.push('StreamPage', { ... } as StreamPageParams);
 */

/**
 * route_map.json 注册的路由名。AppNav.push 的参数类型收窄到此联合类型，
 * 拼写错误在编译期报错，而不是运行时路由静默失败。
 */
export type RouteName =
  | 'PcListPageV2'
  | 'AppListPageV2'
  | 'StreamPage'
  | 'HostWebUiPage'
  | 'AddPcPageV2'
  | 'SettingsPageV2'
  | 'ControllerTestPage';

/** AppListPageV2（应用列表） */
export interface AppListPageParams {
  computerId: string;
}

/** HostWebUiPage（主机 Web UI） */
export interface HostWebUiPageParams {
  computerId: string;
}

/** StreamPage（串流页） */
export interface StreamPageParams {
  computerId: string;
  appId: number;
  appName?: string;
  cmdList?: string;       // JSON 字符串格式的超级指令列表
  resume?: boolean;       // 是否恢复已运行的游戏
  displayGuid?: string;   // 指定的显示器 GUID
  useVdd?: boolean;       // 是否使用虚拟显示器
  posterPath?: string;    // 应用本地海报路径，连接中遮罩背景
}

/** 将超级指令列表序列化为路由参数（空列表 → undefined），StreamPage 侧负责反序列化 */
export function serializeCmdList<T>(cmdList?: T[]): string | undefined {
  return cmdList && cmdList.length > 0 ? JSON.stringify(cmdList) : undefined;
}
