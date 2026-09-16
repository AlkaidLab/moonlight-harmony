# 解码器两倍帧率配置：性能余量还是副作用

日期：2026-09-15。项目基线 `e7c0495`；OpenHarmony AVCodec 源码固定在当日主线 `90c234ed2c034d8dafe3efcae982660a6e8c90b8`。本报告为源码与接口分析，没有真机功耗或解码性能 A/B 数据；本次没有修改解码器运行行为。

## 结论

**两倍帧率是有意提高解码性能余量的兼容策略，存在作用于硬件的路径；但当前实现不能保证它持续防止降频，也不足以证明所有设备仍需要默认开启。**

建议的产品方向是：真实 FPS 作为默认配置；两倍 FPS 保留为有机型、系统版本和实验依据的兼容选项。VRR 开启时使用真实 FPS。正式切换默认值前，用问题设备完成静态转运动与持续热态的对照，防止移除已有收益。

这里的“真实 FPS”是协商的串流帧率，例如 119.88，而不是当前一秒接收计数，也不是屏幕当前刷新率。不能随网络抖动下调媒体描述帧率。

## 1. 原来的动机成立，收益尚未被单独证明

2026-02-21 的[提交 1b3ff56](https://github.com/AlkaidLab/moonlight-harmony/commit/1b3ff564a096c52ed4ac66197e7128a8c401726b)同时引入：

- 帧率由 `config_.fps` 改成 `config_.fps * 2.0`，意图防止静态内容时 VPU 降频。
- `MAX_INPUT_SIZE` 预分配，意图避免画面复杂度突然增加时的缓冲区分配开销。

因此，即使那次版本整体改善了卡顿，也不能仅凭同一提交的效果认定收益全部来自乘二。需要保持输入缓冲区预分配不变，只改变帧率参数做对照。提交信息没有附可复核的逐项实验数据。

## 2. 最新源码揭示了三个不同用途

### 2.1 配置值确实会传给硬件

`HDecoder::SetupPort` 读取配置帧率，将其保存到 `codecRate_`，并用于输入、输出端口的 PortInfo。`HCodec::SetVideoPortInfo` 把它转换为硬件端口的 `xFramerate` 等字段。[HDecoder](https://gitcode.com/openharmony/multimedia_av_codec/blob/90c234ed2c034d8dafe3efcae982660a6e8c90b8/services/engine/codec/video/hcodec/hdecoder.cpp)、[HCodec](https://gitcode.com/openharmony/multimedia_av_codec/blob/90c234ed2c034d8dafe3efcae982660a6e8c90b8/services/engine/codec/video/hcodec/hcodec.cpp)。

判断：如果厂商硬件用端口帧率选择性能档位，较高配置可能缩短某些帧的处理时间。这是合理的机制推断；实际时钟策略位于设备驱动及系统配置中，上述代码不能证明每台设备都会提高 VPU 频率。

本项目的 PTS 调度仍使用原串流配置。乘二没有增加输入帧数，也没有把播放速度改为两倍。问题在于这个配置还可能参与其他决策。

### 2.2 AFC 会重新调整硬件运行速率

当前 `CodecServer::InitFramerateCalculator` 建立控制器，其回调写入内部 `VIDEO_OPERATING_RATE` 并调用底层 SetParameter。`HDecoder::OnSetParameters` 再传给 `OMX_IndexCodecExtConfigOperatingRate`。这是一条真实的运行速率控制路径。[CodecServer](https://gitcode.com/openharmony/multimedia_av_codec/blob/90c234ed2c034d8dafe3efcae982660a6e8c90b8/services/services/codec/server/video/codec_server.cpp)。

控制器 AFC（Adaptive Framerate Controller）约每秒统计应用消耗的输出 buffer 数。吞吐持续偏低时，它可以经过滞后窗口把 operating rate 调到实际消耗率；吞吐恢复时，可回升到配置帧率。参数 `persist.OHOS.MediaAVCodec.AFC.Enable` 在此开源实现中的默认值为 true，但商用设备可能采用不同配置。[AFC 实现](https://gitcode.com/openharmony/multimedia_av_codec/blob/90c234ed2c034d8dafe3efcae982660a6e8c90b8/services/services/common/adaptive_framerate_controller/adaptive_framerate_controller.cpp)。

据此可推演：实际持续消耗 120fps，而初始配置为 240fps 时，AFC 可以把后续运行速率调整回约 120。它没有把配置的 240 永久当作下限。这不是设备实测结果，而是对该版本控制逻辑的推演。

这改变了对“必要性”的判断：

- 在具有同样 AFC 行为的系统中，乘二可能主要影响初始化、停顿后恢复或负载回升，不能声称持续维持两倍性能余量。
- 静态画面仍按 120fps 送入并消耗时，AFC 看到的是持续 120fps。它不会仅根据压缩包变小就知道下一帧会变复杂；真实 VPU 的时钟策略仍需设备 trace。
- 输出消费受其他环节限制时，AFC 观察到的吞吐也会受影响，不能把其统计值等同于 VPU 最大能力。

### 2.3 开启 VRR 时，它还是视频内容帧率

官方视频可变帧率文档要求正确设置 `OH_MD_KEY_FRAME_RATE`。该功能能根据内容调节屏幕刷新率，并在送显前丢弃部分视频帧。[视频可变帧率](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/media/avcodec/video-variable-refreshrate.md)。

源码中的 `HDecoder::VrrPrediction` 将 `codecRate_` 传给视频刷新率预测函数。两倍值因而进入内容预测，不只作用于性能配置。预测结果如何变化取决于设备算法，不能直接断言必然降到 60；但将 120fps 内容描述成 240fps 作为该算法输入，已与其文档前提不符。

本项目 `enableVrr` 默认 false，所以这项风险不能用来解释所有用户的掉帧。用户启用该设置时，应优先消除两倍帧率与 VRR 的组合。这里指的是解码器 VRR 开关，不是所有带 LTPO 屏幕的设备。

## 3. “反而有害”的证据强度

| 情况 | 可能结果 | 判断依据与限制 |
| --- | --- | --- |
| 设备确实因较高帧率配置提高性能档位 | 静态转运动的尖峰延迟可能降低 | 硬件配置路径已证实，机型收益未测 |
| 两倍 FPS 超出所选编码格式、分辨率的能力 | 可能配置失败或进入未验证的设备行为 | 官方 Configure 对超范围帧率列出错误；当前开源通用检查只验证正数，因此不能说所有设备必然拒绝 |
| 已有足够解码余量但较高配置仍增加资源投入 | 可能增加功耗、升温，间接恶化长时间稳定性 | 条件性风险；时钟提高、能耗增加、触发温控必须分别测量，不能直接画等号 |
| 设备 AFC 调回实际吞吐，或驱动忽略较高值 | 稳态收益可能很小或没有 | 不构成持久防降频保证 |
| 解码器 VRR 已启用 | 刷新率预测拿到不匹配的视频 FPS | 数据流和文档前提已证实，具体呈现损失未测 |

能力限制依据：[OH_VideoDecoder_Configure](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/reference/apis-avcodec-kit/capi-native-avcodec-videodecoder-h.md#oh_videodecoder_configure)、[当前参数检查实现](https://gitcode.com/openharmony/multimedia_av_codec/blob/90c234ed2c034d8dafe3efcae982660a6e8c90b8/services/services/codec/server/video/codec_param_checker.cpp)。

举例：4K120 配成 4K240，与 1080p60 配成 1080p120 的风险不同。若要保留性能余量，应查询实际选中的解码器及分辨率组合；不能拿屏幕最大 Hz，或另一种 MIME 的通用最高 FPS 作为限制。

当前项目的倍数是无条件乘二，没有按该组合限制，也没有专门的“乘二失败后恢复真实 FPS”重试路径。

## 4. 有没有已经可以替代它的官方接口

### 低延迟模式：有，但解决的问题不同

项目已设置 `OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY=1`。公开定义侧重限制解码器额外持有输入、输出数据，不承诺锁定 VPU 工作频率；不支持时还可能继续普通解码。因此不能推导出“已开低延迟，所以提高性能余量永远多余”。[AVCodec 参数定义](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/reference/apis-avcodec-kit/capi-native-avcodec-base-h.md)。

### Operating rate：内部有，尚未找到对应公开 C API 键

Android 的 `KEY_OPERATING_RATE` 明确用于资源规划和 operating points，和视频内容帧率有独立语义。[Android MediaFormat](https://developer.android.com/reference/android/media/MediaFormat#KEY_OPERATING_RATE)。

本次在 OpenHarmony 内部实现中找到了 `VIDEO_OPERATING_RATE`、工作频率和性能等级路径；但没有在本机 API 26 的公开 AVCodec 头文件及对应公开参数列表中找到可直接替换的 operating-rate 键。不能把内部 tag 或系统参数复制成产品对外依赖，尤其不能假定所有 HarmonyOS 版本都支持。

### API 26 的保帧模式：不是防降频接口

本机 SDK 和 AVCodec 主线头文件新增了 `OH_MD_KEY_VIDEO_DECODER_FRAME_RETENTION_MODE`：FULL 模式用于禁用该功能的主动丢帧。它不能替代时钟或性能余量控制，也不能保证显示链路不丢帧。[公开头文件](https://gitcode.com/openharmony/multimedia_av_codec/blob/90c234ed2c034d8dafe3efcae982660a6e8c90b8/interfaces/kits/c/native_avcodec_base.h)。

本项目没有设置这些保帧模式参数。已核对当前 builder/parser：缺少模式和比例时不会构建有效策略，不能把 UNIFORM 模式下的默认 30fps 错读为“所有 API 26 解码器默认限 30fps”。[策略解析](https://gitcode.com/openharmony/multimedia_av_codec/blob/90c234ed2c034d8dafe3efcae982660a6e8c90b8/services/services/codec/server/video/features/smart_fluency_decoding/smart_fluency_decoding.cpp)、[策略构建](https://gitcode.com/openharmony/multimedia_av_codec/blob/90c234ed2c034d8dafe3efcae982660a6e8c90b8/services/services/codec/server/video/features/smart_fluency_decoding/smart_fluency_decoding_builder.cpp)。

## 5. 建议与可判定的 A/B

建议将“媒体 FPS”和“性能余量策略”在实现中分开命名与记录。默认目标应为真实 FPS；两倍配置仅作为受控兼容策略，在问题机型上取得收益证据后使用。保留倍数时至少满足：

1. 解码器 VRR 关闭。
2. 所选解码器的实际尺寸与帧率能力允许该配置；能力未知时不把未知当作支持。
3. 配置失败能重新创建并用真实 FPS 回退，而不是直接让本来可解码的流失败。
4. 没有改变网络目标 FPS、PTS 或显示请求来混淆实验。

### 对照只改一个量

- A：`OH_MD_KEY_FRAME_RATE = config_.fps`。
- B：`OH_MD_KEY_FRAME_RATE = config_.fps * 2.0`。
- 两组保持低延迟模式、输入预分配、解码队列、同步/异步模式、分辨率、编码、码率和显示策略相同。
- 同时测试原问题机型与正常机型；固定完整系统构建号。每组重复静态 10–20 秒后突然复杂运动；另测连续运动 10–15 分钟。

### 重点观察

- 静态转运动后的前 5–10 帧，原始输入提交至输出回调延迟的 P95/P99、超时帧数和队列深度。
- 稳态接收、解码输出与实际呈现是否一致；不能只看面板 Hz。
- 可取得时观察 AFC 的 Reset framerate 日志、硬件 operating-rate/频率 trace；日志缺失本身不能证明 AFC 未启用。
- 热态功耗、温度、频率和尾延迟变化。

项目现有“解码时间”会用上一次输出时间修正起点。这是软件估计，并非硬件开始解码的时间；测试需要同时保留未经修正的提交到输出延迟，避免把队列或调度等待从结果中消掉。

保留乘二的判据：问题设备上的恢复尖峰有稳定、重复的改善，且热态丢帧、延迟和功耗可接受。若两组很快被 AFC 调到相同运行速率，或没有可重复收益，就应去掉无条件乘二。若 A 更省电且热态更稳，应优先用 A。

最终判断：当前证据支持收敛这项策略的适用范围，不支持宣称它已经完全无用，也不支持宣称它就是本次自动掉帧的根因。
