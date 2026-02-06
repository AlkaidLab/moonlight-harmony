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
 * 按键事件拦截器
 *
 * 使用 OH_Input_AddKeyEventInterceptor 拦截被系统劫持的手柄按键
 * （如蓝牙手柄 Home/Mode 键），并通过 ThreadSafe 回调转发给 ArkTS 层
 *
 * 参考文档: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/interceptor-guidelines
 * 需要权限: ohos.permission.INTERCEPT_INPUT_EVENT
 */

#ifndef INPUT_INTERCEPTOR_H
#define INPUT_INTERCEPTOR_H

#include <napi/native_api.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 初始化输入拦截器 NAPI 接口
 * 注册 addKeyInterceptor / removeKeyInterceptor 方法到 InputInterceptor 对象
 */
napi_value InputInterceptor_Init(napi_env env, napi_value exports);

#ifdef __cplusplus
}
#endif

#endif // INPUT_INTERCEPTOR_H
