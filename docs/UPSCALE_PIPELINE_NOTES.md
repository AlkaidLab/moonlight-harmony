# 超分辨率管线开发笔记

## 架构概览

```
ArkTS Settings UI (upscaleMode / upscaleSharpness)
    ↓ MoonBridge_SetUpscaleMode (NAPI)
    ↓ 保存到 VideoDecoderInstance 全局变量（跨解码器实例保留）
    ↓
GLPostProcessor::Init()
    ├─ 创建 EGL surface → eglQuerySurface 获取实际像素尺寸
    ├─ 设置 NativeWindow 色彩空间（HLG/PQ/SDR→HDR）
    ├─ 创建 NativeImage（OES 代理纹理）
    ├─ 创建 FBO（输入分辨率，HDR=RGBA16F / SDR=RGBA8）
    ├─ InitUpscale() → 尝试 XEngine → 回退 FSR1
    └─ 如果超分不需要（输出≤输入）→ 释放 FBO 管线

渲染管线（每帧）：
  无超分：OES → [后处理shader] → 屏幕           (1 pass)
  有超分：OES → [后处理shader] → FBO → 超分引擎 → 屏幕  (2-3 pass)
```

## 超分引擎

### XEngine（硬件加速，华为 NPU）

- 库：`libxengine.so`，通过 dlopen 加载
- 头文件：`sdk/default/hms/native/sysroot/usr/include/xengine/`
- 检测：`HMS_XEG_GetString(XEG_EXTENSIONS)` 中包含 `"XEG_spatial_upscale"`

**SCISSOR 参数 (0x01) — 关键陷阱：**
- 定义**输入纹理采样区域**，不是输出视口
- 必须是 `unsigned int[4]`，**不能**用 `float[4]`（IEEE 754 表示会导致蓝屏）
- 正确值：`{0, 0, inputWidth, inputHeight}`（整个输入纹理）
- 错误值：`{0, 0, outputWidth, outputHeight}` → 画面只有左下角正常，其余蓝色填充

**每帧渲染流程：**
```cpp
unsigned int scissor[4] = {0, 0, inputWidth_, inputHeight_};
xegSpatialUpscaleParam(0x01, scissor);          // 设置输入裁剪
float sharp = upscaleSharpness_;
xegSpatialUpscaleParam(0x02, &sharp);           // 设置锐度 [0,1]
glViewport(renderX_, renderY_, renderW_, renderH_); // 设置输出区域
xegRenderSpatialUpscale(fboTexture_);           // 执行超分
```

> 参数在每帧设置而非初始化时设置，确保与当前 EGL context 匹配。

**纹理要求：**
- `GL_TEXTURE_2D`，1 mipLevel
- RGBA8 和 RGBA16F 均可正常工作
- 不需要 NativeBuffer 背书（neural upscale 才需要）

### FSR 1（AMD FidelityFX，GPU shader 实现）

两个 Pass：
1. **EASU**（Edge-Adaptive Spatial Upsampling）：方向自适应 lanczos 核上采样
2. **RCAS**（Robust Contrast Adaptive Sharpening）：对比度自适应锐化

**HDR 亮度系数：**
- SDR（BT.709）：`vec3(0.299, 0.587, 0.114)`
- HDR（BT.2020）：`vec3(0.2627, 0.6780, 0.0593)`
- 通过 `uniform int uIsHdr` 在 shader 中切换

**精度选择：**
- 使用 `precision mediump float`（对移动端保持性能，视觉无明显差异）

**中间 FBO：**
- EASU 输出到 `fsrFbo_`（renderWidth × renderHeight）
- RCAS 从 `fsrTexture_` 采样，输出到默认 FBO（屏幕）

## HDR 色彩空间设置（关键修复）

### 问题
解码器直出时，系统自动为 NativeWindow 设置 HLG/PQ 色彩空间元数据。但经过 GLPostProcessor 的 FBO 中转后，EGL surface 没有色彩空间信息，系统按 sRGB 处理导致色彩偏黄/偏淡。

### 解决方案
在 `Init()` 中根据 HDR 模式手动设置 NativeWindow 色彩空间：

```cpp
// HLG
OH_NativeWindow_SetColorSpace(displayWindow, OH_COLORSPACE_BT2020_HLG_FULL);
OH_NativeWindow_NativeWindowHandleOpt(displayWindow, SET_COLOR_GAMUT,
                                       NATIVEBUFFER_COLOR_GAMUT_BT2100_HLG);

// PQ (HDR10)
OH_NativeWindow_SetColorSpace(displayWindow, OH_COLORSPACE_BT2020_PQ_FULL);
OH_NativeWindow_NativeWindowHandleOpt(displayWindow, SET_COLOR_GAMUT,
                                       NATIVEBUFFER_COLOR_GAMUT_BT2100_PQ);
```

**要点：**
- `OH_NativeWindow_SetColorSpace` 和 `SET_COLOR_GAMUT` 两者都需要设置
- SDR→HDR 模式也需要设置（因为输出是 PQ 编码）
- SDR 模式不需要额外设置

### FBO 精度
- HDR 模式统一使用 `GL_RGBA16F`（保留 10-bit 色深精度）
- SDR 模式使用 `GL_RGBA8`（足够）
- XEngine 确认支持 RGBA16F 输入

## 原生分辨率优化

当串流分辨率 ≥ 屏幕分辨率时，超分不会带来画质提升。`InitUpscale()` 检测到 `outputWidth ≤ inputWidth && outputHeight ≤ inputHeight` 后：

1. 设置 `activeUpscale_ = OFF`
2. 释放 FBO 管线（`ReleaseFBO()`）
3. 设置 `upscaleMode_ = OFF`（避免 `IsActive()` 误判）
4. 如果没有其他后处理需求（`!IsActive()`），调用 `ReleaseInternal()` 释放整个管线

效果：无超分需求时，解码器直出到 XComponent NativeWindow，**零开销**。

## EGL Surface 尺寸

- 由 XComponent 布局决定（已包含 letterbox 计算）
- 通过 `eglQuerySurface(display, surface, EGL_WIDTH/EGL_HEIGHT)` 获取实际像素尺寸
- 作为 `renderWidth_/renderHeight_` 用于 glViewport
- `eglSwapInterval(display, 0)` 禁用 VSync 避免阻塞解码器回调线程

## 接口设计

### 管线激活判断

```cpp
// 旧接口（已废弃）
bool IsEnabled() const;              // 只看 enabled_ || sdrToHdr_

// 新接口
bool IsActive() const;               // ditherEnabled_ || sdrToHdr_ || upscaleMode_ != OFF
void SetDitherEnabled(bool);         // 原 SetEnabled，仅控制暗区增强
UpscaleMode GetActiveUpscaleMode();  // 实际生效的引擎（初始化后可能降级或关闭）
```

### 全局状态保留

超分参数保存在 `VideoDecoderInstance` 命名空间的全局变量中，跨解码器重建保留：
- `g_upscaleMode` / `g_upscaleSharpness` / `g_ditherEnabled`
- `MoonBridge_SetUpscaleMode()` 写入全局变量
- `VideoDecoder::Start()` 从全局变量恢复到新的 `GLPostProcessor` 实例

## 运行时状态查询

```
ArkTS: NativeModule.getActiveUpscaleMode()
  → NAPI: MoonBridge_GetActiveUpscaleMode()
    → GLPostProcessor::GetActiveUpscaleMode()
      → 返回 activeUpscale_（0=OFF, 1=XENGINE, 2=FSR1）
```

**UI 显示：**
- PerformanceOverlay：绿色文字显示引擎名称
- StreamPage Toast：启动后提示超分是否生效及分辨率信息

## 锐度调节

- 范围：0-100（SettingsPageV2 滑块），映射到 0.0-1.0
- 动态 subtitle 提示：
  - 0-20%：柔和自然（推荐写实类游戏）
  - 25-50%：适中锐化（适合大多数场景）
  - 55%+：强力锐化（可能出现液化/过锐伪影）
- 默认值：50%
