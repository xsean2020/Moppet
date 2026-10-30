# 脚本引擎热更新方案：JavaScriptCore + Agent 修复闭环

> 状态：设计完成，已验证可行性
> 日期：2026-10-29
> 核心结论：用 JavaScriptCore 嵌入 JS 脚本层，Agent 改脚本即修即生效，所有用户均可热更新，无需编译器

## 1. 背景与动机

### 1.1 问题

Moppet 是 Swift 编译型 macOS 应用。用户反馈 bug 后，需要开发者改源码 → 重新编译 → 发布新版本 → 用户下载更新，周期长且普通用户无法参与。

### 1.2 目标

- 用户反馈 bug → Agent 确认问题 → Agent 修改 → 热更新生效 → Git 记录版本
- 所有用户都能享受热更新（不需要安装 Swift 工具链）
- 支持修 UI bug、优化性能、增加新功能三种场景
- 自带 Git 版本管理，可追溯、可回滚

### 1.3 为什么选 JavaScriptCore

| 方案 | 热更新 | 需要编译器 | App Store | 复杂度 |
|------|--------|-----------|-----------|--------|
| 重启进程 + swift build | 闪退重启 | 是 | 可过审 | 低 |
| dylib 动态加载 | 不重启 | 是 | 过审困难 | 极高 |
| **JavaScriptCore** | **不重启** | **否** | **可过审** | **中** |

JavaScriptCore 是 Apple 原生框架（`import JavaScriptCore`），零第三方依赖，App Store 合规。JS 脚本是纯数据，改了即生效，普通用户也能热更新。

## 2. 验证结果

已编写完整验证程序（`/tmp/jsc_validation.swift`），覆盖五种场景：

| 场景 | 用户说 | Agent 改什么 | 效果 |
|------|--------|-------------|------|
| 优化删除速度 | "删除太慢" | JS 删除策略从逐个改批量 | 100 次调用→1 次调用，热更生效 |
| 增加新功能 | "帮我清 Docker" | 新增 JS 规则 + JS UI 卡片 | 新功能立即可用 |
| 修 UI bug | "滑块拖不动" | JS UI 描述去掉 `disabled` | 即修即生效 |
| 热加载 | — | 改 JS 文件 → JSContext 重新加载 | 不重启 App |
| 编排流程 | "一键清理" | JS 编排扫描→确认→删除→记录 | 完整流程可控 |

验证输出：
```
══ 场景 1：优化删除速度 ══
旧策略：100 次 native 调用（逐个删除）
新策略：1 次 native 调用（批量删除）
✅ Agent 改 JS 脚本即可优化删除策略，无需重新编译 Swift

══ 场景 2：增加新功能（Docker 清理）══
✅ Agent 通过新增 JS 脚本添加新功能，含规则逻辑 + UI 描述

══ 场景 3：修 UI bug ══
✅ Agent 改 JS UI 描述即修复 bug，无需重新编译

══ 场景 4：热加载验证 ══
✅ 脚本文件改了立即生效，无需重启 App

══ 场景 5：JS 编排复杂流程（扫描→确认→删除→记录）══
✅ JS 可编排完整流程：扫描→确认→删除→记录历史
```

## 3. 整体架构

```
Swift 编译层（不可热更，但极少变动）
├── ScriptEngine.swift           ← JSContext 管理、热重载
├── NativeBridge.swift           ← Swift 原生能力暴露给 JS
├── UIRegistry.swift             ← JS UI 描述 → 原生 SwiftUI 组件
├── DynamicView.swift            ← 动态视图渲染器
├── ScriptStore.swift            ← 脚本文件管理 + Git
├── ScriptSeeds.swift            ← 默认脚本种子
├── BrainAgent / BrainSandbox    （已有，不改动核心）
└── BrainTools.swift             （新增 update_script 工具）

JS 脚本层（可热更，Agent 改的就是这层）
├── ui/home.js                   ← 首页布局 + 数据展示逻辑
├── ui/clean.js                  ← 清理页面 + 删除策略逻辑
├── ui/settings.js               ← 设置页布局
├── ui/components.js             ← 公共 UI 组件描述
├── logic/clean_rules.js         ← 清理规则定义（可新增）
├── logic/formatters.js          ← 格式化逻辑
└── state/store.js               ← 共享状态管理

版本管理
├── ~/.moppet/brain/scripts/     ← 脚本文件存储
├── git init + 每次修改 commit    ← 版本记录
├── CanaryWatcher                ← 退化检测 + 自动回滚
└── HarnessSurface 白名单扩展    ← 安全边界
```

### 3.1 分层职责

| 层 | 职责 | 可热更 | 谁改 |
|----|------|--------|------|
| Swift 编译层 | 引擎壳、沙箱、安全、核心工具 | 否 | 开发者 |
| JS 脚本层 | UI 布局、业务逻辑、规则 | 是 | Agent（用户反馈驱动） |
| Git 版本层 | 版本快照、回滚、历史 | 是 | 自动 |

### 3.2 安全边界

| 层级 | 可改 | 不可改 | 验证方式 |
|------|------|--------|---------|
| JS 脚本 | UI 布局、显示逻辑、格式化、清理规则、清理策略 | BrainAgent、沙箱、审批、工具注册表、SafetyGuard | HarnessValidator + JSContext 异常捕获 |
| Swift 源码（开发者可选） | Views/、Theme/、Core/Modules/ | Brain/ 整个目录 | swift build + SmokeTest |

## 4. 详细设计

### 4.1 ScriptEngine — JSContext 管理器

```swift
import JavaScriptCore

/// JSContext 管理器：加载脚本、暴露原生能力、热重载
@Observable
final class ScriptEngine {
    static let shared = ScriptEngine()
    
    private var ctx: JSContext
    private var scriptPaths: [String: Date] = [:]  // 文件路径 → 修改时间
    
    var scriptRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moppet/brain/scripts")
    }
    
    private(set) var lastError: String?
    
    init() {
        ctx = JSContext()!
        ctx.exceptionHandler = { [weak self] _, exception in
            self?.lastError = exception?.toString()
        }
        registerNatives()
        loadAll()
    }
    
    /// 加载所有脚本文件（按 state → logic → ui 顺序）
    func loadAll() {
        guard FileManager.default.fileExists(atPath: scriptRoot.path) else {
            seedDefaults()
            return
        }
        loadDir("state")
        loadDir("logic")
        loadDir("ui")
    }
    
    /// 热重载：检测文件变化 → 重新加载
    func reloadIfChanged() {
        var changed = false
        let fm = FileManager.default
        guard let files = fm.enumerator(atPath: scriptRoot.path) else { return }
        while let file = files.nextObject() as? String {
            let path = scriptRoot.appendingPathComponent(file).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mod = attrs[.modificationDate] as? Date else { continue }
            if scriptPaths[path] != mod {
                changed = true
                scriptPaths[path] = mod
            }
        }
        if changed { loadAll() }
    }
    
    /// 调用 JS 函数，返回字典
    func call(_ fnPath: String, args: [Any]) -> [String: Any]? {
        guard let value = ctx.evaluateScript(fnPath) else { return nil }
        let result = value.call(withArguments: args)
        guard let result, result.isObject else { return nil }
        return result.toDictionary() as? [String: Any]
    }
    
    /// 执行一段 JS 代码（用于 Agent 测试）
    func eval(_ code: String) -> JSValue? {
        ctx.evaluateScript(code)
    }
    
    private func loadDir(_ dir: String) {
        let url = scriptRoot.appendingPathComponent(dir)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
        for file in files.sorted() where file.hasSuffix(".js") {
            let path = url.appendingPathComponent(file)
            if let content = try? String(contentsOf: path, encoding: .utf8) {
                ctx.evaluateScript(content)
                let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
                scriptPaths[path.path] = attrs?[.modificationDate] as? Date
            }
        }
    }
}
```

### 4.2 NativeBridge — 原生能力桥接

```swift
extension ScriptEngine {
    private func registerNatives() {
        // 删除能力（批量）
        ctx.setObject({ (paths: [String]) -> [String: Any] in
            CleanExecutor.batchDelete(paths: paths)
        } as @convention(block) ([String]) -> [String: Any],
        forKeyedSubscript: "nativeDelete" as NSString)
        
        // 安全检查
        ctx.setObject({ (path: String) -> Bool in
            SafetyGuard.checkDeletable(URL(fileURLWithPath: path)).allowed
        } as @convention(block) (String) -> Bool,
        forKeyedSubscript: "isSafe" as NSString)
        
        // 扫描能力
        ctx.setObject({ (pattern: String) -> [[String: Any]] in
            ScanEngine.scan(pattern: pattern)
        } as @convention(block) (String) -> [[String: Any]],
        forKeyedSubscript: "nativeScan" as NSString)
        
        // 磁盘信息
        ctx.setObject({ () -> [String: Any] in
            let snap = DiskInfo.snapshot()
            return [
                "total": snap.totalBytes,
                "free": snap.freeBytes,
                "used": snap.usedBytes,
                "usedFraction": snap.usedFraction,
            ]
        } as @convention(block) () -> [String: Any],
        forKeyedSubscript: "nativeDiskInfo" as NSString)
        
        // 历史记录
        ctx.setObject({ (record: [String: Any]) -> Void in
            HistoryStore.appendJS(record)
        } as @convention(block) ([String: Any]) -> Void,
        forKeyedSubscript: "nativeRecordHistory" as NSString)
        
        // 路由跳转
        ctx.setObject({ (route: String) -> Void in
            WindowRouter.shared.navigate(to: route)
        } as @convention(block) (String) -> Void,
        forKeyedSubscript: "navigate" as NSString)
    }
}
```

### 4.3 UIRegistry — JS UI 描述 → 原生 SwiftUI 组件

JS 脚本返回的是 UI 描述 JSON，Swift 侧用注册表映射到原生组件：

```swift
enum UIRegistry {
    typealias Builder = ([String: Any], UIContext) -> AnyView
    static var builders: [String: Builder] = [:]
    
    static func register() {
        builders["ScrollView"] = { node, ctx in
            AnyView(ScrollView {
                renderChildren(node["children"] as? [[String: Any]] ?? [], ctx)
            })
        }
        
        builders["VStack"] = { node, ctx in
            let spacing = node["spacing"] as? Double
            return AnyView(VStack(spacing: spacing.map(CGFloat.init)) {
                renderChildren(node["children"] as? [[String: Any]] ?? [], ctx)
            })
        }
        
        builders["HStack"] = { node, ctx in
            let spacing = node["spacing"] as? Double
            return AnyView(HStack(spacing: spacing.map(CGFloat.init)) {
                renderChildren(node["children"] as? [[String: Any]] ?? [], ctx)
            })
        }
        
        builders["Text"] = { node, ctx in
            let text = node["text"] as? String ?? ""
            let font = node["font"] as? String ?? "body"
            return AnyView(Text(text).font(fontMap[font] ?? .body))
        }
        
        builders["Card"] = { node, ctx in
            AnyView(SettingsCard {
                renderChildren(node["children"] as? [[String: Any]] ?? [], ctx)
            })
        }
        
        builders["Button"] = { node, ctx in
            AnyView(AiriButton(
                title: node["title"] as? String ?? "",
                icon: node["icon"] as? String,
                variant: variantMap[node["variant"] as? String ?? "primary"] ?? .primary,
                action: { ctx.dispatch(node["action"] as? String ?? "") }
            ))
        }
        
        builders["IconItemCard"] = { node, ctx in
            AnyView(IconItemCard(
                icon: node["icon"] as? String ?? "circle",
                title: node["title"] as? String ?? "",
                subtitle: node["subtitle"] as? String ?? "",
                metadata: node["metadata"] as? String,
                action: { ctx.dispatch(node["action"] as? String ?? "") }
            ))
        }
        
        builders["Toggle"] = { node, ctx in
            let key = node["key"] as? String ?? ""
            let disabled = node["disabled"] as? Bool ?? false
            return AnyView(ToggleRow(
                title: node["title"] as? String ?? "",
                isOn: ctx.binding(key)
            ).opacity(disabled ? 0.5 : 1))
        }
        
        builders["ProgressRing"] = { node, ctx in
            AnyView(ProgressRing(
                progress: node["progress"] as? Double ?? 0,
                showValue: node["showValue"] as? Bool ?? false,
                valueText: node["label"] as? String ?? ""
            ))
        }
        
        builders["BatchProgressOverlay"] = { node, ctx in
            let p = node["progress"] as? [String: Any] ?? [:]
            return AnyView(BatchProgressOverlay(
                progress: BatchProgress(
                    title: p["title"] as? String ?? "",
                    done: p["done"] as? Int ?? 0,
                    total: p["total"] as? Int ?? 0,
                    detail: p["detail"] as? String
                )
            ))
        }
        
        builders["Spacer"] = { _, _ in AnyView(Spacer()) }
        builders["Divider"] = { _, _ in AnyView(Divider()) }
    }
    
    static func render(_ node: [String: Any], context: UIContext) -> AnyView {
        let type = node["type"] as? String ?? "Text"
        let props = node["props"] as? [String: Any] ?? node
        guard let builder = builders[type] else {
            return AnyView(Text("⚠ Unknown: \(type)").foregroundStyle(.red))
        }
        return builder(props, context)
    }
    
    static let fontMap: [String: Font] = [
        "title": .system(size: 22, weight: .bold),
        "pageTitle": .system(size: 28, weight: .bold),
        "body": .system(size: 14),
        "caption": .system(size: 12),
        "caption2": .system(size: 11),
    ]
    
    static let variantMap: [String: AiriButtonVariant] = [
        "primary": .primary, "secondary": .secondary, "destructive": .destructive,
    ]
}
```

### 4.4 DynamicView — 动态视图渲染器

```swift
/// 渲染上下文：状态绑定 + 事件分发
@Observable
final class UIContext {
    var state: [String: Any] = [:]
    var route: (String) -> Void
    
    init(route: @escaping (String) -> Void) {
        self.route = route
    }
    
    func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { self.state[key] as? Bool ?? false },
            set: { self.state[key] = $0 }
        )
    }
    
    func dispatch(_ action: String) {
        if action.hasPrefix("navigate:") {
            route(String(action.dropFirst("navigate:".count)))
        } else {
            ScriptEngine.shared.call("onAction", args: [action])
        }
    }
}

/// 动态视图：用 JS 脚本渲染页面
struct DynamicView: View {
    let scriptPath: String  // e.g. "ui/home"
    let route: (String) -> Void
    
    @State private var context: UIContext
    @State private var node: [String: Any]?
    
    init(scriptPath: String, route: @escaping (String) -> Void) {
        self.scriptPath = scriptPath
        self.route = route
        _context = State(initialValue: UIContext(route: route))
    }
    
    var body: some View {
        Group {
            if let node {
                UIRegistry.render(node, context: context)
            } else {
                ProgressView()
            }
        }
        .onAppear { reload() }
        .onReceive(Timer.publish(every: 1, on: .main).autoconnect()) { _ in
            // 轮询脚本文件变化 → 热重载
            ScriptEngine.shared.reloadIfChanged()
            reload()
        }
    }
    
    private func reload() {
        if let result = ScriptEngine.shared.call(
            "\(scriptPath).render", args: [context.state]
        ) {
            node = result
        }
    }
}
```

### 4.5 默认脚本种子

```javascript
// ═══ state/store.js ═══
var state = {
    diskUsed: 0,
    diskFree: 0,
    diskTotal: 0,
    recentCleanups: 0,
    aiConfigured: false,
};

function get(key) { return state[key]; }
function set(key, value) { state[key] = value; }
function snapshot() { return Object.assign({}, state); }

// ═══ logic/clean_rules.js ═══
var CleanRules = {
    strategy: 'batch',  // 'batch' | 'individual'
    concurrency: 4,
    
    shouldDelete: function(finding) {
        if (!isSafe(finding.path)) return { delete: false, reason: 'blocked' };
        if (finding.bytes < 1024) return { delete: false, reason: 'too small' };
        return { delete: true };
    },
    
    execute: function(findings) {
        var toDelete = findings.filter(function(f) {
            return CleanRules.shouldDelete(f).delete;
        });
        
        if (CleanRules.strategy === 'batch') {
            var paths = toDelete.map(function(f) { return f.path; });
            var result = nativeDelete(paths);
            return { deleted: result.deleted, freed: result.freed };
        } else {
            var count = 0, freed = 0;
            toDelete.forEach(function(f) {
                var r = nativeDelete([f.path]);
                count += r.deleted;
                freed += r.freed;
            });
            return { deleted: count, freed: freed };
        }
    }
};

// ═══ ui/home.js ═══
function render(state) {
    var disk = nativeDiskInfo();
    var usedPct = Math.round(disk.usedFraction * 100);
    var usedGB = (disk.used / 1073741824).toFixed(1);
    var freeGB = (disk.free / 1073741824).toFixed(1);
    var totalGB = (disk.total / 1073741824).toFixed(1);
    
    return {
        type: "ScrollView",
        children: [{
            type: "VStack",
            props: { spacing: 12 },
            children: [
                {
                    type: "VStack",
                    props: { spacing: 4 },
                    children: [
                        { type: "Text", props: { text: "Dashboard", font: "pageTitle" } },
                        { type: "Text", props: { text: "Everything below is previewed before deletion.", font: "caption" } }
                    ]
                },
                {
                    type: "Card",
                    children: [{
                        type: "HStack",
                        props: { spacing: 16 },
                        children: [
                            { type: "ProgressRing", props: { progress: disk.usedFraction, showValue: true, label: usedPct + "%" } },
                            {
                                type: "VStack",
                                props: { spacing: 2 },
                                children: [
                                    { type: "Text", props: { text: usedGB + " GB used", font: "body" } },
                                    { type: "Text", props: { text: freeGB + " GB free of " + totalGB + " GB", font: "caption" } }
                                ]
                            }
                        ]
                    }]
                },
                {
                    type: "HStack",
                    props: { spacing: 8 },
                    children: [
                        { type: "IconItemCard", props: { icon: "sparkles", title: "Quick Clean", subtitle: "Scan caches, logs & artifacts", action: "navigate:clean" } },
                        { type: "IconItemCard", props: { icon: "brain", title: "Ask AI", subtitle: "Chat with the pet", action: "navigate:chat" } }
                    ]
                }
            ]
        }]
    };
}

// ═══ ui/clean.js ═══
function render(state) {
    var phase = state.phase || 'configure';
    
    if (phase === 'scanning') {
        return { type: "BatchProgressOverlay", props: { progress: { title: "Scanning…", total: 0 } } };
    }
    if (phase === 'cleaning') {
        var done = state.cleanDone || 0;
        var total = state.cleanTotal || 0;
        return { type: "BatchProgressOverlay", props: { progress: { title: "Cleaning", done: done, total: total } } };
    }
    
    var sections = state.sections || [];
    var cards = sections.map(function(sec) {
        return {
            type: "Card",
            children: [
                { type: "Text", props: { text: sec.title, font: "title" } },
                { type: "Text", props: { text: sec.subtitle, font: "caption" } }
            ].concat(sec.items.map(function(item) {
                return { type: "Toggle", props: { title: item.name, key: "item_" + item.id } };
            }))
        };
    });
    
    return {
        type: "ScrollView",
        children: [{
            type: "VStack",
            props: { spacing: 12 },
            children: cards.concat([
                { type: "Button", props: { title: "Scan", icon: "magnifyingglass", action: "scan" } }
            ])
        }]
    };
}

// ═══ ui/settings.js ═══
function render(state) {
    return {
        type: "ScrollView",
        children: [{
            type: "VStack",
            props: { spacing: 12 },
            children: [
                {
                    type: "Card",
                    children: [
                        { type: "Text", props: { text: "General", font: "title" } },
                        { type: "Toggle", props: { title: "Launch at login", key: "launchAtLogin" } },
                        { type: "Toggle", props: { title: "Scheduled clean", key: "scheduledClean" } }
                    ]
                },
                {
                    type: "Card",
                    children: [
                        { type: "Text", props: { text: "AI Provider", font: "title" } },
                        { type: "Text", props: { text: state.aiVendor || "Not configured", font: "caption" } },
                        { type: "Button", props: { title: "Configure", variant: "secondary", action: "navigate:aiSettings" } }
                    ]
                },
                {
                    type: "Card",
                    children: [
                        { type: "Text", props: { text: "Growth", font: "title" } },
                        { type: "Toggle", props: { title: "Enable learning", key: "growthEnabled" } },
                        { type: "Toggle", props: { title: "Enable self-modification", key: "evolveEnabled" } }
                    ]
                }
            ]
        }]
    };
}
```

### 4.6 HarnessSurface 白名单扩展

```swift
// HarnessSurface.swift 扩展

extension HarnessSurface {
    static let scriptExts = ["ui", "logic", "state"]
    
    // 在 isAllowed 中新增 JS 脚本路径白名单：
    // ui/*.js, logic/*.js, state/*.js
    //
    // if r.hasSuffix(".js") {
    //     let parts = r.split(separator: "/")
    //     if parts.count == 2, scriptExts.contains(String(parts[0])),
    //        isValidName(String(parts[1]).replacingOccurrences(of: ".js", with: "")) {
    //         return true
    //     }
    // }
}
```

### 4.7 BrainTools 新增 update_script 工具

```swift
// BrainTools.swift 新增工具

static let updateScriptSpec = Spec(
    name: "update_script",
    description: """
    更新 JS 脚本文件。用于修改 UI 布局、清理逻辑、新增功能。 \
    改了即热生效（无需重启 App）。路径必须在白名单内：\
    ui/*.js, logic/*.js, state/*.js。
    """,
    parametersJSONSchema: [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "脚本路径，如 ui/home.js"],
            "content": ["type": "string", "description": "完整的脚本新内容（不是 diff）"],
        ],
        "required": ["path", "content"],
    ],
    risk: .writeWorkspace
)

// dispatch 中新增 case：
// case "update_script":
//     return try await runUpdateScript(call, context: context)

private static func runUpdateScript(_ call: BrainToolCall, context: Context) async throws -> String {
    guard let args = BrainAgent.parseArgs(call.argumentsJSON),
          let path = args["path"] as? String,
          let content = args["content"] as? String else {
        throw BrainError("update_script: missing 'path' or 'content'")
    }
    // 白名单检查
    guard HarnessSurface.isAllowed(path) else {
        throw BrainError("update_script: path not on surface: \(path)")
    }
    // 写文件
    let target = ScriptEngine.shared.scriptRoot.appendingPathComponent(path)
    try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: target, atomically: true, encoding: .utf8)
    // 热重载
    ScriptEngine.shared.reloadIfChanged()
    // git commit
    _ = await BrainSandbox.run(
        command: "cd \(ScriptEngine.shared.scriptRoot.path) && git add -A && git commit -m 'update \(path)'",
        cwd: ScriptEngine.shared.scriptRoot.path,
        mode: .workspaceWrite,
        workspaceRoot: ScriptEngine.shared.scriptRoot.path,
        timeout: 10)
    return "success: \(path) updated and hot-reloaded"
}
```

### 4.8 路由集成

```swift
// MoppetApp.swift 路由层替换硬编码 View

// 旧：
// Route.clean → CleanView()
// Route.home → HomeView()
// Route.settings → SettingsView()

// 新：
Route.clean → DynamicView(scriptPath: "ui/clean", route: navigate)
Route.home → DynamicView(scriptPath: "ui/home", route: navigate)
Route.settings → DynamicView(scriptPath: "ui/settings", route: navigate)
```

## 5. Agent 修复闭环

### 5.1 完整流程

```
用户反馈："清理页面删除太慢了"
  │
  ▼
Agent（BrainAgent turn loop）：
  1. read_file "logic/clean_rules.js" → 看到 strategy: 'individual'
  2. update_script path="logic/clean_rules.js"
     content="... strategy: 'batch'; concurrency: 8; ..."
  3. 脚本文件写入磁盘 → ScriptEngine.reloadIfChanged() → 热生效
  4. git commit → "update logic/clean_rules.js"
  5. Agent 回复："已将删除策略从逐个改为批量并发，现在应该快多了"
  │
  ▼
用户：下次清理体验
  │
  ├── 体验改善 → CanaryWatcher 48h 通过 → 修改固化
  └── 体验退化 → CanaryWatcher 触发 → git revert → 自动回滚
```

### 5.2 三种场景的修复路径

#### 场景 A：优化删除速度

```
用户："删除太慢"
  ↓
Agent: read_file "logic/clean_rules.js"
  → 看到 strategy: 'individual'（逐个删除，100 次 native 调用）
  ↓
Agent: update_script "logic/clean_rules.js"
  → 改为 strategy: 'batch'（批量删除，1 次 native 调用）
  ↓
热生效：下次清理立即使用新策略
  ↓
git commit: "update logic/clean_rules.js"
```

#### 场景 B：增加新功能

```
用户："帮我清理 Docker 镜像"
  ↓
Agent: update_script "logic/docker_rules.js"
  → 新增 Docker 清理规则（扫描 dangling 镜像 + 删除策略）
  ↓
Agent: update_script "ui/clean.js"
  → 在清理页面新增 Docker 卡片（IconItemCard）
  ↓
热生效：清理页面立即出现 Docker 选项
  ↓
git commit: "add docker clean feature"
```

#### 场景 C：修 UI bug

```
用户："设置页面的滑块拖不动"
  ↓
Agent: read_file "ui/settings.js"
  → 看到 { type: "Slider", props: { disabled: true } }
  ↓
Agent: update_script "ui/settings.js"
  → 去掉 disabled: true
  ↓
热生效：设置页面滑块立即可拖动
  ↓
git commit: "fix settings slider disabled bug"
```

## 6. 版本管理与回滚

### 6.1 Git 集成

```swift
// 脚本目录初始化为 git 仓库
enum ScriptGit {
    static let repoRoot = "~/.moppet/brain/scripts"
    
    /// 初始化 git 仓库
    static func initRepo() {
        _ = BrainSandbox.run(
            command: "git init && git add -A && git commit -m 'initial seed'",
            cwd: repoRoot, ...)
    }
    
    /// 每次 update_script 后自动 commit
    static func commit(message: String) async {
        _ = await BrainSandbox.run(
            command: "git add -A && git commit -m '\(message)'",
            cwd: repoRoot, ...)
    }
    
    /// 查看修改历史
    static func log() async -> String {
        let result = await BrainSandbox.run(
            command: "git log --oneline -20",
            cwd: repoRoot, ...)
        return result.output
    }
    
    /// 查看 diff
    static func diff(from: String, to: String) async -> String {
        let result = await BrainSandbox.run(
            command: "git diff \(from) \(to)",
            cwd: repoRoot, ...)
        return result.output
    }
    
    /// 回滚到指定版本
    static func revert(to commitHash: String) async -> Bool {
        let result = await BrainSandbox.run(
            command: "git checkout \(commitHash) -- .",
            cwd: repoRoot, ...)
        return result.exitCode == 0
    }
}
```

### 6.2 CanaryWatcher 扩展

现有的 `CanaryWatcher` 已经有 canary → 评估 → 回滚的完整框架。扩展到脚本修改：

```
update_script → git commit → CanaryWatcher.begin(version, domain)
  ↓
后续 N 次使用中：
  - bad verdict 率 > 基线 + 20% → git revert → 自动回滚
  - 连续 2 次 bad → git revert → 自动回滚
  - 48h 无退化 → canary 通过 → 修改固化
```

## 7. 实施计划

| 阶段 | 文件 | 时间 | 产出 |
|------|------|------|------|
| P1 | `Script/ScriptEngine.swift` | 1-2 天 | JS 引擎可跑，原生桥接就位 |
| P2 | `Script/UIRegistry.swift` + `DynamicView.swift` | 1-2 天 | JS 能渲染原生 UI |
| P3 | `Script/ScriptSeeds.swift` | 1 天 | 三个页面有默认脚本 |
| P4 | `HarnessSurface.swift` + `BrainTools.swift` 扩展 | 半天 | Agent 可改脚本 |
| P5 | `MoppetApp.swift` 路由替换 | 1 天 | 现有页面跑在脚本上 |
| P6 | 端到端测试 | 半天 | 用户反馈→修复闭环跑通 |

总计约 **5-7 天**。

### 7.1 新增文件清单

```
Sources/Moppet/Script/
├── ScriptEngine.swift          ← JSContext 管理、热重载
├── NativeBridge.swift          ← Swift 原生能力暴露给 JS
├── UIRegistry.swift            ← JS UI 描述 → 原生 SwiftUI 组件
├── DynamicView.swift           ← 动态视图渲染器
├── ScriptStore.swift           ← 脚本文件管理 + Git
└── ScriptSeeds.swift           ← 默认脚本种子
```

### 7.2 修改文件清单

```
Sources/Moppet/Brain/Harness/HarnessSurface.swift   ← 白名单加 ui/*.js
Sources/Moppet/Brain/BrainTools.swift                ← 新增 update_script 工具
Sources/Moppet/Views/MoppetApp.swift                 ← 路由替换为 DynamicView
Sources/Moppet/Core/CleanExecutor.swift              ← 新增 batchDelete 入口
Sources/Moppet/Core/HistoryStore.swift              ← 新增 appendJS 入口
```

## 8. 安全设计

### 8.1 三层防线

1. **HarnessSurface 白名单**：JS 脚本只能写在 `ui/*.js`、`logic/*.js`、`state/*.js` 路径下，不可改 Swift 源码
2. **JSContext 沙箱**：JS 只能通过 `nativeDelete`、`nativeScan`、`isSafe` 等桥接函数调用原生能力，不能直接访问文件系统
3. **SafetyGuard 不变**：删除操作的最终安全检查仍然由 Swift 侧 `SafetyGuard` 把关，JS 无法绕过

### 8.2 不可修改的宪法层

以下文件 JS 脚本不可修改（`HarnessSurface` 白名单不包含）：

- `Sources/Moppet/Brain/` 整个目录（Agent 循环、沙箱、审批、工具注册表）
- `Sources/Moppet/Core/SafetyGuard.swift`
- `Sources/Moppet/Script/` 自身（脚本引擎不可自改）

## 9. 开发者双轨（可选）

对安装了 Swift 工具链的开发者，Agent 也能改 Swift 源码 + `swift build` 验证。这是额外能力，不是必须的：

```
开发者用户：
  Agent: apply_patch 改 Swift 源码 → shell "swift build" → 验证通过 → 重启 App

普通用户：
  Agent: update_script 改 JS 脚本 → 热生效 → 无需编译器
```

## 10. 验证程序

完整验证程序已保存至 `/tmp/jsc_validation.swift`，覆盖：
1. 优化删除速度（逐个→批量，100 次调用→1 次）
2. 增加新功能（新增 Docker 清理规则 + UI 卡片）
3. 修 UI bug（去掉 disabled 属性）
4. 热加载（JS 文件改了立即生效）
5. 编排复杂流程（扫描→确认→删除→记录历史）

运行：`swift /tmp/jsc_validation.swift`
