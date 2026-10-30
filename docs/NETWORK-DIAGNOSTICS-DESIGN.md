# 网络诊断与优化 — 设计方案

> 写于 2026-10-30。对应代码状态：侧边栏视觉轮 + vibrancy 修复之后，构建 0 错 0 警。
> 本文只回答一件事：**Moppet 要不要做网络模块、做成什么样、怎么落到现有架构里**。
> 所有命令/字段都在本机（macOS 26.3.1）实跑验证过，不是凭记忆写的。

---

## 0. 先说结论：macOS 上没有"网络加速"

清理类软件讲"网络优化"，绝大多数是伪科学。必须先划清边界，否则这个模块会变成骗人的开关。

**做不到的（别写进 UI）**：

| 传说 | 事实 |
|---|---|
| 改 TCP 拥塞控制算法提速 | macOS 没有可写的 sysctl 开关，拥塞控制由内核按系统版本决定，用户态改不了 |
| "清理网络缓存"提速 | DNS 缓存有，但刷新只在"改了配置没生效"时有用，不是提速手段 |
| 关掉系统服务"腾出带宽" | 除了你自己开的同步/更新，系统网络服务几乎不占稳态带宽 |
| 装个"加速通道" | 那是 VPN/代理，不属于清理工具，且合规风险高 |

**做得到的（有据可依，可测量）**：

1. **DNS 解析路径** —— 解析器顺序、响应时延、失效/被劫持的配置（占比最大的"网页打开慢"来源之一）
2. **代理 / PAC 残留** —— 本机实测就有一个：`ProxyAutoConfigEnable: 1, PAC = http://localhost:1089/proxy.pac`，代理工具退了但 PAC 还挂着，每个请求先付一次 PAC 拉取/失败重试
3. **MTU / PMTU 黑洞** —— VPN、PPPoE、双栈隧道下极常见，表现为"能 ping 通但网页卡住"
4. **多网卡 / 服务顺序 / 双栈优先级** —— 本机就有 en1 与 en11 同时在网，默认路由走 en11 而 DNS 走 192.168.0.1
5. **Wi-Fi 侧质量** —— 信号、噪声、信道拥挤、2.4G/5G、低数据模式
6. **后台流量** —— iCloud/照片/系统更新/浏览器同步在后台吃满上行，直接推高"延迟"
7. **TCP 层健康度** —— 重传率、建连失败率（`netstat -s -p tcp` 增量）

所以模块定位不是"一键加速"，而是：**先测清楚瓶颈在哪一层，只改确实能改的那几项，改完再测一遍证明有效**。这条闭环本身就是产品差异点。

---

## 1. 五层诊断模型

一次诊断 = 一条**带时间戳的采样链**，而不是一堆散装指标。分层是为了让"根因"可推导：哪一层耗时/异常，就往哪一层归因。

| 层 | 数据源（已验证） | 关键指标 | 典型故障判据 |
|---|---|---|---|
| **L0 链路** | `NWPathMonitor`（原生、推送式） | 接口类型、`isExpensive`、`isConstrained`、IPv4/IPv6 支持、路径变化事件 | 路径频繁 flip（Wi-Fi 与有线来回切）、被标记为按流量计费 |
| **L1 本地网络** | `route -n get default`、`networksetup -getMTU <svc>`、`ping -c5 <网关>`、`scutil --nwi` | 网关 RTT、丢包、MTU 实际值 vs 设置值、IPv6 状态 | 网关 RTT > 10ms 或丢包 > 0（问题在家用路由器/AP，不在运营商） |
| **L2 名称解析** | `scutil --dns`、`dig +stats @<resolver>`、计时 `getaddrinfo` | 解析器顺序、单次解析耗时、失败率、DoH/DoT 是否生效 | 解析 > 100ms 或偶发超时（换 DNS 立刻见效） |
| **L3 传输** | `networkQuality -c`、`netstat -s -p ip`、四段分解 | `base_rtt`、`il_tcp_handshake_443`、`il_tls_handshake`、`dl_throughput`、`dl_responsiveness`(RPM)、**TLS÷TCP 放大比** | 握手正常但 RPM < 100（bufferbloat）；TLS÷TCP > 10 且 TCP 正常（握手期丢包/干扰） |
| **L4 应用** | `URLSessionTaskMetrics` | DNS / TCP / TLS / TTFB 四段耗时、`isReusedConnection`、`networkProtocolName` | DNS 800ms 而 TCP 30ms → 纯 DNS 问题；TTFB 高但握手低 → 服务端或链路 RTT |
| **L5 进程** | `nettop -P -L 1 -x -J bytes_in,bytes_out -t wifi` | 每进程字节数（两次采样求增量）、占比 | 某进程持续吃满上行 → 先停它，而不是换 DNS |

### 1.1 为什么是这五个数据源

- `networkQuality` 是系统自带（macOS 12+），**一次跑完给出吞吐 + 空载 RTT + 负载下 RTT + RPM**，还带 `il_tcp_handshake_443` / `il_tls_handshake` 分解。等于免费拿到 L3 的完整证据链，不需要自己写测速服务端。
- `nettop` 无需 root 就能给出每进程字节数（实测 `-P -L 1` 单次采样即退出），比私有 `NetworkStatistics.framework` 安全得多（后者是私有 API，上架必死）。
- `netstat -s -p ip` 给 IP 层收发/丢弃计数（**注意：macOS 26 上 `-p tcp` 计数器恒为 0，见 §1.2**）。丢包改由两个应用层信号推断：① **阶段放大比** = TLS 握手耗时 ÷ TCP 握手耗时，且**必须配合绝对耗时**（TLS1.3 正常 1–3×；但 TCP 4ms → TLS 100ms 也是 24×，属正常证书开销，所以判据是 TLS > 400ms **且** 比值 > 10×）；② **SYN 退避台阶**（connect 耗时 ≈ 1s/3s/7s 的整数倍 = SYN 被丢后指数退避）。
- `URLSessionTaskMetrics` 是唯一能把"我打开网页为什么慢"拆成四段的原生 API，且零权限。

### 1.2 本机实测：三层数据长什么样（2026-10-30 / macOS 26.3.1）

**四段分解**（`curl -w`，`--noproxy '*'` 直连，同一分钟内各测 2 次）

| 端点 | DNS | TCP 握手 | TLS 握手 | TTFB | 判读 |
|---|---|---|---|---|---|
| apple.com `118.112.11.56` | 5–15ms | 12–21ms | 22–30ms | 32–40ms | 健康，TLS ≈ 2×TCP |
| baidu.com `183.2.172.177` | 4–5ms | 40ms | 116–120ms | 150–156ms | 正常，TLS ≈ 3×TCP |
| speed.cloudflare.com `172.66.0.218` | 3ms | **4ms** | **1524–2108ms** | 1989–3677ms | 异常，TLS ≈ **400×**TCP |

第三行是全篇最重要的证据：**TCP 4ms（Anycast 极近），TLS 2 秒**。说明

- 不是 DNS 问题（3ms）
- 不是链路 RTT 问题（4ms）
- 是 TLS 握手阶段在丢包/被干扰 —— TLS 1.3 只需 1 个往返，2 秒意味着至少 5–10 次 RTO 退避

如果只 `ping` 或只测 DNS，结论会是"网络很好"，完全测反。**这就是必须分层 + 多端点的理由。**

**吞吐（同一端点，3MB）**：253 KB/s ≈ 2 Mbps，耗时 11.8s。同一个网络里，apple.com 的 TTFB 是 32ms、cloudflare 只有 2Mbps —— 不同路径差两个数量级。

**配置层**

```
$ scutil --proxy
  ProxyAutoConfigEnable : 1
  ProxyAutoConfigURLString : http://127.0.0.1:1089/proxy.pac   ← Shadowsocks 在跑，PAC 返回 200
$ networksetup -getdnsservers Wi-Fi → 1.1.1.1
$ scutil --dns | head               → resolver #1 : 192.168.0.1 (en11)   ← 配置与实际不一致
$ route -n get default              → interface: en11（en1 也在线）      ← 默认路由与 DNS 出口不同网卡
$ networksetup -getMTU Wi-Fi        → Active MTU: 1500 (Current Setting: 1500)
```

PAC 那条要更正一个直觉：它不是"代理退了没清干净"（进程在、PAC 可访问），而是**每次 PAC 校验要 56ms**（本地请求，实测 `time_total=0.056`）。规则因此只能判"不可达"，不能判"指向 localhost 就是残留"。

**坑：macOS 26 上 TCP 计数器是死的**

```
$ netstat -s -p tcp   → 全部为 0（刚下完 2MB 仍是 0）
$ sysctl net.inet.tcp.stats → 空
$ netstat -s -p ip    → 7600 万包，正常
```

所以**不能靠 TCP MIB 算重传率**。丢包要换证据：见 §1.3 的"阶段放大比"与"SYN 退避台阶"。

### 1.3 测量协议：怎么测，才配当参照物

**先承认一个事实**：网络是时变随机过程。同一台机器、同一个网站，隔 30 秒测两次，吞吐差 20–40% 是常态；而一次"优化"的真实收益往往只有 5–15%。所以**"改前测一次、改后测一次"测到的基本是噪声，不是效果**。

#### 三层参照系

| 参照 | 做法 | 回答什么 | 局限 |
|---|---|---|---|
| **时间参照**（配对） | A/B 交错：A、B、A、B…，取配对差值的中位数 | 这次改动本身有没有效 | 只适用于能快速来回切的改动（切 DNS 可以，改 MTU 不行） |
| **空间参照**（对照组） | 同时测一个**不受改动影响**的指标 | 是不是网络自己变好了 | 要挑对对照指标 |
| **历史参照**（基线） | 按 (接口, SSID, 时段) 分桶的滚动中位数 | 今天比平时慢吗 | 冷启动没数据 |

对照组按"改什么"来挑：

| 改的东西 | 实验组 | 对照组（不受影响） |
|---|---|---|
| DNS 服务器 | 域名解析耗时 | 到固定 **IP** 的 TCP 握手 RTT（不经 DNS） |
| MTU | 1472B DF 包连通性 | 小包（56B）ping RTT |
| 代理 / PAC | 应用 TTFB | 直连同一 IP 的握手 RTT |

校正公式：**净改善 = Δ实验组 − Δ对照组**。若对照组也同步变化，说明是环境漂移，实验组的差值不可信。

#### 一次测量的时序（约 20 秒）

| 阶段 | 时长 | 内容 | 关键排除项 |
|---|---|---|---|
| t0 预检 | 2s | NWPath 稳定、`nettop` 确认无大流量、记录 RSSI/接口 | 路径在 flip 就不测 |
| t1 解析 | 3s | 3 个**随机子域**，取中位数 | 必须绕开 DNS 缓存 |
| t2 RTT | 2s | 5 次 TCP 握手到**固定 IP**，中位数 + MAD | 先解析成 IP，别让 DNS 污染 |
| t3 应用 | 5s | 3 次**全新连接**取 TTFB | 禁用连接复用 |
| t4 吞吐 | 8s | 4 流并发，**丢弃前 1.5s** | 稳态窗口，避开慢启动 |
| t5 负载延迟 | 覆盖 t4 | 每 200ms 一次小请求，取 P95 | bufferbloat 指标 |
| t6 汇总 | — | 对照组校正 → 比历史基线 → 三态结论 | — |

#### 判定：三态，不是百分比

```
improved      净改善 > MDD 且方向一致
unchanged     |净改善| ≤ MDD
regressed     净改善 < −MDD
inconclusive  配对样本 < 5，或对照组本身剧烈波动
```

`MDD`（最小可检测差异）≈ `2.8 × σ_pair / √n`。本机实测 σ 约 20%，n=5 时 MDD ≈ 25% —— **小于 25% 的改善根本测不出来**。产品上必须显示"在误差范围内，无法判定"，而不是编一个"提升 12%"。

> 磁盘清理的参照物是字节数（确定性、可核对），网络优化的参照物只能是统计量。
> 前者可以承诺"清出 3.2GB"，后者只能承诺"这个改动在你的网络下统计上有效/无效"。混淆两者就是骗人。

### 1.4 误差来源与控制

| 来源 | 典型影响 | 控制手段 |
|---|---|---|
| CDN 落点变化 | 吞吐 ±30% | 固定端点 + 多次取中位数；不同端点分别出结论 |
| TCP 慢启动 | 前 1–2s 偏低 30–50% | 丢弃预热窗口 / 用 ≥3MB 或 ≥8s |
| 并发流数 | 单流比多流低 30–50% | 固定 4–8 流，写进报告 |
| DNS / HTTP 缓存 | 虚高（本机实测缓存命中时 DNS 从 25ms 掉到 0.1ms） | 随机子域 + 唯一 query 参数 |
| 后台流量 | 偏低且波动大 | `nettop` 预检 + 明确提示 |
| 时段 | 晚高峰低 20%+ | 历史基线按时段分桶 |
| Wi-Fi 信道/信号 | 随机波动 | 记录 RSSI 作为协变量，跨信道样本不合并 |
| 测速自身消耗 | 流量费 | 明示预估 MB，允许"只测延迟" |

## 2. 规则引擎：从数据到结论

诊断结果不是一堆数字，而是**按证据强度排序的结论**。规则表驱动，便于加规则和写测试（`--smoke` 可以喂固定样本断言输出）。

| 规则 ID | 条件 | 结论 | 建议动作 | 置信度 |
|---|---|---|---|---|
| `dns.slow` | 平均解析 > 100ms 或失败率 > 10% | 域名解析慢 | 切换 DNS + 刷新缓存 | 高 |
| `dns.mismatch` | `scutil --dns` 首解析器 ≠ 服务配置的 DNS | 配置与实际不一致 | 说明原因（多为 DHCP 覆盖或 VPN） | 中 |
| `proxy.pac-stale` | PAC 开启但 URL 不可达 / 指向 localhost 且端口无监听 | 代理残留 | 关闭 PAC | 高 |
| `mtu.blackhole` | 小包通、1472 字节 DF 包不通 | PMTU 黑洞 | 建议降 MTU（VPN 场景） | 高 |
| `rtt.gateway` | 网关 RTT > 10ms 或丢包 | 本地网络问题 | 检查 Wi-Fi/路由器，不换 DNS | 高 |
| `bufferbloat` | `dl_responsiveness` < 100 RPM 且 `base_rtt` 正常 | 上行拥塞 | 限制后台同步/换 5G 频段 | 中 |
| `wifi.weak` | RSSI < -70dBm 或 noise > -85dBm | 信号差 | 靠近 AP / 换信道 | 高 |
| `handshake.amplified` | TLS > 400ms **且** TLS÷TCP > 10 | 握手期丢包/干扰（非 DNS、非带宽） | 换路径（代理/换网），不要动 DNS | 高 |
| `handshake.syn-retry` | connect 耗时 ≈ 1s/3s/7s 台阶 | SYN 被丢 | 同上 | 高 |
| `process.hog` | 单进程占上行 > 60% 持续 30s | 后台流量 | 列出进程，让用户决定 | 高 |

设计要点：

- **每条结论必须带"证据行"**（原始命令输出片段），可点开看。清理软件的信任来自可核对。
- **置信度低的结论不自动执行**，只提示。比如 `dns.mismatch` 常常是 VPN 的正常行为。
- **规则可组合**：`rtt.gateway` 命中时，抑制 `dns.slow` 的"换 DNS"建议——网关都不稳，换 DNS 没用。这个抑制表是防误诊的关键。

---

## 3. 优化动作目录（可执行 + 可回滚）

原则：**每个动作三件套 —— 前置校验、执行、回滚**。执行前后各测一次，把 delta 摆给用户看；没改善就自动回滚。这是"优化"能被验证的唯一方式。

| # | 动作 | 实现 | 前置校验 | 回滚 | 权限 | 预期收益 |
|---|---|---|---|---|---|---|
| 1 | 刷新 DNS 缓存 | `dscacheutil -flushcache; killall -HUP mDNSResponder`（已有） | — | 无需 | root | 低（配置变更后生效用） |
| 2 | 切换 DNS | `networksetup -setdnsservers <svc> 1.1.1.1 8.8.8.8` | 先测当前解析时延做基线 | `-setdnsservers <svc> Empty`（回到 DHCP） | root | 中—高（视当前解析器） |
| 3 | 关闭残留 PAC/代理 | `networksetup -setautoproxystate <svc> off`（URL 保留，只是不生效） | 先探 PAC URL 是否可达 | `-setautoproxystate <svc> on` | root | 高（若命中） |
| 4 | 修正 MTU | `networksetup -setMTU <硬件端口> 1400` | 先做 DF 探测确定安全值 | `-setMTUAndMediaAutomatically <硬件端口>` | root | 高（VPN/PPPoE） |
| 5 | 重排网络服务顺序 | `networksetup -ordernetworkservices ...` | 列出当前顺序 | 按原顺序写回 | root | 中（多网卡） |
| 6 | 关低数据模式 | `defaults write` 相关键 / 提示手动 | — | 写回 | 无 | 低 |
| 7 | 限后台同步 | 只给建议 + 深链到系统设置 | — | — | — | 中 |
| 8 | 重置网络栈 | 删 `NetworkInterfaces.plist` 等 + 重启 | **强制二次确认 + 备份到 `~/.moppet/backup/netstack-<ts>/`** | 从备份还原 | root | 最后手段 |

**刻意不做**的动作（写进代码注释，防止后人加回来）：改 `net.inet.tcp.*` 内核参数、关闭 IPv6、禁用 mDNSResponder、装第三方 DNS 代理进程。

---

## 4. 落到 Moppet 现有架构

### 4.1 文件与职责

```
Sources/Moppet/Core/Modules/NetworkEngine.swift      // 采集：五层数据，纯 async，无 UI
Sources/Moppet/Core/Modules/NetworkOptimizer.swift   // 动作目录：复用 OptimizeEngine.shell / shellWithAdmin
Sources/Moppet/Core/NetworkDiagnostics.swift         // 数据模型 + 规则引擎（纯函数，可单测）
Sources/Moppet/Views/NetworkView.swift               // 三块 UI：结论卡 / 时间线 / 明细
```

`NetworkEngine` 与现有 `SystemStatus` 的分工：`SystemStatus.network` 只做"速率读数"（已存在，Status 页在用），`NetworkEngine` 做"一次性深度诊断"，互不覆盖。速率读数保持轻量，别把 `networkQuality` 塞进 2 秒刷新的 Status 页。

### 4.2 数据模型

```swift
struct NetworkReport: Codable, Sendable {
    let startedAt: Date
    let path: PathSnapshot        // L0：NWPath 快照
    let local: LocalSnapshot      // L1：网关 / MTU / IPv6
    let dns: DNSSnapshot          // L2：解析器顺序 + 实测时延
    let transport: TransportSnapshot  // L3：networkQuality + 重传
    let apps: [AppProbe]          // L4：URLSessionTaskMetrics 四段
    let processes: [ProcFlow]     // L5：nettop 增量
    let findings: [Finding]       // 规则引擎输出
}

struct Finding: Identifiable, Codable, Sendable {
    let id: String            // 规则 ID，如 "dns.slow"
    let layer: Layer          // .link/.local/.dns/.transport/.app/.process
    let severity: Severity    // .info/.warn/.critical
    let confidence: Double    // 0…1，低置信度不自动执行
    let title: String
    let evidence: [String]    // 原始输出行，UI 可展开
    let actions: [String]     // 关联的优化动作 ID
}

/// 一次采样 = 一个可比较的向量。参照系的原子单位。
struct Measurement: Codable, Sendable {
    let at: Date
    let interface: String       // en0 / en1 / utun3
    let ssid: String?           // 分桶维度之一（缺定位权限时为 nil）
    let hourBucket: Int         // 0…23，时段分桶
    // 分层指标（毫秒）
    let dnsMs: Double
    let tcpMs: Double
    let tlsMs: Double
    let ttfbMs: Double
    let jitterMs: Double        // RTT 的 MAD
    // 吞吐（Mbps）与负载延迟
    let downMbps: Double?
    let upMbps: Double?
    let loadedRttP95: Double?
    let bytesUsed: Int64

    /// 阶段放大比：TLS ÷ TCP。正常 1–4×，>10× 说明握手期丢包。
    var handshakeAmplification: Double { tcpMs > 0 ? tlsMs / tcpMs : 0 }
}

/// 历史基线：同一 (接口, SSID, 时段) 的滚动统计，回答"今天比平时慢吗"。
struct Baseline: Codable, Sendable {
    let scope: String           // "en0|HomeWiFi|20"
    let sampleCount: Int
    let medianTTFB: Double
    let p10: Double
    let p90: Double
}

/// 一次优化/清理的判定结果。三态 + 误差区间，绝不只给一个百分比。
enum Verdict: String, Codable, Sendable {
    case improved, unchanged, regressed, inconclusive
}

struct ChangeReport: Codable, Sendable {
    let actionID: String
    let before: Measurement
    let after: Measurement
    let controlBefore: Measurement?   // 对照组（不受改动影响）
    let controlAfter: Measurement?
    /// 净改善 = Δ实验组 − Δ对照组，单位 ms 或 %，按指标而定
    let netDelta: Double
    let mdd: Double                   // 最小可检测差异 2.8·σ/√n
    let verdict: Verdict
    let rolledBack: Bool
}
```

### 4.3 关键采集骨架

```swift
// L0 —— 推送式，不用轮询
let monitor = NWPathMonitor()
monitor.pathUpdateHandler = { path in
    // path.status / usesInterfaceType(.wifi) / isExpensive / isConstrained
}

// L3 —— 一次跑完吞吐 + RTT + 握手分解（-c 出 JSON，别解析人类可读输出）
// networkQuality -c -s -M 20   →  base_rtt, dl_throughput, dl_responsiveness,
//                                 il_tcp_handshake_443, il_tls_handshake, interface_name
let json = try await OptimizeEngine.shell("/usr/bin/networkQuality -c -s -M 20",
                                          timeout: 45)

// L4 —— 四段耗时分解，比任何"测速"都更接近用户体感
func urlSession(_ s: URLSession, task: URLSessionTask,
                didFinishCollecting m: URLSessionTaskMetrics) {
    guard let t = m.transactionMetrics.last else { return }
    // domainLookupStart/End → TCP connectStart/End → secureConnectionStart/End → responseStart
    // isReusedConnection == false 才有握手耗时，复用连接要单独标注
}

// L5 —— 两次采样求增量
// nettop -P -L 1 -x -J bytes_in,bytes_out -t wifi
```

### 4.4 吞吐怎么测（不依赖 networkQuality 的自建实现）

`networkQuality` 好用，但只能测 Apple 的服务器、且一次跑满几十秒流量。要"可复现、可换端点、可只测延迟"，需要自己的实现。三条硬规则：

1. **多流并发**：单流受拥塞窗口与 BDP 限制，通常比真实带宽低 30–50%。固定 4–8 条。
2. **丢弃预热**：TCP 慢启动让前 1–2 秒严重偏低。只统计最后 N 秒的稳态速率。
3. **不走缓存**：URL 带唯一参数 + 独立的 `URLSessionConfiguration`（禁用连接复用、禁用缓存）。

```swift
/// 多流并发下载，返回稳态吞吐（Mbps）。丢前 `warmup` 秒。
func measureDownload(host: URL, streams: Int = 4, seconds: Double = 8,
                     warmup: Double = 1.5) async -> (mbps: Double, bytes: Int64) {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.httpMaximumConnectionsPerHost = streams
    cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let session = URLSession(configuration: cfg)

    let start = Date()
    var windowStart = start.addingTimeInterval(warmup)
    var windowBytes: Int64 = 0

    // 每条流各自续传：服务器返回多少收多少，凑够 seconds 就停
    await withTaskGroup(of: Int64.self) { group in
        for _ in 0..<streams {
            group.addTask {
                var total: Int64 = 0
                while Date().timeIntervalSince(start) < seconds {
                    // 唯一 query 参数绕开 CDN 缓存
                    let url = host.appending(queryItems: [.init(name: "r", value: UUID().uuidString)])
                    guard let (data, _) = try? await session.data(from: url) else { break }
                    if Date() >= windowStart { windowBytes += Int64(data.count) }
                    total += Int64(data.count)
                }
                return total
            }
        }
        for await _ in group {}
    }

    let steady = seconds - warmup
    return (Double(windowBytes) * 8 / steady / 1_000_000, windowBytes)
}
```

配套注意：

- `windowBytes` 是跨任务累加，真实实现要用 `actor` 或 `OSAllocatedUnfairLock` 包一层，别在并发闭包里直接写 `var`。
- 上传同理（POST 到可丢弃端点），但**默认关闭**——上行流量最贵，且多数"慢"不是上行问题。
- 端点选择：优先自建（最可控），其次公开 Anycast 测速端点；无论用哪个，**报告里必须写明端点**，否则数字不可比。
- `networkQuality -c` 仍然保留作为"标准参照"：它的 `dl_responsiveness`(RPM) 是苹果自己的体感指标，可以用来交叉验证自建实现是否跑偏。

### 4.5 路由与导航

- `Route` 加 `case network`，`Route.icon = "wifi"`（保持 13pt/medium 线性图标规范）
- 放 `RouteGroup.insights`（洞察组），与"状态/分析"并列——它是只读诊断，不是清理动作
- `RootView.detail` 加 `NetworkView(onClose: backToDashboard)`

### 4.6 MCP / AI 工具（两个，一读一写）

```swift
Tool(name: "network_diagnose",
     description: "Run a layered network diagnosis (path, DNS, latency, throughput, per-process flow) and return findings.",
     params: [Param("layers", "array", "Subset of link/local/dns/transport/app/process", enums: nil)],
     destructive: false) { args, _ in ... }

Tool(name: "network_optimize",
     description: "Apply a network fix (dns_switch, proxy_off, mtu_fix) with before/after measurement and automatic rollback.",
     params: [Param("action", "string", "Fix to apply", required: true,
                    enums: ["dns_switch", "proxy_off", "mtu_fix", "dns_flush"]),
              Param("confirmed", "boolean", "User confirmed", required: true)],
     destructive: true) { args, mode in ... }   // 走现有 ApprovalMode 双通道
```

关键：`network_optimize` 的返回值必须包含 `before` / `after` / `improved: Bool` / `rolledBack: Bool`。AI 才有资格说"我修好了"，而不是"我执行了命令"。

---

### 4.7 CLI 现状（P0 + P1 已实现）

```bash
Moppet --net-probe                                  # 五层报告：分段表 + 对照 + 冷 DNS + findings
Moppet --net-probe --samples 9 --json               # 结构化输出，供脚本/CI 用
Moppet --net-probe --hosts www.apple.com --throughput   # 多流吞吐（会消耗流量）
Moppet --net-probe --compare --rounds 6             # A/A 参照系自检：不做任何改动，应全为 unchanged
Moppet --net-probe --compare --run "<命令>"          # A/B：测 → 执行 → 再测，输出净改善与三态
```

每次运行都会把结果追加到 `~/.moppet/network/samples.jsonl`（0600，一行一个 host），
下一次同一接口同一时段的运行会多打印一行 `history`：`ttfb p50 / p10 / p90`。
`--no-record` 可跳过写入（例如做实验时不想污染历史）。

**A/A 自检**是这套东西的验收标准：什么都不改，四个指标必须全部读 `unchanged`。
如果哪天它开始报"改善"，说明判定逻辑坏了，而不是网络变好了。实测输出：

```
A/A reference test · 6 paired rounds · www.apple.com · control 192.168.0.1
metric  before     after      Δ          σ         MDD       verdict
ttfb    21.9       20.5       -1.8       3.1       3.6       unchanged
tls     31.4       69.8       +16.7      33.2      38.0      unchanged
tcp     10.2       10.2       -0.6       1.1       1.2       unchanged
dns     106.7      99.4       -7.3       7.7       8.8       unchanged
→ 4/4 unchanged — the pipeline does not invent improvement.
```

`--smoke` 里另有 10 条合成数据断言（清晰改善必须判 improved、噪声必须判 unchanged、
n<5 必须 inconclusive、对照组同幅漂移必须把改善抵消掉），保证判定逻辑不靠现场数据也能验证。

## 5. UI：三块，一屏看完

1. **结论区**（最重要）：按严重度排序的 Finding 卡，每条一行标题 + 置信度点 + "查看证据"展开。没有问题时明确写"未发现明显瓶颈"，并给出实测数值，而不是空状态。
2. **时间线**：DNS→TCP→TLS→TTFB 的横向条，宽度按耗时。一眼看出卡在哪一段。
3. **明细**：接口/网关/MTU/DNS 解析器表、进程流量 Top 5、阶段放大比。默认折叠。

时间线要带**参照刻度**：把"本机历史中位数"画成一条竖线，当前这次测量的每段柱子和它比，长出来的部分才值得看。没有参照的时间线只是好看。

交互红线：**任何写操作前先展示 baseline 与预期**；执行后展示 `ChangeReport` 的三态 chip（`改善 22% (超出误差)` / `无变化 (在误差范围内)` / `变差，已回滚` / `无法判定`），绝不只给一个百分比。没有改善要明说，不粉饰。

---

## 6. 分阶段计划

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **P0**（测量内核，2–3 天）✅ | `NetworkEngine` 四段分解 + 多流吞吐 + `Measurement` 模型；`NetworkView` 先只展示原始数值 | 同一端点连测 5 次，TTFB 中位数波动 < 15%；吞吐与 `networkQuality` 交叉验证误差 < 20% |
| **P1**（参照系 + 规则，3–4 天）✅ 测量与判定已实现，规则表待接入 UI | `Baseline` 历史分桶、对照组校正、`ChangeReport` 三态判定；`NetworkDiagnostics` 规则表 + 证据行；`--smoke` 喂固定样本断言 | 能报出"DNS 配置与实际不一致""握手放大 400×"两条；对一次无效改动必须输出 `unchanged` 而不是假百分比 |
| **P2**（可回滚优化，3–5 天） | `NetworkOptimizer` 4 个动作（刷新/切换 DNS/关 PAC/MTU）+ 配对测量 + 回滚 + 写 History | 每个动作都产出 `ChangeReport`；无效改动自动回滚；回滚后配置与执行前逐字节一致 |
| **P3**（进程与 Wi-Fi） | `nettop` 增量、CoreWLAN RSSI/信道、`URLSessionTaskMetrics` 探针 | 进程流量 Top5 与活动监视器误差 < 5% |
| **P4**（可选） | 每周体检（Scheduler，只出报告不改配置）、趋势图 | 不产生任何写操作 |

建议先做 **P0+P1**，因为它已经能回答用户 80% 的问题（"为什么慢"），且零风险、零权限。写操作放到 P2，是因为它需要提权、需要回滚、需要更多验证——收益却小于"告诉用户真相"。

---

## 7. 风险与合规

| 风险 | 处置 |
|---|---|
| **沙盒（MAS 版）** | 沙盒内 `networksetup` 写操作、`killall` 全部不可用（见 `docs/APPSTORE_PLAN.md` §1.1）。**MAS 版只保留只读诊断**（`NWPathMonitor` + `URLSessionTaskMetrics` + 解析计时全在沙盒内可用）；写操作只在 Developer ID 直发版提供。用 `#if` 或运行时能力探测做功能门控，而不是两套代码。 |
| **定位权限** | CoreWLAN 读 SSID/BSSID 在 macOS 14+ 需 `NSLocationWhenInUseUsageDescription`。RSSI/信道不需要。方案：SSID 缺失时降级显示"当前网络"，不阻塞诊断。 |
| **提权** | 复用 `OptimizeEngine.shellWithAdmin`（AppleScript 管理员弹窗），不要引入 SMJobBless helper——那会显著增加上架与签名复杂度。 |
| **误诊** | 置信度 < 0.7 的结论只提示不执行；规则抑制表防"网关不稳却建议换 DNS"。 |
| **数据使用** | `networkQuality` 会消耗流量（默认跑满几十秒）。必须在 UI 明示"将消耗约 XX MB 流量"，并允许关闭吞吐测试只测延迟。 |
| **私有 API** | 禁用 `NetworkStatistics.framework`；`nettop` 是系统 CLI，属允许范围。 |

---

## 8. 一句话总结

**不要做"网络加速"，做"网络体检"。** 五层采样 → 规则归因 → 只改能改的（DNS/代理/MTU/服务顺序）→ **配对复测** → 没效果就回滚。

而"有没有效果"这件事，必须靠参照系而不是感觉：**时间参照（A/B 配对）+ 空间参照（对照组）+ 历史参照（分桶基线）**，三态判定（improved / unchanged / regressed / inconclusive），测不出来就说测不出来。清理磁盘的参照物是字节数，网络优化的参照物只能是统计量——把前者的话术套到后者身上，就是骗人。
