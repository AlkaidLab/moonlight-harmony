# Moonlight Harmony 网络模型

本模型把“主机是否可达”和“用户实际选择哪条链路连接”拆成两个平面。电脑卡片状态表示任一已知地址能否通过主机身份验证；应用列表、配对和串流则始终遵循用户锁定地址或最近一次轮询胜出的活动地址。

```mermaid
flowchart TD
  subgraph Sources[地址来源]
    MDNS[mDNS 局域网地址]
    MANUAL[手动地址 / DDNS]
    REMOTE[远程 IPv4 / 隧道地址]
    IPV6[IPv6 地址]
    ACTIVE[最近轮询胜出的活动地址]
    PREFERRED[用户锁定地址]
  end

  subgraph Availability[可用性平面：ComputerManager]
    COLLECT[收集并去重所有已知地址]
    POLL[并行 serverinfo 轮询<br/>LAN 成功优先]
    IDENTITY{返回 UUID 是否匹配}
    TEMP{是否 discovered-* 临时条目}
    RECONCILE[归一为真实 UUID]
    REJECT[拒绝错误主机候选]
    MERGE[合并 ServerInfo<br/>活动地址 / 端口 / 游戏状态]
    ONLINE[任一地址成功 → ONLINE]
    OFFLINE[连续失败达到阈值 → OFFLINE]
  end

  subgraph Connection[连接平面：应用列表 / 配对 / 串流]
    SELECT{是否锁定地址}
    USE_PREFERRED[使用 preferredAddress]
    USE_ACTIVE[使用 address（activeAddress）<br/>否则按固定回退链选择]
    PORT{HTTP 端口是否与活动地址一致}
    REUSE[复用缓存 HTTPS 端口]
    DISCOVER_PORT[重新探测 / 推算 HTTPS 端口]
    AUTH[HTTPS + 客户端证书]
  end

  subgraph Diagnostic[网络诊断：只读]
    BASE[逐地址 HTTP serverinfo<br/>基础可达性与延迟]
    ACTUAL[仅对实际连接地址验证 applist]
    REPORT[分别报告<br/>基础网络 / 锁定地址 / 认证链路]
    PIN[用户可明确锁定或解除地址]
  end

  MDNS --> COLLECT
  MANUAL --> COLLECT
  REMOTE --> COLLECT
  IPV6 --> COLLECT
  ACTIVE --> COLLECT
  COLLECT --> POLL --> IDENTITY
  IDENTITY -->|匹配| MERGE
  IDENTITY -->|不匹配| TEMP
  TEMP -->|是| RECONCILE --> MERGE
  TEMP -->|否| REJECT
  MERGE --> ONLINE
  POLL -->|全部失败| OFFLINE

  PREFERRED --> SELECT
  ACTIVE --> SELECT
  SELECT -->|是| USE_PREFERRED
  SELECT -->|否| USE_ACTIVE
  USE_PREFERRED --> PORT
  USE_ACTIVE --> PORT
  PORT -->|一致| REUSE --> AUTH
  PORT -->|不同| DISCOVER_PORT --> AUTH

  MDNS --> BASE
  MANUAL --> BASE
  REMOTE --> BASE
  IPV6 --> BASE
  BASE --> ACTUAL --> REPORT --> PIN
  PIN --> PREFERRED
```

## 连接地址选择契约

`selectBestAddress` 是应用列表、配对和串流的连接目标选择入口，顺序固定为：

1. `preferredAddress`：用户锁定地址。
2. `address`：最近一次状态轮询胜出的活动地址。
3. `manualAddress`：用户手动输入的地址或域名。
4. LAN IPv4：`localAddress` 中的局域网 IPv4。
5. LAN IPv6：`ipv6Address` 中的局域网 IPv6。
6. 非 LAN `localAddress`。
7. 全局 `ipv6Address`。
8. `remoteAddress`。

只要 `preferredAddress` 存在，它就始终是实际认证和串流目标。锁定地址不可达时不会改用备用地址完成 `applist` 或串流认证；备用地址仍可参与状态轮询和只读网络诊断，以便分别报告“主机可达”和“锁定链路不可用”。

`NvHttp.fromAddress` 只负责为已经选定的目标构造客户端，并根据目标与活动地址的 HTTP 端口是否一致决定能否复用缓存 HTTPS 端口；它不执行地址回退。`ConnectionPathService.pickTargetAddress` 只在目标主机完成 DNS 解析后选择与 LAN/WAN 路径分类匹配的解析结果，也不属于上述主机地址回退链。

## 不变量

- 网络诊断不修改电脑的在线状态、活动地址、游戏状态或缓存端口。
- 锁定地址只决定实际控制连接，不缩小电脑状态轮询的地址集合。
- 已有真实 UUID 的电脑不会因为某个地址返回其他 UUID 而被重命名或合并。
- 缺少 UUID 的响应和已删除条目返回的陈旧轮询结果不会进入合并路径。
- 只有 `discovered-*` 临时条目可以在首次验证后归一为服务器返回的真实 UUID。
- 缓存 HTTPS 端口仅在目标 HTTP 端口与活动地址端口一致时复用，保持与 Sunshine 端口偏移及 Android Moonlight 一致。
