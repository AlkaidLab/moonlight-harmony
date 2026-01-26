# Moonlight HarmonyOS 迁移指南

本文档详细说明如何将 Android 版本的代码逐步迁移到 HarmonyOS。

## 1. 文件迁移清单

### 1.1 核心 Java 类 → ArkTS

| Android Java 文件 | HarmonyOS ArkTS 文件 | 迁移状态 |
|------------------|---------------------|---------|
| `PcView.java` | `pages/PcListPage.ets` | ✅ 已创建 |
| `AppView.java` | `pages/AppListPage.ets` | ✅ 已创建 |
| `Game.java` | `pages/StreamPage.ets` | ✅ 已创建 |
| `HelpActivity.java` | `pages/SettingsPage.ets` | ✅ 已创建 |
| `ShortcutTrampoline.java` | - | ⏳ 待迁移 |

### 1.2 数据模型

| Android | HarmonyOS | 状态 |
|---------|-----------|------|
| `computers/ComputerDetails.java` | `model/ComputerInfo.ets` | ✅ 已创建 |
| `nvstream/NvApp.java` | `model/AppInfo.ets` | ✅ 已创建 |
| `preferences/PreferenceConfiguration.java` | `model/StreamConfig.ets` | ✅ 已创建 |

### 1.3 网络通信

| Android | HarmonyOS | 状态 |
|---------|-----------|------|
| `nvstream/http/NvHTTP.java` | `service/NvHttp.ets` | ✅ 已创建 |
| `discovery/DiscoveryService.java` | `service/MdnsDiscovery.ets` | ✅ 已创建 |
| `computers/ComputerManagerService.java` | `service/ComputerManager.ets` | ✅ 已创建 |

### 1.4 Native 代码

| Android JNI | HarmonyOS NAPI | 状态 |
|-------------|----------------|------|
| `simplejni.c` | `napi_init.cpp` | ✅ 已创建 |
| `minisdl.c` | `video_decoder.cpp` | ✅ 已创建 |
| `callbacks.c` | `moonlight_bridge.cpp` | ✅ 已创建 |
| `OpusEncoder.c` | `audio_decoder.cpp` | ✅ 已创建 |

### 1.5 moonlight-common-c

需要从 Android 项目复制以下文件到 `nativelib/src/main/cpp/moonlight-common-c/`:

```
moonlight-common-c/
├── src/
│   ├── Connection.c
│   ├── ControlStream.c
│   ├── VideoStream.c
│   ├── AudioStream.c
│   ├── Input.c
│   ├── RtspConnection.c
│   ├── RtpVideoQueue.c
│   ├── RtpAudioQueue.c
│   ├── Rs.c
│   ├── Misc.c
│   ├── LinkedBlockingQueue.c
│   ├── Platform.c
│   └── Crypto.c
└── headers/
    └── *.h
```

## 2. 详细迁移步骤

### 2.1 复制 moonlight-common-c

```bash
# 从 Android 项目复制
cp -r moonlight-android/app/src/main/jni/moonlight-core/moonlight-common-c \
      moonlight-harmonyos/nativelib/src/main/cpp/
```

### 2.2 修改 CMakeLists.txt

取消注释 `CMakeLists.txt` 中的 moonlight-common-c 源文件：

```cmake
set(MOONLIGHT_COMMON_SOURCES
    moonlight-common-c/src/Connection.c
    moonlight-common-c/src/ControlStream.c
    # ... 其他文件
)

add_library(moonlight_nativelib SHARED
    ${SOURCE_FILES}
    ${MOONLIGHT_COMMON_SOURCES}
)
```

### 2.3 编译 OpenSSL

moonlight-common-c 依赖 OpenSSL，需要为 HarmonyOS 交叉编译：

```bash
# 下载 OpenSSL 源码
wget https://www.openssl.org/source/openssl-3.0.x.tar.gz

# 使用 ohos-ndk 编译
export OHOS_NDK=/path/to/ohos-ndk
./Configure linux-aarch64 --prefix=/path/to/output
make
```

### 2.4 实现平台适配层

创建 `nativelib/src/main/cpp/platform_ohos.c`：

```c
// HarmonyOS 平台适配
#include "Platform.h"

void PltSleepMs(int ms) {
    usleep(ms * 1000);
}

uint64_t PltGetMillis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// ... 其他平台函数
```

## 3. 资源文件迁移

### 3.1 图标和图片

将 Android `res/drawable` 中的图片复制到：
`entry/src/main/resources/base/media/`

### 3.2 字符串资源

Android `res/values/strings.xml` → `resources/base/element/string.json`

### 3.3 颜色资源

Android `res/values/colors.xml` → `resources/base/element/color.json`

## 4. 权限对照

| Android Permission | HarmonyOS Permission |
|-------------------|---------------------|
| `INTERNET` | `ohos.permission.INTERNET` |
| `ACCESS_NETWORK_STATE` | `ohos.permission.GET_NETWORK_INFO` |
| `ACCESS_WIFI_STATE` | `ohos.permission.GET_WIFI_INFO` |
| `RECORD_AUDIO` | `ohos.permission.MICROPHONE` |
| `VIBRATE` | `ohos.permission.VIBRATE` |
| `FOREGROUND_SERVICE` | `ohos.permission.KEEP_BACKGROUND_RUNNING` |

## 5. 测试计划

### 5.1 单元测试

- [ ] 网络请求测试
- [ ] 数据模型测试
- [ ] 加密功能测试

### 5.2 集成测试

- [ ] 电脑发现流程
- [ ] 配对流程
- [ ] 串流连接
- [ ] 输入响应

### 5.3 性能测试

- [ ] 视频延迟 < 50ms
- [ ] 帧率稳定性
- [ ] 内存占用
- [ ] CPU 占用

## 6. 常见问题

### Q: NAPI 和 JNI 的主要区别？

NAPI 使用 Node.js 风格的 API，需要通过 `napi_value` 进行参数传递，而不是直接使用 Java 类型。

### Q: 如何调试 Native 代码？

在 DevEco Studio 中使用 LLDB 调试器，或使用 `OH_LOG_INFO` 输出日志。

### Q: XComponent 如何获取 Surface？

使用 `XComponentController.getXComponentSurfaceId()` 获取 Surface ID，然后在 Native 层通过 `OH_NativeWindow_CreateNativeWindowFromSurfaceId` 获取 NativeWindow。
