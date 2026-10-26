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
                                       "--probe-models", "--route-perf", "--win-debug"]
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
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.menu)
    }
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
    case dashboard, clean, uninstall, optimize, startup, analyze, status, purge, slim, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: L("Dashboard")
        case .clean: L("Clean")
        case .uninstall: L("Uninstall")
        case .optimize: L("Optimize")
        case .startup: L("Startup")
        case .analyze: L("Analyze")
        case .status: L("Status")
        case .purge: L("Purge")
        case .slim: L("Slim")
        case .history: L("History")
        case .settings: L("Settings")
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .clean: "paintbrush"
        case .uninstall: "square.and.arrow.down.on.square"
        case .optimize: "wand.and.rays"
        case .startup: "power"
        case .analyze: "chart.bar.doc.horizontal"
        case .status: "cpu"
        case .purge: "shippingbox"
        case .slim: "scissors"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    /// mole command equivalence shown as a tiny caption in the sidebar.
}

/// Sidebar grouping by importance: Dashboard → daily cleaning tools →
/// system tools → History, with Settings pinned LAST (macOS convention).
/// Four labelled/unlabelled bands, rendered top to bottom.
private enum RouteGroup {
    static let top: [(label: String, routes: [Route])] = [
        ("", [.dashboard]),
    ]
    static let cleaning: [(label: String, routes: [Route])] = [
        (L("Clean"), [.clean, .uninstall, .purge, .slim]),
    ]
    static let system: [(label: String, routes: [Route])] = [
        (L("System"), [.optimize, .startup, .status, .analyze]),
    ]
    static let bottom: [(label: String, routes: [Route])] = [
        ("", [.history, .settings]),
    ]
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
        .task { await routePerfProbe() }
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
    private var sidebar: some View {
        VStack(spacing: 0) {
            // brand header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Airi.primary)
                Text("Moppet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Airi.neutral950)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    sidebarSection(rows: RouteGroup.top)
                    sidebarSection(rows: RouteGroup.cleaning)
                    sidebarSection(rows: RouteGroup.system)
                    sidebarSection(rows: RouteGroup.bottom)
                }
                .padding(.horizontal, 10)
            }

            Divider().overlay(Airi.neutral200.opacity(0.5))
            // footer: pet toggle — PetPanelVisibilityFlag is @Observable, so
            // the eye tracks the actual panel state (previously it read a
            // plain controller property in body and never refreshed).
            HStack(spacing: 8) {
                Image(systemName: "pawprint.fill")
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.primary)
                Text(String(format: L("%@ · desktop pet"), PetIdentity.name))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
                    .lineLimit(1)
                Spacer()
                Button {
                    PetPanelController.shared.isVisible
                        ? PetPanelController.shared.hide()
                        : PetPanelController.shared.show()
                } label: {
                    Image(systemName: PetPanelVisibilityFlag.shared.visible
                          ? "eye" : "eye.slash")
                        .font(Airi.footnoteFont)
                        .foregroundStyle(Airi.neutral500)
                }
                .buttonStyle(.plain)
                .help(L("Show / hide the pet"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        // Keep the sidebar a usable width when the window narrows — without
        // a floor, .balanced style crushes it until row titles wrap mid-word.
        .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 288)
    }

    private func backToDashboard() {
        route = .dashboard
    }

    // MARK: - Sidebar

    /// One labelled band of routes ("Clean", "System", …). Empty label =
    /// no section header (the Dashboard's band stays unmarked).
    @ViewBuilder
    private func sidebarSection(rows: [(label: String, routes: [Route])]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            if !row.label.isEmpty {
                Text(row.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Airi.neutral400)
                    .textCase(.uppercase)
                    .padding(.leading, 10)
                    .padding(.top, 2)
            }
            ForEach(row.routes) { item in
                sidebarRow(item)
            }
        }
    }

    private func sidebarRow(_ item: Route) -> some View {
        let isActive = route == item
        return SidebarRowButton(item: item, isActive: isActive) {
            route = item
        }
        .keyboardShortcut(Self.routeShortcut(item))
    }

    /// ⌘1…⌘9 jumps to the first nine sidebar routes (dashboard first),
    /// giving the whole app keyboard navigation without touching the flow.
    private static func routeShortcut(_ route: Route) -> KeyboardShortcut? {
        let ordered: [Route] = [.dashboard, .clean, .uninstall, .purge, .slim,
                                .optimize, .startup, .status, .analyze, .history, .settings]
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
        case .history:
            HistoryView(onClose: backToDashboard)
        case .settings:
            SettingsView(onClose: backToDashboard)
        }
    }
}

/// Sidebar row with hover feedback — the plain Button had no hover state, so
/// rows only reacted on click (off-pattern for macOS list navigation).
private struct SidebarRowButton: View {
    let item: Route
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(Airi.bodyFont)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isActive ? Airi.primary : Airi.neutral500)
                    .frame(width: 20)
                Text(item.title)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Airi.primary : Airi.neutral800)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Airi.primary.opacity(0.1)
                          : hovering ? Airi.neutral100.opacity(0.6) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Airi.controlAnimation, value: hovering)
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
