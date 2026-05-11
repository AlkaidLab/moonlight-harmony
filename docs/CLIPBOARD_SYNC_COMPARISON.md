# 安卓 vs 鸿蒙剪贴板同步对比

## 当前结论

两端的协议思路已经对齐，但当前 HarmonyOS 落地状态是：

- **文本同步：已实现并可编译**
- **图片同步：协议与 UI 入口保留，运行时显式降级**

换句话说，鸿蒙侧已经不是“设计稿”，而是“文本闭环版”。

## 核心概念对标

| 概念 | 安卓 (Kotlin) | 鸿蒙 (ArkTS) |
|-----|-------------|-----------|
| 配置类 | `PreferenceConfiguration` | `ClipboardSyncConfig` |
| 主服务 | `ClipboardSyncManager` | `ClipboardSyncService` |
| 桥接入口 | `MoonBridge` | `ClipboardBridge.MoonBridge` |
| 系统剪贴板 | `ClipboardManager` | `@kit.BasicServicesKit` pasteboard |
| 变化事件 | `OnPrimaryClipChangedListener` | `sysBoard.on('update', listener)` |
| 文本写入 | `setPrimaryClip()` | `setDataSync(createData(...))` |
| 图片同步 | 已实现 | 当前降级 |

## 架构对比

### 安卓

- 监听本地剪贴板
- 文本/图片都可发送
- 接收主机文本/图片并写回系统剪贴板
- 使用 `recentSentTokens + pendingSelfWrites` 处理回显

### 鸿蒙

- 监听本地剪贴板文本变化
- 文本可发送到主机
- 接收主机文本后写回系统剪贴板
- 接收主机图片或本地启用图片同步时，只提示暂不支持
- 同样使用 `recentSentTokens + pendingSelfWrites` 处理回显

## 图片处理差异

### 安卓

安卓侧已经有完整图片链路：

- 从系统剪贴板中读取图片
- 编码为 PNG
- 通过协议发送
- 接收后通过系统机制重新暴露给应用

### 鸿蒙当前实现

鸿蒙侧当前不再假设某套图片 API 一定可用，而是明确区分：

- **协议层：保留 PNG kind**
- **设置层：保留图片同步开关**
- **运行时：首次命中图片路径时提示不支持并停止处理**

这样做避免了两类问题：

1. 代码里塞入与当前 SDK 不匹配的图片接口
2. 文档和实现脱节，导致后续维护者误判真实能力

## 事件监听差异

### 安卓

```kotlin
clipboard.addPrimaryClipChangedListener(listener)
clipboard.removePrimaryClipChangedListener(listener)
```

### 鸿蒙

```ts
const listener = (): void => {
  void this.onPasteboardChanged()
}
sysBoard.on('update', listener)
sysBoard.off('update', listener)
```

## 回显抑制策略对比

### 两端共性

- 发送时生成随机 token
- 接收时先检查 token 是否为最近发送历史
- 本地写系统剪贴板前先累加 `pendingSelfWrites`
- 监听到 update 时优先消费 self echo

### 鸿蒙当前实现示意

```ts
private recentSentTokens: TokenEntry[] = []
private pendingSelfWrites: number = 0

private async applyRemoteClipboardData(kind: number, token: number, payload: Uint8Array): Promise<void> {
  if (this.isHostEcho(token)) {
    return
  }

  if (kind === ClipboardWireFrame.KIND_PNG) {
    this.warnImageSyncUnsupported('remote')
    return
  }

  this.pendingSelfWrites++
  const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
  sysBoard.setDataSync(pasteData)
}
```

## JNI / NAPI 差异

### 安卓

- Java 直接与 JNI 接口交互
- 常见输入类型是 `byte[]`

### 鸿蒙

- ArkTS 通过 NAPI 调用 C++ bridge
- 当前实现专门补了 `GetByteArrayData(...)`
- 因而既能接受 `ArrayBuffer`，也能接受 `TypedArray`
- inbound 回调通过 `napi_threadsafe_function` 回到 ArkTS

## 权限差异

### 安卓

安卓侧更多是围绕图片 URI / 存储访问链路展开。

### 鸿蒙

当前真实可用配置是：

```json5
{
  "name": "ohos.permission.READ_PASTEBOARD"
}
```

注意：

- `WRITE_PASTEBOARD` 不应继续写进当前 HarmonyOS 模块权限声明
- 文档如果继续写这个权限，会直接误导后续实现

## 迁移检查清单（按当前实现口径）

- [x] `ClipboardSyncConfig` 映射完成
- [x] `ClipboardSyncService` 文本路径实现完成
- [x] 回显抑制逻辑已接入
- [x] `StreamingSession` 已打通 inbound callback
- [x] `ClipboardBridge` 已暴露收发接口
- [x] `module.json5` 权限已修正为可编译形式
- [x] 设置页已接入两个开关
- [x] hvigor 实际构建通过
- [ ] 真机端到端回归
- [ ] 图片同步能力恢复

## 当前常见陷阱

### 1. 误把“图片入口保留”当成“图片功能已可用”

现在不是这样。UI 和协议入口保留，仅表示架构已预留，不表示系统图片剪贴板已经打通。

### 2. 继续声明 `WRITE_PASTEBOARD`

这会把实现重新带回不兼容状态。

### 3. 在 ArkTS 中大量使用未显式类型化的对象字面量

ArkTS 编译器对这类写法相当敏感；本轮已用显式接口/类实例方式规避。

### 4. 默认假设 NAPI 只会收到 `ArrayBuffer`

实际 ArkTS 侧常会传 `Uint8Array`，bridge 必须兼容两种输入。

## 参考实现位置

### HarmonyOS

- `entry/src/main/ets/service/clipboard/ClipboardSyncConfig.ets`
- `entry/src/main/ets/service/clipboard/ClipboardSyncService.ets`
- `entry/src/main/ets/service/jni/ClipboardBridge.ets`
- `entry/src/main/ets/service/streaming/StreamingSession.ets`
- `entry/src/main/ets/pages/StreamPage.ets`
- `entry/src/main/ets/pages/SettingsPageV2.ets`

### Native

- `nativelib/src/main/cpp/moonlight_bridge.cpp`
- `nativelib/src/main/cpp/callbacks.cpp`
- `nativelib/src/main/cpp/callbacks.h`
- `nativelib/src/main/cpp/napi_init.cpp`
- `nativelib/src/main/cpp/moonlight-common-c`
