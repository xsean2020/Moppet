import Foundation

/// Lightweight i18n: keys are the English literals; `t()` maps them to the
/// active language. Language override persists in UserDefaults.
enum L10n {

    enum Language: String, CaseIterable, Identifiable {
        case system, english = "en", chinese = "zh-Hans"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .system: "System"
            case .english: "English"
            case .chinese: "中文"
            }
        }
    }

    static let languageKey = "app.language"

    static var current: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "system") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: languageKey) }
    }

    private static var resolvedCode: String {
        switch current {
        case .system:
            return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
        case .english: return "en"
        case .chinese: return "zh-Hans"
        }
    }

    static func t(_ key: String) -> String {
        resolvedCode == "zh-Hans" ? (zh[key] ?? key) : key
    }

    /// Forces the zh table to initialize and sanity-checks known mappings.
    /// A duplicate key in the literal traps at first init (Swift runtime) —
    /// calling this from SmokeTest surfaces that in CI instead of crashing
    /// the app on the user's first settings click.
    static func selfCheck() -> Bool {
        guard zh.count > 50 else { return false }
        return zh["Settings"] == "设置" && zh["Scan"] == "扫描"
            && zh["Permanent"] == "永久删除" && zh["Deleted items"] == "已删除项目"
            && zh["Select sessions"] == "多选会话"
    }
}

/// Convenience used across views: Text(L("Scan")).
func L(_ key: String) -> String { L10n.t(key) }

private let zh: [String: String] = [
    // uninstall batch + history source
    "+%lld more": "另 %lld 个",
    "Apps and their user data (preferences, caches, containers, saved state, logs…) are moved to the Trash together. Nothing is deleted permanently — you can restore from the Trash.": "App 与其用户数据（偏好设置、缓存、容器、恢复状态、日志等）会一起移入废纸篓。不会永久删除——可从废纸篓恢复。",
    "%1$@ apps · %2$@ data": "App %1$@ · 数据 %2$@",
    " · %lld leftover files": " · %lld 个残留文件",
    // dashboard lifetime stats
    "Cleaned so far": "累计清理",
    "Open the cleanup history": "打开清理历史",
    "Reading history…": "正在读取历史…",
    "No runs yet — your first clean will show up here.": "还没有清理记录——第一次清理后会出现在这里。",
    "%lld runs": "%lld 次清理",
    "%lld paths": "%lld 个路径",
    "last %@": "最近 %@",
    // scan-scope round (clean/quick scan must never widen)
    "%1$lld / %2$lld": "%1$lld / %2$lld",
    "%1$@ (%2$lld/%3$lld)": "%1$@（%2$lld/%3$lld）",
    "All items selected — click to clear": "已选全部——点击取消",
    "Some items selected — click to clear the section": "已选部分——点击清空该分区",
    "No items selected — click to select all": "未选——点击全选",
    "Scanned %1$lld categories · found %2$lld paths (%3$@)": "已扫描 %1$lld 个类别 · 找到 %2$lld 个路径(%3$@)",
    "%1$lld of %2$lld categories selected": "已选 %1$lld / %2$lld 个类别",
    "Nothing selected — open Clean and pick what to scan.": "没有选中任何项目——请到「清理」页勾选要扫描的内容。",
    // audit-round additions (agent/Brain + status + slim)
    "Uninstall %1$lld apps (%2$@)": "卸载 %1$lld 个应用(%2$@)",
    "Oops, error:": "哎呀，出错了：",
    "Needs your approval:": "需要你批准：",
    "loaded": "已加载",
    "Slimming": "正在瘦身",
    "Kill process (SIGTERM): %@ (pid %lld)?": "结束进程(SIGTERM)：%@（pid %lld）？",
    "Refusing to walk the whole disk / home folder": "拒绝扫描整个磁盘或整个主目录",
    "Unsaved work in that process is lost. System daemons refuse the signal (owned by root).": "该进程中未保存的工作会丢失；系统守护进程会拒绝信号（属 root）。",
    "Move to Trash failed:": "移到废纸篓失败：",
    "selected": "已选",
    "universal binaries": "个通用二进制",
    "Remove Intel code from universal apps (mo slim)": "移除通用应用中的 Intel 代码（mo slim）",
    "Live system health · uptime %@": "实时系统状态 · 已运行 %@",
    "Regenerable build artifacts in your project folders": "项目目录中可再生的构建产物",
    "Maintenance tasks — Finder, DNS, memory and stale state": "维护任务——访达、DNS、内存与过期状态",
    // navigation
    "Dashboard": "仪表盘", "Clean": "清理", "Uninstall": "卸载", "Optimize": "优化",
    "Analyze": "分析", "Status": "状态", "Purge": "项目清理", "History": "历史",
    "Settings": "设置",
    // dashboard
    "Moley · desktop pet": "Moley · 桌宠",
    "Show / hide the pet": "显示 / 隐藏宠物",
    "Quick Clean": "快速清理",
    "Scan caches, logs, dev artifacts & installers, then review": "扫描缓存、日志、开发产物与安装包，然后复查",
    "Start here": "从这里开始",
    "Ask the Brain": "问问大脑",
    "Uninstall Apps": "卸载应用",
    "Trash apps and sweep their leftovers": "移入废纸篓并清扫残留",
    "Purge Projects": "清理项目",
    "node_modules & friends across your code folders": "代码目录里的 node_modules 们",
    "chat sessions": "个聊天会话", "rollout JSONL history": "rollout JSONL 历史",
    "MCP server": "MCP 服务器", "AI not configured": "AI 未配置",
    "Settings → AI Provider": "设置 → AI 服务商",
    "Hi Sean 👋": "嗨 Sean 👋",
    "Moley is on the desktop. Everything below is previewed before anything is deleted.": "Moley 就在桌面上。以下所有操作都会先预览，确认后才删除。",
    "%@ used · %@ free of %@": "已用 %@ · 剩余 %@ / 共 %@",
    "Codex-style agent with shell, patches & cleaning tools": "Codex 风格智能体——可执行命令、打补丁、调用清理工具",
    "Add an API key in Settings to enable the agent": "在设置里添加 API Key 即可启用智能体",
    "tools": "个工具",
    // clean flow
    "Pick what to look for — nothing is deleted before you confirm": "选择要查找的内容——确认前不会删除任何东西",
    "Measuring candidates — read-only pass": "测量候选——只读扫描",
    "Deselect anything you want to keep, then clean": "取消勾选想保留的内容，然后清理",
    "Removing selected items": "正在移除所选内容",
    "Summary of this run": "本次运行汇总",
    "Scan": "扫描", "Rescan": "重新扫描",
    "Back to start": "回到开始", "Done": "完成",
    "locations": "个位置", "Scanning…": "扫描中…",
    "Review": "复查", "Cleaning": "清理中",
    "Installers and archives go to the Trash (recoverable); caches and logs are removed permanently.": "安装包与归档进废纸篓（可恢复）；缓存与日志将永久移除。",
    "Caches and logs are removed permanently. This cannot be undone.": "缓存与日志将永久移除，无法撤销。",
    "Remove %lld items (%@)?": "移除 %1$lld 项（%2$@）？",
    "Clean %@": "清理 %@",
    "%lld paths · %@": "%1$lld 个路径 · %2$@",
    "%@ across %lld paths": "%@ · 共 %lld 个路径",
    "%1$@ · %2$lld of %3$lld paths": "%1$@ · %2$lld/%3$lld 个路径",
    "%@ · %lld files": "%@ · %lld 个文件",
    "Trash-routed items are recoverable from the Trash": "进废纸篓的项目可从废纸篓找回",
    "Freed %@": "已释放 %@",
    "%lld items processed · %lld failed": "已处理 %1$lld 项 · %2$lld 项失败",
    "Recorded to history — %lld audited paths": "已记入历史——共审计 %lld 个路径",
    "operation failed": "操作失败",
    "%lld failed": "%lld 项失败",
    // analyze / status / purge
    "Expand folders to size them — tick paths to trash": "展开目录测量大小——勾选路径进废纸篓",
    "Move %lld to Trash": "移 %lld 项入废纸篓",
    "Measuring your home folder…": "正在测量主目录…",
    "sizing…": "测量中…",
    "Uninstall + data (%@)": "卸载并清数据（%@）",
    "Finding related files…": "正在查找相关文件…",
    "No user leftovers found.": "未发现用户级残留。",
    "Related user files": "相关用户文件",
    "Select an app to see its leftovers.": "选择应用查看残留。",
    "Run": "运行", "Reload": "刷新", "Clear": "清除",
    // history audit trail
    "Audit log of every clean run": "每次清理的审计日志",
    "No runs recorded yet — your first clean will show up here": "还没有清理记录——首次清理后会显示在这里",
    "runs": "次清理", "freed in total": "累计释放", "paths": "个路径",
    "failed": "失败", "Deleted items": "已删除项目",
    "Trash": "废纸篓", "Permanent": "永久删除",
    // permanent-delete round (Uninstall / Analyze no longer route through Trash)
    "Delete apps and sweep their leftovers": "删除应用并清扫残留",
    "Apps are deleted permanently (cannot be undone). Related files listed in the detail pane are NOT touched by batch uninstall.": "应用将被永久删除（无法撤销）；详情面板里列出的关联文件不会被批量卸载触及。",
    "Deleted": "已删除",
    "Delete %@ permanently?": "永久删除 %@？",
    "Delete %@ and its data permanently?": "永久删除 %@ 及其数据？",
    "Delete permanently": "永久删除",
    "The app is deleted permanently. This cannot be undone.": "应用将被永久删除，无法撤销。",
    "The app and its selected related files are deleted permanently. This cannot be undone.": "应用及其勾选的关联文件将被永久删除，无法撤销。",
    "%@ deleted": "已删除 %@",
    "%lld related files deleted": "已删除 %lld 个关联文件",
    "Expand folders to size them — tick paths to delete": "展开目录测量大小——勾选路径永久删除",
    "Delete %lld": "删除 %lld",
    "Delete %lld items (%@) permanently?": "永久删除 %lld 个项目（%@）？",
    "Items are deleted permanently. This cannot be undone.": "项目将被永久删除，无法撤销。",
    "Deleted %lld paths 🗑": "已删除 %lld 个路径 🗑",
    "Trash %@": "废纸篓 %@",
    // chat
    "Chats": "会话", "New chat": "新会话", "Delete session": "删除会话",
    "Delete chat?": "删除会话？",
    "Select sessions": "多选会话", "Delete chats?": "删除会话？", "Delete": "删除",
    "sessions · rollout JSONL": "会话 · rollout JSONL",
    "No sessions yet": "还没有会话",
    "Send": "发送", "Stop": "停止", "Cancel": "取消", "Save": "保存", "Add": "添加",
    // chat control-strip tooltips
    "AI provider — applies app-wide (Settings syncs)": "AI 厂商——全局生效（与设置页同步）",
    "Model — type a custom id in Settings → AI Provider": "模型——自定义 id 请到 设置 → AI 厂商 填写",
    "Approval — Ask always: confirm every command · On request: the model decides when to escalate · Never ask: auto-run": "审批——每次询问：每条命令都要确认 · 按需询问：模型自行判断何时征求批准 · 从不询问：自动执行",
    "Sandbox — Read-only · Workspace write: edits limited to the working directory · Full access (danger)": "沙箱——只读 · 工作区可写：仅限当前工作目录 · 完全访问（危险）",
    "Sandbox network — on: commands may reach the network in workspace-write; off: fully offline": "沙箱联网——开：工作区可写模式下命令可访问网络；关：完全离线",
    "Web search — server-side search on the ChatGPT backend (codex hosted web_search)": "网页搜索——ChatGPT 后端的服务端搜索（codex hosted web_search）",
    "Attach image (or drag & drop / paste)": "附加图片（也可拖拽 / 粘贴）",
    "attached image": "已附加图片",
    "A quick question": "一个小问题",
    "Quick question": "小问题",
    "Answer": "回答", "Skip": "跳过",
    "Answer in chat…": "去聊天窗回答…",
    // startup items
    "Startup": "启动项", "Enable": "启用", "Disable": "禁用",
    "user agent": "用户代理", "global agent": "全局代理", "daemon": "守护进程",
    "Needs an administrator password to change": "修改需要管理员密码",
    "Yours — no password needed": "你的项目——无需密码",
    // slim (mo slim parity)
    "Slim": "瘦身",
    "No universal apps with Intel code found": "没有发现含 Intel 代码的通用二进制应用",
    "Sign in with ChatGPT": "使用 ChatGPT 登录",
    "Waiting for authorization…": "等待授权…", "Waiting…": "等待…",
    // settings
    "Pet Identity": "宠物身份", "Name": "名字",
    "Save identity": "保存身份",
    "Codex Subscription (ChatGPT plan)": "Codex 订阅（ChatGPT 套餐）",
    "AI Provider": "AI 服务商", "Vendor": "厂商", "Model": "模型",
    "Test connection": "测试连接", "Saved ✓": "已保存 ✓",
    "Model list": "模型清单", "Refresh from API": "从 API 刷新", "Remove from list": "从清单移除",
    // provider cards (ZCode-style)
    "Provider Name": "Provider 名称", "Rename": "重命名",
    "Name already exists": "名称已存在", "Name cannot be empty": "名称不能为空",
    "New Provider": "新 Provider", "Active provider": "当前使用的 Provider",
    "Add model": "添加模型", "API format": "API 格式",
    "Show key": "显示密钥", "Hide key": "隐藏密钥",
    "No models configured — add one to use this provider in chat": "还没有配置模型——添加后即可在聊天中使用",
    "No custom providers yet": "还没有自定义 Provider",
    "Custom Providers": "自定义 Provider", "Add provider": "添加 Provider",
    "Edit provider": "编辑 Provider", "Delete provider": "删除 Provider",
    "Desktop Pet": "桌宠", "Launch at login": "开机自启",
    "Whitelist": "白名单", "Always protected": "始终保护",
    "Scan Result Cache": "扫描结果缓存", "Clear cache": "清除缓存", "entries": "条",
    "About": "关于",
    // uninstall
    "Select all": "全选", "Deselect all": "取消全选", "sizing": "测量中",
    "Uninstall (app only)": "卸载（仅应用）", "Search apps": "搜索应用",
    "System leftovers": "系统残留",
    "Remove system leftovers…": "移除系统残留…",
    // misc buttons
    "Quick Scan": "快速扫描", "Main Window": "主窗口", "Sleep": "睡觉", "Chat": "聊天",
    // menu bar extra / pet quick menu
    "Show / Hide Pet": "显示 / 隐藏宠物",
    "Open Main Window": "打开主窗口",
    "Open AI Chat": "打开 AI 聊天",
    "Quick Scan & Clean…": "快速扫描清理…",
    "Quit": "退出",
    "Quit %@ first?": "先退出 %@？",
    "Quit & Clean": "退出并清理",
    "Browser caches can only be cleared while the browser is closed — a running browser keeps rewriting them. Unsaved tabs/forms may be lost (most browsers restore tabs on relaunch).": "浏览器运行时无法彻底清理缓存——运行中的浏览器会持续重写缓存。未保存的标签页/表单可能丢失（多数浏览器重开后可恢复）。",
    "Double-click me to chat": "双击我直接聊天",
    "Login cancelled": "已取消登录",
    // quick chat on the pet
    "Ask me anything…": "问点什么…",
    "Approve": "批准", "Deny": "拒绝",
    "Thinking…": "思考中…",
    "Answers stream here · full history lives in the chat window": "回答会在这里流式显示 · 完整历史在聊天窗",
    "⏎ send · Esc close": "⏎ 发送 · Esc 关闭",
    "Provider": "服务商",
    "Close": "关闭",
    // codex login
    "Use device code instead": "改用设备码登录",
    "Browser opened — finish signing in, then come back…": "已打开浏览器——请在页面完成登录后回来…",
    // status / optimize / purge
    "Output": "输出", "Disk · %@": "磁盘 · %@", "Top processes": "进程资源占用",
    "Scanning project folders…": "正在扫描项目目录…", "Search roots": "搜索根目录",
    "%@ free": "%@ 可用",
    "Process data unavailable": "暂时拿不到进程数据",
    "%1$lld active · %2$lld disabled": "%1$lld 个启用 · %2$lld 个已禁用",
    "%lld Apple system items hidden": "已隐藏 %lld 个 Apple 系统项",
    "newer apps may register via System Settings → Login Items": "新应用可能通过 系统设置 → 登录项 注册",
    // startup
    "Scanning launch folders…": "正在扫描启动项…",
    "No third-party launch items found": "未发现第三方启动项",
    "How this works": "工作原理",
    "Each row is a launchd plist from ~/Library/LaunchAgents, /Library/LaunchAgents or /Library/LaunchDaemons. Disabling sets its Disabled flag (persistent) and unloads it right away — reversible, nothing is deleted. Global items need an administrator password. Apple system items are hidden (disabling boot daemons can wedge macOS).": "每一行对应 ~/Library/LaunchAgents、/Library/LaunchAgents 或 /Library/LaunchDaemons 中的一个 launchd 配置。禁用会写入 Disabled 标志（持久生效）并立即卸载——完全可逆，不删除任何东西。全局项目需要管理员密码。Apple 系统项已隐藏（禁用系统守护进程可能搞挂 macOS）。",
    // slim
    "Scanning applications…": "正在扫描应用…",
    "%1$lld selected · %2$@": "已选 %1$lld 个 · %2$@",
    "How slimming works": "瘦身原理",
    "Each selected app is copied, its Intel slices (x86_64/i386) removed with lipo, re-signed and code-signature-verified — only then does the original move to the Trash and the slimmed copy takes its place. App Store, Apple and running apps are never touched. An app update restores the Intel code. %@.": "每个选中的应用都会先复制副本，用 lipo 移除 Intel 切片（x86_64/i386），重签并校验代码签名——通过后原件才移入废纸篓、瘦身版就位。App Store、Apple 与运行中的应用绝不动。应用更新会带回 Intel 代码。%@。",
    "Intel code": "Intel 代码",
    "Slim %lld apps?": "瘦身 %lld 个应用？",
    "Intel slices (%@) will be removed from verified copies; originals move to the Trash as the rollback. Apps re-signed ad-hoc may ask for confirmation on first launch.": "将从校验通过的副本中移除 Intel 切片（%@）；原件移入废纸篓作为回滚保障。ad-hoc 重签的应用首次启动可能要求确认。",
    // chat transcript
    "writing": "写入中", "Other": "其他", "Plan": "计划", "output": "输出",
    "\"%@\" and its rollout history will be removed. This cannot be undone.": "“%@”及其 rollout 历史将被删除，无法撤销。",
    "type your own answer…": "输入自定义回答…",
    // settings
    "Persona · system prompt soul": "人设 · 系统提示词的灵魂",
    "Written to %@. Prepend-style: it becomes the first section of the agent's system prompt on every turn. Markdown supported.": "写入 %@。前缀式：它会成为每轮 agent 系统提示词的第一节。支持 Markdown。",
    "Takes effect immediately on visible texts.": "对界面文案立即生效。",
    "Sign in with your ChatGPT account (Plus/Pro/Team). A browser window opens auth.openai.com; the token is stored in the Keychain and the chat runs on the ChatGPT codex backend — no API key needed.": "用 ChatGPT 账号（Plus/Pro/Team）登录。将打开浏览器进入 auth.openai.com；令牌存入钥匙串，聊天运行在 ChatGPT codex 后端——无需 API Key。",
    "active · %@": "已启用 · %@",
    "Model list is empty — add an id or refresh from the API": "模型清单为空——添加 id 或从 API 刷新",
    "Powered by swift-ai-sdk — one agent, many vendors. Each provider keeps its own API key (stored in ~/.moppet/ai-keys.json, chmod 0600 — no keychain prompts); switching providers loads that provider's key.": "基于 swift-ai-sdk——一个智能体，多家厂商。各 Provider 的 API Key 独立保存（~/.moppet/ai-keys.json，权限 0600——不再弹钥匙串）；切换时自动载入对应 Key。",
    "ZCode-style: add any OpenAI-compatible endpoint (vLLM, LM Studio, one-api, new gateways). Config lives at ~/.moppet/ai-providers.json; each provider keeps its own key and model list. Names must be unique — duplicates are rejected.": "ZCode 式：添加任意 OpenAI 兼容端点（vLLM、LM Studio、one-api、各类新网关）。配置位于 ~/.moppet/ai-providers.json；每个 Provider 有自己的 Key 与模型清单。名称必须唯一——重名会被拒绝。",
    "Expose all %lld tools to external AI agents. Toggle runs an HTTP MCP server inside this app; clients connect over the network — no stdio wiring.": "把全部 %lld 个工具暴露给外部 AI 智能体。开关会在应用内启动 HTTP MCP 服务器；客户端经网络连接——无需 stdio 接线。",
    "or stdio: Moppet --mcp": "或 stdio：Moppet --mcp",
    "Heavy directory measurements are cached (3-day TTL, invalidated when a folder changes) — warm Analyze/Uninstall runs are instant.": "重型目录测量有缓存（3 天有效，目录一变即失效）——缓热后的分析/卸载瞬间完成。",
    "One glob per line. Matching paths are never scanned or deleted. Lines starting with # are ignored.": "每行一个 glob。匹配路径不会被扫描或删除。# 开头的行会被忽略。",
    "Regardless of whitelist or rules, this app refuses to delete anything outside your home directory and never touches:": "无论白名单或规则如何，本应用都拒绝删除主目录之外的任何内容，并且绝不触碰：",
    "Moppet 1.0 — a SwiftUI experiment pairing AIRI's design language with a mole-style cleaning engine. Clean previews everything before deleting; installers and archives are moved to the Trash.": "Moppet 1.0——AIRI 设计语言 × mole 式清理引擎的 SwiftUI 实验。清理前先完整预览；安装包与归档移入废纸篓。",
    "Saved": "已保存", "Save whitelist": "保存白名单", "Language": "语言",
    "Start Moley with your Mac (SMAppService)": "开机时随 macOS 启动 Moley（SMAppService）",
    "Run MCP server (HTTP)": "运行 MCP 服务器（HTTP）",
    "listening on %@": "监听中 %@", "stopped": "已停止",
    "MCP Server": "MCP 服务器",
    "Saved ✓ — applies to the next message": "已保存 ✓——下一条消息生效",
    "sk-… (optional for local servers)": "sk-…（本地服务可留空）",
    "model id, e.g. glm-4.6": "模型 id，如 glm-4.6",
    // protected categories
    "Preferences & safety configuration": "偏好与安全配置",
    "Keychains": "钥匙串", "Cookies": "Cookie", "Messages": "信息", "Mail": "邮件",
    "iCloud Drive": "iCloud 云盘", "Device Backups": "设备备份",
    "Group Containers": "群组容器", "Preferences": "偏好设置", "Accounts": "账户",
    "Safari Data": "Safari 数据", "Browser Profiles": "浏览器配置", "Login Items": "登录项",
    "Base URL": "接口地址（Base URL）", "API Key": "API Key",
    "Base URL (profile)": "接口地址", "API Key (profile)": "API Key",
    // MARK: v15.30 UX round
    // navigation / app chrome
    "System": "系统", "General": "通用", "All": "全部", "Size": "大小",
    "Settings…": "设置…",
    "%@ · desktop pet": "%@ · 桌宠",
    "Good morning": "早上好", "Good afternoon": "下午好", "Good evening": "晚上好",
    "%@ is on the desktop. Everything below is previewed before anything is deleted.":
        "%@ 就在桌面上。以下所有操作都会先预览，确认后才删除。",
    // clean flow
    "Nothing to clean": "没有可清理项",
    "The scan found no reclaimable space in the selected sections.": "所选分区里没有可回收的空间。",
    "Adjust selection": "调整选择",
    "Show less": "收起", "Show more": "展开",
    "Show all %lld paths": "显示全部 %lld 个路径",
    "Found %lld paths (%@)": "找到 %1$lld 个路径（%2$@）",
    "Nothing to clean ✨": "没有需要清理的 ✨",
    // uninstall
    "Move apps to the Trash and sweep their leftovers": "把应用移入废纸篓并清扫残留",
    "No apps installed": "没有已安装的应用",
    "No apps match your search": "没有匹配搜索的应用",
    "Try a shorter or different name.": "试试更短或别的名字。",
    "Clear search": "清除搜索",
    "Uninstall %lld apps (%@)?": "卸载 %1$lld 个应用（%2$@）？",
    "Uninstall %lld apps": "卸载 %lld 个应用",
    "Apps move to the Trash (recoverable). Related files listed in the detail pane are NOT touched by batch uninstall.":
        "应用将移入废纸篓（可恢复）。详情栏列出的关联文件不会被批量卸载处理。",
    "Uninstalling…": "卸载中…",
    "Moved to Trash": "已移入废纸篓",
    "Uninstalled %lld apps 🗑": "已卸载 %lld 个应用 🗑",
    "Uninstalled %@": "已卸载 %@",
    "%@ moved to Trash": "%@ 已移入废纸篓",
    "app removal failed": "应用移除失败",
    "%lld related files trashed": "%lld 个关联文件已入废纸篓",
    "removed %lld system items": "已移除 %lld 个系统级项目",
    // history / analyze
    "Clear all history?": "清空全部历史？",
    "All %lld run records are erased. This cannot be undone.": "将擦除全部 %lld 条运行记录，无法撤销。",
    "No runs recorded yet": "还没有运行记录",
    "Your first clean will show up here — every removed path is audited.": "第一次清理会显示在这里——每个被移除的路径都有审计。",
    "Start a clean": "去清理",
    "Move %lld items (%@) to Trash?": "把 %1$lld 项（%2$@）移入废纸篓？",
    "Move to Trash": "移入废纸篓",
    "Items go to the Trash and stay recoverable until it is emptied.": "项目将进入废纸篓，清空前都可恢复。",
    "Trashed %lld paths 🗑": "已把 %lld 个路径移入废纸篓 🗑",
    // optimize / purge
    "Run “%@”?": "运行“%@”？",
    "This maintenance task changes system state and will prompt for your administrator password.":
        "此维护任务会更改系统状态，并需要管理员密码。",
    "This maintenance task changes system state.": "此维护任务会更改系统状态。",
    "Purge %lld directories (%@)?": "清理 %1$lld 个目录（%2$@）？",
    "Build artifacts are regenerated on the next build — but deletion here is immediate and NOT routed through the Trash.":
        "构建产物会在下次构建时重新生成——但这里的删除是立即的，不经过废纸篓。",
    "Removed %lld directories · %@ freed": "已移除 %1$lld 个目录 · 释放 %2$@",
    "Found %lld artifact dirs (%@)": "找到 %1$lld 个产物目录（%2$@）",
    "No artifacts found ✨": "没有找到构建产物 ✨",
    "Purged %@": "已清理 %@",
    "Folder not found: %@": "找不到文件夹：%@",
    // pet
    "Awake! ✨": "醒啦！✨",
    "Wake": "唤醒",
    "Hi! I'm %@ 🦫 Click me to chat — double-click opens the full window.":
        "嗨！我是 %@ 🦫 点我聊天——双击打开完整窗口。",
    "Auto-dismisses after 5 minutes": "5 分钟后自动关闭",
    // quick chat
    "No AI provider configured yet — open Settings to add an API key or sign in.":
        "还没有配置 AI 服务商——请打开设置添加 API Key 或登录。",
    "%@ is chat-window only — double-click the pet to open it": "%@ 只能在聊天窗口使用——双击宠物打开",
    // chat window
    "set an API key in Settings": "请在设置里配置 API Key",
    "sandbox": "沙盒",
    "%lld sessions": "%lld 个会话", "recent %lld": "最近 %lld 条",
    "%lld chats and their rollout history will be removed. This cannot be undone.":
        "将删除 %lld 个聊天及其 rollout 历史，无法撤销。",
    "Chat with %@ — the desktop pet with a Codex-grade agent brain: shell, resumable exec, file patches, images, plans, cleaning tools, MCP. Type / for commands.":
        "和 %@ 聊聊——这只桌宠有 Codex 级的智能体大脑：shell、可恢复执行、文件补丁、图片、计划、清理工具、MCP。输入 / 查看命令。",
    "Chat with %@ — clean, build, fix, analyze…  ( / for commands )":
        "和 %@ 聊——清理、构建、修问题、分析…（输入 / 查看命令）",
    "export failed": "导出失败",
    "copied %lld chars": "已复制 %lld 个字符",
    "no assistant reply to copy yet": "还没有可复制的回复",
    "compacting…": "压缩中…",
    "%@ is chat-window only": "%@ 只能在聊天窗口使用",
    "(unreadable image)": "（图片无法读取）",
    "Turn cancelled": "回合已取消",
    "Back to bottom": "回到底部",
    "Reasoning": "思考",
    "Question timed out — no answer was sent.": "提问超时——没有发送任何回答。",
    // slash summaries
    "list commands": "列出命令",
    "session config + token usage": "会话配置与 token 用量",
    "connected MCP servers & tools": "已连接的 MCP 服务器与工具",
    "start a new chat": "开始新聊天",
    "summarize history to free context": "总结历史以释放上下文",
    "have the agent write AGENTS.md for this folder": "让智能体为此目录写 AGENTS.md",
    "git diff of the workspace": "工作区的 git diff",
    "print working directory": "打印工作目录",
    "/cd <path> — change working directory": "/cd <路径>——切换工作目录",
    "running exec sessions": "运行中的执行会话",
    "/stop [id] — stop exec sessions": "/stop [id]——停止执行会话",
    "export chat as Markdown": "把聊天导出为 Markdown",
    "copy last reply": "复制最后一条回复",
    // settings sections / pet card
    "Data & Safety": "数据与安全",
    "Small": "小", "Medium": "中", "Large": "大",
    "Follow window screen": "跟随窗口屏幕",
    "Move the pet to the display where the main or chat window lives — turn off to keep a hand-placed pet where you put it.":
        "把宠物移到主窗口或聊天窗口所在的显示器——关闭后手动摆放的宠物会留在原地。",
    // MARK: v15.32 startup-items round
    "Disabled": "已禁用", "Enabled": "已启用",
    "Kill": "结束进程",
    "Kill process (SIGTERM)": "结束进程（SIGTERM）",
    "Sent TERM to %@ (pid %lld)": "已向 %1$@（pid %2$lld）发送 TERM",
    "Could not kill pid %lld — owned by root?": "无法结束 pid %lld——可能是 root 进程？",
    "Measured %lld entries (%@)": "已测量 %1$lld 项（%2$@）",
    "Cleaning scope: %@": "清理范围：%@",
    "%lld items": "%lld 个条目",
    "%@ total": "共 %@",
    "Click to enter": "点击进入",
    "Nothing measurable in this folder": "这个文件夹里没有可测量的内容",
    "Disable login agents & daemons — stop background auto-starts": "禁用登录代理与守护进程——阻止后台自启",
]
