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
 * 鼠标事件监听器
 *
 * 使用 OH_Input_AddMouseEventMonitor 在系统输入管线层级监听鼠标事件，
 * 绕过 ArkUI 渲染帧率限制（不触摸时 ~30Hz），以硬件原始轮询率接收鼠标事件，
 * 并直接调用 moonlight-common-c 的输入 API 发送给远端 PC。
 * Monitor 不消费事件，触摸和滚轮事件完全不受影响。
 *
 * 需要权限: ohos.permission.INPUT_MONITORING
 */

#ifndef MOUSE_INTERCEPTOR_H
#define MOUSE_INTERCEPTOR_H

#include <napi/native_api.h>

#ifdef __cplusplus
extern "C" {
#endif

napi_value MouseInterceptor_Init(napi_env env, napi_value exports);

#ifdef __cplusplus
}
#endif

#endif // MOUSE_INTERCEPTOR_H
