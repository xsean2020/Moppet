import SwiftUI
import AppKit

@main
struct MoppetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Writing to a dead child's pipe (exec sessions, MCP servers) kills
        // this whole process with SIGPIPE — ignore it process-wide so the
        // write returns an error instead (verified: exit 141 without this).
        signal(SIGPIPE, SIG_IGN)
        // Relocate pre-rename "Cleaner" data (settings, keys, brain
        // sessions, history, whitelist) — must run before ANY reader, in
        // every mode (GUI and the headless CLI paths below).
        LegacyMigration.runIfNeeded()

        // Flag hardening: a typo'd headless flag used to fall through to a
        // FULL GUI launch (pet panel + persisted MCP HTTP listener).
        let knownFlags: Set<String> = ["--smoke", "--brain-smoke", "--mcp", "--mcp-http",
                                       "--brain-exec", "--yes", "--probe-floater",
                                       "--probe-models", "--probe-pet-bubble",
                                       "--probe-pet-panel", "--probe-imk", "--probe-analyze",
                                       "--probe-analyze-render", "--probe-sidebar", "--probe-home",
                                       "--net-probe",
                                       "--samples", "--hosts", "--json", "--throughput",
                                       "--compare", "--run", "--rounds", "--control-ip", "--no-record",
                                       "--route-perf", "--win-debug", "--scheduled-clean"]
        let args = CommandLine.arguments
        // A bare "--" is the conventional separator (`swift run Moppet -- --smoke`)
        // and must not count as an unknown flag.
        let unknown = args.dropFirst().filter {
            $0.hasPrefix("--") && $0 != "--" && !knownFlags.contains($0)
        }
        if !unknown.isEmpty {
            FileHandle.standardError.write(Data("error: unknown flag(s): \(unknown.joined(separator: " "))\n".utf8))
            exit(2)
        }

        // Headless self-test: `Moppet --smoke` exercises the core engine and exits.
        if args.contains("--smoke") {
            SmokeTest.run()
        }
        // Analyze ring render: writes a PNG of the page with a synthetic
        // in-flight delete, so the overlay can be checked without screen
        // recording permission and without deleting real files.
        if let index = args.firstIndex(of: "--probe-analyze-render") {
            let output = args.count > index + 1 ? args[index + 1] : "/tmp/moppet-analyze.png"
            let appearance = args.count > index + 2 ? args[index + 2] : "light"
            Task { @MainActor in AnalyzeRenderProbe.run(outputPath: output, appearance: appearance) }
        }
        // Headless network probe: the measurement kernel, validated in a
        // terminal before any UI exists. `Moppet --net-probe [--json]`.
        if args.contains("--net-probe") {
            NetworkProbeCLI.run()
        }
        // Sidebar render: writes a PNG of the nav panel so its spacing and
        // icon work can be checked without a screen-recording grant.
        // `Moppet --probe-sidebar out.png dark 700`
        if let index = args.firstIndex(of: "--probe-sidebar") {
            let output = args.count > index + 1 ? args[index + 1] : "/tmp/moppet-sidebar.png"
            let appearance = args.count > index + 2 ? args[index + 2] : "light"
            let height = args.count > index + 3 ? (Double(args[index + 3]) ?? 700) : 700
            Task { @MainActor in
                SidebarRenderProbe.runPanel(outputPath: output, appearance: appearance,
                                            height: height)
            }
        }
        // Dashboard render: writes a PNG of the landing page so card layout
        // and metric legibility can be checked without screen recording.
        // `Moppet --probe-home out.png dark 780 640`
        if let index = args.firstIndex(of: "--probe-home") {
            let output = args.count > index + 1 ? args[index + 1] : "/tmp/moppet-home.png"
            let appearance = args.count > index + 2 ? args[index + 2] : "light"
            let width = args.count > index + 3 ? (Double(args[index + 3]) ?? 780) : 780
            let height = args.count > index + 4 ? (Double(args[index + 4]) ?? 640) : 640
            Task { @MainActor in
                HomeRenderProbe.run(outputPath: output, appearance: appearance,
                                    width: width, height: height)
            }
        }
        // LaunchAgent entry: the scheduled safe clean. Runs headless, records
        // to history with source .scheduled, exits.
        if args.contains("--scheduled-clean") {
            Scheduler.runScheduledClean()
        }
        // IMK focus probe: opens the chat window while the app is inactive,
        // the exact situation that logs the IMKCFRunLoopWakeUpReliable /
        // TSM caps-lock diagnostics.
        if args.contains("--probe-imk") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                NSApp.hide(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    WindowRouter.shared.showChat()
                }
            }
        }
        // Pet bubble sizing probe: measures real laid-out heights.
        if args.contains("--probe-pet-bubble") {
            PetBubbleProbe.run()
        }
        // Pet PANEL probe: posts a long answer and checks the window actually
        // widens AND grows upward while staying under the screen's top edge —
        // the "wide answer swallowed the pet" regression, at runtime.
        if args.contains("--probe-pet-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let long = String(repeating: "这是一段很长的回答内容，用来验证气泡变宽变高时宠物依然完整显示。",
                                  count: 10)
                PetBus.shared.say(long, state: .talking, hideAfter: 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    guard let panel = NSApp.windows.first(where: { $0 is PetPanel }) else {
                        print("probe-pet-panel: no pet panel")
                        exit(3)
                    }
                    let frame = panel.frame
                    let base = PetSettings.currentSize
                    let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
                    // Growth is relative to the user's pet scale (base can be
                    // 200×320 at 0.8): the panel must widen and rise, and
                    // stay under the screen's top edge.
                    let grew = frame.width > base.width + 40 && frame.height > base.height + 20
                    let inside = visible.map { frame.maxY <= $0.maxY + 0.5 } ?? true
                    print("probe-pet-panel: frame=\(frame) base=\(base) grew=\(grew) insideScreen=\(inside)")
                    exit(grew && inside ? 0 : 2)
                }
            }
        }
        // Floater color diagnostics: see Airi.probeFloaterColors.
        if args.contains("--probe-floater") {
            Airi.probeFloaterColors()
        }
        // Subscription backend diagnostics: `Moppet --probe-models` dumps
        // GET {codex backend}/models with the stored token.
        if args.contains("--probe-models") {
            CodexSubscription.probeModels()
        }
        // MCP server: `Moppet --mcp` serves all built-in tools over stdio JSON-RPC.
        if args.contains("--mcp") {
            MCPServer.run()
        }
        // Brain headless verification: `Moppet --brain-smoke`.
        if args.contains("--brain-smoke") {
            BrainSmokeTest.run()
        }
        // codex exec parity: one-shot headless agent run.
        // `Moppet --brain-exec "clean my browser caches and report"`
        if let index = args.firstIndex(of: "--brain-exec") {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                FileHandle.standardError.write(Data("error: --brain-exec needs a quoted prompt\n".utf8))
                exit(2)
            }
            BrainExec.run(prompt: args[index + 1])
        }
        // Foreground HTTP MCP server: `Moppet --mcp-http [port]`
        if let index = args.firstIndex(of: "--mcp-http") {
            var port = MCPHTTPServer.defaultPort
            if index + 1 < args.count, !args[index + 1].hasPrefix("--"),
               let parsed = UInt16(args[index + 1]), parsed > 0 {
                port = parsed
            } else if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                FileHandle.standardError.write(Data("error: invalid port '\(args[index + 1])'\n".utf8))
                exit(2)
            }
            let server = MCPHTTPServer()
            do {
                try server.start(port: port)
                print("moppet MCP (HTTP) listening on http://127.0.0.1:\(port)/mcp")
                setvbuf(stdout, nil, _IONBF, 0)
                dispatchMain()
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    var body: some Scene {
        // Window (not WindowGroup): singleton scenes — openWindow(id:) then
        // reuses/activates the existing window instead of spawning a fresh
        // duplicate on every "Ask the Brain" / "Open Main Window" click.
        Window("Moppet", id: "main") {
            RootView()
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 700)

        Window("Pet Chat", id: "chat") {
            ChatView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 640)

        // Menu-bar item lives in the SwiftUI scene world, so it keeps a
        // working `openWindow` even when every document window is closed —
        // the missing piece that made "Open Main Window" a no-op.
        MenuBarExtra {
            MenuBarContent()
        } label: {
            // Monochrome template glyph: a colored app icon next to the other
            // white menu-bar symbols looked pasted-on. `cat.fill` matches the
            // system style and still reads as the Moppet mascot.
            Image(systemName: "cat.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Brand mark for the sidebar / title bar — the FULL app icon (rounded
/// background included). The transparent menu-bar crop reads as a muddy
/// smudge at 14–20pt; the app icon stays clean at those sizes.
enum MoppetBrandIcon {
    static let image: NSImage = {
        Bundle.module.image(forResource: "brand")
            ?? NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Moppet")
            ?? NSImage()
    }()
}

/// Menu-bar quick actions (replaces the hand-rolled NSStatusItem).
private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("Show / Hide Pet")) {
            let controller = PetPanelController.shared
            controller.isVisible ? controller.hide() : controller.show()
        }
        .keyboardShortcut("p", modifiers: .command)
        .onAppear {
            WindowRouter.shared.openMainHandler = { openWindow(id: "main") }
            WindowRouter.shared.openChatHandler = { openWindow(id: "chat") }
        }
        Divider()
        Button(L("Open Main Window")) { WindowRouter.shared.showMain() }
            .keyboardShortcut("m", modifiers: .command)
        Button(L("Open AI Chat")) { WindowRouter.shared.showChat() }
            .keyboardShortcut("c", modifiers: .command)
        // Settings lives on a main-window route; ⌘, is the macOS convention
        // every user tries first.
        Button(L("Settings…")) { WindowRouter.shared.showMain(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NotificationCenter.default.post(name: .moppetNavigateSettings, object: nil) } }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button(L("Quick Scan & Clean…")) { QuickScan.run() }
            .keyboardShortcut("s", modifiers: .command)
        Divider()
        Button(L("Quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

/// Tags the hosting window with a stable identifier so WindowRouter (and the
/// pet menu) can find/focus it from AppKit.
struct WindowIdentifierTagger: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView { TaggerView(id: id) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class TaggerView: NSView {
        private let id: String
        init(id: String) { self.id = id; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("unsupported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window.identifier?.rawValue != id {
                window.identifier = NSUserInterfaceItemIdentifier(id)
            }
        }
    }
}

/// Cross-window navigation: the menu bar can't reach RootView's route
/// binding, so ⌘, broadcasts and RootView listens (main window may not be
/// open yet — showMain() above reopens it first).
extension Notification.Name {
    static let moppetNavigateSettings = Notification.Name("moppet.navigate.settings")
    static let moppetNavigateClean = Notification.Name("moppet.navigate.clean")
    static let moppetLanguageChanged = Notification.Name("moppet.language.changed")
}

// MARK: - Sidebar navigation

enum Route: String, Hashable, CaseIterable, Identifiable {
    case dashboard, clean, orphans, uninstall, optimize, startup, analyze, status,
         purge, slim, hogs, largeFiles, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: L("Dashboard")
        // Concrete row names: the band header already says "Space Cleanup",
        // so a row also called "Clean" read as the same thing twice.
        case .clean: L("Cache Clean")
        case .uninstall: L("App Uninstall")
        case .optimize: L("Optimize")
        case .startup: L("Startup")
        case .analyze: L("Analyze")
        case .status: L("Status")
        case .purge: L("Project Cleanup")
        case .slim: L("Slim")
        case .hogs: L("Space Hogs")
        case .largeFiles: L("Large Files")
        case .orphans: L("Orphans")
        case .history: L("History")
        case .settings: L("Settings")
        }
    }

    var icon: String {
        switch self {
        // One glyph family, all outline: every symbol below is a linear SF
        // Symbol at the same optical weight. `tray.full` (a filled stack) and
        // `square.and.arrow.down.on.square` (a dense double-frame) were the
        // two marks that read as a different icon set.
        case .dashboard: "square.grid.2x2"
        case .clean: "paintbrush"
        case .uninstall: "trash"
        case .optimize: "wand.and.rays"
        case .startup: "power"
        case .analyze: "chart.bar.xaxis"
        case .status: "cpu"
        case .purge: "shippingbox"
        case .slim: "scissors"
        case .hogs: "internaldrive"
        case .largeFiles: "doc.text.magnifyingglass"
        case .orphans: "tray"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    /// mole command equivalence shown as a tiny caption in the sidebar.
}

struct RootView: View {
    @SceneStorage("route.selected") private var route: Route = .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Bumped on language change — .id() on the split view forces every
    /// visible L() call to re-resolve (sidebar included).
    @State private var languageRevision = 0
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Bound (not .constant) so the system title-bar sidebar toggle works —
        // a constant binding swallows the toggle's writes and the button
        // appears dead.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            // NOTE: no .id(route) and no withAnimation on switches — the
            // switch already swaps view identity (fresh @State per module),
            // and forcing a full-column teardown/insert animation measured
            // 150–750ms per click on Intel. DeferredView then commits the
            // route change instantly and builds the heavy tree next frame.
            DeferredView {
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowVibrancy())
        .background(WindowIdentifierTagger(id: WindowRouter.mainWindowID))
        .onAppear {
            // The main window is the app's primary scene-scoped context —
            // register openWindow with the router so the pet panel and the
            // menu bar can reopen/focus windows from AppKit at any time.
            WindowRouter.shared.openMainHandler = { openWindow(id: "main") }
            WindowRouter.shared.openChatHandler = { openWindow(id: "chat") }
        }
        // In-window shortcuts: MenuBarExtra (.menu) key equivalents only fire
        // while its menu is OPEN, so ⌘, never reached Settings from the main
        // window. A hidden button inside the window works whenever it is key.
        .background {
            Group {
                Button("") { route = .settings }
                    .keyboardShortcut(",", modifiers: .command)
                Button("") { QuickScan.run() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .moppetNavigateClean)) { _ in
            route = .clean
        }
        .onReceive(NotificationCenter.default.publisher(for: .moppetLanguageChanged)) { _ in
            // Force the whole tree (sidebar included) to re-evaluate L().
            languageRevision += 1
        }
        .id(languageRevision)
        .onReceive(NotificationCenter.default.publisher(for: .moppetNavigateSettings)) { _ in
            route = .settings
        }
        .task {
            await routePerfProbe()
            await analyzeRingProbe()
        }
    }

    /// `--probe-analyze`: jump straight to the Analyze page so the centered
    /// delete ring (seeded by `AnalyzeView` under the same flag) can be
    /// inspected without deleting anything real.
    private func analyzeRingProbe() async {
        guard CommandLine.arguments.contains("--probe-analyze") else { return }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        route = .analyze
    }

    /// `--route-perf`: cycle through every route and log commit/render cost
    /// to stderr — measures sidebar-switch latency on this machine.
    private func routePerfProbe() async {
        guard CommandLine.arguments.contains("--route-perf") else { return }
        let routes: [Route] = [.clean, .uninstall, .optimize, .analyze,
                               .status, .purge, .history, .settings, .dashboard]
        for lap in 1...2 {
            for probe in routes {
                try? await Task.sleep(nanoseconds: 1_200_000_000)   // settle
                let t0 = CFAbsoluteTimeGetCurrent()
                route = probe
                DispatchQueue.main.async {
                    let commit = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    DispatchQueue.main.async {
                        let render = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                        FileHandle.standardError.write(Data(
                            "route-perf lap\(lap) \(probe.rawValue): commit \(Int(commit))ms render \(Int(render))ms\n".utf8))
                    }
                }
            }
        }
    }

    // MARK: - Sidebar
    /// The panel itself lives in SidebarPanel.swift (brand header, grouped
    /// route list, pet footer) so its spacing ladder is testable on its own.
    private var sidebar: some View {
        SidebarPanel(route: $route)
    }

    private func backToDashboard() {
        route = .dashboard
    }

    /// ⌘1…⌘9 jumps to the first nine sidebar routes (dashboard first),
    /// giving the whole app keyboard navigation without touching the flow.
    static func routeShortcut(_ route: Route) -> KeyboardShortcut? {
        // Same order as RouteGroup so the shortcut number matches what the
        // eye counts in the sidebar (rows are reordered, shortcuts follow).
        let ordered: [Route] = [.dashboard, .clean, .uninstall, .orphans, .purge,
                                .slim, .hogs, .largeFiles, .optimize, .startup,
                                .status, .analyze, .history, .settings]
        guard let index = ordered.firstIndex(of: route), index < 9 else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch route {
        case .dashboard:
            HomeView(navigate: { route = $0 }, openChat: { openWindow(id: "chat") })
        case .clean:
            CleanView(onClose: backToDashboard)
        case .orphans:
            OrphansView(onClose: backToDashboard)
        case .uninstall:
            UninstallView(onClose: backToDashboard)
        case .optimize:
            OptimizeView(onClose: backToDashboard)
        case .startup:
            LaunchItemsView(onClose: backToDashboard)
        case .analyze:
            AnalyzeView(onClose: backToDashboard)
        case .status:
            StatusView(onClose: backToDashboard)
        case .purge:
            PurgeView(onClose: backToDashboard)
        case .slim:
            SlimView(onClose: backToDashboard)
        case .hogs:
            SystemHogsView(onClose: backToDashboard)
        case .largeFiles:
            LargeFilesView(onClose: backToDashboard)
        case .history:
            HistoryView(onClose: backToDashboard)
        case .settings:
            SettingsView(onClose: backToDashboard)
        }
    }
}

/// Builds its content one transaction after insertion: the route switch
/// commits instantly (sidebar highlight + light placeholder), the heavy view
/// tree constructs on the next frame. Full construction measured 80–750ms
/// per module on this Intel/debug build — deferring keeps clicks feeling
/// immediate instead of "stuck".
struct DeferredView<V: View>: View {
    @State private var ready = false
    let content: () -> V

    var body: some View {
        Group {
            if ready {
                content()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Sleep guarantees the placeholder paints before the heavy build —
        // a bare task can coalesce into the first transaction.
        .task {
            try? await Task.sleep(nanoseconds: 30_000_000)
            ready = true
        }
    }
}
