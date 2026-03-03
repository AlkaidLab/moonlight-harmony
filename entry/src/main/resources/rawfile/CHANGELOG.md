# 更新日志

<!-- 
  格式说明（请严格遵循）：
  
  ## [版本号] - YYYY-MM-DD
  版本摘要（可选，单独一行）
  
  ### 新增
  - 变更描述
  
  ### 优化
  - 变更描述
  
  ### 修复
  - 变更描述
  
  ### 移除
  - 变更描述
  
  注意：
  - 版本号部分必须用 `## [x.x.x] - YYYY-MM-DD` 格式
  - 类型标题必须是：新增、优化、修复、移除 之一
  - 每条变更以 `- ` 开头
  - 最新版本放在最前面
-->

## [1.0.0.725] - 2025-07-15
USB 手柄高速轮询 + 帧顿卡修复

### 新增
- USB DDK 高速轮询：基于 HarmonyOS USB DDK 原生同步 API，绕过 usbManager IPC 瓶颈
- Xbox 360/One、DualShock 4/DualSense 自动尝试 DDK 路径，失败自动回退 usbManager
- 更新日志页面：设置中可查看版本更新历史

### 优化
- Xbox 360 手柄轮询率从 ~130Hz 提升至 ~210Hz（硬件上限的 84%）
- USB High Speed 控制器理论可达 1000Hz 轮询率

### 修复
- 修复长时间串流后帧顿卡问题（每帧无用 tsfn 派发导致 GC 压力累积）
- 修复 tsfn 关闭期间 12 处内存泄漏（nonblocking 调用未检查返回值）
- 修复 Game Controller Kit 回调 env=NULL 时的未定义行为（tsfn teardown 阶段）

### 移除
- 移除失败的 ioctl USB 轮询方案（被 HarmonyOS 安全沙箱阻止）
- 移除 DDK 可行性测试代码

## [1.0.0] - 2025-01-01
首个公开版本

### 新增
- 支持 H.264/HEVC 硬件解码
- 支持 4K@120fps 高清串流
- 支持 HDR10/HLG 高动态范围
- 支持 VRR 可变刷新率
- Game Controller Kit 鸿蒙原生手柄支持
- 体感助手 (Gyro Aim) 陀螺仪辅助瞄准
- 空间音频支持 (HarmonyOS 5.0+)
- 麦克风重定向语音开黑
- 可拖拽自定义性能覆盖层
- 虚拟显示器无缝连接
