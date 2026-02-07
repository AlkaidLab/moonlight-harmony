/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * USB Helper - 内核驱动重绑定实现
 *
 * 使用 Linux USBDEVFS ioctl 接口通知内核重新绑定 USB 接口驱动。
 * 这解决了 claimInterface(force=true) 解绑内核 HID 驱动后，
 * releaseInterface() 不会自动重绑定的问题。
 */

#include "usb_helper.h"

#include <sys/ioctl.h>
#include <errno.h>
#include <string.h>
#include <hilog/log.h>

#define LOG_TAG "USB-Helper"

// ============================================================
// Linux USB ioctl 定义
// 参考: linux/usbdevice_fs.h
// HarmonyOS NDK 可能不包含此头文件，手动定义所需常量
// ============================================================

// usbdevfs_ioctl 结构体 - 用于 USBDEVFS_IOCTL 调用
struct usbdevfs_ioctl_arg {
    int ifno;          // 接口编号
    int ioctl_code;    // 子 ioctl 代码
    void *data;        // 数据指针（CONNECT 时为 NULL）
};

// _IO(type, nr) = ((type) << 8) | (nr)
// _IOC(dir, type, nr, size) = ((dir) << 30) | ((type) << 8) | (nr) | ((size) << 16)
// dir: 0=none, 1=write, 2=read, 3=read|write

// USBDEVFS_CONNECT = _IO('U', 23)
// 通知内核重新绑定接口的默认驱动
#define USBDEVFS_CONNECT_NR 23

// USBDEVFS_IOCTL = _IOWR('U', 18, struct usbdevfs_ioctl)
// _IOWR: dir=3 (read|write), type='U'(0x55), nr=18
// size=sizeof(usbdevfs_ioctl_arg) 在 64-bit 上 = 16, 32-bit = 12
#define USBDEVFS_IOCTL_CMD  ((3u << 30) | (0x55u << 8) | 18u | ((unsigned int)sizeof(struct usbdevfs_ioctl_arg) << 16))

// USBDEVFS_CONNECT 的 ioctl_code 值
// _IO('U', 23) = (0x55 << 8) | 23 = 0x5517
#define USBDEVFS_CONNECT_CODE ((0x55u << 8) | USBDEVFS_CONNECT_NR)

// USBDEVFS_RESET = _IO('U', 20)
#define USBDEVFS_RESET_CMD ((0x55u << 8) | 20u)

/**
 * 通过 ioctl 通知内核重新绑定 USB 接口的默认驱动
 * 
 * 原理：USBDEVFS_IOCTL + USBDEVFS_CONNECT 告诉内核对指定接口
 * 重新执行驱动匹配和绑定流程（等价于 libusb_attach_kernel_driver）。
 *
 * @param fd USB 设备文件描述符
 * @param interfaceNumber 接口编号
 * @return 0=成功, 负值=失败（errno）
 */
static int reattach_kernel_driver(int fd, int interfaceNumber) {
    struct usbdevfs_ioctl_arg arg;
    memset(&arg, 0, sizeof(arg));
    arg.ifno = interfaceNumber;
    arg.ioctl_code = USBDEVFS_CONNECT_CODE;
    arg.data = NULL;

    OH_LOG_INFO(LOG_APP, "[%{public}s] 尝试重绑定内核驱动: fd=%{public}d, 接口=%{public}d",
                LOG_TAG, fd, interfaceNumber);

    int ret = ioctl(fd, USBDEVFS_IOCTL_CMD, &arg);
    if (ret < 0) {
        int err = errno;
        OH_LOG_WARN(LOG_APP, "[%{public}s] ioctl USBDEVFS_CONNECT 失败: fd=%{public}d, 接口=%{public}d, "
                    "errno=%{public}d (%{public}s)",
                    LOG_TAG, fd, interfaceNumber, err, strerror(err));
        return -err;
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] 内核驱动重绑定成功: fd=%{public}d, 接口=%{public}d, ret=%{public}d",
                LOG_TAG, fd, interfaceNumber, ret);
    return 0;
}

/**
 * 通过 ioctl 重置 USB 设备（如果 CONNECT 失败可以尝试）
 *
 * @param fd USB 设备文件描述符
 * @return 0=成功, 负值=失败（errno）
 */
static int reset_usb_device(int fd) {
    OH_LOG_INFO(LOG_APP, "[%{public}s] 尝试 USB 设备重置: fd=%{public}d", LOG_TAG, fd);

    int ret = ioctl(fd, USBDEVFS_RESET_CMD, NULL);
    if (ret < 0) {
        int err = errno;
        OH_LOG_WARN(LOG_APP, "[%{public}s] ioctl USBDEVFS_RESET 失败: fd=%{public}d, errno=%{public}d (%{public}s)",
                    LOG_TAG, fd, err, strerror(err));
        return -err;
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] USB 设备重置成功: fd=%{public}d", LOG_TAG, fd);
    return 0;
}

// ============================================================
// NAPI 接口
// ============================================================

/**
 * NAPI: UsbHelper.reattachKernelDriver(fd: number, interfaceNumber: number): number
 */
napi_value UsbHelper_ReattachKernelDriver(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] reattachKernelDriver 参数不足", LOG_TAG);
        napi_value result;
        napi_create_int32(env, -1, &result);
        return result;
    }

    int32_t fd = -1;
    int32_t interfaceNumber = 0;
    napi_get_value_int32(env, args[0], &fd);
    napi_get_value_int32(env, args[1], &interfaceNumber);

    int ret = reattach_kernel_driver(fd, interfaceNumber);

    // 如果 CONNECT 失败，尝试 RESET 作为后备方案
    if (ret < 0) {
        OH_LOG_WARN(LOG_APP, "[%{public}s] CONNECT 失败 (ret=%{public}d)，尝试 RESET 后备方案",
                    LOG_TAG, ret);
        ret = reset_usb_device(fd);
        if (ret == 0) {
            // RESET 成功，用特殊返回值 1 表示是通过 RESET 恢复的
            napi_value result;
            napi_create_int32(env, 1, &result);
            return result;
        }
    }

    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/**
 * 初始化 USB Helper NAPI 接口
 * 在 exports 上创建 UsbHelper 对象
 */
void UsbHelper_Init(napi_env env, napi_value exports) {
    napi_value usbHelperObj;
    napi_create_object(env, &usbHelperObj);

    napi_property_descriptor methods[] = {
        { "reattachKernelDriver", nullptr, UsbHelper_ReattachKernelDriver,
          nullptr, nullptr, nullptr, napi_default, nullptr },
    };

    napi_define_properties(env, usbHelperObj,
                           sizeof(methods) / sizeof(methods[0]), methods);

    napi_set_named_property(env, exports, "UsbHelper", usbHelperObj);

    OH_LOG_INFO(LOG_APP, "[%{public}s] USB Helper NAPI 初始化完成", LOG_TAG);
}
