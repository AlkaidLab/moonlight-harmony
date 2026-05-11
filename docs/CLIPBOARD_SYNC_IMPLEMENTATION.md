# 剪贴板同步实现指南

## 核心库定义

### 消息类型

- **消息类型：** `0x5508`（Sunshine / Gen7Enc 扩展消息）
- **消息索引：** `IDX_CLIPBOARD = 20`
- **控制包格式：** 可变长度，单包最大约 `65500` 字节（不含 ENet 头）

### 有线帧格式（v1）

```text
Offset  Size    Field
0       1       version (= 0x01)
1       1       kind (0x01 = TEXT, 0x02 = PNG)
2       4       token (u32 little-endian)
6       4       length (u32 little-endian)
10      N       payload
```

**总头大小：** `10` 字节（`CLIPBOARD_WIRE_HEADER`）

## 安卓实现摘要

安卓侧 `ClipboardSyncManager.kt` 已经具备完整实现，主要特征如下：

- 监听系统剪贴板变化并向主机发送
- 接收主机回显或主机主动下发的剪贴板数据
- 使用两层回显抑制：
  - `recentSentTokens`：处理主机回显
  - `pendingSelfWrites`：处理本地写剪贴板引发的监听回调
- 文本与图片（PNG）都走同一套 wire frame 头部

### Android 侧错误码

`LiSendClipboardData()` 约定如下：

- `0`：成功
- `-1`：payload 无效或长度超限
- `-2`：服务器/协议不支持 clipboard message
- `-3`：当前未连接
- `-4`：底层 ENet 发送失败

## HarmonyOS 当前实现状态

当前仓库内的 HarmonyOS 版本已经完成**文本剪贴板同步闭环**，并通过实际构建验证。

### 已完成

- ArkTS 侧监听本地系统剪贴板文本变化
- 本地文本变化通过 native bridge 发送到 Sunshine 主机
- native 层接收主机下发的 clipboard 帧并回调到 ArkTS
- ArkTS 侧解析远端文本并写回本地系统剪贴板
- 设置页提供文本/图片两个开关
- 串流页按会话生命周期启动/停止同步服务

### 当前显式降级

- **图片同步仍保留协议入口和设置入口**
- 但由于当前 HarmonyOS 兼容 SDK 下没有在本仓验证通过的图片剪贴板 API，
  `ClipboardSyncService.ets` 会在图片场景下提示：
  **“当前 HarmonyOS 兼容 SDK 下未验证图片剪贴板 API，图片同步暂时禁用”**
- 该降级是故意的，目的是保证实现真实、可编译、可维护，而不是伪造一条未验证路径

## HarmonyOS 实现结构

### ArkTS 层

#### `ClipboardSyncConfig.ets`

- `enableSyncText`
- `enableSyncImage`
- `echoTtlMs = 5000`
- `maxTokenHistory = 16`
- `ClipboardWireFrame.build(...)`
- `ClipboardWireFrame.parse(...)`

#### `ClipboardSyncService.ets`

职责：

- 注册/注销系统剪贴板监听
- 注册/注销 native clipboard listener
- 处理本地 → 主机发送
- 处理主机 → 本地写回
- 执行 host echo / self echo 抑制

当前已验证可编译的 HarmonyOS 文本剪贴板 API：

- 读取：`await sysBoard.getData()` + `pasteData.getPrimaryText()`
- 写入：`pasteboard.createData(...)` + `sysBoard.setDataSync(...)`
- 监听：`sysBoard.on('update', listener)` / `sysBoard.off('update', listener)`

#### `ClipboardBridge.ets`

职责：

- 保存当前 ArkTS clipboard listener
- 提供 `sendClipboardData(frame)` 给 ArkTS 调用 native
- 提供 `onClipboardDataReceived(...)` 作为 native 回调入口

### Streaming 集成点

#### `StreamingSession.ets`

- 在 native callback 类型中加入 `clipboardData`
- 收到 native 回调后转发到 `ClipboardBridge.MoonBridge.onClipboardDataReceived(...)`

#### `StreamPage.ets`

- 在串流成功建立后读取设置
- 创建 `ClipboardSyncConfig`
- 启动 `ClipboardSyncService`
- 在连接结束 / 页面消失时停止服务

### 设置页集成点

#### `SettingsService.ets`

新增键名：

- `ENABLE_CLIPBOARD_SYNC_TEXT`
- `ENABLE_CLIPBOARD_SYNC_IMAGE`

#### `SettingsPageV2.ets`

- 增加“剪贴板同步”设置分组
- 两个开关分别对应文本/图片同步
- 当前图片同步开关仍保留，作为未来能力恢复的 UI 入口

## Native 层实现要点

### `moonlight_bridge.cpp`

- 新增 `GetByteArrayData(...)`，兼容 `ArrayBuffer` / `TypedArray`
- 新增 `MoonBridge_SendClipboardData(...)`
- 把 `ListenerCallbacks.clipboardData` 接入到连接回调结构

### `callbacks.h` / `callbacks.cpp`

- 新增 `tsfn_clipboardData`
- 新增 `BridgeClClipboardData(...)`
- 在 native 线程收到数据后，通过 `napi_threadsafe_function` 转回 ArkTS

### `napi_init.cpp`

- 注册 `sendClipboardData`

### `moonlight-common-c` 子模块

- 当前子模块指针前进到包含 clipboard 常量补充的提交
- 本次 PR 需要保留该子模块更新，否则 HarmonyOS 侧 clipboard 常量和能力定义对不上

## 回显抑制策略

### Layer 1：Host Echo

- 每次发送前生成随机 `u32 token`
- 保存到 `recentSentTokens`
- 接收来自主机的数据时，如果 token 命中历史表，则丢弃
- 历史表带 TTL（默认 `5000ms`）和最大容量（默认 `16`）

### Layer 2：Self Echo

- 本地写系统剪贴板前，`pendingSelfWrites++`
- 系统 update 监听触发时，优先消费该计数并直接返回

## 权限与模块配置

HarmonyOS 当前只声明：

- `ohos.permission.READ_PASTEBOARD`

说明：

- 当前兼容 SDK 下继续声明 `WRITE_PASTEBOARD` 会导致配置不成立
- 本仓现有文本写剪贴板路径不需要额外声明该权限即可正常编译

## 当前限制

1. **仅 Sunshine 支持**：GFE 不支持 `0x5508`
2. **仅支持文本真正落地**：图片同步暂时不写入系统图片剪贴板
3. **单帧大小受限**：约 `65500 - 10` 字节
4. **文本编码统一 UTF-8**

## 能力范围内已完成的闭环检查

- [x] ArkTS 关键文件编辑器诊断清零
- [x] `ClipboardSyncService.ets` 尾部残留旧代码已清理
- [x] `StreamPage.ets` 中 observer / ArkTS 对象字面量问题已修复
- [x] native bridge 支持 `TypedArray`/`ArrayBuffer`
- [x] inbound clipboard callback 已打通到 ArkTS
- [x] `module.json5` 权限配置已修正
- [x] DevEco hvigor 实际构建通过

## 暂未在本轮完成的事项

- [ ] 真机端到端手工验证“主机复制文本 ↔ 客户端同步文本”
- [ ] 图片剪贴板真正恢复
- [ ] 大文本 / 高频复制 / 多语言文本等专项回归

## 推荐后续验证清单

- [ ] 本地复制短文本 → 主机能收到
- [ ] 主机复制短文本 → 本地系统剪贴板更新
- [ ] 禁用文本同步后不再收发文本
- [ ] 启用图片同步时只出现一次降级提示
- [ ] 非 Sunshine / 不支持协议的场景下行为符合预期
