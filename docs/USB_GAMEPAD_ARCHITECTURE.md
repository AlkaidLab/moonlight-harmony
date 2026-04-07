# USB 手柄处理架构

## 系统总览

```mermaid
graph LR
    subgraph APP ["🎮 应用层"]
        GM["GamepadManager<br/>手柄管理器"]
        Stream["串流会话"]
    end

    subgraph SERVICE ["🔌 USB 驱动服务"]
        UDS["UsbDriverService 单例"]
        Timer["⏱ 5s 重扫定时器"]
        Events["📡 USB 插拔事件监听"]
    end

    subgraph CTRL ["🎯 控制器"]
        direction TB
        Xbox["Xbox 系列<br/>360 / One"]
        PS["PlayStation 系列<br/>DS4 / DualSense"]
        SW["Switch Pro"]
        HID["通用 HID<br/>NativeHidController"]
    end

    subgraph IO ["⚡ 数据通道"]
        DDK["DDK 高速轮询<br/>pthread · ~500Hz"]
        USBM["usbManager IPC<br/>bulkTransfer"]
    end

    GM -->|输入上报| Stream
    UDS -->|生命周期管理| CTRL
    Timer -.->|周期检查| UDS
    Events -.->|插拔通知| UDS
    CTRL -->|reportInput| GM

    Xbox ==>|优先| DDK
    PS ==>|优先| DDK
    Xbox -.->|回退| USBM
    PS -.->|回退| USBM
    SW -->|仅| USBM
    HID -->|仅| USBM
```

## 设备发现与驱动选择

```mermaid
flowchart TD
    A["🔌 USB 设备插入"] --> B["枚举设备列表"]
    B --> C{"识别为手柄?"}
    C -->|否| C1["跳过"]
    C -->|是| D{"有 USB 权限?"}
    D -->|有| F
    D -->|无| E["弹出权限请求"]
    E -->|拒绝| E1["标记已处理<br/>不再询问"]
    E -->|授权| F["打开设备连接"]
    F --> G{"匹配驱动"}
    G --> G1["Xbox One"]
    G --> G2["Xbox 360"]
    G --> G3["DualSense"]
    G --> G4["DualShock 4"]
    G --> G5["Switch Pro"]
    G --> G6["通用 HID"]
    G1 & G2 & G3 & G4 & G5 & G6 --> H["启动控制器"]
    H --> I{"DDK 可用?"}
    I -->|是| J["🚀 DDK 高速模式"]
    I -->|否| K["📦 usbManager 模式"]

```

## DDK vs usbManager 双路径

```mermaid
flowchart LR
    subgraph DDK ["🚀 DDK 高速路径"]
        direction TB
        D1["加载 libusb_ndk.z.so"] --> D2["查找设备 (VID/PID)"]
        D2 --> D3["关闭 usbManager 管道"]
        D3 --> D4["ClaimInterface<br/>+ CreateMemMap"]
        D4 --> D5["启动 pthread 轮询"]
        D5 --> D6["SendPipeRequest 循环<br/>~500Hz 原生读取"]
        D6 -->|threadsafe callback| D7["JS 层 handleRead"]
    end

    subgraph USB ["📦 usbManager 路径"]
        direction TB
        U1["claimInterface"] --> U2["async bulkRead 循环"]
        U2 --> U3["handleRead"]
    end

    Start["controller.start()"] ==>|优先| D1
    Start -.->|DDK 不可用<br/>或启动失败| U1
    D4 -->|失败| Recover["恢复 usbManager 管道"]
    Recover --> U1

```

## DDK 轮询线程状态机

```mermaid
flowchart TD
    Loop["🔄 轮询循环开始"] --> Out{"有待发数据?<br/>(rumble/init)"}
    Out -->|是| SendOut["发送输出"]
    Out -->|否| Read
    SendOut --> Read

    Read["📥 读取输入<br/>SendPipeRequest"] --> Ret{"结果"}

    Ret -->|✅ 成功| Dup{"数据变化?"}
    Dup -->|相同| Skip["跳过 (去重)"]
    Dup -->|不同| Freq{"间隔 ≥ 2ms?"}
    Freq -->|否| Skip
    Freq -->|是| CB["📤 回调 JS 层"]
    CB --> WasErr{"之前有错误?"}
    WasErr -->|是| Heal["发送恢复信号 ✅"]
    WasErr -->|否| Loop
    Heal --> Loop
    Skip --> Loop

    Ret -->|⏱ 超时| Loop
    Ret -->|❌ IO 错误| Inc["错误计数 +1"]
    Inc --> Wait["退避等待<br/>50~200ms"]
    Wait --> Check{"累计 > 50?<br/>(约 10 秒)"}
    Check -->|否| Loop
    Check -->|是| Die["💀 归零输入<br/>通知致命错误<br/>线程退出"]

    Ret -->|⛔ 其他错误| Die2["💀 直接退出"]

```

## 断开与重连时序

```mermaid
sequenceDiagram
    participant USB as 🔌 USB 总线
    participant OS as 📱 HarmonyOS
    participant SVC as 🏗 UsbDriverService
    participant CTRL as 🎮 控制器
    participant DDK as ⚡ DDK 线程

    rect rgb(255, 235, 238)
    Note over USB: 场景 A · 物理拔出
    USB->>OS: disconnect
    OS->>SVC: DEVICE_DETACHED
    SVC->>SVC: 检查哪些控制器断开
    SVC->>CTRL: stop()
    CTRL->>DDK: 停止轮询
    CTRL->>SVC: deviceRemoved()
    SVC->>SVC: 清理记录
    end

    rect rgb(232, 245, 233)
    Note over USB: 设备重新插入
    USB->>OS: connect
    OS->>SVC: DEVICE_ATTACHED
    SVC->>SVC: 延迟 500ms 枚举
    SVC->>OS: 检查权限
    alt 权限有效
        SVC->>SVC: 创建新控制器 → start()
        SVC->>CTRL: ✅ 手柄恢复
    else 权限丢失
        SVC->>OS: 弹出权限弹窗 ⚠️
    end
    end

    rect rgb(227, 242, 253)
    Note over USB: 场景 B · 电源波动 (DDK 模式)
    USB->>DDK: IO_FAILED
    DDK->>DDK: 退避重试 (50~200ms)
    alt 10 秒内设备恢复
        USB->>DDK: 读取成功
        DDK->>CTRL: 恢复信号 ✅
    else 超过 10 秒
        DDK->>CTRL: 归零输入 + 致命错误
        CTRL->>CTRL: stop()
        Note over SVC: 等待 5s rescan
        SVC->>SVC: 检测到设备 → 重新创建控制器
    end
    end
```

## 设备标识与权限模型

```mermaid
graph TB
    subgraph IDS ["🏷 三种设备标识"]
        DN["device.name<br/><i>系统分配的路径</i>"]
        DK["deviceKey<br/><i>VID:PID:busNum:devAddress</i>"]
        DDKId["DDK deviceId<br/><i>uint64 总线编号</i>"]
    end

    DN -->|绑定| PERM["🔑 USB 权限<br/>hasRight / requestRight"]
    DK -->|绑定| PROC["📋 已处理设备集合<br/>processedDevices"]
    DDKId -->|绑定| CLAIM["🔗 DDK 接口声明<br/>ClaimInterface"]

    subgraph RISK ["⚠️ 电源波动后"]
        R1["devAddress 可能变化"]
        R1 --> R2["device.name 变化"]
        R1 --> R3["deviceKey 变化"]
        R2 --> R4["权限失效 ❌"]
        R3 --> R5["视为新设备 ✅<br/>但需重新授权"]
    end

```

## 已知限制与脆弱点

```mermaid
graph LR
    subgraph HIGH ["🔴 高风险"]
        P1["权限丢失<br/>电源波动导致 devAddress 变化<br/>串流中弹权限弹窗<br/>用户无法操作确认"]
    end

    subgraph MED ["🟡 中风险"]
        P2["无温和恢复<br/>DDK IO 错误只能退避重试<br/>不支持 release + re-claim<br/>50 次后必须整体重建"]
        P3["重连延迟长<br/>10s 错误检测 + 5s 定时器<br/>最长约 15s 无输入"]
    end

    subgraph LOW ["🟢 低风险"]
        P4["接口竞争窗口<br/>closePipe → ClaimInterface<br/>之间内核驱动可能抢占<br/>5 次重试可缓解"]
        P5["多设备匹配<br/>DDK findDevice 按 VID/PID<br/>相同型号多手柄可能误匹配<br/>有 makeDeviceId 后备"]
    end

```

## 文件清单

| 文件 | 职责 |
|------|------|
| `UsbDriverService.ets` | 单例服务：设备枚举、权限、生命周期、5s rescan |
| `AbstractController.ets` | 控制器基类：状态机、输入状态、reportInput |
| `AbstractXboxController.ets` | Xbox 协议基类：DDK/usbManager 双路径、输入循环 |
| `AbstractDualSenseController.ets` | DualSense 协议基类：触摸板、陀螺仪 |
| `Xbox360Controller.ets` | Xbox 360 协议解析 |
| `XboxOneController.ets` | Xbox One 协议解析 |
| `DualSenseController.ets` | PS5 DualSense 协议 |
| `Dualshock4Controller.ets` | PS4 DS4 协议 |
| `SwitchProController.ets` | Switch Pro 协议 |
| `NativeHidController.ets` | 通用 HID：C++ 原生解析器 |
| `DdkUsbPoller.ets` | DDK 封装：NAPI 桥接层 |
| `usb_ddk_poller.cpp` | DDK 原生层：pthread 轮询、memMap、错误恢复 |
| `ControllerConstants.ets` | 常量：按钮标志、控制器类型 |
| `UsbErrorCodes.ets` | USB 错误码映射 |
