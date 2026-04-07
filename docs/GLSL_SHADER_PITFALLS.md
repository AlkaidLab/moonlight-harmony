# GLSL Shader 兼容性陷阱

> 目标设备：HUAWEI MatePad Mini · HarmonyOS 6.1 · arm64-v8a · GLES 3.0

## 设备特定限制

以下写法会导致 **shader 静默编译失败**（渲染输出全黑，无错误日志）：

### 1. `#define` 多行宏（`\` 续行）

```glsl
// ❌ 在该设备上编译失败
#define BT2020_TO_LMS mat3( \
    0.412109, 0.523926, 0.063965, \
    0.166748, 0.720459, 0.112793, \
    0.024170, 0.075440, 0.900390  \
)
```

### 2. `const mat3` 全局变量

```glsl
// ❌ 在该设备上编译失败
const mat3 BT2020_TO_LMS = mat3(
    0.412109, 0.523926, 0.063965,
    0.166748, 0.720459, 0.112793,
    0.024170, 0.075440, 0.900390
);
```

### 3. 函数内 `mat3()` 构造器（不稳定）

```glsl
// ⚠️ 部分矩阵能用，部分不能，无规律
vec3 rgb2020_to_lms(vec3 v) {
    return mat3(0.412109, ...) * v;  // 有时 OK，有时黑屏
}
```

### 4. 未使用的函数定义

即使函数从未被调用，仅仅定义在 shader 中也可能触发编译失败。

## 安全写法

### `dot()` 逐行点乘（最可靠）

```glsl
vec3 rgb2020_to_lms(vec3 v) {
    return vec3(
        dot(v, vec3(0.412109, 0.523926, 0.063965)),
        dot(v, vec3(0.166748, 0.720459, 0.112793)),
        dot(v, vec3(0.024170, 0.075440, 0.900390))
    );
}
```

### 调试方法论

1. **先用 passthrough 验证 shader 能编译**：`outColor = tex; return;`
2. **二分法定位**：逐步注释代码块，每次只启用一部分
3. **输出中间值作为颜色**：`outColor = vec4(intermediate_vec3, 1.0);`
   - 灰色 = 数值正常
   - 全黑 = shader 编译失败 或 数值为 0
   - 色偏 = 通道数值异常

## ICtCp 色彩空间实验总结

| 步骤 | 结果 | 结论 |
|------|------|------|
| PQ 编码/解码 | ✅ 灰色输出 | PQ 传递函数正确 |
| ICtCp 矩阵往返 | ✅ 灰色输出 | 矩阵数学正确 |
| 完整逆路径 PQ→线性→LMS→RGB→HLG | ❌ 暗区黑块 | `max(rgb, 0.0)` 截断精度误差 |
| `#define` 宏定义矩阵 | ❌ 全黑 | 设备不支持多行宏 |
| `const mat3` 全局 | ❌ 全黑 | 设备不支持 |
| `dot()` 函数 | ✅ 可用 | 最可靠方案 |

## 关键教训

- **实验前必须先 commit 能用的代码**。本次实验中，原始能用的 S-curve 算法从未被提交到 git，在多次迭代修改后完全丢失，不得不从算法原理重新构建。
- **GLES 3.0 规范合规 ≠ 设备实际支持**。`const mat3` 和 `#define` 多行宏都是合法 GLSL，但特定驱动不支持。
- **shader 编译失败无错误日志**。唯一的表现是输出全黑，必须通过控制变量法排查。

## `void main()` 丢失陷阱

FRAGMENT_SHADER_SRC 是 C++ 原始字符串字面量 `R"(...)"`，shader 源码长达 270+ 行。经过大量迭代修改后，`void main() {` 声明被意外删除，所有 shader 逻辑（`if` 分支）浮在全局作用域：

```
// 编译错误: 0:66: L0001: Typename expected, found 'if'
```

- 编译失败时 `InitShaders()` 失败 → `Init()` 返回 -1 → decoder 回退到直接渲染 → **后处理完全无效**
- **不会显示黑屏**，只是回退到无后处理状态，画面"看起来正常"但所有增强都不生效
- **检查清单**：每次修改 shader 后确认 `void main() {` 和匹配的 `}` 存在

## OES 纹理采样性能

`samplerExternalOES` 采样比普通 `sampler2D` 慢得多（移动 GPU 上）：

- 4 次额外邻域采样（十字邻域高光检测）导致解码时间大幅增加，L1 drain-to-latest 持续丢帧
- **规则**：避免对 OES 外部纹理做多次采样
- 如需邻域操作，先 blit 到 FBO（`sampler2D`）再做多次采样

## 部署调试流程陷阱

### 1. `bm install` 后必须强杀 app 进程

安装新 HAP 不会自动重载运行中进程已加载的 `.so`。必须：

```bash
hdc shell aa force-stop com.alkaidlab.sdream
```

否则进程继续使用旧 `.so`，误以为"部署无效"。

### 2. hilog buffer 溢出丢日志

串流初始化阶段各组件同时大量输出日志，关键的 shader 编译日志被丢弃：
```
write socket failed, 44 line(s) dropped!
```

对策：
- 减少初始化阶段的日志量（已注释 EGL config 详细日志）
- 排查前先 `hdc shell hilog -r` 清空缓冲区
- 使用 `hdc shell hilog -x` 读取完整 buffer

### 3. Git Bash 路径转换

`hdc file send ... /data/local/tmp/` 会被 Git Bash 转为 Windows 路径。修复：
```bash
hdc file send "C:\...\entry-default-signed.hap" //data/local/tmp/entry-default-signed.hap
#                                                ^^ 双斜杠避免路径转换
```

### 4. HAP 内 .so 文件名

```
libs/arm64-v8a/libmoonlight_nativelib.so   # ← 实际名称
# 不是 libnativelib.so
```

验证 HAP 内容：
```python
import zipfile
with zipfile.ZipFile('entry-default-signed.hap') as z:
    data = z.read('libs/arm64-v8a/libmoonlight_nativelib.so')
    for s in [b'void main', b'uSdrToHdr']:
        print(f'{"FOUND" if s in data else "MISSING"}: {s.decode()}')
```

## 完整部署流程（C++ 修改后）

```bash
# 1. 清理构建（必须！）
rm -rf nativelib/build entry/build

# 2. 构建
hvigorw assembleHap --mode module -p module=entry@default -p product=default --no-daemon

# 3. 推送安装
hdc file send "C:\...\entry-default-signed.hap" //data/local/tmp/entry-default-signed.hap
hdc shell bm install -r -p //data/local/tmp/entry-default-signed.hap

# 4. 强杀进程 + 清日志（关键！）
hdc shell aa force-stop com.alkaidlab.sdream
hdc shell hilog -r

# 5. 在设备上重新打开 app 并开始串流
```
