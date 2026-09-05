/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * HID DDK Probe - 见 hid_ddk_probe.h
 *
 * 不直接链接 libhid.z.so（避免对 API 18 SDK 的硬依赖），
 * 通过 dlopen + dlsym 调用，类型定义与官方 <hid/hid_ddk_types.h> 保持一致。
 */

#include "hid_ddk_probe.h"

#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <atomic>
#include <cstddef>
#include <hilog/log.h>

#define LOG_TAG "HID-DDK-Probe"

// ============================================================
// HID DDK 类型与常量 (官方 hid_ddk_types.h 布局, ABI 自 18 起稳定)
// ============================================================

struct Hid_DeviceHandle;  // 不透明句柄

typedef struct Hid_RawDevInfo {
    uint32_t busType;
    uint16_t vendor;
    uint16_t product;
} Hid_RawDevInfo;

#define HID_DDK_SUCCESS          0
#define HID_DDK_NO_PERM          201
#define HID_DDK_INVALID_PARAMETER 401
#define HID_DDK_FAILURE          27300001
#define HID_DDK_NULL_PTR         27300002
#define HID_DDK_INVALID_OPERATION 27300003
#define HID_DDK_TIMEOUT          27300004
#define HID_DDK_INIT_ERROR       27300005
#define HID_DDK_SERVICE_ERROR    27300006
#define HID_DDK_MEMORY_ERROR     27300007
#define HID_DDK_IO_ERROR         27300008
#define HID_DDK_DEVICE_NOT_FOUND 27300009

#define PROBE_DESC_MAX 1024
#define PROBE_SAMPLE_COUNT 3
#define PROBE_SAMPLE_MAX 64
#define PROBE_IFACE_MAX 4

typedef int32_t (*Fn_OH_Hid_Init)(void);
typedef int32_t (*Fn_OH_Hid_Release)(void);
typedef int32_t (*Fn_OH_Hid_Open)(uint64_t deviceId, uint8_t interfaceIndex, Hid_DeviceHandle **dev);
typedef int32_t (*Fn_OH_Hid_Close)(Hid_DeviceHandle **dev);
typedef int32_t (*Fn_OH_Hid_GetRawInfo)(Hid_DeviceHandle *dev, Hid_RawDevInfo *rawDevInfo);
typedef int32_t (*Fn_OH_Hid_GetRawName)(Hid_DeviceHandle *dev, char *data, uint32_t bufSize);
typedef int32_t (*Fn_OH_Hid_GetReportDescriptor)(Hid_DeviceHandle *dev, uint8_t *buf, uint32_t bufSize, uint32_t *bytesRead);
typedef int32_t (*Fn_OH_Hid_ReadTimeout)(Hid_DeviceHandle *dev, uint8_t *data, uint32_t bufSize, int timeout, uint32_t *bytesRead);
typedef int32_t (*Fn_OH_Hid_Write)(Hid_DeviceHandle *dev, uint8_t *data, uint32_t length, uint32_t *bytesWritten);

static void *g_hidLib = nullptr;
static bool g_hidLoaded = false;
static Fn_OH_Hid_Init              fn_HidInit = nullptr;
static Fn_OH_Hid_Release           fn_HidRelease = nullptr;
static Fn_OH_Hid_Open              fn_HidOpen = nullptr;
static Fn_OH_Hid_Close             fn_HidClose = nullptr;
static Fn_OH_Hid_GetRawInfo        fn_HidGetRawInfo = nullptr;
static Fn_OH_Hid_GetRawName        fn_HidGetRawName = nullptr;
static Fn_OH_Hid_GetReportDescriptor fn_HidGetDesc = nullptr;
static Fn_OH_Hid_ReadTimeout       fn_HidReadTimeout = nullptr;
static Fn_OH_Hid_Write             fn_HidWrite = nullptr;

static const char *hidErrStr(int32_t code) {
    switch (code) {
        case HID_DDK_SUCCESS:           return "SUCCESS";
        case HID_DDK_NO_PERM:           return "NO_PERM";
        case HID_DDK_INVALID_PARAMETER: return "INVALID_PARAMETER";
        case HID_DDK_FAILURE:           return "FAILURE";
        case HID_DDK_NULL_PTR:          return "NULL_PTR";
        case HID_DDK_INVALID_OPERATION: return "INVALID_OPERATION";
        case HID_DDK_TIMEOUT:           return "TIMEOUT";
        case HID_DDK_INIT_ERROR:        return "INIT_ERROR";
        case HID_DDK_SERVICE_ERROR:     return "SERVICE_ERROR";
        case HID_DDK_MEMORY_ERROR:      return "MEMORY_ERROR";
        case HID_DDK_IO_ERROR:          return "IO_ERROR";
        case HID_DDK_DEVICE_NOT_FOUND:  return "DEVICE_NOT_FOUND";
        default:                        return "UNKNOWN";
    }
}

static bool loadHidLibrary() {
    if (g_hidLoaded) return true;

    g_hidLib = dlopen("libhid.z.so", RTLD_LAZY);
    if (!g_hidLib) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] dlopen libhid.z.so 失败: %{public}s", LOG_TAG, dlerror());
        return false;
    }

    fn_HidInit     = (Fn_OH_Hid_Init)dlsym(g_hidLib, "OH_Hid_Init");
    fn_HidRelease  = (Fn_OH_Hid_Release)dlsym(g_hidLib, "OH_Hid_Release");
    fn_HidOpen     = (Fn_OH_Hid_Open)dlsym(g_hidLib, "OH_Hid_Open");
    fn_HidClose    = (Fn_OH_Hid_Close)dlsym(g_hidLib, "OH_Hid_Close");
    fn_HidGetRawInfo = (Fn_OH_Hid_GetRawInfo)dlsym(g_hidLib, "OH_Hid_GetRawInfo");
    fn_HidGetRawName = (Fn_OH_Hid_GetRawName)dlsym(g_hidLib, "OH_Hid_GetRawName");
    fn_HidGetDesc  = (Fn_OH_Hid_GetReportDescriptor)dlsym(g_hidLib, "OH_Hid_GetReportDescriptor");
    fn_HidReadTimeout = (Fn_OH_Hid_ReadTimeout)dlsym(g_hidLib, "OH_Hid_ReadTimeout");
    fn_HidWrite   = (Fn_OH_Hid_Write)dlsym(g_hidLib, "OH_Hid_Write");

    if (!fn_HidInit || !fn_HidOpen || !fn_HidClose || !fn_HidReadTimeout) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] 核心 OH_Hid_* 符号缺失 (系统低于 API 18?): "
                     "Init=%{public}s Open=%{public}s Close=%{public}s Read=%{public}s",
                     LOG_TAG,
                     fn_HidInit ? "OK" : "MISS", fn_HidOpen ? "OK" : "MISS",
                     fn_HidClose ? "OK" : "MISS", fn_HidReadTimeout ? "OK" : "MISS");
        return false;
    }

    g_hidLoaded = true;
    OH_LOG_INFO(LOG_APP, "[%{public}s] libhid.z.so 加载成功 (RawInfo=%{public}s RawName=%{public}s GetDesc=%{public}s Write=%{public}s)",
                LOG_TAG, fn_HidGetRawInfo ? "OK" : "MISS",
                fn_HidGetRawName ? "OK" : "MISS", fn_HidGetDesc ? "OK" : "MISS",
                fn_HidWrite ? "OK" : "MISS");
    return true;
}

// ============================================================
// OH_Hid_Init/Release 引用计数（probe 与常驻 reader 共享，
// 避免探测结束时 Release 拆掉 reader 正在使用的 DDK 连接）
// ============================================================

static pthread_mutex_t g_hidInitRefMutex = PTHREAD_MUTEX_INITIALIZER;
static int g_hidInitRefCount = 0;

static bool hidInitRef() {
    pthread_mutex_lock(&g_hidInitRefMutex);
    if (g_hidInitRefCount == 0) {
        int32_t code = fn_HidInit();
        if (code != HID_DDK_SUCCESS) {
            pthread_mutex_unlock(&g_hidInitRefMutex);
            OH_LOG_ERROR(LOG_APP, "[%{public}s] OH_Hid_Init 失败: %{public}d (%{public}s)",
                         LOG_TAG, code, hidErrStr(code));
            return false;
        }
        OH_LOG_INFO(LOG_APP, "[%{public}s] OH_Hid_Init 成功 (引用计数 0→1)", LOG_TAG);
    }
    g_hidInitRefCount++;
    pthread_mutex_unlock(&g_hidInitRefMutex);
    return true;
}

static void hidReleaseRef() {
    pthread_mutex_lock(&g_hidInitRefMutex);
    if (g_hidInitRefCount > 0) {
        g_hidInitRefCount--;
        if (g_hidInitRefCount == 0) {
            int32_t code = fn_HidRelease();
            OH_LOG_INFO(LOG_APP, "[%{public}s] OH_Hid_Release (引用计数→0): %{public}d", LOG_TAG, code);
        }
    }
    pthread_mutex_unlock(&g_hidInitRefMutex);
}

// ============================================================
// 探测结果 (线程间传递, JS 线程构建返回对象后释放)
// ============================================================

struct HidProbeResult {
    bool available;      // 库与符号可用
    bool opened;         // 至少一个 interface 打开成功
    int32_t initCode;
    int32_t openCode;    // 最后一次 Open 的返回码
    int32_t descCode;    // GetReportDescriptor 返回码
    uint8_t openIface;
    uint16_t vid;
    uint16_t pid;
    uint32_t busType;
    char name[128];
    uint32_t descLen;
    uint8_t desc[PROBE_DESC_MAX];
    uint64_t reportCount;
    double reportsPerSec;
    uint32_t sampleCount;
    uint8_t samples[PROBE_SAMPLE_COUNT][PROBE_SAMPLE_MAX];
    uint32_t sampleLens[PROBE_SAMPLE_COUNT];
};

static void probeResultToJs(napi_env env, napi_value result, const HidProbeResult *r) {
    auto setBool = [&](const char *name, bool val) {
        napi_value v; napi_get_boolean(env, val, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setInt = [&](const char *name, int64_t val) {
        napi_value v; napi_create_int64(env, val, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setDouble = [&](const char *name, double val) {
        napi_value v; napi_create_double(env, val, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setStr = [&](const char *name, const char *val) {
        napi_value v; napi_create_string_utf8(env, val, NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, result, name, v);
    };

    setBool("available", r->available);
    setBool("opened", r->opened);
    setInt("initCode", r->initCode);
    setInt("openCode", r->openCode);
    setInt("descCode", r->descCode);
    setStr("initError", r->initCode == HID_DDK_SUCCESS ? "" : hidErrStr(r->initCode));
    setStr("openError", r->openCode == HID_DDK_SUCCESS ? "" : hidErrStr(r->openCode));

    if (r->opened) {
        setInt("interfaceIndex", r->openIface);
        setInt("vid", r->vid);
        setInt("pid", r->pid);
        setInt("busType", r->busType);
        setStr("name", r->name);
        setInt("descriptorLength", r->descLen);
        setInt("reportCount", (int64_t)r->reportCount);
        setDouble("reportsPerSec", r->reportsPerSec);

        // 描述符 Uint8Array
        if (r->descLen > 0) {
            void *bufData = nullptr;
            napi_value arrayBuffer;
            if (napi_create_arraybuffer(env, r->descLen, &bufData, &arrayBuffer) == napi_ok && bufData) {
                memcpy(bufData, r->desc, r->descLen);
                napi_value desc;
                if (napi_create_typedarray(env, napi_uint8_array, r->descLen, arrayBuffer, 0, &desc) == napi_ok) {
                    napi_set_named_property(env, result, "descriptor", desc);
                }
            }
        }

        // 样例报文
        napi_value samples;
        napi_create_array(env, &samples);
        for (uint32_t i = 0; i < r->sampleCount && i < PROBE_SAMPLE_COUNT; i++) {
            void *bufData = nullptr;
            napi_value arrayBuffer;
            if (napi_create_arraybuffer(env, r->sampleLens[i], &bufData, &arrayBuffer) == napi_ok && bufData) {
                memcpy(bufData, r->samples[i], r->sampleLens[i]);
                napi_value sample;
                if (napi_create_typedarray(env, napi_uint8_array, r->sampleLens[i], arrayBuffer, 0, &sample) == napi_ok) {
                    napi_set_element(env, samples, i, sample);
                }
            }
        }
        napi_set_named_property(env, result, "sampleReports", samples);
    }
}

static void probeResultOnJs(napi_env env, napi_value js_callback, void *context, void *rawData) {
    HidProbeResult *r = (HidProbeResult *)rawData;
    if (!env || !js_callback || !r) {
        free(r);
        return;
    }
    napi_value result;
    napi_create_object(env, &result);
    probeResultToJs(env, result, r);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, js_callback, 1, &result, nullptr);
    free(r);
}

// ============================================================
// 探测线程
// ============================================================

struct ProbeThreadArgs {
    uint64_t deviceId;
    uint32_t readMs;
    napi_threadsafe_function tsfn;
};

static void *probeThread(void *arg) {
    ProbeThreadArgs *args = (ProbeThreadArgs *)arg;
    uint64_t deviceId = args->deviceId;
    uint32_t readMs = args->readMs;
    napi_threadsafe_function tsfn = args->tsfn;
    free(args);

    HidProbeResult *r = (HidProbeResult *)calloc(1, sizeof(HidProbeResult));
    r->available = true;

    OH_LOG_INFO(LOG_APP, "[%{public}s] 开始探测: deviceId=%{public}llu readMs=%{public}u",
                LOG_TAG, (unsigned long long)deviceId, readMs);

    // Step 1: Init — 权限与服务的第一个信号点（与常驻 reader 共享引用计数）
    if (!hidInitRef()) {
        r->initCode = HID_DDK_INIT_ERROR;
        napi_call_threadsafe_function(tsfn, r, napi_tsfn_nonblocking);
        napi_release_threadsafe_function(tsfn, napi_tsfn_release);
        return nullptr;
    }
    r->initCode = HID_DDK_SUCCESS;
    OH_LOG_INFO(LOG_APP, "[%{public}s] OH_Hid_Init: %{public}d (%{public}s)",
                LOG_TAG, r->initCode, hidErrStr(r->initCode));

    // Step 2: 依次尝试 interface 0..4 打开
    Hid_DeviceHandle *dev = nullptr;
    for (uint8_t iface = 0; iface <= PROBE_IFACE_MAX; iface++) {
        int32_t code = fn_HidOpen(deviceId, iface, &dev);
        OH_LOG_INFO(LOG_APP, "[%{public}s] OH_Hid_Open(iface=%{public}u): %{public}d (%{public}s)",
                    LOG_TAG, iface, code, hidErrStr(code));
        if (code == HID_DDK_SUCCESS && dev) {
            r->opened = true;
            r->openCode = HID_DDK_SUCCESS;
            r->openIface = iface;
            break;
        }
        r->openCode = code;
        dev = nullptr;
        if (code != HID_DDK_DEVICE_NOT_FOUND && code != HID_DDK_INVALID_PARAMETER) {
            // 权限/服务级错误，换接口也不会成功
            break;
        }
    }

    if (r->opened && dev) {
        // Step 3: 设备信息
        if (fn_HidGetRawInfo) {
            Hid_RawDevInfo info;
            memset(&info, 0, sizeof(info));
            int32_t code = fn_HidGetRawInfo(dev, &info);
            if (code == HID_DDK_SUCCESS) {
                r->busType = info.busType;
                r->vid = info.vendor;
                r->pid = info.product;
                OH_LOG_INFO(LOG_APP, "[%{public}s] RawInfo: bus=%{public}u VID=0x%{public}x PID=0x%{public}x",
                            LOG_TAG, info.busType, info.vendor, info.product);
            } else {
                OH_LOG_WARN(LOG_APP, "[%{public}s] GetRawInfo: %{public}d (%{public}s)",
                            LOG_TAG, code, hidErrStr(code));
            }
        }
        if (fn_HidGetRawName) {
            char name[128] = {0};
            int32_t code = fn_HidGetRawName(dev, name, sizeof(name) - 1);
            if (code == HID_DDK_SUCCESS) {
                strncpy(r->name, name, sizeof(r->name) - 1);
                OH_LOG_INFO(LOG_APP, "[%{public}s] RawName: %{public}s", LOG_TAG, name);
            } else {
                OH_LOG_WARN(LOG_APP, "[%{public}s] GetRawName: %{public}d (%{public}s)",
                            LOG_TAG, code, hidErrStr(code));
            }
        }

        // Step 4: 报告描述符
        if (fn_HidGetDesc) {
            uint32_t descRead = 0;
            int32_t code = fn_HidGetDesc(dev, r->desc, PROBE_DESC_MAX, &descRead);
            r->descCode = code;
            r->descLen = descRead;
            if (code == HID_DDK_SUCCESS && descRead > 0) {
                OH_LOG_INFO(LOG_APP, "[%{public}s] ReportDescriptor: %{public}u 字节", LOG_TAG, descRead);
                // 打印前 96 字节 hex
                char hex[97 * 3] = {0};
                uint32_t dumpLen = descRead < 96 ? descRead : 96;
                for (uint32_t i = 0; i < dumpLen; i++) {
                    snprintf(hex + i * 3, 4, "%02x ", r->desc[i]);
                }
                OH_LOG_INFO(LOG_APP, "[%{public}s] 描述符前%{public}u字节: %{public}s", LOG_TAG, dumpLen, hex);
            } else {
                OH_LOG_WARN(LOG_APP, "[%{public}s] GetReportDescriptor: %{public}d (%{public}s)",
                            LOG_TAG, code, hidErrStr(code));
            }
        }

        // Step 5: 限时读输入报文
        uint64_t startMs = 0, nowMs = 0;
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        startMs = ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;

        uint8_t buf[PROBE_SAMPLE_MAX];
        while (true) {
            uint32_t bytesRead = 0;
            int32_t code = fn_HidReadTimeout(dev, buf, sizeof(buf), 300, &bytesRead);
            if (code == HID_DDK_SUCCESS && bytesRead > 0) {
                r->reportCount++;
                if (r->sampleCount < PROBE_SAMPLE_COUNT) {
                    uint32_t len = bytesRead > PROBE_SAMPLE_MAX ? PROBE_SAMPLE_MAX : bytesRead;
                    memcpy(r->samples[r->sampleCount], buf, len);
                    r->sampleLens[r->sampleCount] = len;
                    char hex[PROBE_SAMPLE_MAX * 3 + 1] = {0};
                    for (uint32_t i = 0; i < len; i++) {
                        snprintf(hex + i * 3, 4, "%02x ", buf[i]);
                    }
                    OH_LOG_INFO(LOG_APP, "[%{public}s] 报文样例#%{public}u (%{public}u字节): %{public}s",
                                LOG_TAG, r->sampleCount + 1, len, hex);
                    r->sampleCount++;
                }
            } else if (code != HID_DDK_TIMEOUT) {
                OH_LOG_WARN(LOG_APP, "[%{public}s] ReadTimeout: %{public}d (%{public}s)",
                            LOG_TAG, code, hidErrStr(code));
                if (code == HID_DDK_NO_PERM || code == HID_DDK_INIT_ERROR || code == HID_DDK_SERVICE_ERROR) {
                    break;
                }
            }

            clock_gettime(CLOCK_MONOTONIC, &ts);
            nowMs = ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
            if (nowMs - startMs >= readMs) break;
        }

        if (r->reportCount > 0 && nowMs > startMs) {
            r->reportsPerSec = (double)r->reportCount * 1000.0 / (double)(nowMs - startMs);
        }
        OH_LOG_INFO(LOG_APP, "[%{public}s] 读取完成: %{public}llu 报文 / %{public}u ms ≈ %{public}.1f Hz",
                    LOG_TAG, (unsigned long long)r->reportCount, readMs, r->reportsPerSec);

        // Step 6: 关闭
        int32_t closeCode = fn_HidClose(&dev);
        OH_LOG_INFO(LOG_APP, "[%{public}s] OH_Hid_Close: %{public}d (%{public}s)",
                    LOG_TAG, closeCode, hidErrStr(closeCode));
    }

    // 释放本探测持有的引用（引用计数归零时才真正 Release，
    // 避免拆掉并发运行的常驻 reader 正在使用的 DDK 连接）
    hidReleaseRef();
    OH_LOG_INFO(LOG_APP, "[%{public}s] 探测 Release 完成", LOG_TAG);

    OH_LOG_INFO(LOG_APP, "[%{public}s] 探测结束: opened=%{public}d iface=%{public}u desc=%{public}uB reports=%{public}llu",
                LOG_TAG, (int)r->opened, r->openIface, r->descLen, (unsigned long long)r->reportCount);

    napi_call_threadsafe_function(tsfn, r, napi_tsfn_nonblocking);
    napi_release_threadsafe_function(tsfn, napi_tsfn_release);
    return nullptr;
}

// ============================================================
// NAPI
// ============================================================

static napi_value HidProbe_IsAvailable(napi_env env, napi_callback_info info) {
    (void)info;
    bool ok = loadHidLibrary();
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

static napi_value HidProbe_Probe(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 3) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    int64_t deviceId64 = 0;
    int32_t readMs = 2000;
    napi_get_value_int64(env, args[0], &deviceId64);
    napi_get_value_int32(env, args[1], &readMs);
    if (readMs <= 0 || readMs > 10000) readMs = 2000;

    napi_value resName;
    napi_create_string_utf8(env, "HidDdkProbeResult", NAPI_AUTO_LENGTH, &resName);
    napi_threadsafe_function tsfn;
    napi_status status = napi_create_threadsafe_function(
        env, args[2], nullptr, resName, 2, 1, nullptr, nullptr, nullptr,
        probeResultOnJs, &tsfn
    );
    if (status != napi_ok) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    if (!loadHidLibrary()) {
        // 库不可用 → 同样走回调，保持单一结果通道
        HidProbeResult *r = (HidProbeResult *)calloc(1, sizeof(HidProbeResult));
        r->available = false;
        r->initCode = HID_DDK_INIT_ERROR;
        napi_call_threadsafe_function(tsfn, r, napi_tsfn_nonblocking);
        napi_release_threadsafe_function(tsfn, napi_tsfn_release);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    ProbeThreadArgs *targs = (ProbeThreadArgs *)malloc(sizeof(ProbeThreadArgs));
    targs->deviceId = (uint64_t)deviceId64;
    targs->readMs = (uint32_t)readMs;
    targs->tsfn = tsfn;

    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&thread, &attr, probeThread, targs) != 0) {
        free(targs);
        HidProbeResult *r = (HidProbeResult *)calloc(1, sizeof(HidProbeResult));
        r->available = true;
        r->initCode = HID_DDK_FAILURE;
        napi_call_threadsafe_function(tsfn, r, napi_tsfn_nonblocking);
        napi_release_threadsafe_function(tsfn, napi_tsfn_release);
    }
    pthread_attr_destroy(&attr);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

void HidDdkProbe_Init(napi_env env, napi_value exports) {
    napi_value obj;
    napi_create_object(env, &obj);

    napi_property_descriptor methods[] = {
        { "isAvailable", nullptr, HidProbe_IsAvailable, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "probe",       nullptr, HidProbe_Probe,       nullptr, nullptr, nullptr, napi_default, nullptr },
    };

    napi_define_properties(env, obj, sizeof(methods) / sizeof(methods[0]), methods);
    napi_set_named_property(env, exports, "HidDdkProbe", obj);

    OH_LOG_INFO(LOG_APP, "[%{public}s] HID DDK Probe NAPI 已注册", LOG_TAG);
}

// ============================================================
// 常驻 Reader - HID DDK 输入通道（供 HidDdkController 使用）
//
// 与 UsbDdkPoller 的区别：走内核 hidraw 通道（OH_Hid_*），
// 无需 claim USB 接口、无需内核驱动重绑定，读为阻塞事件驱动。
// ============================================================

#define HID_READER_MAX 4
#define HID_READER_REPORT_MAX 256

struct HidReaderContext {
    std::atomic<bool> running;
    pthread_t thread;
    bool threadCreated;
    pthread_mutex_t handleMutex;
    Hid_DeviceHandle *handle;
    uint64_t deviceId;
    uint8_t iface;
    uint32_t descLen;
    int32_t lastError;

    // 统计（1 秒滚动窗口）
    uint64_t totalReports;
    uint64_t totalBytes;
    uint64_t windowReports;
    uint64_t windowStartMs;
    double reportsPerSec;

    // 入队去重 + 限速（与 UsbDdkPoller 同策略：内容未变不入队，
    // 回调最小间隔 2ms，防止 JS 线程繁忙时无界 tsfn 队列增长）
    uint8_t lastInputData[HID_READER_REPORT_MAX];
    uint32_t lastInputLen;
    bool lastInputValid;
    uint64_t lastCallbackTimeMs;

    napi_threadsafe_function reportTsfn;
    napi_threadsafe_function errorTsfn;
};

static HidReaderContext g_hidReaders[HID_READER_MAX];
static pthread_mutex_t g_hidReaderMutex = PTHREAD_MUTEX_INITIALIZER;
static bool g_hidReaderPoolInited = false;

static void initReaderPool() {
    if (g_hidReaderPoolInited) return;
    for (int i = 0; i < HID_READER_MAX; i++) {
        g_hidReaders[i].running.store(false);
        g_hidReaders[i].threadCreated = false;
        g_hidReaders[i].handle = nullptr;
        g_hidReaders[i].reportTsfn = nullptr;
        g_hidReaders[i].errorTsfn = nullptr;
        pthread_mutex_init(&g_hidReaders[i].handleMutex, nullptr);
    }
    g_hidReaderPoolInited = true;
}

static int allocateReader() {
    for (int i = 0; i < HID_READER_MAX; i++) {
        if (!g_hidReaders[i].running.load() && !g_hidReaders[i].threadCreated) {
            return i;
        }
    }
    return -1;
}

static uint64_t nowMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
}

// ---- tsfn 回调数据 ----

struct HidReportEvent {
    int32_t readerId;
    uint8_t *data;
    uint32_t len;
};

struct HidReaderEvent {
    int32_t readerId;
    int32_t code;
};

static void readerReportOnJs(napi_env env, napi_value js_callback, void *context, void *rawData) {
    HidReportEvent *ev = (HidReportEvent *)rawData;
    if (!env || !js_callback || !ev) {
        if (ev) { free(ev->data); free(ev); }
        return;
    }
    void *bufData = nullptr;
    napi_value arrayBuffer;
    if (napi_create_arraybuffer(env, ev->len, &bufData, &arrayBuffer) == napi_ok && bufData) {
        memcpy(bufData, ev->data, ev->len);
        napi_value data;
        if (napi_create_typedarray(env, napi_uint8_array, ev->len, arrayBuffer, 0, &data) == napi_ok) {
            napi_value readerIdVal, lenVal, undefined;
            napi_create_int32(env, ev->readerId, &readerIdVal);
            napi_create_int32(env, (int32_t)ev->len, &lenVal);
            napi_get_undefined(env, &undefined);
            napi_value argv[3] = { readerIdVal, data, lenVal };
            napi_call_function(env, undefined, js_callback, 3, argv, nullptr);
        }
    }
    free(ev->data);
    free(ev);
}

static void readerEventOnJs(napi_env env, napi_value js_callback, void *context, void *rawData) {
    HidReaderEvent *ev = (HidReaderEvent *)rawData;
    if (!env || !js_callback || !ev) {
        if (ev) free(ev);
        return;
    }
    napi_value readerIdVal, codeVal, undefined;
    napi_create_int32(env, ev->readerId, &readerIdVal);
    napi_create_int32(env, ev->code, &codeVal);
    napi_get_undefined(env, &undefined);
    napi_value argv[2] = { readerIdVal, codeVal };
    napi_call_function(env, undefined, js_callback, 2, argv, nullptr);
    free(ev);
}

static void sendReaderEvent(napi_threadsafe_function tsfn, int32_t readerId, int32_t code) {
    if (!tsfn) return;
    HidReaderEvent *ev = (HidReaderEvent *)malloc(sizeof(HidReaderEvent));
    if (!ev) return;
    ev->readerId = readerId;
    ev->code = code;
    if (napi_call_threadsafe_function(tsfn, ev, napi_tsfn_nonblocking) != napi_ok) {
        free(ev);
    }
}

// ---- 读线程（Open 已在 startReader 调用线程同步完成）----

static void *hidReaderThread(void *arg) {
    int readerId = (int)(intptr_t)arg;
    HidReaderContext *ctx = &g_hidReaders[readerId];

    OH_LOG_INFO(LOG_APP, "[%{public}s] Reader#%{public}d 线程启动: deviceId=%{public}llu iface=%{public}u",
                LOG_TAG, readerId, (unsigned long long)ctx->deviceId, ctx->iface);

    ctx->windowStartMs = nowMs();
    ctx->windowReports = 0;

    while (ctx->running.load()) {
        uint8_t buf[HID_READER_REPORT_MAX];
        uint32_t bytesRead = 0;
        int32_t code = fn_HidReadTimeout(ctx->handle, buf, sizeof(buf), 100, &bytesRead);
        if (!ctx->running.load()) break;

        if (code == HID_DDK_SUCCESS && bytesRead > 0) {
            ctx->totalReports++;
            ctx->totalBytes += bytesRead;
            ctx->windowReports++;

            uint64_t now = nowMs();
            if (now - ctx->windowStartMs >= 1000) {
                ctx->reportsPerSec = (double)ctx->windowReports * 1000.0 / (double)(now - ctx->windowStartMs);
                ctx->windowReports = 0;
                ctx->windowStartMs = now;
            }

            // 去重：与上一帧完全相同则不入队（状态未变化）
            if (ctx->lastInputValid && bytesRead == ctx->lastInputLen &&
                memcmp(buf, ctx->lastInputData, bytesRead) == 0) {
                continue;
            }
            // 限速：回调最小间隔 2ms（500Hz 上限），不更新去重缓存，
            // 累积变化在下个间隔窗口发出
            if (ctx->lastCallbackTimeMs > 0 && now - ctx->lastCallbackTimeMs < 2) {
                continue;
            }
            ctx->lastCallbackTimeMs = now;

            if (bytesRead <= sizeof(ctx->lastInputData)) {
                memcpy(ctx->lastInputData, buf, bytesRead);
                ctx->lastInputLen = bytesRead;
                ctx->lastInputValid = true;
            }

            HidReportEvent *ev = (HidReportEvent *)malloc(sizeof(HidReportEvent));
            if (ev) {
                ev->readerId = readerId;
                ev->len = bytesRead;
                ev->data = (uint8_t *)malloc(bytesRead);
                if (ev->data) {
                    memcpy(ev->data, buf, bytesRead);
                    if (napi_call_threadsafe_function(ctx->reportTsfn, ev, napi_tsfn_nonblocking) != napi_ok) {
                        free(ev->data);
                        free(ev);
                    }
                } else {
                    free(ev);
                }
            }
        } else if (code == HID_DDK_TIMEOUT) {
            continue;
        } else {
            // IO 错误（设备拔出等）→ 上报并退出
            OH_LOG_ERROR(LOG_APP, "[%{public}s] Reader#%{public}d 读失败: %{public}d (%{public}s)",
                         LOG_TAG, readerId, code, hidErrStr(code));
            ctx->lastError = code;
            sendReaderEvent(ctx->errorTsfn, readerId, code);
            break;
        }
    }

    pthread_mutex_lock(&ctx->handleMutex);
    if (ctx->handle) {
        int32_t closeCode = fn_HidClose(&ctx->handle);
        ctx->handle = nullptr;
        OH_LOG_INFO(LOG_APP, "[%{public}s] Reader#%{public}d 关闭: %{public}d, 共 %{public}llu 报文",
                    LOG_TAG, readerId, closeCode, (unsigned long long)ctx->totalReports);
    }
    pthread_mutex_unlock(&ctx->handleMutex);

    hidReleaseRef();
    ctx->running.store(false);
    OH_LOG_INFO(LOG_APP, "[%{public}s] Reader#%{public}d 线程退出", LOG_TAG, readerId);
    return nullptr;
}

// ---- NAPI ----

static napi_value HidReader_IsAvailable(napi_env env, napi_callback_info info) {
    (void)info;
    bool ok = loadHidLibrary() && fn_HidWrite != nullptr;
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

// 返回 readerId(≥0)；失败返回 -(HID_DDK 错误码)，调用方可同步回退
// args: deviceId, readTimeoutMs(预留，当前固定 100ms), onReport(readerId, data, length), onError(readerId, code)
static napi_value HidReader_StartReader(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        napi_value r;
        napi_create_int32(env, -HID_DDK_INVALID_PARAMETER, &r);
        return r;
    }

    int64_t deviceId64 = 0;
    napi_get_value_int64(env, args[0], &deviceId64);

    initReaderPool();
    if (!loadHidLibrary()) {
        napi_value r;
        napi_create_int32(env, -HID_DDK_INIT_ERROR, &r);
        return r;
    }

    // Init（同步，权限/服务检查在此刻出结果）
    if (!hidInitRef()) {
        napi_value r;
        napi_create_int32(env, -HID_DDK_INIT_ERROR, &r);
        return r;
    }

    pthread_mutex_lock(&g_hidReaderMutex);
    int readerId = allocateReader();
    if (readerId < 0) {
        pthread_mutex_unlock(&g_hidReaderMutex);
        hidReleaseRef();
        napi_value r;
        napi_create_int32(env, -HID_DDK_FAILURE, &r);
        return r;
    }
    HidReaderContext *ctx = &g_hidReaders[readerId];
    ctx->running.store(false);
    ctx->handle = nullptr;
    ctx->deviceId = (uint64_t)deviceId64;
    ctx->iface = 0;
    ctx->descLen = 0;
    ctx->lastError = 0;
    ctx->totalReports = 0;
    ctx->totalBytes = 0;
    ctx->windowReports = 0;
    ctx->windowStartMs = 0;
    ctx->reportsPerSec = 0;
    ctx->lastInputLen = 0;
    ctx->lastInputValid = false;
    ctx->lastCallbackTimeMs = 0;

    // iface 扫描（同步）：首个 Open 成功且描述符非空者
    bool opened = false;
    int32_t failCode = HID_DDK_DEVICE_NOT_FOUND;
    for (uint8_t iface = 0; iface <= PROBE_IFACE_MAX; iface++) {
        Hid_DeviceHandle *dev = nullptr;
        int32_t code = fn_HidOpen(ctx->deviceId, iface, &dev);
        if (code == HID_DDK_SUCCESS && dev) {
            uint8_t descBuf[128];
            uint32_t descRead = 0;
            bool descOk = !fn_HidGetDesc;  // 无 GetDesc 符号时退化为仅要求 Open 成功
            if (fn_HidGetDesc) {
                int32_t dcode = fn_HidGetDesc(dev, descBuf, sizeof(descBuf), &descRead);
                descOk = (dcode == HID_DDK_SUCCESS && descRead > 0);
            }
            if (descOk) {
                ctx->handle = dev;
                ctx->iface = iface;
                ctx->descLen = descRead;
                opened = true;
                OH_LOG_INFO(LOG_APP, "[%{public}s] Reader#%{public}d 打开成功: iface=%{public}u desc=%{public}uB",
                            LOG_TAG, readerId, iface, descRead);
                break;
            }
            OH_LOG_WARN(LOG_APP, "[%{public}s] Reader#%{public}d iface=%{public}u 打开但无描述符，换下一个",
                        LOG_TAG, readerId, iface);
            fn_HidClose(&dev);
            continue;
        }
        if (code == HID_DDK_NO_PERM || code == HID_DDK_INIT_ERROR || code == HID_DDK_SERVICE_ERROR) {
            OH_LOG_ERROR(LOG_APP, "[%{public}s] Reader#%{public}d Open 失败: %{public}d (%{public}s)",
                         LOG_TAG, readerId, code, hidErrStr(code));
            failCode = code;
            break;
        }
        // DEVICE_NOT_FOUND → 下一个 iface
        failCode = code;
    }

    if (!opened) {
        ctx->lastError = failCode;
        pthread_mutex_unlock(&g_hidReaderMutex);
        hidReleaseRef();
        napi_value r;
        napi_create_int32(env, -failCode, &r);
        return r;
    }

    napi_value name1, name2;
    napi_create_string_utf8(env, "HidDdkReport", NAPI_AUTO_LENGTH, &name1);
    napi_create_string_utf8(env, "HidDdkError", NAPI_AUTO_LENGTH, &name2);

    bool ok = napi_create_threadsafe_function(env, args[2], nullptr, name1, 0, 1,
                        nullptr, nullptr, nullptr, readerReportOnJs, &ctx->reportTsfn) == napi_ok
           && napi_create_threadsafe_function(env, args[3], nullptr, name2, 8, 1,
                        nullptr, nullptr, nullptr, readerEventOnJs, &ctx->errorTsfn) == napi_ok;

    if (!ok) {
        if (ctx->handle) { fn_HidClose(&ctx->handle); ctx->handle = nullptr; }
        if (ctx->reportTsfn) napi_release_threadsafe_function(ctx->reportTsfn, napi_tsfn_abort);
        if (ctx->errorTsfn) napi_release_threadsafe_function(ctx->errorTsfn, napi_tsfn_abort);
        ctx->reportTsfn = nullptr;
        ctx->errorTsfn = nullptr;
        pthread_mutex_unlock(&g_hidReaderMutex);
        hidReleaseRef();
        OH_LOG_ERROR(LOG_APP, "[%{public}s] Reader#%{public}d 创建 tsfn 失败", LOG_TAG, readerId);
        napi_value r;
        napi_create_int32(env, -HID_DDK_FAILURE, &r);
        return r;
    }

    ctx->running.store(true);
    int pret = pthread_create(&ctx->thread, nullptr, hidReaderThread, (void *)(intptr_t)readerId);
    if (pret != 0) {
        ctx->running.store(false);
        if (ctx->handle) { fn_HidClose(&ctx->handle); ctx->handle = nullptr; }
        napi_release_threadsafe_function(ctx->reportTsfn, napi_tsfn_abort);
        napi_release_threadsafe_function(ctx->errorTsfn, napi_tsfn_abort);
        ctx->reportTsfn = nullptr;
        ctx->errorTsfn = nullptr;
        pthread_mutex_unlock(&g_hidReaderMutex);
        hidReleaseRef();
        OH_LOG_ERROR(LOG_APP, "[%{public}s] Reader pthread_create 失败: %{public}d", LOG_TAG, pret);
        napi_value r;
        napi_create_int32(env, -HID_DDK_FAILURE, &r);
        return r;
    }

    ctx->threadCreated = true;
    pthread_mutex_unlock(&g_hidReaderMutex);

    napi_value r;
    napi_create_int32(env, readerId, &r);
    return r;
}

static napi_value HidReader_StopReader(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t readerId = -1;
    if (argc >= 1) napi_get_value_int32(env, args[0], &readerId);
    if (readerId < 0 || readerId >= HID_READER_MAX) {
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }

    HidReaderContext *ctx = &g_hidReaders[readerId];
    pthread_mutex_lock(&g_hidReaderMutex);
    if (!ctx->threadCreated) {
        pthread_mutex_unlock(&g_hidReaderMutex);
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }
    ctx->running.store(false);
    pthread_mutex_unlock(&g_hidReaderMutex);

    pthread_join(ctx->thread, nullptr);

    pthread_mutex_lock(&g_hidReaderMutex);
    if (ctx->reportTsfn) { napi_release_threadsafe_function(ctx->reportTsfn, napi_tsfn_release); ctx->reportTsfn = nullptr; }
    if (ctx->errorTsfn) { napi_release_threadsafe_function(ctx->errorTsfn, napi_tsfn_release); ctx->errorTsfn = nullptr; }
    ctx->threadCreated = false;
    pthread_mutex_unlock(&g_hidReaderMutex);

    OH_LOG_INFO(LOG_APP, "[%{public}s] Reader#%{public}d 已停止", LOG_TAG, readerId);
    napi_value r;
    napi_create_int32(env, 0, &r);
    return r;
}

static napi_value HidReader_WriteOutput(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t readerId = -1;
    if (argc >= 2) napi_get_value_int32(env, args[0], &readerId);
    if (readerId < 0 || readerId >= HID_READER_MAX) {
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }

    HidReaderContext *ctx = &g_hidReaders[readerId];

    uint8_t *data = nullptr;
    size_t len = 0;
    bool isTyped = false;
    napi_is_typedarray(env, args[1], &isTyped);
    if (isTyped) {
        napi_typedarray_type type;
        void *buf = nullptr;
        napi_get_typedarray_info(env, args[1], &type, &len, &buf, nullptr, nullptr);
        data = (uint8_t *)buf;
    } else {
        void *buf = nullptr;
        napi_get_arraybuffer_info(env, args[1], &buf, &len);
        data = (uint8_t *)buf;
    }
    if (!data || len == 0 || len > 64) {
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }

    pthread_mutex_lock(&ctx->handleMutex);
    if (!ctx->handle) {
        pthread_mutex_unlock(&ctx->handleMutex);
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }
    uint32_t written = 0;
    int32_t code = fn_HidWrite(ctx->handle, data, (uint32_t)len, &written);
    pthread_mutex_unlock(&ctx->handleMutex);

    if (code != HID_DDK_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "[%{public}s] Reader#%{public}d WriteOutput: %{public}d (%{public}s)",
                    LOG_TAG, readerId, code, hidErrStr(code));
        ctx->lastError = code;
        napi_value r;
        napi_create_int32(env, -code, &r);
        return r;
    }
    napi_value r;
    napi_create_int32(env, (int32_t)written, &r);
    return r;
}

static napi_value HidReader_GetReaderStats(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t readerId = -1;
    if (argc >= 1) napi_get_value_int32(env, args[0], &readerId);

    napi_value result;
    napi_create_object(env, &result);
    if (readerId < 0 || readerId >= HID_READER_MAX) return result;

    HidReaderContext *ctx = &g_hidReaders[readerId];
    auto setInt = [&](const char *name, int64_t val) {
        napi_value v; napi_create_int64(env, val, &v);
        napi_set_named_property(env, result, name, v);
    };
    napi_value rateVal;
    napi_create_double(env, ctx->reportsPerSec, &rateVal);
    napi_set_named_property(env, result, "reportsPerSec", rateVal);

    setInt("iface", ctx->iface);
    setInt("descriptorLength", ctx->descLen);
    setInt("totalReports", (int64_t)ctx->totalReports);
    setInt("totalBytes", (int64_t)ctx->totalBytes);
    setInt("lastError", ctx->lastError);
    napi_value runningVal;
    napi_get_boolean(env, ctx->running.load(), &runningVal);
    napi_set_named_property(env, result, "running", runningVal);
    return result;
}

void HidDdkReader_Init(napi_env env, napi_value exports) {
    napi_value obj;
    napi_create_object(env, &obj);

    napi_property_descriptor methods[] = {
        { "isAvailable",   nullptr, HidReader_IsAvailable,   nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startReader",   nullptr, HidReader_StartReader,   nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopReader",    nullptr, HidReader_StopReader,    nullptr, nullptr, nullptr, napi_default, nullptr },
        { "writeOutput",   nullptr, HidReader_WriteOutput,   nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getReaderStats", nullptr, HidReader_GetReaderStats, nullptr, nullptr, nullptr, napi_default, nullptr },
    };

    napi_define_properties(env, obj, sizeof(methods) / sizeof(methods[0]), methods);
    napi_set_named_property(env, exports, "HidDdk", obj);

    OH_LOG_INFO(LOG_APP, "[%{public}s] HID DDK Reader NAPI 已注册", LOG_TAG);
}
