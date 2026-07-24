# Audio Haptics SDK — HarmonyOS 集成

## 当前边界

HarmonyOS 客户端直接消费独立仓库
[AlkaidLab/moonlight-audio-haptics](https://github.com/AlkaidLab/moonlight-audio-haptics)
的公共 C ABI。

- 固定提交：`b71b47a08fd400996ed374a97e1bff73bac2932e`
- SDK 版本：`v0.6.0`
- ABI：v1
- 许可证：Apache License 2.0

职责划分：

```text
Opus 解码 PCM
  → SDK AhEngine（DSP、场景创作、Haptic IR）
  → N-API 稀疏帧
  → AudioVibrationService（时间对齐、能力降级、设备/USB 路由）
  → HarmonyOS vibrator / USB 手柄
```

旧 `BassEnergyAnalyzer`、aubio 及其演示实现已从仓库移除，不再进入
`moonlight_nativelib` 构建或驱动振动。需要回看时使用 Git 历史，不保留第二套
运行时实现。

## SDK 获取

本地推荐将两个仓库并列：

```text
StudioProjects/
├─ moonlight-harmonyos/
└─ moonlight-audio-haptics/
```

其他位置可设置：

```powershell
$env:AUDIO_HAPTICS_SDK_DIR = 'D:\src\moonlight-audio-haptics'
```

CI 将 SDK 检出到仓库内忽略目录 `audio-haptics-sdk/`，并固定完整 commit SHA。
CMake 不会联网下载依赖，也不会静默回退到旧分析器；缺少 SDK 时配置阶段直接
失败。

## 生命周期

- 音频初始化：按实际采样率和声道数创建 `AhEngine`。
- 设置更新：通过原子变量发布，在下一个 PCM block 边界应用。
- 停止/后台/断流：立即停止设备和 USB 输出，并重置 SDK 时间线。
- 重新连接：重新创建 Core，不复用上一会话的节奏、连续振动或时间戳状态。
- `STOP` IR：优先执行，不受普通触觉提交节流限制。

## Renderer 策略

- HD Haptic：使用 `VibratorPatternBuilder` 的 transient/continuous 事件。
- 无 HD Haptic：降级到有界的 time vibration，不创建无限持续效果。
- USB 手柄：根据 `lowBandRatio` 分配双马达，并使用 `stereoPan` 做有限空间调制。
- SDK transient 与 continuous 合并成单次平台提交，避免双路振动。
- 以 OHAudio 环形缓冲深度估算呈现等待，并减去保守的执行器提前量；最大等待
  50 ms，`STOP` 不等待。

## 验收状态

代码闭环要求：

- [x] 固定 SDK 提交并由 CI 获取。
- [x] CMake 静态链接 `moonlight::haptics`。
- [x] PCM 仅进入 SDK Core。
- [x] 三类 IR（transient、continuous changed、stop）进入 HarmonyOS Renderer。
- [x] 设备/USB 路由、HD Haptic 降级和生命周期停止已接线。
- [x] aubio/旧分析器从生产构建和运行链路移除。
- [x] Native HAR 与完整 Debug App 在本地 DevEco 工具链构建通过。
- [ ] HarmonyOS 真机确认马达能力、主观同步和持续效果。
- [ ] 至少第二类不同马达能力设备完成回归。

在真机项完成前，可以称为“代码与构建闭环”，不能称为“鸿蒙生产体验验收完成”。
