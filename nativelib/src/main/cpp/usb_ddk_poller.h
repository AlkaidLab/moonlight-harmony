/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * USB DDK Poller - 基于 HarmonyOS USB DDK 的高速轮询器
 *
 * 使用 OH_Usb_SendPipeRequest() 同步 API 在独立 pthread 中轮询 USB 设备，
 * 绕过 ArkTS 事件循环和 usbManager IPC 瓶颈，实现接近硬件上限的轮询率。
 *
 * 替代路径：
 *   ioctl(USBDEVFS_BULK) → 被 HarmonyOS 安全沙箱阻止 (EACCES)
 *   usbManager.bulkTransfer → IPC 瓶颈，~130-150Hz 上限
 *   USB DDK → 同步原生 API，理论可达 1000Hz (High Speed)
 */

#ifndef USB_DDK_POLLER_H
#define USB_DDK_POLLER_H

#include <napi/native_api.h>

/**
 * 初始化 DDK Poller NAPI 模块。
 *
 * 注册到 exports.UsbDdkPoller 命名空间：
 *   - init(): number              — 初始化 DDK (dlopen + OH_Usb_Init)
 *   - findDevice(vid, pid): obj   — 查找匹配设备，返回 deviceId
 *   - startPoller(...)：number    — 声明接口 + 启动轮询线程，返回 pollerId
 *   - stopPoller(pollerId): void  — 停止轮询 + 释放资源
 *   - sendOutput(pollerId, endpoint, data): number — 发送输出数据
 *   - getStats(pollerId): obj     — 获取统计信息
 *   - release(): void             — 释放 DDK
 */
void UsbDdkPoller_Init(napi_env env, napi_value exports);

#endif // USB_DDK_POLLER_H
