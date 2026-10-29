import Foundation

/// The P1 seed: five skills distilled from failures this app already paid for
/// (design doc §5.4), plus the tool-guidance and memory-index files.
///
/// These are **not new advice** — they are the lessons currently buried in
/// `HANDOFF.md`, which no model can read. Turning them into skills is pure gain.
enum HarnessSeeds {

    static let toolGuidance = """
    # 工具指引

    何时用哪个工具：
    - 清理：先 `scan_clean`（**必须**带 sections/items），展示结果，用户同意后再 `execute_clean`。
    - 卸载：`list_apps` → `uninstall_app` → `app_related_files` 核对残留。
    - 分析：`analyze_disk` / `find_large_files` / `scan_space_hogs`，只读，可自由调用。
    - 瘦身：`scan_slim` → `slim_apps`（Intel 机上禁用，见 `slim-gate` 技能）。
    - 启动项：`scan_launch_items` → `set_launch_item_enabled`。
    - 工程产物：`find_project_artifacts` → 用户确认 → `purge_artifacts`。
    - 记忆与技能：用户提到长期偏好时用 `recall`；情形匹配下面任一条时用 `use_skill(name)`。

    可用技能（需要时调用 use_skill(name)）：
    \(skillsPlaceholder)
    """

    static let skillsPlaceholder = "{{skills}}"

    static let memoryIndex = """
    # 记忆索引

    （暂无记忆。需要时用 recall 查询。）
    """

    static let skills: [Skill] = [
        Skill(
            name: "cleanup-scope",
            description: "用户指定清理范围（\"只清浏览器\"/\"别动 Docker\"）时，如何把范围翻译成工具参数",
            body: """
            1. 从用户话里抽出三样东西：类别（browsers / dev / caches / logs …）、排除项、应用名或 vendor。
            2. `scan_clean` 的 `sections` / `items` **必须显式传**。两个都不传等于全盘扫描——这是禁止的，
               哪怕用户只说"清理一下"。用户没说范围时，先问一句，或传一个明确的保守子集并说明。
            3. 输出第一行必须回报实际范围，例如：`扫描范围：browsers（Safari, Chrome）；排除：Docker`。
            4. 用户点名的类别匹配不到任何 id 时：**报错并列出可用 id**，绝不静默扩大范围。
            5. 用户说"别动 X"时，X 同时进排除项与白名单（`whitelist_add`），这样下次不用重复交代。
            """
        ),
        Skill(
            name: "uninstall-residue",
            description: "卸载应用后如何核对残留，避免只删 .app 留下缓存与 LaunchAgent",
            body: """
            1. `list_apps` 找到目标，确认 bundle id 与显示名（两者都要，残留目录常按其中一个命名）。
            2. `uninstall_app` 执行卸载。
            3. `app_related_files` 复核：按 **bundle id 与显示名双键**扫描，而不是只按名字。
            4. 报告分三段：已删除、仍需确认、明确保留（用户数据目录默认保留，除非用户要求清）。
            5. 残留里有 `~/Library/LaunchAgents/*.plist` 时提醒用户：下次登录可能仍会拉起。
            """
        ),
        Skill(
            name: "dev-artifacts",
            description: "判断哪些构建产物可以安全删除，避免误删源码或误留垃圾",
            body: """
            1. `find_project_artifacts` 先扫描，**不要**用 shell 自己找目录。
            2. 只有这些算安全：`build/`、`DerivedData/`、`node_modules/`、`target/`、`dist/`、`*.xcarchive`、
               `__pycache__/`、`.pytest_cache/`。
            3. 永不删除：`.git/`、任何源码、`Podfile.lock` / `Package.resolved` 之类的锁文件、
               用户未提交的工作区改动。
            4. 删除前逐项列出大小与路径，等用户确认；`purge_artifacts` 只传用户确认过的项。
            5. 项目在 iCloud / 外置盘时先提醒：重建会重新下载，可能比省下的空间更贵。
            """
        ),
        Skill(
            name: "slim-gate",
            description: "瘦身（剥离二进制）前的硬门禁：Intel 机上必须拒绝，否则会\"成功\"剥出废件",
            body: """
            1. 先确认架构：`shell` 跑 `uname -m`（或读 `system_status`）。**`x86_64` 一律拒绝瘦身**——
               这条门禁是硬的，不是建议：Intel 机上剥离会产出无法启动的应用，而流程仍报成功。
            2. Apple Silicon（`arm64`）上：`scan_slim` 列出候选与可回收空间。
            3. 只对用户**点名确认**的应用执行 `slim_apps`；一次不超过 3 个，便于回退。
            4. 报告必须给出：瘦身前大小、瘦身后大小、以及"如何恢复"（重装 / App Store 重新下载）。
            5. 任何签名校验失败的应用，跳过并说明，不要强行处理。
            """
        ),
        Skill(
            name: "approval-etiquette",
            description: "审批被拒绝或按 Esc 关闭后怎么处理——dismiss 即 deny，不要反复重试",
            body: """
            1. 用户关闭审批面板、按 Esc、或超时 = **拒绝**。不要把它当成"没看见"。
            2. 同一个破坏性调用**一轮内最多请求一次**。被拒后不要换个写法重试（那是绕过审批）。
            3. 被拒后回一句人话：说明你要做什么、为什么需要、以及有没有非破坏性的替代方案。
            4. 用户拒绝删除时，提供"只报告不删除"的路径：`scan_*` 展示，等用户自己动手。
            5. 连续两次被拒，停止该方向，改为询问用户希望怎么做。
            """
        ),
    ]

    /// Everything P1 adds to the tree. P0's two files stay in `PetHarness.seed`.
    static var tree: HarnessSurface.Tree {
        var out: HarnessSurface.Tree = [
            "tool_guidance.md": toolGuidance,
            "memory/INDEX.md": memoryIndex,
        ]
        for skill in skills {
            out[skill.path] = Frontmatter.render(fields: [
                ("name", skill.name),
                ("description", skill.description),
            ], body: skill.body)
        }
        return out
    }
}
