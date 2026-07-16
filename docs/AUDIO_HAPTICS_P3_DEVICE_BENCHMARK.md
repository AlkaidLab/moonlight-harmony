# 音频振动 P3 真机采集与准入

> 状态：工具链完成，等待实体设备采集
> 日期：2026-07-15
> SDK：0.3.0 / ABI v1 / `game-p3-v1`

## 目标

本阶段验证 SDK 候选算法在 HarmonyOS 真机音频线程上的稳定性和实时性，不改变现有
`BassEnergyAnalyzer` 的生产振动输出。设备端只输出累计计数和固定耗时直方图，不保存
PCM、频谱或可还原内容的特征。

准入报告默认要求：

- 至少两台、两类目标设备；
- 每类设备都覆盖强瞬态游戏、持续低频、音乐、语音、静音底噪、断流重连六类场景；
- 每次采集 `errors=0`，直方图计数与 block 数一致；
- 由固定直方图推导的处理耗时 P99 桶上界不超过 500 微秒；
- 所有输入都标记为真实设备数据，合成日志只能用于测试工具本身。

## 准备内部验证包

仅在内部验证构建中把
`entry/src/main/ets/service/streaming/StreamingSession.ets` 的
`ENABLE_AUDIO_HAPTICS_SHADOW` 改为 `true`，构建并安装 Debug HAP。生产构建必须保持
`false`；需要硬回滚时把 CMake 的 `MOONLIGHT_AUDIO_HAPTICS_SHADOW` 设为 `OFF`。

设备连接后先确认：

```powershell
& "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" list targets
```

## 单场景采集

从 `tools/audio_haptics_eval` 目录执行，开始命令后立即在设备上运行对应场景：

```powershell
python capture_device_shadow.py `
  --output-dir out/device `
  --device-class phone_performance `
  --scenario-id game-combat-01 `
  --scenario-category game_strong_transient `
  --duration-seconds 60
```

工具会自动发现单台 HDC 设备、读取型号/系统/ABI、对序列号做 SHA-256 截断哈希，并输出：

- `shadow.hilog`：仅保留 `[HAPTICS_SHADOW]` 聚合日志；
- `metadata.json`：设备类别、场景、SDK 与参数集版本；
- `device_shadow_summary.json/.md`：单次采集指标与门禁结果。

若连接多台设备，增加 `--serial <HDC-target>`。原始序列号不会写入产物。每个场景建议
连续运行至少 60 秒；断流重连场景应包含至少三次断开与恢复。

## 汇总准入

完成两类设备的六类场景后执行：

```powershell
python device_shadow_gate.py out/device --output-dir out/device-admission
```

输出 `device_shadow_admission.json/.md`。P99 根据累计直方图保守计算；单次 `maxUs` 只作
诊断，不能代替 P99。单场景指标使用采集窗口首尾累计快照的差值，因此不会把前一个
场景混进当前场景；新增的累计 `totalUs` 用于精确计算窗口平均耗时。若 P99 落入开放的
`>1000` 微秒桶，会直接阻断而不是伪造上界。

工程门禁通过后，仍需完成内部体验审核和旧算法回滚演练，才能解除 aubio 替换项目的
最终 BLOCKED 状态。
