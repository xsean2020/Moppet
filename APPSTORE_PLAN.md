# Moppet 上架 Mac App Store 开发文档(待审核)

> 状态:**提案,未开工**。写于 2026-10-25,基于代码状态 v15.29 / 构建 0 错误 0 警告 / smoke 99 + brain-smoke 51 全绿。
> 审核通过前不做任何代码改动。本文档只回答一件事:**距离能上架还差什么、怎么做、付出什么代价、砍掉什么**。

---

## 0. 结论摘要(30 秒版)

1. **当前形态连"安装包"都不是**:Moppet 是 SPM 可执行目标(`swift run` 启动),没有 .app bundle、没有 Info.plist、没有 entitlements、没有签名。上架第一步是工程化(Xcode app target),这是纯机械工作,无风险。
2. **真正的硬门槛是 App 沙盒**:Mac App Store 强制要求 `com.apple.security.app-sandbox`。沙盒内**物理上不可能**做提权清理(全版本:不能以管理员身份运行任何命令、不能 killall 其他进程、不能写 /Library、不能改写其他 App 的二进制)。这不是审核松紧问题,是操作系统直接拒绝。
3. **因此必须做"双版本"决策**:MAS 版是一个功能精简、靠用户授权(拖拽/文件夹授权)工作的沙盒 App;完整版继续走 Developer ID + 公证(App Store 之外分发)。业界先例:MacPaw 的 CleanMyMac 在 MAS 上就是沙盒精简版;FreeMacSoft 的 AppCleaner 因沙盒冲突干脆不上 MAS。
4. **Brain 的命令执行(exec/shell)不能进 MAS 版**:审核条款 2.5.2 禁止 App 执行会改变自身功能的代码,AI 生成的任意 shell 命令属于高危拒审点;且沙盒内写入路径全部重定向到容器,exec 功能实际上也会残废。聊天/解释/生成清理建议可以保留。
5. **总量估算**:MAS 版改造 ≈ **2–4 周净工作量**(工程化 2–4 天 + 沙盒化引擎改造 5–10 天 + 合规材料 2–3 天 + 提交与 1–3 轮审核往返),另需 Apple Developer 账号 $99/年。详细分阶段计划见 §7。

**等待你决策的问题在 §9**(账号类型、产品名、是否双轨、MAS 版功能取舍、定价)。

---

## 1. 现状盘点(对照上架要求逐项打分)

| 项 | 现状 | MAS 要求 | 差距 |
|---|---|---|---|
| 构建产物 | SPM 可执行文件(`swift run`) | 标准 .app bundle + Info.plist | ❌ 需建 Xcode app target |
| 沙盒 | 无 entitlements | `app-sandbox` 强制 | ❌ 需新增,且是所有功能改造的根源 |
| 签名 | 未签名(ad-hoc) | App Store 分发签名 + Profile | ❌ 需开发者账号 |
| Hardened Runtime | 无 | 必须 | ❌(Xcode 配置项) |
| App 图标 | 无 xcassets | 1024pt 图标必需 | ❌ 需设计/导入 |
| 隐私清单 | 无 PrivacyInfo.xcprivacy | required-reason API 必须申报 | ❌ 我们大量用文件时间戳/磁盘空间 API |
| 最低系统 | macOS 14+ | 兼容即可 | ✅ |
| 通用二进制 | 本机架构构建 | arm64 + x86_64 双架构 | ❌ xcodebuild 构建时解决 |
| 登录启动 | SMAppService(现代 API) | 沙盒内正是官方推荐方式 | ✅ |
| 本地化 | L10n 中英文 | 可选,加分项 | ✅ |
| Keychain 存 AI key | KeychainAccess | 沙盒内可用 | ✅(需 team 前缀 provisioning) |
| 开源合规 | airi MIT / codex Apache-2.0 借鉴,mole 零复制 | 需随包附许可声明 | ⚠️ 加一个"开源致谢"页面即可 |

### 1.1 各引擎与沙盒的兼容性矩阵(核心事实表)

| 引擎/功能 | 沙盒内可行性 | 处置 |
|---|---|---|
| UninstallEngine(全盘搜索残留→删除) | ⚠️ **受限可行** — 不能扫全盘,只能处理用户**拖入/授权**的 App 及其关联文件 | MAS 版重写为"拖拽授权"模式(见 §4.2) |
| OptimizeEngine 中 `requiresAdmin` 任务(purge/mdutil/dscacheutil…,走 NSAppleScript 提权) | ❌ 沙盒内 NSAppleScript 提权直接失败 | 砍掉,移入完整版 |
| OptimizeEngine 非 root 任务(killall Finder 等) | ❌ 沙盒内不能向其他进程发信号 | 砍掉,移入完整版 |
| LaunchItemsEngine(扫 LaunchAgents/Daemons + plutil 写 + launchctl bootout) | ❌ 容器外路径不可读写;系统域提权不可用 | **整体砍掉**,移入完整版 |
| SlimEngine(lipo 瘦身其他 App + 重签名 + 替换) | ❌ 物理不可能 + 直接违反审核条款(改写其他 App) | **整体砍掉**,仅完整版保留 |
| Brain:apply_patch / exec / sandbox(Seatbelt) / unified_exec | ❌ 2.5.2 高危 + 沙盒内路径全重定向 | **MAS 版编译剔除**(见 §4.6) |
| Brain:聊天、规划、解释清理结果、生成操作单 | ✅ 纯网络请求 + UI | 保留 |
| MCP HTTP 服务器(app 内开关) | ⚠️ 可行,需 `network.server` entitlement;工具集随引擎缩水 | 保留但工具数减少 |
| AI Providers(9 厂商自定义)/ ChatGPT 订阅 PKCE 登录 | ✅ 需 `network.client`;PKCE 回调 127.0.0.1 本地监听沙盒允许 | 保留 |
| `~/.moppet` 配置目录 | ⚠️ 沙盒内应迁入 App 容器 | MAS 版改用容器路径;LegacyMigration 仅完整版执行 |
| 3D 宠物 / 贴纸 / 磨砂 UI / Quick Chat 窗口 | ✅ 与沙盒无关 | 原样保留 |

> 关键认知:**沙盒不是"配置一下就过"的开关,而是把 App 的文件系统视野锁进容器**。凡是"清理别人的东西"的功能,都只能在用户显式授权的范围内做。这就是 CleanMyMac MAS 版功能弱于直装版的根本原因,没有绕过办法。

---

## 2. 三条可选路线对比(本次审核的核心决策)

| | A. 双轨(推荐) | B. 仅 MAS 精简版 | C. 仅 Developer ID(不上架) |
|---|---|---|---|
| 做法 | 同一代码库,两个构建目标:`#if APPSTORE` 编译剔除不兼容功能 | 只维护沙盒版,完整功能放弃 | 继续现状 + 公证分发 |
| 分发 | MAS + 官网直装 | 仅 MAS | 仅官网/GitHub |
| 用户信任 | MAS 背书 + 完整功能两头都有 | MAS 背书,功能口碑受损 | 无 MAS 背书,需自建更新机制 |
| 维护成本 | 双构建 + 功能矩阵文档(一次性建好,日常增量) | 最低 | 最低 |
| 审核风险 | MAS 版仍有拒审可能(见 §6) | 同左 | 无审核 |
| 额外工作量 | ≈ 双轨共享 85%,增量约 +15% | 基准 | ≈ 2–4 天(公证 + Sparkle 更新) |

**推荐 A**:代码库已有类似先例(SlimEngine 用运行时 sysctl 硬门控 Apple Silicon),把"能力开关"抽象成 `BuildCapabilities` 编译期常量即可干净分叉;两版本共享全部 UI / 聊天 / 宠物 / AI 代码。

---

## 3. Apple 侧硬性要求清单(2026 现行,全部要做)

1. **Apple Developer Program**:$99 USD/年。个人账号即可上架;公司名义需 DUNS 编码(申请约 1–4 周,建议尽早决定 §9.1)。
2. **Bundle ID 注册**:如 `cc.cleaner.moppet`(keychain service `cc.cleaner.ai` 与此兼容,不受影响)。
3. **App 沙盒 + 最小 entitlement 集**(MAS 版):
   - `com.apple.security.app-sandbox`(强制)
   - `com.apple.security.files.user-selected.read-write`(用户授权文件/文件夹 — 卸载引擎的命脉)
   - `com.apple.security.network.client`(AI 请求、PKCE 回调)
   - `com.apple.security.network.server`(MCP HTTP / PKCE 127.0.0.1 监听;如嫌敏感可砍,见 §4.7)
   - bookmarks.persistent(持久化用户的文件夹授权,避免每次重新授权)
   - **不加** any USB/device/camera/microphone 等,最小化审核面。
4. **Hardened Runtime**:Xcode 勾选,无例外豁免(不用 JIT/未签名插件)。
5. **PrivacyInfo.xcprivacy**:申报 required-reason API——文件时间戳(C617.1:向用户展示文件信息)、磁盘空间(E174.1:向用户展示磁盘占用)——以及数据收集类型(AI 聊天 = 用户内容发送第三方,见 §5)。
6. **审核条款红线**(与我们相关的):2.5.2(执行代码)、2.5.1(私有 API/未文档 API — 无)、2.4.5(改写其他 App — SlimEngine 命中)、5.1.1/5.1.2(数据收集同意与披露)、2.1(App Completeness — **审核员没有你的 AI key,必须提供无 key 可用的演示路径**,见 §6.4)。
7. **元数据**:名称、副标题、关键词、描述、分类(Utilities)、年龄分级(4+,无不良内容)、隐私政策 URL(**必需**,需一页网页)、支持 URL、版权行、截图(至少 1440×900,可选 1280×800 / 2560×1600)、开源致谢。
8. **出口合规**:仅 HTTPS 标准加密 → Info.plist 标 `ITSAppUsesNonExemptEncryption=false`,免逐案申报。
9. **定价**:免费或付费;付费需签付费协议 + 银行/税务信息(材料准备 1–2 天)。

---

## 4. 逐模块改造方案(MAS 版)

### 4.1 工程化(双版本共同的地基)【约 2–4 天】

- 新建 Xcode 工程 `Moppet.xcodeproj`,引用现有 `Cleaner/Sources/Moppet` 全部源码与 Resources(不搬文件,保留 SPM 目录结构;`swift run --smoke` 等开发流继续可用)。
- 两个 target:
  - **Moppet(MAS)** — entitlements 见 §3.3,`ACTIVE_COMPILATION_CONDITIONS = APPSTORE`。
  - **Moppet Full(Developer ID)** — 无沙盒 entitlements(仅 Hardened Runtime),走公证。
- Info.plist:`LSApplicationCategoryType=public.app-category.utilities`、`LSUIElement=false`、版本号规则(`CFBundleShortVersionString` 15.x + build 号递增)。
- 图标:1024pt App Icon xcassets(宠物形象是天然候选,需出一版正式图标)。
- 构建脚本:`xcodebuild -configuration Release` 通用二进制;完整版另加 `productbuild`/公证脚本。
- **验收**:`xcodebuild build` 两 target 0 错误;产物可在双架构 `lipo -info` 验证;完整版行为与现状完全一致(`--smoke` 99 项照跑)。

### 4.2 UninstallEngine → "拖拽授权"模式【约 3–5 天,工作量主体】

现状:全盘规则搜索 ~/Library 各处残留 → 删除。沙盒内全盘搜索不可行。

改造为 MAS 先例模式(参照 MAS 上的 App Cleaner 类 App):
1. 用户把 App **拖入窗口**(拖拽 = powerbox 授予该 .app 的访问权),或 NSOpenPanel 选择。
2. 残留搜索范围 = **用户一次性授权的目录集合**(引导式:首次使用时弹 OpenPanel 请用户授权 `~/Library/Application Support`、`Caches`、`Preferences` 等 3–5 个目录,security-scoped bookmark 持久化,之后不再重复询问)。
3. 授权目录内照常复用现有规则库/白名单/SafetyGuard 逻辑(这部分代码 100% 保留)。
4. 未授权目录的残留 → 列为"建议手动处理",附 Finder 定位按钮(沙盒允许 `NSWorkspace.activateFileViewerSelecting`)。
- **产品话术**:把"深度清理"变成"在你授权范围内深度清理"——这也是 CleanMyMac MAS 版的真实形态。
- **验收**:卸载一个真实 App(如wechat),授权目录内残留全中;重启后授权仍有效;未授权路径不崩溃且有指引。

### 4.3 OptimizeEngine【约 1 天】

- MAS 版 catalog 里 `requiresAdmin=true` 的任务全部不显示;非 root 但需跨进程操作的(killall Finder)同样隐藏——沙盒内会失败。
- 保留可用项:清自己容器缓存、DNS 无关的用户级建议项(重新筛选 catalog,预计 MAS 版剩 2–4 项或暂隐藏整个路由 → **§9.4 决策点**)。
- **验收**:MAS 版无任何会静默失败的按钮;完整版 catalog 与现状一致。

### 4.4 LaunchItemsEngine 与 SlimEngine【0 天 — 直接剔除】

- MAS 版整模块编译剔除(`#if !APPSTORE`),路由不注册(导航栏不出现"启动项";瘦身功能仅完整版有)。
- **验收**:MAS 版 Info 无相关路由/MCP 工具;完整版 v15.29 行为不变。

### 4.5 配置与存储迁移【约 1 天】

- MAS 版:配置根 = App 容器(`~/Library/Containers/cc.cleaner.moppet/Data`);不执行 LegacyMigration(旧 `~/.cleaner`→`~/.moppet` 迁移无法读容器外路径)。
- 首启提供"从旧版导入"入口:OpenPanel 选 `~/.moppet/ai-keys.json` 等文件导入(可选,第一期可不做,§9.5)。
- **验收**:MAS 沙盒版首启可完成 Provider 配置→聊天全链路(这是 §6.4 审核演示路径的一半)。

### 4.6 Brain 的 MAS 版边界【约 2 天】

- 编译剔除:exec / unified_exec / write_stdin / apply_patch 落盘执行 / Seatbelt sandbox(子进程写路径全进容器,功能无意义且撞 2.5.2)。
- 保留:聊天流、规划、web_search、request_user_input、会话管理、/compact、图片查看(只读)。
- 工具面同步收缩:ToolRegistry 在 MAS 构建下只注册沙盒可用工具;`--brain-exec`/`--mcp` CLI 模式仅完整版产物带。
- **验收**:MAS 版 brain-smoke 裁剪集通过(需新增一份 MAS 版断言清单,预计 ~35 项);聊天全链路真实 key 手测。

### 4.7 MCP 双通道【约 0.5 天】

- HTTP 服务器 + `network.server` 保留(127.0.0.1 监听);stdio 模式仅 CLI/完整版。
- 工具数从 23 缩至沙盒可用子集,`tools/list` 输出与实际能力一致(沿用 §6.22 严格匹配原则,不虚报)。
- **验收**:外部 MCP 客户端连 MAS 版 HTTP 端点,列出的工具全部可真实调用。

### 4.8 AI / Keychain / 登录项【约 0.5 天】

- KeychainAccess 在 MAS provisioning(Team 前缀 keychain-access-groups)下照常;AIProviders、PKCE 订阅登录原样。
- SMAppService 登录启动原样(v15 sidebar 性能陷阱的守则保持:不在 body 里调 `isEnabled`)。

---

## 5. 合规材料(代码之外,缺一不可)

1. **隐私政策页面**(必须可公开访问的 URL):说明 AI 聊天内容会发送至用户配置的第三方 AI 服务(OpenAI/Anthropic/… 各自政策链接)、收集项(AI 配置、聊天记录存本地、崩溃数据不收集)、联系方式、删除方式。**一页静态网页即可,可先挂 GitHub Pages。**
2. **App Store Connect 隐私营养标签**:申报"用户内容(聊天输入)→ 发送给第三方、与身份关联=否、用于 App 功能=是";不得申报为"不收集任何数据"(聊天上云是事实)。
3. **AI 功能首次使用同意弹窗**(审核 5.1.1 越来越看重):首次发起聊天时提示"对话将发送给你配置的 AI 服务商",设置里可关闭记忆。代码量小,建议进第一期。
4. **开源致谢页**:airi(MIT,贴纸/VRMA)、codex(Apache-2.0,协议参考)、swift-ai-sdk 等依赖许可全文。mole(GPL-3.0)**零代码复制**的声明写入开发备注以防审核问询。
5. **截图/预览**:3–5 张 1440×900(主清理页、宠物聊天、启动项仅完整版截图不放 MAS 商店页)、App 图标。

---

## 6. 审核风险登记表(按概率排序)

| # | 风险 | 概率 | 缓解 |
|---|---|---|---|
| 1 | **2.5.2 执行代码**(AI 生成 shell 执行残留) | 高(若带 exec 提审) | §4.6 编译剔除,提审包物理不含该代码路径 |
| 2 | **2.1 审核员无 AI key 无法体验** | 高 | 内置"演示模式":无 key 时可用只读演示数据 + 有限次数的官方演示 key 额度,或提供审核专用测试 key(App Review 信息栏填写) |
| 3 | 沙盒内触发隐藏权限 API 崩溃 | 中 | TestFlight 外测 20+ 人先跑一轮;`--smoke` 保留项全绿 |
| 4 | 名称/商标冲突("Moppet" MAS 检索) | 中 | 提交前 App Store Connect 名称查重;备选名 2 个(§9.2) |
| 5 | 5.1.1 数据披露不足 | 中 | §5.1–5.3 三件套齐全 |
| 6 | "清理工具"品类被要求说明删除范围 | 中 | App 描述明确"仅在你授权的文件夹内清理";演示视频佐证 |
| 7 | 付费协议/税务信息拖慢 | 低 | 若付费,提前 1 周办银行信息 |

---

## 7. 分阶段执行计划(审核通过后启动)

| 阶段 | 内容 | 净工期 | 出口验收 |
|---|---|---|---|
| M0 决策 | §9 全部问题拍板;开发者账号注册(公司则同步申请 DUNS) | 0.5 天(账号审批 Apple 侧 1–2 天,并行) | 决策记录写入本文档;账号可用 |
| M1 工程化 | §4.1 双 target + 图标 + 构建脚本 | 2–4 天 | 双 target Release 构建 0 错;完整版与 v15.29 行为一致 |
| M2 沙盒化 | §4.2–4.8 全部 | 6–9 天 | MAS 版真机全流程手测 + MAS 版 smoke 清单绿 |
| M3 合规 | §5 材料 + 隐私标签 + 截图 | 2–3 天 | App Store Connect 表单可提交态 |
| M4 内测 | TestFlight(自测 + 外测 10–20 人) | 3–5 天(含修复) | 无 P1/P2 缺陷 |
| M5 提审 | 提交 + 响应审核问题(预计 1–3 轮,每轮 1–3 天) | 1–2 周(含等待) | 过审上架 |
| 合计 | | **约 3–5 周日历时间**(净工作量 2–4 周) | |

持续运维(过审后):每次发版走 M4→M5 精简流程;完整版独立节奏。

---

## 8. 成本汇总

- Apple Developer Program:**$99/年**(两版本共用一个账号)。
- 域名 + 隐私政策/支持页托管:~$10/年(GitHub Pages 亦可 $0)。
- 图标设计:自制 $0(宠物形象改稿)或外包 $50–300。
- 人力:见 §7;无其他 license 费用(全部依赖 MIT/Apache)。

---

## 9. 待你决策的问题(审核此文档时请逐项表态)

1. **账号类型**:个人开发者(快,个人名义展示)vs 公司(需 DUNS + 法人信息,展示公司名)?→ 影响启动时间。
2. **产品名**:MAS 检索名用什么?"Moppet" 如撞名,备选?(建议给 2 个备选)
3. **路线**:确认走 §2 的 A 双轨?还是先只做 B(MAS 精简)验证市场?
4. **MAS 版功能取舍确认**:启动项管理、瘦身、深度清理、Brain exec **全部不进 MAS 版**——是否接受?(这是本文档最重要的取舍)
5. **旧数据导入**:MAS 版是否需要"从完整版导入 AI 配置"(§4.5,可选 +1 天)?
6. **定价**:免费 / 买断 / 订阅?(买断最省事;订阅需持续价值主张,AI 功能自带 key 的模式下订阅说服力弱)
7. **审核演示模式**(§6.2)选型:内置演示数据 / 审核专用 key / 两者都要。

---

## 附:本次调研依据

- Apple《App Review Guidelines》(2.5.2、2.4.5、5.1.x、MAS 沙盒强制):developer.apple.com/app-store/review/guidelines
- Apple《Submitting to the App Store》与《Upcoming requirements》:developer.apple.com/app-store/submitting
- 先例:CleanMyMac(MAS 沙盒精简版,apps.apple.com/us/app/cleanmymac/id1339170533)、App Cleaner - App Uninstaller(MAS 拖拽授权模式)、FreeMacSoft AppCleaner(因沙盒不上 MAS)
- 代码事实:`OptimizeEngine.shellWithAdmin` 为 NSAppleScript 提权;`SlimEngine` 改写并重签其他 App 二进制;`LaunchItemsEngine` 读写系统级 LaunchAgents/Daemons;构建形态为 SPM 可执行目标(无 bundle/entitlements)。
