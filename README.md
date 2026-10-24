# Moppet + Moley 🦫

原生 macOS 智能清理工具：**airi 式桌宠 + [OpenAI Codex](https://github.com/openai/codex) agent 能力完整移植的 Brain + mole 全部功能模块 + 供 AI 调用的内置工具（MCP）**。SwiftUI（macOS 14+）。

```
┌────────────────────────┐          ┌───────────────────────────────┐
│  ✦ Moppet (主窗口)     │          │   Moley 桌宠 (透明置顶面板)     │
│  [磁盘卡][9 模块入口]    │          │  "Found 612 MB 🧹"  ← 气泡     │
│  Clean/Uninstall/...   │          │      (◍˃ᗜ˂◍)       ← 吉祥物    │
└────────────────────────┘          │  [Scan][Ask AI][Main][Sleep]  │
┌────────────────────────┐          └───────────────────────────────┘
│  Moley · AI Chat       │  ←─────── AI Agent 用内置工具干活
│  user: 帮我清理下磁盘    │          (每次删除都弹原生确认对话框)
│  AI: → scan_clean ...  │
└────────────────────────┘          ┌───────────────────────────────┐
                                    │ Moppet --mcp (MCP 服务器)     │
  Claude Code / Cursor / 任何 MCP 客户端 ──→ 23 个工具 (JSON-RPC stdio)│
                                    └───────────────────────────────┘
```

## 运行

```bash
cd Moppet
swift run                    # GUI（主窗口 + 桌宠 + 菜单栏图标）
swift run Moppet --smoke    # 38 项无头自测（不删任何文件）
swift run Moppet --mcp      # 作为 MCP 服务器（供外部 AI 调用）
```

Xcode 可直接打开 `Package.swift`。

## 一、3D 桌宠（Moley）

复刻 `airi/apps/stage-tamagotchi` 的窗口配方（无边框透明置顶、全空间可见）+ 程序化 3D 角色：

| 能力 | 实现 |
|---|---|
| 3D 角色 | **原生 SceneKit 程序化 3D 鼹鼠**（几何体组合 + PBR 材质 + 三灯布光 + 呼吸联动的落地接触阴影），无 WebView/CDN 依赖——零网络也必定可见 |
| 状态动画 | 7 种状态实时驱动：呼吸/摆动（idle）、浮动（thinking）、鼻尖脉冲+雀跃（talking）、左右扫视（scanning）、颤抖（cleaning）、跳跃旋转（celebrating）、侧倒打鼾+闭眼（sleeping）、随机眨眼 |
| 悬浮 UI | 语音气泡（固定白卡+固定墨色，流式回答逐字显示，**双击气泡打开聊天窗**）、单击宠物切换快捷输入条、全窗拖拽 |
| 引擎联动 | `PetBus` 事件总线 → `PetSceneBridge` 直接驱动 3D 状态；聊天/工具/清理的每个阶段宠物实时表演 |
| 快捷聊天 | **单击宠物 → 屏幕中央的纯输入条**（560×64，大号输入框，不抢前台焦点）：⏎ 提交后自动收起、点击其他任何地方自动收起、Esc 关闭、再次单击宠物切换显示；**回答流式显示在宠物头顶气泡里**（长答案只显示尾部，完整历史进聊天窗会话列表）；工具审批时头顶直接弹 Approve/Deny 内联卡片 |
| 点击反馈 | 点按 = 跳跃+wiggle+鼻尖 boop 动画 + 手型光标；**庆祝动画播约两秒（一圈旋转）自动回落待机，单击宠物 = "知道了"立即停止**（此时不弹输入条）；**双击宠物/气泡打开完整聊天窗**（头部有明确关闭按钮）；**回合完成必提示**（"搞定啦 ✨·token 数"庆祝 / 出错卖惨 / 需要批准时召唤你） |
| 菜单栏控制 | SwiftUI `MenuBarExtra`（持有场景级 `openWindow`，主窗口/聊天窗被关闭后也能从菜单栏重新打开）+ 主窗口侧栏宠物显隐开关 |
| 独立运行 | 宠物面板是纯 AppKit `NSPanel`，独立于窗口生命周期——关闭全部窗口宠物依然在，且能从快捷菜单/菜单栏把主窗口和聊天窗重新拉起；关闭最后一个窗口不退出 app |
| 无闪烁登场 | 面板初始 `alphaValue = 0`，SceneKit 渲染出**第一帧后**才淡入（`SceneReadyCoordinator`）——延迟加载期间不再出现白色背景闪一下再变透明 |

> airi 的 `idle_loop.vrma` 待机动画仍随 bundle 保留（`Resources/pet/`），作为未来接入 VRM 皮肤管线（three-vrm 加载用户 `~/.moppet/pet.vrm`）的资产。

## 二、宠物聊天（Brain 即服务）

聊天窗就是**宠物本身的聊天**——没有独立的 "Brain 模式"：后台唯一引擎是移植自 Codex 的 agent 大脑，为宠物对话提供全部能力（工具调用、审批、会话记忆），swift-ai-sdk 作为统一 provider 层服务全部厂商：

- **9 家厂商开箱即用**：OpenAI / Anthropic / Gemini / DeepSeek / Groq / Mistral 原生 provider + GLM（智谱）/ Ollama / 任意自定义 OpenAI 兼容端点走 OpenAICompatible 传输——同一套 Agent，**Provider 与模型可在聊天窗控制条、快捷面板、Settings 三处切换并自动级联**（`AIVendor.knownModels` 内置各家精选模型清单）
- **自定义 Provider（ZCode 方式，含 API 格式选择）**：Settings → Custom Providers 可添加**任意多个**端点，编辑表单与 ZCode 同构——**Base URL / API 格式（Chat Completions (/chat/completions) · Anthropic Messages (/v1/messages) · Responses (/responses)——与 ZCode 三选项一致）/ API Key（眼睛显隐）/ 模型列表（+ 添加模型 逐行维护，空态虚线提示）**；配置存于 `~/.moppet/ai-providers.json`（纯文本可手编，旧文件无格式字段按 Chat Completions 解码）；每个 provider 拥有自己的 API key 槽位（`api-key.profile:<id>`，存于 0600 凭证文件，绝不与内置厂商串槽）和模型清单（手编或按格式从 `{base}/models`(Bearer，含 Responses) / `{base}/v1/models`(x-api-key) 一键刷新），设置页里**每个 provider 一张独立卡**（名称做卡头 + `…` 菜单重命名/删除，字段内联：Base URL / API 格式 / API Key 眼睛显隐 / 模型列表逐行添加），**添加卡带必填 Provider Name 字段，显示名称强制唯一**（重名/空名内联红字拦截，大小写与首尾空格不敏感），支持叠加任意多张卡；选择即 `providerId/modelId`；聊天窗/Settings 的 Provider 菜单把自定义 provider 与内置厂商并列，Test connection 按所选格式走真实传输验证
- **流式输出**：`streamText` 的 textDelta 逐字打到聊天气泡（Markdown 实时渲染），工具调用/结果/错误作为独立事件流式插入
- **SDK 托管的多步工具循环**：19 个内置工具经 `AIToolBridge` 桥接为 SDK `ToolSet`（JSON Schema 自动生成），`stopWhen: isStepCount(8)` 控制轮数；工具错误回喂模型自行恢复
- **安全契约写进系统提示词**：必须先 dry-run（`scan_clean`/`find_*`）、把结果展示给用户、确认后才能调用破坏性工具
- **原生审批对话框**：AI 调用破坏性工具时弹出 `ApprovalSheet`，用户点 Approve 才执行（`ApprovalCenter` + continuation）
- **API Key 存 `~/.moppet/ai-keys.json`（0600 权限文件，非钥匙串）**：未签名二进制每次重建签名都变、钥匙串 ACL 弹窗没完没了——文件存储零弹窗（与 codex CLI 的 `~/.codex/auth.json` 同一取舍）；钥匙串里的旧条目首次读取时自动迁移并删除；厂商切换自动填充默认 baseURL/模型名，一键测试连接
- **完整会话管理**：聊天窗左侧会话栏 ↔ agent rollout 一一对应——新建/切换（`codex resume` 式恢复完整上下文）/删除（带确认）；会话标题取首条用户消息；首条消息后自动进入列表
- **单一对话体验**：聊天即宠物对话（Brain 是它的服务层，不作为模式露出）；沙箱/审批/联网/Stop 是**输入框正上方**的一行轻量运行控制（紧贴 composer，语义是"下一条消息怎么跑"）
- **斜杠命令**：输入 `/` 弹出命令面板（/status /compact /diff /cd /ps /stop /init /export …，codex TUI 命令的聊天窗等价物）；快捷输入条同样支持，输出进宠物气泡
- **图片进对话**：📎 附件 / 拖拽 / ⌘V 粘贴图片随消息发送；模型也能用 `view_image` 主动看图

## 三、Brain：OpenAI Codex agent 能力完整移植 🧠

桌宠的大脑是 codex-rs 核心能力集的 Swift 移植（`Sources/Moppet/Brain/`，逐项对照上游源码实现）：

| Codex 能力（codex-rs） | Brain 实现 |
|---|---|
| agent 循环（`core/`：turn → SSE 流式 → 工具调用 → 回喂 → 直到无调用） | `BrainAgent.runLoop`：流式 textDelta、多轮工具循环（上限可配）、取消、usage 统计 |
| 审批策略 `AskForApproval`（untrusted / on-request / never） | `BrainApprovalPolicy` 三档 + 原生审批弹窗（ApprovalCenter） |
| 沙箱 `SandboxMode`（read-only / workspace-write / danger-full-access）+ `sandbox_workspace_write.network_access` / `writable_roots` | `BrainSandbox`：macOS Seatbelt（sandbox-exec）动态 profile，writable-root 用 **realpath 规范化**（firmlink！），网络默认拒绝（workspace-write 可开联网开关/追加可写根），zsh 重定向怪癖规避（沙箱内走 POSIX sh） |
| `shell` 工具（workdir/timeout/沙箱违规→升级询问） | `BrainTools.shell`：完整决策矩阵（untrusted 必问 / on-request 违规后询问升级 / never 直接回喂） |
| `exec_command` + `write_stdin`（unified_exec 可恢复会话） | `BrainExecSession` 注册表：spawn→yield→按 session_id 轮询/喂 stdin；`/ps` `/stop` 管理后台会话；跨 turn 存活、5 分钟寿命上限 |
| `apply_patch` 自定义补丁格式（Add/Update/Delete/Move to + @@ 上下文 hunk + 模糊定位） | `ApplyPatch` 完整解析器与执行器：上下文失配报行号、路径逃逸拦截、trailing-whitespace 容差 |
| `read_file`（行号、字节预算、截断） | `BrainTools.runReadFile` |
| `view_image`（图片进对话，ImageViewItem） | `view_image` 工具：魔数嗅探（PNG/JPEG/GIF/WebP，≤10MB）→ data URL → 图片会话项；Responses 走 `input_image`、swift-ai-sdk 走原生 image part；聊天窗图片气泡（点开原图） |
| 用户图片输入（TUI 粘贴 / exec `-i`） | 聊天窗📎附件（文件选择/拖拽/⌘V 粘贴，≤4 张）随消息发送，同一图片会话项管线 |
| `update_plan` / 计划步骤状态 | `update_plan` 工具 + 聊天窗 Plan 卡片渲染 |
| `request_user_input`（模型问结构化问题） | 原生问题卡：聊天窗 sheet（选项+Other 自由文本）+ 宠物面板内联紧凑卡；5 分钟超时安全回落，无头模式明确"未回答"不挂起 |
| hosted web_search（Responses 原生工具） | ChatGPT 订阅后端开启 `{"type":"web_search"}` 服务端搜索（聊天窗🔍开关；与上游一致按厂商能力门控——chat-completions 厂商不提供） |
| MCP resources（list/templates/read） | `list_mcp_resources` / `list_mcp_resource_templates` / `read_mcp_resource` 三工具（有服务器连接时注册） |
| `/compact` / 自动压缩（CompactedItem） | `/compact` 模型真实摘要压缩 + `compacted` rollout 记录（resume 时还原为上下文消息）+ 阈值自动截断压缩 |
| TUI 斜杠命令 | 聊天输入 `/` 唤起命令面板：/help /status /mcp /new /compact /init /diff /pwd /cd /ps /stop /export /copy（快捷条同样支持，输出进宠物气泡） |
| Responses API 原生协议（SSE：output_text.delta / output_item.done / response.completed） | `OpenAIResponsesModel`：自研 SSE 客户端，与 codex 同协议 |
| Provider 层（`model-provider-info`，OpenAI/Anthropic/自定义端点可换） | **全部统一走 swift-ai-sdk**（`AIModelFactory` 9 厂商）：Brain 只定义 agent 能力，传输层/工具编解码单一实现，与 Chat 的 Assistant 模式共用同一 provider 配置 |
| rollout 会话（JSONL：session_meta/turn_context/response_item/compacted，可 resume） | `BrainRollout`：同构记录 + 断尾容错 + `resume(sessionID:)`（含图片会话项；旧版 turn_context 无新字段可正常解码） |
| `rmcp-client`（MCP 客户端，工具命名 `mcp__server__tool`，资源三工具） | `BrainMCPClient`：stdio JSON-RPC 握手/list/call + resources/list、templates/list、resources/read，`~/.moppet/brain/mcp.json` 配置服务器 |
| AGENTS.md 指令发现（用户级 + root→cwd 祖先链） | `BrainInstructions`：`~/.moppet/AGENTS.md` + 全祖先扫描拼接 |
| 并行工具调用 | `runLoop` 的 TaskGroup 并发分发 |

验证：`swift run Moppet --brain-smoke`——49 项断言（apply_patch 七项行为、沙箱三档+联网/可写根 profile、脚本化模型驱动真实 4 工具轮循环、rollout 恢复、MCP 客户端往返、exec 会话 stdin 往返、view_image data URL、request_user_input 无头回落、图片/compacted 记录 round-trip、斜杠命令）全部通过，全程无网络。

> 范围说明：Codex 上游是 ~130 crate 的 Rust 代码库，本移植覆盖其**全部 agent 能力类别**（循环/流式/工具/补丁/沙箱/审批/会话/MCP/指令/多厂商），以 Swift 重实现而非逐行翻译；多代理（multi-agent）、云任务、语音等平台级子系统不在“桌宠大脑”范畴。

## 四、mole 全部功能（9 大命令对照）

| mole 命令 | 模块 | 实现程度 |
|---|---|---|
| `mo clean` | **Clean**：4 分区 24 规则（系统与用户/开发者 13 项/浏览器 5 项/安装包），dry-run 预览→确认→双模式删除（永久/废纸篓） | ✅ 用户级分区 |
| `mo uninstall` | **Uninstall**：应用列表（bundle ID + 图标 + 大小）、关联文件定位（Preferences/Caches/Containers/Support/LaunchAgents/Group Containers）、数据可选、全部进废纸篓 | ✅ |
| `mo optimize` | **Optimize**：Finder/Dock 重启、DNS flush、Spotlight 重建、purge、网络卷 .DS_Store、30 天+ Saved State 清理、健康报告；admin 任务走系统密码框（AppleScript privileges，等价 mole 的按操作 sudo） | ✅ |
| `mo analyze` | **Analyze**：目录大小排行（并行测量） | ✅ |
| `mo status` | **Status**：CPU（host_statistics 增量）、内存（vm_statistics64）、网络（getifaddrs 速率）、电池（IOKit）、Top 进程、uptime，2 秒刷新 | ✅ |
| `mo purge` | **Purge**：21 种构建产物（node_modules/target/dist/.gradle/Pods/__pycache__…）可配置根目录并行扫描 | ✅ |
| `mo installer` | Clean 的 Installers 分区（dmg/pkg/iso → 废纸篓）+ `find_large_files` 工具 | ✅ |
| （无对应，Moppet 原创） | **Startup 启动项**：扫描 `~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons` 三目录（`com.apple.*` 隐藏计数），逐项显示 RunAtLoad/KeepAlive/loaded 状态；禁用 = plist `Disabled=true`（持久）+ `launchctl bootout` **立即停跑**，启用 = 清标志下次登录生效，可逆不删除；全局项走管理员授权（同 Optimize 流程）；AI 工具 `scan_launch_items` / `set_launch_item_enabled`（label/路径严格匹配，§6.22） | ✅ |
| `mo history` | **History**：JSON 审计（逐路径、字节、成败、错误）+ AI 工具 `clean_history` | ✅ |
| `mo slim` | **Slim**：fat 头直读扫描通用二进制（零 lipo 子进程）→ 副本剥离 x86_64/i386（lipo -remove）→ 原身份重签名（无证书则 ad-hoc）→ codesign 校验通过才换位（原件进废纸篓）；App Store/Apple/运行中/只读应用跳过；**Intel 主机硬门禁**（hw.optional.arm64 sysctl，剥离后无法运行） | ✅ Apple Silicon |

安全模型与第一版相同并贯穿所有模块：只删 home 内、20+ 保护类别、符号链接解析、白名单永远赢、删除前二次校验、审计日志。

## 五、AI 可调用的内置工具（21 个 + Brain 的 Codex 工具）

`ToolRegistry` 是唯一工具源，**App 内 AI 与外部 MCP 客户端调用同一套实现、同一套安全门控**：

| 类别 | 工具 |
|---|---|
| 状态 | `disk_status` `system_status` |
| 清理 | `list_clean_rules` `scan_clean`（dry-run，返回 confirmation_token）`execute_clean`（需 token + 确认） |
| 分析 | `analyze_disk` `find_large_files` |
| 项目 | `find_project_artifacts` `purge_artifacts` |
| 卸载 | `list_apps` `app_related_files` `uninstall_app` |
| 优化 | `optimize_catalog` `run_optimize`（admin 任务只允许 UI 运行） |
| 历史 | `clean_history` |
| 白名单 | `whitelist_list` `whitelist_add` `whitelist_remove` |
| 安全 | `safety_check` |

**破坏性工具双门控**：
- App 内（`.ui` 模式）：原生确认对话框
- MCP（`.confirmedFlag` 模式）：调用方必须传 `"confirmed": true`——与 mole 给 Claude/Codex 的 skill 契约一致（先 dry-run 展示、征得同意、再执行）

### 接入 Claude Code / Cursor（MCP）

两种传输，任选：

**stdio**（经典方式）：
```json
{ "mcpServers": { "moppet": { "command": "/path/to/.build/debug/Moppet", "args": ["--mcp"] } } }
```

**HTTP（app 内开关）**：Settings → MCP Server 打开 "Run MCP server (HTTP)"（Network.framework 监听 127.0.0.1:8765，状态持久化、随 app 启动自动恢复；也可 `Moppet --mcp-http [port]` 独立运行）：
```json
{ "mcpServers": { "moppet": { "url": "http://127.0.0.1:8765/mcp" } } }
```

实测（stdio + HTTP 双通道）：`initialize` 握手 → `tools/list` 返回 19 工具 → `scan_clean` 返回真实结果（Chrome 缓存 612.4 MB + token）→ 未带 `confirmed` 的 `purge_artifacts` 被拒 → `safety_check /System` 返回 DENIED；HTTP 端 curl 三请求全通。

## 开源依赖

| 库 | 用途 |
|---|---|
| [swift-ai-sdk](https://github.com/teunlao/swift-ai-sdk) (Apache-2.0) | AI 核心：36 厂商统一接口、流式、工具调用 Agent 循环 |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) (MIT) | 聊天消息的 Markdown 渲染（代码块/列表/表格） |
| [KeychainAccess](https://github.com/kishikawatsumi/KeychainAccess) (MIT) | 仅作旧钥匙串条目的一次性迁移源（现行存储为 0600 凭证文件） |
| [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) (MIT) | 桌宠开机自启（SMAppService） |
| Swift Charts（Apple） | Status 页实时曲线（DSFSparkline 因 macOS 26 SDK 的 CGFloat 兼容问题被替换） |

## 性能与批量操作

- **并行测量**：目录大小改为并行递归计算（TaskGroup 分扇下钻，宽度 8），实测 CPU 占用 59%→133%
- **结果缓存**：重度扫描结果（目录测量/应用大小）缓存 3 天（`~/.moppet/brain/size-cache.json`），目录 mtime 变化即失效；实测跨进程热分析 16.4s → 7.2s；Settings → Scan Result Cache 可查看/清除
- **卸载页不再卡顿**：应用列表改为两段式——先秒出元数据（名称/bundle id），大小由 TaskGroup 并行后台补齐（带 `sizing n/m` 进度），完成后再按大小排序
- **会话枚举轻量化**：Dashboard/聊天侧栏的 rollout 列表只读文件头 + 字符串统计（不再整文件 JSON 解码），标题提取改为流式早停
- **批量卸载**：卸载页多选框 + 全选/反选 + `Uninstall N apps (大小)` 一键批量进废纸篓（单次 NSWorkspace.recycle 批处理），结果卡片列出成功/失败/释放空间并记入历史
- **彻底清理残留**：按 bundle id **和** 应用名双键扫描用户隐藏目录——Preferences/ByHost、Caches、Application Support、Containers、Saved State、HTTPStorages、WebKit、Logs、CrashReporter、Group Containers（只读上报）；**系统级** `/Library/{LaunchAgents,LaunchDaemons}`（含按内容引用扫描的僵尸启动项）、`/Library/{Preferences,Caches,Application Support}`、pkg receipts——系统项一键经管理员密码移除（AppleScript privileges）

### Codex 能力审计（对照 codex-rs 核心命令面）

| codex 能力 | 状态 |
|---|---|
| agent 循环 / 流式 / 工具并行 / 取消 / usage 统计 | ✅ |
| shell / read_file / apply_patch / update_plan 四工具 | ✅ |
| 审批策略 untrusted·on-request·never + 原生弹窗 | ✅ |
| 沙箱三档（Seatbelt + realpath 规范化 + 网络拒绝） | ✅ |
| rollout 会话持久化 / resume / 删除 / 会话侧栏 | ✅ |
| AGENTS.md 指令链 + persona 人格注入 | ✅ |
| `/compact` 上下文压缩 | ✅ 自动窗口化（>80 条时保留目标+近 40 条） |
| `codex exec` 无头单次执行 | ✅ `Moppet --brain-exec "<prompt>" [--yes]` |
| 多代理协作 / 云任务 / 语音 | 🗺 超出桌宠大脑范畴 |
- **内置清理工具直连 Brain**：19 个清理工具作为 Brain 一等公民注册（完整 JSON Schema + 安全门控）；破坏性工具只弹**一次**原生审批（原先 Brain 与注册表各弹一次）

## 宠物身份与人格

- **自定义名字**：Settings → Pet Identity 修改宠物名，聊天头部/输入框占位/开场白全局即时生效
- **自定义系统提示词（人格灵魂）**：多行编辑器写入 `~/.moppet/brain/persona.md`，每轮作为系统提示词的**第一段**注入（Persona 段 + Codex 式操作规则合成），下一条消息即生效

## 国际化（i18n）

- 轻量 `L10n` 层：键即英文文案，`L("Scan")` → "扫描"；跟随系统语言，Settings → Language 可即时切换（System / English / 中文）
- 已覆盖：侧栏导航、Dashboard、聊天窗（会话栏/输入/按钮）、清理流程（阶段标题/按钮）、卸载/分析/优化/状态/历史/设置的页面标题与主要操作

## Codex 订阅（UI 内登录）

- Settings → **Codex Subscription (ChatGPT plan)** → "使用 ChatGPT 登录"：**浏览器优先的 PKCE 流**（与 codex CLI 同一公共 OAuth client `app_EMoamEEZ73f0CkXaXp7hrann`）——点击**立即打开** `auth.openai.com/authorize`，本机 `localhost:1455` 回调监听器接收授权码后换 token 存入凭证文件（`~/.moppet/ai-keys.json`），厂商自动切到 Codex（模型默认 `gpt-5.2-codex`），账号邮箱从 id_token 解析显示
- 为什么不用设备码当主流程：`auth.openai.com` 在 Cloudflare 后面，**应用层 HTTP 客户端直接 403**（"Just a moment…"挑战页，实测复现），而浏览器能过（走用户系统代理/PAC）；设备码流程保留为 **"改用设备码登录"** 备选按钮
- 登录健壮性：请求 20s 超时；等待期 **Cancel** 按钮（取消贯穿轮询/回调等待）；`URLSession` 读取 `HTTP(S)_PROXY/ALL_PROXY` 环境变量；错误信息带 HTTP 状态码与 Cloudflare 判别提示
- 订阅后端（`chatgpt.com/backend-api/codex`）只讲 Responses API，为它配备专用 `ResponsesModel` 传输（SSE，与 Brain 契约一致，同走代理 session）；其余厂商仍走 swift-ai-sdk

## airi 资源复用

直接取自 airi 仓库（均 MIT）并随 bundle 打包：
- `idle_loop.vrma` 待机动画（未来 VRM 皮肤管线）
- **表情贴纸包**（`stage-ui/src/assets/stickers`，8 种情绪）——聊天窗头像实时映射宠物状态（扫描=困惑、清理完成=庆祝、睡觉=困倦…），失败时换悲伤脸

## 修复记录（本轮）

- **键盘无法输入（点击能聚焦但打不了字）**：`--win-debug` 实测抓到铁证——**从终端启动的 GUI app 是"后台启动"：`isActive=false`、`keyWindow=nil`**，点击能工作（点击穿透）但键盘事件没有着落。修复三层：① 启动时显式 `NSApp.activate(ignoringOtherApps:)` + 主窗口置 key；② **所有输入字段接 `@FocusState` 显式聚焦**（Settings 的 Base URL/Model/API Key/宠物名/persona/白名单 + 聊天输入框）——点按字段即程序化建立焦点，不再依赖可能失效的系统点击→first-responder 链路；③ `--win-debug` 改为每 4 秒周期输出 `isActive/keyWindow/firstResponder`，若仍复现可抓取点击后的真实焦点状态
- **标题栏侧栏开关按钮没反应**：`NavigationSplitView(columnVisibility: .constant(.all))` 的常量绑定把系统开关的写入吞掉了——改为 `@State` + `$columnVisibility` 双向绑定，开关可正常收起/展开侧栏
- **扫描范围 bug（"只选了浏览器却全扫"）**：排查结论——Clean 模块 UI 的勾选→`selectedItems`→`ScanEngine` 三层全部正确；根因在 **AI 聊天路径**：`scan_clean` 工具的旧契约是"不传参数=全扫"，模型在你指定范围时漏传/拼错参数就变成全量扫描。修复四件套：① `resolveItems` 模糊匹配（大小写/单复数/标题/条目名，"browser"→"browsers"）；② 无匹配时**明确报错并列出可用 section ids**（绝不静默扩大范围）；③ 工具输出首行回报**实际扫描范围**；④ 工具描述与系统提示词收紧（用户指定范围时必须传参，仅明确要求全扫才可省略）。冒烟新增 6 条范围防线断言（45 项），MCP 实测 `sections:["browser"]` 只扫浏览器 5 项
- **侧栏切换卡顿（点设置卡几秒）**：用 `--route-perf` 探针实测，根因是 `LaunchAtLogin.isEnabled`（SMAppService XPC）单次 1.5–1.8s 且 petCard 每次 body 求值都同步调它——settings 一次切换 3–8s。修复：状态缓存进 `@State`、首次离线读取、开关写入也走后台任务；另去掉切换时的整列 `withAnimation` 与 `.id(route)`（重复销毁+全列动画实测 150–750ms）、详情页改 `DeferredView` 一帧延迟构建、Settings 卡片列表改 `LazyVStack`（10 卡 0.9s→只建可见卡）、Dashboard 会话枚举挪出主线程。实测（debug/Intel）：全部路由 0.1–0.6s，settings 3.5–7.9s → 0.52s
- **GPT 登录报 device code request failed**：实测 `auth.openai.com` 对应用层 HTTP 客户端返回 Cloudflare 403 挑战页（浏览器则放行）——主流程改为**点击即开浏览器的 PKCE 授权码流**（localhost:1455 回调 + S256 + state 校验），设备码降级为备选按钮；错误信息现在带状态码与 Cloudflare 判别
- **主题跟随系统（本轮最终形态）**：此前为修"深色下文字看不清"曾把 app 钉成浅色——代价是毛玻璃变奶白、和系统脱节。最终方案：**移除一切外观钉死（preferredColorScheme / window.appearance / colorScheme(.light)），主题完整跟随系统**；可读性改由动态 token 保证——固定白底全部换成 `Airi.cardBackground`（浅色=白卡、深色=半透明黑纱），气泡/输入条/审批卡文字用自适应 `Airi.neutral900`。浅色系统=浅色毛玻璃+深字，深色系统=深色毛玻璃+浅字，两种模式都成套可读
- **快捷输入极简化（按用户要求）**：中央输入条只保留输入（回答区/Provider 切换器已移除），提交或点击外部即隐藏，回答流回宠物气泡
- **聊天窗关闭按钮**：窗口样式是 hiddenTitleBar（无红绿灯），头部右侧补 `⨯` 关闭按钮（Esc 也可）
- **Provider/Model 切换 + 自动级联**：每家 Provider 内置精选模型清单（`AIVendor.knownModels`）；**聊天窗控制条**（Provider + Model 菜单）切换，Settings 里切 Provider 自动级联默认 baseURL + 默认模型；共用 `AISettingsCoordinator`——任一处切换即持久化并广播，活跃 BrainAgent `refreshModel()` 即时生效（下一轮对话用新模型），自由填写的自定义模型 ID 会作为额外选项保留在菜单里
- **宠物快捷聊天（Raycast 式）**：单击宠物 → 头顶输入框（⏎ 发送/Esc 关/⏹ 审批内联），流式回答直接进头顶气泡；面板子类化 `PetPanel.canBecomeKey` 才能让无边框面板拿到键盘焦点；原单击菜单移到右键
- **双击宠物打开聊天**：双击开完整聊天窗（单击已被快捷输入占用）
- **宠物白底闪烁**：延迟加载期 SceneKit 首帧未渲染时窗口露出白色背景——面板初始 `alphaValue=0`，首帧回调（`SceneReadyCoordinator`）后 0.35s 淡入，1.2s 兜底
- **主窗口点击弹不出**：NSStatusItem → SwiftUI `MenuBarExtra`（常驻场景持有 `openWindow`，可重建已关窗口）+ `WindowRouter` 中继 + 稳定窗口标识；另加**离屏窗口修复**（frame 落在已断开的显示器上时自动拉回主屏居中）与 `--win-debug` 窗口自检模式
- **聊天布局**：Sandbox/Approval/Stop 从头部下方移到输入框正上方
- **宠物独立运行**：显式关窗不退出；宠物面板独立于窗口生命周期且能反向恢复全部窗口
- 顺手清掉既有构建警告（L10n 重复键、无谓 try、未用变量、Sendable 捕获等）

## 历史修复

- CPU 恒 0%：`host_statistics` 的 `count` 未按 `HOST_CPU_LOAD_INFO_COUNT` 预置（输入参数），调用直接失败——修复后实测 24.4%/68.2% 真实值
- 网络虚高：`utun*` 与 `en*` 双重计数同一流量——现仅统计物理接口
- 进程排序：`ps -Arcro pid,pcpu,pmem,comm` 正确按 CPU 降序
- 模块页（含 Clean）补齐返回 Dashboard 按钮

## 界面（macOS 现代质感）

- **毛玻璃**：窗级 `NSVisualEffectView`（behind-window vibrancy，主窗/聊天窗统一）+ 侧栏/头部/输入区 `.ultraThinMaterial`；内容卡片为半透明玻璃卡（浅色白 0.6 / 深色黑 0.3），壁纸色调透卡而过，文字用自适应中性色保证可读
- **卡片式分区**：所有模块以圆角卡片（12pt + 1px 描边 + 柔和投影）组织，CleanMyMac 式分区面板
- **动效**：`ProgressRing` 环形进度（弹簧插值的 trim 动画）+ `TickingNumber` 数字滚动（`.contentTransition(.numericText)`）贯穿扫描/清理/卸载计数/仪表盘
- **树状多选**：清理复查用 `OutlineGroup`（规则 → 逐文件勾选，取消勾选即保留该路径）；分析页是懒加载目录树（展开即并行测量，可勾选任意路径进废纸篓）
- **主窗口**：`NavigationSplitView` 侧栏导航（含 `mo xxx` 对照小字）+ 宠物显隐开关；Dashboard 落地页（磁盘环、快捷卡、状态胶囊）
- **聊天窗**：会话管理栏 + 宠物对话区（输入框上方一行沙箱/审批运行控制 + Stop）
- 宠物为原生 **SceneKit** 3D（含落地接触阴影、呼吸/眨眼/状态动画）

## 架构

```
Sources/Moppet/
├── Brain/                     # ★ Codex agent 能力移植（桌宠的大脑）
│   ├── BrainAgent.swift       # 循环 + Responses SSE + SDK 双模型后端
│   ├── BrainSandbox.swift     # Seatbelt 沙箱（realpath 规范化）
│   ├── BrainTools.swift       # shell/read_file/apply_patch/plan + 清理 + MCP 统一分发
│   ├── ApplyPatch.swift       # Codex 补丁格式完整解析器
│   ├── BrainRollout.swift     # JSONL 会话 + AGENTS.md 指令发现
│   ├── BrainMCPClient.swift   # MCP 客户端（stdio）
│   ├── BrainTypes.swift       # 审批策略/沙箱模式/事件流类型
│   └── BrainSmokeTest.swift   # --brain-smoke 无头验证
├── App/
│   ├── PetPanel.swift          # NSPanel 容器(canBecomeKey) + WindowRouter(开窗中继+离屏修复+--win-debug) + SceneReadyCoordinator(首帧淡入) + QuickScan + AppDelegate
│   ├── PetView.swift           # SceneKit MolePuppet(3D 鼹鼠+7 状态动画) + 气泡 + 内联审批卡 + 右键菜单
│   └── QuickChat.swift         # Spotlight 式中央快捷聊天面板(560×280，canBecomeKey panel + Markdown 流式回答 + 强制 light scheme)
├── Core/
│   ├── ToolRegistry.swift      # 19 个 AI 工具 + JSON Schema + 双门控（Brain 可调）
│   ├── AIAgent.swift           # swift-ai-sdk 多厂商 Agent（流式+工具循环）+ AIToolBridge
│   ├── MCPServer.swift         # stdio JSON-RPC MCP 服务器
│   ├── PetBus.swift            # 事件总线 + 审批中心（线程安全）
│   ├── Models / RuleLibrary / SafetyGuard / ScanEngine / CleanExecutor / SmokeTest
│   └── Modules/
│       ├── UninstallEngine.swift   # 应用卸载
│       ├── OptimizeEngine.swift    # 维护任务（含 admin 提权）
│       ├── SystemStatus.swift      # Mach/sysctl/IOKit 实时指标
│       ├── PurgeEngine.swift       # 项目产物 + 大文件
├── Resources/pet/              # airi 的 idle_loop.vrma（未来 VRM 皮肤管线资产）
├── Theme/                      # airi 设计 tokens 与组件
├── ViewModels/CleanViewModel.swift
└── Views/                      # 首页(9 入口)/Clean/Uninstall/Optimize/Status
                               # /Analyze/Purge/History/Settings/Chat
```

## 验证记录

- `swift build`：0 error / 0 warning
- `--smoke`：**38 项断言全部通过**（安全判定/glob/规则库/JSON 编解码/磁盘信息/工具注册表/破坏性门控/token 校验/系统指标/MCP 序列化）
- `--brain-smoke`：**20 项断言全部通过**——apply_patch 真实文件操作（增改删移/坏上下文拒绝/路径逃逸拦截）、Seatbelt 沙箱三档实测（read-only 拒写 home、workspace-write 允许写、curl 被拒 exit 6）、脚本化模型驱动 Brain 完整循环（plan→read_file→apply_patch→shell→流式总结，usage 精确统计）、rollout JSONL 持久化与恢复（16 items）、MCP 客户端连接自家服务器（19 工具 + safety_check 往返）
- 移植过程中实测修复的 macOS 26 兼容坑：`/var`→`/private/var` firmlink 需 realpath（`URL.resolvingSymlinksInPath` 不够）；zsh 输出重定向被 Seatbelt 拒（改 POSIX sh）；`(deny file-write*)` 会覆盖 subpath allow（Seatbelt 默认拒绝，无需显式 deny）；`sandbox-exec -f` 对新写文件偶发 ENOENT（改 `-p` 内联）
- `--mcp` 端到端：initialize / tools/list / tools/call（disk_status、system_status、scan_clean dry-run）/ 门控拒绝 / DENIED 判定 全部符合预期
- 扫描大小与 `du -sk` 一致（536,684 KB = 549,564,416 B）
- GUI 冒烟：主窗口 + 桌宠面板 + 菜单栏稳定运行
- 修复过一个真实死锁：MCP 模式主线程被 stdio 循环占用，工具内 `MainActor.run` 永久等待 → 改为直接回调 + PetBus 主线程跳转
- 第三方库升级后回归：依赖解析、全量编译 0 警告、`--smoke` 38 项断言、MCP 19 工具、GUI 存活 全部通过

## Roadmap

- [ ] `mo slim`：通用二进制检测与 thin（需保留 codesign）
- [ ] AI 语音/流式输出；桌宠 Live2D/VRM 皮肤
- [ ] 大文件/重复文件专用 UI（当前通过 AI 工具可用）
- [ ] Homebrew/AI agent 缓存等更多 clean 分区；活跃进程检测（lsof 等价）

> mole 为 GPL-3.0（tw93 商标），本项目未复制其代码；airi 为 MIT——3D 待机动画 `idle_loop.vrma` 取自其仓库，界面风格按其公开设计规范独立实现；Codex 为 Apache-2.0，Brain 为能力对等的 Swift 重实现。
