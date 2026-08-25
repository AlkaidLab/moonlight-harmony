/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * HID DDK Probe - 验证 HID DDK (libhid.z.so) 能否在主进程访问 USB 手柄
 *
 * 探测链路（全程日志，只读不写，不接管输入）：
 *   1. dlopen("libhid.z.so") + dlsym 解析 OH_Hid_* host 侧 API (API 18+)
 *   2. OH_Hid_Init() → 权限/服务可用性
 *   3. OH_Hid_Open(deviceId, iface 0..4) → 打开 hidraw 通道
 *   4. OH_Hid_GetRawInfo / GetRawName / GetReportDescriptor → 设备与描述符
 *   5. OH_Hid_ReadTimeout() 限时读输入报文 → 频率与样例
 *   6. OH_Hid_Close() → OH_Hid_Release()
 */

#ifndef HID_DDK_PROBE_H
#define HID_DDK_PROBE_H

#include <napi/native_api.h>

/**
 * 初始化 HID DDK Probe NAPI 模块。
 *
 * 注册到 exports.HidDdkProbe 命名空间：
 *   - isAvailable(): boolean
 *   - probe(deviceId, readMs, onResult): void — 异步探测，结果经回调返回
 */
void HidDdkProbe_Init(napi_env env, napi_value exports);

/**
 * 初始化 HID DDK Reader NAPI 模块（常驻输入通道）。
 *
 * 注册到 exports.HidDdk 命名空间：
 *   - isAvailable(): boolean
 *   - startReader(deviceId, readTimeoutMs, onReport, onError): number — readerId(≥0)，
 *     同步打开设备，失败返回 -(HID_DDK 错误码) 供调用方回退。
 *     注意：打开（含 iface 0..4 扫描，每接口一次 HID 服务 IPC + 描述符读取）
 *     在调用线程同步执行，典型耗时几毫秒，设备响应慢时最坏可达数百毫秒。
 *     选择同步语义是为了让调用方（UsbDriverService）能确定性回退旧通道。
 *   - stopReader(readerId): void
 *   - writeOutput(readerId, data): number — OH_Hid_Write（震动等输出报告）
 *   - getReaderStats(readerId): object — iface/descLen/reports/reportsPerSec/lastError
 */
void HidDdkReader_Init(napi_env env, napi_value exports);

#endif // HID_DDK_PROBE_H
