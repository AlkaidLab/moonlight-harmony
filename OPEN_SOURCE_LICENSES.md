# Moonlight V+ 开源库说明

本文档列出了 Moonlight V+ 应用使用的所有开源库及其许可证信息。

## 核心项目

### Moonlight

- **项目**: Moonlight
- **网站**: https://moonlight-stream.org/
- **GitHub**: https://github.com/moonlight-stream
- **许可证**: GNU General Public License v3.0 (GPLv3)
- **说明**: 本应用基于 Moonlight 开源项目开发，是一款用于 NVIDIA GameStream 和 Sunshine 的开源游戏串流客户端。

---

## 原生库

### moonlight-common-c

- **项目**: moonlight-common-c
- **GitHub**: https://github.com/moonlight-stream/moonlight-common-c
- **许可证**: GNU General Public License v3.0 (GPLv3)
- **说明**: Moonlight 的核心 C 语言库，实现了 GameStream 协议的客户端逻辑，包括：
  - 连接管理 (RTSP)
  - 视频/音频流解包
  - 输入流处理
  - 加密通信

```
GNU GENERAL PUBLIC LICENSE
Version 3, 29 June 2007

Copyright (C) 2007 Free Software Foundation, Inc. <http://fsf.org/>
```

### ENet

- **项目**: ENet
- **网站**: http://enet.bespin.org/
- **GitHub**: https://github.com/lsalzman/enet
- **许可证**: MIT License
- **说明**: 可靠的 UDP 网络库，用于游戏输入的低延迟传输。

```
Copyright (c) 2002-2020 Lee Salzman

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

### Reed-Solomon

- **项目**: Reed-Solomon Forward Error Correction
- **许可证**: BSD 2-Clause License
- **说明**: Reed-Solomon 前向纠错实现，用于视频流的丢包恢复。

```
(C) 1997-98 Luigi Rizzo (luigi@iet.unipi.it)
(C) 2001 Alain Knaff (alain@knaff.lu)
(C) 2017 Iwan Timmer (irtimmer@gmail.com)

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHORS "AS IS" AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
```

### ohos-openssl

- **项目**: ohos-openssl (OpenSSL for HarmonyOS)
- **GitHub**: https://github.com/ohos-rs/ohos-openssl
- **许可证**: MIT License (封装层) + Apache License 2.0 (OpenSSL)
- **说明**: 为 HarmonyOS 预编译的 OpenSSL 库，提供 TLS/SSL 加密通信功能。

```
MIT License (ohos-openssl wrapper)

Copyright (c) 2024 ohos-rs

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```

### OpenSSL

- **项目**: OpenSSL
- **网站**: https://www.openssl.org/
- **许可证**: Apache License 2.0
- **说明**: 用于 TLS/SSL 加密通信和加密操作。

```
Copyright 2002-2024 The OpenSSL Project Authors. All Rights Reserved.

Licensed under the Apache License 2.0 (the "License"). You may not use
this file except in compliance with the License. You can obtain a copy
in the file LICENSE in the source distribution or at
https://www.openssl.org/source/license.html
```

---

## HarmonyOS 系统 API

本应用使用了以下 HarmonyOS 系统 API：

### AVCodec API
- **用途**: 硬件视频解码 (H.264/HEVC/AV1)
- **提供方**: 华为 HarmonyOS SDK

### AVPlayer API
- **用途**: 音频播放 (Opus 解码)
- **提供方**: 华为 HarmonyOS SDK

### USB Manager API
- **用途**: USB 手柄设备管理
- **提供方**: 华为 HarmonyOS SDK

### Game Controller Kit
- **用途**: 系统手柄输入支持
- **提供方**: 华为 HarmonyOS SDK

### XComponent/Native Window API
- **用途**: 视频画面渲染
- **提供方**: 华为 HarmonyOS SDK

---

## 测试框架

### @ohos/hypium

- **项目**: HarmonyOS Unit Test Framework
- **许可证**: Apache License 2.0
- **说明**: HarmonyOS 单元测试框架。

---

## 资源与参考

### SDL GameControllerDB

- **项目**: SDL_GameControllerDB
- **GitHub**: https://github.com/gabomdq/SDL_GameControllerDB
- **许可证**: zlib License
- **说明**: 游戏控制器映射数据库，用于识别和映射各种手柄设备。

```
Copyright (c) 2006-2024 Sam Lantinga

This software is provided 'as-is', without any express or implied warranty.
In no event will the authors be held liable for any damages arising from
the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```

---

## 许可证摘要

| 库名称 | 许可证 | 类型 |
|--------|--------|------|
| Moonlight | GPLv3 | Copyleft |
| moonlight-common-c | GPLv3 | Copyleft |
| ENet | MIT | Permissive |
| Reed-Solomon | BSD 2-Clause | Permissive |
| OpenSSL | Apache 2.0 | Permissive |
| ohos-openssl | MIT | Permissive |
| SDL GameControllerDB | zlib | Permissive |
| @ohos/hypium | Apache 2.0 | Permissive |

---

## 合规说明

### GPLv3 合规

本应用遵循 GNU General Public License v3.0：

1. **源代码可用性**: 本应用的完整源代码可在 GitHub 获取
2. **许可证传递**: 本应用也采用 GPLv3 许可证
3. **版权声明**: 保留所有原始版权声明
4. **修改说明**: 对原始代码的修改已在源代码中标注

### 获取源代码

如需获取本应用的完整源代码，请访问：
- GitHub: [待补充仓库地址]

或通过以下方式联系我们获取：
- 邮箱: [待补充]

---

*最后更新: 2025年1月*
