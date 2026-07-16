# 音频驱动触觉 P3 HarmonyOS 设备侧 Shadow 报告

> 状态：设备侧基础设施完成，运行时默认关闭
> 日期：2026-07-15
> SDK：0.3.0 / ABI v1 / `game-p3-v1`

## 1. 接入结论

HarmonyOS 音频解码线程现在可以把同一份解码后 PCM 同时送入：

1. 现有 `BassEnergyAnalyzer`，继续作为唯一生产振动来源。
2. 独立 aubio `specflux` 参考检测器，仅用于 shadow 比较。
3. `sdk_core` 候选检测器，仅生成内存中的统计数据。

`sdk_core` 的 `AhHapticFrame` 不进入 `tsfn_bassEnergy`，不会调用 ArkTS 振动服务，也不会改变现有 intensity、low-frequency ratio 或 stereo balance。shadow 即使发生错误，也只增加 `processErrors`，不影响生产分析器和音频播放。

## 2. 双重开关

编译开关：

```cmake
MOONLIGHT_AUDIO_HAPTICS_SHADOW=ON   # 编译能力，当前默认
MOONLIGHT_AUDIO_HAPTICS_SHADOW=OFF  # 完全编译关闭
```

运行时开关位于 `StreamingSession.ets`：

```ts
const ENABLE_AUDIO_HAPTICS_SHADOW: boolean = false;
```

生产包必须保持 `false`。内部验证包将它改为 `true` 后，第四个 N-API 参数会开启 shadow：

```ts
setBassVibrationConfig(enabled, sensitivity, sceneMode, shadowEnabled)
```

前三个参数的旧调用完全兼容；省略第四个参数时原生层强制使用 `false`。每次从关闭切到开启都会在音频线程重置检测器、事件队列和统计，控制线程不直接修改 DSP 状态。

## 3. 在线比较

设备侧使用固定容量 16-event 队列，以 50 ms 窗口贪心匹配 aubio 与 SDK 事件，输出以下聚合字段：

- 输入 block/frame 数。
- aubio 与 SDK 瞬态总数。
- matched、aubio-only、sdk-only。
- 待匹配事件数。
- 匹配时间差总和与最大绝对差。
- 处理错误数。
- 总/最大 shadow 处理耗时。
- `≤50/100/200/500/1000 μs` 和 `>1000 μs` 固定直方图。

处理路径没有日志拼接、文件 I/O 或逐帧 heap allocation。每约 1 秒由已有音频诊断窗口读取原子快照并输出两条 `[HAPTICS_SHADOW]` HiLog。

## 4. 隐私边界

设备侧不保存、不上传、不打印：

- 原始 PCM 或频谱。
- 游戏、音乐或语音内容。
- 可还原内容的逐采样特征。

日志只包含计数、时间差和耗时桶。若后续增加 telemetry，仍只能使用这些聚合字段，并必须遵守现有隐私策略和用户授权。

## 5. 验证结果

| 验证 | 结果 |
|---|---|
| 设备侧 shadow Host 单测 | 通过 |
| 反相立体声：aubio 0 / SDK 4 | 通过，正确记录 4 个 sdk-only |
| 运行时关闭后不再消费 block | 通过 |
| 编译开关 `=0` stub | 通过 |
| evaluator 全套 CTest | 7/7 通过 |
| HarmonyOS arm64-v8a/x86_64 HAR | 通过 |
| Entry ArkTS 编译 | 通过 |
| Debug HAP 打包与签名 | 通过 |

首次 HAP 打包因 shell 中没有 `java` 报 `spawn java ENOENT`；设置 DevEco Studio JBR 为 `JAVA_HOME` 后构建成功，确认与代码无关。

## 6. 真机采集步骤

1. 仅在内部验证分支把 `ENABLE_AUDIO_HAPTICS_SHADOW` 改为 `true`。
2. 构建并安装 Debug HAP，确认初始化日志显示 `compiled=true ready=true`。
3. 分别运行强冲击、持续低频、音乐、对话、静音/底噪和断流重连场景。
4. 过滤 `[HAPTICS_SHADOW]`，保存设备型号、系统版本、场景时长和参数集版本。
5. 检查 `errors=0`，并从直方图计算 P99；不能只使用单次 max。
6. 测试结束立即恢复运行时常量为 `false`。需要硬回滚时再将 CMake 开关设为 `OFF`。

设备侧 shadow 已具备采集条件，但尚未在实体 ARM 设备执行，因此“两类目标设备 benchmark”和“内部体验审核”仍保持 BLOCKED。
