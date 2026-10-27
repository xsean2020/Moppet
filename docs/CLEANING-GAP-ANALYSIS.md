# Moppet 清理系统 · 功能缺口分析报告

> **版本**：2026-10-27 · **对象**：Moppet（Swift / SwiftUI + SceneKit，macOS 14+）
> **方法**：代码盘点（11 个模块 · 24 条 Clean 规则 · 8 个 Optimize 任务 · 21 类 Purge 产物 · 23 个 MCP 工具）+ 对标 mole / CleanMyMac / DaisyDisk / OnyX / AppCleaner 与 macOS 系统「存储空间」。
> **一句话**：Moppet 不缺「能清、敢清、可审计」，缺的是**清理覆盖面、空间洞察力、自动化和对普通用户的引导**。

---

## 一、结论先行

当前能力已经覆盖「缓存 / 日志 / 开发者产物 / 安装包 / 卸载 / 项目产物 / 二进制瘦身 / 启动项」这条主链路，安全模型（25 类保护路径、白名单、审批、逐路径审计）也是同类里最扎实的。

但和「一个完整的清理系统」相比，最关键的 5 个缺口是：

| # | 缺口 | 为什么重要 |
|---|---|---|
| 1 | **系统级空间大户没覆盖**：APFS/Time Machine 本地快照、iOS 备份、Mail/信息附件、Docker、Homebrew 旧版本 | 这些往往是单机几十 GB 的来源，现在一条规则都没有 |
| 2 | **大文件 / 重复文件没有 UI** | 只有 MCP 工具 `find_large_files`，普通用户在界面里看不到 |
| 3 | **全盘访问（Full Disk Access）没有引导** | 没授权时扫描「看起来是空的」，用户会以为软件坏了 |
| 4 | **没有计划 / 自动清理** | 清理是一次性手动动作，无法「低于 X% 自动清」 |
| 5 | **空间可视化只有气泡图** | 缺 treemap、文件类型分布、最大文件榜、可清除空间分类汇总 |

---

## 二、现状盘点（已有能力）

| 模块 | 能力 | 删除方式 |
|---|---|---|
| **Clean** | 4 分区 24 条规则（系统与用户 / 开发者 / 浏览器 / 安装包） | 缓存/日志永久删；安装包/归档进废纸篓 |
| **Uninstall** | 应用列表 + 关联残留 + 系统级残留（admin） | 永久删除（带确认） |
| **Optimize** | 8 个任务：重启 Finder/Dock、刷 DNS、重建 Spotlight、purge 内存、网络卷 .DS_Store、30 天+ Saved State、健康报告 | 不改用户数据 |
| **Startup** | LaunchAgents / LaunchDaemons 启停 | 写 Disabled + `launchctl bootout`（可逆） |
| **Analyze** | 目录列表 + 气泡图 + 逐层测量 | 永久删除（带确认） |
| **Status** | CPU / 内存 / 网络 / 电池 / Top 进程 / uptime | 仅 SIGTERM |
| **Purge** | 21 类可再生产物（node_modules、target、build、.next、.gradle、Pods、`__pycache__`…） | 永久删除 |
| **Slim** | 剥离通用二进制 Intel 切片 + 重签名（仅 Apple Silicon） | 原件进废纸篓、失败回滚 |
| **History** | 逐路径审计（路径、字节、方式、成败） | 只读 |
| **Settings** | AI 供应商、宠物、白名单、语言、缓存、MCP | — |
| **Brain / MCP** | 23 个工具，stdio + 回环 HTTP，外部 AI 可驱动 | 同一套安全门控 |

**安全层**：家目录限制、25 类保护路径、白名单（含子树）、符号链接解析、删除前复检、逐路径审计、AI 删除必审批。

---

## 三、缺口分析（按维度）

> 优先级：**P0** = 直接影响「能不能清干净 / 用户敢不敢用」；**P1** = 明显提升体验；**P2** = 锦上添花。

### A. 清理覆盖（最实质的缺口）

| 缺口 | 现状 | 影响 | 建议实现 | 优先级 |
|---|---|---|---|---|
| **APFS / Time Machine 本地快照** | 无 | 常见 10–100 GB，磁盘「已用」却看不到文件 | `tmutil listlocalsnapshots /` 报告；`tmutil deletelocalsnapshots <date>` 删除（需明确警告）；或 `tmutil thinlocalsnapshots / <bytes> 4` | **P0** |
| **iOS / iPadOS 备份** | `MobileSync/Backup` 在保护名单，完全不碰 | 旧 iPhone 备份动辄 20–80 GB | 只读报告大小 + 「在 Finder 中管理备份」跳转；不直接删 | **P0** |
| **Mail / 信息 附件** | `Library/Mail`、`Library/Messages` 受 TCC 保护 | 邮件附件常年几十 GB | 只读统计 + 跳转；不自动删（TCC 也不允许） | P1 |
| **Docker** | 无 | `Docker.raw` / `vms` 常见几十 GB | `docker system df` 报告 + `docker system prune`（需用户确认，会停容器） | **P0** |
| **Homebrew 旧版本** | 只清 `~/Library/Caches/Homebrew/*` | Cellar 旧版本、旧 bottle 残留 | `brew cleanup -n` 预览 + `brew cleanup` 执行 | **P0** |
| **系统日志** | 只清 `~/Library/Logs` | `/var/log`、`/Library/Logs` 长期膨胀 | admin 执行 `rm` 指定子目录（白名单限定），或 `log erase` | P1 |
| **Xcode 模拟器设备** | 只清 `CoreSimulator/Caches` | `xcrun simctl delete unavailable` 可回收数 GB | 调 `simctl` 列出 unavailable 设备并删除 | P1 |
| **语言资源裁剪（.lproj）** | Slim 只剥 Intel 切片 | 多语言 app 可再瘦 20–40% | 删除非当前语言的 `.lproj` + 重签名（会破坏签名，需谨慎） | P2 |
| **浏览器隐私数据** | 只清缓存子树，cookie/历史/下载记录不碰 | 想清隐私的用户没有入口 | 独立「隐私清理」入口 + 强警告（会登出） | P2 |
| **大归档（.zip/.tar/.7z）** | 安装包只覆盖 dmg/pkg/iso | 下载目录里的大压缩包漏掉 | 并入「大文件」清理（按大小 + 年龄） | P1 |
| **孤立残留（app 已删、残留还在）** | Uninstall 只针对「已安装 app」 | 手动拖走的 app 残留永远清不掉 | 扫描 `~/Library/{Caches,Preferences,Containers,Application Support}` 中无对应 app 的 bundle id | **P0** |
| **空目录 / 零字节文件** | 无 | 长期积累的噪声 | 可选规则（低风险，默认关） | P2 |
| **字体缓存 / LaunchServices 重建** | Optimize 无 | 字体/打开方式异常时的维护手段 | `atsutil databases -remove`（需 admin）、`lsregister -kill -r -domain local -domain user` | P2 |
| **照片 / 音乐缓存** | 无 | Photos/Music 缓存可数 GB | 只读报告 + 可选清理（注意 iCloud 同步） | P2 |

### B. 空间分析与可视化

| 缺口 | 现状 | 建议 | 优先级 |
|---|---|---|---|
| **Treemap / 旭日图** | 只有气泡图 | 增加 treemap（面积=大小、可下钻），比气泡更易读 | P1 |
| **文件类型分布** | 无 | 按扩展名/类别（视频/图片/文档/代码/归档）聚合饼图或条形 | P1 |
| **最大文件 Top N** | 只有 MCP `find_large_files` | 界面化：Top 100 大文件，可按大小/年龄筛选、直接删 | **P0** |
| **可清除空间分类汇总** | 无 | 首页一张卡：缓存 / 日志 / 快照 / 备份 / 废纸篓 / 大文件，各多少 | P1 |
| **跨卷 / 外置盘分析** | 只扫 home | 允许选择任意卷/目录 | P1 |
| **文件级下钻 + 排序过滤** | Analyze 只到目录层 | 文件级列表 + 排序/搜索 | P2 |
| **空间趋势 / 预测** | 无 | 记录每日可用空间，画趋势、预测「还能撑几天」 | P2 |

### C. 安全与权限

| 缺口 | 现状 | 建议 | 优先级 |
|---|---|---|---|
| **Full Disk Access 检测与引导** | 无（HANDOFF 已列为欠账） | 检测 `TCC.db` 可读性；未授权时在 Clean 顶部提示 + 一键打开系统设置 | **P0** |
| **TCC 权限说明** | 无 | 明确哪些路径需要 FDA（Mail/Messages/Safari 数据等） | P1 |
| **常驻 admin helper** | 每次 AppleScript 提权，反复弹密码 | 安装一次 SMJobBless helper，后续免密（复杂度高） | P2 |
| **删除前快照 / 撤销** | 除 Trash 路径外不可撤销 | 对永久删除提供「导出清单 + 可恢复副本」或 Time Machine 提示 | P2 |
| **干跑报告导出** | 只有界面预览 | 导出「将删除清单 + 预计释放」PDF/CSV | P1 |

### D. 自动化与计划任务

| 缺口 | 现状 | 建议 | 优先级 |
|---|---|---|---|
| **计划清理** | 无 | 每天/每周定时跑指定规则（LaunchAgent + 静默审批策略） | **P0** |
| **低空间自动清理** | 无 | 可用空间 < X% 时自动清缓存（只清安全项） | P1 |
| **登录时自动扫描** | 无 | 可选：登录后后台扫描并通知 | P2 |
| **清理后自动清空废纸篓** | 无 | 可选开关（默认关，永久化） | P2 |
| **规则到期提醒** | 无 | 「30 天没清理了」提醒 | P2 |

### E. 卸载与残留

| 缺口 | 现状 | 建议 | 优先级 |
|---|---|---|---|
| **孤立残留扫描** | 无（见 A） | 按 bundle id 反查无主残留 | **P0** |
| **批量卸载 + 关联数据** | 批量目前 `withData:false` | 批量也能带残留（逐个确认） | P1 |
| **卸载前退出运行中进程** | 无（浏览器清理已有此逻辑） | 卸载前检测并退出目标 app | P1 |
| **系统残留批量提权** | 逐个 AppleScript | 一次提权批量 `rm` | P2 |
| **应用更新器** | 无 | 检查 Homebrew/Sparkle 更新 | P2 |
| **登录项联动卸载** | Startup 独立 | 卸载时提示「还有 3 个登录项指向它」 | P2 |

### F. 报告与历史

| 缺口 | 现状 | 建议 | 优先级 |
|---|---|---|---|
| **历史导出** | 只读界面 | 导出 CSV / JSON / PDF | P1 |
| **趋势图** | 无 | 每次清理大小/时间折线 | P2 |
| **本次 vs 上次对比** | 无 | 「比上次多清了 1.2 GB」 | P2 |
| **按路径聚合 Top 空间** | 无 | 历史里「最常清 / 最大」的路径榜 | P2 |

### G. 性能与监控

| 缺口 | 现状 | 建议 | 优先级 |
|---|---|---|---|
| **菜单栏精简监控** | 只有图标菜单 | 菜单栏显示磁盘/CPU/内存小字（roadmap） | P1 |
| **磁盘空间告警** | 无 | 低于阈值通知 | P1 |
| **实时 I/O / 温度 / 风扇** | 无 | IOKit/SMC 读取 | P2 |
| **进程占用历史** | 无 | Top 进程时间序列 | P2 |

### H. Agent / MCP

| 缺口 | 现状 | 建议 | 优先级 |
|---|---|---|---|
| **长任务流式进度** | 工具一次性返回 | MCP progress notification | P2 |
| **工具级取消** | 无 | 支持 `notifications/cancelled` | P2 |
| **事务化批量** | 单工具调用 | 多工具原子执行 + 回滚点 | P2 |
| **资源订阅** | resources 只读 | 支持 subscribe/updated | P2 |

### I. UX / 可用性

| 缺口 | 现状 | 建议 | 优先级 |
|---|---|---|---|
| **首启引导** | 直接落 Dashboard | 3 步清单：授权 → 认识桌宠 → 第一次扫描 | P1 |
| **设置内搜索** | 单页长滚动 | 搜索框 + 分段 | P1 |
| **预计释放预览** | 有总大小，无「勾选即预览」 | 勾选时实时显示「将释放 X」 | P1 |
| **撤销上一步** | 无 | 对 Trash 路径提供「撤销」 | P2 |
| **文案本地化完整性** | 部分硬编码英文 | 全量 `L()` + 扫描断言 | P2 |
| **键盘可达性** | 部分有 | 全局快捷键面板 + 焦点环 | P2 |

### J. 分发与打包

| 缺口 | 现状 | 影响 | 建议 | 优先级 |
|---|---|---|---|---|
| **无 .app 包** | 裸 SPM 二进制 | IMK 日志、Gatekeeper、开机自启受限 | 提供打包脚本（`swift build` → 组装 `.app` + Info.plist） | P1 |
| **无签名 / 公证** | 无 | 分发给他人会被拦 | Developer ID 签名 + notarize | P2 |
| **无自动更新** | 无 | 版本分发靠手动 | Sparkle | P2 |
| **App Store 不可上架** | 已知（APPSTORE_PLAN） | — | 维持站外分发 | — |

---

## 四、与主流工具对比矩阵

| 能力 | Moppet | mole | CleanMyMac | DaisyDisk | OnyX | AppCleaner |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| 缓存/日志清理 | ✅ | ✅ | ✅ | — | ✅ | — |
| 应用卸载 + 残留 | ✅ | ✅ | ✅ | — | — | ✅ |
| 孤立残留扫描 | ❌ | ❌ | ✅ | — | — | ❌ |
| 开发者产物清理 | ✅ | ✅ | ✅ | — | — | — |
| 通用二进制瘦身 | ✅ | ✅ | ✅ | — | — | — |
| 大文件 UI | ❌ | ✅ | ✅ | ✅ | — | — |
| 重复文件 | ❌ | ❌ | ✅ | — | — | — |
| 空间可视化 | 气泡图 | 列表 | 环形 | **treemap** | — | — |
| 快照/备份清理 | ❌ | ❌ | ✅ | — | ✅ | — |
| Docker/Homebrew | 部分 | 部分 | ✅ | — | — | — |
| 启动项管理 | ✅ | ❌ | ✅ | — | ✅ | — |
| 系统监控 | ✅ | ✅ | ✅ | — | ✅ | — |
| 计划清理 | ❌ | ❌ | ✅ | — | — | — |
| AI Agent / MCP | **✅ 独有** | ❌ | ❌ | ❌ | ❌ | ❌ |
| 审批 + 逐路径审计 | **✅ 最完整** | 部分 | 部分 | — | — | — |
| 开源 / 本地 | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ |

> 注：「—」表示该工具不做这类功能；Moppet 的差异化优势是 **agent + MCP + 安全审计**，短板是**覆盖面与洞察**。

---

## 五、优先级路线图

### P0（建议下一版就做）
1. **Full Disk Access 检测 + 引导**（Clean 顶部横幅 + 跳系统设置）。
2. **孤立残留扫描**（app 已删、残留还在）。
3. **系统大户清理**：APFS/Time Machine 本地快照、Docker、Homebrew 旧版本、iOS 备份（只读+跳转）。
4. **大文件 UI**（Top N 大文件，按大小/年龄筛选）。
5. **历史/清单导出**（CSV/PDF）。
6. **计划清理**（每天/每周定时跑安全规则）。

### P1
- Treemap + 文件类型分布 + 可清除空间分类汇总。
- 批量卸载带残留；卸载前退出进程。
- 菜单栏精简监控 + 磁盘告警。
- 首启引导 + 设置内搜索 + 勾选实时预览。
- `.app` 打包脚本（顺带消掉 IMK 日志）。
- 系统日志、Xcode 模拟器设备、大归档。

### P2
- 重复文件、语言资源裁剪、隐私清理入口、字体缓存/LaunchServices 重建。
- 趋势图、本次 vs 上次、自动更新、常驻 admin helper。
- MCP 流式进度 / 取消 / 事务化。

---

## 六、风险与注意事项

| 动作 | 风险 | 缓解 |
|---|---|---|
| 删除本地快照 | 不可逆，可能影响 Time Machine 恢复点 | 明确警告 + 只删指定日期 + 先 dry-run |
| `docker system prune` | 会停容器、删未使用镜像 | 明确列出将删内容 + 二次确认 |
| `brew cleanup` | 删旧版本，回滚需重装 | 先 `-n` 预览 |
| 语言资源裁剪 | 破坏代码签名，app 可能无法启动 | 重签名 + 失败回滚（参考 Slim） |
| Mail/Messages 附件 | TCC 保护，越权访问会被拒 | 只读报告 + 跳转，不直接删 |
| 系统日志 | 需 admin，误删影响排障 | 白名单限定子目录 + 保留最近 N 天 |

---

## 七、附录：P0 落地要点

| 功能 | 落点 | 关键实现 |
|---|---|---|
| FDA 引导 | `Core/Permissions.swift` + `CleanView` 顶部 | 尝试打开 `~/Library/Application Support/com.apple.TCC/TCC.db`；失败→提示 + `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` |
| 孤立残留 | `Core/Modules/OrphanResidueEngine.swift` | 枚举 `~/Library/{Caches,Preferences,Containers,Application Support,LaunchAgents}` 的 bundle id，与 `/Applications` + `~/Applications` 的 app bundle id 求差集；经 `SafetyGuard` 过滤 |
| 本地快照 | `Core/Modules/SnapshotEngine.swift` | `tmutil listlocalsnapshots /` 解析；删除走 `tmutil deletelocalsnapshots` |
| Docker | `Core/Modules/DockerEngine.swift` | `docker system df --format json`；prune 需用户确认 |
| Homebrew | `Core/Modules/HomebrewEngine.swift` | `brew cleanup -n` 预览 → `brew cleanup` |
| 大文件 UI | `Views/LargeFilesView.swift` + `find_large_files` 工具复用 | 扫描 home（可配根目录），按大小排序，支持勾选删除 |
| 导出 | `HistoryStore` + `Views/HistoryView` | 序列化 `CleanRecord[]` 为 CSV/JSON；PDF 用 `ImageRenderer`/`NSPrintOperation` |
| 计划清理 | `Core/Scheduler.swift` + LaunchAgent | 写 `~/Library/LaunchAgents/com.moppet.schedule.plist`，触发 `--brain-exec` 或专用无头入口 |

---

*本报告基于当前代码状态（`main`，2026-10-27）与公开产品能力整理；具体实现前建议先补 `--smoke` 断言与安全层复检。*
