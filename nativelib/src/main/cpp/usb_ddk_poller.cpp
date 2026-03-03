/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * USB DDK Poller - 基于 HarmonyOS USB DDK 的高速轮询实现
 *
 * 核心机制：
 *   1. dlopen("libusb_ndk.z.so") 动态加载 DDK (避免硬依赖)
 *   2. OH_Usb_Init() → OH_Usb_GetDevices() → 匹配 VID/PID
 *   3. OH_Usb_ClaimInterface() → OH_Usb_CreateDeviceMemMap()
 *   4. pthread 循环调用 OH_Usb_SendPipeRequest() 阻塞读取 IN 端点
 *   5. 数据通过 napi_threadsafe_function 回调到 JS 线程
 *   6. 输出(init/rumble) 通过 SendPipeRequest() 在 JS 线程同步发送
 *
 * 性能优势：
 *   - SendPipeRequest 是纯同步内核调用，无 IPC 开销
 *   - pthread 直接等待内核事件，响应延迟 < 0.1ms
 *   - 理论轮询率可达 USB High Speed 上限 (1000Hz)
 */

#include "usb_ddk_poller.h"

#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <dlfcn.h>
#include <atomic>
#include <hilog/log.h>

#define LOG_TAG "USB-DDK-Poller"

// ============================================================
// USB DDK 类型定义 (手动定义，通过 dlopen 调用)
// ============================================================

#define USB_DDK_SUCCESS         0
#define USB_DDK_NO_PERM         201
#define USB_DDK_INVALID_PARAM   401
#define USB_DDK_MEMORY_ERROR    27400001
#define USB_DDK_INVALID_OP      27400002
#define USB_DDK_IO_FAILED       27400003
#define USB_DDK_TIMEOUT         27400004

struct UsbDeviceDescriptor {
    uint8_t bLength;
    uint8_t bDescriptorType;
    uint16_t bcdUSB;
    uint8_t bDeviceClass;
    uint8_t bDeviceSubClass;
    uint8_t bDeviceProtocol;
    uint8_t bMaxPacketSize0;
    uint16_t idVendor;
    uint16_t idProduct;
    uint16_t bcdDevice;
    uint8_t iManufacturer;
    uint8_t iProduct;
    uint8_t iSerialNumber;
    uint8_t bNumConfigurations;
} __attribute__((aligned(8)));

struct Usb_DeviceArray {
    uint64_t *deviceIds;
    uint32_t num;
};

struct UsbRequestPipe {
    uint64_t interfaceHandle;
    uint32_t timeout;
    uint8_t endpoint;
} __attribute__((aligned(8)));

struct UsbDeviceMemMap {
    uint8_t * const address;
    const size_t size;
    uint32_t offset;
    uint32_t bufferLength;
    uint32_t transferedLength;
};

// ============================================================
// DDK 函数指针
// ============================================================

typedef int32_t (*Fn_OH_Usb_Init)(void);
typedef void    (*Fn_OH_Usb_Release)(void);
typedef int32_t (*Fn_OH_Usb_GetDevices)(Usb_DeviceArray *devices);
typedef int32_t (*Fn_OH_Usb_GetDeviceDescriptor)(uint64_t deviceId, UsbDeviceDescriptor *desc);
typedef int32_t (*Fn_OH_Usb_ClaimInterface)(uint64_t deviceId, uint8_t interfaceIndex, uint64_t *interfaceHandle);
typedef int32_t (*Fn_OH_Usb_ReleaseInterface)(uint64_t interfaceHandle);
typedef int32_t (*Fn_OH_Usb_CreateDeviceMemMap)(uint64_t deviceId, size_t size, UsbDeviceMemMap **devMmap);
typedef void    (*Fn_OH_Usb_DestroyDeviceMemMap)(UsbDeviceMemMap *devMmap);
typedef int32_t (*Fn_OH_Usb_SendPipeRequest)(const UsbRequestPipe *pipe, UsbDeviceMemMap *devMmap);

// ============================================================
// 全局 DDK 状态
// ============================================================

static void *g_ddkLib = nullptr;
static bool g_ddkLoaded = false;
static bool g_ddkInited = false;

static Fn_OH_Usb_Init              fn_Init = nullptr;
static Fn_OH_Usb_Release           fn_Release = nullptr;
static Fn_OH_Usb_GetDevices        fn_GetDevices = nullptr;
static Fn_OH_Usb_GetDeviceDescriptor fn_GetDeviceDescriptor = nullptr;
static Fn_OH_Usb_ClaimInterface    fn_ClaimInterface = nullptr;
static Fn_OH_Usb_ReleaseInterface  fn_ReleaseInterface = nullptr;
static Fn_OH_Usb_CreateDeviceMemMap fn_CreateDeviceMemMap = nullptr;
static Fn_OH_Usb_DestroyDeviceMemMap fn_DestroyDeviceMemMap = nullptr;
static Fn_OH_Usb_SendPipeRequest   fn_SendPipeRequest = nullptr;

// ============================================================
// Poller 上下文
// ============================================================

#define DDK_MAX_POLLERS 4

struct DdkPollerContext {
    // DDK 资源
    uint64_t deviceId;
    uint64_t interfaceHandle;
    uint8_t inEndpoint;
    uint8_t outEndpoint;
    uint32_t maxPacketSize;
    uint32_t timeoutMs;

    UsbDeviceMemMap *inMemMap;   // 输入 (轮询线程专用)
    UsbDeviceMemMap *outMemMap;  // 输出 (JS 线程专用)

    // 线程控制
    std::atomic<bool> running;
    pthread_t thread;
    bool threadCreated;
    bool interfaceClaimed;

    // JS 回调
    napi_threadsafe_function tsfn;      // 数据回调
    napi_threadsafe_function errorTsfn; // 错误回调

    // 忽略断开信号 (对应用户设置 "忽略手柄断开")
    std::atomic<bool> ignoreDisconnect;

    // 统计
    std::atomic<uint64_t> totalReads;
    std::atomic<uint64_t> totalBytes;
};

static DdkPollerContext g_ddkPollers[DDK_MAX_POLLERS];
static pthread_mutex_t g_ddkMutex = PTHREAD_MUTEX_INITIALIZER;
static bool g_ddkPoolInited = false;

// ============================================================
// 回调数据
// ============================================================

struct DdkCallbackData {
    uint8_t *data;
    int length;
    int pollerId;
};

struct DdkErrorData {
    int errorCode;
    int pollerId;
};

// ============================================================
// 辅助函数
// ============================================================

static const char *ddkErrStr(int32_t code) {
    switch (code) {
        case USB_DDK_SUCCESS:       return "SUCCESS";
        case USB_DDK_NO_PERM:       return "NO_PERM";
        case USB_DDK_INVALID_PARAM: return "INVALID_PARAM";
        case USB_DDK_MEMORY_ERROR:  return "MEMORY_ERROR";
        case USB_DDK_INVALID_OP:    return "INVALID_OP";
        case USB_DDK_IO_FAILED:     return "IO_FAILED";
        case USB_DDK_TIMEOUT:       return "TIMEOUT";
        default:                    return "UNKNOWN";
    }
}

static void initPollerPool() {
    if (g_ddkPoolInited) return;
    memset(g_ddkPollers, 0, sizeof(g_ddkPollers));
    for (int i = 0; i < DDK_MAX_POLLERS; i++) {
        g_ddkPollers[i].running.store(false);
        g_ddkPollers[i].threadCreated = false;
        g_ddkPollers[i].interfaceClaimed = false;
        g_ddkPollers[i].inMemMap = nullptr;
        g_ddkPollers[i].outMemMap = nullptr;
        g_ddkPollers[i].tsfn = nullptr;
        g_ddkPollers[i].errorTsfn = nullptr;
        g_ddkPollers[i].ignoreDisconnect.store(false);
    }
    g_ddkPoolInited = true;
}

static int allocatePoller() {
    for (int i = 0; i < DDK_MAX_POLLERS; i++) {
        if (!g_ddkPollers[i].running.load() && !g_ddkPollers[i].threadCreated) {
            return i;
        }
    }
    return -1;
}

static bool loadDdkLibrary() {
    if (g_ddkLoaded) return true;

    g_ddkLib = dlopen("libusb_ndk.z.so", RTLD_LAZY);
    if (!g_ddkLib) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] dlopen 失败: %{public}s", LOG_TAG, dlerror());
        return false;
    }

    fn_Init              = (Fn_OH_Usb_Init)dlsym(g_ddkLib, "OH_Usb_Init");
    fn_Release           = (Fn_OH_Usb_Release)dlsym(g_ddkLib, "OH_Usb_Release");
    fn_GetDevices        = (Fn_OH_Usb_GetDevices)dlsym(g_ddkLib, "OH_Usb_GetDevices");
    fn_GetDeviceDescriptor = (Fn_OH_Usb_GetDeviceDescriptor)dlsym(g_ddkLib, "OH_Usb_GetDeviceDescriptor");
    fn_ClaimInterface    = (Fn_OH_Usb_ClaimInterface)dlsym(g_ddkLib, "OH_Usb_ClaimInterface");
    fn_ReleaseInterface  = (Fn_OH_Usb_ReleaseInterface)dlsym(g_ddkLib, "OH_Usb_ReleaseInterface");
    fn_CreateDeviceMemMap = (Fn_OH_Usb_CreateDeviceMemMap)dlsym(g_ddkLib, "OH_Usb_CreateDeviceMemMap");
    fn_DestroyDeviceMemMap = (Fn_OH_Usb_DestroyDeviceMemMap)dlsym(g_ddkLib, "OH_Usb_DestroyDeviceMemMap");
    fn_SendPipeRequest   = (Fn_OH_Usb_SendPipeRequest)dlsym(g_ddkLib, "OH_Usb_SendPipeRequest");

    if (!fn_Init || !fn_Release || !fn_ClaimInterface || !fn_ReleaseInterface ||
        !fn_CreateDeviceMemMap || !fn_DestroyDeviceMemMap || !fn_SendPipeRequest) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] 核心函数加载失败 (Init=%{public}s Release=%{public}s Claim=%{public}s "
                     "Release=%{public}s CreateMem=%{public}s DestroyMem=%{public}s SendPipe=%{public}s)",
                     LOG_TAG,
                     fn_Init ? "OK" : "MISS",
                     fn_Release ? "OK" : "MISS",
                     fn_ClaimInterface ? "OK" : "MISS",
                     fn_ReleaseInterface ? "OK" : "MISS",
                     fn_CreateDeviceMemMap ? "OK" : "MISS",
                     fn_DestroyDeviceMemMap ? "OK" : "MISS",
                     fn_SendPipeRequest ? "OK" : "MISS");
        dlclose(g_ddkLib);
        g_ddkLib = nullptr;
        return false;
    }

    // GetDevices 和 GetDeviceDescriptor 是 API 18，可选
    if (!fn_GetDevices) {
        OH_LOG_WARN(LOG_APP, "[%{public}s] OH_Usb_GetDevices 不可用 (需要 API 18+)", LOG_TAG);
    }
    if (!fn_GetDeviceDescriptor) {
        OH_LOG_WARN(LOG_APP, "[%{public}s] OH_Usb_GetDeviceDescriptor 不可用 (需要 API 10+)", LOG_TAG);
    }

    g_ddkLoaded = true;
    OH_LOG_INFO(LOG_APP, "[%{public}s] DDK 库加载成功", LOG_TAG);
    return true;
}

// ============================================================
// 线程安全回调 (JS 线程执行)
// ============================================================

static void ddkDataCallbackOnJs(napi_env env, napi_value js_callback, void *context, void *rawData) {
    if (!env || !js_callback || !rawData) {
        if (rawData) {
            DdkCallbackData *cbd = (DdkCallbackData *)rawData;
            free(cbd->data);
            free(cbd);
        }
        return;
    }

    DdkCallbackData *cbd = (DdkCallbackData *)rawData;

    // 创建 ArrayBuffer + Uint8Array
    void *bufferData = nullptr;
    napi_value arrayBuffer;
    if (napi_create_arraybuffer(env, cbd->length, &bufferData, &arrayBuffer) != napi_ok || !bufferData) {
        free(cbd->data);
        free(cbd);
        return;
    }
    memcpy(bufferData, cbd->data, cbd->length);

    napi_value uint8Array;
    if (napi_create_typedarray(env, napi_uint8_array, cbd->length, arrayBuffer, 0, &uint8Array) != napi_ok) {
        free(cbd->data);
        free(cbd);
        return;
    }

    napi_value pollerIdVal, lengthVal;
    napi_create_int32(env, cbd->pollerId, &pollerIdVal);
    napi_create_int32(env, cbd->length, &lengthVal);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_value argv[3] = { pollerIdVal, uint8Array, lengthVal };
    napi_call_function(env, undefined, js_callback, 3, argv, nullptr);

    free(cbd->data);
    free(cbd);
}

static void ddkErrorCallbackOnJs(napi_env env, napi_value js_callback, void *context, void *rawData) {
    if (!env || !js_callback || !rawData) {
        if (rawData) free(rawData);
        return;
    }

    DdkErrorData *ped = (DdkErrorData *)rawData;

    napi_value pollerIdVal, errorCodeVal;
    napi_create_int32(env, ped->pollerId, &pollerIdVal);
    napi_create_int32(env, ped->errorCode, &errorCodeVal);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_value argv[2] = { pollerIdVal, errorCodeVal };
    napi_call_function(env, undefined, js_callback, 2, argv, nullptr);

    free(ped);
}

// ============================================================
// 轮询线程
// ============================================================

static void *ddkPollThread(void *arg) {
    int pollerId = (int)(intptr_t)arg;
    DdkPollerContext *ctx = &g_ddkPollers[pollerId];

    OH_LOG_INFO(LOG_APP, "[%{public}s] 轮询线程启动: id=%{public}d, inEp=0x%{public}x, maxPkt=%{public}u, timeout=%{public}ums",
                LOG_TAG, pollerId, ctx->inEndpoint, ctx->maxPacketSize, ctx->timeoutMs);

    // 轮询率统计
    uint64_t statPollCount = 0;
    uint64_t statStartTime = 0;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    statStartTime = ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;

    UsbRequestPipe pipe;
    memset(&pipe, 0, sizeof(pipe));
    pipe.interfaceHandle = ctx->interfaceHandle;
    pipe.endpoint = ctx->inEndpoint;
    pipe.timeout = ctx->timeoutMs;

    while (ctx->running.load()) {
        // 设置 memmap 参数
        ctx->inMemMap->offset = 0;
        ctx->inMemMap->bufferLength = ctx->maxPacketSize;

        int32_t ret = fn_SendPipeRequest(&pipe, ctx->inMemMap);

        if (!ctx->running.load()) break;

        if (ret == USB_DDK_SUCCESS) {
            uint32_t len = ctx->inMemMap->transferedLength;
            if (len == 0) continue;  // 零长度 - 跳过

            statPollCount++;
            ctx->totalReads.fetch_add(1);
            ctx->totalBytes.fetch_add(len);

            // 分配回调数据
            DdkCallbackData *cbd = (DdkCallbackData *)malloc(sizeof(DdkCallbackData));
            if (cbd) {
                cbd->data = (uint8_t *)malloc(len);
                if (cbd->data) {
                    memcpy(cbd->data, ctx->inMemMap->address, len);
                    cbd->length = (int)len;
                    cbd->pollerId = pollerId;

                    napi_status st = napi_call_threadsafe_function(ctx->tsfn, cbd, napi_tsfn_nonblocking);
                    if (st != napi_ok) {
                        free(cbd->data);
                        free(cbd);
                    }
                } else {
                    free(cbd);
                }
            }

            // 统计日志 (每5秒)
            clock_gettime(CLOCK_MONOTONIC, &ts);
            uint64_t now = ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
            if (now - statStartTime >= 5000) {
                double rate = (double)statPollCount * 1000.0 / (double)(now - statStartTime);
                OH_LOG_INFO(LOG_APP, "[%{public}s] id=%{public}d 轮询率: %{public}.1f Hz (%{public}llu 次/%{public}.1f秒)",
                            LOG_TAG, pollerId, rate,
                            (unsigned long long)statPollCount,
                            (double)(now - statStartTime) / 1000.0);
                statPollCount = 0;
                statStartTime = now;
            }
        } else if (ret == USB_DDK_TIMEOUT) {
            // 超时 - 正常，继续
            continue;
        } else {
            // 错误
            OH_LOG_ERROR(LOG_APP, "[%{public}s] id=%{public}d SendPipeRequest 失败: %{public}d (%{public}s)",
                         LOG_TAG, pollerId, ret, ddkErrStr(ret));

            // 通知 JS 错误
            DdkErrorData *ped = (DdkErrorData *)malloc(sizeof(DdkErrorData));
            if (ped) {
                ped->errorCode = ret;
                ped->pollerId = pollerId;
                napi_status st = napi_call_threadsafe_function(ctx->errorTsfn, ped, napi_tsfn_nonblocking);
                if (st != napi_ok) free(ped);
            }

            // IO 错误 - 停止轮询（除非忽略断开信号）
            if (ret == USB_DDK_IO_FAILED || ret == USB_DDK_INVALID_OP) {
                if (ctx->ignoreDisconnect.load()) {
                    OH_LOG_WARN(LOG_APP, "[%{public}s] id=%{public}d 致命错误(%{public}s)但忽略断开信号已启用，50ms 后继续轮询",
                                LOG_TAG, pollerId, ddkErrStr(ret));
                    usleep(50 * 1000);  // 50ms
                    continue;
                }
                OH_LOG_ERROR(LOG_APP, "[%{public}s] id=%{public}d 致命错误，停止轮询", LOG_TAG, pollerId);
                break;
            }
        }
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] 轮询线程退出: id=%{public}d, reads=%{public}llu",
                LOG_TAG, pollerId,
                (unsigned long long)ctx->totalReads.load());

    ctx->running.store(false);
    return nullptr;
}

// ============================================================
// NAPI: init() → 加载库 + OH_Usb_Init
// ============================================================

static napi_value DdkPoller_Init(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);

    auto setField = [&](const char *name, int32_t val) {
        napi_value v;
        napi_create_int32(env, val, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setStr = [&](const char *name, const char *val) {
        napi_value v;
        napi_create_string_utf8(env, val, NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, result, name, v);
    };

    initPollerPool();

    // 加载 DDK
    if (!loadDdkLibrary()) {
        setField("code", -1);
        setStr("error", "DDK library load failed");
        return result;
    }

    // 初始化 DDK (如果还没初始化)
    if (!g_ddkInited) {
        int32_t initResult = fn_Init();
        OH_LOG_INFO(LOG_APP, "[%{public}s] OH_Usb_Init: %{public}d (%{public}s)",
                    LOG_TAG, initResult, ddkErrStr(initResult));
        if (initResult != USB_DDK_SUCCESS) {
            setField("code", initResult);
            setStr("error", ddkErrStr(initResult));
            return result;
        }
        g_ddkInited = true;
    }

    setField("code", 0);
    setStr("status", "OK");

    // 报告可选 API 可用性
    napi_value hasGetDevices;
    napi_get_boolean(env, fn_GetDevices != nullptr, &hasGetDevices);
    napi_set_named_property(env, result, "hasGetDevices", hasGetDevices);

    napi_value hasGetDesc;
    napi_get_boolean(env, fn_GetDeviceDescriptor != nullptr, &hasGetDesc);
    napi_set_named_property(env, result, "hasGetDeviceDescriptor", hasGetDesc);

    return result;
}

// ============================================================
// NAPI: findDevice(vid, pid) → 查找设备
// ============================================================

static napi_value DdkPoller_FindDevice(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t vid = 0, pid = 0;
    if (argc >= 2) {
        napi_get_value_int32(env, args[0], &vid);
        napi_get_value_int32(env, args[1], &pid);
    }

    napi_value result;
    napi_create_object(env, &result);

    auto setField = [&](const char *name, int64_t val) {
        napi_value v;
        napi_create_int64(env, val, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setStr = [&](const char *name, const char *val) {
        napi_value v;
        napi_create_string_utf8(env, val, NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setBool = [&](const char *name, bool val) {
        napi_value v;
        napi_get_boolean(env, val, &v);
        napi_set_named_property(env, result, name, v);
    };

    if (!g_ddkInited || !fn_GetDevices || !fn_GetDeviceDescriptor) {
        setBool("found", false);
        setStr("error", !g_ddkInited ? "DDK not initialized" :
                        !fn_GetDevices ? "GetDevices not available" :
                        "GetDeviceDescriptor not available");
        return result;
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] 查找设备: VID=0x%{public}x PID=0x%{public}x", LOG_TAG, vid, pid);

    // 获取设备列表
    Usb_DeviceArray devices;
    memset(&devices, 0, sizeof(devices));
    int32_t ret = fn_GetDevices(&devices);

    if (ret != USB_DDK_SUCCESS) {
        setBool("found", false);
        setField("ddkError", ret);
        setStr("error", ddkErrStr(ret));
        OH_LOG_ERROR(LOG_APP, "[%{public}s] GetDevices 失败: %{public}d", LOG_TAG, ret);
        return result;
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] 发现 %{public}u 个 USB 设备", LOG_TAG, devices.num);
    setField("deviceCount", (int64_t)devices.num);

    // 遍历匹配 VID/PID
    bool found = false;
    uint64_t matchedDeviceId = 0;

    for (uint32_t i = 0; i < devices.num; i++) {
        UsbDeviceDescriptor desc;
        memset(&desc, 0, sizeof(desc));
        ret = fn_GetDeviceDescriptor(devices.deviceIds[i], &desc);
        if (ret != USB_DDK_SUCCESS) {
            OH_LOG_WARN(LOG_APP, "[%{public}s] GetDeviceDescriptor[%{public}u] 失败: %{public}d",
                        LOG_TAG, i, ret);
            continue;
        }

        OH_LOG_INFO(LOG_APP, "[%{public}s] 设备[%{public}u] id=%{public}llu VID=0x%{public}x PID=0x%{public}x",
                    LOG_TAG, i, (unsigned long long)devices.deviceIds[i],
                    desc.idVendor, desc.idProduct);

        if (desc.idVendor == (uint16_t)vid && desc.idProduct == (uint16_t)pid) {
            found = true;
            matchedDeviceId = devices.deviceIds[i];
            OH_LOG_INFO(LOG_APP, "[%{public}s] 匹配成功! deviceId=%{public}llu",
                        LOG_TAG, (unsigned long long)matchedDeviceId);
            break;
        }
    }

    // 释放设备数组 (deviceIds 由 DDK 分配)
    if (devices.deviceIds) {
        free(devices.deviceIds);
    }

    setBool("found", found);
    if (found) {
        setField("deviceId", (int64_t)matchedDeviceId);
    }

    return result;
}

// ============================================================
// NAPI: startPoller(deviceId, ifaceIndex, inEndpoint, outEndpoint,
//                   maxPacketSize, onData, onError, timeoutMs)
//       → 声明接口 + 创建内存映射 + 启动轮询线程
//       返回 pollerId (-1 表示失败)
// ============================================================

static napi_value DdkPoller_StartPoller(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 7) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] startPoller 参数不足: %{public}zu", LOG_TAG, argc);
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }

    // 解析参数
    int64_t deviceId64 = 0;
    int32_t ifaceIndex = 0, inEp = 0, outEp = 0, maxPkt = 64, timeoutMs = 100;
    napi_get_value_int64(env, args[0], &deviceId64);
    napi_get_value_int32(env, args[1], &ifaceIndex);
    napi_get_value_int32(env, args[2], &inEp);
    napi_get_value_int32(env, args[3], &outEp);
    napi_get_value_int32(env, args[4], &maxPkt);
    // args[5] = onData callback
    // args[6] = onError callback
    if (argc >= 8) {
        napi_get_value_int32(env, args[7], &timeoutMs);
    }

    uint64_t deviceId = (uint64_t)deviceId64;

    OH_LOG_INFO(LOG_APP, "[%{public}s] startPoller: deviceId=%{public}llu iface=%{public}d inEp=0x%{public}x outEp=0x%{public}x maxPkt=%{public}d timeout=%{public}dms",
                LOG_TAG, (unsigned long long)deviceId, ifaceIndex, inEp, outEp, maxPkt, timeoutMs);

    if (!g_ddkInited) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] DDK 未初始化", LOG_TAG);
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }

    pthread_mutex_lock(&g_ddkMutex);

    int pollerId = allocatePoller();
    if (pollerId < 0) {
        pthread_mutex_unlock(&g_ddkMutex);
        OH_LOG_ERROR(LOG_APP, "[%{public}s] 无空闲 poller 槽", LOG_TAG);
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }

    DdkPollerContext *ctx = &g_ddkPollers[pollerId];
    memset(ctx, 0, sizeof(DdkPollerContext));
    ctx->running.store(false);

    // Step 1: 声明接口 (带重试，等待 usbManager 释放设备)
    int32_t ret = -1;
    const int MAX_CLAIM_ATTEMPTS = 5;
    for (int attempt = 0; attempt < MAX_CLAIM_ATTEMPTS; attempt++) {
        if (attempt > 0) {
            int delay_ms = 50 * (1 << (attempt - 1)); // 50, 100, 200, 400ms
            OH_LOG_INFO(LOG_APP, "[%{public}s] ClaimInterface 重试 %{public}d/%{public}d, 等待 %{public}dms...",
                        LOG_TAG, attempt + 1, MAX_CLAIM_ATTEMPTS, delay_ms);
            usleep(delay_ms * 1000);
        }
        ret = fn_ClaimInterface(deviceId, (uint8_t)ifaceIndex, &ctx->interfaceHandle);
        if (ret == USB_DDK_SUCCESS) {
            OH_LOG_INFO(LOG_APP, "[%{public}s] ClaimInterface 成功 (尝试 %{public}d/%{public}d)",
                        LOG_TAG, attempt + 1, MAX_CLAIM_ATTEMPTS);
            break;
        }
        OH_LOG_WARN(LOG_APP, "[%{public}s] ClaimInterface 尝试 %{public}d/%{public}d 失败: %{public}d (%{public}s)",
                    LOG_TAG, attempt + 1, MAX_CLAIM_ATTEMPTS, ret, ddkErrStr(ret));
    }
    if (ret != USB_DDK_SUCCESS) {
        pthread_mutex_unlock(&g_ddkMutex);
        OH_LOG_ERROR(LOG_APP, "[%{public}s] ClaimInterface 最终失败: %{public}d (%{public}s), 所有重试已用尽",
                     LOG_TAG, ret, ddkErrStr(ret));
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }
    ctx->interfaceClaimed = true;
    OH_LOG_INFO(LOG_APP, "[%{public}s] 接口已声明: handle=%{public}llu",
                LOG_TAG, (unsigned long long)ctx->interfaceHandle);

    // Step 2: 创建输入内存映射
    ret = fn_CreateDeviceMemMap(deviceId, (size_t)maxPkt, &ctx->inMemMap);
    if (ret != USB_DDK_SUCCESS || !ctx->inMemMap) {
        fn_ReleaseInterface(ctx->interfaceHandle);
        ctx->interfaceClaimed = false;
        pthread_mutex_unlock(&g_ddkMutex);
        OH_LOG_ERROR(LOG_APP, "[%{public}s] CreateDeviceMemMap(IN) 失败: %{public}d", LOG_TAG, ret);
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }

    // Step 3: 创建输出内存映射 (用于 sendOutput)
    if (outEp != 0) {
        // 输出缓冲区大小：64 字节足够大多数控制命令
        ret = fn_CreateDeviceMemMap(deviceId, 64, &ctx->outMemMap);
        if (ret != USB_DDK_SUCCESS || !ctx->outMemMap) {
            OH_LOG_ERROR(LOG_APP, "[%{public}s] CreateDeviceMemMap(OUT) 失败: %{public}d (%{public}s), DDK 整体回退",
                        LOG_TAG, ret, ddkErrStr(ret));
            ctx->outMemMap = nullptr;
            // 输出不可用 → 回退到 usbManager，保障振动等输出功能
            fn_DestroyDeviceMemMap(ctx->inMemMap);
            fn_ReleaseInterface(ctx->interfaceHandle);
            ctx->interfaceClaimed = false;
            ctx->inMemMap = nullptr;
            pthread_mutex_unlock(&g_ddkMutex);
            napi_value r;
            napi_create_int32(env, -1, &r);
            return r;
        } else {
            OH_LOG_INFO(LOG_APP, "[%{public}s] CreateDeviceMemMap(OUT) 成功: size=%{public}zu, address=%{public}p",
                        LOG_TAG, ctx->outMemMap->size, (void *)ctx->outMemMap->address);
        }
    } else {
        OH_LOG_INFO(LOG_APP, "[%{public}s] 无输出端点 (outEp=0), 跳过输出 memmap 创建", LOG_TAG);
    }

    // 保存配置
    ctx->deviceId = deviceId;
    ctx->inEndpoint = (uint8_t)inEp;
    ctx->outEndpoint = (uint8_t)outEp;
    ctx->maxPacketSize = (uint32_t)maxPkt;
    ctx->timeoutMs = (uint32_t)timeoutMs;
    ctx->totalReads.store(0);
    ctx->totalBytes.store(0);
    ctx->ignoreDisconnect.store(false);

    // Step 4: 创建 threadsafe functions
    napi_value dataResName;
    napi_create_string_utf8(env, "DdkPollerData", NAPI_AUTO_LENGTH, &dataResName);
    napi_status status = napi_create_threadsafe_function(
        env, args[5], nullptr, dataResName,
        64,   // max queue size (high for 1000Hz)
        1, nullptr, nullptr, nullptr,
        ddkDataCallbackOnJs, &ctx->tsfn
    );
    if (status != napi_ok) {
        if (ctx->outMemMap) fn_DestroyDeviceMemMap(ctx->outMemMap);
        fn_DestroyDeviceMemMap(ctx->inMemMap);
        fn_ReleaseInterface(ctx->interfaceHandle);
        ctx->interfaceClaimed = false;
        ctx->inMemMap = nullptr;
        ctx->outMemMap = nullptr;
        pthread_mutex_unlock(&g_ddkMutex);
        OH_LOG_ERROR(LOG_APP, "[%{public}s] 创建 data tsfn 失败", LOG_TAG);
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }

    napi_value errorResName;
    napi_create_string_utf8(env, "DdkPollerError", NAPI_AUTO_LENGTH, &errorResName);
    status = napi_create_threadsafe_function(
        env, args[6], nullptr, errorResName,
        8, 1, nullptr, nullptr, nullptr,
        ddkErrorCallbackOnJs, &ctx->errorTsfn
    );
    if (status != napi_ok) {
        napi_release_threadsafe_function(ctx->tsfn, napi_tsfn_abort);
        ctx->tsfn = nullptr;
        if (ctx->outMemMap) fn_DestroyDeviceMemMap(ctx->outMemMap);
        fn_DestroyDeviceMemMap(ctx->inMemMap);
        fn_ReleaseInterface(ctx->interfaceHandle);
        ctx->interfaceClaimed = false;
        ctx->inMemMap = nullptr;
        ctx->outMemMap = nullptr;
        pthread_mutex_unlock(&g_ddkMutex);
        OH_LOG_ERROR(LOG_APP, "[%{public}s] 创建 error tsfn 失败", LOG_TAG);
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }

    // Step 5: 启动轮询线程
    ctx->running.store(true);
    int pret = pthread_create(&ctx->thread, nullptr, ddkPollThread, (void *)(intptr_t)pollerId);
    if (pret != 0) {
        ctx->running.store(false);
        napi_release_threadsafe_function(ctx->tsfn, napi_tsfn_abort);
        napi_release_threadsafe_function(ctx->errorTsfn, napi_tsfn_abort);
        ctx->tsfn = nullptr;
        ctx->errorTsfn = nullptr;
        if (ctx->outMemMap) fn_DestroyDeviceMemMap(ctx->outMemMap);
        fn_DestroyDeviceMemMap(ctx->inMemMap);
        fn_ReleaseInterface(ctx->interfaceHandle);
        ctx->interfaceClaimed = false;
        ctx->inMemMap = nullptr;
        ctx->outMemMap = nullptr;
        pthread_mutex_unlock(&g_ddkMutex);
        OH_LOG_ERROR(LOG_APP, "[%{public}s] pthread_create 失败: %{public}d", LOG_TAG, pret);
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }

    ctx->threadCreated = true;
    pthread_mutex_unlock(&g_ddkMutex);

    OH_LOG_INFO(LOG_APP, "[%{public}s] Poller 启动成功: id=%{public}d, deviceId=%{public}llu, handle=%{public}llu",
                LOG_TAG, pollerId,
                (unsigned long long)deviceId,
                (unsigned long long)ctx->interfaceHandle);

    napi_value r;
    napi_create_int32(env, pollerId, &r);
    return r;
}

// ============================================================
// NAPI: stopPoller(pollerId) → 停止线程 + 释放资源
// ============================================================

static napi_value DdkPoller_StopPoller(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t pollerId = -1;
    if (argc >= 1) napi_get_value_int32(env, args[0], &pollerId);

    napi_value result;
    napi_create_int32(env, 0, &result);

    if (pollerId < 0 || pollerId >= DDK_MAX_POLLERS) {
        napi_create_int32(env, -1, &result);
        return result;
    }

    pthread_mutex_lock(&g_ddkMutex);
    DdkPollerContext *ctx = &g_ddkPollers[pollerId];

    if (!ctx->threadCreated) {
        pthread_mutex_unlock(&g_ddkMutex);
        napi_create_int32(env, -1, &result);
        return result;
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] 停止 Poller: id=%{public}d", LOG_TAG, pollerId);
    ctx->running.store(false);
    pthread_mutex_unlock(&g_ddkMutex);

    // 等待线程退出
    pthread_join(ctx->thread, nullptr);

    pthread_mutex_lock(&g_ddkMutex);

    // 释放 threadsafe functions
    if (ctx->tsfn) {
        napi_release_threadsafe_function(ctx->tsfn, napi_tsfn_release);
        ctx->tsfn = nullptr;
    }
    if (ctx->errorTsfn) {
        napi_release_threadsafe_function(ctx->errorTsfn, napi_tsfn_release);
        ctx->errorTsfn = nullptr;
    }

    // 释放内存映射
    if (ctx->outMemMap) {
        fn_DestroyDeviceMemMap(ctx->outMemMap);
        ctx->outMemMap = nullptr;
    }
    if (ctx->inMemMap) {
        fn_DestroyDeviceMemMap(ctx->inMemMap);
        ctx->inMemMap = nullptr;
    }

    // 释放接口
    if (ctx->interfaceClaimed) {
        int32_t ret = fn_ReleaseInterface(ctx->interfaceHandle);
        OH_LOG_INFO(LOG_APP, "[%{public}s] ReleaseInterface: %{public}d", LOG_TAG, ret);
        ctx->interfaceClaimed = false;
    }

    ctx->threadCreated = false;

    pthread_mutex_unlock(&g_ddkMutex);

    OH_LOG_INFO(LOG_APP, "[%{public}s] Poller 已停止: id=%{public}d, reads=%{public}llu",
                LOG_TAG, pollerId, (unsigned long long)ctx->totalReads.load());

    return result;
}

// ============================================================
// NAPI: sendOutput(pollerId, endpoint, data) → 同步发送输出
//       返回发送的字节数，-1 表示失败
// ============================================================

static napi_value DdkPoller_SendOutput(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t pollerId = -1;
    int32_t endpoint = 0;
    if (argc >= 2) {
        napi_get_value_int32(env, args[0], &pollerId);
        napi_get_value_int32(env, args[1], &endpoint);
    }

    napi_value result;
    napi_create_int32(env, -1, &result);

    if (pollerId < 0 || pollerId >= DDK_MAX_POLLERS || argc < 3) {
        return result;
    }

    DdkPollerContext *ctx = &g_ddkPollers[pollerId];
    if (!ctx->interfaceClaimed || !ctx->outMemMap) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] sendOutput: id=%{public}d 不可用 (claimed=%{public}d, outMemMap=%{public}s)",
                     LOG_TAG, pollerId, (int)ctx->interfaceClaimed,
                     ctx->outMemMap ? "有" : "无");
        return result;
    }

    // 获取输入数据
    uint8_t *inputData = nullptr;
    size_t inputLen = 0;

    bool isTypedArray = false;
    napi_is_typedarray(env, args[2], &isTypedArray);

    if (isTypedArray) {
        napi_typedarray_type type;
        size_t length;
        void *data;
        napi_get_typedarray_info(env, args[2], &type, &length, &data, nullptr, nullptr);
        inputData = (uint8_t *)data;
        inputLen = length;
    } else {
        // ArrayBuffer
        void *data;
        napi_get_arraybuffer_info(env, args[2], &data, &inputLen);
        inputData = (uint8_t *)data;
    }

    if (!inputData || inputLen == 0 || inputLen > ctx->outMemMap->size) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] sendOutput: 数据无效 (len=%{public}zu, maxSize=%{public}zu)",
                     LOG_TAG, inputLen, ctx->outMemMap->size);
        return result;
    }

    // 复制数据到输出 memmap
    memcpy(ctx->outMemMap->address, inputData, inputLen);
    ctx->outMemMap->offset = 0;
    ctx->outMemMap->bufferLength = (uint32_t)inputLen;

    // 发送
    UsbRequestPipe pipe;
    memset(&pipe, 0, sizeof(pipe));
    pipe.interfaceHandle = ctx->interfaceHandle;
    pipe.endpoint = (uint8_t)endpoint;
    pipe.timeout = 3000;  // 3 秒超时

    int32_t ret = fn_SendPipeRequest(&pipe, ctx->outMemMap);
    if (ret == USB_DDK_SUCCESS) {
        napi_create_int32(env, (int32_t)inputLen, &result);
    } else {
        OH_LOG_WARN(LOG_APP, "[%{public}s] sendOutput 失败: id=%{public}d ep=0x%{public}x len=%{public}zu ret=%{public}d (%{public}s)",
                    LOG_TAG, pollerId, endpoint, inputLen, ret, ddkErrStr(ret));
        napi_create_int32(env, -ret, &result);
    }

    return result;
}

// ============================================================
// NAPI: getStats(pollerId) → { totalReads, totalBytes }
// ============================================================

static napi_value DdkPoller_GetStats(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t pollerId = -1;
    if (argc >= 1) napi_get_value_int32(env, args[0], &pollerId);

    napi_value result;
    napi_create_object(env, &result);

    if (pollerId >= 0 && pollerId < DDK_MAX_POLLERS) {
        DdkPollerContext *ctx = &g_ddkPollers[pollerId];
        napi_value reads, bytes;
        napi_create_int64(env, (int64_t)ctx->totalReads.load(), &reads);
        napi_create_int64(env, (int64_t)ctx->totalBytes.load(), &bytes);
        napi_set_named_property(env, result, "totalReads", reads);
        napi_set_named_property(env, result, "totalBytes", bytes);
    }

    return result;
}

// ============================================================
// NAPI: setIgnoreDisconnect(pollerId, ignore) → 设置忽略断开信号
// ============================================================

static napi_value DdkPoller_SetIgnoreDisconnect(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t pollerId = -1;
    bool ignore = false;
    if (argc >= 1) napi_get_value_int32(env, args[0], &pollerId);
    if (argc >= 2) napi_get_value_bool(env, args[1], &ignore);

    if (pollerId >= 0 && pollerId < DDK_MAX_POLLERS) {
        g_ddkPollers[pollerId].ignoreDisconnect.store(ignore);
        OH_LOG_INFO(LOG_APP, "[%{public}s] id=%{public}d ignoreDisconnect=%{public}d",
                    LOG_TAG, pollerId, (int)ignore);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ============================================================
// NAPI: release() → 释放 DDK
// ============================================================

static napi_value DdkPoller_Release(napi_env env, napi_callback_info info) {
    if (g_ddkInited && fn_Release) {
        fn_Release();
        g_ddkInited = false;
        OH_LOG_INFO(LOG_APP, "[%{public}s] DDK 已释放", LOG_TAG);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ============================================================
// NAPI: makeDeviceId(busNum, devAddress) → 从 usbManager 设备信息构造 DDK deviceId
//
// 由于 OH_Usb_GetDevices() 对普通应用返回空列表，
// 我们通过 usbManager 的 busNum/devAddress 推算 DDK deviceId。
// 尝试多种编码方式，用 OH_Usb_GetDeviceDescriptor 验证。
// ============================================================

static napi_value DdkPoller_MakeDeviceId(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t busNum = 0, devAddr = 0;
    if (argc >= 2) {
        napi_get_value_int32(env, args[0], &busNum);
        napi_get_value_int32(env, args[1], &devAddr);
    }

    napi_value result;
    napi_create_object(env, &result);

    auto setBool = [&](const char *name, bool val) {
        napi_value v; napi_get_boolean(env, val, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setI64 = [&](const char *name, int64_t val) {
        napi_value v; napi_create_int64(env, val, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setStr = [&](const char *name, const char *val) {
        napi_value v; napi_create_string_utf8(env, val, NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, result, name, v);
    };

    if (!g_ddkInited) {
        setBool("found", false);
        setStr("error", "DDK not initialized");
        return result;
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] makeDeviceId: busNum=%{public}d devAddr=%{public}d",
                LOG_TAG, busNum, devAddr);

    // 已知编码: (busNum << 32) | devAddress
    // 保留备选编码以防不同设备/系统版本有差异
    uint64_t candidates[] = {
        ((uint64_t)busNum << 32) | (uint64_t)devAddr,           // A: bus << 32 | addr (已验证)
        ((uint64_t)busNum << 16) | (uint64_t)devAddr,           // B: bus << 16 | addr
        (uint64_t)(busNum * 1000 + devAddr),                    // C: bus*1000 + addr
        (uint64_t)((busNum << 8) | devAddr),                    // D: bus << 8 | addr
        (uint64_t)devAddr,                                      // E: 仅 addr
        (uint64_t)busNum,                                       // F: 仅 busNum
    };
    const char *candidateNames[] = { "A:bus<<32|addr", "B:bus<<16|addr", "C:bus*1000+addr",
                                     "D:bus<<8|addr", "E:addr_only", "F:bus_only" };
    int numCandidates = sizeof(candidates) / sizeof(candidates[0]);

    // 用 GetDeviceDescriptor 验证哪个 deviceId 有效
    if (fn_GetDeviceDescriptor) {
        for (int i = 0; i < numCandidates; i++) {
            UsbDeviceDescriptor desc;
            memset(&desc, 0, sizeof(desc));
            int32_t ret = fn_GetDeviceDescriptor(candidates[i], &desc);
            if (ret == USB_DDK_SUCCESS && desc.idVendor != 0) {
                setBool("found", true);
                setI64("deviceId", (int64_t)candidates[i]);
                setStr("encoding", candidateNames[i]);
                setI64("vid", desc.idVendor);
                setI64("pid", desc.idProduct);
                OH_LOG_INFO(LOG_APP, "[%{public}s] deviceId 匹配: encoding=%{public}s id=%{public}llu VID=0x%{public}x PID=0x%{public}x",
                            LOG_TAG, candidateNames[i],
                            (unsigned long long)candidates[i], desc.idVendor, desc.idProduct);
                return result;
            }
        }
    }

    // 回退: 尝试 ClaimInterface 验证
    OH_LOG_WARN(LOG_APP, "[%{public}s] GetDeviceDescriptor 未匹配，尝试 ClaimInterface 验证...", LOG_TAG);
    for (int i = 0; i < numCandidates; i++) {
        uint64_t handle = 0;
        int32_t ret = fn_ClaimInterface(candidates[i], 0, &handle);
        if (ret == USB_DDK_SUCCESS) {
            fn_ReleaseInterface(handle);
            setBool("found", true);
            setI64("deviceId", (int64_t)candidates[i]);
            setStr("encoding", candidateNames[i]);
            OH_LOG_INFO(LOG_APP, "[%{public}s] ClaimInterface 匹配: encoding=%{public}s", LOG_TAG, candidateNames[i]);
            return result;
        }
    }

    setBool("found", false);
    setStr("error", "all deviceId encodings failed");
    return result;
}

// ============================================================
// NAPI 注册
// ============================================================

void UsbDdkPoller_Init(napi_env env, napi_value exports) {
    napi_value obj;
    napi_create_object(env, &obj);

    napi_property_descriptor methods[] = {
        { "init",         nullptr, DdkPoller_Init,         nullptr, nullptr, nullptr, napi_default, nullptr },
        { "findDevice",   nullptr, DdkPoller_FindDevice,   nullptr, nullptr, nullptr, napi_default, nullptr },
        { "makeDeviceId", nullptr, DdkPoller_MakeDeviceId, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startPoller",  nullptr, DdkPoller_StartPoller,  nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopPoller",   nullptr, DdkPoller_StopPoller,   nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendOutput",   nullptr, DdkPoller_SendOutput,   nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getStats",     nullptr, DdkPoller_GetStats,     nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setIgnoreDisconnect", nullptr, DdkPoller_SetIgnoreDisconnect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "release",      nullptr, DdkPoller_Release,      nullptr, nullptr, nullptr, napi_default, nullptr },
    };

    napi_define_properties(env, obj, sizeof(methods) / sizeof(methods[0]), methods);
    napi_set_named_property(env, exports, "UsbDdkPoller", obj);

    OH_LOG_INFO(LOG_APP, "[%{public}s] DDK Poller NAPI 已注册", LOG_TAG);
}
