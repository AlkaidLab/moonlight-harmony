# 音频振动 SDK Android 真机基准

> 状态：第一台 Android 真机 SDK Core 基线与混合 DSP 门禁通过
> 日期：2026-07-16
> SDK：0.3.0 `game-p3-v1` 基线；0.5.14 `action-rpg-p4g-v4` 当前版本；ABI v1 不变

## 结论

在魅族 17（Android 13 / API 33 / arm64-v8a）上，SDK Core 完成五种确定性负载、每种
10 秒的连续离线压测。`0.5.14 / action-rpg-p4g-v4` 所有 `ah_process_i16()` 调用均无错误，
P99 最高 274.270 微秒，低于 500 微秒门槛；最低实时倍数为 22.5x。Android arm64 第一类
设备的 CPU 性能
门禁通过。

| 场景 | Mean | P95 | P99 | Max | 实时倍数 | 错误 |
|---|---:|---:|---:|---:|---:|---:|
| 静音底噪 | 136.977 µs | 140.469 µs | 170.521 µs | 435.625 µs | 36.4x | 0 |
| 持续低频 | 202.411 µs | 211.458 µs | 253.489 µs | 483.542 µs | 24.7x | 0 |
| 游戏强瞬态 | 141.508 µs | 171.042 µs | 198.021 µs | 436.771 µs | 35.2x | 0 |
| 音乐型混合 | 221.387 µs | 227.605 µs | 274.270 µs | 490.833 µs | 22.5x | 0 |
| 语音型调制 | 221.401 µs | 227.084 µs | 274.115 µs | 513.959 µs | 22.5x | 0 |

压测前后电池温度均为 28.7℃。构建使用 NDK 28.2.13676358，运行二进制及报告
均记录 SHA-256；设备序列号只保留 12 位 SHA-256 截断哈希。

相对早期基线，trailing time median、frequency median 与 previous-spectrum maximum filter
显著增加了固定计算量；当前最慢内容仍有 22.5x 实时余量且 P99 通过移动端单会话 gate。
Sunshine 多会话部署前需另做并发预算，不能直接用本次单会话结论外推。

### 0.4.0 混合 DSP 回归

加入 AOSP HapticGenerator 风格执行器包络并与 PCEN/Spectral Flux 混合判定后，在同一
魅族 17 上按相同的 48 kHz、双声道、240-frame block 和五种负载各 10 秒复测：

| 场景 | Mean | P95 | P99 | Max | 实时倍数 | 错误 |
|---|---:|---:|---:|---:|---:|---:|
| 静音底噪 | 102.792 µs | 102.812 µs | 129.010 µs | 414.687 µs | 48.5x | 0 |
| 持续低频 | 104.470 µs | 104.687 µs | 132.656 µs | 380.521 µs | 47.7x | 0 |
| 游戏强瞬态 | 103.896 µs | 104.584 µs | 130.729 µs | 395.573 µs | 48.0x | 0 |
| 音乐型混合 | 106.172 µs | 106.458 µs | 135.000 µs | 379.635 µs | 46.9x | 0 |
| 语音型调制 | 105.920 µs | 106.302 µs | 133.229 µs | 381.146 µs | 47.0x | 0 |

新增每采样滤波、partial AGC 和非线性使均值相对 0.3.0 基线上升约 1.6～1.9 倍，但最高
P99 最高为 135.000 微秒，低于 500 微秒门槛，且五种负载均为零错误。混合 DSP 的
Android arm64 CPU gate 通过；OPPO PKJ110 当时不在 ADB 在线列表，仍需补第二类设备
和真实串流 App 线程 P99。正式报告保存在
`tools/audio_haptics_android_bench/out/hybrid_hg_p4_v1/`（该目录按约定不纳入版本控制）。

## 已验证范围

- SDK 公共 C ABI 可被 Android NDK arm64 程序直接链接和调用；
- 48kHz、双声道、240-frame block 的处理耗时和长循环稳定性；
- 静音、持续低频、强瞬态、音乐型与语音型输入下的不同输出分支；
- P50/P95/P99/max、错误数、输出数、实时倍数和温度元数据的自动采集。

## 尚未替代的门禁

本结果不能替代：

- 真实游戏、音乐和语音数据集上的事件准确率与拟真度；
- Android App 实际解码音频线程的调度、负载竞争和 shadow 对比；
- Android 机型的振动器映射与主观体验审核；
- HarmonyOS 设备的音频线程性能及马达体验复核。

因此 aubio 移除总门禁仍保持 BLOCKED，但“Android arm64 SDK Core 实时性”子门禁已经
解除。

真实远端主机音乐串流的 Android 解码线程 shadow 已于同日完成首轮采集。SDK-only
`-O2` 后 mean 为 400 微秒、P99 桶上界为 1000 微秒、错误为零；它满足 5ms block 的
硬实时预算，但未达到 500 微秒目标门槛，因此 App 音频线程子门禁仍为 BLOCKED。

## Android 本地闭环首轮验证

2026-07-15 在同一魅族 17 上安装 SDK-output Debug APK，完成以下真实串流链路：

```text
远端主机音频
  → Android Opus 解码 PCM
  → GPL 宿主薄 C ABI 接线
  → AAR libmoonlight_haptics_android.so / moonlight-haptics-core
  → AAR native SPSC HapticFrame 队列
  → PCM critical 外通知 NativeHapticsSession
  → 私有线程批量 drain / AudioVibrationService 产品策略
  → AndroidHapticRenderer
  → Android vibrator_manager
```

构建同时开启：

```text
enableAudioHapticsShadow=true
enableAudioHapticsOutput=true
```

SDK output 开启时，旧 `BassEnergyAnalyzer` 只保留 shadow 对比，不再驱动 Renderer，避免双路振动。默认关闭 APK 与 SDK-output APK 均完成 native、Kotlin、R8 和 APK 打包。

系统证据：

- `MUSIC` 场景：`vibrator_manager` 记录到应用 UID 发出的 `USAGE_MEDIA` 单次波形，首轮样本时长 54/57 ms、幅度约 0.67/0.75，无 repeat；音乐连续底座已在 Renderer 抑制。
- `GAME` 场景：记录到 repeat continuous waveform，以及 transient + continuous 组合波形；连续更新增加 100 ms 限流和 0.08 幅度滞回，transient 保持低延迟抢占。
- 会话被强制结束后，`mCurrentVibration` 和 `mNextVibration` 均为 `null`；测试配置随后恢复为 `MUSIC`。
- 串流初始稳定段 `ah_process_i16()` mean 约 61～65 µs、错误为 0；该数据来自 Debug 集成观察，不替代 Release 精确 P99 gate。

因此“SDK IR 能驱动 Android 真实马达”的功能子门禁已解除。以下 P4-A 门禁仍为 BLOCKED：

- 用户手持主观确认同步性、拟真度、疲劳感与强度；
- 设置关闭、正常退出、切后台、断流、重连的完整生命周期矩阵；
- 30 分钟连续串流稳定性；
- Release/等效优化构建的精确 P50/P95/P99；
- 第二类 Android 振动能力设备的降级验证。

### AAR native 边界收口后的回归状态

首轮马达证据之后，同日完成了 native 边界重构：`AhEngine`、固定容量 IR 队列、
`STOP` 饱和优先级、丢帧计数和批量 JNI drain 已移入 Apache-2.0 AAR；GPL 宿主删除了
重复 `AudioHapticsOutputFrame` 与逐帧十参数 JNI callback，只注册 opaque session
handle。重新启用 output 或音频重连时，Engine 由音频生产线程重建；会话 IR 时间戳
跨重建保持单调，避免 Renderer stop 后 continuous 状态不再重发或新帧被误判为过期。
native drain 与 Android Renderer 两层均增加同步 stop fence，防止后台/退出时已经取出的
旧 batch 在 cancel 后再次补触发马达。

重构后已完成：

- AAR 三 ABI Release 构建、单测、lint、Prefab/AAR 打包；
- 默认关闭、output-only、shadow+output 三种宿主 APK 的 native、Kotlin、R8 和打包；
- output-only APK 在魅族 17 覆盖安装与冷启动，无 linker/JNI/AndroidRuntime 崩溃；
- APK 同时包含 arm64 `libmoonlight-core.so` 和
  `libmoonlight_haptics_android.so`，宿主通过 `dlopen` 公共 C ABI 接线，不形成私有
  C++ ABI 依赖；
- 解锁设备并允许 USB 测试安装后，AAR instrumentation 1/1 通过，覆盖 native `.so`
  加载、`NativeHapticsSession` 创建/场景/stop/close 和 `AndroidHapticRenderer`
  stop/close；
- 重构后的 output-only APK 完成真实音乐串流回归：AAR C ABI 解析为
  `resolved=true`，系统在 16:34:33.999 和 16:34:39.056 记录应用 UID 的 `MEDIA`
  单次脉冲；两次均约 55 ms、幅度约 0.70、`repeat=-1`，符合 `MUSIC transient`，
  且没有 linker/JNI/AndroidRuntime 异常；
- 音乐串流中触发 HOME 后，Flyme 将 `Game` 退到后台并回到应用列表；5 秒后系统
  `mCurrentVibration` 与 `mNextVibration` 均为 `null`，未观察到旧 batch 补振或崩溃，
  新增的双层同步 stop fence 通过本轮后台验证；
- 重新进入同一音乐串流后，新 `Game` 于 16:39:41 创建，native audio 在 389 ms 内
  连接完成；16:39～16:40 的系统历史保留 27 次新 `MEDIA` transient，幅度范围
  0.655～0.714、时长 53～56 ms，全部 `repeat=-1`。这证明新会话 Engine/队列在 stop
  后成功重建，单调时间戳没有把新帧误判为过期；期间无 native/JNI 运行时异常。

新的 AAR native 边界已通过 `MUSIC`、后台 stop、设置关闭/恢复、正常退出、网络断流 stop
和手动重新进入功能回归；`GAME` Core 首轮已经实现但仍需真机体验，客户端自动重连也仍是
连接层待办。30 分钟长稳由用户在 2026-07-16 明确后置，不能把短时回归代替发布稳定性结论。

## 0.5.0 Real-Time PLP 节奏时钟回归

`0.5.0 / rtplp-hg-p5-v1` 在现有 PCEN/Spectral Flux 与 AOSP
HapticGenerator 双支路之后加入固定容量、零前瞻的因果节奏时钟。时钟覆盖
60～180 BPM；至少需要六个强瞬态才能建立锁定；预测拍必须同时存在当前弱声学证据，
并避开 50 ms 内已输出的 onset；无弱证据约 2 秒后解锁。ABI v1 结构仍为 80 字节，
仅新增向后兼容的 `AH_FRAME_RHYTHM_PREDICTED` 位。

Host Release 新增 72/90/120/160 BPM 锁定、120→90 BPM 变速、静音解锁、非周期
误锁、弱拍补强和 onset 去重测试，连同 C API、ABI、DSP 与许可证检查共 5/5 通过。
Android SDK 单测、lint、三 ABI Release AAR，以及宿主 App Debug 单测、lint 和 APK
构建通过。

2026-07-15 在魅族 17（Android 13 / API 33 / arm64-v8a）复跑五类负载，每类 10 秒：

| 场景 | Mean | P95 | P99 | Max | 实时倍数 | 错误 |
|---|---:|---:|---:|---:|---:|---:|
| 静音底噪 | 103.010 us | 102.917 us | 129.114 us | 248.333 us | 48.4x | 0 |
| 持续低频 | 104.682 us | 104.844 us | 131.875 us | 261.250 us | 47.6x | 0 |
| 游戏强瞬态 | 104.239 us | 104.896 us | 132.187 us | 474.583 us | 47.8x | 0 |
| 音乐型混合 | 106.468 us | 106.771 us | 135.990 us | 365.729 us | 46.8x | 0 |
| 语音型调制 | 106.156 us | 106.511 us | 134.896 us | 389.531 us | 46.9x | 0 |

五类 P99 均低于 500 us 门槛；新增时钟相对 `hybrid-hg-p4-v1` 的 music P99
没有显著回退（135.000 → 135.990 us）。最终源码对应的报告位于
`tools/audio_haptics_android_bench/out/rtplp_hg_p5_v1_final/`。CPU 门禁通过不代替真实
串流中的主观同步、补点量与疲劳感审核。

## 0.5.1 节奏补拍门控优化

真机 `0.5.0 / rtplp-hg-p5-v1` 的系统历史显示 55.38 秒内有 51 次 MEDIA
振动，但 28/50 个事件间隔大于 800 ms，且没有出现 Android 为 PLP 补拍预设的
32～38 ms 波形。根因不是 onset 总数下降，而是节奏特征启动瞬态污染局部相干度，
加上只允许“跨零后的 20 ms 证据窗”，导致真实音乐中补拍门控没有放行。

`0.5.1 / rtplp-hg-p5-v2` 做了以下修正：

- 节奏特征增加 750 ms 预热，不影响原 onset 输出；
- 强证据累计从依赖阈值回落改为 onset/局部攻击加 60 ms 冷却；
- 建立锁定所需强事件从 6 个降为 5 个，锁定/补拍置信门槛分别降至 0.58/0.50；
- 弱声学证据阈值降至 0.08，因果支持窗扩大至 40 ms；
- 弱证据进入拍点相位窗时立即补拍，不再等待相位跨零，每周期最多一次；
- ONE_SHOT 补拍最低幅度提高到 0.70，时长提高到 36～42 ms；
- ABI 结构大小不变，`reserved[0..2]` 承载 BPM、节奏置信度和相位诊断；Android
  每 5 秒只在非音频线程记录 transient/predicted 聚合计数。

Host Release 5/5、Android SDK 单测/lint/三 ABI AAR、宿主单测/lint/APK 均通过。
魅族 17 最终 ARM 门禁结果：

| 场景 | Mean | P95 | P99 | Max | 实时倍数 | 错误 |
|---|---:|---:|---:|---:|---:|---:|
| 静音底噪 | 103.328 us | 102.969 us | 131.980 us | 1317.395 us | 48.2x | 0 |
| 持续低频 | 104.975 us | 105.000 us | 133.906 us | 1413.542 us | 47.5x | 0 |
| 游戏强瞬态 | 104.622 us | 105.000 us | 134.583 us | 1425.833 us | 47.6x | 0 |
| 音乐型混合 | 106.699 us | 106.719 us | 138.177 us | 1566.146 us | 46.7x | 0 |
| 语音型调制 | 106.377 us | 106.458 us | 137.084 us | 1532.396 us | 46.8x | 0 |

正式报告位于 `tools/audio_haptics_android_bench/out/rtplp_hg_p5_v2/`。

## 0.5.2 低频优先节奏激活与可观测性

真实串流中 `0.5.1 / rtplp-hg-p5-v2` 的 BPM 始终为 0、置信度只有 12%～28%，
且没有 predicted 事件；体感改善主要来自当轮网络/音频时序更稳定，并非 PLP 已经补拍。
代码审查确认节奏钟把任何全频 onset 都直接抬到至少 0.6，容易让人声、镲片和普通瞬态
污染候选速度。

`0.5.2 / rtplp-lowband-p5-v3` 将职责重新拆分：

- 新增无分配、无前视的 `RhythmActivationExtractor`，低频 PCEN flux 与 AOSP 风格
  tactile envelope 是主要证据，中高频 novelty 只作辅助；
- “推动锁拍的强证据”和“防止同一 onset 重复补拍”分成两个信号；高频 onset 仍能抑制
  重复预测，但不能独立增加锁拍事件数；
- `CausalRhythmClock` 只负责候选速度、锁定、相位、变速与补拍门控，不再计算音频特征；
- ABI v1 结构大小保持 80 bytes，`reserved[0..5]` 增加候选 BPM、locked、activation
  和 low-frequency support；Android 每 5 秒聚合输出这些诊断；
- Android Renderer 的幅度、时长和 predicted 策略保持 `0.5.1` 不变，使下一轮体感差异
  可归因于节奏证据与锁拍，而不是马达强度变化；
- 回归覆盖 72/90/120/160 BPM、120→90 变速、弱拍补偿、静音解锁、非周期事件、
  低频鼓点叠加周期性镲片，以及纯高频非周期瞬态不能锁拍。

Host Release 5/5、Android SDK 单测/lint/三 ABI AAR、宿主单测/lint/APK 均通过。
魅族 17 ARM 门禁结果：

| 场景 | Mean | P95 | P99 | Max | 实时倍数 | 错误 |
|---|---:|---:|---:|---:|---:|---:|
| 静音底噪 | 103.082 us | 103.020 us | 129.740 us | 371.979 us | 48.3x | 0 |
| 持续低频 | 104.699 us | 104.896 us | 131.146 us | 328.698 us | 47.6x | 0 |
| 游戏强瞬态 | 104.250 us | 104.896 us | 131.615 us | 415.156 us | 47.8x | 0 |
| 音乐型混合 | 106.470 us | 106.667 us | 136.094 us | 397.656 us | 46.8x | 0 |
| 语音型调制 | 106.156 us | 106.510 us | 134.948 us | 394.114 us | 46.9x | 0 |

正式报告位于 `tools/audio_haptics_android_bench/out/rtplp_lowband_p5_v3/`。CPU 门禁不
替代真实音乐的候选 BPM、锁定耗时、补拍量、同步性和误触发审核。

## 0.5.3 倍频候选族与 Tactus 稳定器

真实串流中 `0.5.2 / rtplp-lowband-p5-v3` 的 onset 与 groove bed 已能形成较协调的
双层触感，但约三分钟诊断里 candidate BPM 在 60～170 间跳动，`locked` 始终为
`false`、`predicted=0`。日志中的 85↔170、70↔140 属于典型半拍/倍拍歧义；原实现
每 50 ms 直接采用最高单个共振峰，既没有候选族聚合，也没有挑战者持有时间，而且
置信度只看单峰，真实音乐的能量被谐波分摊后难以跨过 0.58 锁定门槛。

`0.5.3 / rtplp-tactus-p5-v4` 保持音频对齐、onset、groove bed、瞬态增益、时长和
Android Renderer 完全不变，只修改节奏钟：

- 将 BPM 与其半速/倍速共振峰组成固定容量候选族，聚合族内相干度作为 acquisition
  confidence；仍无堆分配、无 FFT、无前视；
- 使用方向性的交替重音证据：双倍速子拍可以支持较慢 tactus，半速分量只弱支持较快
  tactus；因此 70/85 BPM 的强弱交替 pattern 不再被固定识别成 140/170 BPM，而等强
  的真实 160 BPM 脉冲仍保持 160 BPM；
- 60～72 与 150～180 BPM 只施加平滑、较弱的人体 tactus 区先验，不能压过清晰的
  单峰证据；
- 新候选必须比当前候选强 8% 并连续保持 8 次评估（约 400 ms）才可切换；半拍/倍拍
  切换要求强 12% 并连续保持 20 次评估（约 1 s）；
- 首次锁定要求候选至少稳定 12 次评估（约 600 ms），避免启动瞬态在达到事件数量
  门槛后立即锁到错误速度；短于 2 秒的无证据缺口继续保持时钟但禁止无声补拍。

回归新增 70/85 BPM 强弱交替双倍速消歧和 500 ms 短缺口保持，同时保留
72/90/120/160 BPM、120→90 变速、弱拍补偿、静音解锁、非周期事件、低频鼓点叠加
镲片，以及纯高频瞬态不能锁拍。Host Release 5/5、Android SDK/宿主单测、lint、三
ABI native 与 SDK-output APK 构建通过。魅族 17 ARM 门禁结果：

| 场景 | Mean | P95 | P99 | Max | 实时倍数 | 错误 |
|---|---:|---:|---:|---:|---:|---:|
| 静音底噪 | 103.332 us | 103.177 us | 130.625 us | 1423.750 us | 48.2x | 0 |
| 持续低频 | 105.360 us | 105.521 us | 135.781 us | 1503.698 us | 47.3x | 0 |
| 游戏强瞬态 | 104.834 us | 105.365 us | 135.521 us | 1432.343 us | 47.5x | 0 |
| 音乐型混合 | 107.130 us | 107.291 us | 139.166 us | 1427.916 us | 46.5x | 0 |
| 语音型调制 | 106.851 us | 107.188 us | 139.531 us | 1693.958 us | 46.6x | 0 |

正式报告位于 `tools/audio_haptics_android_bench/out/rtplp_tactus_p5_v4/`。下一轮真机
准入重点是 candidate 是否收敛、何时 locked、predicted 是否出现，以及补拍是否改善
及时性而不制造双击或错误半拍。

## 0.5.4 锁定保持与低置信宽限

`0.5.3` 的有效真机日志已证明候选族开始工作：32 个节奏诊断窗口中有 2 个窗口进入
`locked=true`，5 个窗口产生补拍、合计 `predicted=7`；candidate 大多收敛在 60～90
BPM，仅出现一次 140 BPM。但锁定保持时间仍短，音乐中的切分音、填充段或短时低频
证据下降会使时钟过快解锁，后续补拍又需要重新完成 acquisition，体感表现为律动偶尔
建立、很快消失。

`0.5.4 / rtplp-hold-p5-v5` 不改变 onset、groove bed、音频对齐、Android Renderer 或
执行器参数，只增强已锁定节奏钟的保持策略：

- 置信度上升仍使用 `0.35` 平滑系数；锁定后的下降改用 `0.08` 慢释放，降低单个弱段
  对稳定节拍的破坏；
- 目标置信度低于 `0.30` 时立刻暂停预测补拍，但保留 tempo/phase；低置信必须连续约
  2 秒才解锁，恢复真实 onset 后可沿原相位继续；
- 已锁定且当前 tempo 的证据暂时不足时冻结挑战者，避免短暂的 90 BPM 填充段改写
  已建立的 120 BPM 时钟；
- 锁定后的非倍频切换要求新候选强 12% 且连续保持约 1 秒；半拍/倍拍切换要求强 20%
  且连续保持约 4 秒；持续变速仍允许跟随；
- 所有保持逻辑都位于固定容量、无堆分配、无前视的因果时钟内，不增加音频缓冲延迟。

回归新增：120 BPM 锁定后 500 ms 强非周期干扰不掉锁且干扰期间不补拍、恢复后仍保持
120 BPM；同类干扰持续 3 秒必须解锁；短时 90 BPM 挑战不能改写锁定时钟；持续
120→60 和 120→90 仍能完成跟随。Host Release 5/5、Android 宿主单测/lint 与
SDK-output APK 构建均通过。魅族 17 ARM 门禁结果：

| 场景 | Mean | P95 | P99 | Max | 实时倍数 | 错误 |
|---|---:|---:|---:|---:|---:|---:|
| 静音底噪 | 103.421 us | 103.750 us | 129.843 us | 387.083 us | 48.2x | 0 |
| 持续低频 | 105.321 us | 106.719 us | 133.541 us | 406.718 us | 47.3x | 0 |
| 游戏强瞬态 | 104.623 us | 105.521 us | 131.614 us | 392.552 us | 47.6x | 0 |
| 音乐型混合 | 106.916 us | 107.657 us | 133.959 us | 408.489 us | 46.6x | 0 |
| 语音型调制 | 106.603 us | 107.448 us | 134.167 us | 397.136 us | 46.7x | 0 |

正式报告位于 `tools/audio_haptics_android_bench/out/rtplp_hold_p5_v5/`。真机体验重点从
“能否锁定”转为“稳定段能否持续保持、切分/填充后能否快速恢复补拍，以及宽限期是否
引入错误补拍”；诊断时同时核对 `locked`、`predicted` 与实际听感。

## 0.5.5 多假设节奏跟踪与休眠锁定

`0.5.4` 的下一次真机会话在 84 BPM 首次进入 `locked=true`，并在显示置信度降到 29%
时仍保持锁定且产生 1 次补拍，证明低置信宽限已生效；但下一次 5 秒诊断就解锁，candidate
短暂跳到 113 BPM，随后回到 83～87 BPM 却没有快速重锁。根因不只是宽限偏短：旧决策
层只保留一个 candidate，tempo 与 phase 会随解锁一起丢失，稳定候选即使重新出现也要
完整执行 acquisition。

`0.5.5 / rhythm-mht-p5-v6` 保持音频特征、onset、groove bed、执行器与 Android
Renderer 不变，重构因果节奏钟的时间序列决策层：

- 在原有 121 个 60～180 BPM 共振器之上增加事件专用的 6 秒相位相关长窗，并将密集
  activation 证据与稀疏 evidence-event 相位似然融合；事件似然带 1 秒 freshness，不能
  永久支撑已经过时的节拍；
- 每次评估从平滑后验中提取 8 个去重 tempo 模式，半拍、正拍和倍拍仍作为独立假设
  联合竞争，不再由单个瞬时峰直接改写时钟；
- 使用显式因果 phase accumulator 和小幅 onset 相位校正，弱证据时相位仍按已建立 tempo
  前进，不再依赖短窗相关相位漂移；
- 状态拆分为 acquisition、active 与 coasting：低置信约 1.6 秒或 1 秒无有效声学证据
  后进入 coasting，立即停止所有预测，但静默保留 tempo/phase 最长约 6 秒；
- coasting 中两个相位一致的 evidence event 可在 1 秒内恢复 active；错相事件不能唤醒；
  强而持续的新 tempo 仍可经过挑战者确认接管；
- 预测补拍除相位、置信度与声学支持外，还要求当前 activation 相对上一 hop 明显上升，
  持续底噪或宽带填充不能因为相位过零而产生连续“幽灵鼓点”；
- ABI v1 使用 `reserved[6]` 暴露 coasting，Android `HapticFrame.rhythmCoasting` 与 5 秒
  诊断同步增加该字段，未扩大 `AhHapticFrame`，旧宿主可继续忽略诊断扩展。

回归新增：持续非周期段进入 coasting 且不补拍；恢复两个同相 onset 后 1 秒内回到
120 BPM；三个错相 onset 不能唤醒；约 6 秒后休眠记忆必须过期。同时保留全部已知 BPM、
70/85 BPM 强弱交替、短缺口、弱拍补偿、静音、非周期、120→90/60 变速和频带抗干扰
回归。Host Release 5/5、Android 宿主单测/lint、三 ABI SDK 与 SDK-output APK 构建
均通过。魅族 17 ARM 门禁结果：

| 场景 | Mean | P95 | P99 | Max | 实时倍数 | 错误 |
|---|---:|---:|---:|---:|---:|---:|
| 静音底噪 | 104.140 us | 107.343 us | 132.813 us | 1462.552 us | 47.8x | 0 |
| 持续低频 | 105.991 us | 109.635 us | 136.041 us | 1462.656 us | 47.0x | 0 |
| 游戏强瞬态 | 105.193 us | 109.114 us | 133.750 us | 1390.260 us | 47.4x | 0 |
| 音乐型混合 | 107.612 us | 111.458 us | 138.021 us | 1415.990 us | 46.3x | 0 |
| 语音型调制 | 107.511 us | 111.771 us | 138.333 us | 1435.000 us | 46.3x | 0 |

正式报告位于 `tools/audio_haptics_android_bench/out/rhythm_mht_p5_v6/`。真机重点观察
`locked→coasting→locked` 是否能跨过切分与填充段、coasting 是否始终 `predicted=0`，
以及 candidate 是否避免此前的 84→113→86 短时漂移。

## Android MUSIC groove-bed v1 体验分支

在保持 SDK Core `0.5.2 / rtplp-lowband-p5-v3`、瞬态增益和瞬态时长不变的前提下，
Android 宿主将 `MUSIC` 从 transient-only 改为双层渲染：

- `TRANSIENT` 继续负责 36～46 ms 的鼓点重音，最低幅度策略不变；
- SDK 已有的 `continuousAmplitude` 经过 `rhythmLowFrequencySupport` 门控后作为低强度
  groove bed，最大幅度限制为 0.26；
- 启动门槛为 continuous 0.12、low-frequency support 0.18，启动后分别降至 0.08、
  0.12 形成迟滞；低频支持不足时不允许普通连续能量启动底座；
- 底座沿用 Core attack/release 和 Android Renderer 的 100 ms 更新间隔、0.08 幅度
  迟滞，不恢复旧 BassEnergy 路径每 15 ms cancel/restart 的伪连续策略；
- `STOP`、场景切换、后台、退出和系统 HapticGenerator 接管均清空底座状态；
- 5 秒诊断增加 `grooveBed` 当前幅度，供真机确认底座是否真正开启。

Android 宿主单元测试、lint 与 SDK-output APK 构建通过。该分支只改变 Android 产品
渲染策略，不改变公共 C ABI、SDK 参数版本或 HarmonyOS 行为；准入仍需验证持续感、
鼓点清晰度、疲劳感，以及停播/退出无残留振动。

## Android latency-alignment v1 体验分支

`MUSIC groove-bed v1` 的首轮反馈是持续感明显改善，但仍能感到触觉滞后。真机日志与
vibrator history 将问题分成两类：

- 串流突发时音频解码队列达到 40～70 ms，并伴随密集的 network dropped audio；
- native PCM 回调先执行触觉分析，Java `AndroidAudioRenderer` 随后才按 40 ms 门槛丢弃
  音频，因此触觉会响应并未真正交给 `AudioTrack` 的 PCM；
- groove bed 生效后，Android Renderer 仍在每次强度更新前显式 `cancel()`，真机历史中
  约每 80～200 ms 重建一次持续波形，造成厂商相关的停启间隙和马达重复起振。

`latency-alignment v1` 不改变 Core DSP、参数版本、幅度或鼓点时长，只调整时序边界：

- 把 40 ms backlog shedding 移到 native 解码回调、所有音频派生分析之前；被丢弃的 PCM
  不再进入 bass、shadow 或 SDK-output，保留的 PCM 则保证继续交给 `AudioTrack`；
- Android Renderer 更新波形时直接提交新的 `vibrate()` 请求，由系统替换当前效果；仅在
  `STOP`、生命周期结束、低于停振门槛或异常兜底时调用 `cancel()`；
- 保持 SPSC 队列、私有渲染线程、100 ms continuous 更新间隔和 0.08 幅度迟滞不变，便于
  将主观差异归因于 PCM 对齐和马达停启，而非新的强度调参。

NonRoot Debug 的三 ABI native 构建、SDK Android 编译、宿主单元测试、lint 和 APK 构建
通过；lint 仍为基线内/既有的 55 warnings、1 hint，无新增阻断错误。该修复能消除客户端
自身制造的错位，但无法掩盖网络造成的音频丢包；复测时应同时观察触觉协调性和
`Network dropped audio data` 的频率。

首个 `latency-alignment v1` 体验 APK 曾因构建命令遗漏
`-PenableAudioHapticsOutput=true` 而回退到默认关闭的旧 bass 后端。真机证据为：没有
`AudioHaptics rhythm` 日志，系统历史只有旧 `triggerMusicOneShot()` 特征的 42～70 ms
单点波形，且生成的 `BuildConfig.AUDIO_HAPTICS_OUTPUT=false`。该包不作为算法 A/B
结论。随后使用显式属性重建，并同时检查 BuildConfig 和 APK 内
`libmoonlight_haptics_android.so`；正确体验包 SHA-256 为
`1B726150473D3D32111FAC1AC5262E9BADDC9160E6FA488B04283A2DD8ED9217`。后续所有
SDK-output 真机包必须把这两项检查作为安装前门禁，不能只依据 Gradle 构建成功。

## Android latency-alignment v2 路由实测

2026-07-16 在魅族 17 上验证 `0.5.6 / latency-alignment v2`。Core 参数集保持
`rhythm-mht-p5-v6` 不变；本轮只验证 native IR 生产时间、共享 display-priority worker、
`AudioTrack` presentation clock、10 ms 执行器提前量、25 ms stale deadline 和
presentation-aware latest-wins。

蓝牙 A2DP 路由下，AudioFlinger 确认应用处于 FAST track，但厂商 FastMixer/Track
仍报告约 283～288 ms 输出延迟。SDK 测得 IR 相对当前可听播放头领先约 298～303 ms，
与系统报告一致。将合理调度保护窗从 100 ms 放宽至 500 ms 后：

- presentation clock 决策持续接受，无时间轴回退；
- 生产到 `vibrate()` 调用约 292～297 ms，这是为等待蓝牙声音的主动调度；
- audio-target skew P95/P99 约 1.2～1.5 ms；
- 稳态无 stale transient、无 superseded transient，主观反馈为振动与蓝牙声音同步。

同一会话切换到机身扬声器后，无需重建参数或硬编码路由延迟。切换后的首个统计窗口
混合了蓝牙已排期帧，随后 production-to-dispatch 自动收敛到约 42～45 ms，
audio-target skew P99 约 1.2～1.8 ms，clock 持续接受且稳定后无新增 stale/superseded。
因此 500 ms 是异常保护上限而非固定等待值；实际等待始终由当前 AudioTrack timestamp
决定。其他机型仍需复测马达起振提前量，默认 10 ms 不应被解释为所有设备的最终校准值。

### OPPO PKJ110 第二机型验证与厂商缩放标记

2026-07-16 在 OPPO PKJ110（Android 16 / API 36）扬声器路由复测同一
`0.5.6 / latency-alignment v2`。系统公开 `AMPLITUDE_CONTROL`，并支持
`CLICK/DOUBLE_CLICK/TICK/THUD/POP/HEAVY_CLICK` 等 predefined effect；但
supported primitives 为空，composition size、PWLE/envelope 上限均为 0。因此该机型虽然
系统版本较新，实际仍是“幅度 waveform + predefined effect”，不能按 API level 推断为
composition/envelope 设备。系统 `HapticGenerator.isAvailable()` 也为 false。

稳态数据与听感如下：

- presentation clock 持续接受，audio-target skew P99 约 0.9～1.8 ms；
- production-to-dispatch 从约 172 ms 随厂商 AudioFlinger track latency 动态增长到
  203～209 ms，SDK 跟随当前播放时钟而非使用固定机型延迟；
- 稳态无 stale/superseded transient；只在重连起始阶段观察到约 40～80 ms 音频 backlog
  丢弃，不计入稳态算法结论；
- 主观反馈为“同步”，但“连续振动更多”。vibrator history 显示 OPlus 对
  `USAGE_MEDIA` continuous waveform 使用 `VERY_HIGH` scale，原始幅度约 0.15/0.26
  被播放为约 0.31/0.50，而不是 Core 检测出更多节拍。

`0.5.7` 不为该机型降低宿主 groove 参数，只记录已知差异。`0.5.8` 开始在 SDK Renderer
加入可关闭、可测量的 device profile；任何连续增益校准都不能进入 Core 或 Moonlight
场景业务代码，predefined effect 仍作为后续独立能力分支。

## 0.5.7 MUSIC authoring SDK 边界迁移

`AH-023` 将已通过真机体验的通用音乐创作从 Moonlight Android 宿主迁入可复用 SDK：

- Core 新增 `MusicSceneAuthor`，负责 groove 低频门控与滞回、连续幅度上限、音乐瞬态
  gain，以及首拍/长间隔 restart 衰减；IR 新增可向后忽略的 `AH_FRAME_MUSIC_RESTART`；
- Android SDK 新增 `HapticDevicePolicy`，根据 amplitude/on-off 与 primitive/envelope
  执行器能力映射音乐瞬态幅度下限和时长；已知 OPlus continuous scaling 仍只作标记，
  本轮不引入隐式机型降 gain；
- Moonlight `AudioVibrationService` 删除上述通用曲线，只保留用户总强度、系统效果仲裁、
  生命周期与手机/手柄路由；旧 BassEnergy 仍只作为关闭 SDK 时的互斥回滚路径；
- ABI v1 结构保持 80 bytes；Core Release 6/6、Android SDK 与宿主定向单元测试、三 ABI
  native 和显式 `AUDIO_HAPTICS_OUTPUT=true` 的 NonRoot Debug APK 构建通过。
- 体验包 SHA-256 为
  `8D8D593A6073925FF972BC65D2EB494F6F147A928641ED63629F18961236DBC6`；已覆盖安装到
  OPPO PKJ110，包进程可正常启动且无 AndroidRuntime/libc 启动异常。

该迁移先保证职责和参数等价，不声称引入新的体感增益。当前第一轮门禁是确认 MUSIC
鼓点、groove 连续感与 0.5.6 基线无明显回退；随后进入独立 GAME profile 和可关闭 device
profile，不再把通用触觉创作放回客户端业务层。

## 0.5.8 OPPO 连续层次补偿

`0.5.7` 在 PKJ110 真实音乐会话中保持 `stale=0 / superseded=0`，稳态 audio-target skew
大多约 0.7～1.4 ms；每 5 秒约有 9～15 个真实瞬态。体感反馈仍为连续振动层次不足，系统
history 同时确认 OPlus 将原始 continuous `0.21` 播放为约 `0.41`，而原始 transient
`0.72` 只增至约 `0.93`，强弱比从约 3.4 压缩至约 2.3。

`0.5.8` 仅在 Android SDK Renderer 增加第一版显式 device profile：

- 精确匹配 `manufacturer=OPPO / model=PKJ110`，MUSIC continuous gain 为 `0.60`；
- transient、Core DSP、节拍数量、presentation clock 和 GAME 场景保持不变；
- profile id 为 `oplus-pkj110-media-v1`，Moonlight 会话初始化日志输出该 id；
- `HapticRenderConfig.enableDeviceProfiles=false` 可恢复 neutral profile，未知设备默认
  gain 为 `1.0`，不按 Android API level 或厂商名泛化；
- Core Release 6/6、SDK profile/policy 单测、宿主定向单测、三 ABI native 和完整 APK
  构建通过；体验包 SHA-256 为
  `899E8B8C77E212173B82C684A56B621AB254944ACCA22BBF1CE540B1727D5E9A`，已安装到 PKJ110。

本轮真机门禁是确认底座仍能感知、鼓点突出且同步不回退；在主观确认前不把该倍率扩展到
其他 OPlus 机型。

## 0.5.9 OPPO 有限 groove 尾段

`0.5.8` 真机 history 确认 `0.60` gain 已生效：典型 continuous 原始幅度由约 `0.21`
降至 `0.12`，OPlus 播放值由约 `0.41` 降至 `0.25`。但体感仍认为连续量偏多，根因是
每个 transient 后的 1000 ms continuous segment 使用 `repeat=2` 无限循环，直到下一次
effect 或 stop 才结束；密集事件间常实际持续 200～500 ms，甚至出现约 1.5 s 连续段。

`0.5.9 / oplus-pkj110-media-v2` 保持 `0.60` gain，同时把 PKJ110 MUSIC continuous
改为 90 ms 有限尾段：

- transient 后的尾段和 standalone groove pulse 都使用 `repeat=-1`，到时自然结束；
- transient 幅度/时长、Core IR、节拍数量、同步调度、GAME 和其他设备完全不变；
- neutral profile 仍使用原有可循环 continuous 语义，避免未经验证地改变其他执行器；
- Core Release 6/6、Android SDK 单测、三 ABI native 和完整 APK 构建通过；体验包
  SHA-256 为 `5E1DD82E18C8534D115DC90DE5751FF19B80D8436BD8A70F00D2CAE0F7B47BE6`，
  已安装到 PKJ110。

真机 system history 确认请求为 `90ms / repeat=-1`，但 OPlus 将单个有限 amplitude step
优化成固定约 45 ms 的 prebaked effect；主观结果变成“全是单击、完全没有连绵振动”。
因此 `0.5.9` 证明有限时长方向正确，但单段波形在该厂商实现上不可用。

## 0.5.10 OPPO 多段有限持续尾部

`0.5.10 / oplus-pkj110-media-v3` 不回到无限循环，而是把有限尾部编码为 4 个连续的
60 ms amplitude step，总请求 240 ms；相邻 step 使用 `1.0 / 0.92` 的轻微调制，避免
OPlus 把整个尾部合并成单个 45 ms 点击。按该机此前每个 step 约 45 ms 的实际映射，目标
持续触感约 180 ms，位于 `0.5.8` 偏多与 `0.5.9` 消失之间。

Core、transient、同步调度、`0.60` continuous gain、GAME 与 neutral profile 均不变。
Core Release 6/6、Android SDK 单测、三 ABI native 和完整 APK 构建通过；体验包 SHA-256
为 `BB4DEE6654468FF97CC71794D62B24CAF45F69F7E899807F71C9929E7A49A56D`，已安装到
PKJ110。真机 history 保留了 4 个 segment，但 OPlus 将每段分别改写为约 45 ms 的
`effectId=69` prebaked effect；主观结果仍是连续点击，没有形成连续材质。因此只要 waveform
是有限 step，增加 segment 数量不能绕过该厂商优化。

## 0.5.11 OPPO 循环波形租约

`0.5.11 / oplus-pkj110-media-v4` 恢复该机已证明能够产生连续材质的 repeating amplitude
waveform，但不恢复无限驻留语义。Android SDK Renderer 为 PKJ110 的 MUSIC continuous
增加 `220 ms` 最大租约：

- continuous 使用原生 repeating step，绕过有限 step 被重写为 prebaked 点击的问题；
- Renderer 在 `220 ms` 后主动 cancel；后续有效 effect 通过 generation 更新租约，旧的
  延迟 stop 不能误停新 effect；
- `STOP`、场景切换和生命周期 stop 仍立即 cancel，并使所有未执行租约失效；
- `0.60` continuous gain、Core IR、transient、同步调度、GAME、neutral profile 与公共 ABI
  均不变，机型 workaround 仍严格位于 SDK Renderer 边界。

Core Release 6/6、Android SDK 单测和完整 APK 构建通过；体验包 SHA-256 为
`C3A1E7F32D37E5DC286048AA7A402EDBD8044318D0A8F7C4474218B9BAC87F9D`，已安装到 PKJ110。
真机验收要求 history 出现 repeating step，并在稀疏输入时约 `220 ms` 内 cancel，而不是只出现
`effectId=69` 列表；主观目标是恢复短连绵尾部，同时不退回 `0.5.8` 的长时间常振。

真机验收通过：history 确认 continuous 与 transient tail 分别以 `repeat=1/2` 的 Step waveform
播放，典型效果在 SDK cancel 后由系统记录为约 241～246 ms；短于该值的效果来自后续 effect
抢占或显式 stop。独立 transient 仍允许表现为约 45 ms 点击，但连续层不再退化为点击列表。
同一会话诊断保持 `stale=0 / superseded=0`，audio-target skew 观测约 0.4～1.6 ms；主观反馈
确认短连绵振动已恢复。该 profile 作为 PKJ110 当前接受基线保留，后续参数优化不得跨回 Core
或 Moonlight 宿主边界。

## 0.5.11 生命周期租约回归

为防止有限租约引入“旧定时 stop 误停新 effect/session”，SDK 将 generation 竞争收口为
worker-thread-only 的 `HapticEffectLeaseGuard`，并增加三类自动回归：当前租约只能到期一次、
新 effect 使旧租约失效、显式生命周期 stop 使所有待执行租约失效。Core Release 6/6、Android
SDK 与 Moonlight 宿主定向单测、完整 APK 构建通过；本轮魅族 17 体验包 SHA-256 为
`54CF43149C46B7BB3DC0E0B120AAFBAB3D37654A03321D3F0F1F39E009FB3DE8`。

2026-07-16 在魅族 17 的真实串流 MUSIC 会话完成首轮后台/重进矩阵：

- 切后台 700 ms 后系统报告 `mIsVibrating=false / mCurrentVibration=null`，无残留马达；
- 该机当前会结束串流 Activity 并返回主界面，重新进入后 App 进程仍为同一 PID，但音频 session
  从 `1401` 更新为 `1409`；
- 新 session 立即恢复 `repeat=1/2` MEDIA waveform，旧 session 的队列或延迟任务没有误停新输出；
- 新 session 保持 `stale=0 / superseded=0`，audio-target skew 约 0.46～2.33 ms。

魅族 vibrator history 对已被 supersede/cancel 的记录仍显示 `endTime=null / status=running`，这是
该系统 history 记账行为；验收以 controller 的 `mIsVibrating=false` 和 `mCurrentVibration=null`
为准。上述首轮之后继续补测设置、正常退出与网络断流。

同日继续完成设置、正常退出和网络断流首轮：

- 将 `checkbox_audio_vibration` 从 `true` 切为 `false` 后重新进入真实串流，连续 4 秒无新增
  MEDIA history、无 current/next effect、无新 rhythm 输出；恢复为 `true` 后，新音频 session
  `1425` 立即恢复 MEDIA waveform；
- 在新 `repeat=2` waveform 后通过游戏菜单“断开连接”，600 ms 内 controller、current/next
  effect 均为空，随后 6 秒无新增 MEDIA history，Activity 正常返回 AppView；
- 在新 `repeat=1/2` waveform 后关闭 Wi-Fi，700 ms 时马达已为空，3 秒断流窗口无新增
  waveform；Wi-Fi 通过 `finally` 恢复到原 SSID；
- 网络恢复后底层短暂收到音频并输出一条 rhythm 诊断，但连接约 7 秒后以错误 `-1` 终止，
  Moonlight 当前没有自动重连；终止过程无残振；
- 手动重新进入后，同一 App 进程创建音频 session `1441`，4 秒观察窗内 MEDIA waveform
  持续更新，`stale=0 / superseded=0`，audio-target skew 约 0.40～1.60 ms。

因此 SDK/Renderer 的“设置关闭、正常退出、断流 stop、新 session 干净恢复”门禁通过；“网络
恢复后自动重连”属于 Moonlight 客户端连接层，不能由 SDK 隐式接管，作为独立客户端待办保留。
生命周期矩阵只剩自动重连策略和 30 分钟稳定运行未通过；后者按本轮决策暂不阻塞 GAME
体验迭代，发布前仍需恢复该 gate。

## 0.5.12 GAME Core 首轮

`0.5.12 / scene-core-p4g-v2` 新增独立 `GameSceneAuthor`，不修改已经确认的 MUSIC profile：

- GAME 瞬态只来自当前 PCM 的因果 onset，不接收 PLP predicted beat，也不会携带
  `MUSIC_RESTART`；
- 低频持续意图需连续 8 hop（约 40 ms）达到 input/support/low-band 三重门槛才启动，
  并使用独立 attack、release、迟滞和最高 `0.55` 的设备无关 IR 上限；
- impact/click 根据低频支持、分带 novelty、tactile impulse 和 onset sharpness 分层，
  输出仍使用 ABI v1 的 amplitude/duration/sharpness/confidence；
- leaky fatigue budget 只 duck 长时间 continuous，明确 transient 不减弱；强冲击后短时降低
  bed，保留事件与引擎底座的层次；
- Android Renderer 继续按设备能力选择 envelope/primitive/amplitude waveform，PKJ110 的
  MUSIC 专用 gain/220 ms lease 不会泄漏到 GAME。

Host Release 7/7、Android SDK 单测、Moonlight 宿主单测和
`:app:assembleNonRootDebug -PenableAudioHapticsOutput=true` 已通过。首个待测体验包 SHA-256 为
`325C03B46121FF3A5187196D74FC351B9937EF33C462D06CD89A017C59CE1884`。下一步用真实游戏覆盖
爆炸/枪声/碰撞/脚步/UI click、引擎/载具、对白/风噪和断流 stop；当前阶段不把合成回归当作
拟真度通过结论。

魅族 17 安装后已确认宿主设置为 `scene=0 / sensitivity=1.0 / strength=80`。首轮无法进入实际
gameplay，改用正在串流的游戏 BGM 作为 GAME 配乐负样本：系统 vibrator history 的连续
8.3 秒窗口记录 35 次 MEDIA repeating waveform，约 4.2 次/秒，提交幅度约 0.059～0.439；
窗口后抽样 `mIsVibrating=false / mCurrentVibration=null / mNextVibration=null`，未形成卡死或
无限残留。该结果证明 stop/迟滞路径工作，但提交密度说明这首配乐对 GAME 低频门控仍较活跃；
是否属于可接受的节奏反馈要结合主观“连续感/干扰感”判断，不能替代 gameplay impact recall。

## 0.5.13 GAME 旧式风格回退

由于当前无法进入真实 gameplay，无法可靠校准 0.5.12 的 impact/click、8-hop continuous
准入和 fatigue 参数。`0.5.13 / game-legacy-p4g-v3` 因此只回退默认 GAME authoring：恢复
改造前的共享低频 continuous 包络与当前因果 onset 单击，不启用实验 profile 的持续门控、
冲击重塑和 fatigue duck。`GameSceneAuthor` 与单元测试仍保留，`MUSIC`、Renderer device
profile、时钟调度和 ABI v1 不变。

公共 IR 回归已增加旧式 full-scale continuous 断言；Host Release 7/7、Android SDK 单测、
Moonlight 宿主单测及完整 APK 构建通过。体验包 SHA-256 为
`B246A1F9338C0DFE4C246AE0CAFC56ABF008F9C94C185944B224A333ACFF5F1D`。本轮用同一游戏 BGM
与 0.5.12 的约 4.2 次/秒、0.059～0.439 幅度窗口做主观对照，不从 BGM 推导 gameplay
冲击召回结论。

## 0.5.14 Action-RPG GAME profile

`0.5.14 / action-rpg-p4g-v4` 不复现旧 BassEnergy，也不沿用 0.5.13 的默认旧式接线。
新 GAME profile 面向《原神》一类 BGM-heavy action RPG：探索/对白/配乐应尽量安静，技能、
受击和重物理冲击应清晰分层，continuous 只保留给明确的非音调低频轰鸣。

- 特征层新增项目自研、固定容量的 causal median-HPSS 近似和 SuperFlux-style 振音抑制；
- MUSIC 继续消费原来的 novelty，避免本轮影响已确认的音乐体验；
- GAME 对稳定管弦/人声、纯音和已锁定节拍上的中等 BGM percussion 降权，强低频冲击绕过；
- 重冲击使用较长、较钝 transient，锐攻击使用较短、较利落 transient；
- continuous 需累计 12 hop 非音调低频证据，上限 `0.24`，4-hop 释放迟滞并带 fatigue duck；
- GAME 不使用 PLP predicted beat，也不携带 `MUSIC_RESTART`。

Host Release 新增 percussive feature 回归，覆盖稳态纯音的 harmonic dominance、宽带攻击的
percussive salience 与单 hop 因果时序、振音 novelty 抑制；GAME author 回归覆盖管弦拒绝、
稳定 BGM beat 降权、物理冲击绕过、impact/skill 层次、continuous 准入/上限/release/fatigue；
公共 IR 回归从旧式“60 Hz full-scale continuous”改为“稳定 60 Hz 纯音安静、非音调低频轰鸣
可启动且不超过 0.24”。Host 8/8 已通过。Android AAR、宿主构建、安装和真机 BGM 数据待本节
后续补录，不能用 BGM 负载替代实际 gameplay 的战斗召回结论。

## 复现

连接并授权 Android 设备后，在仓库根目录运行：

```powershell
python tools/audio_haptics_android_bench/run_android_benchmark.py `
  --duration-seconds 10 `
  --device-class android_phone_performance `
  --output-dir tools/audio_haptics_android_bench/out/formal
```

工具自动跳过缺失 CMake toolchain 的不完整 NDK，选择最新的完整版本。正式门禁要求每个
场景至少运行 10 秒、错误为零、P99 不超过 500 微秒。

## 后续顺序

1. ~~把 SDK Core 作为独立静态库接入相邻 `moonlight-android` 工程。~~ 已完成。
2. ~~在 Android 解码 PCM 回调中增加默认关闭的 shadow，只记录聚合指标，不驱动振动。~~ 已完成。
3. ~~把 SDK HapticFrame 通过 JNI 送入 Android Renderer，并确保旧 bass 输出互斥。~~ 已完成。
4. ~~在魅族 17 上验证 `MUSIC/GAME` 马达输出与强制结束 cancel。~~ 基础验证已完成。
5. ~~在新的 AAR native 边界上复跑 `MUSIC`，并补跑 NativeHapticsSession 真机 instrumentation。~~ 已完成。
6. ~~按实施文档第 3.3 节收口 MUSIC authoring 边界。~~ `0.5.7` 已完成；下一步按第 6.8 节
   实现并复跑 `GAME` continuous/stop。
7. ~~验证后台 stop 无残留振动。~~ 已完成首轮。
8. ~~验证 stop 后重新进入会话可恢复 `MUSIC` transient。~~ 已完成首轮。
9. 正常退出、网络断流 stop 与手动重进已完成首轮；客户端自动重连另列连接层待办，30 分钟
   长稳本轮后置；当前补齐 GAME 主观体验矩阵。
10. 用 Release/等效优化构建采集真实串流精确 P50/P95/P99。
11. ~~再选择第二类 Android 设备复跑相同门禁。~~ OPPO PKJ110 已完成音乐同步首轮，
    发现 predefined 能力未利用与厂商 continuous scaling；仍需完成游戏和生命周期矩阵。
12. Android 闭环通过后才启动 Sunshine 接入。
