# 鸿蒙剪贴板同步集成指南

> 本文档描述的是当前仓库中**已经实现并通过构建验证**的 HarmonyOS 集成方式。
> 当前状态是：**文本剪贴板同步已闭环，图片剪贴板同步暂时降级。**

## 目录结构

```text
entry/src/main/ets/
  ├── pages/
  │   ├── StreamPage.ets
  │   └── SettingsPageV2.ets
  ├── service/
  │   ├── SettingsService.ets
  │   ├── clipboard/
  │   │   ├── ClipboardSyncConfig.ets
  │   │   └── ClipboardSyncService.ets
  │   ├── jni/
  │   │   └── ClipboardBridge.ets
  │   └── streaming/
  │       ├── MoonBridge.ets
  │       └── StreamingSession.ets
```

## 1. 导入模块

```ts
import { ClipboardSyncConfig } from '../service/clipboard/ClipboardSyncConfig'
import { ClipboardSyncObserver, ClipboardSyncService } from '../service/clipboard/ClipboardSyncService'
```

说明：

- `ClipboardBridge.ets` 由服务内部和 streaming callback 使用
- 页面层通常只需要 `ClipboardSyncConfig` 与 `ClipboardSyncService`

## 2. 在串流页面启动服务

当前仓库在 `StreamPage.ets` 中处理生命周期。

关键流程：

1. 串流连接建立成功后读取用户设置
2. 若文本/图片任一开关开启，则创建 `ClipboardSyncConfig`
3. 实例化 `ClipboardSyncService`
4. 在 observer 中把错误提示转给 `ToastQueue`
5. 页面退出或连接断开时 `stop()`

示意代码：

```ts
const clipboardConfig = new ClipboardSyncConfig()
clipboardConfig.enableSyncText = enableClipboardSyncText
clipboardConfig.enableSyncImage = enableClipboardSyncImage

class StreamClipboardObserver implements ClipboardSyncObserver {
  onError(error: string): void {
    ToastQueue.show({ message: `剪贴板同步错误: ${error}`, duration: 2000 })
  }
}

this.clipboardSyncService = new ClipboardSyncService(
  clipboardConfig,
  new StreamClipboardObserver()
)
this.clipboardSyncService.start()
```

## 3. 设置页接入

当前仓库在 `SettingsPageV2.ets` 中增加“剪贴板同步”分组，并使用 `SettingsKeys` 统一读写：

- `SettingsKeys.ENABLE_CLIPBOARD_SYNC_TEXT`
- `SettingsKeys.ENABLE_CLIPBOARD_SYNC_IMAGE`

建议文案含义：

- **文本同步**：真正生效
- **图片同步**：保留入口，但当前兼容 SDK 下会降级提示暂不支持

## 4. 系统剪贴板 API

当前仓库使用 `@kit.BasicServicesKit` 中已验证可编译的文本接口：

### 读取文本

```ts
const sysBoard = pasteboard.getSystemPasteboard()
const pasteData = await sysBoard.getData()
const text = pasteData.getPrimaryText()
```

### 写入文本

```ts
const sysBoard = pasteboard.getSystemPasteboard()
const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
sysBoard.setDataSync(pasteData)
```

### 监听变化

```ts
const listener = (): void => {
  void this.onPasteboardChanged()
}
sysBoard.on('update', listener)
sysBoard.off('update', listener)
```

## 5. 权限配置

### `module.json5`

当前仅保留：

```json5
{
  "name": "ohos.permission.READ_PASTEBOARD",
  "reason": "$string:permission_read_pasteboard_reason",
  "usedScene": {
    "abilities": ["EntryAbility"],
    "when": "inuse"
  }
}
```

说明：

- 当前兼容 SDK 下不应继续声明 `WRITE_PASTEBOARD`
- 权限 `reason` 需要走资源字符串，不能直接写死不受支持格式

## 6. Native 层适配

当前 native 层已经完成以下适配：

### 发送路径

- ArkTS 构建完整 wire frame
- `ClipboardBridge.MoonBridge.sendClipboardData(frame)` 调用 native
- native `MoonBridge_SendClipboardData(...)` 接受 `ArrayBuffer` / `TypedArray`
- 继续调用 `LiSendClipboardData(...)`

### 接收路径

- `moonlight-common-c` 收到 `0x5508`
- `ListenerCallbacks.clipboardData` 被触发
- `callbacks.cpp` 解析 frame 后通过 `napi_threadsafe_function` 回到 ArkTS
- `StreamingSession.ets` 把回调转发给 `ClipboardBridge.MoonBridge.onClipboardDataReceived(...)`
- `ClipboardSyncService.ets` 最终消费 `kind/token/payload`

## 7. 图片同步当前策略

当前不是“没做”，而是“显式保守处理”：

- 设置页保留图片同步入口
- 协议仍识别 PNG kind
- 本地或远端一旦进入图片分支，只提示一次不支持
- 不调用未验证图片剪贴板 API

这样做的好处是：

- 构建稳定
- 行为明确
- 未来恢复图片同步时，不需要重新设计协议和 UI

## 8. 建议的人工验证步骤

### 基础检查

- [ ] 设置页能看到文本/图片同步两个开关
- [ ] 启动串流后日志显示 clipboard sync start
- [ ] 退出串流后服务停止

### 文本同步

- [ ] 本地复制文本 → 主机端有反应
- [ ] 主机复制文本 → 设备本地系统剪贴板更新
- [ ] 关闭文本同步后不再收发文本

### 图片同步降级

- [ ] 打开图片同步后，仅出现一次降级提示
- [ ] 收到主机 PNG 时不会崩溃、不会写入错误数据

## 9. 当前已知限制

1. 仅 Sunshine 支持该协议扩展
2. 兼容 SDK 下图片剪贴板 API 仍待后续验证
3. 大 payload 仍受单帧大小限制
4. 本轮验证以编译通过和代码闭环为主，不含真机端到端专项回归
