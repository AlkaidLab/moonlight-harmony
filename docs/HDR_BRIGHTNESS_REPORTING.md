# HDR 亮度上报契约(客户端 → Sunshine)

客户端在 launch 请求(`POST /launch`)中上报显示亮度能力,宿主(foundation Sunshine)据此:

1. 创建对应峰值亮度的虚拟 HDR 屏;
2. 分析抓帧并生成 CUVA HDR Vivid 动态元数据的 tone-map 目标。

## 参数

| 参数 | 类型 | 语义 | 客户端行为 |
|---|---|---|---|
| `minBrightness` | float | 黑位(nits) | 固定 0.001(保留黑位精度,不取整) |
| `maxBrightness` | int | 面板峰值亮度(nits),虚拟屏亮度依据 | 实测 `sdrNits × maxHeadroom` **吸附标准档 [400,600,800,1000,1200,1600,2000,2600,4000]**(±30% 内吸附,避免逐会话微变触发宿主重建 VDD);回退 1000;手动滑条覆盖时为用户值(300–4000) |
| `maxAverageBrightness` | int | 满帧可持续亮度(nits),大面积亮场 tone-map 目标 | 实测 `sdrNits × p75(currentHeadroom)` 归整到 50 的倍数;回退/覆盖规则同上 |
| `sdrBrightness` | int | **SDR 参考白 / paper white(nits)** | 实测有效即携带(手动滑条覆盖时同样携带);测量不可靠或非 HDR 会话时**省略该参数** |

`sdrBrightness` 为本客户端扩展参数,旧宿主与 GFE 忽略未知 launch 参数,行为不变。

## 宿主侧要求

- **所有亮度参数都是 tone-map 目标,不是硬上限。**
- 虚拟屏按 `maxBrightness` 建峰亮;`maxAverageBrightness` 用于压缩大面积亮场(面板 ABL/可持续约束)。
- **`sdrBrightness` 的落地方式(foundation-sunshine 已实现)**:解析范围 [50,1000](越界忽略按未携带处理);在 scRGB→HLG 转换着色器中对 SDR 波段(≤ Windows 当前 SDR 白位,来自 VDD 光标共享内存的实时值)乘增益 `clamp(phoneSdr / windowsSdr, 0.5, 2.5)`,波段上沿 2 倍处平滑过渡回 1.0——HDR 高光保持绝对值,SDR 参考内容落到手机自己的 SDR 白位。未携带时增益恒 1,行为与旧宿主逐字节一致。日志关键字:`SDR band gain: phone=X, windows=Y, gain=Z`。
- 宿主若不读 `sdrBrightness`,应假设 ~200 nits 参考白,绝不能把 `maxBrightness` 当 SDR 白位使用——那会让全画面中亮度内容整体过亮,是 HDR Vivid 过曝的直接来源。
- VDD 能力比较带容差(每字段 ±max(25 nits, 5%)),配合客户端档位吸附,正常情况下同设备重复连接不触发 VDD 重建。

## 客户端测量逻辑(参考)

`entry/src/main/ets/service/streaming/BrightnessSampler.ets`:启动时对 `display.getBrightnessInfo()` 窗口采样(5 次 × 250ms),校验门:sdrNits ≥ 50、样本间波动比 ≤ 1.5、峰值 ≥ 100 且 ≥ sdrNits;`sdrNits` 取中位数,峰值取 `sdrNits × max(maxHeadroom)` 后吸附标准档,满帧取 `sdrNits × p75(currentHeadroom)` 后归整 50 倍数。

sdrNits 并非恒定面板参数,是系统状态快照(亮度滑条/显示模式可能改变它);客户端同时注册 `brightnessInfoChange` 探针打日志(`[BrightnessProbe]`),用于评估其动态性。

## 诊断

串流性能浮层 DECODER 行显示 `屏<sdrr>/<peak>→<hostMaxLum>nit`:手机实测 SDR 白位/峰值 vs 宿主通过 SS_HDR_METADATA 回传的 `maxDisplayLuminance`。两者偏差大即 tone-map 目标与真实面板脱节,优先排查宿主是否吃到上述参数。
