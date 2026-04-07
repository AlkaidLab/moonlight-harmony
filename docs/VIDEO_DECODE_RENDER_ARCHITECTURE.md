# 视频解码送显架构

## 系统总览

```mermaid
graph LR
    subgraph NET ["📡 网络接收"]
        RTP["RTP 视频流<br/>VideoStream.c"]
        DEPKT["解包成帧<br/>VideoDepacketizer.c"]
    end

    subgraph BRIDGE ["🔗 桥接层"]
        CB["callbacks.cpp<br/>BridgeDrSubmitDecodeUnit"]
        VDI["VideoDecoderInstance<br/>全局单例管理"]
    end

    subgraph DECODE ["🎬 硬件解码"]
        VD["VideoDecoder<br/>AVCodec NDK"]
        ASYNC["异步模式<br/>回调获取 buffer"]
        SYNC["同步模式<br/>主动轮询 buffer<br/>(API 20+)"]
    end

    subgraph RENDER ["🖥 送显"]
        DIRECT["直接送显<br/>RenderOutputBuffer"]
        VSYNC["VSync 送显<br/>RenderOutputBufferAtTime"]
        GLPP["GL 后处理<br/>GLPostProcessor"]
    end

    subgraph DISPLAY ["📺 显示"]
        XC["XComponent<br/>SURFACE 类型"]
        NW["NativeWindow"]
    end

    RTP --> DEPKT
    DEPKT --> CB
    CB -->|scatter-gather 零拷贝| VDI
    VDI --> VD
    VD --> ASYNC
    VD --> SYNC
    ASYNC & SYNC --> DIRECT
    ASYNC & SYNC --> VSYNC
    ASYNC & SYNC -->|后处理启用时| GLPP
    GLPP --> NW
    DIRECT & VSYNC --> NW
    NW --> XC
```

## 数据流转全链路

```mermaid
sequenceDiagram
    participant Host as 🖥 PC 主机
    participant Net as 📡 网络线程
    participant Depkt as 📦 解包器
    participant Bridge as 🔗 Bridge
    participant Decoder as 🎬 AVCodec
    participant Render as 🖥 NativeRender
    participant Screen as 📺 XComponent

    Host->>Net: RTP 视频报文 (H.264/HEVC/AV1)
    Net->>Depkt: 解密 + RTP 解包
    Depkt->>Bridge: 完整帧 (DECODE_UNIT 链表)

    Note over Bridge: scatter-gather 零拷贝
    Bridge->>Decoder: 直写 AVBuffer<br/>(无中间 memcpy)

    alt 异步模式 (默认)
        Note over Decoder: OnInputBufferAvailable 回调
        Decoder->>Decoder: 硬件解码
        Note over Decoder: OnOutputBufferAvailable 回调
    else 同步模式 (API 20+, 低延迟)
        Note over Decoder: QueryInputBuffer 轮询
        Decoder->>Decoder: 硬件解码
        Note over Decoder: QueryOutputBuffer 轮询<br/>drain-to-latest 跳帧
    end

    alt 无后处理
        Decoder->>Render: RenderOutputBuffer[AtTime]
        Render->>Screen: 直接送显到 NativeWindow
    else 有后处理 (超分/HDR/暗区增强)
        Decoder->>Render: 输出到代理 NativeImage
        Note over Render: FrameAvailable 回调触发
        Render->>Render: GL 着色器处理
        Render->>Screen: eglSwapBuffers 到 NativeWindow
    end
```

## 解码器双模式

```mermaid
flowchart LR
    subgraph ASYNC ["📬 异步模式 (默认)"]
        direction TB
        A1["OnInputBufferAvailable<br/>回调获取空闲 buffer"] --> A2["写入帧数据<br/>PushInputBuffer"]
        A2 --> A3["硬件解码"]
        A3 --> A4["OnOutputBufferAvailable<br/>回调获取解码帧"]
        A4 --> A5{"延迟检查"}
        A5 -->|正常| A6["送显"]
        A5 -->|延迟过高| A7["跳帧 (L2/L5)<br/>FreeOutputBuffer"]
    end

    subgraph SYNC ["⚡ 同步模式 (API 20+)"]
        direction TB
        S1["QueryInputBuffer<br/>主动轮询空闲 buffer"] --> S2["写入帧数据<br/>PushInputBuffer"]
        S2 --> S3["硬件解码"]
        S3 --> S4["QueryOutputBuffer<br/>主动轮询解码帧"]
        S4 --> S5{"drain-to-latest"}
        S5 -->|最新帧| S6["送显"]
        S5 -->|旧帧| S7["跳帧 (L1)<br/>FreeOutputBuffer"]
    end
```

## GL 后处理管线

```mermaid
flowchart TD
    subgraph INPUT ["输入"]
        DEC["解码器输出"]
    end

    DEC --> CHECK{"后处理启用?"}
    CHECK -->|全部关闭| DIRECT["直接送显<br/>零开销"]

    CHECK -->|任一启用| PROXY["输出到代理 NativeImage"]
    PROXY --> OES["OES 纹理采样"]

    OES --> PASS1{"超分辨率?"}

    PASS1 -->|关闭| PP["后处理 Shader (1 pass)<br/>· 暗区抖动补偿<br/>· SDR → HDR 逆色调映射<br/>→ 直接输出屏幕"]

    PASS1 -->|开启| PP2["后处理 Shader (pass 1)<br/>→ 输出到 FBO"]
    PP2 --> EASU["EASU (pass 2)<br/>边缘自适应上采样<br/>→ FBO"]
    EASU --> RCAS["RCAS (pass 3)<br/>自适应锐化<br/>→ 屏幕"]

    subgraph UPSCALE ["超分引擎选择"]
        XE["XEngine<br/>华为 GPU 硬件加速"]
        FSR["FSR 1<br/>AMD 软件 shader"]
        XE -.->|不支持| FSR
    end

    PASS1 --> UPSCALE
```

## 帧率优化三层机制

```mermaid
graph TB
    subgraph L1 ["Layer 1 · ArkUI 框架层"]
        XCRate["XComponent<br/>SetExpectedFrameRateRange<br/>(FrameNode API)"]
    end

    subgraph L2 ["Layer 2 · Surface 层"]
        NWRate["NativeWindow<br/>SetFrameRateRange<br/>(API 12+)"]
    end

    subgraph L3 ["Layer 3 · VSync 层"]
        VSRate["NativeVSync<br/>SetExpectedFrameRateRange<br/>(API 20+)"]
    end

    L1 --> L2 --> L3

    Note1["解锁 MatePad 等设备<br/>被锁定 60fps 的问题"]
    L1 -.-> Note1

    Note2["Surface buffer queue<br/>帧率偏好"]
    L2 -.-> Note2

    Note3["VSync 回调频率<br/>精确帧节奏"]
    L3 -.-> Note3
```

## 丢帧分级机制

```mermaid
graph LR
    subgraph LEVELS ["丢帧层级 (从温和到激进)"]
        direction TB
        L1["L1 · Sync drain-to-latest<br/>同步模式追最新帧<br/>跳过中间积压帧"]
        L2["L2 · Async 延迟跳帧<br/>异步模式解码延迟过高<br/>丢弃当前帧"]
        L3["L3 · 临界延迟 IDR<br/>延迟严重积压<br/>丢弃全部 + 请求关键帧"]
        L4["L4 · 网络突发检测<br/>短时间大量数据涌入<br/>丢弃旧帧保留最新"]
        L5["L5 · Async 渲染跳帧<br/>输出间隔过短 + 延迟偏高<br/>跳过非关键输出"]
    end

    subgraph STATS ["📊 统计面板"]
        S1["droppedByL1"]
        S2["droppedByL2"]
        S3["droppedByL3"]
        S4["droppedByL4"]
        S5["droppedByL5"]
    end

    L1 --> S1
    L2 --> S2
    L3 --> S3
    L4 --> S4
    L5 --> S5
```

## 性能优化技术

```mermaid
graph TB
    subgraph CPU ["🔧 CPU 优化"]
        BIG["大核绑定<br/>sched_setaffinity<br/>检测 big.LITTLE 架构"]
        QOS["QoS 最高等级<br/>QOS_USER_INTERACTIVE"]
        BIG --- QOS
    end

    subgraph MEM ["📦 内存优化"]
        SG["Scatter-Gather 零拷贝<br/>网络链表 → 直写 AVBuffer<br/>无中间 memcpy"]
        STACK["栈上分段数组<br/>避免 new/delete GC 压力"]
        SG --- STACK
    end

    subgraph API ["🔌 API 兼容"]
        DLSYM["dlsym 动态加载<br/>同步 API / VRR / VSync"]
        FALLBACK["多级回退<br/>Sync → Async<br/>XEngine → FSR1 → 直通"]
        DLSYM --- FALLBACK
    end

    subgraph DEDUP ["🎯 去重/限流"]
        NOCB["移除无用 JS 回调<br/>每帧 new/delete 消除"]
        DEDUP2["输入去重<br/>同步模式 drain-to-latest"]
        NOCB --- DEDUP2
    end
```

## 文件清单

| 文件 | 层级 | 职责 |
|------|------|------|
| `VideoStream.c` | 网络 | RTP 视频流接收 |
| `VideoDepacketizer.c` | 网络 | RTP 解包、帧重组 |
| `callbacks.cpp` | 桥接 | moonlight-common-c 回调实现 |
| `moonlight_bridge.cpp` | 桥接 | NAPI 接口、Surface 绑定 |
| `video_decoder.h/cpp` | 解码 | AVCodec 解码器：双模式、丢帧、统计 |
| `native_render.h/cpp` | 送显 | NativeWindow 管理、VSync、帧率优化 |
| `gl_post_processor.h/cpp` | 后处理 | EGL/GLES3 着色器：暗区增强、SDR→HDR、超分 |
| `StreamPage.ets` | UI | XComponent 容器、Surface 创建 |
