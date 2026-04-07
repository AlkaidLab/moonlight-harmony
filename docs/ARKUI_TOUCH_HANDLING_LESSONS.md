# ArkUI 触摸事件处理经验总结

> 源自 Moonlight HarmonyOS 虚拟控制器按钮响应问题的调试过程

## 问题描述

虚拟手柄的摇杆 (`AnalogStick`) 触摸响应正常，但所有按钮（ABXY、方向键、肩键、扳机等）极度不灵敏，需要反复点击才能偶尔触发一次。

## 根本原因

ArkUI 存在一个行为特征：**首次渲染时，组件的命中测试 (hit-test) 区域可能未正确建立**。需要通过一次额外的渲染周期来刷新命中测试树，使触摸区域正确注册。

摇杆不受影响是因为 `AnalogStick` 是独立 `@Component`，内部有 `@State stickX/stickY/isPressed`，触摸时这些状态变化会**持续触发自身重渲染**，从而自然地刷新了命中测试区域。

## 核心发现

### 1. 组件内部重渲染会破坏 `.onTouch()` 处理器

在 `VirtualController` 内部添加 `@State` 并触发重渲染：

```typescript
// ❌ 在按钮所在组件内部触发重渲染 — 会破坏触摸处理器
@State private layoutTrigger: number = 0;
aboutToAppear() {
  setTimeout(() => { this.layoutTrigger = 1; }, 100);
}
```

**结果**：初始灵敏，但重渲染后按钮**永久失去响应**。原因是 ArkUI 重新执行 `build()` 时，所有 `.onTouch()` 处理器被重新绑定，期间触摸事件的注册链断裂。

### 2. 父组件重渲染可以安全刷新命中测试区域

在 `VirtualControllerOverlay`（父层）触发重渲染：

```typescript
// ✅ 在父容器触发重渲染 — 刷新命中测试但不重建子组件处理器
@State private hitTestReady: number = 0;
aboutToAppear() {
  setTimeout(() => { this.hitTestReady = 1; }, 100);
}
build() {
  Stack() {
    VirtualController({ controllerScale: this.controllerScale, ... })
  }
  .opacity(this.hitTestReady > 0 ? 1 : 0.99) // 微不可见的变化触发渲染
}
```

**结果**：按钮从进入串流起就灵敏响应。父层重渲染使 ArkUI 重新计算整棵子树的命中测试区域，但 `VirtualController` 的 `@Prop controllerScale` 值不变 → **V2 不重渲染** → `.onTouch()` 处理器完好无损。

### 3. `@Prop` 对象字面量导致不必要的重渲染

```typescript
// ❌ @Prop 接收对象字面量 — 每次父组件渲染都创建新引用
@Prop config: VirtualControllerConfig = {};

// 父组件 build() 中：
VirtualController({
  config: { opacity: 0.75, ... } as VirtualControllerConfig // 每次都是新对象
})
```

`@Observed` 的 `StreamViewModel` 任何属性变化（如性能统计每秒更新）都可能触发 StreamPage 重评估 → 创建新 config 对象 → `@Prop` 深比较失败 → V2 重渲染 → 触摸中断。

**修复**：将 `config` 改为普通属性（不使用 `@Prop`），仅在构造时设置一次。

```typescript
// ✅ 普通属性，父组件重渲染时不会传导
config: VirtualControllerConfig = {};
```

### 4. `event.stopPropagation()` 防止事件冒泡干扰

按钮触摸事件未阻止冒泡时，可能被父容器（Stack/Column）或 XComponent 消费。

```typescript
private handleButtonTouch(button: ControllerButton, event: TouchEvent): void {
  event.stopPropagation(); // ✅ 防止触摸事件冒泡到父容器
  // ... 处理逻辑
}
```

### 5. 父容器的空 `.onTouch(() => {})` 可能干扰子组件

```typescript
// ❌ 空触摸处理器可能参与命中测试竞争
Stack() { ... }
  .hitTestBehavior(HitTestMode.Default)
  .onTouch(() => {})

// ✅ 仅使用 hitTestBehavior 控制命中测试，不添加空处理器
Stack() { ... }
  .hitTestBehavior(HitTestMode.Default)
```

### 6. ArkTS struct 字段初始化器中的 `this` 绑定问题

```typescript
// ⚠️ 字段初始化器中 this 可能不指向代理实例
private handler: (e: TouchEvent) => void = (e) => {
  this.someMethod(e); // 'this' 可能是原始 struct 而非 ArkUI 代理
};

// ✅ 在 build() 中使用内联 lambda — this 绑定正确
.onTouch((event: TouchEvent) => this.handleButtonTouch(button, event))
```

## 最终解决方案

组合以下四项修复：

| 修复项 | 位置 | 作用 |
|--------|------|------|
| `config`/`touchPassthrough` 移除 `@Prop` | VirtualController | 防止父组件重渲染传导 |
| `event.stopPropagation()` | handleButtonTouch/handleTriggerTouch | 防止事件冒泡干扰 |
| 移除 `.onTouch(() => {})` | VirtualControllerOverlay | 消除空处理器竞争 |
| `@State hitTestReady` + setTimeout | VirtualControllerOverlay | 父层触发一次重渲染刷新命中测试区域 |

## 设计模式：AnalogStick 为何天然工作

`AnalogStick` 的模式天然适合 ArkUI 触摸处理：

1. **独立 `@Component`** — 自有 build 生命周期，父组件重渲染不会重建其处理器
2. **内部 `@State`** — `stickX/stickY/isPressed` 在触摸时持续变化 → 持续重渲染 → 命中测试区域持续刷新
3. **`HitTestMode.Block`** — 根节点 Stack 上设置，确保命中测试优先级高
4. **大触摸区域** — 110vp 的圆形区域，命中率高

## 调试流程要点

1. 对比**正常工作**与**异常**组件的差异（AnalogStick vs 按钮）
2. 逐步排除：
   - `Button()` → `Column()`（排除内置手势竞争）
   - 添加 `HitTestMode.Block`（排除兄弟节点命中竞争）
   - 移除 `@State`（排除重渲染中断触摸链）
   - 移除 `@Prop`（排除父组件传导重渲染）
3. 关注用户描述中的**时序信息**："一进入不行" vs "操作摇杆后好使"
4. 区分修复触发器的位置：**组件内部 vs 父层** — 效果完全不同
