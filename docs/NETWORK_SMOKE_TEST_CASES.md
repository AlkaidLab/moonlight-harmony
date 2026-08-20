# 网络冒烟测试用例

本文档覆盖网络链路的最小冒烟集，用于每次修改网络发现、地址选择、配对、WOL、串流连接前后的快速验证。

整体地址、状态和认证链路见 [Moonlight Harmony 网络模型](./NETWORK_MODEL.md)。

## 自动冒烟

| ID | 用例 | 步骤 | 通过标准 |
| --- | --- | --- | --- |
| NS-A01 | ArkTS 编译与 HAP 打包 | 执行项目 HAP 构建命令 | `BUILD SUCCESSFUL` |
| NS-A02 | 启动期网络契约自检 | 启动 App，查看 hilog `NetworkSelfCheck` | 出现 `network self-check passed`，无 `CONTRACT BROKEN` |
| NS-A03 | 网络错误分类契约 | 启动 App，查看 `transient error classifier self-check passed` | 超时、DNS、reset、cancel 等用例通过 |
| NS-A04 | 地址分类契约 | 启动 App，查看 `NetHelper self-check passed` | IPv4/IPv6 LAN/WAN/tunnel、端口解析、URL 格式化用例通过 |
| NS-A05 | WOL MAC 校验契约 | 启动 App，查看 `WakeOnLan self-check passed` | 冒号/连字符 MAC 识别，非法 MAC 拒绝 |
| NS-A06 | 地址选择契约 | 启动 App，查看 `selectBestAddress self-check passed` | preferred、active、manual、LAN、WAN 优先级符合预期 |
| NS-A07 | Foundation Sunshine mock 连接模型 | 执行 `npm run test:sunshine-mock` | mock serverinfo、applist、pair、unpair、端口 fallback、retry/error、ComputerManager 合并、轮询竞速、HTTPS 端口复用、launch/resume/quit、动态码率响应校验、服务端 ABR 去重和 tick 单飞用例全部 `PASS` |
| NS-A08 | Sunshine 启动前带宽探测 | 执行 `npm run test:sunshine-mock` | capabilities、二进制响应、同路径任务合并、缓存命中、800 ms 启动超时、蜂窝/计费授权、320 KiB 预算和旧 Sunshine 404 回退用例全部 `PASS` |

推荐构建命令：

```bash
JAVA_HOME=/Users/mac/ohos-sdk-cache/jdk17-temurin/Home \
PATH=/Users/mac/ohos-sdk-cache/jdk17-temurin/Home/bin:$PATH \
DEVECO_SDK_HOME=/Users/mac/ohos-sdk-cache/6.1-Release-mac/sdk-ci-shape \
node hvigorw.js assembleHap --mode module -p module=entry@default -p product=default --no-daemon
```

连接模型 mock 命令：

```bash
npm run test:sunshine-mock
```

该 mock 套件基于 `AlkaidLab/foundation-sunshine` 的真实接口字段建模：

- `src/nvhttp.cpp`：`/serverinfo`、`HttpsPort`、`ExternalPort`、`PairStatus`、HTTP/HTTPS MAC 行为。
- `src/nvhttp/apps.cpp`：`/applist`、`AppTitle`、`ID`、`IsHdrSupported`、`SuperCmds`。
- `src/nvhttp/pairing.cpp`：`/pair` 的 `getservercert`、`clientchallenge`、`serverchallengeresp`、`clientpairingsecret`、`pairchallenge` 阶段顺序。

同时覆盖本项目连接模型的关键回归点：

- `serverinfo` 字段缺省值与 XML 转义解析。
- `ComputerManager.mergeServerInfo` 对零 MAC、127.x 回环地址、配对状态、IPv6、HTTP/HTTPS 端口的合并守卫。
- 轮询竞速优先 LAN，WAN 先返回时短暂等待 LAN。
- `NvHttp.fromComputer` / `fromAddress` 仅在目标与活动地址的 HTTP 端口匹配时复用缓存 HTTPS 端口，避免跨端口复用 stale 端口，同时支持同一 Sunshine 的多网络地址。
- 视频问题推演场景：`serverinfo` 可达但 `applist` 不可达、网络诊断保持只读、锁定地址不限制状态轮询、锁定地址不可达时不借备用地址误报认证成功、错误主机 UUID 被拒绝。
- `PairingManager` 与 `NvHttp` 一致使用地址中的显式端口优先。
- HTTPS-only 的 `applist`、`launch`、`resume`、`cancel` 和 HTTP `unpair` 请求路径。
- `/bitrate` 仅接受明确成功响应，服务端 ABR 已接受时不重复下发，同时同步客户端目标码率；慢请求期间 tick 保持单飞。
- `/api/network/capabilities` 与 `/api/network/probe` 契约，以及启动前探测的任务合并、缓存、超时回退和计费流量预算。

## 手动冒烟

| ID | 用例 | 前置条件 | 步骤 | 通过标准 |
| --- | --- | --- | --- | --- |
| NS-M01 | 应用冷启动 | 无 | 安装后首次启动 App | 无崩溃；网络自检日志全部通过 |
| NS-M02 | 局域网自动发现 | 手机与 Sunshine/Moonlight Host 在同一 LAN | 进入电脑列表，点击扫描 | 可发现主机；地址标签显示局域网或 IPv6 局域网 |
| NS-M03 | 手动添加 IPv4 主机 | 已知 `192.168.x.x` 主机地址 | 手动添加 IPv4 地址 | 添加成功；电脑列表出现主机 |
| NS-M04 | 手动添加域名或 DDNS | 域名可解析并指向主机 | 手动添加域名 | 添加成功；轮询不强制回落到不可达 LAN 地址 |
| NS-M05 | 自定义端口连接 | Host 使用非默认 HTTP 端口 | 输入 `host:port` 添加 | `NvHttp` 使用输入端口；serverinfo/app list 可加载 |
| NS-M06 | IPv6 地址连接 | 网络支持 IPv6，Host 有全局或 ULA IPv6 | 输入裸 IPv6 或扫描发现 IPv6 | URL 格式化正确；不出现 IPv6 方括号/端口解析错误 |
| NS-M07 | 配对流程 | 未配对主机在线 | 触发配对，输入 PIN | 配对成功；pairState 变为已配对 |
| NS-M08 | 应用列表加载 | 主机已配对在线 | 打开主机详情/应用列表 | 应用列表加载成功；图标/名称显示正常 |
| NS-M09 | 串流启动与停止 | 主机已配对，至少一个可启动应用 | 启动任意应用串流，再停止串流 | 进入串流页成功；停止后回到列表/详情无残留连接错误 |
| NS-M10 | WOL 唤醒 | 主机支持 Wake-on-LAN，已保存有效 MAC | 主机关机/睡眠后点击唤醒 | 不因广播失败中断；主机可被唤醒或至少无 App 崩溃 |
| NS-M11 | 网络不可达兜底 | 使用一个不可达地址 | 添加或刷新该地址 | UI 给出失败提示；不会无限重试或卡死 |
| NS-M12 | 证书/认证错误暴露 | 使用证书不匹配或未配对场景 | 请求应用列表或连接 | 错误暴露给用户；不被误判成瞬时网络错误静默重试 |

## 回归重点

修改以下模块后至少跑 `NS-A01` 到 `NS-A08`，并按改动范围选择手动用例：

- `entry/src/main/ets/utils/NetHelper.ets`
- `entry/src/main/ets/model/ComputerInfo.ets`
- `entry/src/main/ets/service/network/*`
- `entry/src/main/ets/service/streaming/NvHttp.ets`
- `entry/src/main/ets/service/streaming/StreamingSession.ets`
- `entry/src/main/ets/service/ComputerManager.ets`

## 判定规则

- 自动冒烟失败时，不进入手动冒烟。
- 启动日志出现 `CONTRACT BROKEN` 时，本次网络冒烟失败。
- 手动冒烟允许外部网络环境导致主机不可达，但 App 不应崩溃、卡死或错误选择已知不可达地址。
