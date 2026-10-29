import SwiftUI
import LaunchAtLogin

/// Whitelist management — the user-managed safety valve.
/// Same file format as mole's `~/.config/mole/whitelist` (one glob per line),
/// stored at `~/.config/moppet/whitelist`.
struct SettingsView: View {
    var onClose: (() -> Void)?

    @State private var whitelistText = ""
    @State private var saved = false
    @State private var saveError: String?
    @State private var ai = AISettings.load()
    @State private var aiTestResult: String?
    @State private var mcpService = MCPAppService.shared
    @State private var language = L10n.current
    @State private var codexLoginState: String?
    @State private var codexLoginBusy = false
    @State private var codexLoginTask: Task<Void, Never>?
    @State private var cacheCount = SizeCache.shared.count
    @State private var petName = PetIdentity.name
    @State private var personaText = PetIdentity.persona ?? ""
    @State private var identitySaved = false
    @State private var schedule = Scheduler.Settings.load()
    @State private var scheduleBusy = false
    @State private var scheduleStatus: String?
    /// Explicit focus plumbing for every text input (see labeledField).
    private enum Field: Hashable { case petName, persona, baseURL, model, apiKey, whitelist }
    @FocusState private var focusedField: Field?

    /// Section filter — the page used to be one 1200-line scroll through
    /// ten cards; the segmented filter keeps every card reachable in one hop.
    private enum Section: String, CaseIterable, Identifiable {
        case all, general, ai, growth, data, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: L("All")
            case .general: L("General")
            case .ai: L("AI")
            case .growth: L("Growth")
            case .data: L("Data & Safety")
            case .about: L("About")
            }
        }
    }
    @State private var section: Section = .all

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Settings"), subtitle: L("Preferences & safety configuration"), onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            Picker("", selection: $section) {
                ForEach(Section.allCases) { sec in
                    Text(sec.label).tag(sec)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Airi.space4)
            .padding(.vertical, Airi.space1)
            ScrollView {
                // Lazy: ten stacked cards cost ~0.9s to build eagerly in
                // debug; only the visible ones need to exist at first paint.
                LazyVStack(spacing: Airi.space3) {
                    if section == .all || section == .general {
                        identityCard
                        languageCard
                        scheduledCleanCard
                        petCard
                    }
                    if section == .all || section == .ai {
                        codexSubscriptionCard
                        aiCard
                    }
                    // Brain Growth has its own tab: its toggles and the
                    // learning table are what people come here to flip, and
                    // burying them under "AI" cost two clicks every time.
                    if section == .all || section == .growth {
                        BrainGrowthCard()
                    }
                    if section == .all || section == .data {
                        whitelistCard
                        mcpCard
                        cacheCard
                        protectionCard
                    }
                    if section == .all || section == .about {
                        aboutCard
                    }
                }
                .padding(Airi.space4)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Airi.pageBackground.opacity(0.001))
        .onAppear {
            whitelistText = SafetyGuard.loadWhitelistPatterns().joined(separator: "\n")
        }
    }

    private var identityCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("Pet Identity"), systemImage: "pawprint.circle")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)

                labeledField(L("Name"), field: .petName) {
                    TextField("Moley", text: $petName)
                        .textFieldStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Persona · system prompt soul"))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                    TextEditor(text: $personaText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Airi.neutral900)
                        .focused($focusedField, equals: .persona)
                        .onTapGesture { focusedField = .persona }
                        .frame(minHeight: 130)
                        .padding(6)
                        .scrollContentBackground(.hidden)
                        .background(
                            RoundedRectangle(cornerRadius: Airi.radiusControl)
                                .fill(Airi.neutral50)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Airi.radiusControl)
                                .strokeBorder(Airi.neutral200, lineWidth: 2)
                        )
                    Text(String(format: L("Written to %@. Prepend-style: it becomes the first section of the agent's system prompt on every turn. Markdown supported."),
                                PetIdentity.personaFile.path))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral400)
                        .textSelection(.enabled)
                }

                HStack(spacing: Airi.space2) {
                    AiriButton(title: L("Save identity"), icon: "checkmark.seal") {
                        PetIdentity.setName(petName)
                        PetIdentity.savePersona(personaText)
                        identitySaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            identitySaved = false
                        }
                    }
                    if identitySaved {
                        Label(L("Saved ✓ — applies to the next message"), systemImage: "checkmark.circle.fill")
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.success)
                    }
                }
            }
        }
    }

    private var languageCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("Language"), systemImage: "globe")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Picker(L("Language"), selection: $language) {
                    ForEach(L10n.Language.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                .onChange(of: language) { _, newValue in
                    L10n.current = newValue
                    // Only this view re-renders from the @State change — the
                    // sidebar, chat window and pet keep the old language
                    // until something else forces them to redraw.
                    NotificationCenter.default.post(name: .moppetLanguageChanged, object: nil)
                }
                Text(L("Applies immediately across the app."))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
            }
        }
    }

    /// ChatGPT/Codex subscription login (device-code flow, same public
    /// OAuth client as codex-rs) — the subscription alternative to API keys.
    private var codexSubscriptionCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("Codex Subscription (ChatGPT plan)"), systemImage: "creditcard")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Text(L("Sign in with your ChatGPT account (Plus/Pro/Team). A browser window opens auth.openai.com; the token is stored in the Keychain and the chat runs on the ChatGPT codex backend — no API key needed."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)

                if let state = codexLoginState {
                    Text(state)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(state.hasPrefix("✓") ? Airi.success : (state.hasPrefix("✗") ? Airi.danger : Airi.neutral700))
                        .textSelection(.enabled)
                }
                if codexLoginBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("Waiting for authorization…")).font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                        AiriButton(title: L("Cancel"), variant: .secondary) {
                            codexLoginTask?.cancel()
                        }
                    }
                }
                HStack(spacing: Airi.space2) {
                    AiriButton(title: codexLoginBusy ? L("Waiting…") : L("Sign in with ChatGPT"),
                               icon: "person.badge.key", disabled: codexLoginBusy) {
                        startCodexLogin()
                    }
                    AiriButton(title: L("Use device code instead"),
                               variant: .secondary, disabled: codexLoginBusy) {
                        startCodexDeviceLogin()
                    }
                    if ai.vendor == .codex {
                        Text(String(format: L("active · %@"), ai.model))
                            .font(Airi.captionFont).foregroundStyle(Airi.success)
                    }
                }
            }
        }
    }

    /// Primary: browser PKCE flow — the browser opens immediately and carries
    /// the auth dance through Cloudflare / the user's proxy.
    private func startCodexLogin() {
        codexLoginBusy = true
        codexLoginState = nil
        codexLoginTask = Task {
            await CodexSubscription.loginPKCE { step in
                Task { @MainActor in handleLoginStep(step) }
            }
        }
    }

    /// Fallback for users who prefer copy-pasting a code (or can't run the
    /// loopback listener).
    private func startCodexDeviceLogin() {
        codexLoginBusy = true
        codexLoginState = nil
        codexLoginTask = Task {
            await CodexSubscription.login { step in
                Task { @MainActor in handleLoginStep(step) }
            }
        }
    }

    @MainActor
    private func handleLoginStep(_ step: CodexSubscription.LoginStep) {
        switch step {
        case .browserOpened:
            codexLoginState = L("Browser opened — finish signing in, then come back…")
        case .pendingVerification(let code, let url):
            codexLoginState = "1. Open \(url)\n2. Enter code: \(code)"
            if let target = URL(string: url) {
                NSWorkspace.shared.open(target)
            }
        case .authenticated(let account, let expires):
            codexLoginState = "✓ Signed in (\(account), expires \(expires.formatted(date: .abbreviated, time: .shortened)))"
            ai = AISettings.load()
            codexLoginBusy = false
            PetBus.shared.say("Codex subscription ready 🎫", state: .celebrating)
        case .failed(let message):
            codexLoginState = message == "cancelled"
                ? L("Login cancelled")
                : "✗ \(message)"
            codexLoginBusy = false
        }
    }

    /// Per-vendor editable model catalog: delete rows, add model ids, and
    /// pull the provider's live list when it has a models endpoint. This is
    /// the user's correction surface — no more waiting for an app update
    /// when a provider renames or retires a model.
    private struct ModelCatalogEditor: View {
        let vendor: AIVendor
        @State private var models: [String] = []
        @State private var draft = ""
        @State private var result: String?
        @State private var refreshing = false
        /// True while a model row is being deleted — disables the trash button
        /// so a double-click cannot remove two rows at once.
        @State private var deletingModel: String?

        var body: some View {
            VStack(alignment: .leading, spacing: Airi.space1) {
                HStack {
                    Text(L("Model list"))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                    Spacer()
                    if AIModelCatalog.supportsAPIRefresh(vendor) {
                        AiriButton(title: L("Refresh from API"), variant: .secondary, disabled: refreshing, busy: refreshing) {
                            refresh()
                        }
                    }
                }

                // Grouped container (matches the custom-provider cards):
                // monospaced rows with hairline dividers, trash to remove,
                // and an inline add row — capped height for long catalogs.
                VStack(spacing: 0) {
                    if models.isEmpty {
                        Text(L("Model list is empty — add an id or refresh from the API"))
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.neutral400)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                    }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(models.enumerated()), id: \.element) { index, model in
                                catalogRow(model)
                                if index < models.count - 1 {
                                    Divider().overlay(Airi.neutral200.opacity(0.5))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    // The frame collapses to nothing when the list is empty —
                    // let the empty-state row set the height instead.
                    .fixedSize(horizontal: false, vertical: models.isEmpty)

                    Divider().overlay(Airi.neutral200.opacity(0.5))
                    catalogAddRow
                }
                .background(
                    RoundedRectangle(cornerRadius: Airi.radiusControl)
                        .fill(Airi.neutral50.opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Airi.radiusControl)
                        .strokeBorder(Airi.neutral200.opacity(0.7), lineWidth: 1)
                )

                if let result {
                    Text(result)
                        .font(Airi.captionFont)
                        .foregroundStyle(result.hasPrefix("✓") ? Airi.success : Airi.danger)
                }
            }
            .onAppear { reload() }
            .onChange(of: vendor) { _, _ in
                result = nil
                draft = ""
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: AIModelCatalog.changedNotification)) { _ in
                reload()
            }
        }

        private var catalogAddRow: some View {
            HStack(spacing: Airi.space2) {
                Image(systemName: "plus")
                    .font(Airi.footnoteFont)
                    .foregroundStyle(Airi.neutral400)
                TextField("model-id", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(addDraft)
                Button {
                    addDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? Airi.neutral200.opacity(0.9) : Airi.primary)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(L("Add"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }

        private func catalogRow(_ model: String) -> some View {
            HStack(spacing: Airi.space2) {
                Text(model)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Airi.neutral900)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    deletingModel = model
                    Task {
                        delete(model)
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        deletingModel = nil
                    }
                } label: {
                    if deletingModel == model {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "trash")
                            .font(Airi.footnoteFont)
                            .foregroundStyle(Airi.neutral400)
                    }
                }
                .buttonStyle(.plain)
                .disabled(deletingModel != nil)
                .help(L("Remove from list"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }

        private func reload() {
            models = AIModelCatalog.models(for: vendor)
        }

        private func addDraft() {
            AIModelCatalog.addModel(draft, for: vendor)
            draft = ""
            reload()
        }

        private func delete(_ model: String) {
            AIModelCatalog.removeModel(model, for: vendor)
            reload()
            // Deleting the selected model moves the selection to the next
            // surviving entry — that's the correction the user is making.
            let settings = AISettings.load()
            if settings.vendor == vendor, settings.model == model {
                // Empty catalog → vendor default (a dangling model id made
                // every later request 404 at the provider).
                let next = models.first ?? vendor.defaultModel
                AISettingsCoordinator.apply(model: next)
            }
        }

        private func refresh() {
            refreshing = true
            result = nil
            Task {
                let message = await AIModelCatalog.refreshFromAPI(for: vendor)
                await MainActor.run {
                    result = message
                    reload()
                    refreshing = false
                }
            }
        }
    }

    private var aiCard: some View {
        aiCardContent
            .onReceive(NotificationCenter.default.publisher(for: AISettingsCoordinator.changedNotification)) { _ in
                // Another surface (chat picker / codex login / quick bar)
                // changed the settings — reload or this card's next Save
                // would write the stale snapshot back over them.
                ai = AISettings.load()
            }
    }

    private var aiCardContent: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("AI Provider"), systemImage: "brain.head.profile")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Text(L("Powered by swift-ai-sdk — one agent, many vendors. Each provider keeps its own API key (stored in ~/.moppet/ai-keys.json, chmod 0600 — no keychain prompts); switching providers loads that provider's key."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)

                HStack(spacing: Airi.space2) {
                    Picker(L("Provider"), selection: providerSelection) {
                        ForEach(providerOptions) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)

                    // Add via sheet — the saved provider joins THIS picker
                    // (no separate Custom Providers section) and is selected
                    // immediately; the sheet closes itself on save.
                    Button {
                        addDraftProvider()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Airi.neutral500)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Airi.neutral100))
                    }
                    .buttonStyle(.plain)
                    .help(L("Add provider"))

                    // Manage the ACTIVE custom provider in place.
                    if ai.activeProfile != nil {
                        Menu {
                            Button(L("Edit provider")) {
                                editingProfile = ai.activeProfile
                            }
                            Button(L("Delete provider"), role: .destructive) {
                                deleteActiveProfile()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(Airi.neutral500)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(L("Custom Providers"))
                    }
                }
                .sheet(isPresented: Binding(
                    get: { draftNew != nil },
                    set: { if !$0 { draftNew = nil } })) { providerAddSheet }
                .sheet(item: $editingProfile) { profile in providerEditSheet(profile) }
                .onAppear { profiles = AIProviderRegistry.load() }
                .onReceive(NotificationCenter.default.publisher(
                    for: AIProviderRegistry.changedNotification)) { _ in
                    profiles = AIProviderRegistry.load()
                }

                if ai.activeProfile != nil {
                    labeledField(L("Base URL (profile)"), field: .baseURL) {
                        TextField("https://…/v1", text: $ai.baseURL)
                            .textFieldStyle(.plain)
                    }
                    labeledField(L("Model"), field: .model) {
                        TextField("model id", text: $ai.model)
                            .textFieldStyle(.plain)
                    }
                    labeledField(L("API Key (profile)"), field: .apiKey) {
                        SecureField("sk-… (optional for local servers)", text: $ai.apiKey)
                            .textFieldStyle(.plain)
                    }
                } else if !ai.vendor.usesNativeProvider {
                    labeledField(L("Base URL"), field: .baseURL) {
                        TextField(ai.vendor.defaultBaseURL ?? "https://…/v1", text: $ai.baseURL)
                            .textFieldStyle(.plain)
                    }
                    labeledField(L("Model"), field: .model) {
                        TextField(ai.vendor.defaultModel, text: $ai.model)
                            .textFieldStyle(.plain)
                    }
                    ModelCatalogEditor(vendor: ai.vendor)
                    if ai.vendor.needsAPIKey {
                        labeledField(L("API Key"), field: .apiKey) {
                            SecureField("sk-…", text: $ai.apiKey)
                                .textFieldStyle(.plain)
                        }
                    }
                } else {
                    labeledField(L("Model"), field: .model) {
                        TextField(ai.vendor.defaultModel, text: $ai.model)
                            .textFieldStyle(.plain)
                    }
                    ModelCatalogEditor(vendor: ai.vendor)
                    if ai.vendor.needsAPIKey {
                        labeledField(L("API Key"), field: .apiKey) {
                            SecureField("sk-…", text: $ai.apiKey)
                                .textFieldStyle(.plain)
                        }
                    }
                }
                HStack(spacing: Airi.space2) {
                    AiriButton(title: L("Save"), icon: "tray.and.arrow.down") {
                        ai.save()
                        AISettingsCoordinator.broadcast(ai)
                        aiTestResult = "Saved ✓"
                    }
                    AiriButton(title: L("Test connection"), variant: .secondary) {
                        testAI()
                    }
                    if let aiTestResult {
                        Text(aiTestResult).font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                    }
                }
            }
        }
    }

    // MARK: - Provider selection (built-ins + ZCode-style profiles)

    private var providerOptions: [AIProviderOption] {
        AIVendor.allCases.map(AIProviderOption.builtin)
            + AIProviderRegistry.load().map { AIProviderOption.profile($0.id) }
    }

    private var providerSelection: Binding<AIProviderOption> {
        Binding(
            get: { ai.providerOption },
            set: { option in
                switch option {
                case .builtin(let vendor):
                    ai.switchVendor(to: vendor)
                case .profile(let id):
                    ai.selectProfile(id: id)
                }
                ai.save()
                AISettingsCoordinator.broadcast(ai)
            }
        )
    }

    @State private var profiles: [AIProviderProfile] = []
    /// Add flow: the draft lives in a SHEET (sheet closes itself on save —
    /// the old inline draft card never auto-dismissed).
    @State private var draftNew: AIProviderProfile?
    /// Edit flow for the active custom provider (opened from the … menu).
    @State private var editingProfile: AIProviderProfile?

    /// Sheet: new provider draft. Save → upsert + auto-select + close.
    private var providerAddSheet: some View {
        VStack(spacing: Airi.space3) {
            if let draft = draftNew {
                ProfileCard(profile: draft, isNew: true,
                            isActiveProvider: false,
                            onChange: { profiles = AIProviderRegistry.load() },
                            onCommitDraft: { saved, key in
                                // upsert may suffix the id on slug collision —
                                // write the key + select by the id that landed.
                                let all = AIProviderRegistry.upsert(saved, isNew: true)
                                let landed = all.first {
                                    $0.name.trimmingCharacters(in: .whitespaces)
                                        .caseInsensitiveCompare(saved.name) == .orderedSame
                                }?.id ?? saved.id
                                let slot = AIProviderProfileKey(landed)
                                if key.isEmpty {
                                    APIKeyStore.delete(slot: slot)
                                } else {
                                    APIKeyStore.write(key, slot: slot)
                                }
                                draftNew = nil
                                profiles = AIProviderRegistry.load()
                                // "Added" means IN the picker and active.
                                ai.selectProfile(id: landed)
                                ai.save()
                                AISettingsCoordinator.broadcast(ai)
                            },
                            onDiscard: { draftNew = nil })
            }
            HStack {
                Text(L("ZCode-style: add any OpenAI-compatible endpoint (vLLM, LM Studio, one-api, new gateways). Config lives at ~/.moppet/ai-providers.json; each provider keeps its own key and model list. Names must be unique — duplicates are rejected."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                Spacer()
                AiriButton(title: L("Cancel"), variant: .secondary) { draftNew = nil }
            }
        }
        .padding(Airi.space4)
        .frame(width: 580)
    }

    /// Sheet: edit an existing provider. Save → close + re-sync if active.
    private func providerEditSheet(_ profile: AIProviderProfile) -> some View {
        VStack(spacing: Airi.space3) {
            ProfileCard(profile: profile, isNew: false,
                        isActiveProvider: ai.activeProfileID == profile.id,
                        onChange: {
                            profiles = AIProviderRegistry.load()
                            // Deleted via the card's … menu → close the sheet.
                            if AIProviderRegistry.profile(id: profile.id) == nil {
                                editingProfile = nil
                            }
                        },
                        onCommitDraft: { saved, key in
                            let slot = AIProviderProfileKey(saved.id)
                            if key.isEmpty {
                                APIKeyStore.delete(slot: slot)
                            } else {
                                APIKeyStore.write(key, slot: slot)
                            }
                            AIProviderRegistry.upsert(saved)
                            editingProfile = nil
                            profiles = AIProviderRegistry.load()
                            syncActiveProfile(saved.id)
                        },
                        onDiscard: { editingProfile = nil })
            HStack {
                Spacer()
                AiriButton(title: L("Cancel"), variant: .secondary) { editingProfile = nil }
            }
        }
        .padding(Airi.space4)
        .frame(width: 580)
    }

    /// Deleting the active profile: registry clears the selection (with its
    /// own settings fixup); locally fall back to a sane builtin vendor so the
    /// picker doesn't strand on the bare `.custom` entry.
    private func deleteActiveProfile() {
        guard let id = ai.activeProfileID else { return }
        _ = AIProviderRegistry.delete(id: id)
        profiles = AIProviderRegistry.load()
        ai = AISettings.load()
        if ai.vendor == .custom {
            ai.switchVendor(to: .glm)
            ai.save()
            AISettingsCoordinator.broadcast(ai)
        }
    }

    /// New draft with a unique default display name ("New Provider",
    /// "New Provider 2", …) — the name itself is still editable on the card
    /// and checked for duplicates at save. Setting draftNew presents the sheet.
    private func addDraftProvider() {
        var index = 1
        var name = L("New Provider")
        while AIProviderRegistry.nameExists(name) {
            index += 1
            name = "\(L("New Provider")) \(index)"
        }
        draftNew = AIProviderProfile(
            id: AIProviderRegistry.slugify(name),
            name: name, baseURL: "", models: [])
    }

    /// After a save/delete touches the ACTIVE profile, re-select it so base
    /// URL / models / key stay in sync and pickers cascade.
    private func syncActiveProfile(_ profileID: String) {
        guard ai.activeProfileID == profileID else { return }
        ai.selectProfile(id: profileID)
        ai.save()
        AISettingsCoordinator.broadcast(ai)
    }

    @State private var lastVendor: AIVendor = .glm
    /// `LaunchAtLogin.isEnabled` is an SMAppService XPC round-trip that
    /// measured 1.5–1.8s per call on this machine — reading it inside body
    /// froze every settings render. Cache it: read once off-main, write
    /// optimistically (the setter's result isn't surfaced by the lib anyway).
    @State private var launchAtLogin = false

    /// Scheduled cleaning (gap-analysis P0): a LaunchAgent that runs the
    /// safe, headless clean on a calendar interval. The toggle installs/
    /// removes `~/Library/LaunchAgents/com.moppet.schedule.plist`.
    private var scheduledCleanCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("Scheduled Clean"), systemImage: "clock.badge.checkmark")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                ToggleRow(title: L("Clean automatically"),
                          subtitle: L("Runs the safe set (caches, logs, dev package caches) in the background — never the Trash, installers or whole-home scans."),
                          isOn: Binding(
                            get: { schedule.enabled },
                            set: { on in
                                schedule.enabled = on
                                Task { await applySchedule() }
                            }))
                if schedule.enabled {
                    HStack(spacing: Airi.space2) {
                        Picker(L("Frequency"), selection: Binding(
                            get: { schedule.frequency },
                            set: { newValue in
                                schedule.frequency = newValue
                                Task { await applySchedule() }
                            })) {
                            Text(L("Every day")).tag(Scheduler.Frequency.daily)
                            Text(L("Every week")).tag(Scheduler.Frequency.weekly)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                        if schedule.frequency == .weekly {
                            Picker("", selection: Binding(
                                get: { schedule.weekday },
                                set: { newValue in
                                    schedule.weekday = newValue
                                    Task { await applySchedule() }
                                })) {
                                ForEach(1...7, id: \.self) { day in
                                    Text(Self.weekdayName(day)).tag(day)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 130)
                            .labelsHidden()
                        }
                        Picker("", selection: Binding(
                            get: { schedule.hour },
                            set: { newValue in
                                schedule.hour = newValue
                                Task { await applySchedule() }
                            })) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(String(format: "%02d:00", hour)).tag(hour)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 110)
                        .labelsHidden()
                        Spacer()
                    }
                }
                HStack(spacing: Airi.space2) {
                    if scheduleBusy { ProgressView().controlSize(.small) }
                    Text(scheduleStatus ?? (Scheduler.isInstalled
                        ? String(format: L("Installed — %@"), Scheduler.describe(schedule))
                        : L("Not installed")))
                        .font(Airi.captionFont)
                        .foregroundStyle(scheduleStatus == nil ? Airi.neutral500 : Airi.neutral700)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
    }

    @MainActor
    private func applySchedule() async {
        scheduleBusy = true
        defer { scheduleBusy = false }
        do {
            if schedule.enabled {
                try await Scheduler.install(settings: schedule)
                scheduleStatus = String(format: L("Installed — %@"), Scheduler.describe(schedule))
            } else {
                await Scheduler.uninstall()
                scheduleStatus = L("Not installed")
            }
        } catch {
            // The toggle stays where the user put it, but the failure and
            // the launchctl output are surfaced — a silently dead scheduler
            // would look like "it just doesn't clean".
            scheduleStatus = String(format: L("Failed: %@"), error.localizedDescription)
            schedule.enabled = false
        }
    }

    private static func weekdayName(_ day: Int) -> String {
        [L("Sunday"), L("Monday"), L("Tuesday"), L("Wednesday"),
         L("Thursday"), L("Friday"), L("Saturday")][day - 1]
    }

    private var petCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("Desktop Pet"), systemImage: "pawprint")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                ToggleRow(title: L("Launch at login"),
                          subtitle: L("Start Moley with your Mac (SMAppService)"),
                          isOn: Binding(
                            get: { launchAtLogin },
                            set: { newValue in
                                launchAtLogin = newValue
                                Task.detached { LaunchAtLogin.isEnabled = newValue }
                            }))
                    .task {
                        launchAtLogin = await Task.detached { LaunchAtLogin.isEnabled }.value
                    }
                HStack(spacing: Airi.space3) {
                    Text(L("Size"))
                        .font(Airi.cardTitleFont)
                        .foregroundStyle(Airi.neutral950)
                    Picker("", selection: Binding(
                        get: { PetSettings.sizeScale },
                        set: { PetPanelController.shared.applySizeScale($0) }
                    )) {
                        Text(L("Small")).tag(CGFloat(0.8))
                        Text(L("Medium")).tag(CGFloat(1.0))
                        Text(L("Large")).tag(CGFloat(1.25))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                ToggleRow(title: L("Follow window screen"),
                          subtitle: L("Move the pet to the display where the main or chat window lives — turn off to keep a hand-placed pet where you put it."),
                          isOn: Binding(
                            get: { PetSettings.followScreen },
                            set: { PetSettings.followScreen = $0 }))
            }
        }
    }

    private var mcpCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("MCP Server"), systemImage: "server.rack")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Text(String(format: L("Expose all %lld tools to external AI agents. Toggle runs an HTTP MCP server inside this app; clients connect over the network — no stdio wiring."),
                            ToolRegistry.tools.count))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)

                HStack(spacing: Airi.space3) {
                    ToggleRow(
                        title: L("Run MCP server (HTTP)"),
                        subtitle: mcpService.isRunning
                            ? String(format: L("listening on %@"), mcpService.endpointURL)
                            : L("stopped"),
                        isOn: Binding(
                            get: { mcpService.isRunning },
                            set: { mcpService.setEnabled($0) }
                        ))
                    if mcpService.isRunning {
                        Circle().fill(Airi.success).frame(width: 7, height: 7)
                    }
                }
                if let error = mcpService.errorMessage {
                    Text(error).font(Airi.caption2Font).foregroundStyle(Airi.danger)
                }

                HStack(spacing: 6) {
                    Text("http://127.0.0.1:\(mcpService.port)/mcp")
                        .font(Airi.monoCaption2Font)
                        .foregroundStyle(Airi.neutral700)
                        .textSelection(.enabled)
                    Spacer()
                    Text(L("or stdio: Moppet --mcp"))
                        .font(Airi.monoCaption2Font)
                        .foregroundStyle(Airi.neutral400)
                }
                Text("Client config: {\"mcpServers\": {\"moppet\": {\"url\": \"http://127.0.0.1:\(mcpService.port)/mcp\"}}}")
                    .font(Airi.monoCaption2Font)
                    .foregroundStyle(Airi.neutral500)
                    .textSelection(.enabled)
            }
        }
    }

    private var cacheCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("Scan Result Cache"), systemImage: "externaldrive.badge.timemachine")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Text(L("Heavy directory measurements are cached (3-day TTL, invalidated when a folder changes) — warm Analyze/Uninstall runs are instant."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                HStack(spacing: Airi.space2) {
                    Text("\(cacheCount) \(L("entries"))")
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                        .monospacedDigit()
                    Spacer()
                    AiriButton(title: L("Clear cache"), icon: "trash", variant: .secondary) {
                        SizeCache.shared.clear()
                        cacheCount = 0
                    }
                }
            }
        }
    }

    private func labeledField<Content: View>(_ title: String, field: Field? = nil,
                                             @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Airi.space3) {
            Text(title).font(Airi.captionFont).foregroundStyle(Airi.neutral500).frame(width: 64, alignment: .leading)
            content()
                .font(.system(size: 12, design: .monospaced))
                // Fixed dark text: these fields sit on a light fill; adaptive
                // color renders white-on-light under the system dark
                // appearance ("can't type into the box").
                .foregroundStyle(Airi.neutral900)
                // Explicit focus plumbing: some launch contexts (terminal
                // background launch) leave the app without a working
                // click-to-first-responder chain, so a tap re-asserts focus
                // through SwiftUI's focus system.
                .focused($focusedField, equals: field)
                .onTapGesture { focusedField = field }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Airi.neutral50))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Airi.neutral200, lineWidth: 2))
        }
    }

    private func testAI() {
        aiTestResult = "Testing…"
        let settings = ai
        Task {
            aiTestResult = await AIConnectionTest.test(settings)
        }
    }

    private var whitelistCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("Whitelist"), systemImage: "shield.lefthalf.filled")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Text(L("One glob per line. Matching paths are never scanned or deleted. Lines starting with # are ignored."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                Text(SafetyGuard.whitelistURL.path)
                    .font(Airi.monoCaption2Font)
                    .foregroundStyle(Airi.neutral400)
                    .textSelection(.enabled)
                TextEditor(text: $whitelistText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Airi.neutral900)
                    .focused($focusedField, equals: .whitelist)
                    .onTapGesture { focusedField = .whitelist }
                    .frame(minHeight: 120)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: Airi.radiusControl)
                            .fill(Airi.neutral50)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Airi.radiusControl)
                            .strokeBorder(Airi.neutral200, lineWidth: 2)
                    )
                // Save lives IN the card — a page-wide bottom bar made it
                // look like it belonged to whatever card was on screen.
                HStack(spacing: Airi.space2) {
                    if saved {
                        Label(L("Saved"), systemImage: "checkmark.circle.fill")
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.success)
                            .transition(.opacity)
                    }
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.danger)
                    }
                    Spacer()
                    AiriButton(title: L("Save whitelist"), icon: "tray.and.arrow.down") {
                        save()
                    }
                }
                .animation(Airi.controlAnimation, value: saved)
            }
        }
    }

    private var protectionCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("Always protected"), systemImage: "lock.shield")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Text(L("Regardless of whitelist or rules, this app refuses to delete anything outside your home directory and never touches:"))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                FlowProtectedCategories(categories: [
                    L("Keychains"), L("Cookies"), L("Messages"), L("Mail"), L("iCloud Drive"),
                    L("Device Backups"), L("Group Containers"), L("Preferences"), L("Accounts"),
                    L("Safari Data"), L("Browser Profiles"), L("Login Items"),
                ])
            }
        }
    }

    private var aboutCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("About"), systemImage: "info.circle")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Text(L("Moppet 1.0 — a SwiftUI experiment pairing AIRI's design language with a mole-style cleaning engine. Clean previews everything before deleting; installers and archives are moved to the Trash."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
            }
        }
    }

    private func save() {
        let patterns = whitelistText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try SafetyGuard.saveWhitelistPatterns(patterns)
            saveError = nil
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Simple wrapping chip layout for the protected-category list.
struct FlowProtectedCategories: View {
    let categories: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
            ForEach(categories, id: \.self) { category in
                Text(category)
                    .font(Airi.footnoteFont)
                    .foregroundStyle(Airi.neutral700)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(
                        Capsule().fill(Airi.neutral100)
                    )
                    .overlay(
                        Capsule().strokeBorder(Airi.neutral200.opacity(0.7), lineWidth: 1)
                    )
            }
        }
    }
}

/// One custom provider rendered as its own card (ZCode style): the provider
/// NAME is the card title with a … menu (rename / delete), Base URL, API
/// 格式, API key (show/hide) and the per-row model list are inline. New
/// cards (isNew) expose a required "Provider Name" field instead of the
/// rename menu; display names must be unique across providers.
struct ProfileCard: View {
    let profile: AIProviderProfile
    let isNew: Bool
    let isActiveProvider: Bool
    let onChange: () -> Void
    /// Commit path: (saved profile, entered API key). The PARENT upserts and
    /// writes the key slot — only it knows the id that actually landed (slug
    /// collisions get suffixed), and writing to the pre-suffix id would
    /// orphan the key.
    let onCommitDraft: (AIProviderProfile, String) -> Void
    let onDiscard: () -> Void

    @State private var name = ""
    @State private var baseURL = ""
    @State private var format: AIProviderFormat = .chatCompletions
    @State private var apiKey = ""
    @State private var modelRows: [String] = []
    @State private var showKey = false
    @State private var renaming = false
    @State private var renameDraft = ""
    @State private var nameError: String?
    @State private var testResult: String?
    @State private var refreshing = false
    @State private var seeded = false

    private var models: [String] {
        modelRows.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !models.isEmpty
            && nameError == nil
    }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                header
                if let nameError {
                    Label(nameError, systemImage: "exclamationmark.triangle.fill")
                        .font(Airi.footnoteFont)
                        .foregroundStyle(Airi.danger)
                }
                fieldRow(L("Provider Name")) {
                    TextField("My Provider", text: $name)
                        .disabled(!isNew)   // existing cards rename via … menu (stable id)
                }
                fieldRow(L("Base URL")) {
                    TextField("https://host/v1", text: $baseURL)
                }
                fieldRow(L("API format")) {
                    Picker("API format", selection: $format) {
                        ForEach(AIProviderFormat.allCases) { candidate in
                            Text(candidate.displayName).tag(candidate)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
                fieldRow(L("API Key")) {
                    HStack(spacing: 6) {
                        Group {
                            if showKey {
                                TextField(L("sk-… (optional for local servers)"), text: $apiKey)
                            } else {
                                SecureField(L("sk-… (optional for local servers)"), text: $apiKey)
                            }
                        }
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .font(Airi.footnoteFont)
                                .foregroundStyle(Airi.neutral400)
                        }
                        .buttonStyle(.plain)
                        .help(showKey ? L("Hide key") : L("Show key"))
                    }
                }

                // Model list — per-row entries + add button (ZCode style).
                VStack(alignment: .leading, spacing: Airi.space1) {
                    Text(L("Model list"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Airi.neutral700)
                    if modelRows.isEmpty {
                        Text(L("No models configured — add one to use this provider in chat"))
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.neutral400)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                    .foregroundStyle(Airi.neutral200)
                            )
                    }
                    ForEach(modelRows.indices, id: \.self) { index in
                        HStack(spacing: 6) {
                            TextField(L("model id, e.g. glm-4.6"), text: $modelRows[index])
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button {
                                modelRows.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .font(Airi.footnoteFont)
                                    .foregroundStyle(Airi.neutral400)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    AiriButton(title: L("Add model"), icon: "plus", variant: .secondary) {
                        modelRows.append("")
                    }
                }

                HStack(spacing: Airi.space2) {
                    AiriButton(title: L("Refresh from API"), variant: .secondary, busy: refreshing) {
                        Task {
                            refreshing = true
                            var probe = profile
                            probe.baseURL = baseURL
                            probe.format = format
                            probe.models = models
                            let result = await AIModelCatalog.refreshProfile(probe)
                            if result.hasPrefix("✓"),
                               let refreshed = AIProviderRegistry.profile(id: profile.id) {
                                modelRows = refreshed.models
                            }
                            testResult = result
                            refreshing = false
                        }
                    }
                    AiriButton(title: L("Test connection"), variant: .secondary) {
                        Task {
                            var settings = AISettings.load()
                            settings.activeProfileID = profile.id
                            settings.vendor = .custom
                            settings.baseURL = baseURL
                            settings.model = models.first ?? ""
                            settings.apiKey = apiKey
                            testResult = await AIConnectionTest.test(settings)
                        }
                    }
                    if let testResult {
                        Text(testResult).font(Airi.captionFont).foregroundStyle(Airi.neutral500).lineLimit(2)
                    }
                    Spacer()
                    AiriButton(title: L("Save")) { save() }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            name = profile.name
            baseURL = profile.baseURL
            format = profile.effectiveFormat
            modelRows = profile.models
            apiKey = APIKeyStore.read(slot: AIProviderProfileKey(profile.id)) ?? ""
        }
    }

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Airi.space3) {
            Text(title).font(Airi.captionFont).foregroundStyle(Airi.neutral500).frame(width: 90, alignment: .leading)
            content()
                .font(.system(size: 12, design: .monospaced))
        }
    }

    // MARK: header (name + … menu, rename inline, draft name field)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Airi.primary)
            if renaming {
                TextField(L("Rename"), text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, weight: .semibold))
                Button {
                    commitRename()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Airi.success)
                }
                .buttonStyle(.plain)
                Button {
                    renaming = false
                    nameError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Airi.neutral400)
                }
                .buttonStyle(.plain)
            } else {
                Text(name.isEmpty ? profile.name : name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Airi.neutral950)
                    .lineLimit(1)
                if isActiveProvider {
                    Image(systemName: "checkmark.circle.fill")
                        .font(Airi.footnoteFont)
                        .foregroundStyle(Airi.primary)
                        .help(L("Active provider"))
                }
                Spacer()
                if !isNew {
                    Menu {
                        Button(L("Rename")) {
                            renameDraft = name
                            renaming = true
                            nameError = nil
                        }
                        Button(L("Delete provider"), role: .destructive) {
                            _ = AIProviderRegistry.delete(id: profile.id)
                            onChange()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Airi.neutral500)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    private func commitRename() {
        let candidate = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else {
            nameError = L("Name cannot be empty")
            return
        }
        if AIProviderRegistry.nameExists(candidate, excludingID: profile.id) {
            nameError = L("Name already exists")
            return
        }
        _ = AIProviderRegistry.rename(id: profile.id, to: candidate)
        name = candidate
        renaming = false
        nameError = nil
        onChange()
        syncIfActive()
    }

    // MARK: save (draft creates; existing card persists fields)

    private func save() {
        let candidate = name.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else {
            nameError = L("Name cannot be empty")
            return
        }
        // Duplicate display names make the AI Provider picker ambiguous —
        // reject with an inline message instead of silently creating both.
        if AIProviderRegistry.nameExists(candidate, excludingID: isNew ? nil : profile.id) {
            nameError = L("Name already exists")
            return
        }
        nameError = nil

        var saved = profile
        saved.name = candidate
        saved.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        saved.format = format
        saved.models = models
        if isNew {
            // Slug collision → registry suffixes the id; display names are
            // the unique dimension users see.
            saved.id = AIProviderRegistry.slugify(candidate)
        }
        onCommitDraft(saved, apiKey)
        syncIfActive()
    }

    private func syncIfActive() {
        guard !isNew else { return }
        // Parent re-syncs through onChange → profiles reload; the active
        // selection refresh is handled by syncActiveProfile there.
        onChange()
    }
}
