# Moonlight V+ for HarmonyOS

<div align="center">
  
  <img src="entry/src/main/resources/base/media/app_icon.png" width="128" height="128" alt="Logo">
  
  # 🌙 Moonlight V+ for HarmonyOS
  
  **专为鸿蒙打造的 PC 游戏串流客户端**
  
  [![GitHub License](https://img.shields.io/github/license/AlkaidLab/moonlight-harmony)](LICENSE)
  [![HarmonyOS](https://img.shields.io/badge/HarmonyOS-5.0%2B-blue)](https://www.harmonyos.com/)
  [![API Version](https://img.shields.io/badge/API-12%2B-green)](https://developer.huawei.com/)
  
  基于 [Moonlight V+](https://github.com/qiin2333/moonlight-vplus) 的鸿蒙原生移植版本
  
  [功能特性](#-功能特性) • [下载安装](#-下载安装) • [使用说明](#-使用说明) • [相关项目](#-相关项目) • [开发指南](#-开发指南)
  
</div>

---

## ✨ 功能特性

### 🏆 比原版 Moonlight 强在哪？

> 原版 Moonlight 只能 HDR10？**我们直接 HLG 拉满。** 华为设备原生 HDR Vivid 支持 + HLG (ARIB STD-B67) 传输，画面色彩准确到让你怀疑自己以前串流的是黑白电视。搭配 Foundation Sunshine 使用，你的 PC 游戏画面终于配得上你那块好屏幕了。

| 特性 | 原版 Moonlight | 🌙 Moonlight V+ |
|------|:-:|:-:|
| HDR10 | ✅ | ✅ 亮度映射同步 |
| **HLG (HDR Vivid)** | ❌ | ✅ 独家 |
| **虚拟显示器** | ❌ | ✅ 无缝连接，不抢主屏 |
| **服务端指令** | ❌ | ✅ 串流中直接执行 |
| **动态码率调节** | ❌ | ✅ 串流中任意尝试大小 |
| 空间音频 | ❌ | ✅ HarmonyOS 5.0+ |
| **体感助手 (Gyro Aim)** | ❌ | ✅ 陀螺仪→右摇杆辅助瞄准 |
| Game Controller Kit | ❌ | ✅ 鸿蒙原生手柄 API |
| VRR 可变刷新率 | ❌ | ✅ 告别撕裂 |
| 性能覆盖层 | 基础 | ✅ 可拖拽/自定义项目 |
| 麦克风重定向 | ❌ | ✅ 语音开黑 |

### 视频串流
- 🎮 支持 H.264/HEVC 硬件解码
- 📺 支持 4K@120fps 高清串流
- 🌈 支持 HDR10/HLG 高动态范围
- 🔄 支持 VRR 可变刷新率

### 音频
- 🔊 支持立体声/5.1/7.1 环绕声
- 🎧 支持空间音频 (HarmonyOS 5.0+)
- 🎙️ 支持麦克风重定向 (开发者模式)

### 输入控制
- 🎮 蓝牙/USB 手柄支持 (Xbox/PlayStation/Switch)
- 📱 虚拟屏幕控制器
- 🖱️ 触控/鼠标模拟
- ⌨️ 完整键盘支持

### 连接
- 🔍 自动发现局域网主机
- 🌐 支持远程串流 (需要端口转发或 WAN IP)
- 🔒 AES-128 加密连接

## 📥 下载安装

### 系统要求
- HarmonyOS NEXT 5.0 或更高版本
- 支持的设备：华为手机/平板/MatePad

### 安装方式

1. **从 Release 下载**
   - 前往 [Releases](https://github.com/AlkaidLab/moonlight-harmony/releases) 页面
   - 下载最新版本的 HAP 文件
   - 使用 HDC 安装到设备

2. **从源码编译**
   ```bash
   git clone https://github.com/AlkaidLab/moonlight-harmony.git
   cd moonlight-harmony
   # 使用 DevEco Studio 打开并编译
   ```

## 📖 使用说明

### 主机设置

1. 在 PC 上安装 [Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine) 或 NVIDIA GeForce Experience
2. 启用游戏串流功能
3. 确保 PC 和手机在同一局域网

### 配对连接

1. 打开 Moonlight V+ for HarmonyOS 应用
2. 应用会自动发现局域网内的主机
3. 点击主机进行配对（首次需要在 PC 端确认）
4. 配对成功后即可选择游戏开始串流

### 推荐设置

| 网络环境 | 分辨率 | 帧率 | 码率 |
|----------|--------|------|------|
| 5GHz WiFi 局域网 | 1080p | 60fps | 20 Mbps |
| 5GHz WiFi 局域网 | 4K | 60fps | 50 Mbps |
| 有线/Wi-Fi 6 | 1080p | 120fps | 40 Mbps |

## 🔗 相关项目

| 项目 | 说明 |
|------|------|
| [Moonlight V+ Android](https://github.com/qiin2333/moonlight-vplus) | Android 增强版客户端 |
| [Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine) | 游戏串流服务端 |
| [Moonlight](https://moonlight-stream.org/) | 官方 Moonlight 项目 |
| [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) | 核心协议库 |

## 🛠️ 开发指南

### 开发环境

- **DevEco Studio**: 5.0.0 或更高版本
- **HarmonyOS SDK**: API 12 (HarmonyOS 5.0)
- **Node.js**: 16.x 或更高版本

### 项目结构

```
moonlight-harmony/
├── entry/                          # 主入口模块
│   └── src/main/
│       ├── ets/                    # ArkTS 代码
│       │   ├── pages/              # UI 页面
│       │   ├── components/         # UI 组件
│       │   ├── service/            # 业务服务
│       │   └── model/              # 数据模型
│       └── resources/              # 模块资源
├── nativelib/                      # Native 模块
│   └── src/main/cpp/               # C/C++ 代码
│       ├── moonlight_bridge.*      # NAPI 桥接层
│       ├── video_decoder.*         # 视频解码 (AVCodec)
│       ├── audio_renderer.*        # 音频播放 (OHAudio)
│       └── moonlight-common-c/     # 核心协议库
└── AppScope/                       # 应用配置
```

### 核心技术

| 功能 | 技术方案 |
|------|----------|
| UI 框架 | ArkUI (ArkTS) |
| 视频解码 | HarmonyOS AVCodec API |
| 音频播放 | OHAudio (低延迟模式) |
| 网络协议 | moonlight-common-c |
| Native 接口 | NAPI (C++) |

### 构建项目

```bash
# 克隆仓库
git clone https://github.com/AlkaidLab/moonlight-harmony.git

# 使用 DevEco Studio 打开项目
# File → Open → 选择项目目录

# 编译 HAP
./hvigorw assembleHap
```

## 🐛 问题反馈

如果您遇到问题或有功能建议，请：

1. 查看 [Issues](https://github.com/AlkaidLab/moonlight-harmony/issues) 是否已有相关问题
2. 如果没有，请 [创建新 Issue](https://github.com/AlkaidLab/moonlight-harmony/issues/new)

反馈时请提供：
- 设备型号和系统版本
- 问题复现步骤
- 错误日志（如有）

## 📄 许可证

本项目基于 [GPL v3](LICENSE) 许可证开源。

### 第三方资源声明

本应用的背景壁纸功能使用了第三方 API 服务：

| 来源 | 说明 | 版权 |
|------|------|------|
| [Pipw API](https://img-api.pipw.top) | 二次元壁纸（默认）| 图片版权归原作者所有 |
| [Lorem Picsum](https://picsum.photos) | 摄影壁纸（可选）| Unsplash 授权 |

**重要声明**：
- 本应用仅提供技术链接，不存储、不拥有这些图片的版权
- 如有版权问题，请联系原图片来源方
- 用户可在设置中随时关闭壁纸功能或切换为其他来源

## 🙏 致谢

- [Moonlight Game Streaming](https://moonlight-stream.org/) - 官方 Moonlight 项目
- [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) - 核心协议库
- [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) - 开源串流服务端

---

<div align="center">
  
  **Powered by AlkaidLab** ✨
  
  如果这个项目对您有帮助，欢迎给一个 ⭐️
  
</div>
