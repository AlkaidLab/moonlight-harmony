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
 * libmoonlight_nativelib.so 的类型声明。
 *
 * 该 NAPI 库导出约 100 个函数（注册表见 nativelib/src/main/cpp/napi_init.cpp、
 * gamepad_napi.cpp、usb_ddk_poller.cpp、usbip_napi.cpp 等），全部是 C FFI
 * 边界函数。业务侧已按需定义局部接口（如 StreamingSession 的 NativeModule）
 * 并对本模块做类型断言，因此这里统一声明为宽松的 any，仅用于让 ArkTS
 * 编译器解析对该模块的导入、消除 "module not verified" 警告，不参与
 * 类型检查。新增 NAPI 导出时无需同步本文件。
 */
const nativeLib: any;
export default nativeLib;
