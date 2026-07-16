# 音频驱动触觉 P3 Shadow 基础报告

> 状态：P3 离线与设备侧工具链完成，产品准入进行中
> 日期：2026-07-15
> SDK 版本：0.3.0
> ABI 版本：1
> 参数集：`game-p3-v1`

## 1. 本阶段结果

P3 第一阶段已经建立可重复的离线 shadow A/B 和真实数据准入边界，仍不改变 HarmonyOS 生产振动输出：

- 所有 DSP 参数集中到版本化的 `dsp_parameters.h`。
- 公共 C ABI 增加 `ah_get_parameter_set_version()`，报表同时记录 SDK 与参数集版本。
- 数据集 manifest 增加 rights、是否可再分发、真实/合成、关键事件、期望触觉、split 和双 SHA-256。
- `validate_dataset.py` 校验路径越界、WAV 格式、采样率/声道/时长、标签排序/数量、rights 和文件 hash。
- `shadow_compare.py` 对 aubio 与 `sdk_core` 做逐事件匹配，输出 matched、reference-only、candidate-only 和时间差。
- 自动计算 aubio 删除门槛，并把“算法通过”和“可删除 aubio”拆成两个结论。
- shadow 结果只包含聚合指标、事件时间戳和 descriptor，不复制原始 PCM。
- HarmonyOS 解码线程已接入同源 PCM 的运行时关闭 shadow；详见 [P3 设备侧 Shadow 报告](./AUDIO_HAPTICS_P3_DEVICE_SHADOW.md)。

## 2. 输出产物

一次 `run_baseline.py --backend all` 现在会生成：

| 文件 | 内容 |
|---|---|
| `baseline.json/csv` | 各用例、各后端标注指标与性能 |
| `<case>/events.csv` | 原始事件级输出 |
| `shadow_events.csv` | aubio 与 sdk_core 的一对一事件差异 |
| `shadow_report.json` | 可供 CI 读取的准入 gate |
| `shadow_report.md` | 人工审核报告 |

合成基准的当前结果：

| 指标 | aubio | sdk_core |
|---|---:|---:|
| 全集聚合 F1 | 0.333333 | 1.000000 |
| 关键事件 recall | 0.750000 | 1.000000 |
| 两类负样本误事件 | 38 | 0 |
| 最差标注用例中位时间误差 | 15 ms | 5 ms |
| 最差标注用例 P95 时间误差 | 15 ms | 5 ms |
| 最差 Host block P99 | 67.600 us | 129.401 us |

事件差异为 12 个 matched、44 个 aubio-only、4 个 sdk-only。4 个 sdk-only 全部来自反相立体声夹具，是 aubio 波形下混抵消造成的漏检；aubio-only 主要来自 kick 重复触发和负样本误触发。两个后端 descriptor 的量纲不同，本阶段不直接计算强度误差，后续必须用主观标注或归一化等级比较。

## 3. Gate 结果

| Gate | 当前结果 |
|---|---|
| F1 不低于 aubio 超过 0.02 | PASS |
| 关键冲击 recall 不下降 | PASS |
| 时间中位数 ≤10 ms | PASS |
| 时间 P95 ≤25 ms | PASS |
| 负样本误触发 ≤ aubio 1.1 倍 | PASS |
| Host block P99 ≤500 us | PASS |
| 存在真实世界标注数据 | BLOCKED |
| 至少两类目标真机 benchmark | BLOCKED |
| 内部体验审核通过 | BLOCKED |
| 回滚路径验证 | BLOCKED |

因此当前机器可读结论为：

```text
algorithm_gates_pass = true
ready_for_aubio_removal = false
```

合成集证明算法和工具链可进入真实验证，不构成删除 aubio 或切换生产输出的授权。

## 4. 真实数据接入

真实 WAV 默认放在仓库外；模板位于：

```text
tools/audio_haptics_eval/datasets/manifest.template.csv
```

接入命令：

```bash
python tools/audio_haptics_eval/validate_dataset.py \
  --manifest <dataset>/manifest.csv \
  --require-real-world

python tools/audio_haptics_eval/run_baseline.py \
  --fixtures-dir <dataset> \
  --manifest <dataset>/manifest.csv \
  --skip-generate \
  --runs 30 \
  --warmup-runs 3
```

建议第一批至少覆盖：游戏强冲击、游戏持续低频、带鼓/无鼓音乐、对话、静音/底噪、反相或多声道、削波/PLC/断流。不能明确说明使用权的素材不得进入 CI 或共享目录。

## 5. 验证结果

| 验证 | 结果 |
|---|---|
| SDK C API / ABI / DSP / license CTest | 4/4 通过 |
| evaluator fixture / smoke / dataset / shadow CTest | 5/5 通过 |
| `--require-real-world` 对纯合成集的阻断测试 | 通过，预期拒绝 |
| 30 次 Host shadow benchmark | 通过 |
| HarmonyOS arm64-v8a | 构建通过，静态库 635,568 bytes |
| HarmonyOS x86_64 | 构建通过，静态库 619,456 bytes |
| HarmonyOS `nativelib.har` | 构建通过，12,377,547 bytes |

## 6. 下一步

P3 后半段不再是继续堆算法，而是补齐真实证据：

1. 准备或指定有使用权的真实数据目录并完成标签。
2. 在内部包开启设备侧 shadow，采集至少两类 ARM 设备的耗时直方图。
3. 跑首轮离线/真机 shadow 报告，按类别检查 false positive/negative，而不是只看总 F1。
4. 根据误差建立 `game-p3-v2`，保持旧参数集可复现，不直接覆盖 v1。
5. 完成盲测体验表与 runtime/compile-time 回滚演练后，才允许进入 P4 Renderer 迁移。
