# Moppet（Cleaner）用户体验与视觉优化分析报告

- **日期**：2026-10-25 · **对象**：`/Users/sean/cleaner/Cleaner`（v15.29，53 个 Swift 文件）
- **方法**：全量代码审查（主窗口 / 主题 / 核心流程页精读，宠物与聊天维度专项精读）+ 量化统计（字号、颜色、动效、反馈机制、本地化覆盖率）
- **结论摘要**：产品的视觉地基（Airi token + 毛玻璃）和工程意识（性能、窗口管理）已经是高水准；当前最大的提升空间不在"再美化"，而在**信任防护（确认弹窗缺失）、状态设计（空态/取消/错误）、排版体系收敛、宠物与 AI 聊天的首用引导**这四块。

---

## 一、做得好的地方（建议保持，不要动）

1. **动态色彩体系**：`AiriTheme.swift:25-53` 全部 token 双态定义（light/dark），主题跟随系统、毛玻璃卡片 `cardBackground`（白 0.6 / 黑 0.3）双模半透明——这正是此前定下的"可读性靠动态 token，不 pin 外观"路线，执行得很干净。全项目硬编码 `.white/.black` 仅 4 处且都有正当理由（阴影、按钮前景）。
2. **窗底毛玻璃 + 玻璃卡片的层次感**：`Components.swift:8-31` 的 pass-through `NSVisualEffectView`（alpha 0.7）解决点击穿透，卡片用 glass 填充 + hairline 描边 + 轻阴影，视觉语言统一。
3. **干跑优先（dry-run-first）的清理契约**：`CleanView` 五阶段流程（configure → scanning → review → cleaning → done）+ Trash/永久删除的文案区分（`CleanView.swift:53-61`），这是同类工具里最值得信任的设计。
4. **性能意识**：`DeferredView`（`MoppetApp.swift:364-385`）延迟重树构建、路由切换不做整列动画、滚动历史 off-main（`HomeView.swift:31-36`）、卸载列表先元数据后尺寸流式补齐（`UninstallView.swift:64-82`）。
5. **微动效**：入口 stagger（`IconItemCard` entranceIndex）、数字滚动 `TickingNumber`（`contentTransition(.numericText)`）、按压 0.95 缩放、ProgressRing 弹簧动画——细节到位。
6. **宠物工程质量**：AppKit 交互层解决后台首击问题、`applyState` 显式重置变换避免 SCNAction 残留、审批/提问"宠物内联卡 + 聊天 sheet"双表面共享同一 continuation——健壮且体验贴心。

---

## 二、问题清单与建议（按主题，含优先级）

> 优先级：**P0** = 数据风险/信任破坏，**P1** = 高频路径上的明显摩擦，**P2** = 打磨与前瞻。

### 主题 1：信任与破坏性操作防护（P0，最优先）

**1.1 卸载完全没有二次确认（单 App 与批量都是）**
- 现状：批量卸载 `UninstallView.swift:151-164` 点击按钮直接执行 `batchUninstall`；单个卸载 `UninstallView.swift:398-432` 同样无确认。全 app 唯一的 `confirmationDialog` 在 `CleanView.swift:19`。
- 问题：与自家契约直接冲突——Dashboard 承诺 "Everything below is previewed before anything is deleted"（`HomeView.swift:46`），Clean 页也兑现了，卸载页却一键进废纸篓。批量场景（误触 + 全选）风险放大。
- 建议：批量卸载加 `confirmationDialog`，列出 App 名单前 N 个 + 总大小 + "移至废纸篓（可恢复）" 说明；单个卸载已有左侧预览可视为已预览，但 `Uninstall + data` 建议仍确认一次。工作量：**小（半天内）**。

**1.2 其余破坏性操作同样裸奔**
- `HistoryView.swift:42` Clear 清空全部历史（不可恢复）无确认；`AnalyzeView.swift:75` "Move N to Trash"；`OptimizeStatusPurgeViews.swift:59` Optimize Run（会杀进程/登出重启类操作）；Purge 批量删除 node_modules 等。均无确认。
- 建议：统一一个 `DestructiveConfirm` 帮助函数（title + 名单摘要 + Trash/永久 文案），全部接入。工作量：**小**。

**1.3 确认范式三分天下，需统一**
- Clean 用系统 `confirmationDialog`（`CleanView.swift:19`），Slim 用自绘确认层（`SlimView.swift:14,178-179`），其余没有。交互记忆不统一。
- 建议：统一收敛到系统 `confirmationDialog`（原生、免维护、支持 destructive 角色着色）；Slim 的自绘层若要保留（信息量大），至少视觉规格与系统一致。工作量：**小**。

**1.4 审批按钮颜色语义反常规**
- Approve 用红色 destructive、Deny 用灰色 secondary（`PetView.swift:707-708`、`ChatView.swift:1074-1075`）——与 macOS "确认=主色/取消=灰" 的肌肉记忆相反，紧张场景容易点反。
- 建议：Approve 回主色（或默认强调按钮），风险靠文案与图标警示（"允许执行 rm -rf …"）。工作量：**极小**。

**1.5 审查树只显示前 30 条 finding，但被隐藏的项默认全选**
- `CleanView.swift:306` `result.findings.prefix(30)`——一个 section 超过 30 条路径时，第 31 条起用户看不见也无法取消勾选，却会计入总量并被删除。这违反"所见即所删"的预览承诺。
- 建议：超过 30 条时显示 "…and N more" 行 + "Show all"（虚拟化或分页展开），或至少在行内显示 "N paths not shown are also selected"。工作量：**中**。

**1.6 UserInput 5 分钟超时完全静默**
- `BrainUserInput.swift:50` 300s 超时直接 resume nil，宠物卡与聊天 sheet 都没有倒计时或超时提示，用户回来不知道问题已被取消。
- 建议：卡片/sheet 显示剩余时间（进度条或倒计时文字），超时后宠物说一句。工作量：**小**。

### 主题 2：状态设计——空态、取消、错误（P0–P1）

**2.1 扫描不可取消**
- `CleanViewModel` 无任务句柄、无 cancel（全文 grep 仅 `func scan()` at `CleanViewModel.swift:135`）；`CleanView` scanning 阶段（168-193）没有 Cancel 按钮。全盘扫描可能跑很久，用户只能干等或换路由。
- 建议：scan 存 `Task` 句柄，scanning/cleaning 阶段加 Cancel 按钮；取消后回到 configure 并保留已选项。工作量：**小-中**。

**2.2 空态全线缺失**
- 全项目无 `ContentUnavailableView`/专门空态（grep 证实）。具体：卸载页搜索无结果 = 空白列表（`UninstallView.swift:45-54`）；Clean 扫描零结果只有 totalBanner 显示 "0 paths · 0 KB" + 禁用按钮（`CleanView.swift:224-242`）；History 无记录时同样朴素。
- 建议：做一个 `EmptyStateCard(icon, title, hint, action?)` 组件：Clean 零结果 → "✨ 没有可清理项" + Rescan；搜索无结果 → "No apps match 'xxx'" + 清空搜索；History 空 → 引导先跑一次清理。空态是低频但决定"这软件懂不懂我"的时刻。工作量：**小**。

**2.3 错误反馈无重试范式**
- 卸载失败只写进 resultText 卡片（`UninstallView.swift:411-414`），AI 错误气泡 8 秒即逝且无行动入口（`QuickChat.swift:107`）。没有统一的"失败 + 重试 + 详情"模式。
- 建议：错误卡片统一带 Retry 按钮；QuickChat 错误气泡延长显示并加"打开设置/重试"。工作量：**小**。

**2.4 批量卸载进行中无进度**
- `batchRunning` 只是禁用按钮（`UninstallView.swift:119-128`），多 App 批量时没有任何进度指示。
- 建议：按钮内嵌 ProgressView（AiriButton 已有 `busy` 参数！直接复用），或顶栏显示 "3/8 · Xcode"。工作量：**极小**。

**2.5 完成反馈缺少触感/声音，且模块间不一致**
- 全项目 0 处 `NSHapticFeedbackManager`/`NSSound`（grep 证实）。更割裂的是：卸载/优化/Purge/分析/QuickScan/Brain 回合都会让宠物庆祝，唯独**最大众的主流程 Clean 全程不驱动宠物**（CleanView 无任何 PetBus 调用；对照 `UninstallView.swift:162,426`、`AnalyzeView.swift:118`、`ToolRegistry.swift:208-259`）。
- 建议：① CleanViewModel 在扫描开始（scanning 态）/完成（celebrating + "Freed X"）接入 PetBus；② 清理完成时 `NSHapticFeedbackManager.perform(.alignment)` 或轻提示音（可设开关）。工作量：**小**。

### 主题 3：信息架构与导航（P1）

**3.1 侧栏 11 项平铺，无分组**
- `Route.allCases` 顺序平铺（`MoppetApp.swift:255`）：dashboard/clean/uninstall/optimize/startup/analyze/status/purge/slim/history/settings，两个"系统"类（startup/status）混在"清理"类中间。
- 建议：分 3-4 组（**通用**：Dashboard/History/Settings；**清理**：Clean/Uninstall/Purge/Slim；**系统**：Optimize/Startup/Status/Analyze），组头用 10pt 大写小标题（macOS 侧栏惯例）。也可顺势精简：Optimize 与 Status 是否值得两个独立入口值得再想。工作量：**小**。

**3.2 双导航模型：返回箭头 vs 侧栏**
- 每个内容页 `PageHeader` 都带返回箭头（`onClose` → 回 Dashboard，如 `CleanView.swift:13`），但侧栏始终在场。三套并存的导航（侧栏/返回箭头/Dashboard 快捷卡）让"我在哪、怎么回"的心智模型变复杂，返回箭头还占据标题位。
- 建议：保留侧栏为主导航；`PageHeader` 的 onBack 只在窗口极窄（侧栏折叠）时出现，或干脆去掉（Dashboard 快捷卡已经是"返回首页"的柔和路径）。工作量：**小**。

**3.3 键盘与系统菜单几乎空白**
- 快捷键只存在于 MenuBarExtra（`MoppetApp.swift:96-111`）；主窗口无 cmd+, 打开设置、无 cmd+1..9 路由切换、无 cmd+F 聚焦搜索（卸载页搜索框只能点）。Settings 作为窗口内路由，连系统"Preferences…"菜单项都没有接管。
- 建议：① 菜单栏加 `cmd+,` → 跳 settings 路由；② 侧栏条目挂 `keyboardShortcut("1"..."9")`（需先做分组）；③ 卸载页 `cmd+F` 聚焦搜索（FocusState 已就位：`UninstallView.swift:25`）。工作量：**小**。

**3.4 无首启引导**
- 第一次打开直接落 Dashboard（`route` 默认 `.dashboard`，`MoppetApp.swift:180`），没有任何引导：不知道宠物能点什么、AI 需要配 Key、哪些功能危险。AI 未配置时只有快捷卡副标题一句提示（`HomeView.swift:97`）。
- 建议：轻量首启卡（不做全屏向导）：Dashboard 顶部第一张卡 = 3 步清单（配 AI Key → 认识桌宠 → 跑第一次扫描），完成即折叠消失。工作量：**中**。

**3.5 路由与窗口状态不记忆**
- `route` 是普通 `@State`（`MoppetApp.swift:180`），重启永远回 Dashboard。建议 `@SceneStorage("route")` 记忆上次路由。工作量：**极小**。

**3.6 设置页 1211 行单页长滚动**
- `SettingsView.swift` 1211 行、十余张 SettingsCard 纵向排列（59,117,142,396,517,670,691,738,792,845,863,957），找一项要滚很久。
- 建议：设置内部加二级侧栏/分段（通用 / AI Provider / 模型目录 / 宠物 / 语言），或顶部加锚点分段控件；至少加一个设置内搜索。工作量：**中**。

**3.7 两个小 bug**
- 宠物改名后 UI 仍写死 "Moley"：`HomeView.swift:46`、`MoppetApp.swift:268`（zh 表里也是写死的，`L10n.swift:60,74`）。PetIdentity 明明支持改名（`SettingsView.swift:65-99`）。→ 全部改读 `PetIdentity.name`。
- 侧栏眼睛按钮状态会过期：`PetPanelController` 是普通类非 Observable（`PetPanel.swift:17,41`），`MoppetApp.swift:278` 在 body 里直接读 `isVisible`，无失效通知 → 显隐后图标不同步。→ 改 @Observable 或回调刷新。

### 主题 4：宠物与 AI 聊天（P1，功能完整度高，短板在引导与细节）

**4.1 未配置 AI 时无预检**（`QuickChat.swift:52-81`、`ChatView.swift:417` 硬编码英文提示）——提交后才报错，且无"去设置"按钮。→ submit 前 guard，气泡/空态直接给「打开设置」按钮。**小**。

**4.2 聊天窗口强制自动跟随滚动**（`ChatView.swift:580-591` 每个 delta 都 scrollTo 底部）——流式长回答期间无法回读。→ 偏离底部时暂停跟随，浮现「↓ 回到底部」。**小-中**。

**4.3 宠物睡着唤不醒**：Sleep 后 `settle()` 不覆盖 sleeping（`PetBus.swift:67-76`），单击只 toggle QuickChat（`PetView.swift:488-494`），菜单无 Wake。→ 单击时若 sleeping 先唤醒，或 Sleep 改可切换。**极小**。

**4.4 回合结束双播报冲突**：`BrainAgent.swift:640` 说答案尾部，随即被 `ChatView.swift:121-123` 的"搞定啦 ✨"覆盖；QuickChat 路径 tool 播报与 cleaning 态互相抢占（`BrainAgent.swift:656` vs `QuickChat.swift:96`）。→ 按发起来源单路播报。**小**。

**4.5 长答案气泡不可读**：截尾 320 字符 + `lineLimit(12)`（`QuickChat.swift:116-120`、`PetView.swift:584`），12 秒消失，无"查看完整回答"。→ 超长时显示摘要 + 「在聊天中查看」链接。**小**。

**4.6 双击进聊天窗口可发现性差**：唯一提示藏在 slash 命令报错文案里（`QuickChat.swift:62`）。→ 开场白加一句，或 QuickChat 栏放显式「打开完整聊天」小按钮。**极小**。

**4.7 工具调用过程可视化薄弱**：chip 只有工具名（`ChatView.swift:975-983`），无运行中/耗时/完成态；输出块 `lineLimit(14)` 不可展开（998）；reasoning 直接丢弃（927-928）。→ chip 加 spinner→✓ 与耗时，输出可展开，reasoning 折叠显示。**中**。

**4.8 会话管理缺重命名与搜索**（ChatSessionStore 无 rename API，侧栏仅最近 50 条）→ 右键重命名 + 顶部搜索框。**中**。

**4.9 聊天/宠物文案中英硬编码混杂**：中文硬编码（`ChatView.swift:123-127`「搞定啦 ✨」等）与英文硬编码（417/665、slash 摘要 31-45、`PetView.swift:526`）并存。→ 全部走 L()（见主题 5）。**小**。

**4.10 宠物大小固定 250×400、位置不跨启动持久**（`PetPanel.swift:91,71-79`），且主窗口换屏会把宠物拽走覆盖手动摆放（215-227）。→ 设置加尺寸档位；frame 持久化并恢复；"跟随屏幕"做成可关。**中**。

**4.11 QuickChat 无 ↑ 历史召回；QuickChat 产生的会话不刷新已开聊天窗侧栏**（`QuickChat.swift:11-13` 注释已预期）→ 补 `↑` 召回 + ChatSessionStore 变更通知。**小**。

**4.12 贴纸与 3D 鼹鼠形象割裂 + 死代码**（`Stickers.swift:6-15,25-37`，sad/angry 从未使用）→ 换与 mole 一致的 2D 表情或删减。**小**。

### 主题 5：视觉体系——排版、色彩、材质、动效（P1–P2）

**5.1 排版体系失控（最大的"美观债"）**
- 量化：**185 处硬编码 `.system(size:)`**，分布 9pt×21、10pt×44、11pt×46、12pt×32、13×9、14×11、15×12、16×3、17×2…；而 Airi 字体 token 只有 3 个（30/14/12，`AiriTheme.swift:76-78`）。9-10pt 正文在 Retina 上已低于舒适可读下限（`HomeView.swift:141-147` 状态 chip 的 10pt/9pt 是重灾区）。
- 建议：建立完整字阶 token（caption2=10 / caption=11 / body=13 / emphasis=15 / title=17 / pageTitle=30，数字统一 `.rounded` + monospacedDigit），全项目替换；把 9pt 全部消灭。顺手支持 Dynamic Type（用 `@ScaledMetric` 包一层尺寸），无障碍受益（见主题 7）。工作量：**中（机械但量大，可分批）**。

**5.2 色值逃逸 token：Status 图表硬编码 hex**
- `OptimizeStatusPurgeViews.swift:112-119` 紫橙绿直接 `Color(hex: "8B5CF6")` 等 4 处，未走 Airi 语义色（成功/警告/主色都有现成 token），暗色下不会自适应。
- 建议：收进 token（如 `Airi.chart1..4` 双态定义）。工作量：**极小**。

**5.3 不透明底破坏玻璃层次**
- Clean 页 bottomBar 用实心 `Airi.neutral100`（`CleanView.swift:454`），在 vibrancy 窗底上形成一条实心带；与玻璃卡片语言冲突。搜索框描边 `lineWidth: 2`（`UninstallView.swift:178`）也偏重（全 app hairline 是 1）。
- 建议：bottomBar 改 `cardBackground`/材质 + 顶部 hairline；描边统一 1pt。工作量：**极小**。

**5.4 侧栏行无 hover 态**
- `sidebarRow`（`MoppetApp.swift:300-326`）只有 active 高亮，无 hover 反馈；macOS 列表惯例是 hover 浅填充。
- 建议：hover 时 `neutral100.opacity(0.6)` 填充。工作量：**极小**。

**5.5 图标细节**
- `pawprint.fill`（侧栏底栏）与整体 hierarchical 风格混用 filled；`trash.fill` vs `trash` 在卸载两处按钮并存（`UninstallView.swift:123,307-313`——主行动 filled、次行动 outline 是有意区分则可，但建议定成规则写进 Components 注释）。
- 建议：定一条"filled 仅用于当前主行动"的规则并全项目过一遍。工作量：**小**。

**5.6 动效参数一致性**
- 多处裸 `withAnimation {}` 用默认参数（`UninstallView.swift:160,390,427`、`AnalyzeView` 等），与 Airi.motion token（controlAnimation/cardAnimation/entranceCurve）并存。建议禁用裸调用，统一 token。**小**。
- 好的方面保持：入场 stagger、numericText、0.95 按压都已统一。

### 主题 6：本地化完整性（P1）

- 现状：L10n 机制健全（en 为源语言 + zh-Hans 表 + 设置内语言切换 + selfCheck），但覆盖率参差：**UninstallView 是重灾区**——"Select all"（103）、"Uninstalling…"/"Uninstall N apps"（121-122）、"✓ Moved to Trash: …"（133）、"sizing…"（227）、"✓ removed N system items"（385-387）、宠物播报 "Uninstalled N apps 🗑"（162,426）、页面副标题（33）全部裸英文；ChatView 则反向硬编码中文（123-127）。中文界面下这些直接穿帮。
- 建议：① 全量补 L()（半天机械活）；② 把 selfCheck 升级为扫描式断言：编译期 grep 报告裸 `Text("` 字面量清单进 smoke（可先 warning 后 error）；③ zh 表同步更新。工作量：**小-中**。

### 主题 7：无障碍与键盘可达（P2）

- **自定义 `.plain` 按钮无焦点环**：`AiriButton`/`CircleIconButton`/sidebarRow 全部 `.buttonStyle(.plain)`（`Components.swift:189,128`、`MoppetApp.swift:325`），Tab 键盘导航时看不到焦点位置；按压效果靠 DragGesture 模拟而非系统高亮。
- 9-10pt 字号 + glass 上的 `neutral500` 副文字在暗色下对比度偏低。
- 建议：① plain 按钮统一加 focusable 焦点环修饰（`.onHover` 已有，补 focus 效果即可）；② 字阶升级（5.1）顺带解决对比度；③ 关键列表加 `accessibilityLabel`（勾选框行把"名称+大小"读出来）。工作量：**中，可随 5.1 一起做**。

---

## 三、优先级路线图

### 第一批：Quick wins（每项 ≤ 半天，合计 2-3 天，收益立现）
| # | 事项 | 主题 |
|---|------|------|
| 1 | 卸载（批量/单+data）、History Clear、Analyze Trash、Optimize Run 补确认弹窗并统一范式 | 1.1-1.3 |
| 2 | Approve/Deny 按钮颜色拨正 | 1.4 |
| 3 | 扫描可取消 + 批量卸载进度（复用 AiriButton.busy） | 2.1, 2.4 |
| 4 | EmptyStateCard 组件 + 三个页面接入 | 2.2 |
| 5 | QuickChat 未配置预检 +「打开设置」；错误气泡带行动入口 | 4.1, 2.3 |
| 6 | 睡眠唤醒 + 双播报去重 + 双击提示 | 4.3, 4.4, 4.6 |
| 7 | "Hi Sean"/"Moley" 改读用户/宠物名；侧栏眼睛按钮状态修复 | 3.7 |
| 8 | cmd+, / cmd+F；@SceneStorage 路由记忆；侧栏分组+hover；bottomBar 玻璃化；图表 hex 收 token；裸 withAnimation 清零 | 3.3, 3.5, 3.1, 5.3, 5.2, 5.6 |
| 9 | Uninstall/Chat 硬编码文案全量 L() 化 | 6 |

### 第二批：体系化（各 1-3 天）
- **字阶 token 全量替换 + 消灭 9pt + Dynamic Type**（5.1 + 7）——本轮美观提升最大单项。
- **审查树 30 条上限改造**（1.5）+ UserInput 倒计时（1.6）。
- **宠物尺寸/位置持久化 + 跟随屏幕可关**（4.10）。
- **聊天：滚动跟随 + 回到底部、工具 chip 状态/耗时、输出展开、reasoning 折叠**（4.2, 4.7）。
- **设置页分区/锚点 + 设置内搜索**（3.6）。
- **Clean 主流程接入 PetBus + 完成触感**（2.5）。

### 第三批：体验进阶（按需）
- 首启三步引导卡（3.4）；会话重命名/搜索（4.8）；贴纸统一形象（4.12）；无障碍焦点环与标签（7）；QuickChat ↑ 历史 + 会话列表刷新（4.11）；长答案「在聊天中查看」（4.5）。

---

## 四、不建议做的事（对齐既有偏好，避免走回头路）

- ❌ 不要为了"更通透"再调 vibrancy/卡片透明度——0.7/0.6 组合是调试后的平衡点，再调会重蹈可读性覆辙。
- ❌ 不要 pin 浅色/暗色外观或加"主题切换"——跟随系统 + 动态 token 是定案。
- ❌ 不要把引擎层（Brain/SDK/MCP）作为"模式"暴露进 UI——继续保持"一个聊天窗，能力都在里面"。
- ❌ 不要用一次性大重构（如全部换 AppKit、引入第三方 UI 库）解决一致性问题——当前 SwiftUI + token 路线是对的，缺的是执行覆盖度。
