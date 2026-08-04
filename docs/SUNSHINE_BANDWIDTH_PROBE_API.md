# Sunshine 启动前带宽探测 API v1 实施方案

## 1. 结论

建议 Sunshine 先落地一个受配对客户端证书保护的 HTTPS 二进制流接口：

```http
GET /api/network/probe?bytes={payloadBytes}&nonce={requestId}
```

客户端在用户进入应用列表后机会式调用该接口，以较小流量估算 Sunshine 到客户端的端到端下行吞吐。探测不阻塞应用列表，不进入点击游戏后的关键启动路径；探测失败时静默回退到网络档位、系统带宽提示和历史稳定码率。

v1 使用 HTTPS/TCP，目标是用较低实施成本得到可用于选择“初始视频码率”的保守估计。它不替代串流建立后的 UDP 丢包、RTT 和 ABR 校准。

## 2. 目标与非目标

### 目标

- 测量 `Sunshine -> 客户端` 方向的端到端可用吞吐。
- 支持局域网、公网、端口转发、FRP 和 VPN/组网连接。
- 客户端可在 0.5-1 秒预算内完成渐进探测。
- Sunshine 端低内存、低 CPU、可限流、可取消。
- 旧版 Sunshine 返回 404 时，客户端无错误提示并正常回退。
- 结果仅决定本次串流的初始码率，不突破用户配置的码率上限。

### 非目标

- v1 不测量客户端到 Sunshine 的上行带宽。
- v1 不承诺等同于 Moonlight UDP 视频流的真实极限吞吐。
- v1 不使用第三方测速服务，不上传网络信息。
- v1 不在串流过程中周期性制造额外探测流量。
- v1 不负责判断 LAN、WAN 或 VPN；路径分类由客户端独立完成。

## 3. 调用时序

```text
客户端进入应用列表
  -> serverinfo 和 applist 成功，确认主机在线且已配对
  -> 查询探测能力
  -> UI 空闲时执行渐进探测
  -> 按路径指纹缓存结果
  -> 用户点击游戏
  -> 取消仍在运行的探测
  -> 使用缓存结果计算初始码率
  -> 串流建立后由实际 UDP 指标和 ABR 校准
```

禁止在电脑列表的周期轮询中执行带宽探测。客户端离开应用列表、网络发生切换或开始串流时，应立即取消未完成的请求。

## 4. 能力发现

### 4.1 推荐方式

新增独立的网络能力接口，避免把启动前带宽探测与运行时 ABR 生命周期耦合：

```http
GET /api/network/capabilities
```

```json
{
  "version": 1,
  "features": [
    "bandwidth-probe-v1"
  ],
  "bandwidthProbe": {
    "version": 1,
    "endpoint": "/api/network/probe",
    "minBytes": 65536,
    "maxBytes": 4194304,
    "cooldownMs": 5000
  }
}
```

约束：

- `features` 包含 `bandwidth-probe-v1` 时，`bandwidthProbe` 必须存在。
- 客户端只依赖 `version`、`endpoint`、`minBytes`、`maxBytes` 和 `cooldownMs`。
- Sunshine 可以增加其他字段，但不能改变 v1 字段语义。
- 能力接口和探测接口都必须使用配对客户端证书认证。

### 4.2 过渡兼容

如果希望旧版 ABR 客户端也能提前发现能力，可以同时在现有 `GET /api/abr/capabilities` 的 `features` 中镜像声明 `bandwidth-probe-v1`，但网络能力接口是唯一权威配置源。

如果第一阶段暂不便实现 capabilities，客户端也可以直接请求探测接口并将 404 视为不支持；这仅作为过渡方案。

## 5. 探测接口契约

### 5.1 请求

```http
GET /api/network/probe?bytes=1048576&nonce=550e8400-e29b-41d4-a716-446655440000 HTTP/1.1
Accept: application/octet-stream
Accept-Encoding: identity
Cache-Control: no-store
Connection: keep-alive
```

参数：

| 参数 | 必填 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- | --- |
| `bytes` | 是 | 十进制整数 | `minBytes <= bytes <= maxBytes` | 响应体的精确字节数 |
| `nonce` | 是 | ASCII 字符串 | 1-64 字节，仅允许字母、数字和 `-_.` | 一次渐进探测的会话 ID，同一轮的所有样本复用该值；不参与认证 |

要求：

- 仅允许 HTTPS。
- 必须沿用现有受保护 API 的双向 TLS/配对客户端证书认证。
- 不接受 `Range`，不执行 HTTP 内容压缩。
- 未知查询参数可以忽略，以允许协议后续扩展。

### 5.2 成功响应

```http
HTTP/1.1 200 OK
Content-Type: application/octet-stream
Content-Length: 1048576
Cache-Control: no-store, no-transform
X-Bandwidth-Probe-Version: 1
X-Bandwidth-Probe-Nonce: 550e8400-e29b-41d4-a716-446655440000
```

响应体必须满足：

- 字节数严格等于 `Content-Length` 和请求的 `bytes`。
- 不得包含 `Content-Encoding` 或 `Transfer-Encoding: chunked`。
- 内容无需加密学随机；可以循环发送进程启动时生成的固定伪随机块。
- 不得返回全零、重复短文本或其他容易被 HTTP 压缩的内容。
- 客户端提前断开时立即停止发送并释放并发配额。

建议 Sunshine 预生成一个 64 KiB 伪随机只读缓冲区，通过异步写和背压循环发送，避免为每个请求分配最大 4 MiB 内存。HTTPS 本身会使线上载荷呈现高熵；关键是禁用 HTTP gzip/brotli。

### 5.3 错误响应

错误响应使用 JSON：

```json
{
  "error": "rate_limited",
  "retryAfterMs": 5000
}
```

| HTTP 状态 | 场景 |
| --- | --- |
| `400` | `bytes`、`nonce` 缺失或格式非法 |
| `401/403` | 客户端证书无效、未配对或无权访问 |
| `404` | Sunshine 不支持该协议 |
| `409` | Sunshine 正在向任意客户端串流，拒绝主动探测 |
| `429` | 超出客户端或全局限流；`Retry-After` 使用秒，JSON 同时返回精确的 `retryAfterMs` |
| `503` | Sunshine 正在关闭或暂时无法提供探测 |

客户端对所有非 200 响应静默回退，不自动连续重试。

无效客户端证书可能在 TLS 握手阶段直接被拒绝，此时不会产生 HTTP 401/403 响应，也属于符合预期的认证失败。

## 6. 服务端资源与限流

v1 推荐默认值：

| 项目 | 默认值 |
| --- | --- |
| 单次最小响应 | 64 KiB |
| 单次最大响应 | 4 MiB |
| 单个已配对客户端并发 | 1 |
| Sunshine 全局并发 | 4 |
| 同一客户端冷却时间 | 5 秒 |
| 同一客户端流量桶 | 16 MiB/分钟 |
| Sunshine 全局流量桶 | 64 MiB/分钟 |

限流身份优先使用已配对客户端证书指纹，不使用来源 IP。来源 IP 在 CGNAT、VPN 和反向代理环境下不能稳定代表客户端。

同一个客户端使用同一个 `nonce` 发起的渐进样本属于同一探测会话，不受样本间 5 秒冷却限制，但必须满足以下会话约束：

- 会话最长存活 3 秒。
- 会话内请求严格串行，出现并发请求时返回 429。
- 会话累计请求载荷不超过 6 MiB。
- 会话结束或过期后，再使用新 `nonce` 时才应用 5 秒冷却。
- 已结束或过期的 `nonce` 不得重新激活。

如果 Sunshine 已有活跃串流会话，建议返回 409，避免测速抢占现有视频流带宽。这里只检查活跃串流会话，不检查游戏进程是否正在运行。

## 7. 客户端探测算法

Sunshine v1 只需实现接口，本节用于说明服务端参数为什么这样设计，并作为联调基线。

### 7.1 渐进采样

客户端生成一个 `nonce`，按以下顺序请求，所有样本复用该 `nonce` 和同一 HTTPS 连接：

```text
64 KiB   warm-up，不计入最终结果，用于完成 TLS/连接预热
256 KiB  第一轮有效样本
1 MiB    上一轮低于 250 ms 时继续
4 MiB    上一轮仍低于 250 ms 且服务端允许时继续
```

停止条件满足任一即可：

- 最近一个有效样本传输时间达到 250 ms。
- 累计墙钟时间达到 800 ms。
- 累计有效载荷达到服务端或客户端流量上限。
- 页面离开、网络切换、用户点击启动或请求被取消。

如果客户端 HTTP 栈无法复用连接，warm-up 请求仍然保留，但每轮计时应从收到首个响应字节开始。无法获取首字节时间时，可以用小请求估算固定握手开销并从后续样本中扣除，但结果置信度必须降低。

### 7.2 计算

单轮吞吐：

```text
throughputKbps = receivedBytes * 8 / transferDurationMs
```

最终估计优先使用持续时间最长的完整有效样本；多个相近时长样本可采用按传输时间加权的调和平均，避免短样本虚高。

初始视频码率：

```text
probeSafeKbps = estimatedThroughputKbps * 0.70

initialBitrateKbps = min(
  userProfileLimitKbps,
  probeSafeKbps,
  learnedStableCapacityKbps
)
```

规则：

- 探测结果只能降低本次初始码率，不能突破用户设置上限。
- 单次探测结果不得覆盖长期历史；只有串流中的真实 UDP 指标才更新历史稳定容量。
- 结果低于 2 Mbps、样本不足 128 KiB 或测量时间小于 50 ms 时标记为低置信度，仅作提示，不强制降码率。

## 8. 缓存与失效

客户端按路径指纹缓存结果 15 分钟：

```text
host UUID
实际解析后的目标 IP
本地网络前缀
bearer 类型
VPN 状态
```

以下事件立即失效：

- 默认网络、VPN 状态或网络 bearer 变化。
- Sunshine 实际连接地址变化。
- 缓存超过 15 分钟。
- 最近一次串流显示持续拥塞，且实际稳定容量显著低于缓存值。

不应持久化 HarmonyOS `netId` 作为路径身份，因为它可能在重连或重启后变化。

## 9. 计费网络与隐私

- 客户端在计费蜂窝网络默认不执行主动探测，只使用系统提示、网络档位和历史结果。
- 如果用户允许移动网络探测，建议只执行 64 KiB warm-up 和 256 KiB 样本。
- Sunshine 不记录载荷内容，只记录认证客户端、请求字节数、耗时、取消原因和限流结果。
- 探测数据只在客户端与用户自己的 Sunshine 主机之间传输，不经过第三方服务器。

## 10. Sunshine 实现要点

处理流程：

```text
验证 HTTPS 和客户端证书
  -> 确认客户端已配对
  -> 校验 bytes/nonce
  -> 检查活跃串流和限流
  -> 写入固定 Content-Length 响应头
  -> 以 64 KiB 静态缓冲区异步循环发送
  -> 每次写完成后再调度下一块，遵守 socket 背压
  -> 成功、取消或异常时释放并发配额
```

不要一次性构造整个响应体，不要在发送循环中生成随机数，不要使用无背压的连续 `write()`。探测处理应运行在 Sunshine 现有 HTTP I/O 执行上下文中，不能阻塞视频、音频或输入线程。

建议结构化日志字段：

```text
event=bandwidth_probe
client=<certificate fingerprint prefix>
requested_bytes=<n>
sent_bytes=<n>
duration_ms=<n>
result=completed|cancelled|rate_limited|stream_active|error
```

日志不得记录完整证书、私钥、URL 中的敏感扩展参数或响应内容。

## 11. 验收标准

### 接口契约

- 合法请求返回 200，响应长度与 `bytes` 完全一致。
- 64 KiB、256 KiB、1 MiB、4 MiB 均可正确返回。
- 小于最小值、超过最大值、非法 nonce 返回 400。
- 未携带有效配对证书时，TLS 握手被拒绝或返回 401/403。
- 响应没有 gzip/brotli，且包含 `no-store, no-transform`。

### 资源安全

- 单请求常驻额外内存不随 `bytes` 线性增长，目标不超过 128 KiB。
- 客户端中途断开后 100 ms 内停止继续生成/排队数据。
- 超出并发或流量限制时返回 429，不拖垮 Sunshine HTTP 服务。
- 活跃串流期间返回 409，不影响既有会话的码率和延迟。

### 联调场景

- 千兆局域网。
- 20-100 Mbps 公网下行。
- 高 RTT、低带宽远程网络。
- VPN/Tailscale/ZeroTier。
- FRP 或反向代理地址。
- 请求中途取消、网络切换、客户端退出应用列表。

### 回归要求

- 不改变 `/serverinfo`、`/applist`、配对、launch/resume/cancel 行为。
- 不支持该能力的客户端和 Sunshine 继续正常工作。
- 探测接口异常不会导致 Sunshine 崩溃、阻塞或影响现有串流线程。

## 12. 分阶段交付

### Sunshine 第一阶段

1. 实现 `/api/network/probe` 和认证。
2. 实现固定长度异步发送、取消和限流。
3. 实现 `/api/network/capabilities` 并声明 `bandwidth-probe-v1`。
4. 完成接口契约、并发和活跃串流回归测试。

### Moonlight Harmony 第二阶段

1. 实现路径分类与探测结果缓存。
2. 在应用列表空闲窗口执行渐进探测。
3. 将结果接入 LAN/WAN/VPN 初始码率策略。
4. 串流建立后使用现有统计和 ABR 校准。
5. 增加取消、网络切换、计费网络和旧服务端兼容测试。

## 13. v2 预留

只有在 v1 数据证明 HTTPS/TCP 与实际 UDP 稳定容量偏差过大时，再设计 `bandwidth-probe-v2` UDP packet train。v2 必须单独处理 UDP 认证、防反射攻击、包序列、服务端 pacing、丢包统计和 NAT 映射，不应混入 v1 以拖慢第一阶段落地。
