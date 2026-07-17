# 音频驱动触觉 P1 SDK 基础报告

> 状态：P1 完成
> 日期：2026-07-15
> SDK 版本：0.1.0
> ABI 版本：1
> 许可证：Apache License 2.0
> 迁移说明：本文记录 P1 当时的仓库内路径；SDK 已于 2026-07-17 迁移到 [独立仓库](https://github.com/AlkaidLab/moonlight-audio-haptics)，当前发布基线为 `v0.5.14`。

## 1. P1 交付结果

已在仓库顶层建立独立 `audio-haptics-sdk`：

- Apache-2.0 `LICENSE`、SPDX 文件头和第三方依赖清单。
- 可被 C11、C++17、HarmonyOS BiSheng 和 Android NDK 使用的公共 C ABI。
- 80-byte 固定 `AhHapticFrame` v1 中间表示。
- Engine 创建、配置更新、输入容量计算、PCM 消费、reset 和 destroy 生命周期。
- 初始化后处理路径零 heap allocation、无锁、无回调、无日志和无平台 API。
- C API 行为测试、C++ ABI layout 测试和许可证边界测试。
- P0 evaluator 的 `sdk_core_p1` 第三后端。
- HarmonyOS `nativelib` 静态链接与 arm64-v8a/x86_64 构建验证。

P1 Core 故意不产生触觉事件。它只验证 SDK 边界和生命周期；共享特征、PCEN 与因果 onset 在 P2 实现。

## 2. 公共 ABI

公共入口位于：

```text
audio-haptics-sdk/include/moonlight_haptics/
├─ audio_haptics.h
└─ version.h
```

v1 提供：

```text
ah_config_init
ah_create
ah_update_config
ah_get_max_output_frames
ah_process_i16
ah_reset
ah_destroy
ah_get_abi_version
ah_get_version_string
ah_status_string
```

关键决定：

- `AhStatus`、`AhScene`、`AhFrameFlags` 均为明确的 32-bit 类型，不依赖编译器 enum 尺寸。
- `AhHapticFrame` v1 固定 80 bytes，时间戳偏移 8，幅度区偏移 16，场景偏移 44，reserved 偏移 48。
- IR 是数组输出，因此不能在后续版本简单追加结构字段并改变元素步长。小版本消耗 8 个 reserved 字段；更大结构必须新增 API/ABI。
- `AhConfig` 的 sample rate/channel count 不允许运行时变化，变化返回 `AH_STATUS_RECREATE_REQUIRED`。
- 一次 PCM 可能跨越多个 hop；调用方用 `ah_get_max_output_frames()` 预分配固定输出数组。
- 输出空间不足时不消费 PCM，便于宿主无损重试。

## 3. 线程与内存模型

- `ah_create()` 是唯一允许的 Engine heap allocation。
- `ah_process_i16()` 由单一音频线程调用。
- sensitivity、gain、scene 和 feature flags 使用 lock-free 32-bit atomic 存储，可由控制线程更新。
- `reset/destroy` 由宿主保证不与 `process` 并发。
- Core 不创建线程，也不依赖 N-API、JNI、HarmonyOS 或 Android 头文件。

P2 增加 ring buffer/FFT scratch 时必须在 `ah_create()` 一次性完成固定容量分配，并保持处理路径零分配。

## 4. 构建接入

### 4.1 独立 host

```bash
cmake -S audio-haptics-sdk \
      -B audio-haptics-sdk/build \
      -G Ninja \
      -DCMAKE_BUILD_TYPE=Release
cmake --build audio-haptics-sdk/build
ctest --test-dir audio-haptics-sdk/build --output-on-failure
```

### 4.2 P0 evaluator

Evaluator 通过 `moonlight::haptics` 链接 SDK，并提供 `sdk_core_p1` backend：

```bash
python tools/audio_haptics_eval/run_baseline.py --backend all
```

P1 backend 在所有 fixture 上应为零事件。这是预期行为，不是算法分数；P2 将在该 backend 内产生第一批可比较 IR。

### 4.3 HarmonyOS

`nativelib/src/main/cpp/CMakeLists.txt` 通过 `add_subdirectory` 和静态链接消费同一 Core。生产 `BassEnergyAnalyzer` 未切换，也没有新增运行时回调。

验证产物：

| ABI | Core static library | 本次 Debug 大小 |
|---|---|---:|
| arm64-v8a | `libmoonlight_haptics_core.a` | 66,732 bytes |
| x86_64 | `libmoonlight_haptics_core.a` | 65,788 bytes |

`nativelib.har` 已成功生成；大小 12,377,581 bytes。静态库目前没有被生产代码引用，最终链接器可移除未使用对象，因此该数字不代表发布包净增量。

## 5. 验证结果

| 验证 | 结果 |
|---|---|
| SDK Release configure/build | 通过 |
| C11 API lifecycle test | 通过 |
| C++17 ABI/layout test | 通过 |
| Apache-2.0 license boundary test | 通过 |
| P0 evaluator build | 通过 |
| Evaluator fixture + end-to-end smoke | 通过 |
| 六类 fixture 的 `sdk_core_p1` backend | 通过，预期零事件 |
| HarmonyOS arm64-v8a native build | 通过 |
| HarmonyOS x86_64 native build | 通过 |
| HarmonyOS debug HAR package | 通过，24.752 s |

Harmony 构建只有项目已有的 N-API `.d.ts` 验证警告，与 SDK Core 无关。

## 6. 许可证边界

- SDK 目录内不包含或链接 aubio/GPL 源码。
- SDK P1 没有第三方 runtime 源码或二进制依赖。
- CMake 测试会扫描 SDK C/C++/Python/CMake 文件的 Apache-2.0 SPDX，并拒绝 aubio include、GPL/AGPL 标记。
- P0 evaluator 继续为 GPL，因为它同时链接 aubio 基线；其中的 adapter 只通过 SDK 公共 C ABI 调用 Core。
- 引入 FFT、模型或 runtime 前必须更新 `THIRD_PARTY_NOTICES.md` 并通过许可证准入。

## 7. P2 入口条件

P2 在不改变 ABI v1 的前提下实现：

1. 固定容量多声道 PCM ring buffer。
2. channel-aware 能量融合，先让 antiphase fixture 从 0/4 提升到 4/4。
3. 共享 Hann/STFT 特征层和预分配 scratch。
4. PCEN/自适应归一化。
5. 0～1 hop 因果 onset picker。
6. transient amplitude、sharpness、confidence 和 timestamp 输出。
7. `sdk_core_p1` backend 更名为稳定的 `sdk_core`，开始纳入 P0 质量对比。

P2 完成前不接管 HarmonyOS 正式振动输出。
