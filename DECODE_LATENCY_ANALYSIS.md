# HarmonyOS 高帧率解码延迟分析

## 问题描述

在高帧率（90Hz/120Hz）串流场景下，解码时间会偶发性地出现较大波动。

## 根本原因分析

### 1. I帧/关键帧影响

这是**最主要的原因**。视频编码中：
- **I帧（关键帧）**：完整的图像数据，通常是 P帧的 **5-10 倍大小**
- **P帧**：只包含与前一帧的差异
- Moonlight 默认每 **2-3 秒**发送一个 I帧

因此，每 2-3 秒会有一帧的解码时间显著高于平均值，这是**完全正常的行为**。

### 2. 硬件解码器管线特性

HarmonyOS 使用的是硬件视频解码器（VPU），其内部有：
- 输入缓冲队列
- 解码管线
- 输出缓冲队列

这些管线会引入不确定的延迟抖动，尤其在：
- 队列切换时
- 硬件资源竞争时
- 温控降频时

### 3. 系统调度影响

即使设置了高优先级的 QoS，系统仍可能因为：
- 其他高优先级任务
- GPU/VPU 资源竞争
- 内存带宽限制

导致偶发的解码延迟。

## HarmonyOS API 限制

与 Android 相比，HarmonyOS **缺少**以下关键 API：

| Android API | 用途 | HarmonyOS 等效 |
|-------------|------|----------------|
| `KEY_PRIORITY` | 设置解码器优先级 | ❌ 不存在 |
| `KEY_OPERATING_RATE` | 设置目标运行帧率 | ❌ 不存在 |
| `KEY_LOW_LATENCY` | 低延迟模式 | ✅ `OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY` |

## 已实施的优化

### 1. 低延迟模式（已启用）
```cpp
OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
```

### 2. 缓冲区数量优化
```cpp
// 用户可在设置中自定义缓冲区数量 (0=系统默认, 2-8=自定义)
// 完全尊重用户设置，不再有高帧率时的强制限制
int bufferCount = config_.bufferCount;
if (bufferCount > 0) {
    bufferCount = std::clamp(bufferCount, 2, 8);
    OH_AVFormat_SetIntValue(format, OH_MD_MAX_INPUT_BUFFER_COUNT, bufferCount);
    OH_AVFormat_SetIntValue(format, OH_MD_MAX_OUTPUT_BUFFER_COUNT, bufferCount);
}
```

**缓冲区数量建议**：
- `0` (默认)：系统自动决定，适合大多数场景
- `2-3`：最低延迟，但可能丢帧
- `4-5`：平衡延迟和稳定性
- `6-8`：更好的稳定性，适合高帧率(90-120fps)或网络不稳时

### 3. QoS 线程优先级
```cpp
// 设置解码线程为高优先级
OH_QoS_SetThreadQoS(QOS_DEADLINE_REQUEST);
```

### 4. 动态超时调整
```cpp
// 根据帧率动态调整输入缓冲区等待超时
int timeoutMs = std::min(50, std::max(16, 2000 / fps));
```

### 5. I帧权重调整
```cpp
// 统计平均解码时间时，降低 I帧的权重
// 避免 I帧的高解码时间过度影响统计数据
double alpha = isLikelyKeyframe ? 0.03 : 0.1;
```

## 预期行为

| 场景 | 典型解码时间 | 说明 |
|------|-------------|------|
| 60fps P帧 | 2-5ms | 正常范围 |
| 60fps I帧 | 8-15ms | 每2-3秒一次 |
| 120fps P帧 | 1-3ms | 正常范围 |
| 120fps I帧 | 5-10ms | 每2-3秒一次 |

## 进一步优化建议

### 1. 服务端调整
如果使用 NVIDIA GeForce Experience 或 Sunshine：
- 减小 GOP 间隔（如 60 帧/GOP 而不是 120）
- 使用恒定比特率（CBR）而非可变比特率
- 考虑使用 HEVC（更高效的 I帧编码）

### 2. 客户端 UI 显示
- 在性能叠加层显示"平均解码时间"而非"最新解码时间"
- 可以添加"P95 解码时间"作为更稳定的指标
- 对于 I帧导致的尖峰，可以特别标注

### 3. 监控与诊断
```cpp
// 可以添加 I帧计数器用于诊断
if (attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) {
    keyframeCount++;
    lastKeyframeDecodeTime = decodeTimeMs;
}
```

## 结论

解码时间的周期性波动（每 2-3 秒出现一次高值）是视频编码的**固有特性**，而非 bug。

只要：
- 平均解码时间保持在帧间隔的 50% 以下（如 120fps 时 < 4ms）
- 用户体验流畅，没有明显卡顿
- 丢帧率保持在可接受范围内

则解码性能是正常的。
