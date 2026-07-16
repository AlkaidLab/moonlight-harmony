# 音频驱动触觉 P0 基线报告

> 状态：P0 完成
> 日期：2026-07-15
> 基线提交：`a9092a5` 加当前工作区 P0 工具
> 对应方案：`AUDIO_HAPTICS_SDK_IMPLEMENTATION_PLAN.md` 第 9、10 节

## 1. P0 交付结果

已建立可重复运行的主机评测链路：

- Release CMake/Ninja host runner，同时编译当前 aubio 最小集和当前 `SpectralOnsetDetector`。
- PCM16 RIFF WAV 读取、onset 事件 CSV、单文件 JSON 汇总。
- 基于标签的 precision、recall、F1 和输出时间误差。
- 不含初始化/WAV I/O 的 `ProcessFrame` P50/P95/P99/Max 与 realtime factor。
- 六类确定性合成 WAV、标签和 manifest 生成器。
- 一键构建、生成数据、逐用例执行和聚合 CSV/JSON 的脚本。
- CTest fixture 生成与端到端 runner smoke test。

P0 工具仍属于当前 GPLv3 宿主仓库，因为它需要链接 aubio 基线。它不进入后续 Apache-2.0 SDK。

## 2. 复现方式

```bash
python tools/audio_haptics_eval/run_baseline.py
```

输出目录：

```text
tools/audio_haptics_eval/out/
├─ baseline.csv
├─ baseline.json
└─ <case_id>/
   ├─ events.csv
   └─ summary.json
```

运行 smoke test：

```bash
cmake -S tools/audio_haptics_eval \
      -B tools/audio_haptics_eval/build \
      -G Ninja \
      -DCMAKE_BUILD_TYPE=Release
cmake --build tools/audio_haptics_eval/build
ctest --test-dir tools/audio_haptics_eval/build --output-on-failure
```

## 3. 测试环境

| 项目 | 值 |
|---|---|
| OS | Windows NT 10.0.26200.0 |
| CPU | AMD Ryzen 7 7840HS，8C/16T |
| Compiler | MinGW-w64 GCC 13.2.0 |
| CMake | 3.29.2 |
| Ninja | 1.12.0 |
| Python | 3.12.10 |
| Build | Release |
| Audio | PCM16、48 kHz、mono/stereo |
| Hop | 240 samples / 5 ms |
| Benchmark | 3 warmup + 20 measured runs |
| Label match window | ±50 ms |

主机 benchmark 只用于算法迭代回归，不能替代 HarmonyOS/Android 目标真机数据。

## 4. 初始数据集

| Case | Labels | 目的 |
|---|---:|---|
| `impulse_train_mono` | 5 | 宽带瞬态 recall 与输出时间 |
| `kick_train_stereo` | 6 | 低频冲击、重复触发和立体声输入 |
| `antiphase_impulses_stereo` | 4 | 暴露波形下混导致的反相抵消 |
| `silence_then_hit_mono` | 1 | 数字静音后的状态恢复 |
| `steady_tone_stereo` | 0 | 持续低频负样本误触发 |
| `speech_like_mono` | 0 | 语音类负样本误触发 |

所有 fixture 由固定代码和固定随机种子生成，不提交 WAV 二进制。该集合是工程 smoke baseline，不替代上线前需要的授权真实游戏/音乐/语音数据集。

## 5. 首轮结果

### 5.1 事件质量与输出时间

| Case | Backend | Events | F1 | Median abs error | P95 abs error |
|---|---|---:|---:|---:|---:|
| impulse train | aubio | 5 | 1.000 | 15 ms | 15 ms |
| impulse train | native current | 2 | 0.571 | 30 ms | 30 ms |
| kick train | aubio | 12 | 0.667 | 15 ms | 15 ms |
| kick train | native current | 12 | 0.667 | 35 ms | 35 ms |
| antiphase | aubio | 0 | 0.000 | — | — |
| antiphase | native current | 0 | 0.000 | — | — |
| silence then hit | aubio | 1 | 1.000 | 15 ms | 15 ms |
| silence then hit | native current | 1 | 1.000 | 30 ms | 30 ms |
| steady tone（negative） | aubio | 29 false events | 0.000 | — | — |
| steady tone（negative） | native current | 3 false events | 0.000 | — | — |
| speech-like（negative） | aubio | 9 false events | 0.000 | — | — |
| speech-like（negative） | native current | 7 false events | 0.000 | — | — |

说明：timestamp 记录 detector 在 hop 末尾返回 onset 的时刻，因此包含 detector 本身的前视/确认延迟。Kick burst 的余振被两个后端各自重复识别一次，导致每个标注约产生两个事件。

### 5.2 主机性能

| Backend | 跨全部 fixture 的最高 call P99 | 最低 realtime factor |
|---|---:|---:|
| aubio | 66.5 µs | 93.6x |
| native current | 37.6 µs | 179.9x |

两者在该主机上都低于每 5 ms 音频块 0.5 ms 的 P99 预算，native current 约有明显余量。重复测量时观察到 Windows 调度造成的少数毫秒级 `call_max` 离群点，因此 P0 不用单次 max 作为算法 gate；移动端必须重新测 P99 和音频 underrun。

## 6. 基线结论

1. **评测基础设施已可用**：同一 PCM 可以稳定输出 aubio/native 事件、标签分数和调用耗时。
2. **现有 native 不能直接替换 aubio**：普通宽带 impulse 只召回 2/5，说明当前白化/历史谱或 picker 状态存在明显问题。
3. **25 ms 前视问题可被观测**：native current 的输出中位误差为 30～35 ms，aubio 为 15 ms；P2 必须将未来前视压到 0～1 hop。
4. **反相抵消已经被固定用例捕获**：两个后端在 antiphase case 都为 0/4，P2 的 channel-aware magnitude/energy fusion 必须把该用例提升到 4/4。
5. **持续声和语音必须进入产品门控**：aubio 在两个负样本上产生 38 次事件，native current 产生 10 次；仅以“接近 aubio”为目标不足以获得拟真触感。
6. **低频 burst 会产生重复触发**：需要结合 refractory、持续声判定或 transient/body 分离，不能只靠 80 ms MinIOI。

## 7. P1/P2 的明确输入条件

后续实现不得降低以下可观测性：

- 保持 `events.csv` 与 `summary.json` schema version，破坏性修改必须升版本。
- 新 Core 后端必须接入同一个 runner，不能建立不可比较的另一套工具。
- `antiphase_impulses_stereo` 目标 recall 为 1.0。
- `impulse_train_mono` 目标 recall 不低于 aubio 的 1.0，输出 median error 目标不超过 10 ms。
- 两个 negative case 的 false events 必须明显低于当前 aubio 基线，并在真实数据集上复验。
- 性能结果必须同时报告 host 与至少两类目标移动设备，禁止用本报告的桌面数据代替真机 gate。

## 8. 下一步

进入 P1：建立 Apache-2.0 SDK 目录、公共 C ABI 与 `HapticFrame`，同时让新 Core 能作为第三个 backend 接入本评测器。aubio 与 `native_current` 仅保留为基线，不迁入 SDK。
