/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * USB Helper - 内核驱动重绑定
 *
 * 当应用通过 claimInterface(force=true) 独占 USB 设备后，
 * 内核 HID 驱动会被解绑。releaseInterface() + closePipe()
 * 不会自动重绑定内核驱动。此模块提供 native ioctl 接口
 * 来显式通知内核重新绑定接口驱动。
 */

#ifndef USB_HELPER_H
#define USB_HELPER_H

#include <napi/native_api.h>

/**
 * 初始化 USB Helper NAPI 接口
 */
void UsbHelper_Init(napi_env env, napi_value exports);

/**
 * NAPI: reattachKernelDriver(fd: number, interfaceNumber: number): number
 * 
 * 通过 ioctl(USBDEVFS_IOCTL + USBDEVFS_CONNECT) 通知内核
 * 重新绑定指定接口的默认驱动（通常是 HID 驱动）。
 * 
 * @param fd USB 设备文件描述符（通过 usbManager.getFileDescriptor() 获取）
 * @param interfaceNumber 需要重绑定驱动的接口编号
 * @return 0 表示成功，负值表示失败
 */
napi_value UsbHelper_ReattachKernelDriver(napi_env env, napi_callback_info info);

#endif // USB_HELPER_H
