# PR #133 高刷新率方案复核

复核日期：2026-09-15。对象：[PR #133](https://github.com/AlkaidLab/moonlight-harmony/pull/133)、合并基线 `e7c0495`，以及本工作区的后续修正。

## 结论

**修复请求链路和补足诊断的方向成立；“持续空回调 + 周期重申就能在所有设备无触摸保持 120Hz”的结论不成立。当前补丁是接口兼容性修复，尚未获得真机效果验证。**

本次复核发现上一轮本地修正仍有两项遗漏：DisplaySync 的异步启动上下文，以及 Soloist 独立的 120Hz 参数上限。它们已修正。另将请求上限收敛到选定的显示目标，避免在仅支持 90Hz 的设备上写入 max=120。

必须分开看五个量：主机送来的帧数、解码输出、应用提交、系统回调、屏幕实际呈现。应用提交成功或回调达到 120 次/秒，都不能单独证明每秒呈现了 120 张不同画面。

## 1. 官方约束与当前实现

### 1.1 显示请求不是强制刷新率

OpenHarmony 的可变帧率机制收集各内容的帧率诉求，再由系统决定刷新率；实际效果受屏幕能力及功耗、性能限制。华为 LTPO 指南也反对把 min、max、expected 全部固定为 120。[可变帧率简介](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/graphics/displaysync-overview.md)、[华为 LTPO 指南](https://developer.huawei.com/consumer/cn/doc/doccenter-app-quality/bpta-ltpo-description)。

因此，min=0 是允许系统协商的范围配置，不能解释成“强制保持高刷”，也不能反过来认为它就是自动降到 60 的根因。将下限硬设成 120 没有获得跨设备保证。

### 1.2 无触摸节能策略可能影响 Soloist

OpenHarmony 6.0 源码的 `UI_RATE_TYPE_NAME_MAP` 明确包含 `display_sync`、`ace_component` 和 `display_soloist`。`GetUiIdleFps` 在触摸空闲且对应类型的策略开启时，对请求应用 idleFps；`SetEnergyConsumptionRateRange` 会同时压低 min、max、preferred。[HGM 节能策略源码](https://github.com/openharmony/graphic_graphic_2d/blob/OpenHarmony-6.0-Release/rosen/modules/hyper_graphic_manager/core/frame_rate_manager/hgm_energy_consumption_policy.cpp)。

这是“请求持续存在仍可能被降档”的具体实现依据。**它证明一种系统机制存在，不能证明某台 HarmonyOS 7 商用设备采用了同样的配置，或其降档值必为 60。** 机型、系统构建、屏幕模式和策略配置仍需实测。

PR 中“菜单返回恢复，故每两秒重申可以使之确定恢复”的推导缺少对照：菜单可能改变焦点、场景或触摸状态，重复写入 range 未必重现这些变化。当前实现保留失败重试，运行中的相同请求不再重复设置。

### 1.3 DisplaySync.start 必须找到正确 UI 实例

官方 API 文档明确说明，非 UI 页面或部分异步回调中调用 start，可能找不到 UI 上下文，导致订阅回调不执行；建议通过 `UIContext.runScopedTask` 绑定上下文。[DisplaySync API](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/reference/apis-arkgraphics2d/js-apis-graphics-displaySync.md#start)。

本项目的 `launchStream` 位于异步启动链中。上一轮新增回退直接调用 start，不能只凭没有抛异常就记录为有效。现已为串流和鼠标两条 DisplaySync 启动路径显式指定页面 UIContext，并保留实际回调计数用于确认是否工作。

源码也显示启动需要向 UI pipeline 注册，而停止使用已关联的 context；因此本轮保留现有 stop/off 清理方式。[UIDisplaySync 实现](https://github.com/openharmony/arkui_ace_engine/blob/0fa80879923af4004ade82dea48dc11256d824e5/frameworks/core/components_ng/manager/display_sync/ui_display_sync.cpp)。

### 1.4 各接口的范围不能套用同一上限

| 通道 | 可核实的约束 | 修正后的行为 |
| --- | --- | --- |
| DisplaySoloist | min、max、expected 的公开范围均为 0–120 | 仅在显示目标大于 60 且不超过 120 时启用 |
| ArkUI DisplaySync | max 不超过设备最大帧率，expected 在 min 和 max 之间 | 按能力选择显示目标，设置 `{min:0,max:目标,expected:目标}` |
| XComponent NodeHandle | 有 API 版本、节点类型及接口混用约束 | 完整检测设置/注册/注销路径；失败使用 DisplaySync；max 等于显示目标 |

前两项依据：[Soloist 参数定义](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/reference/apis-arkgraphics2d/capi-nativedisplaysoloist-displaysoloist-expectedraterange.md)、[ArkUI ExpectedFrameRateRange](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-explicit-animation.md#expectedframeraterange11)。本机 SDK 头文件和类型声明与这些限制一致。

上一轮用 max=max(120,expected) 解决 expected>max，只验证了大小关系，漏掉了接口上限。因此那项测试不足以证明 144Hz 合法，现已补充 Soloist 的上限测试。

144fps 串流在 120Hz 显示设备上：调度仍保留 144fps，显示请求选择 120Hz。显示设备支持 144Hz 时：ArkUI 请求 144Hz，Soloist 不启动；不能将 Soloist 截成 120Hz 后继续称其请求目标为 144Hz。超过 120Hz 的实际显示效果仍未验证。

### 1.5 XComponent 的“API 存在”不代表该节点能用

已核对 OpenHarmony 6.0 和当前主线：NodeHandle 设置及回调路径取得 `XComponentPatternV2`，并拒绝已经获取旧 NativeXComponent 的节点；旧 getter 还会写入 `HasGotNativeXComponent` 状态。[当前节点模型](https://github.com/openharmony/arkui_ace_engine/blob/0fa80879923af4004ade82dea48dc11256d824e5/frameworks/core/components_ng/pattern/xcomponent/xcomponent_model_ng.cpp)、[6.0 旧 getter 实现](https://github.com/openharmony/arkui_ace_engine/blob/OpenHarmony-6.0-Release/frameworks/core/interfaces/native/node/node_xcomponent_modifier.cpp)。

本项目仍使用含 id、type、controller 的旧 XComponent 构造方式。按上述实现，不能预设其新 NodeHandle 路径一定可用，也不能把旧 getter 当作无副作用的探测器。当前补丁以返回值选择公开 DisplaySync 回退，避免新旧接口交叉尝试。

此选择没有改造 Surface 创建和解码绑定。未来如迁移新 XComponent 构造方式，应作为独立的生命周期改造验证，而非只换一个调用名称。

### 1.6 当前刷新率不是硬件能力上限

`display.refreshRate` 是当前刷新率。API 20 增加的 `supportedRefreshRates` 返回显示设备支持的档位，但字段可选且默认可为空。[Display 属性](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/reference/apis-arkui/js-apis-display.md#属性)。

设置页原来依据当前值限制选项，会把当前处于 60/90Hz 的 120Hz 屏错误视为上限较低。现改读能力列表；未知时保留用户选择，而不把当前值当作上限。未知能力下的请求仍可能被设备拒绝或降档，保留选项不等于能力保证。

## 2. 社区证据能支持什么

| 来源 | 可用线索 | 证据局限 |
| --- | --- | --- |
| [本仓库 #129](https://github.com/AlkaidLab/moonlight-harmony/issues/129) | PuraXMax 用户报告 120Hz 屏只出现 90Hz，以及串流逐渐降至 60 | 2026-09-04 发布，早于 #133 合并；不能当作 #133 发布后仍失败的证明，无完整运行日志 |
| [华为问答“120帧怎么又掉60了？”](https://developer.huawei.com/consumer/cn/forum/topic/0204223994152394337) | 提问者报告自绘叠加 ArkUI 动画后帧率下降，说明还需检查 UI 线程负载 | 缺机型、构建号和 trace；回复有不同参数建议，没有证实根因，不能把回复当官方接口保证 |
| [flutter_oh：Flutter OHOS LTPO 使用指南](https://openharmonycrossplatform.csdn.net/6aa0fae248977663a5de2e0e.html) | 作者描述触摸停止后降档，并在验证流程提到系统帧率策略云推 | 2026-09-09 发布，限定 Flutter 适配场景；不能据此推断本项目需要白名单或套用其配置 |

Flutter 文章还在不同段落分别写了 3.27.5-ohos-1.0.6 和 1.0.2，版本信息不一致。其链接的 GitCode 配置文件本次未成功读取，未据此推荐具体分支或移植 `framesconfig.json`。

**本轮没有找到足以确认“Soloist 空回调在指定 HarmonyOS 7 机型上长期、无触摸稳定 120Hz”的独立对照测试。** 社区线索支持按系统策略、UI 负载和显示路径分别排查，不能支持继续堆叠请求就一定有效。

## 3. 本地改动的判断

### 有依据保留的部分

- 设置页区分当前档位与设备能力；流的分数 FPS 与整数显示 Hz 分开。
- XComponent 检查完整 API 组合与返回值，失败回退；取消有状态的旧 getter 探测。
- DisplaySync 显式绑定 UIContext；串流 DisplaySync 已存在时不再创建鼠标的第二个 DisplaySync。
- Soloist 使用 SDK 声明校验函数类型，保留动态加载，并遵守 120Hz 上限。
- 启动失败、串流结束、页面销毁和 Surface 清除时清理相关资源。
- 增加请求路径、回调率、提交率、接收率及当前显示档位诊断。

### 仍属待验证的实现选择

1. **持续回调的收益与功耗。** 当前保留 Native Soloist 和必要的 ArkUI 回退。这会增加周期性工作；删除重复的鼠标 DisplaySync 并不意味着总开销为零。华为性能指南要求减少高频回调中的冗余工作，应通过 trace 和功耗对照验证这些请求是否有实际收益。[主线程耗时优化](https://developer.huawei.com/consumer/cn/doc/doccenter-app-quality/bpta-time-optimization-of-the-main-thread)。
2. **周期检查不是无帧看门狗。** Native 检查从 SubmitFrame 触发；完全没有解码输出时不会运行。已有对象但零回调的异常目前靠诊断识别，没有实现自动重建策略。
3. **窗口可见性覆盖不完整。** 当前资源清理跟随串流、页面和 Surface 生命周期。锁屏、仅后台音频、分屏、画中画和外接屏仍需验证。窗口失焦不必然等于视频不可见，不能简单在所有失焦事件里停掉渲染请求。
4. **移除私有 NativeWindow API。** 公开 SDK 无 `OH_NativeWindow_SetFrameRateRange` 的契约，PR 也承认 strategy 语义未被文档确认。移除它有兼容性依据，但未获得各机型效果不变的 A/B 证据。
5. **NativeVSync 仍可作为独立实验。** 删除未使用 RequestFrame 的对象是清理死代码，不代表正确接入 NativeVSync 无效。官方开发指导提供回调及帧率请求路径；若实验，应与实际渲染协作，并测延迟和队列，不能只增加又一条空循环。[NativeVSync 指导](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/graphics/native-vsync-guidelines.md)。

### PR 之外发现的独立风险

`video_decoder.cpp` 当前将 `OH_MD_KEY_FRAME_RATE` 配为实际 FPS 的两倍。提交 `1b3ff56` 明确说明这是主动争取解码性能余量的策略。后续追踪 2026-09-15 的 OpenHarmony AVCodec 源码，确认该值会进入硬件端口配置，因此不能仅凭字段名称认定它没有性能效果。[硬件解码器实现](https://gitcode.com/openharmony/multimedia_av_codec/blob/90c234ed2c034d8dafe3efcae982660a6e8c90b8/services/engine/codec/video/hcodec/hdecoder.cpp)。

但当前实现还包含按实际输出消耗动态调整 operating rate 的 AFC，乘二不能保证持久防降频；开启 VRR 时，该值又会作为视频内容帧率进入预测。结论更新为：有条件的兼容策略，不宜作为全部设备的无条件默认优化。完整证据及对照方法见 `docs/DECODER_FRAME_RATE_HEADROOM_REVIEW_2026-09-15.md`。本次分析未改变该运行行为，尚不能认定它是反馈设备掉帧的原因。

## 4. 真机如何判定问题在哪里

华为官方建议先识别丢帧阶段，再用 Frame/trace 定位；UI、RenderService、GPU 任一阶段都可能超出周期预算。120Hz 的周期约为 8.33ms。[帧率问题分析](https://developer.huawei.com/consumer/cn/doc/doccenter-app-quality/bpta-zhenlv)、[ArkUI 丢帧定位](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-performance-53)。

以下是排查优先级，不能仅凭单个平均值确定根因：

| 同时观察到的现象 | 优先调查 |
| --- | --- |
| 接收和提交仍约 120，屏幕档位掉到 60，触摸立即恢复 | HGM/设备场景策略；核对真实 Surface 呈现，排除统计口径差异 |
| 屏幕仍为 120，DisplaySync 明显变慢或间隔抖动 | UI 主线程调度、动画、布局和其他回调；查看 DispatchDisplaySync、ReceiveVsync |
| 接收先掉、网络丢帧上升 | 主机输出、网络传输和重组 |
| 接收稳定，解码输出减少或解码延迟增加 | 解码能力、温控、缓冲区回压和应用丢帧策略 |
| 提交成功稳定，画面仍明显少帧 | RenderService 合成、Surface 队列、呈现时间戳和实际 scanout |
| DisplaySync 对象存在，回调长期为零 | 启动上下文、页面生命周期和系统版本兼容性；不能当作保活成功 |

### 建议的对照流程

1. 固定设备型号、完整系统构建号、应用提交、屏幕模式、电源模式、亮度和连接方式，记录温度状态。主机使用连续运动、可辨识帧序号的同一画面。
2. 对比 #133 合并版与本地修正版；每组至少重复三轮。先运行稳定，再测试无触摸 60 秒以上及触摸恢复；另跑 10 分钟观察热态。
3. 同时记录 FrameRateDiagnostics、XCFrameRate、系统刷新率叠加层和 Frame/RenderService trace。先确认该系统叠加层显示的是档位还是实时计数，不能单凭它证明独立视频帧的呈现率。
4. 覆盖 60/90/120、119.88、144fps；其中 144 分别测试 120Hz 屏和支持 144Hz 的屏。覆盖能力列表为空、当前 60/90 但支持 120 的情况。
5. 测试菜单返回、重连、启动失败、退出、锁屏恢复、后台音频、分屏与画中画。退出后应停止本次串流的回调和诊断；重新进入应恢复请求。
6. 若仍失败，再逐项隔离 Soloist、ArkUI 请求、解码上报 FPS；每次只改变一项。若应用供帧及提交稳定而系统仍降档，携带日志和 trace 向华为提交具体机型适配问题。

验收目标：前台连续运动且供帧足够时，无触摸阶段不发生可复现的异常降档；显示真实输出、延迟、丢帧和功耗均有对照依据。参数合法和编译成功只是进入验收的前提。

## 5. 本次验证结果

| 检查 | 结果 | 能证明什么 |
| --- | --- | --- |
| C++17 回归测试，开启 Wall/Wextra/Werror | 通过 | 分数帧率转换、非法输入、Soloist 120Hz 边界 |
| DisplayFrameRate 实际工具模块的 Node/SDK TypeScript 测试 | 通过 | 能力列表、90Hz 上限、144Hz 目标、未知能力回退 |
| 仓库规范检查与 git diff --check | 通过 | 基础仓库规范与补丁空白检查 |
| DevEco 完整 assembleHap，含 Native、ArkTS、签名 | 通过 | 本机 SDK 可编译链接并产生安装包 |
| 真机运行、无触摸测试、功耗及延迟 A/B | 未执行；hdc 无连接设备 | 不能宣称解决所有设备自动掉帧 |

## 6. 来源版本与适用范围

正文链接包含各主张的直接来源。官方文档取 OpenHarmony docs `f41b9345`；当前 ArkUI 实现取 `0fa80879`；另核对 OpenHarmony-6.0-Release 的 HGM 和节点行为。公开开源实现作为机制证据，不等同于所有 HarmonyOS 商用系统的运行配置。

华为 LTPO 指南页面标注更新于 2026-03-12；主线程优化 2026-05-30；帧率问题分析 2026-09-09；ArkUI FAQ 2026-07-30。社区文章及本仓库 issue 的日期见正文；问答只显示相对日期，不推定精确发布时间。所有网页本次检索日期为 2026-09-15。

剩余最关键的不确定项是具体反馈设备的系统策略与实际呈现数据。当前结论支持合入经过验证的接口修正，发布说明应描述“改进高刷新率请求兼容性和诊断”，不应承诺“永久锁定 120Hz”。
