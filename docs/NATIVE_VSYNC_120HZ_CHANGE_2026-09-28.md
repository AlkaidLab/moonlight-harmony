# 串流前台持续 120Hz 请求：变更说明

日期：2026-09-28

## 背景与验证结果

在部分设备上，串流开始时屏幕可处于 120Hz，但停止触摸约 3 秒后会降至 60Hz。原有串流页面已通过 XComponent 或 DisplaySync，以及 Native DisplaySoloist 请求目标帧率。这些请求仍受系统刷新率与功耗策略约束。

本次增加与 VintagePomeloPro 相同的 NativeVSync **持续请求回调**方式：在前台且串流 Surface 有效时，创建 NativeVSync 对象，设置期望帧率，每次收到回调后继续请求下一帧。用户已在受影响设备上确认，无触摸时屏幕可以保持 120Hz。该结果只确认本次设备与测试配置的实际效果，不代表接口能在所有设备上锁定物理刷新率。

## 请求链路

1. 串流页面在目标帧率高于 60 时仍按原流程设置 XComponent／DisplaySync，并调用 `setFrameRateKeepAlive(true, displayHz)`。Native 层根据显示目标决定是否启用 DisplaySoloist 和新增的 NativeVSync 请求。
2. NativeVSync 只在请求开启、Surface 存在、应用处于前台且显示目标为 61–120Hz 时运行。120Hz 目标使用 `{ min: 60, max: 120, expected: 120 }`；其他支持的目标使用 `{ min: 60, max: 目标, expected: 目标 }`。超过 120Hz 的显示目标继续由 ArkUI 路径处理，不被错误截成 NativeVSync 的 120Hz 请求。
3. NativeVSync 独立线程调用 `OH_NativeVSync_RequestFrame` 并等待回调。没有解码输出或触摸事件时，回调请求仍会继续；它不向 Surface 提交重复视频帧，也不改变原有视频解码、PTS 调度或送显方式。
4. `OH_NativeVSync_SetExpectedFrameRateRange` 是 API 20 接口，使用运行时符号查找。旧系统缺少该接口或设置失败时，新增路径退出，原有 DisplaySoloist 与 ArkUI 请求路径仍可工作。

## 生命周期与资源清理

| 事件 | NativeVSync 行为 |
| --- | --- |
| 串流启动且 Surface 就绪 | 按目标帧率创建请求线程 |
| Surface 移除或串流结束 | 停止请求、唤醒等待线程、`join` 并销毁 NativeVSync 对象 |
| 应用进入后台 | 暂停新增请求线程，避免隐藏页面继续以高频率请求回调 |
| 应用返回前台 | 若串流请求仍开启且 Surface 有效，按原目标重建请求 |
| 目标帧率变化或请求失败后重试 | 停止旧实例，按新目标重建；运行中的同目标实例不重复创建 |

前后台信号沿用 `AppStateService` → `StreamLifecycleManager` → `StreamPage` → NAPI 桥接传递，只控制新增的 NativeVSync 线程。后台串流、DisplaySoloist 和视频送显原有行为未更改。页面注册监听时会同步当前应用状态，避免在后台创建页面或回到页面后沿用过期的前后台标志。

创建或设置失败后的周期重试沿用 `RefreshFrameRateHints`，由后续解码帧的 `SubmitFrame` 触发，约每 2 秒检查一次；完全没有解码输出时不会另起无帧重试计时器。

## 日志与排查

Native 层新增或使用以下日志：

- `NativeVSync request min=... max=... expected=... result=...`：接口是否接受请求；`result=0` 表示设置成功。
- `NativeVSync period=... rate=...Hz`：NativeVSync 报告的周期变化。
- `NativeVSync callbackHz=...`：近 5 秒的回调频率，用于判断请求是否仍收到信号。
- `NativeVSync request stopped`：实例因停止串流、Surface 变化、进入后台或目标变化而结束。
- 串流页原有的 `FrameRateDiagnostics`：接收帧率、提交帧率、当前屏幕档位与 ArkUI 请求路径。

回调频率、视频提交帧率和实际物理上屏率是三个不同指标。判断是否解决自动降到 60Hz，应在同一设备上同时查看系统刷新率叠加层或 RenderService trace，并进行无触摸、触摸恢复、退后台和重连测试。

## 验证

- 使用 HarmonyOS SDK 对 `native_render.cpp`、NAPI 桥接文件进行 C++ 语法编译：通过。
- 现有 `frame_rate_request_test.cpp`：通过。
- DevEco Studio 随附 hvigor 执行 `assembleApp --mode project -p product=default -p buildMode=debug --no-daemon`：通过，Native 与 ArkTS 均编译完成。
- `git diff --check`：通过。
- 受影响设备前台串流、无触摸保持 120Hz：用户已确认。

完整构建仍有仓库原有的 API 可用性、弃用与 `LOG_TAG` 重定义警告，本次构建没有错误。

## 适用范围和后续观察

本次解决的是高刷请求的持续性，没有把视频输出改为 VSync 驱动，也没有改变设备系统的节能策略。持续回调会增加少量周期性工作，需继续观察长时间串流的功耗、温度与后台恢复表现。系统仍可按机型、屏幕模式及功耗策略调整实际刷新率。

本地构建还需要 `entry/src/main/ets/config/DevKeySecret.ets` 和 `GitHubOAuthConfig.ets`。两者有 `.example` 模板，实际文件被 Git 忽略；它们是本地构建配置，不属于这次提交，也不会上传密钥或 OAuth 配置。
