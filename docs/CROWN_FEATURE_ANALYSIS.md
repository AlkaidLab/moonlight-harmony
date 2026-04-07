# 王冠功能（自定义按键）架构分析与鸿蒙移植方案

## 一、Android 王冠功能架构分析

### 1.1 功能概述

Android 版 moonlight 的「王冠功能」是一套串流中使用的**自定义虚拟按键系统**，允许用户：

- 在串流画面上创建和摆放自定义虚拟按键（键盘键、鼠标键、手柄键）
- 多种按键形态：普通按钮、切换按钮、可拖拽按钮、方向盘、摇杆、组合按钮等
- 将多个按键编排为"配置"，支持配置间的快速切换
- 导入/导出/合并配置文件（JSON 格式）
- 配置内嵌串流设置（触屏灵敏度、触屏模式、震动开关等）

### 1.2 核心文件清单

| 文件 | 职责 |
|------|------|
| `ControllerManager.java` | **中枢管理器**，懒加载持有所有子控制器和 DB Helper |
| `ElementController.java` | **元素控制器**，管理所有虚拟按键的生命周期、加载/创建/删除、事件分发 |
| `Element.java` | **按键基类**（继承 View），定义通用列名、类型常量、编辑模式拖拽逻辑 |
| `DigitalCommonButton.java` | 普通按键实现（点击→按下/释放） |
| `DigitalSwitchButton.java` | 切换按键（点击 toggle） |
| `DigitalMovableButton.java` | 可拖拽按键（带触控区域） |
| `DigitalCombineButton.java` | 组合按键（同时发送多个键） |
| `GroupButton.java` | 按键组（子元素的容器） |
| `DigitalPad.java` | 方向面板（上下左右 4 键） |
| `AnalogStick.java` / `DigitalStick.java` | 摇杆（模拟/数字） |
| `InvisibleAnalogStick.java` / `InvisibleDigitalStick.java` | 隐形摇杆 |
| `WheelPad.java` | 滚轮垫 |
| `SimplifyPerformance.java` | 性能显示元素 |
| `SuperConfigDatabaseHelper.java` | **SQLite 持久化**，管理配置表和元素表 |
| `PageConfigController.java` | **配置页控制器**，管理配置列表、切换、创建/删除 |
| `PageSuperMenuController.java` | 超级菜单 UI 控制器 |
| `KeyboardUIController.java` | 内置 PC 键盘覆盖层控制器 |
| `KeyCodeMapper.java` | Android KeyCode → Windows VK 转换 |
| `Game.java` | 串流主 Activity，集成王冠功能开关 |

### 1.3 数据模型

#### 配置表 (config)

| 字段 | 类型 | 说明 |
|------|------|------|
| config_id | INTEGER | 配置唯一 ID |
| config_name | TEXT | 配置名称 |
| touch_enable | TEXT | 触屏启用 |
| touch_mode | TEXT | 触屏模式 |
| touch_sense | INTEGER | 触屏灵敏度 |
| game_vibrator | TEXT | 游戏震动 |
| button_vibrator | TEXT | 按钮震动 |
| mouse_wheel_speed | INTEGER | 鼠标滚轮速度 |
| enhanced_touch | TEXT | 增强触控 |

#### 元素表 (element)

| 字段 | 类型 | 说明 |
|------|------|------|
| element_id | INTEGER | 元素唯一 ID（时间戳） |
| config_id | INTEGER | 所属配置 ID |
| element_type | INTEGER | 元素类型（0=普通按钮, 1=切换按钮, 2=可拖, 3=组合, 4=组, 20=方向盘...） |
| element_value | TEXT | 绑定的键值（格式: `k<VK码>` 或 `m<鼠标码>` 或特殊键字符串） |
| element_text | TEXT | 显示文字 |
| element_central_x/y | INTEGER | 中心坐标 |
| element_width/height | INTEGER | 尺寸 |
| element_layer | INTEGER | 层级 |
| element_radius | INTEGER | 圆角半径 |
| element_opacity | INTEGER | 透明度 |
| element_color | INTEGER | 常态颜色 |
| element_pressed_color | INTEGER | 按下颜色 |
| element_background_color | INTEGER | 背景色 |
| normalTextColor | INTEGER | 文字颜色 |
| pressedTextColor | INTEGER | 按下文字颜色 |
| textSizePercent | INTEGER | 文字大小百分比 |
| extra_attributes | TEXT | 扩展属性（JSON） |
| element_flag1 | INTEGER | 标志位 |

### 1.4 事件发送链路

```
用户触摸虚拟按钮
  → Element.onTouchEvent (DigitalCommonButton等)
    → listener.onClick() / onRelease()
      → SendEventHandler.sendEvent(boolean down)
        ├── 键盘键: ElementController.sendKeyEvent(down, vkCode)
        │     └── Game.keyboardEvent(down, keyCode) → MoonBridge.sendKeyboardInput()
        ├── 鼠标键: ElementController.sendMouseEvent(mouseId, down)
        │     └── Game.mouseButtonEvent(mouseId, down) → MoonBridge.sendMouseButton()
        ├── 鼠标滚轮: ElementController.sendMouseScroll(direction)
        │     └── Game.mouseVScroll(direction) → MoonBridge.sendMouseScroll()
        └── 手柄键: ElementController.sendGamepadEvent()
              └── ControllerHandler.reportOscState() → MoonBridge.sendMultiControllerInput()
```

键值字符串解析规则（`element_value`）：
- `k<int>` → 键盘键（如 `k27` = ESC, `k65` = A）
- `m<int>` → 鼠标按键（如 `m1` = 左键）
- `LS/RS` → 手柄左/右摇杆
- `lt/rt` → 手柄左/右触发
- `SU/SD` → 鼠标滚轮上/下
- `MMS/CMS/TPM/MTM` → 鼠标模式切换
- `PKS/AKS` → PC/安卓键盘切换
- `CSW` → 切换配置
- `OGM` → 打开游戏菜单
- `EMS` → 编辑模式切换
- `null` → 空操作

### 1.5 配置导入/导出

- **格式**: JSON（使用 Gson，含版本号和 MD5 校验）
- **结构**: `{ version, settings (JSON string), elements (JSON string), md5 }`
- **版本升级**: `upgradeExportedConfig()` 方法实现 fall-through 逐级升级
- **合并**: 支持将新配置的元素合并到已有配置中

### 1.6 UI 集成（Game.java）

```java
// 王冠模式切换
setCrownFeatureEnabled(true/false)  → ControllerManager.show()/hide()
// 返回键菜单模式
BackKeyMenuMode { GAME_MENU, CROWN_MODE }
// 初始偏好检查
prefConfig.onscreenKeyboard → 是否启用王冠功能
```

### 1.7 架构问题与改进空间

| 问题 | 说明 |
|------|------|
| **SQLite 过重** | 虚拟按键数据用 SQLite 存储，对于通常 10-30 个按键的场景过重 |
| **Java 反射式键值解析** | element_value 用字符串前缀标记类型（`k123`, `m1`），缺乏类型安全 |
| **编辑模式耦合严重** | ElementController 既做运行时事件分发，又做编辑模式 UI |
| **View 直接继承** | Element 继承 Android View，逻辑与渲染耦合 |
| **配置切换慢** | 每次切换配置需要完全删除+重建所有 View |
| **DB 升级脆弱** | 每加一个字段就加一个版本号，fall-through switch 易出错 |

---

## 二、HarmonyOS 现有键盘基础设施

### 2.1 已有组件

| 组件 | 文件 | 功能 |
|------|------|------|
| VirtualKeyboard | `VirtualKeyboard.ets` | PC 风格全键盘覆盖层，支持修饰键粘滞、背景图、透明度调节 |
| StreamIMEManager | `StreamIMEManager.ets` | 系统 IME 键盘管理（用于中文输入） |
| KeyboardTranslator | `KeyboardTranslator.ets` | HarmonyOS KeyCode → Windows VK 转换 |
| InputInterceptor | `input_interceptor.cpp` | 原生层按键拦截（含音量键回注） |
| GameMenuDialog | `GameMenuDialog.ets` | 串流菜单（键盘切换入口） |

### 2.2 现有 VirtualKeyboard 的优势

- 声明式 UI（ArkUI），渲染与逻辑分离
- 组合键模式（修饰键粘滞 toggle）
- 背景图 + 透明度调节
- 拖拽移动
- VK 码直接映射

### 2.3 缺失能力

| 缺失功能 | Android 对标 |
|----------|-------------|
| **自定义按键** | Element 系列：用户自由创建/摆放按钮 |
| **配置管理** | config 表：多套配置切换 |
| **编辑模式** | 拖拽调整位置/大小/属性 |
| **导入/导出** | JSON 序列化配置共享 |
| **多类型按键** | 组合键、切换键、摇杆、方向盘 |

---

## 三、鸿蒙移植方案设计

### 3.1 设计原则

1. **声明式优先**: 利用 ArkUI 的响应式数据绑定，UI 自动更新
2. **轻量持久化**: 用 Preferences JSON 替代 SQLite
3. **类型安全**: TypeScript 接口 + 联合类型定义，替代字符串前缀
4. **关注点分离**: 数据模型 / 配置管理 / 渲染 / 事件发送 分层解耦
5. **可扩展**: 按键类型用注册机制，便于后续添加

### 3.2 架构总览

```
┌──────────────────────────────────────────────────────┐
│                    StreamPage                        │
│  ┌─────────────┐  ┌────────────────┐                 │
│  │ GameMenu    │  │ CustomKeyOverlay│ ← 渲染层       │
│  │ Dialog      │  │ (ForEach keys) │                 │
│  └──────┬──────┘  └────────┬───────┘                 │
│         │                  │                         │
│  ┌──────▼──────────────────▼───────┐                 │
│  │     CustomKeyViewModel          │ ← 状态管理      │
│  │  @State keys: CustomKeyDef[]    │                 │
│  │  @State currentProfile: string  │                 │
│  │  @State editMode: boolean       │                 │
│  └──────────────┬──────────────────┘                 │
│                 │                                    │
│  ┌──────────────▼──────────────────┐                 │
│  │     CustomKeyStore              │ ← 持久化        │
│  │  Preferences (JSON)             │                 │
│  │  profiles: { [name]: KeyDef[] } │                 │
│  └──────────────┬──────────────────┘                 │
│                 │                                    │
│  ┌──────────────▼──────────────────┐                 │
│  │     KeyEventSender              │ ← 事件发送      │
│  │  sendKeyboard / sendMouse /     │                 │
│  │  sendGamepad / sendSpecial      │                 │
│  └─────────────────────────────────┘                 │
└──────────────────────────────────────────────────────┘
```

### 3.3 数据模型（TypeScript 接口）

```typescript
/** 按键动作类型 */
type KeyAction =
  | { type: 'keyboard'; vk: number }           // 键盘键
  | { type: 'mouse'; button: number }           // 鼠标按键
  | { type: 'mouseScroll'; direction: number }  // 鼠标滚轮
  | { type: 'gamepadButton'; mask: number }     // 手柄按键
  | { type: 'gamepadStick'; stick: 'L'|'R' }   // 手柄摇杆
  | { type: 'gamepadTrigger'; side: 'L'|'R' }  // 手柄触发
  | { type: 'combo'; actions: KeyAction[] }     // 组合键
  | { type: 'special'; id: string }             // 特殊功能

/** 按键形态 */
type KeyShape = 'rect' | 'circle' | 'dpad' | 'stick'

/** 自定义按键定义 */
interface CustomKeyDef {
  id: string               // UUID
  label: string            // 显示文字
  action: KeyAction        // 绑定动作
  shape: KeyShape          // 形态
  x: number                // 中心 X (vp)
  y: number                // 中心 Y (vp)
  width: number            // 宽度 (vp)
  height: number           // 高度 (vp)
  layer: number            // 层级
  opacity: number          // 透明度 0-100
  borderRadius: number     // 圆角
  normalColor: string      // 常态颜色
  pressedColor: string     // 按下颜色
  bgColor: string          // 背景色
  textColor: string        // 文字颜色
  fontSize: number         // 文字大小
  isToggle: boolean        // 是否切换模式
}

/** 配置档案 */
interface CustomKeyProfile {
  name: string
  keys: CustomKeyDef[]
  settings: {
    touchSensitivity: number
    mouseWheelSpeed: number
    hapticFeedback: boolean
  }
}
```

### 3.4 与 Android 实现的关键差异

| 维度 | Android | HarmonyOS（方案） |
|------|---------|------------------|
| UI 框架 | 命令式 View | 声明式 ArkUI @Builder |
| 持久化 | SQLite | Preferences JSON |
| 按键渲染 | Canvas 自绘 | 组件树 + 样式绑定 |
| 按键类型 | 字符串前缀 `k123` | 联合类型 `{ type, vk }` |
| 编辑模式 | View 内部判断 mode | @State editMode 驱动条件渲染 |
| 配置切换 | 删除 View + 重建 | 替换 @State 数据，ArkUI diff 渲染 |
| 事件反馈 | Handler.postDelayed 冗余发送 | 直接调用 NativeSession API |
| 组合键 | DigitalCombineButton 持有多个键值 | combo 类型 actions 数组 |

### 3.5 实现优先级

| 优先级 | 功能 | 说明 |
|--------|------|------|
| P0 | 自定义按键渲染 + 键盘/鼠标事件发送 | 核心能力 |
| P0 | 编辑模式（拖拽、调大小） | 必须可配置 |
| P1 | 配置档案管理（创建/切换/删除） | 多场景适配 |
| P1 | 按键属性编辑面板 | 细节调优 |
| P2 | 手柄虚拟键支持 | 补充能力 |
| P2 | 导入/导出 | 配置共享 |
| P3 | 摇杆 / 方向盘控件 | 高级形态 |

---

## 四、总结

Android 王冠功能的核心价值在于**让用户自由创建和编排屏幕按键**，覆盖键盘/鼠标/手柄三类输入。其架构以 SQLite 数据库为核心，通过 ElementController 管理按键生命周期，Element 继承 View 实现自绘渲染。

鸿蒙移植应充分利用 ArkUI 的声明式特性：**数据驱动 UI**，用 JSON Preferences 替代 SQLite，用 TypeScript 联合类型替代字符串前缀，从而获得更好的类型安全、更简洁的代码和更流畅的编辑体验。
