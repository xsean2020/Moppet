# HANDOFF — Moppet（airi 界面 × mole 功能 × Codex 大脑的 macOS 桌宠清理工具）

> 交接文档：下一个 agent 从这里开始。写于 2026-10-24，对应代码状态：**构建 0 错误 0 警告，全部验证绿**（见 §2）。
> 项目路径：`/Users/sean/cleaner/Cleaner`（Swift Package，Xcode 直接打开 `Package.swift` 即可）。

---

## 2026-10-30 增量（审核优化 + 视觉轮，构建 0 错 0 警，smoke 237 ✓ / brain-smoke 226 ✓）

接在 47b692f「Analyze overhaul」之后的一轮审核修复，下一 agent 以本节为准（下文旧数字已过时）：

- **UninstallEngine 提权兜底接线**（前一会话遗留的 `deleteBundleWithAdminFallback` 半成品）：`batchUninstall`/`uninstall` 新增 `fallback: Bool = false`，仅 GUI 调用点（UninstallView 两处）传 `true`；无头（MCP `uninstall_app`、smoke）保持默认 `false`，否则 `shellWithAdmin` 的 MainActor hop 在阻塞主线程的无头模式里死锁（§6.1）。TCC 拒绝 → 管理员密码弹窗重删；取消密码框 → 保留 App Management 提示，授权引导卡照常触发。
- **BatchDeleter 白名单子树保护（P0）**：`checkDeletable` 只看种子自身与祖先，选中 `~/Library/Caches` 会连带删掉白名单里的 `~/Library/Caches/Steam`。修复三层：① 白名单种子直接剔除；② 子树可能含白名单命中的种子强制降到展开层（`subtreeMayContainWhitelisted` 通配符前缀结构判定）；③ 展开层逐路径 `isWhitelisted`，命中的文件/目录记入 `Outcome.skippedWhitelist` 并**不删**；rmdir 阶段对含保护内容的目录改用**plain `rmdir()`**（removeItem 是递归的，会把白名单内容一起带走）。
- **路径形式坑（新）**：本机实测 `/var` 类路径有两个活形式（`/var/...` 与 `/private/var/...`），且 `resolvingSymlinksInPath` 与 `realpath` 的归一结果**互相矛盾**（前者归到 /var 形式、后者归到 /private 形式）。BatchDeleter 内部所有前缀比对统一用 `canonical()` = `resolvingSymlinksInPath`（与 SafetyGuard 匹配宇宙一致）；SizeCache 的 key/invalidate 则统一 `realFileSystemPath`（realpath）——两个子系统各自内部一致即可，**不要跨系统混用两种归一器**。smoke 新增 3 断言（白名单子树存活/兄弟删除/跳过上报），测试文件 swap 真白名单后立即恢复。
- **其余审核修复**：AnalyzeView 取消竞态（phase-1 落地前与 `scanTask = nil` 前都加 `Task.isCancelled` guard，取消不再清空树/选中/新任务句柄）；BubbleChart 把 body 期间写 `@State` 的缓存挪到 `@MainActor static`（SwiftUI body 内写状态是未定义行为）；SystemStatus `topProcesses` 的 sysctl 重试第二圈曾是死代码（第一圈失败直接 return）；PetBus 新增流式轮次语义（`beginStreamingTurn`/`sayStreaming`/`endStreamingTurn`/`dismissStreaming`），QuickChat 的 delta 不再逐条 bump messageID——**点宠物关掉流式气泡后不再被下一个 token 弹回**（错误仍会穿透显示）；Evolver.cancel 现在取消真实 tick 任务（旧代码 `task` 从未赋值，取消是空操作且 `running=false` 会放行并发 tick）；BrainActivity.idleOverride 读写进锁。
- **视觉轮**：Analyze 首扫进度环终于接上了数据（此前永远 0%）——phase-2 每测完一个源 tick 一次，底栏新增「测量中 N / M…」心跳 chip（两相扫描下底栏不再看起来已经完成）；EntryRow 的 `NSWorkspace.icon(forFile:)` 加 NSCache（流式 re-sort 时不再每 body 重新取图）。
- 已知未修（审核确认、留待后续）：ScrollbarTuner 每 didUpdate 全树遍历 + 滚动条不可交互/无 AX（需要重设计）；BrainGrowthCard.refresh 在 MainActor 做整片文件 IO；parallelSize 任务数无滑动窗口上界（IOThrottle=32 兜底）；AnalyzeView 删除收尾的同步 IO 在主线程。

### 2026-10-30 追加：大文件「自定义目录」

- `LargeFilesEngine.Scope` 新增 `.custom`；`find(...)` 增加 `customRoots:` 参数（仅 `.custom` 读取，自动展开 `~`、过滤已不存在/非目录的路径，空集合直接返回）。新增 `LargeFilesEngine.CustomRoots`，用 UserDefaults（key `largeFiles.customRoots`）持久化绝对路径。
- `LargeFilesView` 范围菜单新增「自定义目录」：首次切入选会自动弹 `NSOpenPanel`（仅目录、可多选）；卡片内每个目录一个 chip，可单独移除；失效目录标红「目录不存在」并在扫描时跳过；改动目录集合会清空旧结果，避免把已移除目录里的文件误勾进废纸篓。目录为空时 Scan 禁用。
- 空结果提示从 `spotlightWarning: Bool` 改为通用 `warningMessage: String?`（Spotlight 未开 / 自定义目录全部失效共用一张卡）。`--smoke` 通过。

### 2026-10-30 追加：空气泡（模型无输出 / 报错）改为提示文案

- **现象**：快问快答（QuickChat）的答案写在宠物气泡里。模型没有任何文字输出时（纯工具轮、空回复），`turnCompleted` 把 `""`（或只剩 `" · 812 tk"`）写进气泡，`hideAfter 0` 让一张**空白卡片**一直挂着；错误描述为空时则是一个孤零零的 `✗`。聊天窗的 assistant 空条目同样会渲染成空卡片。
- **PetBus 统一兜底**：新增 `emptyAnswerHint`（模型没返回文字 → 提示去聊天窗看详情）与 `streamingPlaceholder`（`…`）。`say()` / `endStreamingTurn()` 的空白文本一律替换为提示；`beginStreamingTurn()` 直接以 `…` 开场（首 token 慢时不再是空气泡）；`sayStreaming()` 忽略纯空白增量（否则气泡被清空但还在屏幕上）；空白收尾不摆 celebrating 姿势，落到 `.idle`。
- **QuickChat**：空回答不再拼接 token 计数（否则气泡只剩 `" · 812 tk"`）；错误描述为空回落「模型返回了错误，但没有给出原因。」。
- **视图侧兜底**：`PetView.bubbleMessage` / `PetBubbleContent` / `ChatView.markdownBubble` 对空白文本再兜一层（渲染提示而不是空卡片），宽高也按兜底文本计算，避免「窄卡片 + 长提示」溢出。
- 验证：`swift build --disable-sandbox` 0 错 0 警；`--smoke` PASS（新增 4 条气泡断言：占位开场 / 空白增量保占位 / 空收尾转提示且不庆祝 / 空白 `say()` 转提示）。

### 2026-10-30 追加：项目清理「搜索根目录」改用文件夹选择器

- **动因**：手打路径太麻烦（且打错只会得到「目录不存在」）。`PurgeView` 的 `TextField + Add` 换成 `NSOpenPanel`（仅目录、可多选、起始目录为最后一个根目录），与「大文件 → 自定义目录」的交互对齐。
- **持久化**：新增 `PurgeEngine.RootsStore`（UserDefaults key `purge.roots`，存绝对路径）。`load()` 返回 `nil` 表示从未保存 → 首次仍用 `defaultRoots()`；保存空数组表示「用户清空了」，不会被默认值覆盖回来。此前手工添加的目录关窗即丢。
- **一致性**：根目录集合变化会清空已扫出的行/勾选/结果文本——已移除目录里的产物不能还留着被勾选删除；列表行用 `~/` 缩写显示，悬停看全路径；全部删空时提供「恢复默认目录」并把 Scan 禁用。
- **保留的防线**：`/` 与家目录仍被拒绝（`Refusing to walk the whole disk / home folder`），只是提示从红框改为行内红字。
- 影响面：`PurgeView` 仅被 `RootView` 引用；`swift build --disable-sandbox` 0 错 0 警，`--smoke` PASS。§10 里「Purge 根目录框补 FocusState 焦点接线」那条随文本框一起作废。

### 2026-10-30 追加：侧边栏视觉轮（图标 / 排版 / 色彩 / 顶底布局）

按一份四维度视觉批评落地，**面板已抽成独立文件**：

- **结构**：侧边栏从 `RootView.sidebar` 抽成 `Views/SidebarPanel.swift`（`SidebarPanel` + `RouteGroup` + `SidebarRowButton`），`RootView` 只剩一行委托。`RouteGroup.bottom`（历史/设置）从滚动列表尾部改成**钉在 ScrollView 之外**——作为列表尾部时，700pt 默认窗口高度下「设置」直接被裁掉。
- **图标**：全部换成线性 SF Symbols（`tray.full→tray`、`square.and.arrow.down.on.square→trash`、`chart.bar.doc.horizontal→chart.bar.xaxis`），统一 `.system(size:13, weight:.medium)` + `.symbolRenderingMode(.monochrome)`；底栏 `pawprint.fill→pawprint`。
- **排版**：行高 32、行缝 1、组间距 14、行内边距 12、圆角 8；分组标题 11pt Regular `#8E8E93`（深色 `#9C9CA3`）——**CJK 标签不加 tracking**（`headerTracking()` 判断），否则中文会变成「空 间 清 理」。
- **色彩**：选中态 `rgba(0,122,255,0.08)`（深色 0.22 alpha），去掉原来的 primary 阴影 + semibold；未选中补 hover 底衬（浅色 black 4% / 深色 white 6%）。
- **顶/底**：品牌行 14pt semibold、图标 22pt，顶部留白在 32pt 标题栏安全区之外再加 26pt；底部 `Divider()` 换成两端渐隐 hairline（`Airi.hairline`），footer 图标统一 12pt。
- 令牌集中在 `AiriTheme.swift` 的 `// MARK: - Sidebar ladder`。
- **新调试开关** `--probe-sidebar <png> [light|dark] [height]`（`App/SidebarRenderProbe.swift`）：面板离屏 2x 渲染，无需录屏权限。注意：本机 `screencapture` 无权限；`NavigationSplitView` 在离屏 NSWindow 里**不布局 sidebar 列**（只能单独 host 面板）；构建须 `swift build --disable-sandbox`。

### 2026-10-30 追加：网络测量内核 + `--net-probe`（P0，仅 CLI，无 UI）

- 新增 `Core/Modules/NetworkEngine.swift`（测量内核）+ `Core/NetworkProbeCLI.swift`（`--net-probe` 入口）。开关：`--samples N` `--hosts a,b` `--json` `--throughput`。
- **分段测量必须用 Network.framework，不能用 URLSession**：本机开着 PAC 代理时，`URLSessionTaskMetrics` 把请求塞进隧道，报出 TCP 1454ms，而直连同一 IP 的 `connect()` 只有 1.0ms（`connectionProxyDictionary` 与清空 `*_PROXY` 都无效）。`NWConnection` 不读系统代理，拿到的是网络本身。
- 四个阶段：DNS（`getaddrinfo`，冷解析用 `r<rand>.example.com` 绕缓存）→ TCP（BSD 非阻塞 `connect()` 到 IP，排除 DNS 污染）→ TLS（`NWConnection` TLS ready 减去 TCP）→ TTFB（TLS 连接上发 HTTP/1.1 GET，ALPN 钉死 h1.1，否则 h2 二进制帧让"首字节"失去意义）。
- **实测基线（本机，2026-10-30）**：cloudflare TCP 1.2ms / TLS 1800–2400ms（放大 1000×+，握手反复 RTO）；apple TCP 7ms / TLS 35ms；baidu TCP 35ms / TLS 40ms；冷 DNS 100ms。若只 ping 或只测 DNS 会得出"网络很好"的相反结论。
- 判定阈值：**TLS > 400ms 且 TLS÷TCP > 10** 才算握手异常。只看比值会误报——TCP 4ms → TLS 100ms 也是 24×，那是正常证书开销。
- 吞吐：多流（默认 4）NWConnection 下载 + 丢弃前 1.5s 慢启动，实测 9.4Mbps / 7.6MB / 6.5s。
- `--smoke` 新增 11 条统计断言（中位数抗离群、偶数取中间两值均值、MAD 围绕中位数、p95、负值丢弃、放大比零除保护），当前 **SMOKE PASS**。
- 踩坑：`StreamReader` 用 `[weak self]` 会让 reader 在 continuation 闭包返回后立刻释放，handler 变空操作 → continuation 永不 resume → 整个测速挂死（120s 超时）。必须强引用 + `finish()` 里置 nil 断环。

### 2026-10-30 追加：网络参照系（P1）+ `--compare`

- 新增 `Core/NetworkReference.swift`：`Verdict`（improved/unchanged/regressed/inconclusive）、`MetricChange`、`paired()`、`unpaired()`、`NetworkSampleStore`（`~/.moppet/network/samples.jsonl`，0600，按 `interface|host|hour` 分桶）。
- `--compare`：默认 **A/A 自检**（A、B 交错各 6 轮，什么都不改，四个指标必须全 `unchanged`）；加 `--run "<cmd>"` 变 A/B（测→执行→再测，不可回滚的配置改动走 unpaired）。
- 判定：`MDD = 2.8σ/√n`，σ 用 1.4826×MAD；**对照组默认取网关**（不经 DNS/WAN），`净改善 = Δ实验 − Δ对照`，σ 平方和相加；再叠加 3% 实际下限；`n<5` 一律 `inconclusive`（findings 同样要求 n≥5）。
- 普通运行自动记录历史，下次同接口同时段多打一行 `history ttfb p50/p10/p90`；`--no-record` 跳过。
- **验收**：A/A 实测 `4/4 unchanged`；`--smoke` 新增 10 条合成断言（清晰改善→improved、噪声→unchanged、n<5→inconclusive、对照组同幅漂移把改善抵消）全绿。
- 坑：函数内 `typealias Ref = NetworkReference` 会让 Swift 误判外层 `failures` 恒为 0，在 `print(failures == 0 ? ...)` 报 "will never be executed"；改用全限定名。

### 2026-10-30 追加：网络测量代码评审修正（4 条）

- **NWPathMonitor 等待**：轮询 20×50ms（上限 1s）改为 `withCheckedContinuation` + `ResumeGate` 单次 resume + **2s** 超时。回调即返回，不再靠轮询撞运气。（注：`interface` 原本不会丢——它 fallback 到 `route.interface`；真正会丢的是 `interfaceKind/isExpensive/isConstrained`。）
- **SYN 重传判定**：原实现用绝对值 1s/3s/7s ±25%，会把 900ms 的正常连接误判成重传。改为**相对基线**（取最快样本）+ 步长 15% 窗口 + 要求 n≥3；已加回归断言「慢链路不算重传」。
- **外部命令**：本来每次运行只调一次，但发现一个隐藏的第三次调用——`route -n get default` 输出里**没有 `mtu:` 键**（MTU 在表格列里），所以 `route.mtu` 恒为 nil，`networksetup -getMTU` 每次都会跑，而且是同步阻塞。改为按表头名定位 `mtu` 列解析，fallback 改 async 且基本不再触发。解析器抽成纯函数 `parseRoute`，用真实样本在 `--smoke` 里断言。
- **统计防御**：`Stats.of` 原本已 `guard !isEmpty` + `isFinite` 过滤，不会除零。但评审点得对——NaN 的后果不是崩溃而是**静默失效**：`NaN > mdd` 恒为 false，判定会永远读 `unchanged`。补了 NaN/Infinity/空数组的显式断言。

### 2026-10-30 追加：网络优化动作接线（P2 的 CLI 半）+ `--net-fix`

- `NetworkOptimizer.swift`（plan/execute/verify/measure/rollback 全套）此前已写好但**没有任何调用方**——它自己注释里提到的 `--net-fix` 入口并不存在。本轮补上：新 `Core/NetworkFixCLI.swift`，MoppetApp knownFlags 注册 `--net-fix --action --dns --mtu --dry-run --host`（`--yes/--rounds/--json` 复用）。
- 用法：`--net-fix`（无参数）= 只读列当前状态（路由/服务/DNS/PAC/MTU + 动作清单）；`--action <dns-switch|dns-flush|proxy-off|mtu-fix|noop>` + `--dns <ip,…>` / `--mtu <n>`；**不带 `--yes` 永远只打印 plan**（exact 命令 + 回滚命令），`--dry-run` 同义但显式。提权：root 直跑，否则 AppleScript 管理员弹窗（与 LaunchItems 同路）。
- **退出码只反映持久配置的结局**：0 = 保留/仅 plan/未改持久状态，1 = 回滚了或 apply 失败，2 = 用法错误。noop 自测即使全 `inconclusive` 也是 0——它本来就不该被 keep；首版用 `!kept||rolledBack` 会把健康自测报成失败，已修。
- `NetworkOptimizer.run` 语义修正：noop 不再走"回滚"分支（`plan.isNoop` 时 `rolledBack` 恒 false）——它证明的是测量链路能读 unchanged，不是假装修复；dns-flush 无逆动作时补"nothing to restore"说明。
- 审计落盘：每次 apply 尝试写一条 `HistoryStore` 记录，`RecordSource` 新增 `.network`（icon `wifi`，标题 L("Network")，词条已存在）；`CleanRecordItem.path` 存的是**实际执行的命令串**，历史页能回答"到底跑了什么"。
- **smoke +16**（net fix 块）：服务解析（含 `(*)` 禁用态与带空格名）、DNS 解析（"There aren't any DNS Servers"→DHCP 空）、PAC 解析、地址校验器（含注入串拒收）、服务名校验（引号/反斜杠）、**回滚命令逐字断言**——DHCP 状态回滚到 `Empty`、静态 DNS 回滚还原原值（不是 Empty）、PAC URL 保留式关断、MTU 回滚到 `-setMTUAndMediaAutomatically`、noop 零改动。
- **实测（本机）**：`--net-fix` 列出 en0 活跃 + DNS 8.8.8.8,1.1.1.1 + PAC localhost:1089（设计文档里那个 PAC 残留还在）；`--action proxy-off --dry-run` 打出 plan 且零变更；`--action noop --yes --rounds 3` 全链路 apply→verify→measure 跑通（n<5 → 全 `inconclusive`，符合设计）；`--json` plan/state 两种模式结构化输出可脚本消费；未知 action / 缺 `--dns` 均 exit 2。**真实 apply（改配置）未在本轮实测**——需要管理员授权且会改机器状态，留给用户手动验证（建议顺序：noop → proxy-off[先确认 PAC 真不要了] → dns-switch）。
- 剩余（非 CLI）：MCP 工具 `network_diagnose`/`network_optimize`（设计 §4.6）、NetworkView GUI（设计 §5）、P3 进程/Wi-Fi 层。

### 2026-10-30 追加：网络模块审查修 bug 轮 + 两个 MCP 工具（设计 §4.6 完成）

- **真 bug ①（有害回滚）**：`NetworkOptimizer.plan(.proxyOff)` 在预检 PAC 本来就是 off 时，rollback 仍生成 `-setautoproxystate on`——若 apply（幂等 off）后测量读"无改善"，回滚会把用户**关着的 PAC 重新打开**。修：rollback 仅在 `pac.enabled` 时生成；且 `run()` 对 `already` 前缀的 warning 短路（不 apply、不测量、直接返回），mtuFix 的 "already ≤ target" 与 dnsSwitch 的 "already set" 同样短路——原来会白跑 12 轮测量再"回滚"一次幂等写。
- **真 bug ②（判定与显示不一致）**：`unpaired()` 展示的 MDD 是加宽公式 `2.8σ·√(1/nb+1/na)`，但 `verdict()` 内部用窄公式 `2.8σ/√n` 判定——Δ 落在两者之间时输出行自相矛盾（Δ < MDD 列却判 improved）。修：`verdict` 加 `mddOverride`，unpaired 传入加宽值。回归断言用 Δ=4.5 卡在窄 3.71/宽 5.25 之间（修前 improved、修后 unchanged）。
- **真 bug ③（吞吐在慢握手链路给空、快链路低估）**：旧实现每流只发一次请求——快链路 2MB×4 流在预热期就传完，速率除以标称 6.5s 窗口严重低估；慢握手链路（本机实测 TLS 握手 10s > 8s 窗口）则整个测量空手而归且无声。修：按设计 §4.4 改成**循环请求直到截止**（每请求新连接+唯一 query 参数），速率按字节实际覆盖的窗口除；在途请求不被截止时间腰斩（窗外字节不计入）；空结果时 CLI 明说"handshakes alone exceeded the window"（独立 NWConnection 脚本实测本机此刻 ready 要 9.94s——不是代码回归，是网络当时就这么烂）。
- **新 bug（重写时引入，实测抓到）**：字节计数原是 `Task { await actor.add(...) }` 从 NWConnection 非异步回调投递——无结构 Task 与结束 continuation 竞态，测量读数时末尾分块可能还没进 actor（表现为空吞吐）。改加锁同步计数类 `ByteCounter`（add 在回调里直接调）。
- 其余修复：`--compare --run` 命令失败原来 `try?` 静默吞掉（A/B 变成纯噪声对比）→ 失败原因打进输出并标"do not read it as a verdict"；`run()` 选活跃服务加 `isSafeServiceName` 过滤（read* 帮手在 plan 之前就拼 shell）；`writeHistory` 只在真正到达机器的 apply（applied 或 apply-failed）且非 noop 时写——"nothing to do"不再产生空审计行；阻塞的 `getaddrinfo`/`connect(2)` 加 `*Async` 包裹（detached 全局队列），`sampleRound`/`collect` 全部改走异步路径——为 MCP 化铺路（协作线程不再被 DNS 卡 30s）。
- **新工具 ×2（MCP 29→31）**：`network_diagnose`（只读，hosts≤4/samples 3–15/throughput 显式 opt-in，返回 Report JSON，**record: false** 不污染 CLI 历史基线）+ `network_optimize`（destructive，action 枚举含下划线别名，dry_run 参数出 plan，返回 `fixJSON`——含设计契约要的 `improved` Bool 与 `rolledBack`）。destructive 确认沿用 registry 统一 `confirmed` 门控（与 execute_clean/docker_prune 同约定，不另设 confirmed 参数）。`NetworkFixCLI` 的 `fixJSON/writeHistory/privilegeForCurrentUser` 与 `NetworkProbeCLI.collect` 改 internal 供工具复用。
- **smoke +5**：unpaired MDD 一致性回归、PAC-off 零回滚、mtu already 前缀、双工具注册、optimize 工具 dry-run 全链路（executeSync 过 registry 门控）。全部 SMOKE PASS。
- 实测：already 短路两路径 exit 0 零测量；MCP stdio `tools/list` 见两新工具；吞吐空结果提示语正确。**真实改配置 apply 仍未实测**（同前轮边界）。
- 设计文档 §4.6 的两个工具至此完成；剩余：NetworkView GUI（§5）、P3（nettop/CoreWLAN）。

### 2026-10-31 追加：P3（进程/Wi-Fi/应用路径）+ P4（周检/趋势）全量完成

- **P3-L5 进程流量**：`NetworkEngine.parseNettopCSV`（纯函数）+ `procFlowDeltas(interval:)`（两次累计快照相减）。**实测更正：macOS 26 上 `nettop -L` 输出 CSV 而非设计文档声称的 JSON**——按 docker-df 教训先抓真机输出再写解析器：表头 `,bytes_in,bytes_out,` 按名定位列，行 `name.pid,in,out,`，pid 取**最后一个点**之后（`com.apple.WebKit.Networking.1234`），同名 pid 跨接口行求和，负增量（计数器重置）跳过。`--processes` 开关 + `--interval N`（2–30s，默认 5），表打 Top5。
- **P3 Wi-Fi**：`wifiSnapshot()` 走 CoreWLAN（detached 队列），RSSI/noise/信道/txRate；**SSID 无定位权限时为 nil → 显示 "current network"**（设计 §7 降级）。坑两个：`rssiValue()/noiseMeasurement()/transmitRate()` 是**方法**不是属性（忘了括号得到 Function）；`CWChannelBand` 的 Swift 导入枚举名与文档对不上（`.channelBand5GHz` 编译不过）→ 频段改用**通道号 >14 = 5/6GHz** 判断（展示够用）。RSSI/噪声为 0 视为"未知"不进报告。新 finding：`wifi.weak`（RSSI<-70 或 noise>-85，设计规则表）。
- **P3-L4 应用路径**：`appPathProbe` 用 URLSessionTaskMetrics（ephemeral、禁复用），**刻意保留系统代理路径**——P1 教训是直连测量不能走隧道，但 app-path 与 direct 的**差值**正是 PAC 代价的直接证据（实测本机：direct tcp 5.2ms vs app-path tcp 1144ms）。`URLSessionTaskTransactionMetrics` 的属性名两处与记忆不符：`isReusedConnection`（非 reusedConnection）、`networkProtocolName`（非 protocolName）。delegate 在自己的队列上把 metric 归约成 Sendable 值元组再出界；三路完成（metrics/完成回调/硬超时）走 ProbeGate 单次 resume。`appPhases` 抽成纯函数可 smoke。新 finding：proxy divergence（app ttfb > 3× direct 且差 >100ms）。
- **新 finding `process.hog`**：单进程占间隔上行 >60% **且**总量 >1MB（否则空机器的心跳包误报）；5s 窗口不满足设计"持续 30s"，finding 文案如实标注窗口时长。
- **P4 周检**：新 `NetworkCheckup.swift`——`com.moppet.netcheckup` LaunchAgent（周日 09:00，`--net-checkup install|uninstall|status`，bootout/bootstrap 无需管理员，与 Scheduler 同模式；plistXML 纯函数 weekday/hour 钳位）。`--net-report` = collect（record: true，基线就是它的意义）+ trend + findings，**只读诊断，绝不改网络配置**（P4 验收线；唯一落盘是自己的 samples 与 launchd 日志 `~/Library/Logs/moppet-net-checkup.log`）。`--net-trend` = samples.jsonl 按日中位数表（`dailyTrend` 纯函数：按本地日分桶、host 过滤、新→旧、截 N 天）。**实测：install → launchctl print 已 loaded → kickstart 手动触发 → 日志写出完整报告 exit 0**。注意：plist 指向当前二进制路径（.build/debug），换 release 路径后需重装。
- **network_diagnose 工具扩参**：`processes`/`app_path` 两个 boolean 透传 collect（默认关，进程采样加 ~interval 秒）。
- **smoke +12**（现 305 项全绿）：nettop CSV 解析（真机样本/列名定位/末点拆 pid/重复合并/空体）、daily trend（分桶/过滤/host 泄漏/中位数/天数上限）、checkup plist（--net-report/日志路径/钳位）、appPhases 纯提取（含全 nil）、wifi.weak/hog/divergence 三规则（含 hog 小流量不误报）。Date 亚毫秒精度坑：phase 断言必须容差（10ms 实测 9.99999）。
- 至此设计文档 P0–P4 的 CLI/工具面全部完成；剩余仅 NetworkView GUI（设计 §5）与 P4 的 GUI 趋势图。**周检 agent 当前处于已安装状态**（验证产物），不需要时 `Moppet --net-checkup uninstall`。

### 2026-10-30 修复：macOS 26 毛玻璃（vibrancy）完全消失

- **现象**：主窗口没有任何磨砂玻璃，侧栏和详情区都是纯色平板。
- **根因**：`WindowVibrancy` 用 `NSVisualEffectView` + `.behindWindow` 混合，这种模式要求窗口自身对合成器透明（`isOpaque == false` + `backgroundColor` 带 alpha）。macOS 26 的 SwiftUI 给的是 `isOpaque=true, backgroundColor=white`，效果视图无背景可采样 → 退化成纯色。全窗口实测只有 1 个 `NSVisualEffectView`（就是自己那个，material=21），**没有**系统 sidebar material；各详情页 `.background(Airi.pageBackground.opacity(0.001))` 那个 0.001 alpha 的 hack 也因此一直是白写。
- **非侧边栏视觉轮引入**：`git worktree` 编基线版本对比，基线同样 `opaque=true bgAlpha=1.0`，是 macOS 26（26.3.1 实测）改了窗口合成行为。
- **修复**：`Components.swift` 的 `PassThroughVibrancy` 新增 `makeWindowTransparent()`（`window.isOpaque = false` + `window.backgroundColor = .clear`），在 `viewDidMoveToWindow()` 和 `updateNSView()` 各调一次（resize / 外观切换 / 折叠侧栏都可能把窗口改回不透明）。ChatView 共用同一组件，一并修好。
- **诊断**：`--win-debug` 的 dump 新增 `opaque=` / `bgAlpha=` 两列；修复后实测 `opaque=false bgAlpha=0.0`，`--smoke` PASS。

### 2026-10-30 追加：状态页四象限弧「内部发光」（对照参考图）
- **动因**：参考图（四象限发光仪表盘）的 1/4 弧不是一条贴在图上的线，而是**从弧向圆心渗出一小段光**的灯管；本项目的四段弧只有一层 `radius 10 / 0.5` 的 shadow，读起来是"线"不是"光"。
- **量化参考图**（1142×982 截图，逐像素径向扫描）：弧线宽 ≈18px / 盘径 ≈900px（2%）；弧内外各有 ≈10–14px 可测辉光 + 一条很淡的长尾；**未填充轨道几乎不发光**；弧内侧 1/3 半径处的面板仍是中性 #131313（染色不会越过圆心）。
- **实现**（`GaugeArc`，仅此一处）：把单层 shadow 换成三层同色高斯阴影——`0.50 @ 0.22×线宽`（贴边高光）、`0.30 @ 0.80×`（主辉光）、`0.14 @ 1.80×`（长尾）；三层都用 `lineWidth` 的倍数，随环尺寸缩放而不是写死像素。
- **试过并否决的两个方案**（都在 `--probe-render status` 里对比过）：① 用"加宽的模糊描边"做辉光——模糊半径小于带宽时核心是实心的，读成弧外又套了一圈轮廓；② 用扇形 `Shape` + `RadialGradient` 给象限内部铺一层染色——径向渐变在缺口处被两条直边切断，像贴了一块半透明面板，即使加 `blur(10)` 也能看出接缝。结论：**只有阴影没有核心和边**，衰减才两面都顺。
- **浅色模式**：同样的 alpha 在白底上会变成褐色污渍，`GaugeArc` 用 `@Environment(\.colorScheme)` 把三层辉光乘 0.5（弧本身的颜色和线宽不变，只减它投出的光）。
- 验证：`swift build --disable-sandbox` 0 错 0 警；`--smoke` PASS；`--probe-render status` 深/浅两种外观均出图核对。

### 2026-10-30 修复：CPU 图标压在弧线上（状态页盘面 400 → 440）

- **现象**：CPU 图标的小方块被蓝色弧线穿过，图标背景与弧重叠。
- **根因（纯几何）**：内容块的左上角在半径 `√(124² + 148²) = 193` 处，而环带占 182…194 —— 角正好落在带内。原注释"corner 193 against a 194 radius"只保证了角不超出环的**外**缘，没保证躲开**内**缘。
- **为什么不能靠挪内容解决**：竖直方向只有 4pt 余量（400 − 2×52 − 2×92 = 112，中心盘 104）；把角压到内缘以内需要顶行下移 ≈23pt，中心盘会被挤到 66pt。横向内缩到 96 则左右两块会互相重叠。
- **修复**：`gaugeBoard` 画板 400 → **440**，`quadrantGrid` 仍钉在 400×400 框内居中。环外移到 r≈202 后，块角（193）让出 9pt，图标与弧之间实测 ≈20pt 间隙，**一个字都不用重排**，中心盘仍是 104。
- **连带重调**（环外移后图表带不再接弧）：上排 sparkline 160 → 185（CPU shift −48 → −73，内端保持 112），下排 levelBar 118 → 136（磁盘 shift −6 → −24）。实测磁盘条左端距弧内缘 3.5pt（扫描 `status_r3.png` y=878 行），与参考图"图表被弧切"一致。
- 验证：0 错 0 警；`--smoke` PASS；深/浅两版 `--probe-render status` 出图核对。

---

## 0. 一句话概述

原生 macOS 应用：**3D 桌宠（SceneKit）+ 聊天即宠物对话（后台是 OpenAI Codex agent 能力的完整 Swift 移植）+ mole 全部清理功能 + 内置工具经 MCP 双通道供外部 AI 调用**。技术栈 SwiftUI (macOS 14+) + Swift Concurrency，5 个开源依赖。

参考仓（只读，勿改）：
- `/Users/sean/cleaner/airi` — 界面设计语言与资产来源（MIT）。已取用：`idle_loop.vrma`（Resources/pet）、8 张表情贴纸（Resources/stickers，`stage-ui/src/assets/stickers`）。
- `/Users/sean/cleaner/mole` — 功能对标（GPL-3.0，tw93 商标）。**未复制任何代码**，仅实现同类功能；白名单文件格式兼容（`~/.config/moppet/whitelist`）。
- Codex 上游：`/tmp/codex`（克隆副本，可重新 clone `https://github.com/openai/codex.git`）。Brain 是其 agent 能力类别的 Swift 重实现（Apache-2.0）。

## 1. 快速上手

```bash
cd /Users/sean/cleaner/Cleaner
swift build                      # 构建（当前 0 error / 0 warning）
swift run                        # GUI（主窗口 + 3D 宠物面板 + 菜单栏图标）
swift run Moppet --smoke        # 99 项无头自测（安全层/glob/规则库/工具注册表/门控/登录契约/模型目录/可编辑清单…）
swift run Moppet --brain-smoke  # 51 项 Brain 全链路（apply_patch/沙箱/循环/rollout/MCP 往返）
swift run Moppet --mcp          # stdio MCP 服务器（外部 AI 接入方式之一）
swift run Moppet --mcp-http 8765 # HTTP MCP 服务器（也可在 app 内开关）
swift run Moppet --brain-exec "清理浏览器缓存并汇报" [--yes]  # codex exec 式无头单次执行
swift run Moppet --win-debug   # GUI + 5s 后 stderr 打印窗口 frame/occlusion/space（窗口问题自检）
swift run Moppet --route-perf  # GUI + stderr 打印每个路由切换的 commit/render 毫秒（两轮，性能自检）
```

用户侧要点：AI 需在 **Settings → AI Provider** 配置（9 厂商）或 **Settings → Codex Subscription** 用 ChatGPT 订阅登录（设备码）；宠物名/人格在 **Settings → Pet Identity**（persona 写入 `~/.moppet/brain/persona.md`，是系统提示词第一段）。

## 2. 当前验证状态（全绿）

| 验证 | 命令/方式 | 结果 |
|---|---|---|
| 构建 | `swift build` | 0 error / 0 warning |
| 核心自测 | `--smoke` | 99 断言 PASS |
| Brain 自测 | `--brain-smoke` | 51 断言 PASS（真实文件 apply_patch、Seatbelt 三档+联网/可写根、脚本化模型 4 工具轮、rollout 恢复、MCP 往返、exec 会话 stdin 往返、view_image、request_user_input 无头回落、图片/compacted 记录、斜杠命令） |
| stdio MCP | printf JSON-RPC 管道 | initialize / tools/list=23 / tools/call 全通；破坏性工具无 `confirmed` 被拒 |
| HTTP MCP | `--mcp-http` + curl 三请求 | 全通（app 内开关同理，Settings → MCP Server） |
| GUI | 启动后 kill -0 | 主窗+宠物面板存活；Quartz 实测宠物窗 250×400 在屏（floating 层） |
| 指标准确性 | MCP system_status | CPU 真实值（曾恒 0%，见 §6 陷阱） |
| 性能 | MCP analyze_disk 冷/热 | 并行递归测量 CPU 59%→133%；TTL 缓存 16.4s→7.2s |

## 3. 仓库结构（53 个 Swift 文件 ≈ 16.8k 行 + 资产）

```
Moppet/
├── Package.swift               # 依赖见 §4；resources: pet/vrma + stickers
├── README.md                   # 面向用户的功能文档（保持同步）
├── HANDOFF.md                  # 本文件
├── Sources/Moppet/
│   ├── Views/MoppetApp.swift  # @main、Route 侧栏导航(NavigationSplitView)、CLI 分发(--smoke/--mcp/--mcp-http/--brain-smoke/--brain-exec)、Chat 场景、MenuBarExtra(菜单栏，持有 openWindow 可重建已关窗口)、WindowIdentifierTagger
│   ├── Views/HomeView.swift    # Dashboard（磁盘环/快捷卡/状态胶囊）
│   ├── Views/CleanView.swift   # 清理流程：configure→scanning(环+跳动数字)→review(OutlineGroup 逐文件勾选)→cleaning→done
│   ├── Views/UninstallView.swift       # 应用列表(多选批量)+残留详情+系统残留 admin 移除
│   ├── Views/SlimView.swift            # mo slim 页面：扫描→勾选→确认→逐 app 结果/历史
│   ├── Views/LaunchItemsView.swift     # 启动项页面：逐项状态 chip+禁用/启用 toggle+admin+结果/历史
│   ├── Views/OptimizeStatusPurgeViews.swift  # Optimize 任务卡 / Status 实时卡(Charts 曲线) / Purge 项目产物
│   ├── Views/AnalyzeView.swift # 懒加载目录树(TreeNodeRow 递归)＋勾选进废纸篓
│   ├── Views/ChatView.swift    # 聊天窗：会话侧栏(ChatSessionStore)+宠物对话+审批 sheet+airi 贴纸头像；沙箱/审批控制条在输入框正上方
│   ├── Views/HistoryView.swift # 审计记录
│   ├── Views/SettingsView.swift# 身份/语言/Codex订阅(自动开浏览器/可取消)/AI厂商/桌宠/MCP开关/缓存/白名单/保护类别/关于
│   ├── App/PetPanel.swift      # AppDelegate+宠物面板 NSPanel(PetPanel.canBecomeKey/首帧淡入)、WindowRouter(开窗中继+离屏修复+--win-debug)、SceneReadyCoordinator、QuickScan
│   ├── App/PetView.swift       # SceneKit MolePuppet(3D 鼹鼠+7 状态动画+点击 poke+落地阴影)、气泡、内联审批卡、右键菜单
│   ├── App/QuickChat.swift     # Spotlight 式中央快捷输入条(纯输入 560×64，提交/点外/ Esc 收起，local+global 事件监视器判点外)、回答流回宠物气泡；独立 BrainAgent，rollout 进同一会话目录
│   ├── Brain/                  # ★ Codex agent 能力移植（宠物的大脑）
│   │   ├── BrainTypes.swift    #   AskForApproval/SandboxMode/ResponseItem(含 image 项)/事件流/Plan
│   │   ├── BrainAgent.swift    #   runLoop(流式→工具并行→回喂)、SDKChatModel/ResponsesModel/ScriptedModel、compactNow(/compact 真实摘要)、resume、exec 会话注册表、webSearch 开关、statusText//命令助手
│   │   ├── BrainTools.swift    #   shell/read_file/apply_patch/update_plan/view_image/exec_command/write_stdin/request_user_input + MCP tools/resources 三工具 + 清理工具(单次审批) 统一分发
│   │   ├── BrainExecSession.swift # unified_exec 移植：可恢复 exec 会话(spawn→yield→write_stdin 轮询/喂 stdin；/ps /stop；5min 寿命)
│   │   ├── BrainUserInput.swift  # request_user_input 原生 UI 中心(幂等 finish 盒；5min 超时；无头明确"未回答")
│   │   ├── BrainSlash.swift      # 斜杠命令共享 runner(/help /status /mcp /compact /init /diff /pwd /cd /ps /stop；/new /export /copy 为 UI 专属)
│   │   ├── ApplyPatch.swift    #   codex 补丁格式完整解析器(统一游标模型)
│   │   ├── BrainSandbox.swift  #   Seatbelt(-p 内联/realpath/POSIX sh/违规→升级询问；workspace-write 可选 network_access + writable_roots)
│   │   ├── BrainRollout.swift  #   JSONL 会话(session_meta/turn_context/response_item/compacted/image 项)+轻量枚举+AGENTS.md 链
│   │   ├── BrainMCPClient.swift#   stdio MCP 客户端(mcp__server__tool + resources/list·templates·read)
│   │   ├── BrainExec.swift     #   --brain-exec 无头执行
│   │   └── BrainSmokeTest.swift#   --brain-smoke（49 断言）
│   ├── Core/
│   │   ├── ToolRegistry.swift  # ★ 23 个工具：JSON Schema+双门控(.ui 原生审批 / .confirmedFlag；scan_slim/slim_apps/scan_launch_items/set_launch_item_enabled)
│   │   ├── AIProviders.swift   # ★ ZCode 式自定义 Provider：~/.moppet/ai-providers.json 注册表 + 每家独立 keychain 槽(api-key.profile:<id>) + 模型清单/{baseURL}/models 刷新
│   │   ├── AIAgent.swift       # AIVendor(9家)/AISettings/AIModelFactory/JSONBridge/AIToolBridge/AIConnectionTest
│   │   ├── CodexSubscription.swift # ChatGPT 设备码登录 + ResponsesModel(订阅后端专用 SSE 传输)
│   │   ├── MCPServer.swift     # stdio JSON-RPC(handleMessage 传输无关)
│   │   ├── MCPHTTPServer.swift # NWListener HTTP 传输 + MCPAppService(app 内开关/持久化/随启动恢复)
│   │   ├── ScanEngine.swift    # 并行递归测量(parallelSize)+规则扫描+topChildren
│   │   ├── SizeCache.swift     # TTL(3天)+mtime 失效的结果缓存(~/.moppet/brain/size-cache.json)
│   │   ├── SafetyGuard.swift   # 只删 home 内/20+保护类别/符号链接解析/白名单永远赢
│   │   ├── CleanExecutor.swift # 废纸篓路由/永久删除/删除前二次校验 + HistoryStore + DiskInfo
│   │   ├── RuleLibrary.swift   # 4 分区 24 规则
│   │   ├── Models.swift / PetBus.swift(事件总线+审批中心) / PetIdentity.swift(名字/persona)
│   │   ├── L10n.swift(中英)/Stickers.swift(贴纸映射)/SmokeTest.swift
│   │   ├── LaunchItemsEngine.swift # ★ 启动项：三目录扫描/plist 解析/Disabled 翻转+bootout/admin/com.apple 过滤/审计
│   │   └── Modules/            # UninstallEngine(双键扫描+批量+admin) / OptimizeEngine(含 shellWithAdmin)
│   │                           # SystemStatus(CPU/内存/网络/电池/进程) / PurgeEngine(+LargeFilesEngine)
│   │                           # SlimEngine(mo slim：fat 头解析/lipo 剥离/重签名/校验/Apple Silicon 门禁)
│   ├── ViewModels/             # CleanViewModel(含逐文件 excludedFindings) / ChatSessionStore(会话↔rollout)
│   ├── Theme/                  # AiriTheme(tokens) / Components(卡片/按钮/IconItemCard/ProgressRing/TickingNumber/WindowVibrancy)
│   └── Resources/              # pet/idle_loop.vrma + stickers/airi-*.png（均来自 airi, MIT）
```

## 4. 依赖（Package.swift）

| 包 | 用途 |
|---|---|
| `teunlao/swift-ai-sdk` 0.20.0 (Apache-2.0) | AI provider 层：9 厂商统一（SwiftAISDK + 各 *Provider 产品） |
| `gonzalezreal/swift-markdown-ui` 2.4.x (MIT) | 聊天 Markdown 渲染 |
| `kishikawakatsumi/KeychainAccess` | API key 存储（APIKeyStore） |
| `sindresorhus/LaunchAtLogin-Modern` 1.x | 开机自启（`LaunchAtLogin.isEnabled`，无 `.toggle`） |

**swift-ai-sdk 常用 API 速查**（本项目实际使用）：`streamText(model:tools:messages:stopWhen:settings:)` → `for try await part in stream.fullStream`（`.textDelta(id:text:providerMetadata:)`/`.toolCall`/`.finishStep(... .usage)`）；`ToolSet=[String:Tool]`，erased `tool(description:inputSchema:execute:)`，`FlexibleSchema(jsonSchema(JSONValue))`；工厂 `createOpenAICompatible(settings: OpenAICompatibleProviderSettings(baseURL:name:apiKey:))` 等，模型经 `provider.chatModel(modelId:)`。**易错**：`finishStep` payload 是 6 元组；`AsyncThrowingStream` 闭包参数需显式标注 Continuation 类型。

## 5. 核心架构与数据流

**聊天即宠物（单一引擎）**：ChatView → ChatSessionStore（会话↔BrainRollout）→ BrainAgent.submit → runLoop（SDKChatModel/ResponsesModel 流式 → BrainTools.dispatch 并行 → 回喂 → 循环至无调用）→ 每条 item 落 rollout JSONL。破坏性操作走 ApprovalCenter（原生 sheet），宠物经 PetBus→PetSceneBridge 实时表演、贴纸头像联动、回合完成必提示（onEvent 监听）。

**安全模型贯穿一切**（mole 思想）：SafetyGuard 是唯一裁决者（home-only、保护类别、realpath 解析、白名单永远赢、删除前二次校验）；ToolRegistry 双门控；Brain 沙箱三档（read-only/workspace-write/full）× 审批三档（untrusted/on-request/never）。

**MCP 双传输同源**：`MCPServer.handleMessage` 传输无关；stdio（CLI）+ HTTP（app 内开关，`MCPAppService`）。破坏性工具需 `"confirmed": true`（外部 agent 先 dry-run 征得用户同意的契约）。

## 6. 踩过的坑（务必先读，避免重蹈）

1. **无头模式死锁**：`--smoke/--brain-smoke/--mcp/--brain-exec` 都在 App.init 阻塞主线程。**任何 `MainActor.run`/`@MainActor Task` 都会永久挂起**。规则：Core 层回调直接调用；PetBus 内部 `Thread.isMainThread ? apply() : DispatchQueue.main.async`（fire-and-forget 安全）。
2. **Seatbelt（sandbox-exec）**：
   - subpath 匹配按解析后路径 → `/var`→`/private/var` 是 **firmlink**，`URL.resolvingSymlinksInPath()` 不解析，必须 C `realpath()`（见 BrainSandbox.realFileSystemPath）。
   - 显式 `(deny file-write*)` 会覆盖 allow —— Seatbelt 默认拒绝，**不要加全局 deny**。
   - zsh 的输出重定向会被拒（即使 subpath 已 allow）→ 沙箱内用 **`/bin/sh -c`**。
   - `sandbox-exec -f 新写文件` 偶发 ENOENT → 用 **`-p` 内联**传 profile。
3. **NSVisualEffectView 背景会吞鼠标**（聊天输入框无法聚焦的根因）→ 必须 `hitTest` 返回 nil（Components.WindowVibrancy.PassThroughVibrancy）。
4. **`host_statistics` 的 count 是输入参数**，须预置 `MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size`（否则 CPU 恒 0）。
5. **网络速率只统计 `en*`**（utun 与 en 双重计数）。
6. SPM 手写资源：`resources: [.copy(...)]` + `Bundle.module`；包名引用用 **URL 派生标识**（如 `package: "swift-markdown-ui"`，非 manifest name）。
7. python heredoc 批量改 Swift 时 `\\(` 会写进字面文件导致插值失效——改完 grep '\\\\(' 自查。
8. 用户界面要求会反转（磨砂曾被要求去掉又要求加回）——**以最新指令为准**，README 同步改。
9. **窗口重开**：`openWindow(id:)` 只在 SwiftUI 场景上下文有效（NSHostingView 手挂的宠物面板里拿到的是空 action）。解法：MenuBarExtra/RootView/ChatView 在 onAppear 把 openWindow 闭包注册进 `WindowRouter`，AppKit 侧（宠物菜单/菜单栏/Dock reopen）统一走 `WindowRouter.showMain/showChat`；主/聊天窗由 `WindowIdentifierTagger` 打稳定 identifier 供兜底查找。
10. **桌宠白闪**：透明 NSPanel 在 SceneKit 首帧渲染前会露出白色 backing store——面板 `alphaValue=0` 上屏，`SceneReadyCoordinator`（SCNSceneRendererDelegate.didRenderScene）首帧回调后淡入，PetPanelController.show 里 1.2s 定时器兜底。
11. **CodexSubscription 网络**：`auth.openai.com` 在 Cloudflare 后——应用层 HTTP 客户端直接 403 挑战页（实测），浏览器能过。因此登录主流程是 **PKCE 浏览器授权码流**（点击即开 `authorize`，`LoopbackCallbackListener` 收 127.0.0.1:1455 回调，CommonCrypto 算 S256 challenge）；设备码仅备选。URLSession 默认不读 HTTP(S)_PROXY 环境变量——专用 session 注入 env 代理 + 20s 超时 + 全程可取消。
12. **无边框 NSPanel 键盘焦点**：`canBecomeKey` 默认 false，TextField 拿不到键盘——必须子类化 NSPanel 覆写为 true，配合 `panel.makeKey()`（nonactivating 不抢前台）。
13. **SwiftUI 场景窗口几何**：直接 `NSWindow.setFrame` 会被 SwiftUI 重新断言回去，别和它抢；离屏修复只处理"frame 不与任何已注册屏幕相交"（拔显示器残留），后台 Space 的窗口（终端启动常态，occlusionState 无 visible 位但 overlaps）是正常现象——激活 app 会自动切 Space，别"修"。诊断用 `Moppet --win-debug`（stderr 打印窗口 frame/occlusion/space）。
14. **PetBus 气泡时长**：`say(_:state:hideAfter:)` 支持每条消息的显隐时长（0=流式保持）；直接改共享 `autoHideInterval` 有跨帧竞态（PetView 下一渲染帧才读）。
15. **`LaunchAtLogin.isEnabled` 是 1.5–1.8s 的 SMAppService XPC 往返**（本机实测，未签名二进制尤甚）——绝不能在 body/Binding get 里同步调。Settings 里已缓存进 `@State`（`.task` 内 `Task.detached` 读一次），开关写入同样后台执行。同理：路由切换不要 `withAnimation` 整列（实测 150–750ms）、不要 `.id(route)`（白白全量销毁重建）、十卡片长列表用 `LazyVStack`。测路由延迟用 `Moppet --route-perf`（stderr 两轮 commit/render 毫秒）。
16. **主线程文件 IO**：`BrainRollout.listSessions` 全量读每个会话 JSONL（会话多了后 ~70ms+），Dashboard 用 `Task.detached` 包了；`ChatSessionStore.refresh`（chat 开窗时 listSessions+逐个 titleForSession）仍在主线程——是已知可优化点，改时注意 @Observable 状态必须回主线程赋值。
17. **字典字面量重复键 = 用户侧崩溃**：Swift 运行时对字面量重复 key 在首次初始化时直接 trap（编译只是 warning）。L10n 的 zh 表曾因重复 "Clean" 键在用户点设置时崩溃（`dispatch_once` 初始化栈，报 `Dictionary literal contains duplicate keys`）。防线：`SmokeTest` 第一条断言调 `L10n.selfCheck()` 强制初始化 zh 表（64 项断言里有它），重复键会立刻让 `--smoke` 红而不是炸用户。往 zh 字典加词条后必跑 `--smoke`。
18. **主题跟随系统 + 动态 token 是最终形态（钉浅色方案已废弃）**：为修"深色下文字看不清"曾经历三代——① 控件自适应色画浅底上；② `Airi` 中性色是 `dynamicColor` 动态 token（neutral900 深色下=#F5F5F5）；③ 钉浅色（preferredColorScheme/panel.appearance/.colorScheme(.light)）——**③被用户否决**：毛玻璃变奶白、与系统脱节。最终：**不钉任何外观**，可读性由动态 token 保证——所有浮层（气泡/审批卡/快捷输入条）填充用 `Airi.cardBackground`（浅=白 0.6 玻璃卡、深=黑 0.3 纱——v15.27 用户报"一点都不透明"后浅色从实白改玻璃白，壁纸色调透过卡片）、文字用自适应 `Airi.neutral900`，两者在两种外观下都成套。规则：**永远别用固定 `Color.white` 当浮层底色、别钉外观**；新控件用 Airi 动态 token 天然跟随系统。固定色仅限蓝底白字这类两种模式都成立的双色组合。
19. **Provider/Model 切换架构**：`AIVendor.knownModels`（各家精选模型清单，default 在首位；ollama/custom 为空=自由文本）；`AISettings.switchVendor(to:)` 级联 baseURL+默认模型；`AISettingsCoordinator.apply/broadcast` 是唯一切换入口——持久化 + `QuickChat.shared.brain.refreshModel` + 通知 `.aiSettingsChanged`（ChatView 监听后刷新自己的 store.brain）。`BrainAgent.settings` 快照 + `refreshModel(settings:)` 让切换对下一轮对话即时生效（agent 不再在 init 时固化配置）。自定义模型 ID 不在清单里时作为菜单首项保留。切换入口：聊天窗控制条 + Settings（快捷输入条按用户要求已精简为纯输入）。
20. **点外即收的快捷浮条**：`QuickChatPanelController` 用 local（自家窗口，跳过宠物面板让 tap 手势切换）+ global（其他 app/桌面）leftMouseDown 监视器实现点击外部收起；监视器类型是 `Any?`（`NSEvent.add*Monitor` 返回非 AnyObject）。聊天窗是 hiddenTitleBar——关闭按钮在头部（`dismiss()`），双击宠物或双击气泡都能打开它。
21. **一次性状态要自动回落**：`.celebrating` 动画是 repeatForever 的，而完成播报（QuickChat/ChatView 的 onEvent）没有下游调 settle()——曾导致庆祝无限循环。现在 `PetBus.say(state: .celebrating)` 自带 3.2s 自动 settle（正好两圈旋转，`settleTask`，其他显式状态会取消它）；单击宠物在庆祝中 = "知道了"（只 settle，不弹输入条），非庆祝时单击才切换快捷输入条。`settle()` 语义：celebrating/scanning/cleaning → idle，talking/thinking/sleeping 不动。同理新增任何 repeatForever 表演状态时想清楚谁负责停。
21b. **移除 SCNAction 不回滚变换**：`removeAllActions()` 会留下动作跑了一半的姿态——庆祝自旋被打断后鼹鼠永远背对镜头（用户截图"没还原"）。`MolePuppet.applyState` 现在先重置基准姿态（root.position/eulerAngles、body.position/eulerAngles/scale、nose.scale，基准值存成属性）再挂新动作。**任何 SCNAction 驱动的状态机都要在状态切换时重置变换**。
22. **AI 工具的范围参数绝不能静默失效**：`scan_clean` 旧契约"omit for all"曾让模型漏传参数时全量扫描（用户"只扫浏览器"却全扫）。现在 `resolveItems` 模糊匹配（id/标题/条目名，大小写+双向子串），无匹配**报错并列出可用 ids**（绝不静默扩大），输出首行回报实际范围，描述+系统提示词都要求"用户指定范围必须传参"。冒烟有 6 条范围断言（总 64 项）。新增带范围语义的工具照此模式。
23. **系统控件用状态绑定，别用常量**：`NavigationSplitView(columnVisibility: .constant(.all))` 会让标题栏侧栏开关"没反应"（写入被常量吞掉）——用 `@State` + `$columnVisibility`。任何把系统控件接到常量绑定上的写法都一样。
24. **终端启动 = 后台启动，键盘没着落（最终解）**：裸 SPM 二进制（无 .app bundle）被系统拒绝激活——`isActive=false keyWindow=nil`：窗口渲染、点击穿透可用，但键盘事件永不投递（输入框有光标也打不了字），且切换上下文后的第一次点击被失败的激活消费掉（宠物快捷条"有时弹不出"）。修复：`NSApp.setActivationPolicy(.regular)` + 启动时 `NSApp.activate(ignoringOtherApps:)` + **本地 mouseDown 监视器在 `!NSApp.isActive` 时随时补激活**（实测 isActive 从 false→true，keyWindow=main）。之前只调 activate 不改 policy 无效——策略是前提。`--win-debug` 每 4s 周期输出 isActive/keyWindow/firstResponder。
25. **swift-ai-sdk 禁止 system 角色消息**：`streamText(messages:)` 里放 `.system(...)` 会抛 `AI_InvalidPromptError: System messages are not allowed…`——系统提示词必须走 `instructions: .text(system)` 参数（`Instructions` 枚举，ExpressibleByStringLiteral）。SDKChatModel 已改；新增 SDK 调用别把 system 塞进 messages。
26. **毛玻璃透明度旋钮**：`WindowVibrancy` 用 `alphaValue` 调"通透感"（NSVisualEffectView 无原生透明度参数；调低 alpha 让壁纸透出更多，浅色模式尤其明显——默认 1.0 偏奶白）。演变：1.0 → 0.8（嫌实）→ **0.7**（2026-10-26 再报"一点都不透明"）；同轮把浅色 `cardBackground` 从实白改成 0.6 玻璃白——真正发实的大面积是卡片不是 vibrancy，两层一起调才有效。`--probe-floater` 可实测（a=0.60/0.30 已验证）。
27. **审批 sheet 被 Esc 关闭 = 工具调用永久挂起**：`.sheet(item:)` 被系统关闭（Esc）时会以 nil 回调 binding 的 set——若只是丢弃 `ApprovalCenter.pending`，`await request(...)` 的 continuation 永不恢复，brain 卡在 isRunning（Send 锁死、quick 条 active 卡死、只能换会话）。约定：**dismiss 即 deny**（ChatView.approvalBinding 里对残留 request 调 `respond(false)`）。且 respond 必须**幂等**：宠物内联卡与聊天 sheet 同时呈现同一请求，快速双击/淡出动画中再点会二次 resume checked continuation → 进程 trap（ApprovalCenter.OnceContinuation 加锁防重，只有第一次生效）。
28. **send() 先清草稿再提交 = 静默丢字**：`BrainAgent.submit` 在 isRunning 时静默 no-op——UI 侧若先 `draft = ""` 再提交，运行中按 ⏎ 用户的字就没了（ChatView 与 QuickChat 都中过招）。约定：**先 guard（非空白 + 未运行）再清空**；被拦截时草稿留在框里，本回合结束后可重发。
29. **固定尺寸 NSPanel 里别用 `axis: .vertical` 多行 TextField**：换行内容长高超出 panel 固定高度即被裁剪（QuickChat 560×64 曾配 lineLimit(1...3)，第 2/3 行不可见）。快捷输入条一律单行，长文本横向滚动（Spotlight 同款）；要多行就把 panel 高度跟内容联动。
30. **nonactivating 浮窗上的 SwiftUI 手势/hover 依赖激活状态**：宠物面板从不成为 key window（nonactivating），SwiftUI 的 `.onTapGesture/.onHover` 挂在 NSViewRepresentable 外层时——app 在后台则 hover 跟踪不触发（手指光标时有时无）、切回前台的第一次点击被激活过程吃掉（"单击有时候无效"）；根部 `DragGesture(minimumDistance:4)` 还会吞掉带抖动的点击。**最终解：AppKit 交互层**（`PetInteractionNSView`，ZStack 盖在 SCNView 上）：`acceptsFirstMouse=true`（后台首击即生效）+ `NSTrackingArea(.activeAlways+.cursorUpdate)` 里 `NSCursor.pointingHand.set()`（任何状态手指恒定正确，永不 push/pop 失衡）+ mouseDown/mouseUp 自判点击（全局位移 <6pt 才算点击，≥6 为拖拽，拖拽自己 `setFrameOrigin` 且 `mouseDownCanMoveWindow=false` 防系统重复拖动）+ 单击延迟 `NSEvent.doubleClickInterval` 再触发（否则双击会先弹输入条）+ 右键 `NSMenu`（`ClosureMenuItem` 子类持闭包——NSMenuItem 不 retain target）。任何"宠物/浮窗点击不可靠"的问题先看这层，别再加回 SwiftUI 手势。配套：`QuickChatPanelController.show` 在 makeKey 前显式 `NSApp.activate`——key 面板的文本框若在后台 app 里连输入法服务器，会打 `IMKCFRunLoopWakeUpReliable` mach port 错误且中文组词可能丢；activate 对已前台时是 no-op（TSM AdjustCapsLockLED… 行是 TextField 拿到焦点的正常噪音，别当 bug 修）。
31. **菜单式 Picker 别配内嵌标签 + 固定宽度**：`Picker("Provider", …)` 的内嵌标签会占掉固定宽度的一半，菜单值被截成 "De…"、"On request (model…"（截图实证）。模式：`labelsHidden()` + `frame(maxWidth: 上限)` 让菜单拥抱内容（macOS 工具栏同款），完整语义放 `.help()` tooltip；枚举需要紧凑显示名时加 `shortName`（BrainApprovalPolicy 已加）。诊断深浅渲染用 `Moppet --probe-floater`（离屏渲染 cardBackground 色板打印三种外观下的像素值，验证动态 token 在 NSHostingView 里的真实解析）。
32. **宠物气泡的布局预算**：气泡+审批卡+鼹鼠共处 250×400 固定面板——气泡写死 `height:270` 的场景一旦遇上高气泡就会溢出裁剪。方案：场景 `.frame(maxWidth:230, maxHeight:270)` + `.layoutPriority(-1)`（气泡/审批卡优先拿竖向空间，鼹鼠临时缩小让位，气泡消失即恢复）；气泡宽度贴满面板（maxWidth 232，别再写 210 的窄柱）、lineLimit 12 截尾兜底（全文在聊天窗 rollout）。另：气泡是纯 Text，AI 的 Markdown 会以星号字面显示——`QuickChat.bubbleTail` 剥 `**` 和反引号（**单星号不剥**，`~/Caches/*` 这类 glob 是清理回答的合法内容）。CGWindowList 查宠物窗要按 `layer==3` 过滤：layer 1000、685×30、onscreen=false 的窗是 AppKit 内部辅助件（IME/菜单），不是双面板 bug。
33. **浮窗要跨全屏可见 + 输入条置顶**：`canJoinAllSpaces` 单独**不**穿越其他 app 的全屏 Space——必须再加 `.fullScreenAuxiliary`（宠物面板与快捷条都配）。快捷输入条 `level = .statusBar`（高于所有 app 的 floating 窗，低于菜单/弹层），弹出即最上层。宠物气泡用 **MarkdownUI** 渲染 AI 回答（`Markdown(message).markdownTheme(.basic).markdownTextStyle{FontSize(12); ForegroundColor(Airi.neutral900)}`，与聊天窗同引擎；bubbleTail 保留 MD 标记不剥离）；**气泡绝不回显用户问题**——`BrainAgent.submit` 只 say("Thinking…", hideAfter: 0)，用户原话进 transcript 不进气泡。气泡宽度**按内容自适应**：`.frame(maxWidth:)` 是贪婪布局（短消息也撑满 232），MarkdownUI 的理想宽度又不可靠——用逐字符估宽（CJK/emoji>0x2E80≈13pt、ASCII≈7.2pt，取最长行 +20 padding，clamp 80…232）显式定 `frame(width:)`，短消息单行紧凑、长消息到上限换行。
34. **列表计数≠总数**：会话列表 `listSessions(limit: 50)` 截断后拿 `sessions.count` 当总数显示——磁盘 60+ 会话时删 1 个仍是"50 sessions"，用户以为删除没生效。规则：枚举接口返回 `(list, total)`（listSessions 已改），底栏/Dashboard 显示 **total**，超出上限时附 "recent N"；零消息会话（"+"了没说话的空壳）在枚举层就过滤（列表与 total 都不含）；`ChatSessionStore.newSession` 不再立刻 `beginSession()`——文件由首次 submit 懒创建（BrainAgent.submit 里 `if writer == nil { beginSession() }` 本来就有），废弃的"+"不再留垃圾。
35. **OAuth redirect_uri 是精确匹配注册的（2026-10-24 实测修复"登录后无回调"）**：OpenAI 客户端 `app_EMoamEEZ73f0CkXaXp7hrann` 只认 codex CLI 注册的 `http://127.0.0.1:1455/auth/callback`——旧实现的 `localhost:1455/callback`（主机名和路径都对不上）被服务端整体拒绝，浏览器端渲染 "Your session has ended" 通用错误页（其 Log in 链接跳 chatgpt.com 登录，**永远不会有 code 回跳**→ App 无声永远 Waiting，用户以为"浏览器登录了但没回调"）。修复 = authorize 整组参数镜像 codex CLI（`/oauth/authorize` 端点 + 加长 scope + `codex_cli_simplified_flow`/`id_token_add_organizations`/`originator` 附加参数 + **删掉 audience 参数**）；换任何 redirect_uri 立刻 JSON `invalid_authorize_request`（真浏览器实测）。`LoopbackCallbackListener.start` 改为等待 NWListener 真实 `.ready`/`.failed`（端口被占立即报错进 failed 分支，不再无声挂起；加锁一次性 settle，防 stop 后 `.cancelled` 事件二次 resume continuation trap）。smoke 有 6 条登录契约断言（redirect 精确串/端点/无 audience/S256）。**改登录参数前先想清楚是注册过的精确串**。
36. **TaskGroup "drain" 在成功路径会等满超时任务（2026-10-24 实测修复"Login captured 后 App 还 Waiting"）**：PKCE 等待组 = `awaitCode()` + 300s sleep 两个子任务竞速。`listener.stop()` 只能唤醒**还挂着的** awaitCode continuation——成功路径下 awaitCode 已返回，剩下的子任务是那个 sleep，此时 `_ = await group.next()` 会**干等 sleep 跑满剩余时间**（实测：浏览器已显示 "✅ Login captured"，App 仍 "Waiting for authorization…" 整整 5 分钟才去换 token）。规则：拿到 first 之后先 `group.cancelAll()` 再 drain（Task.sleep 对取消立即响应）。任何"竞速 + drain"的 TaskGroup 都要检查成功路径的第二个孩子是什么。
37. **凭证存储已改 0600 文件，钥匙串 ACL 弹窗根治（2026-10-26）**：此前每次 `swift build` 后首次读 key 必弹"输入密码 + 始终允许"（未签名二进制签名全变、条目 ACL 不认），Deny 还会被下次 load 重试。根因是钥匙串 ACL 只信任写入时的二进制——代码层面无解。**APIKeyStore 已重写**：主存储 = `~/.moppet/ai-keys.json`（原子写 + chmod 0600，进程内镜像，槽位键与旧钥匙串完全一致 `api-key.<vendor>` / `api-key.profile:<id>`）；钥匙串降级为一次性迁移源——槽位未命中时回读钥匙串一次（这是该槽位最后一次弹窗），值落盘后立即删除钥匙串条目，此后永远零弹窗（含所有未来重建）。与 codex CLI `~/.codex/auth.json` 同一取舍：本地工具明文 0600 可接受；若将来正式签名/公证（债务 #8）可再切回钥匙串。`migrateLegacyKey` 语义保持（legacy 全局槽 → 当前厂商槽后即删）。smoke 有 6 条凭证断言（真实文件备份-往返-恢复法）。

38. **桌宠跨屏跟随（2026-10-25 修复"多屏时桌宠和主界面不在同一屏幕"）**：桌宠锚定屏幕 = 可见的主/聊天窗口所在屏（key 窗口优先；`window.screen` 为 nil（掉进死空间的还原框）时取重叠面积最大的屏）。落点 = 该屏 `visibleFrame` 右下角（margin 16，visibleFrame 已排除 Dock/菜单栏）。触发点：launch +1s/+3s（`PetPanelController.show()` 时主窗口多半还不存在，初始只能落 `NSScreen.main`，必须延迟补一次 `syncPetScreen()`——实测 macOS 会把主窗口放到副屏而桌宠留在主屏）、`showMain/showChat` 的 0.4s repair 块、以及 `NSWindow.didMove/didChangeScreenNotification`（过滤 moppet-main/chat 标识）。`relocateToScreen` 有 `panel.screen !== target` 守卫——用户在同一屏内拖的位置不被打扰。快捷输入条 `centerOnScreen` 改用 `PetPanelController.panelScreen`（跟随桌宠而非 `NSScreen.main`）。窗口 ID 常量要 `nonisolated static let`（PetPanelController/通知闭包等非 MainActor 上下文也要读）。
39. **工具输出哨兵必须全长匹配（2026-10-26 view_image）**：view_image 的图片经 dispatch 以字符串 `image:data:image/…` 返回，runLoop 按前缀识别转成 image 会话项。哨兵是**完整 `image:data:image/` 前缀**而非 `image:`——shell/read_file 的普通输出完全可能以 "image:" 开头（如 `file foo.png`），短哨领会把普通工具结果误判成图片。同类教训：跨层传结构化数据用显式字段或足够特异的哨兵，别用可能与合法内容碰撞的短前缀。
40. **等待用户交互的工具必须有"无人应答"出口（2026-10-26 request_user_input）**：模型侧工具 `request_user_input` 等用户回答，三个出口（作答/超时/取消）都要**幂等地 resume 同一个 continuation**——`UserInputCenter.Channel.finish` 盒子：首个 finish 生效，超时任务也走 finish(nil)，装卡前检查 isFinished 防"超时已赢、卡才上屏"的竞态残留。与 §6.27（dismiss 即 deny）、§6.36（竞速 drain）同类：**任何 await 用户/UI 的工具必须保证 continuation 恰好 resume 一次且每条路径都有人 resume**，否则 brain 永久卡 running。无头模式（--brain-exec/--brain-smoke）`UserInputCenter.uiAvailable=false` 直接回落"未回答"，绝不进入等待。
41. **"删 Intel 代码"类功能必须按宿主 CPU 硬门禁（2026-10-26 SlimEngine）**：fat 头解析在任何机器上都能"成功"找到可剥离的通用二进制——扫描结果为非空绝不等于"可以安全执行"。剥离 x86_64 只留 arm64 的产物在 Intel 主机上是**不可运行的废件**（本机实测 scan 真能列出 Godot 181MB"可瘦身"）。门禁用**运行时** sysctl（`hw.optional.arm64 == 1`）而非编译期 `#if arch(arm64)`（通用二进制两架构都会编译进同一判断分支的错觉）。scan 与 slim 双重拒绝，连 dryRun 也不给（DryRun 结果也会误导）。
42. **TCC 权限框"没弹出来"= 快速失败，不是线程/架构问题（2026-10-30 M1 卸载实测）**：macOS 的 TCC 弹窗会**阻塞**触发它的系统调用——App 管理权限未决时，第一次 `removeItem` 会挂住、弹窗、用户点允许后删除继续。所以"删除**立刻**返回 EPERM 且没有任何弹窗"只有两种成因：TCC 决策已被记录（用户点过"不允许"），或系统对该身份静默拒绝（本项目 `swift build` 出来的二进制是 ad-hoc 签名，每次重建 cdhash 都变，TCC 不认稳定身份）。M1 上遇到的正是后者：Intel 机器弹窗正常，Apple Silicon 直接失败——不是代码分支差异（卸载路径无任何 `#if arch`），而是签名/TCC 归属差异。修复 = 在**快速失败**后回落到管理员提权（`OptimizeEngine.shellWithAdmin` → 系统密码框，等价 Finder 删别人的 App）：因为待决弹窗会"阻塞"而不是"失败"，快速失败恰好证明没有弹窗在路上，所以这条兜底永远不会叠出第二个框。GUI 两条路径传 `fallback: true`；**无头（smoke / stdio MCP / --mcp）必须保持默认 false**——`shellWithAdmin` 内部 `MainActor.run`，而无头模式主线程被阻塞（§6.1），会死锁。

43. **`swift build | tail` / `| grep -c` 会把构建失败吞掉（2026-10-30 实测）**：管道后的退出码是 `tail`/`grep` 的，`swift build … | tail -30` 在编译**报错**时照样 exit 0、输出里也可能只剩前半截，于是"构建通过"的假象一直持续到运行二进制才发现它还是旧的（本轮 `--probe-render spacehogs` 报 unknown page 就是这么来的：源码改了、二进制是上一版）。规则：校验构建一律 `swift build … 2>&1 | grep -E "error:|warning:|Build complete"`，或看完 `Build complete!` 一行再动手；改完源码后跑任何 CLI 前先确认二进制 mtime。
44. **长页面探针必须能改窗口高度**：`--probe-render` 默认 1180×860，Space Hogs / Status 这类页面下半截直接被裁掉——"只看了上半屏"就等于没验证。加 `h=1500` 参数（`MoppetApp` 解析 `h=`，`PageRenderProbe.run(height:)`），长页面一律带高度渲染后再目检。配套：`SystemHogsView.debugSeed`（离屏窗口里 `.task` 不触发，不 seed 只能看到三行 "Checking…"）；seed 的假数据要保证**视觉可分辨**——快照日期若只差 1 小时，行内只打印日期会渲染成七行一模一样（按 6 小时步进）。
45. **禁用态按钮别用 `opacity` 淡化**：`AiriButton` 原先对 disabled 整体 `.opacity(0.5)`，于是 destructive 的禁用态 = 白字 + 极淡粉底，浅色模式下几乎看不见（Space Hogs 快照卡的「删除已选的 0 个」实测）。改法：disabled 时填充换 `neutral200@0.55`、文字换 `neutral400`（真正的"灰掉的控件"），**但 `busy` 保持原色**——`disabled: isDeleting, busy: isDeleting` 这种写法下，灰底 + spinner 读起来像"被关掉了"。
46. **离屏渲染里 `Toggle(.switch)` 的"开"是灰的（别去修）**：非 key 窗口 / 非激活 app 下，NSSwitch 一律用未激活外观——**开=灰轨道+旋钮靠右，关=灰轨道+旋钮靠左**，只有旋钮位置能区分。探针截图里"所有开关都是灰的"不是 bug，真机窗口 key 时开态才是主题蓝。所以：布局回归看旋钮位置，颜色回归只能真机看；别为了让探针好看去手写一个假开关（那样真机的键盘/辅助功能行为全丢）。

47. **圆形仪表盘的象限内容要按 √2 缩进，否则四角戳出圆环**：把 4 块内容摆进一个圆，2×2 网格的**角**离圆心是 `√2 × 内缩`，不是 `内缩`。板宽 W、环半径 R 时，内容块外角要落在环内需 `inset ≥ 0.5W − R/√2`（560 板 + R≈270 → inset ≥ 89，实取 96/92）。inset 变小会让文字块的左上角直接压在弧线上——渲染出来像"文字溢出圆环"。同理中心盘直径受"上下两块高度 + 竖向间距"约束，不是想放多大就多大。另：`Circle().trim` 的 0 在 3 点钟方向、角度**顺时针**增大；要让左右两个表盘"从 12 点向外张开"而不是四个都顺时针（那读起来像一个螺旋），左边两个要用 `trim(from: end−Δ, to: end)`——`GaugeArc` 的 `reversed` 参数就是干这个的。

48. **插入式展开的内容会先画出卡片外（"子框框先出来了"）**：`if expanded { panel }` 在 `withAnimation` 里插入时，**布局立刻按最终尺寸算**，动画只负责插值"渲染几何"——于是子面板第一帧就是全高，而卡片高度还在弹簧长大，面板直接画到卡片底边之外（再被下一行/页面背景盖住），看起来就是"框先冒出来"。修法：让卡片裁剪自己的行（`GroupedCard` 里 `.clipShape(RoundedRectangle(radiusCard))`，注意要放在 `.background` **之前**，背景和阴影不能被裁），裁剪框跟着卡片的高度动画走，展开就变成"卡片长到哪儿、面板露出到哪儿"。配套：别再给面板叠 `.scale(anchor: .top)` 过渡——它和裁剪互相打架，反而更像"滑出来"。同类问题：任何"点开就长高"的容器（折叠分区、内联详情、展开的行）都要保证父容器有裁剪，否则插入内容都会先溢出。

49. **深色底上"没填满的那一段"必须自己会亮**：四象限环形仪表盘第一版用 `neutral200@0.6` 画轨道，深色页面上轨道和背景几乎同色——于是每个象限只剩一小截彩色，用户完全看不出"这一格还剩多少"（"看不出 1/4 圆"）。改成**轨道 = 该象限主色的 18% 透明**（`tint.opacity(0.18)`）后，每格都是一条"暗色整段 + 亮色进度"，边界和余量同时成立，浅色模式下也是淡彩色而不是灰线。规则：进度类控件在深色界面上不要用中性灰当轨道，用主色的低透明度——同一色相的明度差比"灰 vs 彩"更容易读。

50. **圆头线帽会吃掉弧的缺口**：`lineCap: .round` 让每段弧在端点外多画 `lineWidth/2`，半径 188 时 6pt 帽 ≈ 1.77°，两端共 3.5°。缺口只留 6° 时实际只剩 2.5°；更糟的是上下两处**相邻两段都接近 100%** 时，两个亮帽几乎顶在一起（用户看到的"箭头距离 1px"）。规则：缺口角度要按 `缺口 − 2×(lineWidth/2 / R)` 换算成可见间隙，想要 ~18pt 的亮间隙，缺口至少 9°。另外：进度弧的"暗色轨道"必须比亮色端早出现，否则缺口在视觉上更窄。

## 7. 约定

- 文案：新 UI 字符串用 `Text(L("English"))` 并往 `Core/L10n.swift` 的 zh 字典补条目；Route/PageHeader/AiriButton 同理。
- 卡片一律 `SettingsCard`；按钮 `AiriButton`（按压缩放 0.95）；进度 `ProgressRing`/`TickingNumber`。
- 工具新增：在 `ToolRegistry.buildTools()` 加 spec+handler（读=readOnly，破坏=destructive）；Brain 自动获得；MCP 自动暴露。
- 重型测量走 `ScanEngine.parallelSize`（缓存自动生效）；新缓存条目注意 mtime 失效语义。
- 测试：新引擎行为加进 `SmokeTest`/`BrainSmokeTest`（stderr 输出，`✓/✗`，非 0 退出码）。
- 许可：mole 代码勿抄；airi 资产可用（MIT，注明）；Codex 是能力重实现（Apache-2.0 思想，非逐行）。

## 8. 已知债务与 Roadmap（按价值排序）

1. **AI 端到端未实测**：本环境无 API key。GLM/OpenAI/Codex 订阅路径已按真实 API 签名编写，但首次真机验证时重点看：SDKChatModel 工具循环、CodexSubscription 设备码 UI、ResponsesModel SSE（常量：client `app_EMoamEEZ73f0CkXaXp7hrann`、backend `chatgpt.com/backend-api/codex`）。例外：PKCE authorize 一段已于 2026-10-24 真浏览器实测（旧参数=错误页无回调；镜像 codex CLI 参数=登录表单正常渲染），token exchange 待用户真实登录后确认。
2. i18n 覆盖 ~70 条主文案；深层动态字符串（clean 分区名/工具描述/宠物台词）未本地化。
3. ~~mo slim~~ 已实现（v15.27 SlimEngine+SlimView+scan_slim/slim_apps 工具；Apple Silicon 硬门禁）。
4. Brain 与 codex 的差距（v15.26 审计后）：**agent 能力面已对齐**（shell/unified_exec/view_image/web_search(Responses hosted)/request_user_input/MCP tools+resources/apply_patch/plan/compact/sessions/斜杠命令/图片输入/network_access/writable_roots）。明确不做（平台级子系统，非"桌宠大脑"范畴）：multi-agent 协作、cloud tasks、语音/realtime、plugins/apps/hooks、code-mode、granular 审批细则、tool_search 延迟工具发现（我们工具数不需要 BM25）。read_file 在新上游已被并入 exec——保留作为超集，无害。
5. 宠物 VRM 皮肤管线：SceneKit 不支持 VRM；`idle_loop.vrma` 已备。可选路径：接 `threerocks/vrm-swift` 或恢复 WKWebView+three-vrm 方案（注意 CDN 离线必须有程序化回退，且 WKWebView 需 hitTest 穿透——教训 §6.3）。
6. ~~Plan 不还原~~ 已修（v15.27：plan 更新即写 items+rollout，resume 重放最后一个 plan；excludedFindings 属 Clean 流程与 Brain 会话无关，不适用）。
7. ~~缓存无 LRU 上限~~ 已修（v15.27：SizeCache persist 时按 cachedAt 淘汰至 500 条）。
8. Sparkle 自动更新、正式 App Bundle/签名/公证、沙箱 entitlements 均未做（当前 SPM 裸跑，`~/Library` 全盘可读依赖 Full Disk Access 提示未实现）。注：签名/公证落地后可考虑把凭证从 0600 文件迁回钥匙串（届时 ACL 不再弹窗），见 §6.37。
9. ~~--brain-exec --yes 自动审批~~ 已修（v15.27：旧 MainActor 轮询 Task 在无头模式永不执行、破坏性工具直接死锁——改为 `ApprovalCenter.headlessAutoApprove` 标志，在工具路径内、任何 actor hop 之前判定；brain-smoke 有 untrusted shell 无头放行回归断言）。stderr 无 `[trace]` 之外的日志框架（仍在）。

## 9. 验证清单（改动后必跑）

```bash
swift build 2>&1 | grep -cE "error:|warning:"    # 期望 0
.build/debug/Moppet --smoke | tail -1            # SMOKE PASS（64 断言，第 1 条是 L10n 重复键金丝雀，第 2-7 条是扫描范围防线，末 19 条是登录契约+模型目录+可编辑清单）
.build/debug/Moppet --brain-smoke | grep BRAIN   # BRAIN SMOKE PASS
# MCP 回归（stdio）
printf '%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | .build/debug/Moppet --mcp | tail -1
# GUI 冒烟
.build/debug/Moppet >/dev/null 2>&1 & sleep 4; kill -0 $! && kill $!
```

## 10. 本轮开发史（了解决策脉络）

MVP(仅 Clean) → 桌宠+AI+MCP → 第三方库化(swift-ai-sdk/MarkdownUI/Keychain/LaunchAtLogin) → **Codex agent 全量移植(Brain)** → 修复轮×3（Brain 并入宠物对话、去磨砂、宠物改 SceneKit 保可见；后按新指令恢复毛玻璃+卡片区+动效+OutlineGroup 树）→ 性能（并行+缓存）+MCP 开关 → 数据 bug 修复+返回按钮+Codex 订阅+i18n+贴纸接入 → 交互修复轮（双击宠物开聊天；首帧淡入去白闪；聊天控制条移到输入框上方；MenuBarExtra+WindowRouter 主窗口重建；登录超时/可取消/代理 env）→ **快捷聊天轮**（GPT 登录 device code 403 → 实测定位 Cloudflare 拦应用层客户端 → PKCE 浏览器流为主+设备码备选；宠物单击=Raycast 式快捷输入框+流式气泡回答+内联审批，菜单移到右键；PetPanel.canBecomeKey；离屏窗口修复+--win-debug）→ **卡顿修复轮**（--route-perf 实测 → LaunchAtLogin.isEnabled 1.5–1.8s XPC 在 petCard body 同步调 → 缓存+异步化；去整列动画与 .id(route)；DeferredView 一帧延迟构建；Settings LazyVStack；Dashboard 会话枚举出主线程；settings 3.5–7.9s→0.52s）→ **输入可见性+切换轮**（深色外观白字隐身 → 主/聊天窗 LightWindowAppearance 根除 + Settings 固定前景；Provider/Model 三处切换（聊天窗控制条/快捷面板底部/Settings）经 AISettingsCoordinator 自动级联，BrainAgent.refreshModel 即时生效）→ **UI 逻辑审查修复轮**（§6.27–29：审批 sheet Esc 死锁→dismiss 即 deny + respond 幂等防二次 resume trap；两处 send() 运行中回车丢字→先 guard 再清草稿；QuickChat 多行裁剪→单行；Uninstall 搜索框/Purge 根目录框补 FocusState 焦点接线，Purge 回车即 Add + 无效路径红框报错；reviewCount/review 头部计数改为尊重逐文件排除（确认对话框不再虚报）；Uninstall select() 异步竞态守卫 + 详情头部优先实测尺寸；ChatView 收到 aiSettingsChanged 同步刷新 header 副标题；§6.30：宠物单击不可靠/手指光标时有时无 → 根因是 SwiftUI 手势+hover 在 nonactivating 面板上依赖激活状态 → 重写为 AppKit 交互层 PetInteractionNSView（acceptsFirstMouse + .activeAlways 光标跟踪 + 自判点击/拖拽/右键，单击延迟双击间隔））；随后用户发来聊天窗底部截图（深色系统，Provider 截成 "De…"）→ **聊天控制条布局轮**（§6.31：四个菜单 Picker 去内嵌标签 labelsHidden + 拥抱内容宽度 + tooltip 全套（含中文 L10n）；Approval 用新 shortName（Ask always/On request/Never ask）；composer 重排——Send 移到最右、重置按钮左移并加 tooltip、控制条与输入区之间加分隔线成两条工具栏；新增 Moppet --probe-floater 离屏渲染诊断，实测动态 token 三种外观解析全对）。每轮回归全绿，README 与代码同步。→ **历史审计轮**（2026-10-24：History 页每条记录可点击展开，逐条显示具体删除了什么——路径（~ 缩写+悬停全路径）/大小/废纸篓·永久删除徽章/成败与失败原因，头部加失败计数徽章；数据侧补全审计口径：单应用卸载 removed/failed 改存完整路径并把失败项写入历史，批量卸载把相关文件也记入，Analyze 被安全层拦截的项改记为 failed（原先虚报 success），Purge 失败项同样入历史；`UninstallResult.removedFiles`/`failed` 语义变为完整路径（UI 文案处用 count 的地方已核对）；L10n 新增 8 词条并扩 selfCheck 防重复键；smoke 45 项含失败项历史 JSON 往返断言）→ **会话批量删除轮**（2026-10-25：聊天窗侧栏 header 加 checklist 多选开关 → 选择模式下行首变勾选圈、点击行=切换选中（不再 resume）、逐行 trash 隐藏；选中后操作栏显示 N/M 计数 + 全选/取消全选 + 红色 Delete 入口，批量确认 sheet 一次性删除所选 rollout；`ChatSessionStore.deleteAll(_:)` 为批量入口（含当前会话则取消运行中 Brain 并开新会话），单删 `delete(_:)` 重构为同路径；L10n 新增 Select sessions/Delete chats?/Delete 三键并扩 selfCheck）。
→ **订阅登录回调修复轮**（2026-10-24：用户实测 ChatGPT 订阅浏览器登录后无回调、App 永远 Waiting → 真浏览器对比探测定位：OpenAI 对 redirect_uri 精确匹配注册，旧 `localhost:1455/callback` 被整体拒绝渲染 "Your session has ended" 错误页（其 Log in 跳 chatgpt.com，永不回跳）；修复 = authorize 参数整组镜像 codex CLI（/oauth/authorize + `127.0.0.1:1455/auth/callback` + 加长 scope + 3 附加参数 + 去 audience）+ `LoopbackCallbackListener.start` 等 NWListener 真实 ready（端口被占立刻报错）+ buildAuthorizeURL 提为纯函数、smoke 加 6 条登录契约断言（51 项）；详见坑点 §35）→ **回调后 5 分钟空等修复轮**（2026-10-24：用户实测浏览器已显示 Login captured、App 仍 Waiting——成功路径下 TaskGroup drain 等满 300s sleep 才换 token；修复 = 拿到 first 后先 `group.cancelAll()` 再 drain（坑点 §36）；另修 Settings 卡片过时文案 device code→browser window，并记录钥匙串 ACL 弹窗为未签名二进制常态（坑点 §37））→ **桌宠落点轮**（2026-10-25：用户反馈"位置太高" → PetPanel.buildPanel 初始落点从右上角（maxY-430，实测窗口 y 500..900 贴顶）改为右缘垂直居中（midY-height/2，实测 y 265..665 正中屏幕，x 与原 290 边距不变；窗口尺寸提取为 size 常量；拖动位置本就不持久化，仅改启动默认落点）→ **窗口重复 bug 修复轮**（2026-10-25：用户反馈每次点「问问大脑」都新开一个聊天窗 → 根因：main/chat 两个场景原为 `WindowGroup`（多窗口语义），本版 macOS 上 `openWindow(id:)` 每次都新建窗口，而 WindowRouter 注释一直假设它会聚焦已有窗口 → 修复 = 两个场景改为 `Window`（单例场景，macOS 13+），`openWindow(id:)` 变为复用/激活已有窗口、关掉后仍可重建（WindowRouter 依赖的恢复路径不变），同时根除「打开主窗口」菜单的重复窗口问题）→ **AI key 跨厂商污染修复轮**（2026-10-25：用户报 AI 全线报错"之前都是正确的"——OpenAI "no credits remaining" + DeepSeek "api key ****0M4w is invalid" → 根因：Keychain 只有**一个全局 key 槽位** `cc.cleaner.ai/api-key`，`switchVendor` 换厂商/baseURL/model 但 key 不跟换，且 Codex 订阅登录的 OAuth access token 也写进这同一个槽位（`CodexSubscription.storeToken`）——登录 Codex 后 token 就被当作 API key 发给其他厂商，切厂商后旧 key 发给新厂商，全线 Authentication Fails → 修复 = `APIKeyStore` 改为**每厂商一个槽位**（`api-key.<vendor>`），`load()` 读当前厂商槽、`switchVendor` 拉取目标厂商已存 key、`save()` 写当前厂商槽；旧全局 key 一次性迁移进迁移时刻的活跃厂商槽并删除旧条目（不删会让每个新厂商继承旧值、复发污染）；Codex token 读写指向 `.codex` 槽位（`BrainAgent.defaultModel` 回退读 + `storeToken` 写）；Settings 说明文案同步。注：用户两条报错各含账户侧因素——OpenAI key 有效但无额度（需充值），0M4w key 在 DeepSeek 侧本就失效（需换 key）；App 侧修复后各厂商只用自己的 key，Settings 里切换厂商即显示该厂商的 key）→ **侧栏换行修复轮**（2026-10-25：用户截图侧栏菜单标题断词换行（Dashbo/ard、Uninstal/l…）→ 根因：NavigationSplitView(.balanced) 未设列宽下限，窗口收窄时侧栏被压到容不下 13pt 标题 → 修复 = 侧栏行标题/`mo ×`副标题/footer 文案全部 `.lineLimit(1)`（宁截断不断词），并给侧栏列加 `.navigationSplitViewColumnWidth(min:208, ideal:224, max:288)`）。→ **多屏跟随+右下角落位轮**（2026-10-25：用户报多屏时桌宠与主界面不同屏 + 要求桌宠放右下角 → 桌宠锚定主/聊天窗口所在屏（launch 延迟补同步 + didMove/didChangeScreen 跟随），落点改右下角（取代 v15.20 的右缘垂直居中），快捷条跟随桌宠所在屏；CGWindowList 实测主窗口落副屏时桌宠自动跟到该屏右下角 x:3190 y:836 预期帧；坑点 §38）→ **订阅模型目录 API 化轮**（2026-10-25：用户报 ChatGPT 订阅模型清单不对 → 不再写死：`CodexSubscription.refreshModels` 用存储 token `GET chatgpt.com/backend-api/codex/models`（端点实测存在，未认证 401）拉账号真实模型，解析器容忍 items/models/data 包装 + slug/id/model 键 + 字符串数组（响应 shape 未有公开契约）；目录持久化 UserDefaults `codex.model-catalog`，`AIVendor.knownModels` 的 .codex 槽优先用目录（bundledModels 仅离线兜底）；触发 = 登录成功后 force + `refreshModel` 节流 10min；选中模型被后端下架时经 AISettingsCoordinator 自动纠正，目录变化也广播让 Picker 刷新；新增 `--probe-models` 诊断（dump 状态+响应体）；smoke +5 目录解析断言（56）。事件记录：codex token 在 per-vendor 迁移中被随后的 DeepSeek 手动保存覆盖（deepseek 槽 sk-d5d… 是用户真 key，未污染），需重新登录一次，登录后目录自动拉取）→ **全厂商模型目录轮**（2026-10-25：用户要求 ① 除 custom 外各 provider 都从 API 拉模型/可配置 ② 用户可增删模型纠正 → 新增 `AIModelCatalog`（AIAgent.swift）：每厂商可编辑目录持久化 UserDefaults `ai.model-catalogs`（codex 走自己的 codex.model-catalog），种子 = bundledModels；`refreshFromAPI` 按 vendor 打各家 /models（openai/deepseek/groq/mistral=Bearer、anthropic=x-api-key+version、google=x-goog-api-key、glm=baseURL+/models、ollama=baseURL 去 /v1 +/api/tags、custom 无=用户手维），容错解析 data/models/items × id/slug/name/model + 剥 models/ 前缀 + 过滤 embedding/tts/dall-e 等非对话模型；端点存在性已实测（全部 401/403 非 404）。Settings AI 卡新增 `ModelCatalogEditor`（逐行删除 + 添加框 + 从 API 刷新 + 结果行；删除当前选中模型时自动切到清单第一个）；ChatView Picker/`switchVendor` 全部改走 `AIModelCatalog.models(for:)`；目录变更发 `aiModelCatalogChanged` 通知。smoke +8（64，.custom 厂商备份恢复法防污染真实配置））
→ **Codex 全量功能对齐轮（2026-10-26，v15.26）**：用户要求"检查 brain 是否完整移植 codex、支持全部功能、chat 界面实现 UI、不要 TUI"。先用 Explore agent 对照 /tmp/codex 上游（已演进到动态工具注册/环境/插件/cloud/voice）盘点差距：agent 能力面缺 view_image、hosted web_search、unified_exec(exec_command+write_stdin)、MCP resources、request_user_input、workspace-write network_access/writable_roots、斜杠命令、用户图片输入、真实 /compact。全部补齐：① `view_image` 工具（魔数嗅探 PNG/JPEG/GIF/WebP ≤10MB → data URL → 新 `imageItem` 会话项；Responses 编 `input_image`、SDK 编 image part；聊天窗图片气泡点击开原图）；② 用户附件（📎/拖拽/⌘V，≤4 张）走同一 imageItem 管线；③ `exec_command`/`write_stdin`（新 BrainExecSession：可恢复会话、yield 语义、UTF-8 边界缓冲、5min 寿命、/ps /stop）；④ hosted web_search（ResponsesModel 追加 `{"type":"web_search"}`，仅 codex 订阅厂商显示开关——与上游 provider 门控一致）；⑤ MCP resources 三工具（resources/list、templates/list、read，客户端补 JSON-RPC 方法）；⑥ `request_user_input`（新 UserInputCenter：聊天 sheet 选项+Other、宠物面板内联紧凑卡、5min 超时幂等 finish、无头明确"未回答"）；⑦ 沙箱 network_access 开关 + writable_roots（Seatbelt profile 动态 allow network*；TurnContext 新字段向后兼容解码）；⑧ 斜杠命令（新 BrainSlash 共享 runner + ChatView `/` 命令面板 + QuickChat 拦截输出进气泡）：/help /status /mcp /new /compact /init /diff /pwd /cd /ps /stop /export /copy；⑨ /compact 真实模型摘要 + rollout 新 `compacted` 记录（resume 还原）；⑩ 系统提示词纳入新工具规则。回归：build 0/0、smoke 64 PASS、brain-smoke 20→49 PASS（新增 exec stdin 往返、view_image dataURL、request_user_input 无头回落、图片/compacted 记录 round-trip、legacy turn_context 解码、profile 联网/可写根、斜杠命令 7 断言）、stdio MCP 19 工具、GUI 存活。明确不做并记入 §8.4：multi-agent、cloud tasks、语音、plugins/hooks、code-mode、granular 审批、tool_search。坑点 §39/§40 新增。
→ **代码审核 + mo slim + ZCode 式 Provider 轮（2026-10-26，v15.27）**：①审核修复四个真 bug——`--brain-exec --yes` 死锁（MainActor 轮询 Task 无头永不执行 + ApprovalCenter.request @MainActor 永久挂起 → `headlessAutoApprove` 标志在工具路径内判定，brain-smoke 加 untrusted shell 无头放行回归）；plan 更新从不进 transcript/rollout（planCard 是死代码、resume 即丢 → emit 落盘 items+writer，resume 重放末位 plan，顺带接通 networkAccess/writableRoots 恢复）；SizeCache 无上限增长（persist 按 cachedAt 淘汰至 500）；聊天窗拖拽图片 fileURL provider 不识别（public.file-url 不 conform public.image → 按 URL 扩展名分支处理）。②mo slim 全量实现：`SlimEngine`（fat 头**直读解析**扫描零 lipo 子进程——大端 magic 0xcafebabe/nfat_arch/20B fat_arch，cputype 0x01000007=x86_64、0x0100000C=arm64；slim=cp -pR 副本→lipo -remove 逐二进制→原 Developer ID 身份可用则原身份重签否则 ad-hoc→codesign --verify --deep --strict 通过才 trashItem 原件+换位；App Store(_MASReceipt)/com.apple.*/运行中/不可写跳过；历史入 HistoryStore"Slim" 分区）+ `SlimView` 页面（Route.slim）+ `scan_slim`/`slim_apps` 工具（范围参数照 §6.22：未知路径报错列可用清单，MCP 21 工具）+ **Intel 主机硬门禁**（hw.optional.arm64 运行时 sysctl，scan/slim 双拒，坑点 §41——本机 scan 真能列出 181MB"可瘦身"产物，剥离即废件）。③ZCode 式多自定义 Provider：`AIProviders.swift`——`~/.moppet/ai-providers.json` 手编注册表，`AIProviderProfile{id,name,baseURL,models}`，每家独立 keychain 槽 `api-key.profile:<id>`（APIKeyStore 加 raw-key API；AISettings.save 在 profile 激活时**只写 profile 槽**，绝不把 profile key 写进内置厂商槽——v15.x 污染事故防线）；`AISettings.activeProfileID`（可选字段，旧 payload 解码为 nil）+ `selectProfile`；`AIModelFactory` profile 分支走 OpenAICompatible；`AIProviderOption`（builtin|profile）统一 Picker 数据源（聊天窗+Settings）；Settings 新增 Custom Providers 卡（增删改 sheet：name/baseURL/key/模型清单 + Refresh from {baseURL}/models + Test connection 走真实传输）；profile key 删除时联动回落内置厂商。smoke 64→76（clang 现场构建 arm64+x86_64 通用二进制验 fat 解析/isProtected/工具注册/注册表备份-往返-恢复/legacy settings 解码）、brain-smoke 49→51；stdio MCP 21 工具、scan_slim 实测列出 Godot/Quark/CC Switch 后被 Intel 门禁正确拒绝。随后用户发来 ZCode 自定义 Provider 截图对齐：编辑表单缺 **API 格式选择器**——补 `AIProviderFormat`（openai/anthropic/google，三家 SDK 传输都收自定义 baseURL）：profile 新增 `format` 可选字段（旧 json 解码 nil→openai），`AIModelFactory` 按 `effectiveFormat` 分流 createOpenAICompatible / createAnthropic(baseURL) / createGoogle(baseURL)，`AIModelCatalog.listingSpec` 按格式给出模型列表端点与鉴权头（Bearer / x-api-key+version / x-goog-api-key，base 已含 /v1、/v1beta 不重复拼）；ProfileEditorSheet 重做成截图同构：API 格式 menu、API Key 眼睛显隐、模型列表 `+ 添加模型` 逐行 + 空态虚线框；smoke +3（legacy format 解码 / anthropic round-trip / 工厂分流，79 项）。用户再发 API 格式下拉截图对齐选项集：ZCode 是 **Chat Completions (/chat/completions) · Anthropic Messages (/v1/messages) · Responses (/responses)** 三项、无 Gemini——枚举改为 `.chatCompletions/.anthropic/.responses`（rawValue chat-completions/anthropic/responses，displayName 逐字对齐截图），Responses 走 SDK 新引入的 `OpenResponsesProvider`（Package.swift 加 product；`createOpenResponses(url:name:apiKey:).languageModel`），模型列表端点 Chat Completions 与 Responses 同为 `{base}/models` Bearer；smoke +1（responses round-trip，80 项）。再按 B.AI 截图重构自定义 Provider 卡：**每个 provider 一张独立 SettingsCard**（名称 15pt 卡头 + 当前使用✓ + `…` Menu 重命名/删除；Base URL/API 格式/API Key 眼睛显隐/模型列表逐行全部内联），废弃编辑 sheet（`ProfileEditorSheet`→`ProfileCard`）；**添加卡补回 Provider Name 必填字段**（上轮重写时弄丢——用户点名），新增走 draft 卡 + 唯一默认名（New Provider/N…2，`nameExists` 防默认重名）；**显示名称强制唯一**（`AIProviderRegistry.nameExists` 大小写+首尾空格不敏感、可排除自身 id，重命名同样拦截；重名/空名内联红字且 Save 禁用）；rename 保持稳定 id（keychain 槽位与选中态不丢）；active profile 保存后经 syncActiveProfile 重新选择并广播。smoke +4（重名检测/大小写空格/排除自身/rename 保 id，84 项）。用户再发侧栏截图：行内 `mo clean/mo uninstall…` 等宽小字副标题没必要的——移除（sidebarRow 改单行标题，删除死代码 Route.tag）。用户再报内置厂商的模型清单太丑（裸文本+⊖ 一列）——`ModelCatalogEditor` 重排成分组容器（圆角 neutral50 底+描边、等宽 12pt 行、细分隔线、trash 删除、行内"plus + model-id + ↑"添加行、空态提示、长列表 ScrollView maxHeight 220 + fixedSize 空表塌缩），与自定义 Provider 卡的模型列表同一视觉语言；表体过大编译超时拆出 catalogRow/catalogAddRow 子视图。随后用户发设置页截图报"咋一点都不透明"——诊断：浅色 `cardBackground` 实白 #FFFFFF 铺满设置页（vibrancy 只从卡缝透出）+ 侧栏 ultraThinMaterial 叠 vibrancy 双层发奶白；修复 = 浅色卡改玻璃白 0.6（与深色 0.3 纱同语义，`--probe-floater` 实测 a=0.60/0.30）+ vibrancy 0.8→0.7（§6.18/§6.26 更新）。用户再报钥匙串 ACL 弹窗烦（每次重建首读必弹）——APIKeyStore 重写为 0600 凭证文件主存储（`~/.moppet/ai-keys.json`，槽位键不变、进程内镜像、原子写+chmod；钥匙串=一次性迁移源：未命中槽回读一次→落盘→删条目，之后零弹窗；调用点标签 keychainKey:→slot: 13 处；设置卡/README 文案同步），smoke +6（凭证槽往返/隔离/0600/删除清盘，90 项）。用户再要启动项管理（防后台运行/开机自启）——新模块：`LaunchItemsEngine`（扫 ~/Library/LaunchAgents + /Library/LaunchAgents + /Library/LaunchDaemons，PropertyListSerialization 解析 XML plist（JSON 不收——smoke 夹具教训），`com.apple.*` 隐藏计数不列出（禁 boot daemon 可楔死系统）；禁用 = `plutil -replace Disabled -bool true` + `launchctl bootout gui/$UID|system` 立即停跑，启用 = false 清标志；全局项经 OptimizeEngine.shellWithAdmin（AppleScript 管理员授权），改动写 HistoryStore"Startup" 分区；`LaunchItemsView` 页面（Route.startup，power 图标，scope/RunAtLoad/KeepAlive/loaded chips，逐项 Disable/Enable）；工具 scan_launch_items + set_launch_item_enabled（label/路径严格匹配无命中报错列全表，destructive 双门控，MCP 23 工具）；smoke +9（XML plist 解析含 KeepAlive 字典、Disabled、JSON 拒收、apple 过滤、label/路径精确匹配/无模糊、工具注册，99 项）。

→ **项目重命名 Cleaner→Moppet 轮（2026-10-25，v15.30）**：用户定名 Moppet（MOP+PET，拖把×宠物；详见命名分析对话）。全量重命名：Package name/target/path（`Sources/Cleaner`→`Sources/Moppet`，产物二进制 `.build/debug/Moppet`）、`CleanerApp`→`MoppetApp`（文件同名）、侧栏品牌头/主窗标题/关于文案、MCP serverInfo `cleaner`→`moppet` 与 clientInfo `cleaner-brain`→`moppet-brain`、UA `moppet/1.0`、`originator: moppet`、窗口标识 `moppet-main/-chat`、OAuth 队列 label、临时文件前缀（截图/slim）、白名单 `~/.config/moppet/whitelist`、数据根 `~/.moppet/`（keys/providers/brain）。**新 `Core/LegacyMigration.swift`**（MoppetApp.init 首行、全模式生效）：一次性把 `~/.cleaner`→`~/.moppet`、`~/.config/cleaner`→`~/.config/moppet`、`Application Support/Cleaner`→`…/Moppet`（整体 move 保 0600，双端都在则只补缺的子项），UserDefaults 按可执行名分域故从旧域 `Cleaner` 拷全部键到 `Moppet`（以 ai-settings 存在与否防覆盖新配置）。**故意保留**：keychain 服务名 `cc.cleaner.ai`（仅作一次性迁移源标识，改名会孤儿化未迁移条目）、外层文件夹 `/Users/sean/cleaner/Cleaner`（工作区组织，避免打断并行会话/路径记忆；无并行会话时可 `mv` 后全局替换）。验证：rm -rf .build 全新构建 0/0、smoke 99 PASS、brain-smoke 51 PASS、stdio MCP 23 工具、GUI 后台启动实测迁移落盘（~/.moppet 三个数据源全搬空、Moppet.plist 155 键、历史 json 就位）。注意：LaunchAtLogin 以二进制路径注册，路径变了需在设置里重开一次。

→ **i18n 补全 + 首页眉标移除轮（2026-10-25，v15.31）**：用户截图报"国际化不完整"（首页卡片中英混排：`Start here`/`AI agent` 眉标 + `Codex-style agent…`/`node_modules & friends…` 英文副标题）并要求去掉红箭头标的 `mo uninstall`/`mo purge` 副标题。修法：①首页 4 张 IconItemCard 的 metadata 眉标全部移除（mo × 标签与 Start here/AI agent 一并去掉，卡片只剩 标题+副标题；IconItemCard 的 metadata 参数保留但无调用方）；②全 App 英文清扫——50+ 处未包 `L()` 的 Text/Label/TextField/AiriButton/ToggleRow 副标题（多数 key 早就在 zh 表里但从没包裹过），插值串转 `String(format: L(...))`（含磁盘行/确认对话框/统计行/树节点明细/summaryFooter 等）；③zh 表 120→174 词条：新增 Clean 四阶段标题（复查/清理中）、trashNotice 两条、启动项/瘦身/设置全部说明文、保护类目 12 个（钥匙串/登录项…）、聊天 Plan/writing/Other、`%@ free`/`listening on %@`/`stopped` 等；修正 3 个旧值（`chat sessions`→"个聊天会话" 量词、`Move %lld to Trash` 原译文丢数量、`failed`→"失败" 另增 `%lld failed` 计数键）。**坑：C 格式串里 `%@` 与 `%1$lld` 混用是未定义行为**——凡格式串一律全用位置参数（`%1$@ · %2$lld of %3$lld paths`）。有意不译：URL、MCP client JSON 配置、品牌名 Moppet、技术占位符（model-id/sk-…/https://…）。验证：build 0/0、smoke 99 PASS（含 L10n selfCheck——重复键会运行时 trap）、brain-smoke 51 PASS；grep 复核零未包裹英文。GUI 截图验证被终端 TCC 屏幕录制权限挡住（screencapture could not create image）——本环境只能代码级验证。

→ **自定义 Provider 融合轮（2026-10-25，v15.32）**：用户三点反馈——①添加完成直接进 Provider、不必单独展示；②Provider 里 key 不同步；③弹窗添加、保存自动关闭。根因（②）：`AISettings.load()` 无条件读**内置厂商槽**的 key，profile 激活时 vendor=.custom 而真 key 在 `api-key.profile:<id>`——selectProfile 瞬间是对的，任何下一次 load()（每个视图 init/每轮对话）就用空 .custom 槽覆盖掉内存里的 profile key，表现为"key 没同步"。修复 = load() 分支：activeProfileID 命中注册表→读 profile 槽（顺手把失效 id 清空回退）；smoke 新增回归断言 `providers: profile key survives load()`（备份/恢复 ai-settings + 测试 key 槽）。UX 重构：①删除 Settings 的 Custom Providers 独立区块（profilesCard 整段移除），profile 只出现在 AI Provider 的 Picker 里（原本就在），管理入口收进行内——Picker 旁 `+` 按钮开 sheet 添加；profile 激活时 `…` 菜单（编辑→sheet 预填 / 删除→registry.delete 兜底+vendor==.custom 时回落 .glm）；②添加/编辑都走 sheet（580pt 宽，ProfileCard 内容 + Cancel 行），**保存即自动关闭**且自动选中新 provider（upsert 后按落库 id——slug 撞车会被 registry 加后缀——写 key 槽再 selectProfile，顺带修了"key 先写进未加后缀 id 的孤儿槽"边角：ProfileCard.onCommitDraft 签名改为 `(profile, apiKey)`，key 一律由父层用落库 id 写）；③Picker 响应 registry 变化靠 aiCard 上的 onReceive(changedNotification)→profiles 重载。验证：build 0/0、smoke 100 PASS（+1）、brain-smoke 51 PASS、GUI 存活 5s 无错。

→ **白名单保存按钮归位轮（2026-10-25，v15.33）**：用户截图指出 Settings 底部的全局操作栏只挂着一个「保存白名单」——不管浏览到哪张卡片它都钉在页底，位置语义错误。修复：删除全局底栏（body 少一层 HStack+背景，「Saved ✓」/错误提示 + 保存按钮整体移入白名单卡片内部 TextEditor 下方，动画跟着卡片走）；顺带补翻 PageHeader 副标题 "Preferences & safety configuration"→「偏好与安全配置」（上轮 i18n 清扫漏了 subtitle: 位置的这一处）。验证：build 0/0、smoke 100 PASS、brain-smoke 51 PASS、GUI 存活。RULE：单一卡片作用域的动作（保存/清除）放卡片内部；页面级底栏只放跨卡片动作。

→ **快捷聊天条常驻轮（2026-10-25，v15.34）**：用户要求"聊天框一直保留，鼠标点击空白处才关闭"。原行为：`QuickChat.submit()` 两条路径（普通消息 + 斜杠命令）都 `hideInput()`——一按 ⏎ 输入条就消失，答案流进宠物气泡，连续追问只能反复点宠物。修复：删掉两处 hideInput（类头注释同步改）；输入条提交后**常驻**，焦点留在输入框，追问在上一轮流式输出期间即可输入（send() 的 active 门禁保留——流式中 Return 不丢草稿，按钮此时是 stop）；答案照旧流进宠物气泡。关闭途径不变：点击空白/其他窗口（local+global 监听）、Esc、再点宠物。验证：build 0/0、smoke 100、brain-smoke 51、GUI 存活。

→ **宠物气泡结果化轮（2026-10-25，v15.35）**：用户要求"宠物头上的空气泡只显示结果，不要显示工具调用和过程"。QuickChat.handle 原来把 toolStarted（🔧 name…）、toolFinished 失败（⚠️ name failed）、提交瞬间（Thinking…）全打进气泡。改为：①提交后 `PetBus.setState(.thinking)` 只切姿势不冒字；②toolStarted → `setState(.cleaning)`（干活姿势、无文字），toolFinished 不再说话（工具级失败属于过程，最终错误仍走 .error/turnCompleted）；③保留的都是结果类——答案 delta 流式、turnCompleted 最终文本+token、error ✗、斜杠命令输出。排查确认气泡的过程文字只有 QuickChat 一处来源：聊天窗 agent 只在 完成/出错/需要批准（可操作）时说话，各引擎（清理/卸载/Purge）发的都是结果公告。验证：build 0/0、smoke 100、brain-smoke 51、GUI 存活。

→ **测量缓存全面生效轮（2026-10-25，v15.36）**：用户目标"卸载和分析：文件没变不重测大小，直接用缓存；有变化的才重测，提速"。勘察发现三层问题：①**失效守卫一直是坏的（严重）**——`SizeCache.directoryMTime` 用 `URL.resourceValues(.contentModificationDateKey)` 读目录，实测（macOS 26）子文件创建/删除后该值**纹丝不动**（create+delete 前后完全相等），等于缓存一旦写入就粘死到 3 天 TTL，"有变化重测"从未生效过；改用 `FileManager.attributesOfItem(.modificationDate)`（实测 create/delete 都正确更新，亚秒精度）——**坑：目录的 contentModificationDateKey 不可作变更信号**。②**LRU 500 太小造成互相践踏**——一次 ~/Library 深两层分析就写几百条子树条目，扫描途中就把先前热条目挤光，下次全冷（正是"没变也重测"的体感来源）；提到 5000（每条 ~100B ≈ 500KB）。③**三处同步测量路径完全无缓存**——Clean findings（ScanEngine.scan）、卸载详情残留文件（UninstallEngine.relatedFiles，每次选中应用都全量重测，容器/缓存可上 GB）、Purge 产物（PurgeEngine）都用裸 `size(of:)`；新增 `ScanEngine.cachedSize(of:)`（mtime 守卫的同步 lookup→miss 才测→store，空结果不入缓存）统一接管。分析(topChildren→parallelSize)与卸载应用列表(sizeApps→parallelSize)本就带缓存，由 LRU 修复保住热度。smoke +5（LRU 守卫/首测入缓存/未变命中/变更失效/重测变大，SizeCache 文件备份-恢复模式）共 105 项。**实测提速：scan_clean(browsers) 冷 1.49s → 热 0.41s（3.7×，热跑大头已是进程启动）**。build 0/0、brain-smoke 51、GUI 存活。

→ **状态页进程卡修复轮（2026-10-25，v15.37）**：用户发现状态页「进程资源占用」卡片永远空白（"是不是没完成"——确实是）。根因：`SystemStatus.topProcesses` 的 ps 命令 `ps -ArcO %cpu -o pid=%PID%…` 在本机 ps 上列结构错乱（默认列在前、自定义列追加），解析器把第 2 列 TT（"??"）当 CPU 解析 Double 失败 → 每一行都被丢弃 → **该卡自诞生起永远是空数组**（macos26 坑库早已记录正确语法但当时没改到这处调用）。修复：命令改 `ps -Arcro pid,pcpu,pmem,comm | head -N`（-r=按 CPU 降序，列序与解析器严格对齐），实测返回干净四列；卡片补空状态文案（「暂时拿不到进程数据」——ps 失败/权限问题不再显示无声空壳）；smoke +1 守卫（top processes parse，防 ps 语法再漂移）共 106 项。build 0/0、brain-smoke 51、GUI 存活。

→ **沙箱联网 + 非删除放行轮（2026-10-25，v15.38）**：用户两点：①沙盒允许联网能上网查东西；②除删除外其他 bash 命令都允许（否则宠物聊天很多功能做不了）。改动：①`BrainAgent.networkAccess` 默认 **true**（聊天窗 🌐 按钮仍可关；profile 断言双向：true→`allow network*`、false→`deny network*`）。②新 `BrainSandbox.involvesDeletion(_:)` 启发式：按 `;`/`&&`/`||`/`|`/换行切段，段首（剥路径+跳过 sudo/env/nohup 包装）∈{rm,rmdir,unlink,shred,srm,trash}、`git clean`、`find …-delete`、`xargs rm…` 判删除；`shell` 与 `exec_command` 同步新流——**删除类命令在任何交互策略下先弹审批**（拒绝即返回 error），**非删除命令沙箱违规（exit 125）直接自动提权重跑、不再弹窗**（.never 策略除外——保持返回沙箱错误，用户显式选择不开提权）；.untrusted 行为不变。③系统提示词 Operating rules 3/4 重写（联网可用+非删除自动提权；删除永远先问且不许绕过）、shellSpec 描述同步。brain-smoke +5（profile 双向、删除检测 rm 族/find -delete/git clean/trash/管道段首、良性命令不误报：curl/python/mkdir>重定向/grep|wc）。验证：build 0/0、smoke 106、brain-smoke 56 PASS、GUI 存活。RULE：沙箱是护栏不是闸门——审批只留给删除与用户显式选择的策略。

→ **UX/美观优化轮（2026-10-25，v15.31）**：用户要求按《UX-REPORT.md》（同日生成的 7 主题审查报告）实施优化。**信任防护**：批量卸载加 confirmationDialog（名单+总量+废纸篓说明，UninstallView 逐 App 顺序执行并出 n/m 进度——顺带修正 BatchOutcome 累计）、单卸载/Analyze 移废纸篓/Optimize Run/Purge/History 清空全部补确认弹窗（全 app 确认范式统一为系统 confirmationDialog，仅 Slim 保留信息型 sheet）；审批按钮拨正 Approve=primary/Deny=secondary（宠物卡+ApprovalSheet，原来 Approve 是红色 destructive 易点反）；审查树 30 条上限改为可展开（"Show all N paths/收起"，隐藏项此前默认选中且不可见——所见即所删）；UserInput 5min 超时改为可感知（卡片/sheet 加"5 分钟后自动关闭"提示+超时后宠物播报）。**状态设计**：Clean 扫描可取消（CleanViewModel.startScan/cancelScan 任务句柄+ScanEngine 子任务协作检查 isCancelled，取消回 configure 保选择）；EmptyStateCard 组件（icon+title+hint+action）接入 Clean 零结果/Uninstall 搜索无结果/History 空表；完成反馈补 NSHapticFeedbackManager（UXFeedback.success：Clean 完成/批量卸载/单卸载/Analyze/Purge/Optimize）+ **主流程 Clean 全程接入 PetBus**（此前唯一不驱动宠物的模块：扫描 scanning 态、找到 N 项 celebrating、零结果播报、Freed X）。**信息架构**：侧栏 11 项分三组（无标 Dashboard+History/Settings；Clean/Uninstall/Purge/Slim；System/Optimize/Startup/Status/Analyze），行加 hover 反馈（SidebarRowButton），⌘1–9 直达前九路由、⌘F 聚焦卸载搜索框（隐藏按钮 keyboardShortcut 挂法）、菜单栏加 ⌘, 设置（Notification moppetNavigateSettings 广播 → RootView 切路由）；路由 @SceneStorage 记忆；两处硬编码 "Moley"/"Hi Sean" 改读 PetIdentity.name 与 NSFullUserName 时段问候；侧栏眼睛按钮改经 PetPanelVisibilityFlag（@Observable）响应面板显隐（原直读 controller 属性永不过期）。**宠物**：睡眠可唤醒（单击/菜单 Wake，Sleep 变 toggle）；开场白带双击提示；BrainAgent 单路播报（runLoop 内 say("→ tool")→setState、error 内部 say 删除、ChatView onEvent 去掉 turnCompleted "搞定啦"覆盖——窗口回合只说答案尾部）。**QuickChat**：submit 预检 AISettings.isConfigured，未配置直接气泡提示+打开主窗切 Settings 路由；错误气泡 8s→12s。**聊天窗**：滚动跟随开关（底部哨兵 onAppear/onDisappear + 悬浮 ↓ 回到底部按钮，流式长答案可回读）；工具 chip 加完成 ✓；toolResultBlock 可展开（Show more/less）；reasoning 从 EmptyView 改为折叠摘要块；lastError=="cancelled" 渲染为中性"回合已取消"不再红色报错。**宠物持久化**：PetSettings（sizeScale 0.8/1.0/1.25 + 拖动位置 savedFrame 启动恢复 + followScreen 可关——主窗换屏不再拽走手摆的宠物），Settings 桌宠卡加 Size 分段+Follow window screen 开关；Settings 页加分段过滤（All/General/AI/Data & Safety/About，原 10 卡 1200 行单滚）。**视觉体系**：Airi 补全字阶 token（title17/emphasis15/body13/footnote11/caption2 10/mono）+ chartPurple/Amber/Green 动态图表色（Status 页 4 处硬编码 hex 收编）；脚本批量替换 86 行 .system(size:)→token、9pt 全灭（10pt 下限）；Clean/History bottomBar neutral100 实底→ultraThinMaterial 玻璃；卸载搜索框 2pt 描边→1pt hairline。**L10n**：新增约 80 词条（卸载页全量、聊天窗 slash 摘要/页脚/帮助 tooltip、播报文案、设置分区/宠物卡、问候语），zh 表 346 键零重复；ChatView 硬编码中文（搞定啦/呜/需要你的批准）随双播报修复一并移除或 L() 化。回归：build 0 error/0 warning、smoke 99 PASS、brain-smoke 51 PASS。

→ **启动项行样式 + 侧栏重要性重排 + 状态页 kill 轮（2026-10-25，v15.32）**：用户给参考截图要求启动项按新样式排布、侧栏按重要性排列（Settings 最底、History 次底）、并要求支持 kill（先误解为启动项页 kill 进程，用户纠正：**kill 在状态页 Top 进程上**，启动项不需要——已回滚启动项 kill 相关代码，仅保留行样式重做）。①启动项页面重做（LaunchItemsView 全量重写）：每行 = 真实应用图标（`program` 指向 .app/Contents/ 内时截取 .app 路径用 NSWorkspace.icon(forFile:)，纯 plist 项保持文档图标——对齐参考图）+ 名称/label·路径副行 + 右侧**状态胶囊（●绿 Enabled / ●灰 Disabled）**，hover 该行时变为操作按钮（Enable=primary / Disable=secondary；RunAtLoad/KeepAlive/loaded/scope/管理员提示收进整行 tooltip），全局项名称旁小 lock.shield；needsAdmin 图标与 intro 文案不变。②侧栏重排（RouteGroup 四段）：Dashboard（无标）→ Clean（Clean/Uninstall/Purge/Slim）→ System（Optimize/Startup/Status/Analyze）→ 无标尾部（History、Settings 最底）；⌘1–9 恰好映射前九项（dashboard..analyze），History/Settings 无数字快捷键（Settings 仍有 ⌘,）。③状态页 Top 进程 kill：ProcessRow 提取子视图（整行 hover 目标），行尾 hover 浮现 ✕ 按钮（xmark.octagon）→ `kill(pid, SIGTERM)`（pid Int→Int32 显式转换），成功/失败（EPERM root 进程）反馈行显示在列表下方并立即 sample() 刷新（列表本身 2s 节奏）；不加管理员 fallback（root 进程明确报错提示）。L10n +4 词条（Kill process (SIGTERM)/Sent TERM/EPERM 报错/Disabled/Enabled）并清理误解轮孤儿词条（zh 表 353 键零重复）。回归：build 0/0、smoke 99 PASS、brain-smoke 51 PASS、GUI 启动存活。教训：用户说的"图2"只传了一张图（启动项列表），"支持kill"指的其实是状态页——多图需求先确认每张图的对应关系。

→ **分析页扫描进度+取消轮（2026-10-25，v15.33）**：用户截图分析页（"正在测量主目录…"孤 spinner）要求加扫描进度条+可取消。`ScanEngine.topChildren` 加 `progress: (@Sendable (Int, Int) -> Void)?` 回调（线程安全 Counter 计数已完成/总数，@unchecked Sendable + NSLock）+ 协作取消（子任务起手查 Task.isCancelled、for await 收到取消即 group.cancelAll()+break——已开跑的 parallelSize 深遍历不可中断，结果丢弃，注释言明）；`topChildren` 其他调用方（Analyze 子目录展开 limit:30）默认 nil 兼容。AnalyzeView：@State scanTask/progress(done, total)，扫描态 UI 换成线性进度条（ProgressView(value:) tint primary，maxWidth 340）+ TickingNumber 计数 "N / M 项" + Cancel 按钮（AiriButton secondary）；startScan() 包装可取消任务（rescan 时取消保留旧树+选择——取消≠重扫）、cancelScan() 立即回 UI 并 settle 宠物；完成后宠物 celebrating "Measured N entries (X)"；trash 后的自动重扫改走 startScan()。L10n +1（Measured %lld entries (%@)；"entries" 复用既有词条——新加时撞键 TRAP 了 smoke，正是 §已知坑，删重复即修复，354 键零重复）。回归：build 0/0、smoke 99 PASS、brain-smoke 51 PASS、GUI 存活。

→ **快速清理崩溃+范围防呆轮（2026-10-25，v15.34）**：用户报"快速清理只选了浏览器却清了全部"+ x86_64 崩溃（objc_opt_respondsToSelector ← String(format:) ← SwiftUI body 布局）。**崩溃根因实锤**：CleanView 两处 `String(format: L("%@ …"), viewModel.reviewCount)` 把 Int 传给 %@（review 页 totalBanner "%@ paths · %@" 与确认弹窗 "Remove %@ items (%@)?"）——CFString 对 %@ 读对象指针，Int>0 即野指针 respondsToSelector 段错误（**count==0 时 nil 安全不崩**，所以平时看不见）；快速清理流程必经 review 页 → 渲染即崩。修复 = 两处 key 改 %lld（zh 同步 "Remove %lld items (%@)?" / "%lld paths · %@"）。**全项目 format 错配审计**：逐条核对 12 处 String(format:) 的 specifier 与参数类型，其余 10 处全部正确（%lld 开头配 Int、%@ 配 String）。**"清了全部"排查**：CleanExecutor 忠实只清传入 findings（读源码确认）；smoke 新增 selectedFindings 三层断言（只选 browsers section → findings 全部属于 browsers；关 item → 其 findings 消失；excludedFindings → 单条排除生效）全绿——**选择链路正确**；结合 configure 页所有 defaultSelected 项默认勾选的事实，最可能成因是"以为勾选=追加、实际默认全选"的理解偏差 → 防呆：确认弹窗 message 现在首行显示"清理范围：A, B, C"（selectionSummary = reviewSections 的 section 名单），范围不对当场可见可取消。教训入坑清单：**Swift String(format:) 把 Int 传给 %@ 在 CFString 是延迟炸弹（值为 0 时 nil 安全），全项目 format 调用须按 specifier 顺序核对参数类型**。回归：build 0/0、smoke 99→102 PASS（+3 断言）、brain-smoke 51 PASS、GUI 存活。

→ **分析页 mole 式双栏布局轮（2026-10-25，v15.35）**：用户给 mole 分析页截图要求扫描结果按"左列表+右气泡图"布局、点击右侧气泡进入下一层。AnalyzeView 全量重写（原递归树 TreeNodeRow 删除）：①顶部面包屑（House+用户名 › 逐层段，点段跳回该层；chevron.left 回上一层；右侧当前层总大小）——FileNode 的 expanded 字段被 path: [FileNode] 栈取代（drillDown push / goUp pop / 点面包屑 slice）；②左列表 380pt：每行 = 圆形勾选圈（SlimView 同款 checkmark.circle.fill/circle）+ NSWorkspace 真实图标 + 名称 + **N items 副行**（SpaceEntry 新增 fileCount ← parallelSize 的 SizeSummary.files，FileNode 同步加字段）+ 大小右对齐 + 目录行 chevron；行主体点击=进目录（文件行点击=勾选）、圆圈独立勾选、hover 高亮——跨层勾选语义不变（selectedNodes 递归全部已加载节点）；③右气泡图 BubbleChart：**贪心外螺旋 packing**（按 bytes 降序，从中心沿螺旋找第一个无碰撞位，固定起始角保证确定性；r=sqrt(bytes/maxBytes)×100 感知缩放——面积非线性但小项保持可点，bbox aspect-fit 映射进容器）+ 主色渐变圆 + folder/doc 白色符号 + 圆径>52pt 显示名称，hover 放大 1.04+加深，点击目录气泡=drillDown，空层显示"没有可测量的内容"空态；④保留：进度条+取消扫描（v15.33）、底栏选择计数/移废纸篓/Rescan、确认弹窗、PetBus 播报。L10n +4（N items/共 %@/点击进入/空态，359 键零重复）。**pack 算法独立验证**：参考图规模 24 气泡零重叠、bbox 434×369（swift 脚本实测）。回归：build 0/0、smoke 102 PASS、brain-smoke 51 PASS、CGWindowList 实测主窗+宠物面板存活（screencapture 无录屏权限，气泡视觉未能截图验收——用户实测为准）。

→ **分析页秒开+进度回退修复轮（2026-10-26，v15.36）**：用户两个反馈——①进度计数"44/90 忽大忽小"：topChildren 各条目的进度回调各自 Task{@MainActor} 跳主线程，并行完成 + hop 不保序 → 计数回跳；修复 = 赋值前单调 guard（done >= 已有值才写）。②"再次进入分析页很慢，缓存是否生效"：SizeCache 本身健在（磁盘持久 + 3 天 TTL + 5000 LRU），慢的两个真因——**(a)** 全命中路径没有快路：路由切走 DeferredView 销毁 @State rootChildren，重进即全量重测；**(b)** 高频写入目录（Caches/Application Support）mtime 几乎必变 → 对应子树重测。修复 = **cache fast-path**：`ScanEngine.cachedTopChildren(of:limit:) -> (entries, missed)` 从 SizeCache 直接出快照；AnalyzeView.startScan 首扫前先查——**missed==0（即所有 mtime 未变、缓存值精确等于重测结果）→ 瞬时渲染 + 宠物庆祝，直接 return**；任何 miss → 走真测量（部分快照会"藏"目录，绝不 serve）。drillDown 子层同样全命中秒开。**附带真 bug（firmlink key 错配）**：smoke 断言抓到 `contentsOfDirectory` 返回 RESOLVED 路径（/var→/private/var，记忆坑点再现），而调用方构造的 URL 保持未解析形式 → store/lookup key 不一致，枚举子项 lookup 永远 miss 自己刚存的条目；修复 = SizeCache 的 key 统一 `url.resolvingSymlinksInPath().path`（store/lookup 同归一）。smoke +2 断言（全命中快照 missed=0 entries=2；失效计为 miss 拒绝部分 serve），102→105 项。回归：build 0/0、smoke 105 PASS、brain-smoke 51 PASS。注：进度 total=90 是 home 顶层全部条目数（limit 40 只限制返回条数），数字本身正常。

→ **气泡大小标注轮（2026-10-26，v15.37）**：用户要求气泡图每个气泡显示目录总大小。BubbleView 圆径 >52pt 时在名称下方加 bytesFormatted（白色 75% 透明、monospacedDigit、字号随圆径 8–10pt 自适应；图标字号相应 0.32→0.30 让位）；小气泡仍靠 hover tooltip（名称·大小·点击进入）。回归：build 0/0、smoke 105 PASS、brain-smoke 51 PASS。

→ **IME mach port 日志修复轮（2026-10-27，v15.38）**：用户报控制台 "error messaging the mach port for IMKCFRunLoopWakeUpReliable"——文本输入在 app 未激活/窗口未 key 时求 IMK 键盘通道的日志（伴随风险：首次弹出的中文组合丢失）。定位到 QuickChat 首次弹出竞态：showInput() 先置 panelVisible=true 再 show()，而 QuickChatInputView.onAppear 聚焦在 buildPanel 挂载时触发——早于 activate+makeKey。修复 = showInput() 顺序反转（先 show() 激活+key，再 panelVisible=true 让焦点经 onChange 在就绪后流入）+ 删除 onAppear 聚焦（竞态源）；ChatView onAppear 聚焦同理延迟下一 runloop（openWindow 异步建窗）。其余文本输入（卸载搜索/Purge 根目录/Settings 字段）走点击聚焦，click-to-activate monitor 已先行激活，无此问题。该日志在 macOS 26 广泛存在（系统级噪音），若修复后仍偶见但不影响输入，属良性。回归：build 0/0、smoke 105 PASS、brain-smoke 51 PASS、GUI 启动 7s 无该日志。

→ **卸载权限兜底轮（2026-10-30，M1 反馈）**：用户报"卸载没权限的时候没有弹出确认权限框"，补充"M1 平台有 bug，intel 正常"。排查确认卸载路径无架构分支，差异在 TCC 归属（见 §6.42）：Intel 上未决弹窗**阻塞**首次 `removeItem`，允许后删除自然完成；M1 上同一调用**快速失败**且永不弹窗（ad-hoc 签名身份不稳定 / 已记录拒绝）。修复：新增 `UninstallEngine.isPermissionDenied` + `deleteBundleWithAdminFallback`——权限类失败（513 / EPERM / EACCES）时回落 `OptimizeEngine.shellWithAdmin("rm -rf …")`，弹系统密码框以 root 删除（Finder 同款），顺带治好 root 拥有的 bundle；`uninstall` 与 `batchUninstall` 各加 `fallback: Bool = false` 参数，仅 `UninstallView` 两处调用传 true，MCP/无头保持旧行为（防 §6.1 死锁）。密码框被取消时保留原 App 管理提示，既有"去设置授权"恢复流程照旧生效。验证：build 0/0、smoke 271 PASS、brain-smoke 221 PASS。

→ **清理页配置布局重排轮（2026-10-30，用户截图"太丑了"）**：原 configure 页 = 4 张独立大卡片，标题/副标题挤在左、chevron+计数+勾选框挤在最右，中间一整段空白，卡片高度虚高、图标灰底几乎不可见。重做：①**覆盖度摘要卡**（40pt 进度环 + 「已选 4 / 24 条规则」+「已选 1 / 4 个类别」+ 全选/取消全选胶囊）作为页面唯一视觉焦点，取代原来藏在底栏的同类信息；②四个分区合并进**一张分组卡**（System Settings 式行列表，52pt 缩进发丝分隔线），行内顺序改为 图标chip → 标题/副标题 → 计数胶囊 → 三态勾选 → 折叠箭头（原来箭头在计数左边，语义倒序）；③展开的分区条目改为**内嵌面板 + 复选框**（原来用 switch 且每行自带灰底，读起来像"设置项"而不是多选清单），未选中降到 0.7 透明度表示"不在范围内"；④底栏只留范围胶囊 + 主按钮，按钮文案带数量（「扫描 4 条规则」）；⑤内容宽度 680→720，与 review/done 两阶段统一。配套新增离屏渲染探针 `--probe-render <clean|optimize> <png> [light|dark] [expanded]`（`App/PageRenderProbe.swift`，仿 `--probe-analyze-render`；**坑：页面底色近乎透明，离屏 host 必须显式铺 window/layer 底色，否则暗色 token 渲染在白窗上全是白字**），使布局可在无录屏权限下逐轮目检。L10n +3 词条（rules selected / Scan %lld rules / 只读扫描说明），zh 表零重复。验证：build 0/0、smoke 271 PASS、brain-smoke 221 PASS、dark/light/expanded 三态渲染目检通过。

→ **优化页布局重排轮（2026-10-30，用户"这个页面看上去不好看"）**：原 optimize 页 = 8 张同构大卡（图标 + 标题 + 「detail · 分类」副行 + 运行按钮），行内空白巨大、分类被塞进副标题读成噪音、锁图标与魔杖图标混用像错误角标。重做：①抽出可复用组件 `GroupedCard` / `GroupedDivider`（Components.swift）——单张表面 + 发丝分隔 + 缩进 52pt，CleanView 的分组卡同步改用它（渲染结果逐像素一致）；②8 项合并成一张分组列表，行内：图标 chip（普通=蓝魔杖 / 管理员=琥珀锁盾，12% 同色底）→ 标题（管理员项后跟 8pt 琥珀锁 glyph + tooltip）→ detail（去掉"· 分类"尾巴）→ **分类胶囊（minWidth 76 固定列，否则 5–11 字宽参差紧贴按钮，看起来像没对齐）** → 运行按钮（运行中同宽 ProgressView 占位，行不跳）；③列表上方加一行摘要「共 8 个任务 · 3 个需要管理员密码」，取代原来逐行的锁图标噪声；④内容宽度 680→720。L10n +2 词条。验证：build 0/0、smoke 271 PASS、brain-smoke 221 PASS、dark/light 渲染目检通过、clean 页回归渲染与改前逐像素一致。
→ **状态页仪表盘重排轮（2026-10-30，用户"优化一下显示，太丑了"）**：原页面 = 2×2 指标卡（CPU/内存/网络/电池）+ 磁盘卡 + 进程卡。问题：①四张卡内部节奏不一致——电池没有曲线，值+进度条让它的内容整体上移，和左边三张对不齐；②曲线用 Swift Charts 且没有固定 Y 域，自动缩放把 25% 的 CPU 拉满整张卡，面积填充读成"实心色块"（截图里的那种）；③CPU/内存的值和细进度条重复表达同一件事；④网络卡两条面积曲线叠成一片橄榄色楔形，分不清上下行；⑤磁盘只写"43.3 GB 可用"，没有分母；⑥进程列表两个裸百分比没有列名。重做：①统一卡内三槽（图标+标签 / 22pt 圆体数值 + 10pt 副标题 / **固定 34pt 可视化带**），电池用同带内的 levelBar 填充，四张卡回到同一基线；②**sparkline 改用 Canvas 手绘**（`Sparkline` 私有组件）——Swift Charts 在离屏 `cacheDisplay` 下**根本不光栅化**，等于布局回归对探针不可见，Canvas 两条路径一致、四张小卡更省，还能钉死 Y 域：CPU/内存 0…100 + 50% 虚线参考（低位时的空白读成"余量"而不是坏图），网络用 0…峰值×1.15，下行面积+上行虚线（不再叠成泥）；③CPU 的进度条删掉（与数值重复），内存大数字改百分比、副行给"36.2 GB / 68.72 GB"；④磁盘卡补"已用 / 共 / 百分比"；⑤进程卡加 PID·进程·CPU·内存列名 + 行间发丝线 + 右上计数；⑥首帧把首个采样写两遍（单点画不出线，前 2 秒是空带）；⑦`Int64(0).bytesFormatted` 会返回本地化的 "Zero KB"，速率 <1 B/s 一律显示 "0 KB"；⑧内容宽度 680→720。探针配套：`--probe-render status` + `StatusView.debugSeed`（离屏窗口里 `.task` 不触发，不 seed 就只能渲染空曲线和空进程表，等于验证不了）。**坑：一次 body 里放四个泛型 metricCard 调用会让类型检查器超时（"unable to type-check this expression in reasonable time"），拆成每卡一个 computed property 才过。** L10n +9 词条（CPU/内存/网络/电池/充电中/使用电池/进程/近 2 分钟/已用·共）。验证：build 0/0、smoke 271 PASS、brain-smoke 221 PASS、dark/light 渲染目检。
→ **空间大户页重排轮（2026-10-30，用户"这个页面设计也不合理"）**：原页面 = 5 张同构 `SettingsCard`（FDA 提示 / 摘要 / 快照 / Docker / Homebrew / 只读报告），每张自带私有表格，三处"大小"列落在三个不同 x 位置；快照勾选、Docker 清理、brew 清理三个按钮各自贴在不同宽度的文字块右侧；只读报告三行的链接按钮宽度不一，把大小列推得参差；页面宽度还停在 680。重做：①**摘要卡**成为唯一焦点——10pt 标签 + 22pt 圆体总额 + 右侧 Docker/Homebrew 图例（色点+名称+数值右对齐）+ 底部**占比条**（两段 Capsule 按 reclaimable 比例分割，"要不要打开这一页"一眼可见）；②Docker 与 Homebrew 合并进**一张分组卡**（它们是摘要总额的两个来源），行解剖与优化页一致：图标 chip（12% 同色底 28pt）→ 标题/副标题（数字留在副标题里，右列只放一个动作按钮，避免同一数字说两遍）→ 固定 124pt 动作列；明细（Docker 四类用量 / brew 前 5 个旧版本）收进**内嵌面板**（`neutral50@0.35`、缩进 52pt，与清理页展开分区同款），表头 类型/数量/大小 固定列宽右对齐，行间发丝线；③快照卡单独一张（它的操作是破坏性且需要多选）：头部右侧是「删除已选的 N 个」，列表前一行说明"快照共享数据块无法逐个计量" + **全选/取消全选**（原来要逐个点 7 个勾选框），列表后一行琥珀色"删除不可恢复"；④只读报告卡改成行列表（iPhone/邮件/信息 各带图标），大小列固定 76pt、链接列固定 104pt，右边缘成一条直线；⑤动作反馈从"两卡之间飘一句绿字"改成**着色提示条**（成功=绿勾+12% 底，失败=红叹号——原来失败也用成功色）；⑥宽度 680→720，与其余三页统一。配套：`--probe-render spacehogs` + `SystemHogsView.debugSeed`，探针新增 `h=<高度>` 参数（默认 860 会裁掉下半页）。顺带修 `AiriButton` 禁用态（§6.45）与 10pt 警告文案改用 `warningStrong`（浅色下 `warning` 在白底只有 2.2:1）。L10n +3 词条（Reclaimable now / Prune / Clean up）。验证：build 0/0、smoke 271 PASS、brain-smoke 221 PASS、dark/light 全页渲染目检。
→ **启动项页改开关轮（2026-10-30，用户"采用开关那种按钮能看着舒服一点"）**：原页面顶部是四行"工作原理"大段文字（把真正的列表推到折叠线以下）+ 每行一张独立卡片，右侧状态胶囊「● 已启用」**hover 才变成** Enable/Disable 按钮——动作藏起来了，而且胶囊的颜色没人能映射成开/关。重做：①顶部压缩成**一行摘要条**（`power` 图标 chip + 「6 个启用 · 2 个已禁用」+ ⓘ 弹 popover 装原来那段说明 + 右侧「重新扫描」），列表整体上移；②所有行合并进**一张 `GroupedCard`**，行内 = 真实 app 图标 30pt → 名称（管理员项后跟 8pt 锁）+ `label · path` 单行等宽 → **`Toggle(.switch)`**（`.small` + `.tint(primary)`，`.labelsHidden()` 但补 `accessibilityLabel`），动作即状态，不需要 hover；③**乐观开关**：`@State optimistic` 让旋钮先动，`onChange(of: item.disabled)` / `onChange(of: isBusy)` 再落回真值——否则每次切换旋钮会先弹回去 1–2 秒（管理员密码框更久），像点了没反应；父层把 `busyPath = nil` 挪到 `await scan()` **之后**，避免"先复位再翻转"的二次抖动；④busy 态在开关**左侧**预留固定 60pt 栏放 spinner，旋钮不位移；⑤busy 键从 label 改成 path（同一 label 装在 ~/Library 与 /Library 会同时亮两行，§6.22）；⑥禁用行名称降一档灰度、图标 0.75 透明；⑦空态换 `EmptyStateCard`（带 Rescan），操作结果改成成功/失败同色的提示条（最多 4 条）。探针加 `--probe-render startup` + `LaunchItemsView.debugSeed`（假数据指向真实 bundle 才有真图标）。L10n +2 词条。验证：build 0/0、smoke 271 PASS、brain-smoke 221 PASS、dark/light 渲染目检（开关开/关旋钮位置逐行核对）。
→ **状态页环形仪表盘微调轮（2026-10-30，用户"和参考图还有差距，圆太大了可以适当小一点，圆弧间距再小一点"）**：①整盘 500→**450**（所有内部常量同比 0.9：inset 84/64、列宽 132、数值 28pt、副行 10.5pt、中心盘 133、弧 12pt），圆环不再吃掉整页宽度；②弧缺口 12°→**6°**（trim 值 0.5083/0.7417 等），四段弧读起来是一个被切了四刀的整圆；③弧加粗 13→12（相对更粗）+ 辉光 radius 9 / 45%，轨道 0.7→0.6（参考图的轨道更暗，让彩色段更跳）；④**试过"图表带向外溢出 46pt"（参考图里图表确实比文字更靠外），但下排不成立**——同样的 y 上圆环比上排窄得多，绿条会压到弧线上，最后改成四排统一 132 宽、不外溢，靠缩窄列宽把下排图表压回弧内 17pt。教训：圆形布局里"上排能溢出"不代表"下排能溢出"，上下两排的可用宽度完全不同（§6.47）。

→ **状态页环形仪表盘重排（2026-10-30，用户给参考图"中间圆显示网络、其余四个弧显示百分比"）**：原页面是 2×2 指标卡 + 独立磁盘卡 + 进程卡，五块等权、彼此没有关系。重做：①**560pt 圆盘**：四条 78° 弧（12° 缺口落在四个正方向），弧长 = 该指标的百分比——CPU 蓝 / 内存紫 / 磁盘琥珀 / 电池绿，弧底有 70% 灰轨道（暗色下 45% 根本看不见）；左右两侧的弧分别从 12 点 / 6 点**向外张开**（`GaugeArc.reversed`），四个都顺时针会读成一个螺旋；②四个象限内容块 156pt 宽、固定 26pt 可视化带：图标 chip + 标签 → 28pt 圆体百分比 → 10.5pt 副行（内存「已用 / 共」、磁盘「已用 / 共」、电池「充电中 / 使用电池」、CPU「近 2 分钟」）→ 曲线（CPU/内存用 `Sparkline`，磁盘/电池用 7pt levelBar，无时间序列的指标也有东西占住同一条基线）；③**中心 156pt 圆盘**显示网络（它没有百分比，所以不画弧）：网络图标 + ↓ 18pt 速率 + ↑ 12pt 速率，浅绿 5% 填充 + 22% 描边——纯 `cardBackground` 在浅色模式下和白页面完全重合，等于没有焦点；④桌面机没有电池时**保留轨道 + 显示「—/无电池」**，而不是删掉整个象限（删掉后圆环缺一角，像没画完）；⑤进程卡改 `GroupedCard`（图标 chip + 「进程资源占用」+ 「按 CPU 排序 · 每 2 秒刷新」+ 计数胶囊，列名/发丝线/悬停 kill 不变）；⑥磁盘从独立卡片并入圆盘，`DiskInfo.snapshot()` 改为随采样一起在后台线程取。L10n +3 词条（磁盘 / 按 CPU 排序 · 每 2 秒刷新 / 无电池）。验证：build 0/0、smoke 271 PASS、brain-smoke 221 PASS、dark/light 渲染目检（弧长与百分比逐项核对、四象限不压弧线、中心盘在两种外观下都是独立圆面）。
→ **清理页展开动画修复轮（2026-10-30，用户"install 展开动画有问题，子框框先出来了"）**：`if section.expanded { 面板 }` 在 `withAnimation` 里插入时，SwiftUI 立刻按**最终尺寸**布局，动画只插值渲染几何——子面板第一帧就是全高，而卡片高度还在弹簧长大，于是面板先画到卡片底边之外，读起来就是"子框框先出来"。修复：①`GroupedCard` 给行容器加 `.clipShape(RoundedRectangle(cornerRadius: radiusCard, style: .continuous))`（放在 `.background` 之前，卡片背景与投影不受影响），裁剪框随卡片高度动画一起长，展开变成"卡片长到哪、面板露到哪"；②删掉面板上原来的 `.transition(.opacity + .scale(0.99, anchor: .top))`，只留 `.opacity`——scale 和裁剪互相打架，会额外制造"面板先滑出"的错觉。回归：clean(expanded)/optimize/spacehogs/status/startup 五页渲染确认裁剪没有切到卡片圆角、内嵌面板、分隔线与按钮；build 0/0、smoke 271 PASS、brain-smoke 221 PASS。
→ **设置页去掉「全部」标签（2026-10-30，用户"取消全部按钮，全部里面内容太多了，体验不好"）**：分段过滤器原本有 6 段（全部/通用/AI/成长/数据与安全/关于），"全部" 把十张卡一次性堆回来——等于把当初"1200 行单页滚动"的问题原样搬进了一个标签页。改动：删掉 `Section.all`（枚举、label 分支、五个 `section == .all ||` 前置判断），默认标签改为 `.general`；现在每段只承载自己那一组（通用 4 卡 / AI 2 卡 / 成长 1 卡 / 数据与安全 4 卡 / 关于 1 卡）。`L("All")` 已无调用方，但词条保留（字典多一条无害）。探针补 `--probe-render settings`（SettingsView 无 seed 依赖，直接渲染默认标签），实测分段条变成 5 段、默认停在「通用」。验证：build 0/0、smoke 271 PASS、brain-smoke 221 PASS、dark 渲染目检。
→ **状态页环形仪表盘第三轮（2026-10-30，用户"图1图2差很大，要能看出 1/4 圆边界和走势图，用颜色深浅做进度条，圆还是太大"）**：①轨道从 `neutral200@0.6` 改成**各象限主色 18%**——深色底上灰轨道和背景同色，导致每个象限只剩一截彩色、看不出这一格有多长；改成"暗色整段 + 亮色进度"后 1/4 边界立刻成立（§6.49）；②盘面 450→**400**（内部常量同比：inset 74/56、列宽 115、数值 26pt、副行 11pt、中心盘 110、弧 12pt），圆环不再霸占页面；③弧加粗到 12pt（相对更粗）、辉光 10pt/50%，接近参考图的霓虹感；④走势图变清楚：`Sparkline` 线宽 1.6→2.1、面积渐变 0.30→0.42，levelBar 7→9pt；⑤CPU 为 0% 时整格只剩暗蓝轨道——正好验证了"轨道要有色"这条（渲染里能完整看到那一格的范围）。验证：build 0/0、smoke 271 PASS、brain-smoke 221 PASS、dark/light 渲染目检。
→ **状态页环形仪表盘第四轮（2026-10-30，用户"箭头距离 1px、圆再小一点、走势图照红框做"）**：①**缺口 6°→9°**——圆头线帽各吃 1.77°，6° 缺口实际只剩 2.5°，且底部两侧都接近 100% 时两个亮帽几乎相接，就是用户指的"1px"（§6.50）；②**走势图按参考图重做**：图表带从"和文字同宽"改成"朝外侧悬挑、尽量贴到弧线"，上排 160pt（左列左移 48pt）、下排 118pt（受该高度圆环宽度限制），高度 22→26，面积渐变 0.42→0.50、线宽 2.1→2.2——现在是一块带亮顶边的填充面积图，而不是一根细线；③盘面先试 380（中心盘被迫 96、图表带 22，中间发挤），**回退到 400**：中心盘直径受 `板宽 − 2×竖向内缩 − 2×块高` 硬约束，400 是这套内容（标签+数值+副行+图表）的下限，再小就必须砍副行或砍中心盘。验证：build 0/0、smoke 271 PASS、brain-smoke 221 PASS、dark/light 渲染目检（四处缺口等宽、图表不压弧/不压中心盘）。
