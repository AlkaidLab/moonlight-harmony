# Moonlight V+ for HarmonyOS

<div align="center">
  
  # 🌙 Moonlight V+ 鸿蒙版
  
  **HarmonyOS 游戏串流客户端**
  
  基于 [Moonlight](https://moonlight-stream.org/) 的鸿蒙原生移植版本
  
</div>

## 📋 项目概述

本项目是 Moonlight V+ Android 版的 HarmonyOS 移植版本，使用 ArkTS + C++ (NAPI) 实现，支持 HarmonyOS NEXT (5.0+) 设备。

## 🏗️ 项目结构

```
moonlight-harmonyos/
├── AppScope/                       # 应用级配置
│   ├── app.json5                   # 应用配置
│   └── resources/                  # 应用资源
├── entry/                          # 主入口模块
│   └── src/main/
│       ├── ets/                    # ArkTS 代码
│       │   ├── entryability/       # Ability 入口
│       │   ├── pages/              # UI 页面
│       │   │   ├── Index.ets       # 启动页
│       │   │   ├── PcListPage.ets  # 电脑列表
│       │   │   ├── AppListPage.ets # 应用列表
│       │   │   ├── StreamPage.ets  # 串流页面
│       │   │   ├── SettingsPage.ets# 设置页面
│       │   │   └── AddPcPage.ets   # 添加电脑
│       │   ├── components/         # UI 组件
│       │   ├── model/              # 数据模型
│       │   ├── service/            # 业务服务
│       │   ├── services/           # 后台服务
│       │   └── utils/              # 工具类
│       ├── resources/              # 模块资源
│       └── module.json5            # 模块配置
├── nativelib/                      # Native 模块
│   └── src/main/cpp/               # C/C++ 代码
│       ├── CMakeLists.txt          # CMake 配置
│       ├── napi_init.cpp           # NAPI 入口
│       ├── moonlight_bridge.*      # 桥接层
│       ├── video_decoder.*         # 视频解码
│       ├── audio_decoder.*         # 音频解码
│       └── input_handler.*         # 输入处理
├── build-profile.json5             # 构建配置
├── hvigorfile.ts                   # Hvigor 配置
└── oh-package.json5                # 包配置
```

## 🚀 开发环境

### 系统要求

- **操作系统**: Windows 10/11, macOS 10.15+, 或 Ubuntu 18.04+
- **DevEco Studio**: 5.0.0 或更高版本
- **HarmonyOS SDK**: API 12 (HarmonyOS 5.0)
- **Node.js**: 16.x 或更高版本

### 环境配置

1. 下载并安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)
2. 配置 HarmonyOS SDK
3. 配置 Native SDK (用于 C++ 开发)

## 📦 构建项目

### 在 DevEco Studio 中打开项目

1. 打开 DevEco Studio
2. 选择 `File` → `Open` → 选择 `moonlight-harmonyos` 文件夹
3. 等待项目同步完成

### 编译运行

```bash
# 使用 hvigorw 命令行编译
./hvigorw assembleHap

# 或在 DevEco Studio 中点击运行按钮
```

## 🔧 开发指南

### 页面导航

| 页面 | 路径 | 说明 |
|------|------|------|
| 启动页 | `pages/Index` | 应用启动闪屏 |
| 电脑列表 | `pages/PcListPage` | 显示已发现的电脑 |
| 应用列表 | `pages/AppListPage` | 显示电脑上的游戏/应用 |
| 串流页面 | `pages/StreamPage` | 视频串流主界面 |
| 设置页面 | `pages/SettingsPage` | 应用设置 |
| 添加电脑 | `pages/AddPcPage` | 手动添加电脑 |

### 核心服务

| 服务 | 文件 | 说明 |
|------|------|------|
| ComputerManager | `service/ComputerManager.ets` | 管理已发现的电脑 |
| NvHttp | `service/NvHttp.ets` | 与服务器 HTTP 通信 |
| StreamingSession | `service/StreamingSession.ets` | 管理串流会话 |
| MdnsDiscovery | `service/MdnsDiscovery.ets` | mDNS 服务发现 |

### Native 模块

Native 模块使用 C++ 实现，通过 NAPI 与 ArkTS 交互：

- **moonlight_bridge**: 连接管理，封装 moonlight-common-c
- **video_decoder**: 视频解码，使用 AVCodec API
- **audio_decoder**: 音频播放，使用 OHAudio API
- **input_handler**: 输入事件发送

## 📝 待完成功能

### 高优先级

- [ ] 移植 moonlight-common-c 核心库
- [ ] 实现完整的视频解码管线
- [ ] 实现音频解码和播放
- [ ] 实现输入处理（触控、手柄）

### 中优先级

- [ ] mDNS 服务发现
- [ ] 证书生成和配对流程
- [ ] 性能监控和统计
- [ ] 手柄震动反馈

### 低优先级

- [ ] HDR 支持
- [ ] 麦克风重定向
- [ ] 多显示器支持
- [ ] 自定义按键布局

## 🔄 从 Android 迁移

### API 对照表

| Android | HarmonyOS | 说明 |
|---------|-----------|------|
| Activity | UIAbility | 页面入口 |
| Service | ServiceExtensionAbility | 后台服务 |
| View | ArkUI Component | UI 组件 |
| MediaCodec | AVCodec | 视频编解码 |
| AudioTrack | AudioRenderer / OHAudio | 音频播放 |
| SurfaceView | XComponent | 视频渲染 |
| SharedPreferences | Preferences | 数据存储 |
| JNI | NAPI | Native 接口 |
| OkHttp | @ohos.net.http | HTTP 请求 |
| SensorManager | @ohos.sensor | 传感器 |

## 📄 许可证

本项目基于 GPL v3 许可证开源。

## 🙏 致谢

- [Moonlight Game Streaming](https://moonlight-stream.org/)
- [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c)
- [Sunshine](https://github.com/LizardByte/Sunshine)
