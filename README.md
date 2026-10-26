# Moppet

macOS 原生清理工具：**程序化 3D 桌宠 + 移植自 [OpenAI Codex](https://github.com/openai/codex) 的 agent 大脑 + [mole](https://github.com/tw93/mole) 全模块能力 + 23 个可被 AI 调用的内置工具（MCP）**。

纯 SwiftUI / SceneKit，无 WebView、无 Electron、无云端依赖：断网也能正常清理，AI 只在你配置了供应商时才参与。

`macOS 14+` · `Swift 6.0+`（SwiftPM 可执行文件，无 .app 打包） · `Apache-2.0`

```
┌──────────────────────────┐        ┌────────────────────────────┐
│  Moppet 主窗口            │        │  桌宠（透明置顶浮层）        │
│  磁盘卡 + 11 个功能入口    │        │  「找到 612 MB 🧹」← 气泡    │
│  Clean / Uninstall / …   │        │   (◍˃ᗜ˂◍)  ← 3D 角色        │
└──────────────────────────┘        └────────────────────────────┘
┌──────────────────────────┐                    │
│  聊天窗（= 桌宠的对话）     │◀───────────────────┘ 单击宠物 = 快捷输入条
│  你说 → agent 调工具干活    │   每次删除都会弹原生审批
└──────────────────────────┘
        ▲
        └─ 外部 MCP 客户端（Claude Code / Cursor / …）→ 同一套 23 个工具
```

## 快速开始

```bash
git clone git@github.com:xsean2020/Moppet.git
cd Moppet

swift build                    # 首次会拉取 4 个依赖并编译（约 3–5 分钟）
.build/debug/Moppet            # GUI：主窗口 + 桌宠 + 菜单栏
```

也可以 `swift run Moppet`（等价于构建后直接运行）。Xcode 可直接打开 `Package.swift`。

```bash
# 无头自测（不删除任何文件）
swift run Moppet --smoke         # 133 项：安全判定/规则库/工具契约/缓存/补丁/选择持久化
swift run Moppet --brain-smoke   #  56 项：agent 循环/沙箱/补丁/rollout/MCP/exec 会话

# 作为 MCP 服务器
swift run Moppet --mcp                    # stdio
swift run Moppet --mcp-http 8765          # HTTP（只绑 127.0.0.1）

# 无头 agent 单次执行（codex exec 等价）
swift run Moppet --brain-exec "清理浏览器缓存并报告"          # 删除类操作会被拒绝
swift run Moppet --brain-exec "清理浏览器缓存并报告" --yes    # 自动批准
```

其他诊断开关：`--probe-models`（订阅模型目录）、`--probe-floater`（浮层取色）、`--route-perf`（路由切换耗时）、`--win-debug`（窗口/焦点状态）。

## 功能模块

侧栏 11 个入口，全部走同一套安全层（只删家目录内、25 类保护路径、白名单永远优先、删除前二次校验、全部记入审计历史）：

| 模块 | 能力 | 删除方式 |
|---|---|---|
| **Clean** 清理 | 4 分区 24 条规则（系统与用户 / 开发者 / 浏览器 / 安装包），扫描前可逐项勾选，复审页逐文件勾选 | 永久删除（缓存/日志）或进废纸篓（安装包、归档），每项有明确标注 |
| **Uninstall** 卸载 | 应用列表（名称/大小/图标）+ 关联残留（Preferences、Caches、Containers、Support、LaunchAgents、Group Containers）+ 系统级残留（需管理员） | 应用与残留一律进废纸篓 |
| **Optimize** 优化 | Finder/Dock 重启、DNS 刷新、Spotlight 重建、内存 purge、网络卷 .DS_Store、30 天以上 Saved State；健康报告 | 不涉及用户数据 |
| **Startup** 启动项 | 扫描 `~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons`（`com.apple.*` 折叠计数），显示 RunAtLoad/KeepAlive/loaded | 不删除文件：写 `Disabled` 标志 + `launchctl bootout` 立即停跑，可逆 |
| **Analyze** 分析 | 双栏：面包屑 + 目录列表 + 气泡图；展开即并行测量，可勾选任意路径 | 选中项进废纸篓 |
| **Status** 状态 | CPU / 内存 / 网络 / 电池 / Top 进程（可悬停终止）/ uptime，2 秒刷新 | 仅 SIGTERM（带确认） |
| **Purge** 项目清理 | 21 类可再生产物（node_modules、target、build、dist、.next、.gradle、Pods、__pycache__…），自定义根目录并行扫描 | 永久删除（确认框明确告知不进废纸篓） |
| **Slim** 瘦身 | 通用二进制扫描（自读 fat header）→ 副本剥离 Intel 切片 → 原身份重签名 → codesign 校验通过才替换 | 原件进废纸篓；失败自动回滚；**仅限 Apple Silicon**（Intel 机硬门禁） |
| **History** 历史 | 每次清理的逐路径审计（路径、字节、进废纸篓还是永久、成功/失败原因） | 只读 |
| **Settings** 设置 | AI 供应商与模型、Codex 订阅登录、宠物名字/人格、白名单、语言、扫描缓存、MCP 开关 | — |
| **Dashboard** 总览 | 磁盘环、快捷入口、系统状态胶囊、会话数 | — |

## 桌宠

程序化 SceneKit 3D 角色（几何体 + PBR 材质 + 三灯布光 + 接触阴影），不依赖任何 3D 资源文件，装了就能看到。

- **7 种状态动画**：待机（呼吸/摆动/随机眨眼）、思考（浮动）、说话（鼻尖脉冲）、扫描（左右扫视）、清理（颤抖）、庆祝（跳跃旋转）、睡觉（侧倒打鼾闭眼）。任何状态切换都会重置基础姿态，不会卡在半路。
- **单击**：弹出屏幕中央的快捷输入条（⏎ 发送 / Esc 关闭 / 点空白关闭 / 再点宠物切换）。回答**流式显示在头顶气泡**里，完整内容落在聊天窗。
- **双击**：打开完整聊天窗。
- **右键**：快速扫描、打开主窗口、睡眠、退出。
- **审批**：AI 需要删除时，头顶直接弹 Approve/Deny 卡片。
- **气泡只讲结果**：工具调用/进度用姿态表达（扫描=扫视、清理=颤抖），不把过程文本塞进气泡。

宠物与窗口互相独立：关掉所有窗口，宠物还在；从宠物菜单或菜单栏能把主窗口/聊天窗重新拉起。

## Brain（Codex 能力对齐）

`Sources/Moppet/Brain/` 是 codex-rs 核心能力集的 Swift 重实现，不是逐行翻译：

| 能力 | 实现要点 |
|---|---|
| agent 循环 | 流式 textDelta → 并行工具派发（TaskGroup）→ 结果回喂 → 直到无工具调用；轮数上限、取消、usage 统计 |
| 审批策略 | untrusted / on-request / never 三档；**删除类命令在任何交互策略下都先问**，非删除的沙箱越权自动升级重跑 |
| 沙箱 | Seatbelt 动态 profile（read-only / workspace-write / danger-full-access），可写根用 realpath 规范化（firmlink），网络默认开、可关；read-only 不授予任何写路径 |
| 工具 | `shell`（超时/超长输出裁剪/取消终止）、`read_file`（行号+预算，凭证文件硬拒绝）、`apply_patch`、`view_image`（魔数嗅探 ≤10MB）、`update_plan`、`request_user_input`（5 分钟超时） |
| 补丁 | 完整解析 Add/Update/Delete/Move + `@@` 上下文；**两阶段应用**（先全部校验再落盘，失败不留半应用）；拒绝工作区根、解析符号链接、Move 保留内容修改、CRLF 保持 |
| 可恢复会话 | `exec_command` + `write_stdin` 会话注册表：spawn→yield→按 id 轮询/喂 stdin，`/ps` `/stop` 管理，SIGTERM→SIGKILL 升级 |
| 会话持久化 | rollout JSONL（meta/turn_context/response_item/compacted），注释掉的行容错、压缩后 resume 不复活旧历史、并发写串行化 |
| 上下文压缩 | 阈值自动压缩 + `/compact` 真实模型摘要；**压缩不拆散 function_call/output 对**（Responses 会 400） |
| MCP 客户端 | stdio JSON-RPC：超时、错误响应回传、字符串 id、裸命令名查 PATH、进程退出即失败未决请求、resources 三工具 |
| 指令发现 | `~/.moppet/AGENTS.md` + 根到 cwd 全祖先链拼接，persona 作为系统提示词第一段 |
| 斜杠命令 | `/help /status /mcp /new /compact /init /diff /pwd /cd /ps /stop /export /copy` |

未移植（平台级、与桌宠大脑无关）：多 agent 协作、云任务、语音、插件市场、code mode。

## 内置工具与 MCP（23 个）

`ToolRegistry` 是唯一工具源：App 内 agent 与外部 MCP 客户端调用**同一实现、同一安全门控**。

| 类别 | 工具 |
|---|---|
| 状态 | `disk_status` `system_status` |
| 清理 | `list_clean_rules` `scan_clean`（dry-run，返回 token）`execute_clean`（需 token） |
| 分析 | `analyze_disk` `find_large_files` |
| 项目 | `find_project_artifacts` `purge_artifacts` |
| 卸载 | `list_apps` `app_related_files` `uninstall_app` |
| 启动项 | `scan_launch_items` `set_launch_item_enabled` |
| 瘦身 | `scan_slim` `slim_apps` |
| 优化 | `optimize_catalog` `run_optimize`（admin 任务只允许在 App 里跑） |
| 历史 | `clean_history` |
| 白名单 | `whitelist_list` `whitelist_add` `whitelist_remove` |
| 安全 | `safety_check` |

**双门控**：App 内弹原生审批；MCP 调用方必须显式传 `"confirmed": true`，否则拒绝执行。白名单的增删同样算破坏性操作（它会改变"永不触碰"的边界）。

接入 Claude Code / Cursor：

```json
// stdio
{ "mcpServers": { "moppet": { "command": "/绝对路径/.build/debug/Moppet", "args": ["--mcp"] } } }

// HTTP（App 内 Settings → MCP Server 开关，或 --mcp-http）
{ "mcpServers": { "moppet": { "url": "http://127.0.0.1:8765/mcp" } } }
```

HTTP 端点**只监听 127.0.0.1**：它能执行删除类工具且没有额外鉴权，绑全网卡等于把删除权限交给局域网。

## AI 供应商

- **9 家内置**：OpenAI / Anthropic / Gemini / DeepSeek / Groq / Mistral 原生 provider，GLM / Ollama / 任意 OpenAI 兼容端点走兼容层。
- **自定义 Provider**：Settings 里可加任意多个，每个有独立 key 槽位（`api-key.profile:<id>`）、独立模型清单、可选三种 API 格式（Chat Completions / Anthropic Messages / Responses）；重名自动加后缀，不会覆盖已有配置。
- **模型清单**：内置厂商都能按 API 拉取（各自的 listing 端点），也可以手工增删；删除当前选中模型会自动回落到可用项。
- **凭证**：全部存在 `~/.moppet/ai-keys.json`（0600），不用钥匙串——未签名的 SwiftPM 二进制每次重建签名都变，钥匙串会反复弹 ACL 授权。旧钥匙串条目首次读取时迁移并删除。
- **ChatGPT 订阅登录**：浏览器 PKCE 授权码流（与 codex CLI 同一个公共 client 与回调地址，换掉任一项都会被服务端拒绝），token 到期前用 `refresh_token` 静默续期；订阅后端只讲 Responses API，因此单独走一个 SSE 传输。

## 安全模型

删除是这类工具唯一不可逆的动作，所以规则集中在 `SafetyGuard`：

1. **只能删家目录内**的路径（家目录本身、文件系统根、`/System` 等硬拒）。
2. **25 类保护路径**：钥匙串、Cookies、Messages、Mail、iCloud Drive、iOS 备份、Group Containers、Preferences、Accounts、Safari 配置、浏览器 profile 容器，以及 Documents / Desktop / Pictures / Music / Movies。
3. **白名单永远优先**：`~/.config/moppet/whitelist` 每行一个 glob，匹配路径**及其整个子树**即拒绝删除。
4. **符号链接解析后再判定**：链接指向保护区内同样拒绝。
5. **删除前二次校验**：扫描时过滤一次，真正删之前（永久与废纸篓两条路）再查一次。
6. **审计**：每次清理逐路径记录（成功/失败原因、删除方式），History 页可追溯。
7. **AI 删除必须批准**：shell 的删除命令、`apply_patch` 的 Delete/Move、全部破坏性工具，都在执行前弹审批；白名单文件即使在工作区内也不能被补丁删除。

## 扫描范围 = 你的勾选

清理页的勾选会持久化（`CleanSelectionStore`），并统一作用于三个扫描入口：

- Clean 页的 Scan / Rescan
- 菜单栏 / 宠物菜单 / ⌘S 的快速扫描
- AI 的 `scan_clean`：**不传参数时扫描你勾选的项目，而不是规则默认值**（显式传 `sections`/`items` 时以显式为准）

底栏实时显示"已选 N / M 个类别"，快速扫描播报"已扫描 N 个类别 · 找到 M 个路径"，范围永远可见、可核对。

## 性能

- **并行测量**：目录大小按 TaskGroup 分扇下钻（宽度 8）。
- **跨启动缓存**：测量结果入 `~/.moppet/brain/size-cache.json`（5000 条上限，目录 mtime 变化即失效，3 天 TTL）。目录变更检测用 `attributesOfItem(.modificationDate)`——`URL.resourceValues` 对目录在 macOS 26 上不会随子项变化更新，用它做判断会让缓存永久命中。
- **两段式列表**：卸载页先秒出元数据，大小后台并行补齐（带单调进度）；分析页展开才测量。
- **会话枚举轻量化**：侧栏会话列表在后台线程读，不再阻塞主线程。
- **主线程纪律**：`ps` 采样、大规模文件遍历、缓存读写都在后台；UI 状态变更统一回主线程。

## 国际化

轻量 `L10n`：键即英文原文，`L("Scan")` → "扫描"，367 条中文词条。跟随系统语言，Settings 里可即时切换（System / English / 中文），切换会刷新整个界面。注意：**中英表里出现重复 key 会编译警告、运行时 TRAP**，构建必须保持 0 警告。

## 项目结构

```
Sources/Moppet/
├── App/
│   ├── PetPanel.swift      # NSPanel 容器、窗口路由与修复、快捷扫描、AppDelegate
│   ├── PetView.swift       # SceneKit 角色 + 气泡 + 内联审批/提问卡 + 右键菜单
│   └── QuickChat.swift     # 快捷输入面板（便携 agent 会话）
├── Brain/
│   ├── BrainAgent.swift    # 循环、压缩、会话、MCP 连接、事件
│   ├── BrainTools.swift    # shell/read_file/apply_patch/exec/plan/提问 + 清理工具桥接
│   ├── BrainSandbox.swift  # Seatbelt profile、并发管道读取、删除检测
│   ├── BrainExec(Session).swift  # 可恢复 exec 会话
│   ├── ApplyPatch.swift    # 补丁解析与两阶段应用
│   ├── BrainRollout.swift  # rollout JSONL 读写 + AGENTS.md 发现
│   ├── BrainMCPClient.swift      # MCP 客户端（stdio）
│   ├── BrainSlash/UserInput.swift # 斜杠命令、结构化提问
│   └── BrainTypes|BrainSmokeTest.swift
├── Core/
│   ├── ToolRegistry.swift  # 23 个工具 + JSON Schema + 门控 + 确认 token
│   ├── SafetyGuard.swift   # 保护路径、白名单、glob
│   ├── ScanEngine.swift / RuleLibrary.swift / CleanExecutor.swift
│   ├── CleanSelectionStore.swift  # 勾选持久化（三个扫描入口共用）
│   ├── SizeCache.swift / Models.swift / HistoryStore(in CleanExecutor)
│   ├── AIAgent.swift / AIProviders.swift / CodexSubscription.swift
│   ├── MCPServer.swift / MCPHTTPServer.swift
│   ├── PetBus.swift / PetIdentity.swift / Stickers.swift
│   ├── L10n.swift / LegacyMigration.swift / SmokeTest.swift
│   └── Modules/            # Uninstall / Optimize / Purge / Slim / LaunchItems / SystemStatus
├── Theme/                  # Airi 设计 token 与通用组件
├── ViewModels/             # CleanViewModel / ChatSessionStore
├── Views/                  # 各模块页面 + MoppetApp（Window 场景/路由）
└── Resources/              # airi 贴纸（MIT）+ idle_loop.vrma（未来 VRM 皮肤资产）
```

数据目录：`~/.moppet/`（凭证 0600、`ai-providers.json`、`brain/{sessions,mcp.json,persona.md}`、`size-cache.json`）、`~/.config/moppet/whitelist`、`~/Library/Application Support/Moppet/history.json`。旧版本（Cleaner）数据在首次启动时一次性迁移。

## 验证

当前仓库状态（Apple Silicon 与 Intel 均通过；arm64 交叉编译亦验证）：

```
swift build                       0 error / 0 warning
swift run Moppet --smoke          133 项断言 PASS
swift run Moppet --brain-smoke     56 项断言 PASS
MCP (stdio / HTTP)                23 tools，initialize / tools/list / tools/call 正常
HTTP 监听                          仅 127.0.0.1
```

`--smoke` 覆盖：安全判定与 glob、规则库完整性、JSON 往返、磁盘/系统指标、工具注册表与破坏性门控、确认 token、大小缓存失效、补丁边界（删工作区根/无锚点 hunk/两阶段）、勾选持久化与扫描范围、压缩配对安全。`--brain-smoke` 覆盖：补丁真实文件操作、沙箱三档、脚本化模型驱动的多轮循环、rollout 恢复、MCP 客户端往返、exec 会话 stdin、图片项、无头提问回落。

## 已知边界

- **Slim 只有 Apple Silicon 可用**：移除 x86_64 切片后 Intel 机跑不了，运行时用 `hw.optional.arm64` 硬门禁；重签名后公证票据失效，首次启动由 Gatekeeper 在线校验，个别应用可能提示需重新信任。
- **Brain 的适用范围是"桌宠大脑"**：多 agent、云端任务、语音不在其中。
- **VRM 皮肤需要你自备 .vrm**：仓库里的 `idle_loop.vrma` 只是待机动作片段，不含角色模型（airi 上游也不分发受 Live2D/VRM 授权限制的模型）。
- **App Store 不可直接上架**：需要管理员提权、任意删除与本地 HTTP 监听的能力与沙箱冲突，详见 `APPSTORE_PLAN.md`。
- 系统关键项的启停/删除需要管理员密码（AppleScript 提权）；普通项不需要。

## 致谢与许可

本项目以 **Apache-2.0** 发布（见 `LICENSE`）。

- [mole](https://github.com/tw93/mole)（GPL-3.0，tw93 商标）：**只借鉴功能设计，未复制其代码或规则表**。
- [airi](https://github.com/moeru-ai/airi)（MIT）：表情贴纸与 `idle_loop.vrma` 随包分发，界面参照其公开设计规范独立实现。
- [Codex](https://github.com/openai/codex)（Apache-2.0）：Brain 为其 agent 能力的 Swift 重实现。
- 依赖：[swift-ai-sdk](https://github.com/teunlao/swift-ai-sdk)（Apache-2.0）、[MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui)（MIT）、[KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess)（MIT，仅作旧条目迁移源）、[LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern)（MIT）。
