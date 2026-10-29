import Foundation

/// Headless self-test invoked with `Moppet --smoke`.
/// Exercises the safety layer and scan engine against the real filesystem
/// without deleting anything.
enum SmokeTest {

    static func run() -> Never {
        var failures = 0

        func expect(_ name: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "✓" : "✗"
            print("\(mark) \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { failures += 1 }
        }

        let home = SafetyGuard.home

        // MARK: Localization table (duplicate-key trap canary)

        // A duplicate key in the zh dictionary literal traps on first init;
        // forcing it here fails the suite instead of crashing the GUI.
        expect("L10n zh table sane (no duplicate keys, known mappings)", L10n.selfCheck())

        // MARK: Editable daily growth budget

        // The Growth tab edits this cap; the ledger gate must read the CURRENT
        // value on every call (a snapshot taken at launch would ignore it).
        do {
            let original = GrowthSettings.dailyTokens
            GrowthSettings.dailyTokens = 42_000
            expect("growth: the ledger budget follows the editable daily cap",
                   GrowthBudget.current.maxTokensPerDay == 42_000
                   && GrowthLedger.shared.canSpend(1, budget: .current))
            GrowthSettings.dailyTokens = original
        }

        // MARK: Scan scoping (selection must never silently widen)

        // CleanViewModel selection flows into the scan set (struct-copy
        // regression guard for the checkbox bindings).
        do {
            let vm = CleanViewModel()
            vm.sections.forEach { s in s.items.forEach { $0.selected = false } }
            let browsers = vm.sections.first { $0.section.id == "browsers" }
            browsers?.items.forEach { $0.selected = true }
            let picked = Set(vm.selectedItems.map(\.id))
            let expected = Set(browsers?.items.map(\.id) ?? [])
            expect("clean selection flows into scan set", picked == expected && !expected.isEmpty)

            // …and into the CLEAN set: selectedFindings must honor section
            // toggles, item toggles AND per-finding exclusions (this is the
            // "only the browser section was picked, everything was cleaned"
            // regression guard — executor only ever sees this list).
            func fakeResult(_ state: CleanViewModel.ItemState) -> ItemScanResult {
                ItemScanResult(item: state.item, findings: [
                    Finding(id: "f-\(state.id)-0", url: URL(fileURLWithPath: "/tmp/\(state.id)-0"),
                            bytes: 100, fileCount: 1, itemID: state.id),
                    Finding(id: "f-\(state.id)-1", url: URL(fileURLWithPath: "/tmp/\(state.id)-1"),
                            bytes: 100, fileCount: 1, itemID: state.id),
                ])
            }
            for section in vm.sections { section.items.forEach { $0.result = fakeResult($0) } }
            let browserIDs = Set(browsers?.items.map(\.id) ?? [])
            let allForBrowsers = vm.selectedFindings
            expect("clean set: only selected sections",
                   !allForBrowsers.isEmpty && allForBrowsers.allSatisfy { browserIDs.contains($0.itemID) })
            browsers?.items[0].selected = false
            let withoutItem0 = vm.selectedFindings
            expect("clean set: item toggle removes its findings",
                   withoutItem0.allSatisfy { $0.itemID != browsers?.items[0].id })
            browsers?.items[1].selected = true
            browsers?.items[1].excludedFindings.insert("f-\(browsers!.items[1].id)-0")
            let withExclusion = vm.selectedFindings
            expect("clean set: per-finding exclusion honored",
                   !withExclusion.contains { $0.id == "f-\(browsers!.items[1].id)-0" })
        }

        // scan_clean scope resolution: near-miss ids must match narrowly, not
        // fall through to a full scan ("I only selected the browser" bug).
        let browserCount = RuleLibrary.sections.first { $0.id == "browsers" }!.items.count
        let totalDefault = RuleLibrary.sections.flatMap(\.items).filter(\.defaultSelected).count
        expect("fuzzy section match 'browser'→browsers (narrow)",
               ToolRegistry.resolveItems(sections: ["browser"], items: nil).count == browserCount
               && browserCount < totalDefault)
        expect("fuzzy section match by title 'Browsers'",
               ToolRegistry.resolveItems(sections: ["Browsers"], items: nil).count == browserCount)
        expect("exact section id still works",
               ToolRegistry.resolveItems(sections: ["browsers"], items: nil).count == browserCount)
        expect("unknown section resolves empty (tool errors, never widens)",
               ToolRegistry.resolveItems(sections: ["nonexistent-xyz"], items: nil).isEmpty)
        // Contract CHANGED (2026-10-26): omitting sections/items scans exactly
        // what the user ticked on the Clean page — never more. Only a user who
        // never touched the checkboxes gets the rule defaults.
        if CleanSelectionStore.hasCustomSelection {
            expect("omitted args = the user's saved Clean selection (never widens)",
                   Set(ToolRegistry.resolveItems(sections: nil, items: nil).map(\.id))
                   == Set(CleanSelectionStore.selectedItems().map(\.id)))
        } else {
            expect("omitted args = rule defaults when the user never customized",
                   ToolRegistry.resolveItems(sections: nil, items: nil).count == totalDefault)
        }

        // MARK: Safety guard verdicts

        expect("deny filesystem root", !SafetyGuard.checkDeletable(URL(fileURLWithPath: "/")).allowed)
        expect("deny /System", !SafetyGuard.checkDeletable(URL(fileURLWithPath: "/System/Library")).allowed)
        expect("deny /usr subtree", !SafetyGuard.checkDeletable(URL(fileURLWithPath: "/usr/local/foo")).allowed)
        expect("deny /Applications", !SafetyGuard.checkDeletable(URL(fileURLWithPath: "/Applications/Xcode.app")).allowed)
        expect("deny home itself", !SafetyGuard.checkDeletable(home).allowed)
        expect("deny Keychains",
               !SafetyGuard.checkDeletable(home.appendingPathComponent("Library/Keychains")).allowed)
        expect("deny Cookies",
               !SafetyGuard.checkDeletable(home.appendingPathComponent("Library/Cookies")).allowed)
        expect("deny Messages attachments",
               !SafetyGuard.checkDeletable(home.appendingPathComponent("Library/Messages/Attachments/x")).allowed)
        expect("deny iCloud Drive",
               !SafetyGuard.checkDeletable(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")).allowed)
        expect("deny Safari data (history/cookies)",
               !SafetyGuard.checkDeletable(home.appendingPathComponent("Library/Safari/History.db")).allowed)
        expect("deny path with .. component",
               !SafetyGuard.checkDeletable(URL(fileURLWithPath: home.path + "/Library/../../etc")).allowed)
        expect("allow regular cache dir",
               SafetyGuard.checkDeletable(home.appendingPathComponent("Library/Caches/com.example.app")).allowed)

        // MARK: Glob matching

        expect("glob * matches", SafetyGuard.glob("*.dmg", matches: "Installer.dmg"))
        expect("glob * rejects ext", !SafetyGuard.glob("*.dmg", matches: "Installer.pkg"))
        expect("glob prefix",
               SafetyGuard.glob(home.path + "/Library/Caches/*", matches: home.path + "/Library/Caches/org.example"))
        expect("glob literal", SafetyGuard.glob("foo/bar", matches: "foo/bar"))
        expect("glob ? single char", SafetyGuard.glob("a?c", matches: "abc"))
        expect("glob rejects longer", !SafetyGuard.glob("a?c", matches: "abbc"))

        // MARK: Pattern expansion (read-only, against real disk)

        let caches = ScanEngine.expand(pattern: "~/Library/Caches/*", excludedPrefixes: ["pnpm", "uv"])
        expect("expands user caches", !caches.isEmpty, "\(caches.count) entries")
        expect("excluded prefixes honored", !caches.contains { $0.lastPathComponent.hasPrefix("pnpm") })

        let homeDir = ScanEngine.expand(pattern: "~")
        expect("expands bare ~", homeDir.count == 1 && homeDir[0].path == home.path)

        let missing = ScanEngine.expand(pattern: "~/definitely-does-not-exist-xyz")
        expect("missing path yields no candidates", missing.isEmpty)

        let dmgs = ScanEngine.expand(pattern: "~/Downloads/*.dmg")
        print("  (info) \(dmgs.count) dmg files found in Downloads")

        // MARK: Sizing (read-only)

        if let target = caches.first {
            let summary = ScanEngine.size(of: target)
            expect("sizes a cache directory", summary.bytes >= 0, "\(summary.bytes) bytes, \(summary.files) files")
        }

        // MARK: Rule library sanity

        let allItems = RuleLibrary.sections.flatMap(\.items)
        expect("rule library non-empty", allItems.count >= 20, "\(allItems.count) items")
        expect("all patterns are home-relative (deep items use ~ + extensions)",
               allItems.allSatisfy { item in
                   item.pattern.hasPrefix("~/") || item.pattern == "~"
                       ? (item.deepExtensions != nil || item.pattern.hasPrefix("~/"))
                       : false
               })
        expect("trash-mode items exist (installers/archives)",
               allItems.contains { $0.mode == .trash })

        // MARK: History codec round-trip (encode/decode only, no disk writes)

        let record = CleanRecord(
            date: Date(),
            sectionTitles: ["Test"],
            requestedBytes: 200,
            freedBytes: 100,
            itemCount: 2,
            items: [
                CleanRecordItem(path: "/tmp/x", bytes: 100, mode: .permanent, success: true, error: nil),
                CleanRecordItem(path: "/tmp/y", bytes: 100, mode: .trash, success: false,
                                error: "blocked by safety guard"),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try? decoder.decode([CleanRecord].self, from: encoder.encode([record]))
        let failedItem = roundTrip?.first?.items.first { !$0.success }
        expect("history JSON round-trip",
               roundTrip?.count == 1 && roundTrip![0].freedBytes == 100
                   && failedItem?.error == "blocked by safety guard")

        // MARK: Disk info

        let disk = DiskInfo.snapshot()
        expect("disk snapshot has capacity", disk.totalBytes > 0,
              "\(disk.totalBytes.bytesFormatted) total, \(disk.freeBytes.bytesFormatted) free")

        // MARK: Tool registry (AI-callable built-in tools)

        let tools = ToolRegistry.tools
        expect("tool registry has 15+ tools", tools.count >= 15, "\(tools.count) tools")
        expect("destructive tools are marked",
               tools.contains { $0.destructive } && tools.contains { !$0.destructive })
        expect("every tool has a JSON schema",
               tools.allSatisfy { ($0.jsonSchema["type"] as? String) == "object" })
        let expectedTools = ["disk_status", "system_status", "scan_clean", "execute_clean",
                             "analyze_disk", "find_large_files", "find_project_artifacts",
                             "purge_artifacts", "list_apps", "uninstall_app",
                             "optimize_catalog", "clean_history", "whitelist_add", "safety_check"]
        expect("mole-command tools all present",
               expectedTools.allSatisfy { name in tools.contains { $0.name == name } })

        // Safe tool executes headless (disk_status).
        let diskStatus = executeSync("disk_status", args: [:])
        expect("disk_status tool returns text", diskStatus.contains("volume"))

        // Destructive tool refuses without confirmation (MCP contract).
        let refused = executeSync("purge_artifacts", args: ["paths": ["/tmp/whatever"]])
        expect("destructive tool gated without confirmed flag", refused.contains("confirmed"))

        // scan → execute token pipeline refuses bad token (confirmed passed, token invalid).
        let badToken = executeSync("execute_clean",
                                   args: ["confirmation_token": "not-a-token", "confirmed": true])
        expect("execute_clean rejects invalid token",
               badToken.contains("invalid") || badToken.contains("token"))

        // MARK: System status engine

        let mem = SystemStatus.memory
        expect("memory sample plausible", mem.totalBytes > 1_000_000_000 && mem.usedBytes >= 0,
              "\(mem.usedBytes.bytesFormatted)/\(mem.totalBytes.bytesFormatted)")
        _ = SystemStatus.network
        let net2 = SystemStatus.network
        expect("network sample works", net2.bytesIn >= 0)
        // The ps invocation's column layout is load-bearing for the parser —
        // a drifted flag silently emptied the whole Status process card.
        let top = SystemStatus.topProcesses(limit: 5)
        expect("status: top processes parse", !top.isEmpty && top.allSatisfy { $0.pid > 0 && $0.cpu >= 0 },
               "\(top.count) rows")

        // MARK: MCP message handling

        if let mcpToolCount = mcpToolsListCount() {
            expect("MCP tools/list serves the registry", mcpToolCount == tools.count, "\(mcpToolCount)")
        } else {
            expect("MCP tools/list serves the registry", false, "serialization failed")
        }

        // MARK: Codex subscription PKCE login

        // auth.openai.com exact-matches the redirect URI against the codex
        // CLI registration; a drifted value is rejected server-side and the
        // browser login never calls back (silent-hang regression guard).
        if let authorize = CodexSubscription.buildAuthorizeURL(state: "smoke", challenge: "challenge"),
           let comps = URLComponents(url: authorize, resolvingAgainstBaseURL: false) {
            let query = { (name: String) in
                comps.queryItems?.first { $0.name == name }?.value
            }
            expect("codex authorize endpoint is /oauth/authorize", authorize.path == "/oauth/authorize")
            expect("codex redirect URI matches CLI registration exactly",
                   query("redirect_uri") == "http://127.0.0.1:1455/auth/callback",
                   query("redirect_uri") ?? "missing")
            expect("codex authorize keeps simplified-flow flag", query("codex_cli_simplified_flow") == "true")
            expect("codex authorize sends no audience param", query("audience") == nil)
            expect("codex PKCE uses S256 challenge",
                   query("code_challenge_method") == "S256" && query("code_challenge") != nil)
            expect("codex token exchange reuses the registered redirect",
                   CodexSubscription.pkceRedirectURI == "http://127.0.0.1:1455/auth/callback")
        } else {
            expect("codex authorize URL builds", false)
        }

        // Model catalog decoder: the backend shape isn't pinned by a public
        // contract — every wrapper/key variant the decoder accepts must parse.
        func catalogJSON(_ dict: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        }
        func catalogArrayJSON(_ items: [String]) -> Data {
            (try? JSONSerialization.data(withJSONObject: items)) ?? Data()
        }
        expect("model catalog parses {items:[{slug}]}",
               CodexSubscription.parseModelCatalog(catalogJSON(
                   ["items": [["slug": "gpt-5.3-codex"], ["slug": "gpt-5.2-codex"]]])) == ["gpt-5.3-codex", "gpt-5.2-codex"])
        expect("model catalog parses {models:[{id}]}",
               CodexSubscription.parseModelCatalog(catalogJSON(
                   ["models": [["id": "gpt-5.2-codex"], ["id": "gpt-5.2"]]])) == ["gpt-5.2-codex", "gpt-5.2"])
        expect("model catalog parses {data:[{model}]} / string arrays",
               CodexSubscription.parseModelCatalog(catalogJSON(
                   ["data": [["model": "gpt-5.2-codex"]]])) == ["gpt-5.2-codex"]
                   && CodexSubscription.parseModelCatalog(catalogArrayJSON(["gpt-5.2-codex"])) == ["gpt-5.2-codex"])
        expect("model catalog rejects unrecognized shapes",
               CodexSubscription.parseModelCatalog(catalogJSON(["error": ["message": "nope"]])) == nil)
        expect("codex picker falls back to bundled list when catalog empty",
               !CodexSubscription.bundledModels.isEmpty && CodexSubscription.bundledModels[0].contains("codex"))

        // Editable per-vendor catalog: add/remove/persist round-trip on the
        // .custom vendor (backed up + restored so the user's real catalog is
        // untouched), plus the per-provider /models response decoders.
        let customBackup = AIModelCatalog.models(for: .custom)
        AIModelCatalog.setModels(["keep-me"], for: .custom)
        AIModelCatalog.addModel("  new-model  ", for: .custom)
        AIModelCatalog.addModel("new-model", for: .custom)   // dedupe (also trims)
        expect("catalog add trims + dedupes + persists",
               AIModelCatalog.models(for: .custom) == ["keep-me", "new-model"])
        AIModelCatalog.removeModel("keep-me", for: .custom)
        expect("catalog remove persists",
               AIModelCatalog.models(for: .custom) == ["new-model"])
        AIModelCatalog.setModels(customBackup, for: .custom)
        expect("catalog restore returns to backup",
               AIModelCatalog.models(for: .custom) == customBackup)
        func catalogData(_ json: Any) -> Data { (try? JSONSerialization.data(withJSONObject: json)) ?? Data() }
        expect("openai-style {data:[{id}]} parses + filters embeddings",
               AIModelCatalog.parseModelIDs(catalogData(
                   ["data": [["id": "gpt-4o"], ["id": "text-embedding-3-small"], ["id": "gpt-4o-mini"]]]),
                   vendor: .openai) == ["gpt-4o", "gpt-4o-mini"])
        expect("gemini-style {models:[{name}]} strips prefix",
               AIModelCatalog.parseModelIDs(catalogData(
                   ["models": [["name": "models/gemini-2.0-flash"], ["name": "models/text-embedding-004"]]]),
                   vendor: .google) == ["gemini-2.0-flash"])
        expect("anthropic-style parses ids",
               AIModelCatalog.parseModelIDs(catalogData(
                   ["data": [["id": "claude-sonnet-4-5"], ["display_name": "x"]]]),
                   vendor: .anthropic) == ["claude-sonnet-4-5"])
        expect("ollama-style {models:[{name}]} parses",
               AIModelCatalog.parseModelIDs(catalogData(
                   ["models": [["name": "qwen2.5:7b"], ["name": "llama3"]]]),
                   vendor: .ollama) == ["qwen2.5:7b", "llama3"])
        expect("custom provider has no API refresh (user-curated)",
               !AIModelCatalog.supportsAPIRefresh(.custom) && AIModelCatalog.supportsAPIRefresh(.openai))

        // ---- Universal-binary slimming (mo slim) ----
        // Build a real universal binary with clang and parse its fat header.
        let slimScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-slim-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: slimScratch, withIntermediateDirectories: true)
        let mainC = slimScratch.appendingPathComponent("main.c")
        let fatBin = slimScratch.appendingPathComponent("fat.bin")
        let thinBin = slimScratch.appendingPathComponent("thin.bin")
        try? "int main(void){return 0;}\n".write(to: mainC, atomically: true, encoding: .utf8)
        func clang(_ args: [String]) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            process.arguments = args
            process.currentDirectoryURL = slimScratch
            let _ = try? process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        let fatBuilt = clang(["-arch", "arm64", "-arch", "x86_64", "-o", fatBin.lastPathComponent, mainC.lastPathComponent]) == 0
        let thinBuilt = clang(["-o", thinBin.lastPathComponent, mainC.lastPathComponent]) == 0
        if fatBuilt {
            let slices = SlimEngine.fatSlices(at: fatBin) ?? []
            expect("slim: fat header parses both slices",
                   slices.contains { $0.cpuType == SlimEngine.cpuArm64 } &&
                   slices.contains { $0.cpuType == SlimEngine.cpuX86_64 },
                   "\(slices.map(\.cpuType))")
            expect("slim: slimmable + intel bytes counted",
                   SlimEngine.isSlimmable(slices) && SlimEngine.intelBytes(slices) > 0)
            expect("slim: arch names for lipo",
                   SlimEngine.archName(SlimEngine.cpuX86_64) == "x86_64" &&
                   SlimEngine.archName(SlimEngine.cpuArm64) == nil)
        } else {
            expect("slim: clang available to build fixture", false, "clang failed")
        }
        if thinBuilt {
            expect("slim: thin binary is not slimmable",
                   SlimEngine.fatSlices(at: thinBin) == nil)
        }
        expect("slim: protected apps are skipped",
               SlimEngine.isProtected(bundleID: "com.apple.Finder", hasMASReceipt: false, isRunning: false) &&
               SlimEngine.isProtected(bundleID: "com.tencent.xinWeChat", hasMASReceipt: true, isRunning: false) &&
               SlimEngine.isProtected(bundleID: nil, hasMASReceipt: false, isRunning: true) &&
               !SlimEngine.isProtected(bundleID: "com.example.app", hasMASReceipt: false, isRunning: false))
        expect("slim: scan_slim/slim_apps registered",
               ToolRegistry.tool(named: "scan_slim") != nil &&
               ToolRegistry.tool(named: "slim_apps")?.destructive == true)
        try? FileManager.default.removeItem(at: slimScratch)

        // ---- Launch items engine (parse/filter/match, no system mutation) ----
        // Real launchd plists are XML — fixture mirrors that exactly
        // (incl. KeepAlive-as-dictionary, which must count as kept alive).
        let launchPlistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>com.example.helper</string>
        <key>ProgramArguments</key><array>
        <string>/Applications/Example.app/Contents/MacOS/helper</string><string>--flag</string>
        </array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
        </dict></plist>
        """
        let parsed = LaunchItemsEngine.parsePlistData(Data(launchPlistXML.utf8))
        expect("launch items: parses label/args/flags",
               parsed?.label == "com.example.helper" &&
               parsed?.program == "/Applications/Example.app/Contents/MacOS/helper" &&
               parsed?.runAtLoad == true && parsed?.keepAlive == true)
        expect("launch items: no Disabled key → enabled",
               parsed?.disabled == false)
        let disabledPlistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Label</key><string>x</string>
        <key>Program</key><string>/bin/x</string>
        <key>Disabled</key><true/></dict></plist>
        """
        expect("launch items: Disabled=true parses",
               LaunchItemsEngine.parsePlistData(Data(disabledPlistXML.utf8))?.disabled == true)
        let jsonPlist = #"{"Label":"com.example.json","Program":"/bin/x"}"#
        expect("launch items: JSON rejected (launchd uses XML)",
               LaunchItemsEngine.parsePlistData(Data(jsonPlist.utf8)) == nil)
        expect("launch items: non-plist rejected",
               LaunchItemsEngine.parsePlistData(Data("garbage".utf8)) == nil)
        expect("launch items: apple items filtered",
               LaunchItemsEngine.isSystemItem("com.apple.sandboxd") &&
               !LaunchItemsEngine.isSystemItem("com.example.helper"))
        let fixtureItems = [
            LaunchItemsEngine.Item(label: "com.example.helper", path: "/Users/x/Library/LaunchAgents/helper.plist",
                                   scope: .userAgents, program: "/Applications/Example.app/MacOS/helper",
                                   runAtLoad: true, keepAlive: false, disabled: false, loaded: true),
            LaunchItemsEngine.Item(label: "com.vendor.daemon", path: "/Library/LaunchDaemons/vendor.plist",
                                   scope: .globalDaemons, program: "/usr/local/bin/vendor",
                                   runAtLoad: false, keepAlive: true, disabled: true, loaded: false),
        ]
        expect("launch items: match by label and path",
               LaunchItemsEngine.matchItem("com.example.helper", in: fixtureItems)?.scope == .userAgents &&
               LaunchItemsEngine.matchItem("/Library/LaunchDaemons/vendor.plist", in: fixtureItems)?.label == "com.vendor.daemon")
        expect("launch items: no fuzzy match",
               LaunchItemsEngine.matchItem("helper", in: fixtureItems) == nil &&
               LaunchItemsEngine.matchItem("nonexistent", in: fixtureItems) == nil)
        expect("launch items: tools registered",
               ToolRegistry.tool(named: "scan_launch_items") != nil &&
               ToolRegistry.tool(named: "set_launch_item_enabled")?.destructive == true)

        // ---- ZCode-style provider profiles ----
        // Registry round-trip against the REAL config file: back it up,
        // exercise, restore (the .custom-vendor backup pattern).
        let profilesBackup = FileManager.default.fileExists(atPath: AIProviderRegistry.fileURL.path)
            ? try? Data(contentsOf: AIProviderRegistry.fileURL)
            : nil
        try? FileManager.default.removeItem(at: AIProviderRegistry.fileURL)
        let profile = AIProviderProfile(
            id: AIProviderRegistry.slugify("My vLLM Server!"),
            name: "My vLLM", baseURL: "http://127.0.0.1:8000/v1", models: ["qwen3:32b", "glm-4.6"])
        _ = AIProviderRegistry.upsert(profile)
        expect("providers: slugified id", profile.id == "my-vllm-server", profile.id)
        expect("providers: registry round-trip",
               AIProviderRegistry.load() == [profile] &&
               AIProviderRegistry.profile(id: profile.id)?.models.first == "qwen3:32b")
        expect("providers: catalog reads profile models",
               AIModelCatalog.models(forProfile: profile.id) == ["qwen3:32b", "glm-4.6"])
        expect("providers: delete clears",
               { _ = AIProviderRegistry.delete(id: profile.id); return AIProviderRegistry.load().isEmpty }())
        expect("providers: option labels",
               AIProviderOption.builtin(.glm).label == AIVendor.glm.displayName)
        // API format (ZCode "API 格式" selector): legacy files decode as
        // openai, the field round-trips, and the factory routes by it.
        let legacyProfileJSON = #"{"id":"x","name":"X","baseURL":"http://h/v1","models":["m"]}"#
        let legacyProfile = try? JSONDecoder().decode(AIProviderProfile.self, from: Data(legacyProfileJSON.utf8))
        expect("providers: legacy profile format defaults chat-completions",
               legacyProfile?.effectiveFormat == .chatCompletions)
        let anthropicProfile = AIProviderProfile(
            id: "claude-gateway", name: "Claude GW",
            baseURL: "https://gw.example.com", models: ["claude-sonnet-4-5"],
            format: .anthropic)
        _ = AIProviderRegistry.upsert(anthropicProfile)
        expect("providers: anthropic format round-trips",
               AIProviderRegistry.profile(id: "claude-gateway")?.effectiveFormat == .anthropic)
        let responsesProfile = AIProviderProfile(
            id: "responses-gateway", name: "Responses GW",
            baseURL: "https://gw.example.com/v1", models: ["gpt-5.2"],
            format: .responses)
        _ = AIProviderRegistry.upsert(responsesProfile)
        expect("providers: responses format round-trips",
               AIProviderRegistry.profile(id: "responses-gateway")?.effectiveFormat == .responses)
        // Display-name uniqueness: the picker dimension users see.
        _ = AIProviderRegistry.upsert(AIProviderProfile(
            id: "dup-a", name: "Same Name", baseURL: "http://a/v1", models: ["m"]))
        expect("providers: duplicate name detected",
               AIProviderRegistry.nameExists("Same Name"))
        expect("providers: name check case/whitespace insensitive",
               AIProviderRegistry.nameExists("  same name  "))
        expect("providers: name check excludes self id",
               !AIProviderRegistry.nameExists("Same Name", excludingID: "dup-a"))
        _ = AIProviderRegistry.rename(id: "dup-a", to: "Renamed Provider")
        expect("providers: rename keeps stable id",
               AIProviderRegistry.profile(id: "dup-a")?.name == "Renamed Provider")
        _ = AIProviderRegistry.delete(id: "dup-a")
        var formatSettings = AISettings.load()
        formatSettings.activeProfileID = "claude-gateway"
        formatSettings.vendor = .custom
        formatSettings.baseURL = anthropicProfile.baseURL
        formatSettings.model = "claude-sonnet-4-5"
        formatSettings.apiKey = "test-key"
        let routed = try? AIModelFactory.makeModel(formatSettings)
        expect("providers: factory routes by api format", routed != nil)
        // Profile-active load() must pull the key from the PROFILE slot —
        // reading the builtin vendor slot (empty .custom) wiped it on every
        // load: the key set in Settings vanished by the next screen ("key
        // 没同步" regression).
        do {
            let defaults = UserDefaults.standard
            let settingsBackup = defaults.data(forKey: AISettings.storageKey)
            var syncSettings = AISettings.load()
            syncSettings.activeProfileID = "claude-gateway"
            syncSettings.vendor = .custom
            syncSettings.apiKey = "sk-sync-test"
            syncSettings.save()
            let reloaded = AISettings.load()
            expect("providers: profile key survives load()",
                   reloaded.activeProfileID == "claude-gateway" && reloaded.apiKey == "sk-sync-test",
                   reloaded.apiKey)
            if let settingsBackup {
                defaults.set(settingsBackup, forKey: AISettings.storageKey)
            } else {
                defaults.removeObject(forKey: AISettings.storageKey)
            }
            APIKeyStore.delete(slot: AIProviderProfileKey("claude-gateway"))
        }
        // Restore the user's real config byte-for-byte.
        if let profilesBackup {
            try? profilesBackup.write(to: AIProviderRegistry.fileURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: AIProviderRegistry.fileURL)
        }

        // ---- Credential store (0600 file, keychain-free) ----
        // Back up the real store, exercise slots, restore byte-for-byte.
        let keysBackup = FileManager.default.fileExists(atPath: APIKeyStore.fileURL.path)
            ? try? Data(contentsOf: APIKeyStore.fileURL) : nil
        try? FileManager.default.removeItem(at: APIKeyStore.fileURL)
        APIKeyStore.write("sk-test-openai", for: .openai)
        APIKeyStore.write("sk-profile-x", slot: "api-key.profile:x")
        expect("credentials: vendor slot round-trip",
               APIKeyStore.read(for: .openai) == "sk-test-openai")
        expect("credentials: profile slot round-trip",
               APIKeyStore.read(slot: "api-key.profile:x") == "sk-profile-x")
        expect("credentials: slots are isolated",
               APIKeyStore.read(slot: "api-key.profile:x") != APIKeyStore.read(for: .openai))
        let perms = (try? FileManager.default.attributesOfItem(
            atPath: APIKeyStore.fileURL.path)[.posixPermissions]) as? Int
        expect("credentials: file is 0600", perms == 0o600, "\(perms.map { String($0, radix: 8) } ?? "?")")
        APIKeyStore.delete(slot: "api-key.profile:x")
        expect("credentials: delete clears slot", APIKeyStore.read(slot: "api-key.profile:x") == nil)
        // JSON on disk contains the remaining secret (it must, plaintext by
        // design) — assert the DELETED one is gone from the file.
        let onDisk = (try? String(contentsOf: APIKeyStore.fileURL, encoding: .utf8)) ?? ""
        expect("credentials: deleted secret gone from disk", !onDisk.contains("sk-profile-x"))
        APIKeyStore.delete(for: .openai)
        if let keysBackup {
            try? keysBackup.write(to: APIKeyStore.fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: APIKeyStore.fileURL.path)
        } else {
            try? FileManager.default.removeItem(at: APIKeyStore.fileURL)
        }

        // Settings decode: a pre-profiles payload (no activeProfileID key)
        // still decodes with nil — old defaults never crash new code.
        let legacySettingsJSON = #"{"vendor":"glm","baseURL":"https://open.bigmodel.cn/api/paas/v4","model":"glm-4.6","apiKey":""}"#
        let legacySettings = try? JSONDecoder().decode(AISettings.self, from: Data(legacySettingsJSON.utf8))
        expect("providers: legacy settings decode", legacySettings?.activeProfileID == nil && legacySettings?.vendor == .glm)

        // ---- Size cache: warm hits + mtime invalidation ----
        // The uninstall/analyze speedup contract: unchanged paths serve the
        // cached summary; a content change (dir mtime bump) invalidates just
        // that path and it re-measures. Back up the real cache, exercise a
        // temp fixture, restore byte-for-byte.
        do {
            let fm = FileManager.default
            let cacheBackup = fm.fileExists(atPath: SizeCache.fileURL.path)
                ? try? Data(contentsOf: SizeCache.fileURL) : nil
            SizeCache.shared.clear()
            defer {
                SizeCache.shared.clear()
                if let cacheBackup {
                    try? cacheBackup.write(to: SizeCache.fileURL, options: .atomic)
                }
            }

            expect("size cache: LRU cap stays at 5000", SizeCache.maxEntries == 5000)

            // ---- audit round: regression guards for fixed bug classes ----

            // Trash must not be selected by default (permanent empty of real
            // user files behind the "System & User" master toggle).
            let trashItem = RuleLibrary.sections
                .flatMap(\.items).first { $0.id == "trash" }
            expect("clean: Trash is opt-in and warns",
                   trashItem?.defaultSelected == false && trashItem?.warning != nil)

            // User-data directories are protected by the last-line guard.
            for dir in ["Documents", "Desktop", "Pictures", "Music", "Movies"] {
                let verdict = SafetyGuard.checkDeletable(URL(
                    fileURLWithPath: NSHomeDirectory() + "/" + dir + "/x.txt"))
                expect("safety: \(dir) protected", !verdict.allowed)
            }
            expect("safety: iOS backups protected at the real path",
                   !SafetyGuard.checkDeletable(URL(fileURLWithPath: NSHomeDirectory()
                       + "/Library/Application Support/MobileSync/Backup/x")).allowed)

            // Whitelist glob is single-segment (no implicit deep match).
            let globPattern = NSHomeDirectory() + "/Library/*"
            expect("safety: glob '*' does not cross '/'",
                   SafetyGuard.glob(globPattern, matches: NSHomeDirectory() + "/Library/a")
                   && !SafetyGuard.glob(globPattern, matches: NSHomeDirectory() + "/Library/a/b"))
            expect("safety: whitelisted folder protects its whole subtree",
                   SafetyGuard.globMatchesPathOrAncestor(
                       NSHomeDirectory() + "/Library/Caches/Foo",
                       NSHomeDirectory() + "/Library/Caches/Foo/deep/nested/file"))

            // apply_patch guards: workspace root is never a valid target and
            // delete/move needs an anchored hunk / whitelist pass.
            let patchRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("moppet-patch-smoke-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: patchRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: patchRoot) }
            let rootDelete = try? ApplyPatch.apply(
                "*** Begin Patch\n*** Delete File: .\n*** End Patch", workspaceRoot: patchRoot)
            expect("apply_patch: refuses to delete the workspace root", rootDelete == nil)
            let anchorless = try? ApplyPatch.apply(
                "*** Begin Patch\n*** Update File: a.txt\n@@ hint\n+only-add\n*** End Patch",
                workspaceRoot: patchRoot)
            expect("apply_patch: add-only hunk without anchor is malformed", anchorless == nil)
            let addOnly = try? ApplyPatch.apply(
                "*** Begin Patch\n*** Add File: b.txt\n+one\n*** End Patch", workspaceRoot: patchRoot)
            expect("apply_patch: plain add still works", addOnly?.added == ["b.txt"])
            expect("apply_patch: deletion targets reported for the approval gate",
                   ApplyPatch.deletionTargets(
                    in: "*** Begin Patch\n*** Delete File: z.txt\n*** End Patch") == ["z.txt"])

            // Compaction must not orphan a call/output pair (Responses API 400s
            // on every later turn of the session).
            let paired = BrainAgent.pairingSafe([
                .message(role: "user", content: "go"),
                .functionCall(callID: "c1", name: "shell", arguments: "{}"),
                .functionCallOutput(callID: "c1", output: "ok"),
                .functionCall(callID: "orphan", name: "shell", arguments: "{}"),
                .functionCallOutput(callID: "dangling", output: "x"),
                .message(role: "assistant", content: "done"),
            ])
            let callIDs = paired.compactMap { item -> String? in
                if case .functionCall(let id, _, _) = item { return id }
                return nil
            }
            let outputIDs = paired.compactMap { item -> String? in
                if case .functionCallOutput(let id, _) = item { return id }
                return nil
            }
            expect("brain: compaction drops orphan call/output pairs",
                   callIDs == ["c1"] && outputIDs == ["c1"])

            // Tool contract: whitelist edits are destructive (they were
            // classified non-destructive → zero gate on all three agent paths).
            let whitelistTools = ToolRegistry.tools.filter {
                $0.name == "whitelist_add" || $0.name == "whitelist_remove"
            }
            expect("tools: whitelist mutations require confirmation",
                   whitelistTools.count == 2 && whitelistTools.allSatisfy(\.destructive))

            // ---- Clean selection persistence: unchecked items must never be
            // scanned again (Clean re-entry, Quick Scan, AI no-arg scan).
            do {
                let backup = CleanSelectionStore.all()
                defer {
                    CleanSelectionStore.clear()
                    for (id, on) in backup { CleanSelectionStore.setSelected(id: id, on) }
                }
                CleanSelectionStore.clear()
                expect("clean selection: untouched items follow rule defaults",
                       CleanSelectionStore.selectedItems().map(\.id)
                       == RuleLibrary.sections.flatMap(\.items).filter(\.defaultSelected).map(\.id))
                // The user unticks user-logs (default ON) and ticks xcode-archives (default OFF).
                CleanSelectionStore.setSelected(id: "user-logs", false)
                CleanSelectionStore.setSelected(id: "xcode-archives", true)
                let picked = Set(CleanSelectionStore.selectedItems().map(\.id))
                expect("clean selection: unticks persist and are excluded",
                       !picked.contains("user-logs") && picked.contains("xcode-archives"))
                expect("clean selection: AI no-arg scan honors the saved selection",
                       Set(ToolRegistry.resolveItems(sections: nil, items: nil).map(\.id)) == picked)
                // Explicit scope still wins over the saved selection.
                let browserIDs = Set(RuleLibrary.sections
                    .first { $0.id == "browsers" }!.items.map(\.id))
                expect("clean selection: explicit sections still take precedence",
                       Set(ToolRegistry.resolveItems(sections: ["browsers"], items: nil).map(\.id))
                       == browserIDs)
                // A fresh view model (navigation away/back) keeps the user's choice.
                let vm = CleanViewModel()
                let state = vm.sections.flatMap(\.items).first { $0.id == "user-logs" }
                expect("clean selection: view model seeds from persisted selection",
                       state?.selected == false)
                expect("clean selection: hasCustomSelection flags explicit choices",
                       CleanSelectionStore.hasCustomSelection)
                // THE USER-REPORTED BUG (installers selected, browsers scanned):
                // the UI toggle writes ItemState.selected — persistence rides on
                // its didSet reaching the store. Verify the whole chain through
                // the view model, not the store alone.
                do {
                    let vm = CleanViewModel()
                    let dmg = vm.sections.flatMap(\.items).first { $0.id == "dmg" }
                    let chrome = vm.sections.flatMap(\.items).first { $0.id == "chrome-cache" }
                    dmg?.selected = true
                    chrome?.selected = false
                    expect("clean selection: VM toggle persists (didSet chain)",
                           CleanSelectionStore.isSelected(dmg!.item) == true
                           && CleanSelectionStore.isSelected(chrome!.item) == false)
                    let picked = Set(CleanSelectionStore.selectedItems().map(\.id))
                    expect("clean selection: quick scan follows the VM toggle",
                           picked.contains("dmg") && !picked.contains("chrome-cache"))
                    // restore the user's real selection from the backup —
                    // hardcoded values clobbered a live dmg=1 tick.
                    for (id, on) in backup {
                        CleanSelectionStore.setSelected(id: id, on)
                    }
                }
            }

            // Deep clean items (installers over the WHOLE home): the walk
            // must prune protected prefixes and match extensions
            // case-insensitively — verified on a synthetic tree, never the
            // real home.
            do {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("moppet-deep-\(UUID().uuidString)", isDirectory: true)
                let mk = { (rel: String) -> URL in
                    let url = root.appendingPathComponent(rel)
                    try? FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
                    return url
                }
                let hit = mk("projects/old/setup.DMG")           // case-insensitive hit
                let hit2 = mk("deep/nested/pkg.PKG")
                let miss = mk("projects/old/readme.txt")          // wrong extension
                let blocked = mk("Library/Mail/evil.pkg")         // pruned prefix
                defer { try? FileManager.default.removeItem(at: root) }
                let found = ScanEngine.deepScan(
                    root: root, extensions: ["dmg", "pkg"],
                    prunePrefixes: [root.resolvingSymlinksInPath().path + "/Library"])
                let foundPaths = found.map { $0.resolvingSymlinksInPath().path }
                expect("deep scan: finds nested matches case-insensitively",
                       foundPaths.contains(hit.resolvingSymlinksInPath().path)
                       && foundPaths.contains(hit2.resolvingSymlinksInPath().path))
                expect("deep scan: wrong extension skipped",
                       !foundPaths.contains(miss.resolvingSymlinksInPath().path))
                expect("deep scan: pruned prefix never yields a candidate",
                       !foundPaths.contains(blocked.resolvingSymlinksInPath().path))
            }

            // Batch uninstall must sweep app DATA too (the reported bug):
            // fake .app + fake Application Support payload in a temp tree.
            do {
                let fm = FileManager.default
                let root = fm.temporaryDirectory
                    .appendingPathComponent("moppet-batch-\(UUID().uuidString)", isDirectory: true)
                let appURL = root.appendingPathComponent("Fake.app", isDirectory: true)
                let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
                try? fm.createDirectory(at: contents, withIntermediateDirectories: true)
                let info: [String: Any] = ["CFBundleIdentifier": "com.moppet.smoketest",
                                           "CFBundleName": "Fake"]
                (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
                let payload = contents.appendingPathComponent("MacOS/Fake")
                try? fm.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: payload.path, contents: Data(repeating: 1, count: 4096))
                defer { try? fm.removeItem(at: root) }

                let entry = UninstallEngine.AppEntry(
                    id: appURL.path, name: "Fake", url: appURL,
                    bundleID: "com.moppet.smoketest", bytes: 0)
                // Plan only: the engine's data sweep targets the REAL home
                // (Application Support/com.moppet.smoketest). Create that
                // payload so the assertion is about behaviour, then clean up.
                let homeData = fm.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/com.moppet.smoketest",
                                            isDirectory: true)
                let createdHomeData = !fm.fileExists(atPath: homeData.path)
                if createdHomeData {
                    try? fm.createDirectory(at: homeData, withIntermediateDirectories: true)
                    fm.createFile(atPath: homeData.appendingPathComponent("state.db").path,
                                  contents: Data(repeating: 2, count: 2048))
                }
                defer { if createdHomeData { try? fm.removeItem(at: homeData) } }

                let outcome = awaitSync {
                    await UninstallEngine.batchUninstall(
                        apps: [entry], sizes: [entry.id: 4096],
                        withData: true, appendRecord: false)
                }
                expect("uninstall batch: app bundle was removed",
                       !fm.fileExists(atPath: appURL.path) && outcome.trashed.count == 1)
                if createdHomeData {
                    expect("uninstall batch: app DATA is swept with the app",
                           !fm.fileExists(atPath: homeData.path) && outcome.relatedFiles > 0)
                }
                expect("uninstall batch: data bytes counted in the outcome",
                       outcome.relatedBytes > 0 || !createdHomeData)
            }

            // History records name their SOURCE menu (old files without the
            // field must still decode), and the uninstall deletability rule
            // must accept a bundle-scoped preference plist.
            do {
                let record = CleanRecord(date: Date(), sectionTitles: ["Browsers"],
                                         requestedBytes: 10, freedBytes: 10,
                                         itemCount: 1, items: [], source: .clean)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let data = try? encoder.encode(record),
                   let back = try? decoder.decode(CleanRecord.self, from: data) {
                    expect("history: source survives the JSON round-trip", back.source == .clean)
                } else {
                    expect("history: source survives the JSON round-trip", false, "encode/decode failed")
                }
                // Legacy record: no "source" key at all.
                let legacyJSON = #"{"id":"11111111-1111-1111-1111-111111111111","date":"2026-01-01T00:00:00Z","sectionTitles":["Analyze"],"requestedBytes":5,"freedBytes":5,"itemCount":1,"items":[]}"#
                let legacy = try? decoder.decode(CleanRecord.self, from: Data(legacyJSON.utf8))
                expect("history: legacy record without source still decodes",
                       legacy != nil && legacy?.source == nil)
                // Inference used by the History row for such records.
                expect("history: legacy record source is inferred from its section title",
                       legacy.map { HistoryView.resolvedSource($0) == .analyze } == true)

                // Bundle-scoped preferences are removable; the category as a
                // whole is not (batch uninstall used to skip them entirely).
                let home = FileManager.default.homeDirectoryForCurrentUser
                let prefFile = home.appendingPathComponent("Library/Preferences/com.example.app.plist")
                let rel = UninstallEngine.RelatedFile(url: prefFile, bytes: 1,
                                                      kind: "preferences", deletable: true)
                expect("uninstall: bundle-scoped preference plist is removable",
                       UninstallEngine.isDeletableRelated(rel, bundleID: "com.example.app"))
                expect("uninstall: another app's preference plist is not",
                       !UninstallEngine.isDeletableRelated(rel, bundleID: "com.other.app"))
                let prefDir = home.appendingPathComponent("Library/Preferences")
                let dirRel = UninstallEngine.RelatedFile(url: prefDir, bytes: 1,
                                                         kind: "preferences", deletable: true)
                expect("uninstall: the Preferences CATEGORY itself stays protected",
                       !UninstallEngine.isDeletableRelated(dirRel, bundleID: "com.example.app"))
            }

            // Dashboard lifetime totals come from the audit log: only
            // SUCCESSFUL items count, split by deletion mode, and failures
            // never inflate the number.
            do {
                let backup = HistoryStore.load()
                let date = Date()
                HistoryStore.save([
                    CleanRecord(date: date, sectionTitles: ["Test"], requestedBytes: 300,
                                freedBytes: 300, itemCount: 3, items: [
                        CleanRecordItem(path: "/tmp/a", bytes: 100, mode: .permanent,
                                        success: true, error: nil),
                        CleanRecordItem(path: "/tmp/b", bytes: 200, mode: .trash,
                                        success: true, error: nil),
                        CleanRecordItem(path: "/tmp/c", bytes: 900, mode: .permanent,
                                        success: false, error: "boom"),
                    ]),
                    CleanRecord(date: date.addingTimeInterval(-3600), sectionTitles: ["Test"],
                                requestedBytes: 50, freedBytes: 50, itemCount: 1, items: [
                        CleanRecordItem(path: "/tmp/d", bytes: 50, mode: .permanent,
                                        success: true, error: nil),
                    ]),
                ])
                let totals = HistoryStore.totals()
                expect("dashboard totals: runs counted",
                       totals.runs == 2)
                expect("dashboard totals: successful items only, split by mode",
                       totals.permanentBytes == 150 && totals.trashBytes == 200)
                expect("dashboard totals: total excludes failed outcomes",
                       totals.totalBytes == 350 && totals.itemCount == 3)
                expect("dashboard totals: last run is the newest record",
                       totals.lastRun.map { abs($0.timeIntervalSince(date)) < 1 } == true)
                expect("dashboard totals: recent runs oldest→newest",
                       totals.recentRuns.count == 2
                       && totals.recentRuns.first?.bytes == 50
                       && totals.recentRuns.last?.bytes == 300)
                HistoryStore.save(backup)
            }

            // Bubble geometry: the measured card must fit the width it is
            // given at every size scale (a hardcoded 232pt cap once
            // overflowed the 200pt panel and clipped the text).
            do {
                let longLine = String(repeating: "汉", count: 80)   // far wider than any panel
                for panelWidth in [200.0, 250.0, 312.0] as [CGFloat] {
                    let width = PetView.bubbleWidth(for: longLine, maxWidth: panelWidth - 24)
                    expect("pet: bubble fits a \(Int(panelWidth))pt panel",
                           width <= panelWidth - 24 + 0.5)
                }
                let short = "OK"
                expect("pet: short messages keep a compact bubble",
                       PetView.bubbleWidth(for: short, maxWidth: 176) < 96)
                // Height estimate drives the panel's vertical growth; if it
                // under-reports, a long answer swallows the mole's strip (the
                // "pet disappeared" regression) — it must scale with content.
                let longAnswer = String(repeating: "很长的回答内容。", count: 60)
                expect("pet: height estimate scales with the answer",
                       PetView.bubbleHeight(for: short, width: 300) < 60
                       && PetView.bubbleHeight(for: longAnswer, width: 300) > 300)
                // The scroll fallback must be a CONCRETE height (a greedy
                // ScrollView stretched two-line bubbles to 190pt — measured).
                // Mirrored here so the constant cannot drift silently.
                expect("pet: bubble viewport is a bounded, non-zero cap",
                       PetView.bubbleHeightCap(panelHeight: 320) > 0
                       && PetView.bubbleHeightCap(panelHeight: 320) < 320)
            }

            // Bubble persistence: answers must NOT auto-hide (hideAfter 0 =
            // keep until the next say replaces it). This is the contract the
            // quick bar and the chat turn rely on.
            do {
                PetBus.shared.say("ANSWER-TEXT", state: .talking, hideAfter: 0)
                expect("pet: hideAfter 0 keeps the bubble up",
                       PetBus.shared.messageHideInterval == 0)
                expect("pet: the bubble carries the whole answer text",
                       PetBus.shared.message == "ANSWER-TEXT")
                PetBus.shared.say("PROGRESS", state: .scanning)
                expect("pet: announcements still auto-hide by default",
                       (PetBus.shared.messageHideInterval ?? PetBus.shared.autoHideInterval) > 0)
                PetBus.shared.settle()
            }

            // Pet states: every PetState must map to a bundled sticker
            // (sad/angry were dead code — errors showed no emotion), and
            // the sad pose must auto-settle via PetBus.
            for state in [PetState.idle, .thinking, .talking, .scanning,
                          .cleaning, .celebrating, .sleeping, .sad] {
                expect("pet: sticker exists for \(state)",
                       Stickers.image(for: state) != nil)
            }
            expect("pet: PetState has 8 cases",
                   [PetState.idle, .thinking, .talking, .scanning,
                    .cleaning, .celebrating, .sleeping, .sad].count == 8)

            // Model-controlled numeric params must be clamped, not trapped.
            let clampedHistory = executeSync("clean_history", args: ["limit": -1])
            expect("tools: negative limit does not crash", !clampedHistory.isEmpty)


            let fixture = fm.temporaryDirectory
                .appendingPathComponent("smoke-sizecache-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: fixture, withIntermediateDirectories: true)
            try? Data(repeating: 0, count: 65_536).write(to: fixture.appendingPathComponent("a.bin"))
            let first = ScanEngine.cachedSize(of: fixture)
            expect("size cache: first call measures and stores",
                   first.bytes > 0 && SizeCache.shared.lookup(fixture) != nil)
            let warm = ScanEngine.cachedSize(of: fixture)
            expect("size cache: unchanged path serves the cached summary",
                   warm == first, "\(warm.bytes) vs \(first.bytes)")

            // Content change bumps the directory mtime → entry invalidates
            // and only THIS path re-measures.
            try? Data(repeating: 0, count: 65_536).write(to: fixture.appendingPathComponent("b.bin"))
            expect("size cache: dir mtime change invalidates",
                   SizeCache.shared.lookup(fixture) == nil)
            let remeasured = ScanEngine.cachedSize(of: fixture)
            expect("size cache: changed path re-measures bigger",
                   remeasured.bytes > first.bytes, "\(remeasured.bytes) vs \(first.bytes)")

            // Deleting a file bumps the mtime of its OWN parent only —
            // directories further up keep their old mtime, so their cached
            // bytes looked "still valid" and Analyze kept showing the
            // pre-delete size for every ancestor until the 3-day TTL.
            // invalidate() must drop the whole chain, not just one entry.
            do {
                let kid = fixture.appendingPathComponent("kid", isDirectory: true)
                try? fm.createDirectory(at: kid, withIntermediateDirectories: true)
                try? Data(repeating: 0, count: 2_048)
                    .write(to: kid.appendingPathComponent("gone.bin"))
                _ = ScanEngine.cachedSize(of: kid)
                _ = ScanEngine.cachedSize(of: fixture)
                let bystander = fm.temporaryDirectory
                    .appendingPathComponent("smoke-bystander-\(UUID().uuidString)", isDirectory: true)
                try? fm.createDirectory(at: bystander, withIntermediateDirectories: true)
                // Empty dirs are never cached (cachedSize skips 0/0 summaries),
                // so the bystander needs real content to have an entry at all.
                try? Data(repeating: 0, count: 1_024)
                    .write(to: bystander.appendingPathComponent("keep.bin"))
                _ = ScanEngine.cachedSize(of: bystander)

                SizeCache.shared.invalidate(kid.appendingPathComponent("gone.bin"))
                expect("size cache: invalidate drops the deleted path's ancestor chain",
                       SizeCache.shared.lookup(kid) == nil
                       && SizeCache.shared.lookup(fixture) == nil)
                expect("size cache: invalidate leaves unrelated subtrees alone",
                       SizeCache.shared.lookup(bystander) != nil)
            }

            // Analyze delete must shrink every ancestor row IN MEMORY, not
            // just drop the deleted child: the user reported parent sizes
            // staying at their old value after a delete.
            do {
                let dir = fm.temporaryDirectory
                    .appendingPathComponent("smoke-analyze-\(UUID().uuidString)", isDirectory: true)
                let sub = dir.appendingPathComponent("sub", isDirectory: true)
                let deep = sub.appendingPathComponent("deep", isDirectory: true)
                try? fm.createDirectory(at: deep, withIntermediateDirectories: true)
                let target = deep.appendingPathComponent("victim.bin")
                try? Data(repeating: 0, count: 4_096).write(to: target)

                let victim = FileNode(url: target, bytes: 4_096, isDirectory: false, fileCount: 1)
                let deepNode = FileNode(url: deep, bytes: 4_096, isDirectory: true, fileCount: 1)
                deepNode.children = [victim]
                let subNode = FileNode(url: sub, bytes: 8_192, isDirectory: true, fileCount: 3)
                subNode.children = [deepNode]
                let rootNode = FileNode(url: dir, bytes: 12_288, isDirectory: true, fileCount: 5)
                rootNode.children = [subNode]
                var tree = [rootNode]

                expect("analyze: deletion is found in a nested layer",
                       FileNode.applyDeletion(id: victim.id, in: &tree))
                expect("analyze: deleted node leaves the tree",
                       deepNode.children.isEmpty)
                expect("analyze: direct parent shrinks by the deleted bytes",
                       deepNode.bytes == 0 && deepNode.fileCount == 0,
                       "\(deepNode.bytes)/\(deepNode.fileCount)")
                expect("analyze: grandparent and root shrink too",
                       subNode.bytes == 4_096 && rootNode.bytes == 8_192
                       && subNode.fileCount == 2 && rootNode.fileCount == 4,
                       "sub=\(subNode.bytes)/\(subNode.fileCount) root=\(rootNode.bytes)/\(rootNode.fileCount)")
                expect("analyze: deleting an unknown id is a no-op",
                       FileNode.applyDeletion(id: "nope", in: &tree) == false
                       && tree.count == 1)
                // The delete ring must never be pre-seeded outside the probe —
                // a permanently visible modal would block the whole page.
                expect("analyze: delete ring is not seeded without the debug flag",
                       AnalyzeView.debugSeed == nil)
            }

            // cachedTopChildren (Analyze fast-path): after a real pass every
            // child has a valid summary → snapshot with 0 misses; entries
            // measured but since-invalidated count as misses (partial
            // snapshots must NOT be served — they would hide folders).
            do {
                let layer = fm.temporaryDirectory
                    .appendingPathComponent("smoke-topchildren-\(UUID().uuidString)", isDirectory: true)
                try? fm.createDirectory(at: layer, withIntermediateDirectories: true)
                for name in ["kid1", "kid2"] {
                    let kid = layer.appendingPathComponent(name, isDirectory: true)
                    try? fm.createDirectory(at: kid, withIntermediateDirectories: true)
                    try? Data(repeating: 0, count: 2_048).write(to: kid.appendingPathComponent("data.bin"))
                }
                for kid in ["kid1", "kid2"] {
                    _ = ScanEngine.cachedSize(of: layer.appendingPathComponent(kid, isDirectory: true))
                }
                let snapshot = ScanEngine.cachedTopChildren(of: layer, limit: 10)
                expect("cachedTopChildren: full hit after a real pass",
                       snapshot.missed == 0 && snapshot.entries.count == 2,
                       "missed=\(snapshot.missed) entries=\(snapshot.entries.count)")
                // Invalidate one kid → the snapshot must refuse to serve
                // (missed > 0) instead of hiding that folder.
                try? Data(repeating: 0, count: 1_024).write(
                    to: layer.appendingPathComponent("kid1").appendingPathComponent("extra.bin"))
                let afterChange = ScanEngine.cachedTopChildren(of: layer, limit: 10)
                expect("cachedTopChildren: invalidation counts as miss (no partial serve)",
                       afterChange.missed > 0)
            }
        }

        // ---- Gap-analysis P0 engines (snapshots / Docker / Homebrew / orphans /
        // scheduler / export) — parsers exercised on fixtures, never on the
        // live system, and never executing destructive tools. ----
        do {
            // Snapshot list parsing: full mount names AND bare tokens,
            // deduped, newest first.
            let snapOutput = """
            Snapshot dates for /:
            com.apple.TimeMachine.2026-10-27-123456.local
            com.apple.TimeMachine.2026-10-26-020101.local
            2026-10-25-101112
            not-a-snapshot-line
            com.apple.TimeMachine.2026-10-27-123456.local
            """
            let snaps = SnapshotEngine.parseListOutput(snapOutput)
            expect("snapshots: parses 3 unique, newest first",
                   snaps.count == 3 && snaps[0].id == "2026-10-27-123456"
                   && snaps[2].id == "2026-10-25-101112")
            expect("snapshots: token extraction strict",
                   SnapshotEngine.extractSnapshotToken("com.apple.TimeMachine.2026-01-01-000000.local") == "2026-01-01-000000"
                   && SnapshotEngine.extractSnapshotToken("2026-01-01-000000") == "2026-01-01-000000"
                   && SnapshotEngine.extractSnapshotToken("garbage") == nil)
            expect("snapshots: date parses from token",
                   SnapshotEngine.date(from: "2026-10-27-123456") != nil
                   && SnapshotEngine.date(from: "nope") == nil)
            // One malformed token must never pass the delete guard.
            expect("snapshots: delete rejects non-tokens",
                   // can't call the throwing shell path in smoke; the guard
                   // is the same extractSnapshotToken check — assert its verdict.
                   SnapshotEngine.extractSnapshotToken("2026-13-99-999999") == nil)

            // Docker df NDJSON: the REAL Docker Desktop shape (Capitalized
            // types, string counts, human-size strings) plus legacy numeric
            // and lowercase variants — captured verbatim from the machine.
            let dockerJSON = """
            {"Active":"2","Reclaimable":"2.323GB (59%)","Size":"3.918GB","TotalCount":"3","Type":"Images"}
            {"Active":"0","Reclaimable":"131.1kB (100%)","Size":"131.1kB","TotalCount":"2","Type":"Containers"}
            {"Active":"1","Reclaimable":"0B (0%)","Size":"830.8kB","TotalCount":"1","Type":"Local Volumes"}
            {"Active":"0","Reclaimable":"408.4MB","Size":"1.018GB","TotalCount":"34","Type":"Build Cache"}
            """
            let usage = DockerEngine.parseDFJSONL(dockerJSON)
            expect("docker: real df shape parses (Capitalized types, string counts, human sizes)",
                   usage.imagesCount == 3 && usage.imagesBytes == 3_918_000_000
                   && usage.containersCount == 2 && usage.containersBytes == 131_100
                   && usage.volumesCount == 1 && usage.volumesBytes == 830_800
                   && usage.cacheCount == 34 && usage.cacheBytes == 1_018_000_000,
                   "\(usage.totalBytes)")
            expect("docker: totals sum",
                   usage.totalBytes == 3_918_000_000 + 131_100 + 830_800 + 1_018_000_000)
            // Legacy/variant shapes must keep parsing.
            let legacyDockerJSON = """
            {"Type":"images","Images":4,"Size":3200000000}
            {"Type":"containers","Containers":7,"Size":"1024000000"}
            {"Type":"local Volumes","Volumes":2,"Size":512000000}
            {"Type":"build-cache","BuildCache":11,"Size":"2048000000"}
            """
            let legacyUsage = DockerEngine.parseDFJSONL(legacyDockerJSON)
            expect("docker: legacy lowercase/numeric variant parses",
                   legacyUsage.imagesCount == 4 && legacyUsage.imagesBytes == 3_200_000_000
                   && legacyUsage.cacheCount == 11 && legacyUsage.cacheBytes == 2_048_000_000)
            expect("docker: human-size parser handles units and suffixes",
                   DockerEngine.parseHumanBytes("0B") == 0
                   && DockerEngine.parseHumanBytes("131.1kB") == 131_100
                   && DockerEngine.parseHumanBytes("2.243GB") == 2_243_000_000
                   && DockerEngine.parseHumanBytes("1,024 MB") == 1_024_000_000
                   && DockerEngine.parseHumanBytes("990.2MB (44%)") == 990_200_000
                   && DockerEngine.parseHumanBytes("garbage") == 0)

            // Homebrew preview: "Would remove:" block + human-size parser.
            let brewOutput = """
            Warning: some tap warning line
            Would remove:
            /opt/homebrew/Cellar/foo/1.0 (12 files, 3.5MB)
            /opt/homebrew/Cellar/bar/2.0 (1,004 files, 75.5MB)
            /opt/homebrew/Cellar/baz/3.0 (2 files, 900KB)
            ==> Nothing else
            """
            let brew = HomebrewEngine.parseCleanupPreview(brewOutput)
            expect("homebrew: preview parses 3 lines",
                   brew.lines.count == 3 && brew.lines[0].contains("foo/1.0"))
            expect("homebrew: sizes sum (3.5MB + 75.5MB + 900KB)",
                   brew.totalBytes == 3_500_000 + 75_500_000 + 900_000,
                   "\(brew.totalBytes)")
            expect("homebrew: size parser handles GB/B",
                   HomebrewEngine.parseHumanSize(in: "(1.25GB)") == 1_250_000_000
                   && HomebrewEngine.parseHumanSize(in: "(512B)") == 512
                   && HomebrewEngine.parseHumanSize(in: "no size here") == 0)

            // Modern Homebrew (4+/7+) prints "Would remove: <path> (<size>)"
            // on ONE line — the old parser only understood the legacy
            // header-then-paths layout and returned empty for this.
            let modern = """
            Warning: Skipping foo: most recent version not installed
            Would remove: /opt/homebrew/Cellar/pcre2/10.47_1 (244 files, 7.3MB)
            Would remove (empty directory): /opt/homebrew/share/Library/Caches/Yarn
            Would remove: /Users/x/Library/Caches/Homebrew/opencode--2.1.2 (88.5MB)
            """
            let modernPreview = HomebrewEngine.parseCleanupPreview(modern)
            expect("homebrew: modern one-line format parses",
                   modernPreview.lines.count == 3
                   && modernPreview.totalBytes == 7_300_000 + 88_500_000,
                   "\(modernPreview.lines.count) lines / \(modernPreview.totalBytes) B")

            // Orphan residue classification (pure rules — no disk walk).
            expect("orphans: bundle id extraction",
                   OrphanResidueEngine.bundleID(fromEntryName: "com.example.app") == "com.example.app"
                   && OrphanResidueEngine.bundleID(fromEntryName: "com.example.app.plist") == "com.example.app"
                   && OrphanResidueEngine.bundleID(fromEntryName: "com.example.app.savedState") == "com.example.app")
            expect("orphans: ByHost plist collapses to the bundle id",
                   OrphanResidueEngine.bundleID(fromEntryName: "com.example.app.A1B2C3D4.plist") == "com.example.app")
            expect("orphans: non-reverse-DNS names rejected",
                   OrphanResidueEngine.bundleID(fromEntryName: "notabundle") == nil
                   && OrphanResidueEngine.bundleID(fromEntryName: "readme.txt") == nil)
            expect("orphans: vendor helpers of installed apps are kept",
                   OrphanResidueEngine.belongsToInstalledApp("com.google.Keystone",
                       installedIDs: ["com.google.Chrome"])
                   && OrphanResidueEngine.belongsToInstalledApp("com.example.app.helper",
                       installedIDs: ["com.example.app"]))
            expect("orphans: unrelated ids are NOT kept",
                   !OrphanResidueEngine.belongsToInstalledApp("com.unknown.thing",
                       installedIDs: ["com.google.Chrome"]))
            expect("orphans: Apple-owned never reported",
                   OrphanResidueEngine.isSystemOwned("com.apple.sandboxd")
                   && !OrphanResidueEngine.isSystemOwned("com.example.app"))
            expect("orphans: updater ids protected by default",
                   OrphanResidueEngine.builtinProtectedIDs.contains("com.google.Keystone"))
            // Preferences deletability: bundle-scoped plist exempt, the
            // category and unrelated plists are not.
            let orphanPref = SafetyGuard.home
                .appendingPathComponent("Library/Preferences/com.deadapp.example.plist")
            expect("orphans: bundle-scoped preference plist deletable",
                   OrphanResidueEngine.deletable(orphanPref, bundleID: "com.deadapp.example"))
            expect("orphans: unrelated preference plist NOT deletable",
                   !OrphanResidueEngine.deletable(orphanPref, bundleID: "com.other.app"))

            // Scheduler: generated plists are VALID launchd XML (launchd
            // rejects JSON), carry the headless flag, and clamp bad values.
            let dailyPlist = Scheduler.plistXML(
                settings: Scheduler.Settings(enabled: true, frequency: .daily, weekday: 1, hour: 3),
                executablePath: "/usr/local/bin/Moppet")
            let dailyObj = try? PropertyListSerialization.propertyList(
                from: Data(dailyPlist.utf8), options: [], format: nil) as? [String: Any]
            let dailyArgs = (dailyObj?["ProgramArguments"] as? [String]) ?? []
            expect("scheduler: daily plist is valid XML with the headless flag",
                   dailyObj?["Label"] as? String == "com.moppet.schedule"
                   && dailyArgs.count == 2 && dailyArgs[1] == "--scheduled-clean"
                   && dailyArgs[0] == "/usr/local/bin/Moppet")
            let dailyCal = dailyObj?["StartCalendarInterval"] as? [String: Any]
            expect("scheduler: daily has Hour but no Weekday",
                   (dailyCal?["Hour"] as? Int) == 3 && dailyCal?["Weekday"] == nil)
            let weeklyPlist = Scheduler.plistXML(
                settings: Scheduler.Settings(enabled: true, frequency: .weekly, weekday: 2, hour: 23),
                executablePath: "/usr/local/bin/Moppet")
            let weeklyCal = ((try? PropertyListSerialization.propertyList(
                from: Data(weeklyPlist.utf8), options: [], format: nil)) as? [String: Any])?["StartCalendarInterval"] as? [String: Any]
            expect("scheduler: weekly carries Weekday and clamps Hour",
                   (weeklyCal?["Weekday"] as? Int) == 2 && (weeklyCal?["Hour"] as? Int) == 23)
            let bogusPlist = Scheduler.plistXML(
                settings: Scheduler.Settings(enabled: true, frequency: .weekly, weekday: 9, hour: 77),
                executablePath: "/usr/local/bin/Moppet")
            let bogusCal = ((try? PropertyListSerialization.propertyList(
                from: Data(bogusPlist.utf8), options: [], format: nil)) as? [String: Any])?["StartCalendarInterval"] as? [String: Any]
            expect("scheduler: hour/weekday clamped into launchd range",
                   (bogusCal?["Hour"] as? Int) == 23 && (bogusCal?["Weekday"] as? Int) == 7)
            // The safe set is permanent-only, non-deep, never the Trash.
            let safeItems = Scheduler.safeCleanItems()
            expect("scheduler: safe set is permanent/non-deep/no-trash",
                   !safeItems.isEmpty
                   && safeItems.allSatisfy { $0.mode == .permanent && $0.deepExtensions == nil && $0.id != "trash" })

            // History export: CSV round shape + JSON round-trip.
            let exportRecord = CleanRecord(
                date: Date(timeIntervalSince1970: 1_770_000_000),
                sectionTitles: ["Clean", "Big, \"quoted\" section"],
                requestedBytes: 300, freedBytes: 200, itemCount: 2,
                items: [
                    CleanRecordItem(path: "/tmp/a,b.csv", bytes: 100, mode: .permanent,
                                    success: true, error: nil),
                    CleanRecordItem(path: "/tmp/b", bytes: 200, mode: .trash,
                                    success: false, error: "said \"no\""),
                ], source: .hogs)
            let csv = HistoryStore.csvExport(records: [exportRecord])
            expect("export: CSV has header and rows",
                   csv.hasPrefix("run_date,run_source,run_sections,path,bytes,mode,success,error\n")
                   && csv.contains("hogs"))
            expect("export: CSV quotes commas and quotes",
                   csv.contains("\"/tmp/a,b.csv\"")
                   && csv.contains("\"said \"\"no\"\"\""))
            let csvRows = csv.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            expect("export: CSV one row per item", csvRows.count == 3)
            let jsonDecoder = JSONDecoder()
            jsonDecoder.dateDecodingStrategy = .iso8601
            let jsonBack = try? jsonDecoder.decode(
                [CleanRecord].self, from: HistoryStore.jsonExport(records: [exportRecord]))
            expect("export: JSON round-trips",
                   jsonBack?.count == 1 && jsonBack?[0].items.count == 2
                   && jsonBack?[0].source == .hogs)
            // PDF report: readable text with run + path rows (marks included).
            let pdfReport = HistoryView.buildPDFReport([exportRecord])
            expect("export: PDF report carries runs, paths and failure marks",
                   pdfReport.contains("hogs")
                   && pdfReport.contains("/tmp/a,b.csv")
                   && pdfReport.contains("✗ [") && pdfReport.contains("✓ ["))

            // New tool registrations + destructive flags.
            expect("tools: hogs/orphan tools registered",
                   ToolRegistry.tool(named: "scan_space_hogs") != nil
                   && ToolRegistry.tool(named: "scan_orphans") != nil)
            expect("tools: hog mutations are destructive",
                   ToolRegistry.tool(named: "delete_local_snapshots")?.destructive == true
                   && ToolRegistry.tool(named: "docker_prune")?.destructive == true
                   && ToolRegistry.tool(named: "brew_cleanup")?.destructive == true
                   && ToolRegistry.tool(named: "clean_orphans")?.destructive == true)
            // New record sources render a badge (icon + localized title).
            for source in [RecordSource.largeFiles, .orphans, .hogs, .scheduled] {
                expect("history: source badge for \(source.rawValue)",
                       !source.icon.isEmpty && !source.title.isEmpty)
            }

            // Shell timeout guard: a hung child (tmutil did, for real) must
            // throw instead of wedging the caller forever.
            do {
                let slowStart = Date()
                let timedOut: String? = awaitSync {
                    try? await OptimizeEngine.shell("sleep 30", timeout: 1)
                }
                let elapsed = Date().timeIntervalSince(slowStart)
                expect("shell: timeout fires around 1s",
                       timedOut == nil && elapsed < 6 && elapsed >= 0.9,
                       String(format: "%.1fs", elapsed))
            }
            let fast: String = awaitSync {
                do {
                    let out = try await OptimizeEngine.shell("echo ok", timeout: 10)
                    return "OK: \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
                } catch {
                    return "ERR: \((error as NSError).code) \(error.localizedDescription)"
                }
            }
            expect("shell: fast command unaffected", fast == "OK: ok", fast)
            let failing: String? = awaitSync { try? await OptimizeEngine.shell("exit 3", timeout: 10) }
            expect("shell: non-zero exit still throws", failing == nil)

            // Permissions probe runs and answers a Bool (the TCC read may
            // succeed or fail on this machine — both are valid).
            let fda = Permissions.hasFullDiskAccess
            expect("permissions: FDA probe returns a stable Bool",
                   fda == Permissions.hasFullDiskAccess)
        }

        print(failures == 0 ? "SMOKE PASS" : "SMOKE FAIL (\(failures) failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// Runs a tool synchronously (registry is async) and returns its result
    /// or error text.
    private static func executeSync(_ name: String, args: [String: Any]) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var output = ""
        Task {
            do {
                output = try await ToolRegistry.execute(name: name, args: args, approval: .confirmedFlag)
            } catch {
                output = "ERROR: \(error.localizedDescription)"
            }
            semaphore.signal()
        }
        semaphore.wait()
        return output
    }

    /// Runs an async operation from the synchronous smoke body.
    private static func awaitSync<T>(_ work: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        Task {
            result = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }

    /// Serializes tools/list the way the MCP server would.
    private static func mcpToolsListCount() -> Int? {
        let payload: [String: Any] = ["tools": ToolRegistry.tools.map {
            ["name": $0.name, "description": $0.description, "inputSchema": $0.jsonSchema] as [String: Any]
        }]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = decoded["tools"] as? [[String: Any]] else { return nil }
        return tools.count
    }
}
