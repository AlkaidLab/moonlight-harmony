# SDR→HDR 逆色调映射实现笔记

## 架构概览

```
ArkTS Settings UI
    ↓ (peakNits, saturation)
MoonBridge_SetSdrToHdr (NAPI)
    ↓
gl_post_processor.cpp → SetSdrToHdr(bool, float peakNits, float saturation)
    ↓
GLSL Fragment Shader (uniforms: uSdrToHdr, uSdrPeakNits, uSdrSaturation)
```

## Shader Uniforms

| Uniform | 类型 | 范围 | 默认值 | 说明 |
|---------|------|------|--------|------|
| `uSdrToHdr` | int | 0/1 | 0 | 开关 |
| `uSdrPeakNits` | float | 200-2000 | 500 | 目标峰值亮度 |
| `uSdrSaturation` | float | 0.5-2.0 | 1.3 | 饱和度增益 |

## 两种模式

### 1. SDR → PQ（`uHdrMode == 0`）
- sRGB gamma 解码 → 逆 Reinhard → `lin_to_pq` 编码
- 参考白 80 nits

### 2. SDR → HLG（`uHdrMode == 2`）✅ 主力模式
- 直接在 HLG 域操作 S-curve
- 参考白 203 nits（HLG 信号 0.75）

## HLG S-curve 算法（已验证可用 · 2025-03-29）

```glsl
// f(x) = x + maxBoost · x³/(1+x³)
// 暗部几乎不变，中间调温和提升，高光显著扩展
float maxBoost = (uSdrPeakNits - 203.0) / 1000.0;  // 归一化 boost
vec3 x = hlg;
vec3 x3 = x * x * x;
vec3 boost = maxBoost * x3 / (1.0 + x3);
hlg = hlg + boost;

// 饱和度调整
float Yout = dot(hlg, vec3(0.2627, 0.6780, 0.0593));
hlg = Yout + (hlg - Yout) * uSdrSaturation;
hlg = clamp(hlg, 0.0, 1.0);
```

### 为什么用 S-curve `x³/(1+x³)`
- **暗部保护**：x 接近 0 时，x³ 极小，boost ≈ 0
- **高光扩展**：x 接近 1 时，x³/(1+x³) → 0.5，boost ≈ maxBoost/2
- **平滑过渡**：连续可导，无硬拐点
- **每通道独立**：保持色彩比例，避免色偏

### 失败的替代方案

**线性域 gain 计算**（❌ 黑屏）：
```glsl
// 这个方案会导致黑屏！
vec3 lin = hlg_to_lin(hlg);
float Ylin = dot(lin, luma_weights);
float Ylin_target = hlg_to_lin(vec3(Yhlg + boost)).x;  // ← 语义错误
float gain = Ylin_target / Ylin;  // ← 极端值
lin = lin * gain;
hlg = lin_to_hlg(lin);
```
失败原因：
1. `hlg_to_lin(vec3(标量亮度))` 把亮度值当作 3 通道 HLG 信号解码，语义不对
2. gain 可能极大或极小
3. HLG↔线性非线性转换在暗区精度丢失

## HLG 常量

```glsl
const float HLG_A = 0.17883277;
const float HLG_B = 1.0 - 4.0 * HLG_A;  // = 0.28466892
const float HLG_C = 0.5 - HLG_A * log(4.0 * HLG_A);  // ≈ 0.55991...
```

## 算法研究历程

调研过的算法（按研究顺序）：

1. **简单 gamma 提升** → 太粗暴
2. **逆 Reinhard** → 用于 SDR→PQ 模式
3. **S-curve v1~v5** → 迭代优化
4. **S-curve v6** `x + maxBoost·x³/(1+x³)` → ✅ 用户评价"比较自然"
5. **BT.2446A** → 太复杂，需要完整色彩空间转换
6. **BT.2446C** → 同上
7. **Dice ICtCp** → 矩阵运算在设备 GLSL 上不兼容（见 GLSL_SHADER_PITFALLS.md）
8. **libplacebo** → 参考但未采用
9. **AMD LPM** → 参考但未采用

最终结论：**简单的 HLG 域 S-curve 在该设备上效果最好、兼容性最强**。

## 局部高光增强（已移除）

曾实现十字邻域采样检测局部高光区域（技能光效/金属反光），但因 **OES 纹理多次采样性能不可接受** 而移除：

```glsl
// ❌ 已移除 — 4 次额外 OES 采样导致持续丢帧
float Y_up    = dot(texture(uTexture, vTexCoord + vec2(0.0, uTexelSize.y)).rgb, lw);
float Y_down  = dot(texture(uTexture, vTexCoord - vec2(0.0, uTexelSize.y)).rgb, lw);
float Y_left  = dot(texture(uTexture, vTexCoord - vec2(uTexelSize.x, 0.0)).rgb, lw);
float Y_right = dot(texture(uTexture, vTexCoord + vec2(uTexelSize.x, 0.0)).rgb, lw);
```

如果未来需要邻域操作，必须先将 OES 纹理 blit 到 FBO（`sampler2D`），再在 `sampler2D` 上做多次采样。
