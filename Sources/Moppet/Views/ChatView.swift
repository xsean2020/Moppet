import SwiftUI
import MarkdownUI
import AppKit
import UniformTypeIdentifiers

/// One user-attached image (chip above the composer until sent).
struct ChatAttachment: Identifiable {
    let id = UUID()
    let dataURL: String
    let image: NSImage

    init?(data: Data) {
        guard let mime = BrainTools.imageMIME(data),
              let image = NSImage(data: data) else { return nil }
        self.image = image
        self.dataURL = "data:\(mime);base64," + data.base64EncodedString()
    }

    init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL), data.count <= 10 * 1_048_576 else { return nil }
        self.init(data: data)
    }
}

/// A slash command (codex TUI commands, expressed as chat-UI actions).
struct SlashCommand {
    let name: String          // "/compact"
    let summary: String
    let icon: String

    static let all: [SlashCommand] = [
        SlashCommand(name: "/help", summary: L("list commands"), icon: "questionmark.circle"),
        SlashCommand(name: "/status", summary: L("session config + token usage"), icon: "info.circle"),
        SlashCommand(name: "/mcp", summary: L("connected MCP servers & tools"), icon: "server.rack"),
        SlashCommand(name: "/new", summary: L("start a new chat"), icon: "plus.circle"),
        SlashCommand(name: "/compact", summary: L("summarize history to free context"), icon: "square.compress.vertical"),
        SlashCommand(name: "/init", summary: L("have the agent write AGENTS.md for this folder"), icon: "doc.badge.plus"),
        SlashCommand(name: "/diff", summary: L("git diff of the workspace"), icon: "arrow.triangle.branch"),
        SlashCommand(name: "/pwd", summary: L("print working directory"), icon: "folder"),
        SlashCommand(name: "/cd", summary: L("/cd <path> — change working directory"), icon: "folder.badge.gear"),
        SlashCommand(name: "/ps", summary: L("running exec sessions"), icon: "terminal"),
        SlashCommand(name: "/stop", summary: L("/stop [id] — stop exec sessions"), icon: "stop.circle"),
        SlashCommand(name: "/export", summary: L("export chat as Markdown"), icon: "square.and.arrow.up"),
        SlashCommand(name: "/copy", summary: L("copy last reply"), icon: "doc.on.doc"),
    ]
}

/// Ephemeral command output (TUI popups → chat cards; never persisted to
/// the rollout, matching how codex slash results are UI-only).
struct ChatNotice: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
}

/// AI chat window — full session management over agent rollouts:
/// sidebar (new / switch / delete sessions) + the ported Codex agent,
/// streaming markdown, native approval dialogs for destructive tools,
/// slash commands, image attachments and structured model questions.
struct ChatView: View {
    @State private var store = ChatSessionStore()
    @State private var aiSettings = AISettings.load()
    @State private var draft = ""
    @State private var sessionToDelete: ChatSessionStore.SessionInfo?
    /// Sidebar batch-delete: checklist toggle in the header puts rows into
    /// selection mode (tap toggles instead of resuming).
    @State private var selectMode = false
    @State private var selectedSessions: Set<String> = []
    @State private var confirmingBatchDelete = false
    /// True while a deletion is in flight — disables the confirm button and
    /// shows a spinner so the user knows the click registered.
    @State private var isDeleting = false
    /// Pending user-attached images (sent with the next message).
    @State private var attachments: [ChatAttachment] = []
    /// Ephemeral slash-command output cards.
    @State private var notices: [ChatNotice] = []
    /// Transcript auto-follow (off while the user reads above the fold).
    @State private var autoFollow = true
    /// Captured from the transcript's ScrollViewReader — session switches
    /// need to reset scroll from OUTSIDE that reader's scope.
    @State private var scrollProxy: ScrollViewProxy?
    /// Expanded tool-output blocks (lineLimit off).
    @State private var expandedOutputs: Set<Int> = []
    /// Expanded reasoning summaries.
    @State private var expandedReasoning: Set<Int> = []
    /// User-defined provider profiles, snapshotted once per change instead of
    /// re-read per render: `providerOptions` used to call
    /// `AIProviderRegistry.load()` — open + JSON-decode a file — from inside
    /// the composer's body, and the chat body re-evaluates on every streamed
    /// token (dozens of times per second while an answer is being written).
    @State private var providerProfiles: [AIProviderProfile] = []
    @FocusState private var inputFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    /// The chat IS the pet's Brain — one engine (the ported Codex agent),
    /// no separate "assistant" mode.
    private var brain: BrainAgent { store.brain }

    private var slashMatches: [SlashCommand] {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return [] }
        return SlashCommand.all.filter { $0.name.hasPrefix(trimmed) || trimmed.hasPrefix($0.name) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sessionSidebar
            Divider().overlay(Airi.neutral200)
            mainColumn
        }
        .background(WindowVibrancy())
        .background(WindowIdentifierTagger(id: WindowRouter.chatWindowID))
        .frame(minWidth: 760, minHeight: 560)
        .sheet(item: $sessionToDelete) { info in
            deletionConfirm(info)
        }
        .sheet(isPresented: $confirmingBatchDelete) {
            batchDeletionConfirm()
        }
        .sheet(item: approvalBinding) { request in
            ApprovalSheet(request: request)
        }
        .sheet(item: userInputBinding) { request in
            UserInputSheet(request: request)
        }
        .onAppear {
            // Next runloop: openWindow creates the window asynchronously —
            // focusing synchronously during onAppear can reach IMK while the
            // window isn't key yet (IMKCFRunLoopWakeUpReliable log noise).
            // Focus only once Moppet is active AND this window is key.
            // Focusing from a background context starts an IME session the
            // app doesn't own yet — macOS logs the IMK/TSM diagnostics and
            // the first Chinese keystroke can be dropped (see TextFocus).
            TextFocus.whenReady({
                NSApp.isActive
                    && NSApp.keyWindow?.identifier?.rawValue == WindowRouter.chatWindowID
                    && NSApp.keyWindow?.isKeyWindow == true
            }) {
                inputFocused = true
            }
            aiSettings = AISettings.load()
            providerProfiles = AIProviderRegistry.load()
            UserInputCenter.chatSurfaceVisible = true
            // While the chat window lives, it can also reopen both windows
            // for the router (pet panel / menu bar).
            WindowRouter.shared.openMainHandler = { openWindow(id: "main") }
            WindowRouter.shared.openChatHandler = { openWindow(id: "chat") }
            // Pet announcements (error/approval) are wired in
            // ChatSessionStore.makeAgent so they survive session switches;
            // turnCompleted is never announced (BrainAgent.runLoop already
            // speaks the answer's tail — double-broadcast bug).
        }
        .onDisappear {
            UserInputCenter.chatSurfaceVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(
            for: AIProviderRegistry.changedNotification)) { _ in
            // Settings added/renamed/removed a provider profile — refresh the
            // snapshot the picker reads (see `providerProfiles`).
            providerProfiles = AIProviderRegistry.load()
        }
        .onChange(of: store.currentSessionID) { _, _ in
            notices = []
            // Per-offset expand/collapse state must not leak into the next
            // session (ids are offsets, not content)…
            expandedOutputs = []
            expandedReasoning = []
            // …and the scroll position belongs to the previous transcript.
            autoFollow = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                scrollProxy?.scrollTo("brain-bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Session sidebar

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.primary)
                Text(L("Chats"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Airi.neutral950)
                Spacer()
                Button {
                    selectMode.toggle()
                    selectedSessions = []
                } label: {
                    Image(systemName: "checklist")
                        .font(Airi.captionFont)
                        .foregroundStyle(selectMode ? Airi.primary : Airi.neutral400)
                }
                .buttonStyle(.plain)
                .help(L("Select sessions"))
                Button {
                    store.newSession()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Airi.primary)
                }
                .buttonStyle(.plain)
                .help(L("New chat"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            if selectMode {
                batchActionBar
                Divider().overlay(Airi.neutral200.opacity(0.5))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.sessions) { info in
                        sessionRow(info)
                    }
                    if store.sessions.isEmpty {
                        Text(L("No sessions yet"))
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.neutral500)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Spacer()
            Divider().overlay(Airi.neutral200.opacity(0.5))
            Text(footerCountText)
                .font(Airi.caption2Font)
                .foregroundStyle(Airi.neutral500)
                .padding(.vertical, 8)
        }
        .frame(width: 208)
        .background(.ultraThinMaterial)
    }

    /// True on-disk session count; the sidebar list is only the recent
    /// window — with more sessions than the cap, showing the list count
    /// made deletions look like no-ops ("still 50").
    private var footerCountText: String {
        var text = String(format: L("%lld sessions"), store.totalSessions)
        if store.totalSessions > store.sessions.count {
            text += " · " + String(format: L("recent %lld"), store.sessions.count)
        }
        return text + " · rollout JSONL"
    }

    /// Selection-mode toolbar: count + select-all + delete entry.
    private var batchActionBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedSessions.count)/\(store.sessions.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Airi.neutral500)
                .monospacedDigit()
            Spacer()
            Button(selectedSessions.count == store.sessions.count
                   && !store.sessions.isEmpty ? L("Deselect all") : L("Select all")) {
                if selectedSessions.count == store.sessions.count {
                    selectedSessions = []
                } else {
                    selectedSessions = Set(store.sessions.map(\.id))
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Airi.primary)
            if !selectedSessions.isEmpty {
                Button(L("Delete")) { confirmingBatchDelete = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Airi.danger)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sessionRow(_ info: ChatSessionStore.SessionInfo) -> some View {
        let isActive = info.id == store.currentSessionID
        let isSelected = selectedSessions.contains(info.id)
        return HStack(spacing: 6) {
            if selectMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(Airi.footnoteFont)
                    .foregroundStyle(isSelected ? Airi.primary : Airi.neutral400)
            } else {
                Image(systemName: isActive ? "dot.radiowaves.left.and.right" : "message")
                    .font(Airi.caption2Font)
                    .foregroundStyle(isActive ? Airi.primary : Airi.neutral400)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title)
                    .font(.system(size: 11, weight: isActive || isSelected ? .medium : .regular))
                    .foregroundStyle(isActive || isSelected ? Airi.primary : Airi.neutral800)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(info.date.formatted(date: .abbreviated, time: .shortened))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
            }
            Spacer(minLength: 0)
            if !selectMode {
                Button {
                    sessionToDelete = info
                } label: {
                    Image(systemName: "trash")
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral400)
                }
                .buttonStyle(.plain)
                .help(L("Delete session"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Airi.primary.opacity(0.1)
                      : isSelected ? Airi.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if selectMode {
                if isSelected { selectedSessions.remove(info.id) } else { selectedSessions.insert(info.id) }
            } else {
                store.resume(info)
            }
        }
    }

    private func deletionConfirm(_ info: ChatSessionStore.SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: Airi.space3) {
            Label(L("Delete chat?"), systemImage: "trash")
                .font(.system(size: 14, weight: .medium))
            Text(String(format: L("\"%@\" and its rollout history will be removed. This cannot be undone."),
                        info.title))
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral500)
            HStack {
                Spacer()
                AiriButton(title: L("Cancel"), variant: .secondary) { sessionToDelete = nil }
                AiriButton(title: L("Delete"), variant: .destructive, disabled: isDeleting, busy: isDeleting) {
                    isDeleting = true
                    Task {
                        store.delete(info)
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        isDeleting = false
                        sessionToDelete = nil
                    }
                }
            }
        }
        .padding(Airi.space4)
        .frame(width: 380)
    }

    private func batchDeletionConfirm() -> some View {
        VStack(alignment: .leading, spacing: Airi.space3) {
            Label(L("Delete chats?"), systemImage: "trash")
                .font(.system(size: 14, weight: .medium))
            Text(String(format: L("%lld chats and their rollout history will be removed. This cannot be undone."),
                        selectedSessions.count))
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral500)
            HStack {
                Spacer()
                AiriButton(title: L("Cancel"), variant: .secondary) { confirmingBatchDelete = false }
                AiriButton(title: L("Delete"), variant: .destructive, disabled: isDeleting, busy: isDeleting) {
                    isDeleting = true
                    Task {
                        store.deleteAll(Array(selectedSessions))
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        selectedSessions = []
                        selectMode = false
                        isDeleting = false
                        confirmingBatchDelete = false
                    }
                }
            }
        }
        .padding(Airi.space4)
        .frame(width: 380)
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            header
            transcript
            // Sandbox / approval live directly above the composer: they are
            // per-turn run controls, not header identity chrome.
            brainControls
            composer
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    /// Drag & drop of image files anywhere in the chat column. File drops
    /// arrive as public.file-url providers (NOT public.image), so URLs are
    /// loaded and filtered by extension; in-pasteboard image data takes the
    /// direct path.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(for: UTType.image) { data, _ in
                    guard let data, let attachment = ChatAttachment(data: data) else { return }
                    DispatchQueue.main.async {
                        if attachments.count < 4 { attachments.append(attachment) }
                    }
                }
                accepted = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadDataRepresentation(for: UTType.fileURL) { data, _ in
                    guard let data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          ["png", "jpg", "jpeg", "gif", "webp"]
                              .contains(url.pathExtension.lowercased()),
                          let attachment = ChatAttachment(fileURL: url) else { return }
                    DispatchQueue.main.async {
                        if attachments.count < 4 { attachments.append(attachment) }
                    }
                }
                accepted = true
            }
        }
        return accepted
    }

    private var header: some View {
        HStack(spacing: Airi.space2) {
            PetStickerAvatar(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(PetIdentity.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Airi.neutral950)
                Text(headerSubtitle)
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
                    .lineLimit(1)
            }
            Spacer()
            if brain.isRunning {
                ProgressView().controlSize(.mini)
            }
            // The window style is hiddenTitleBar, so there are no traffic
            // lights — provide an explicit close button.
            CircleIconButton(icon: "xmark.circle.fill") { dismiss() }
                .help(L("Close"))
        }
        .padding(Airi.space3)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider().overlay(Airi.neutral200.opacity(0.5)) }
    }

    private var headerSubtitle: String {
        var parts: [String] = []
        parts.append(aiSettings.isConfigured ? aiSettings.model : L("set an API key in Settings"))
        parts.append(L("sandbox") + " \(brain.sandboxMode.rawValue)")
        if let usage = brain.lastUsage {
            parts.append("\(usage.totalTokens) tk")
        }
        return parts.joined(separator: " · ")
    }

    /// Per-turn run controls, docked right above the composer so they read as
    /// "how this next message runs" rather than window chrome. Provider/model
    /// pickers write through `AISettingsCoordinator` so Settings and the
    /// quick-chat panel cascade to the same choice (and vice versa). Menus
    /// hug their content — fixed widths truncated values ("De…",
    /// "On request (model…"), so keep them flexible and put the full
    /// semantics in tooltips.
    private var brainControls: some View {
        HStack(spacing: Airi.space2) {
            Picker("Provider", selection: chatProviderBinding) {
                ForEach(providerOptions) { option in
                    switch option {
                    case .builtin(let vendor): Text(vendor.shortName).tag(option)
                    case .profile: Text(option.label).tag(option)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 140)
            .help(L("AI provider — applies app-wide (Settings syncs)"))

            Picker("Model", selection: chatModelBinding) {
                ForEach(chatModelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 220)
            .help(L("Model — type a custom id in Settings → AI Provider"))

            Spacer(minLength: Airi.space2)

            // codex sandbox_workspace_write.network_access — only meaningful
            // in workspace-write; toggling rebuilds the seatbelt profile.
            if brain.sandboxMode == .workspaceWrite {
                Button {
                    store.brain.networkAccess.toggle()
                } label: {
                    Image(systemName: brain.networkAccess ? "network" : "network.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(brain.networkAccess ? Airi.primary : Airi.neutral400)
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Sandbox network — on: commands may reach the network in workspace-write; off: fully offline"))
            }

            // Hosted web search (codex web_search) — Responses backend only.
            if brain.settings.vendor.usesCodexResponsesTransport {
                Button {
                    store.brain.setWebSearch(!store.brain.webSearchEnabled)
                } label: {
                    Image(systemName: "magnifyingglass.circle\(store.brain.webSearchEnabled ? ".fill" : "")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(store.brain.webSearchEnabled ? Airi.primary : Airi.neutral400)
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Web search — server-side search on the ChatGPT backend (codex hosted web_search)"))
            }

            if brain.isRunning {
                AiriButton(title: L("Stop"), icon: "stop.fill", variant: .destructive) {
                    brain.cancel()
                }
            }

            Picker("Approval", selection: Binding(
                get: { brain.approvalPolicy },
                set: { store.brain.approvalPolicy = $0 }
            )) {
                ForEach(BrainApprovalPolicy.allCases) { policy in
                    Text(policy.shortName).tag(policy)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help(L("Approval — Ask always: confirm every command · On request: the model decides when to escalate · Never ask: auto-run"))

            Picker("Sandbox", selection: Binding(
                get: { brain.sandboxMode },
                set: { store.brain.sandboxMode = $0 }
            )) {
                ForEach(BrainSandboxMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help(L("Sandbox — Read-only · Workspace write: edits limited to the working directory · Full access (danger)"))
        }
        .padding(.horizontal, Airi.space3)
        .padding(.vertical, Airi.space2)
        .overlay(alignment: .top) { Divider().overlay(Airi.neutral200.opacity(0.4)) }
        .onReceive(NotificationCenter.default.publisher(
            for: AISettingsCoordinator.changedNotification)) { _ in
            // Another surface (quick panel / Settings) changed the model —
            // cascade into this window's live agent and refresh the header
            // subtitle, which reads the settings snapshot directly.
            aiSettings = AISettings.load()
            store.brain.refreshModel()
        }
    }

    /// Built-in vendors + user-defined provider profiles (ZCode-style
    /// providerId/modelId — see AIProviders.swift).
    private var providerOptions: [AIProviderOption] {
        AIVendor.allCases.map(AIProviderOption.builtin)
            + providerProfiles.map { AIProviderOption.profile($0.id) }
    }

    private var chatProviderBinding: Binding<AIProviderOption> {
        Binding(
            get: { brain.settings.providerOption },
            set: { AISettingsCoordinator.apply(option: $0) }
        )
    }

    private var chatModelBinding: Binding<String> {
        Binding(
            get: { brain.settings.model },
            set: { AISettingsCoordinator.apply(model: $0) }
        )
    }

    /// The active provider's model catalog (API-refreshed, user-editable in
    /// Settings), plus the current value when it is a custom (free-typed) id.
    private var chatModelOptions: [String] {
        var options: [String]
        if let profileID = brain.settings.activeProfileID {
            options = AIModelCatalog.models(forProfile: profileID)
        } else {
            options = AIModelCatalog.models(for: brain.settings.vendor)
        }
        let current = brain.settings.model
        if !current.isEmpty, !options.contains(current) {
            options.insert(current, at: 0)
        }
        return options
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: Airi.space2) {
                        brainTranscript
                        // Visibility sentinel: scrolled to (or past) the
                        // bottom → follow; user scrolled up → pause. The old
                        // code force-scrolled on EVERY streaming delta, so a
                        // long answer could never be read while streaming.
                        Color.clear.frame(height: 1)
                            .id("brain-bottom")
                            .onAppear { autoFollow = true }
                            .onDisappear { autoFollow = false }
                    }
                    .padding(Airi.space3)
                }
                if !autoFollow {
                    Button {
                        autoFollow = true
                        withAnimation(Airi.controlAnimation) {
                            proxy.scrollTo("brain-bottom", anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Airi.primary)
                            .background(Circle().fill(Airi.cardBackground))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, Airi.space3)
                    .padding(.bottom, Airi.space2)
                    .help(L("Back to bottom"))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(Airi.controlAnimation, value: autoFollow)
            .onAppear { scrollProxy = proxy }
            .onChange(of: brain.items.count) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: brain.streamingText) { _, newValue in
                guard !newValue.isEmpty else { return }
                if autoFollow {
                    proxy.scrollTo("brain-streaming", anchor: .bottom)
                }
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard autoFollow else { return }
        if let last = brain.items.indices.last {
            withAnimation(Airi.controlAnimation) {
                proxy.scrollTo("brain-\(last + 1)", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var brainTranscript: some View {
        if brain.items.isEmpty && brain.streamingText.isEmpty && notices.isEmpty {
            emptyHint(String(format: L("Chat with %@ — the desktop pet with a Codex-grade agent brain: shell, resumable exec, file patches, images, plans, cleaning tools, MCP. Type / for commands."),
                             PetIdentity.name))
        }
        ForEach(Array(brain.items.enumerated()), id: \.offset) { index, item in
            brainBubble(item, index: index)
                .id("brain-\(index + 1)")
        }
        if !brain.streamingText.isEmpty {
            streamingBubble(brain.streamingText)
                .id("brain-streaming")
        }
        if let toolLine = brain.lastToolLine, brain.isRunning {
            Text(toolLine)
                .font(Airi.monoCaption2Font)
                .foregroundStyle(Airi.neutral500)
                .id("brain-tool")
        }
        if let error = brain.lastError {
            // "cancelled" (user pressed Stop) is not a failure — render it as
            // a neutral note instead of a red error row.
            let cancelled = error == "cancelled"
            Label(cancelled ? L("Turn cancelled") : error,
                  systemImage: cancelled ? "stop.circle" : "exclamationmark.triangle.fill")
                .font(Airi.footnoteFont)
                .foregroundStyle(cancelled ? Airi.neutral500 : Airi.danger)
                .id("brain-error")
        }
        ForEach(notices) { notice in
            noticeCard(notice)
        }
    }

    /// Slash-command output card (ephemeral, rollout-free).
    private func noticeCard(_ notice: ChatNotice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.icon)
                .font(Airi.footnoteFont)
                .foregroundStyle(Airi.primary)
            Text(notice.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Airi.neutral700)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusCard)
                .fill(Airi.primary.opacity(0.06))
        )
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(Airi.captionFont)
            .foregroundStyle(Airi.neutral500)
            .multilineTextAlignment(.center)
            .padding(.top, 28)
            .padding(.horizontal, 24)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if !slashMatches.isEmpty {
                slashPalette
            }
            if !attachments.isEmpty {
                attachmentChips
            }
            HStack(spacing: Airi.space2) {
                CircleIconButton(icon: "paperclip") { pickImageAttachment() }
                    .help(L("Attach image (or drag & drop / paste)"))
                TextField(String(format: L("Chat with %@ — clean, build, fix, analyze…  ( / for commands )"),
                                 PetIdentity.name),
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Airi.bodyFont)
                    .lineLimit(1...4)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: Airi.radiusControl)
                            .fill(Airi.neutral50)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Airi.radiusControl)
                            .strokeBorder(Airi.neutral200, lineWidth: 2)
                    )
                    .focused($inputFocused)
                    // Explicit focus: click-derived first responder can be flaky
                    // for terminal-launched apps (isActive=false at launch).
                    .onTapGesture { inputFocused = true }
                    // Vertical-axis TextFields never fire onSubmit on macOS
                    // (Return inserts a newline) — intercept the key itself:
                    // Return sends, Shift+Return inserts a newline.
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        send()
                        return .handled
                    }
                    .onSubmit { send() }
                // Secondary action first, primary (Send) rightmost.
                CircleIconButton(icon: "arrow.counterclockwise") { store.newSession() }
                    .help(L("New chat"))
                AiriButton(title: L("Send"), icon: "arrow.up.circle.fill",
                           disabled: brain.isRunning) { send() }
            }
            .padding(Airi.space3)
        }
        .background(.ultraThinMaterial)
        // Separate the run controls strip from the composer — without this
        // the two rows read as one dense block.
        .overlay(alignment: .top) { Divider().overlay(Airi.neutral200.opacity(0.5)) }
        .onPasteCommand(of: [.image]) { providers in
            for provider in providers {
                _ = provider.loadDataRepresentation(for: UTType.image) { data, _ in
                    guard let data, let attachment = ChatAttachment(data: data) else { return }
                    DispatchQueue.main.async {
                        if attachments.count < 4 { attachments.append(attachment) }
                    }
                }
            }
        }
    }

    /// Command palette filtered by the draft (codex slash popup equivalent).
    private var slashPalette: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slashMatches, id: \.name) { command in
                Button {
                    draft = command.name + " "
                    inputFocused = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: command.icon)
                            .font(Airi.footnoteFont)
                            .foregroundStyle(Airi.primary)
                            .frame(width: 16)
                        Text(command.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Airi.neutral900)
                        Text(command.summary)
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral500)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider().overlay(Airi.neutral200.opacity(0.5)) }
    }

    private var attachmentChips: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { attachment in
                HStack(spacing: 4) {
                    Image(nsImage: attachment.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Button {
                        attachments.removeAll { $0.id == attachment.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Airi.footnoteFont)
                            .foregroundStyle(Airi.neutral400)
                    }
                    .buttonStyle(.plain)
                }
                .help(L("attached image"))
            }
            Spacer()
        }
        .padding(.horizontal, Airi.space3)
        .padding(.top, 8)
    }

    private func pickImageAttachment() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let attachment = ChatAttachment(fileURL: url), attachments.count < 4 {
                attachments.append(attachment)
            }
        }
    }

    private func send() {
        // Slash command? Handle locally, never as a model turn.
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            draft = ""
            handleSlash(trimmed)
            return
        }
        // Gate BEFORE clearing the draft: `brain.submit` is a silent no-op
        // while a turn is running, so an ungated Return would swallow the
        // typed message. Keep the text so it can be sent after this turn.
        let images = attachments.map(\.dataURL)
        guard !trimmed.isEmpty || !images.isEmpty, !brain.isRunning else { return }
        draft = ""
        attachments = []
        Task {
            await brain.submit(trimmed, images: images)
            store.syncCurrentSession()
        }
    }

    // MARK: - Slash commands (codex TUI parity, chat-native)

    private func notice(_ icon: String, _ text: String) {
        notices.append(ChatNotice(icon: icon, text: text))
        if notices.count > 8 { notices.removeFirst(notices.count - 8) }
    }

    private func handleSlash(_ raw: String) {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0].lowercased()

        // UI-owned commands stay here; everything else runs in the shared
        // BrainSlash runner (also used by the quick bar).
        switch command {
        case "/new":
            store.newSession()
            return
        case "/export":
            if let url = brain.exportMarkdown() {
                notice("square.and.arrow.up", url.path)
                NSApp.activate(ignoringOtherApps: true)
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            } else {
                notice("exclamationmark.triangle", L("export failed"))
            }
            return
        case "/copy":
            let last = brain.items.last {
                if case .message("assistant", _) = $0 { return true }
                return false
            }
            if case .message(_, let copiedText) = last {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copiedText, forType: .string)
                notice("doc.on.doc", String(format: L("copied %lld chars"), copiedText.count))
            } else {
                notice("exclamationmark.triangle", L("no assistant reply to copy yet"))
            }
            return
        default:
            break
        }

        let icon = SlashCommand.all.first { $0.name == command }?.icon ?? "terminal"
        if command == "/compact" { notice(icon, L("compacting…")) }
        Task {
            let result = await BrainSlash.run(raw, brain: brain)
                ?? String(format: L("%@ is chat-window only"), command)
            notice(icon, result)
            if command == "/init" { store.syncCurrentSession() }
        }
    }

    // MARK: - Bubbles

    private var approvalBinding: Binding<ApprovalRequest?> {
        Binding(
            get: { ApprovalCenter.shared.pending },
            set: { newValue in
                if newValue == nil, let current = ApprovalCenter.shared.pending {
                    // The sheet was dismissed without a button (Esc) — if we
                    // just drop the request the awaiting tool call hangs
                    // forever (brain stuck running, composer locked). Treat
                    // dismissal as deny. A button-driven dismissal already
                    // cleared `pending`, so this never double-resumes.
                    current.respond(false)
                } else {
                    ApprovalCenter.shared.dismissPendingAsDenied()
                }
            }
        )
    }

    /// Model-asked structured questions (request_user_input) — same
    /// dismiss-means-cancelled contract as approvals.
    private var userInputBinding: Binding<UserInputRequest?> {
        Binding(
            get: { UserInputCenter.shared.pending },
            set: { newValue in
                if newValue == nil, let current = UserInputCenter.shared.pending {
                    current.respond(nil)
                }
            }
        )
    }

    private func userBubble(_ content: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            Text(content)
                .font(Airi.bodyFont)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                        .fill(Airi.primary.opacity(0.9))
                )
        }
    }

    private func markdownBubble(_ content: String) -> some View {
        HStack {
            Markdown(content)
                .markdownTheme(.basic)
                .markdownTextStyle { FontSize(13) }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                        .fill(Airi.neutral100)
                )
            Spacer(minLength: 48)
        }
    }

    @ViewBuilder
    private func brainBubble(_ item: BrainResponseItem, index: Int) -> some View {
        switch item {
        case .message(let role, let content):
            if role == "user" {
                userBubble(content)
            } else {
                markdownBubble(content)
            }
        case .reasoning(let summary):
            reasoningBlock(summary, index: index)
        case .functionCall(_, let name, _):
            toolCallChip(name)
        case .functionCallOutput(_, let output):
            toolResultBlock(output, isError: output.hasPrefix("error:"), index: index)
        case .plan(let steps):
            planCard(steps)
        case .imageItem(let callID, let dataURL):
            imageBubble(callID: callID, dataURL: dataURL)
        }
    }

    /// Reasoning summaries used to be dropped entirely (EmptyView) — they
    /// now render as a collapsed, low-key block the user can expand.
    private func reasoningBlock(_ summary: String, index: Int) -> some View {
        let isExpanded = expandedReasoning.contains(index)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if isExpanded { expandedReasoning.remove(index) }
                else { expandedReasoning.insert(index) }
            } label: {
                Label(L("Reasoning"), systemImage: "lightbulb")
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral400)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(summary)
                    .font(Airi.footnoteFont)
                    .foregroundStyle(Airi.neutral500)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Image in the conversation — view_image results and user attachments
    /// alike (click to open the pixels at full size in Preview).
    private func imageBubble(callID: String, dataURL: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label(callID == "user" ? L("attached image") : "view_image",
                      systemImage: callID == "user" ? "photo" : "eye")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Airi.neutral500)
                if let image = NSImage(contentsOfDataURL: dataURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous))
                        .onTapGesture { openImageDataURL(dataURL) }
                } else {
                    Text(L("(unreadable image)"))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
            }
            Spacer(minLength: 48)
        }
    }

    private func openImageDataURL(_ dataURL: String) {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return }
        let name = "moppet-\(UUID().uuidString.prefix(6)).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url)
        NSWorkspace.shared.open(url)
    }

    /// Completed tool call: name chip + a ✓ — the previous chip was a bare
    /// name with no state, indistinguishable from the row still running.
    private func toolCallChip(_ name: String) -> some View {
        HStack(spacing: 4) {
            Label(name, systemImage: "wrench.and.screwdriver")
                .font(Airi.footnoteFont.weight(.medium))
                .foregroundStyle(Airi.primary)
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Airi.success)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Airi.primary.opacity(0.08)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolResultBlock(_ output: String, isError: Bool, index: Int) -> some View {
        let isExpanded = expandedOutputs.contains(index)
        return VStack(alignment: .leading, spacing: 3) {
            Label(isError ? L("failed") : L("output"),
                  systemImage: isError ? "xmark.octagon" : "checkmark.circle")
                .font(Airi.caption2Font.weight(.medium))
                .foregroundStyle(isError ? Airi.danger : Airi.success)
            Markdown(output)
                .markdownTheme(.basic)
                .markdownTextStyle {
                    FontSize(11)
                    ForegroundColor(isError ? Airi.danger : Airi.neutral700)
                }
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 14)
            Button {
                if isExpanded { expandedOutputs.remove(index) }
                else { expandedOutputs.insert(index) }
            } label: {
                Text(isExpanded ? L("Show less") : L("Show more"))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusCard)
                .fill(Airi.neutral100.opacity(0.7))
        )
    }

    private func planCard(_ steps: [BrainPlanStep]) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 4) {
                Label(L("Plan"), systemImage: "list.clipboard")
                    .font(Airi.cardTitleFont)
                ForEach(steps) { step in
                    HStack(spacing: 6) {
                        Image(systemName: step.status == "completed" ? "checkmark.circle.fill"
                              : step.status == "in_progress" ? "arrow.right.circle.fill" : "circle")
                            .foregroundStyle(step.status == "completed" ? Airi.success : Airi.neutral400)
                        Text(step.step).font(Airi.captionFont)
                            .strikethrough(step.status == "completed")
                            .foregroundStyle(step.status == "completed" ? Airi.neutral500 : Airi.neutral900)
                    }
                }
            }
        }
    }

    private func streamingBubble(_ text: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Markdown(text)
                    .markdownTheme(.basic)
                    .markdownTextStyle { FontSize(13) }
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Airi.neutral400)
                            .frame(width: 4, height: 4)
                            .opacity(0.5)
                    }
                    Text(L("writing"))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral400)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                    .fill(Airi.neutral100.opacity(0.6))
                    .strokeBorder(Airi.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            Spacer(minLength: 48)
        }
    }
}

struct ApprovalSheet: View {
    let request: ApprovalRequest
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: Airi.space3) {
            Label(request.title, systemImage: "shield.lefthalf.filled")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Airi.neutral950)
            Text(request.detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Airi.neutral700)
                .textSelection(.enabled)
                .lineLimit(8)
            HStack {
                Spacer()
                AiriButton(title: L("Deny"), variant: .secondary) { request.respond(false) }
                AiriButton(title: L("Approve"), variant: .primary) { request.respond(true) }
            }
        }
        .padding(Airi.space4)
        .frame(width: 440)
    }
}

/// Structured questions from the model (codex request_user_input): each
/// question offers 2–3 options plus a free-text "Other" answer.
struct UserInputSheet: View {
    let request: UserInputRequest
    /// answers[question.id] — option label or free text.
    @State private var answers: [String: String] = [:]
    @State private var others: [String: String] = [:]

    private var complete: Bool {
        request.questions.allSatisfy { answers[$0.id]?.isEmpty == false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Airi.space3) {
            Label(L("A quick question"), systemImage: "questionmark.bubble.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Airi.neutral950)

            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(question.header)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Airi.primary.opacity(0.12)))
                            .foregroundStyle(Airi.primary)
                        Text(question.question)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Airi.neutral900)
                    }
                    HStack(spacing: 6) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Button {
                                answers[question.id] = option.label
                                others[question.id] = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label)
                                        .font(.system(size: 11, weight: .medium))
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(Airi.caption2Font)
                                            .foregroundStyle(Airi.neutral500)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(answers[question.id] == option.label
                                              ? Airi.primary.opacity(0.15) : Airi.neutral100)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(answers[question.id] == option.label
                                                      ? Airi.primary : Color.clear, lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(L("Other"))
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral500)
                        TextField(L("type your own answer…"), text: Binding(
                            get: { others[question.id] ?? "" },
                            set: { newValue in
                                others[question.id] = newValue
                                answers[question.id] = newValue
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(Airi.footnoteFont)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Airi.radiusCard)
                        .fill(Airi.neutral50.opacity(0.7))
                )
            }

            HStack {
                Spacer()
                AiriButton(title: L("Skip"), variant: .secondary) { request.respond(nil) }
                AiriButton(title: L("Answer"), variant: .primary) {
                    request.respond(answers.filter { !$0.value.isEmpty })
                }
                .disabled(!complete)
            }
            Text(L("Auto-dismisses after 5 minutes"))
                .font(Airi.caption2Font)
                .foregroundStyle(Airi.neutral400)
        }
        .padding(Airi.space4)
        .frame(width: 480)
    }
}

extension NSImage {
    /// "data:image/png;base64,…" → NSImage (nil on malformed input).
    convenience init?(contentsOfDataURL dataURL: String) {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else {
            return nil
        }
        self.init(data: data)
    }
}
