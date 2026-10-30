import SwiftUI

/// Settings → "Brain Growth".
///
/// Design doc §9.4 answers the two questions this card exists for:
/// **P3 is off by default** (the user hands over the wheel only after seeing
/// the pet learn), and **there is no "IQ score"** — only behaviour facts the
/// user can verify ("it stopped asking about browser scope").
///
/// Everything shown here is derived on demand from disk. Nothing is cached in
/// a view model, because the truth is the file tree (§5.12, I3).
struct BrainGrowthCard: View {

    @State private var enabled = GrowthSettings.enabled
    @State private var evolve = GrowthSettings.evolveEnabled
    @State private var alwaysOn = 0
    @State private var skills = 0
    @State private var facts = 0
    @State private var lessons: [Lesson] = []
    @State private var pending: [Evolver.Pending] = []
    @State private var spentToday = 0
    /// Editable daily token cap (GrowthSettings.dailyTokens). The ledger reads
    /// it on every `canSpend`, so a change applies to the next model call.
    @State private var dailyBudget = GrowthSettings.dailyTokens
    @State private var version = 0
    @State private var lastSummary = ""
    @State private var lastParent = 0
    @State private var badRatio = ""
    @State private var canaryLine = ""
    @State private var skillNames: [String] = []
    @State private var memoryCues: [String] = []
    /// True while a destructive action (delete lesson / rollback / discard
    /// proposal) is in flight — disables the button and shows a spinner so
    /// the user knows the click registered.
    @State private var isProcessing = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Label(L("Brain Growth"), systemImage: "leaf.circle")
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Text(L("The pet can learn from your own sessions: what it did right, where it hesitated, what you refused. Everything stays on this Mac as plain text files."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                    .fixedSize(horizontal: false, vertical: true)

                ToggleRow(title: L("Learn from my sessions"),
                          subtitle: L("Record how each turn ended and reflect on the bad ones. Costs a few thousand tokens a day at most; a hard daily budget applies."),
                          isOn: Binding(
                            get: { enabled },
                            set: { newValue in
                                enabled = newValue
                                GrowthSettings.enabled = newValue
                                refresh()
                            }))

                ToggleRow(title: L("Let it rewrite its own instructions"),
                          subtitle: L("Off by default. Changes are proposed only when idle, must pass validation and a shadow-replay comparison, and anything touching the always-on prompt waits for your approval here."),
                          isOn: Binding(
                            get: { evolve },
                            set: { newValue in
                                evolve = newValue
                                GrowthSettings.evolveEnabled = newValue
                                refresh()
                            }))

                // Behaviour facts, never a score (§9.4 #5). A table keeps the
                // five numbers in real columns — the old HStack strip let the
                // "Always-on" label run into its own value.
                GrowthStatsTable(
                    items: [
                        .init(icon: "text.alignleft",
                              title: L("Always-on prompt"),
                              value: alwaysOn.formatted(),
                              suffix: "/ " + HarnessSurface.totalCap.formatted(),
                              fraction: Double(alwaysOn) / Double(max(1, HarnessSurface.totalCap))),
                        .init(icon: "sparkles",
                              title: L("Skills"),
                              value: skills.formatted()),
                        .init(icon: "brain",
                              title: L("Memories"),
                              value: facts.formatted()),
                        .init(icon: "book.closed",
                              title: L("Lessons"),
                              value: lessons.count.formatted()),
                        .init(icon: "creditcard",
                              title: L("Spent today"),
                              value: spentToday.formatted(),
                              suffix: "/ " + GrowthSettings.dailyTokens.formatted() + " tk",
                              fraction: Double(spentToday) / Double(max(1, GrowthSettings.dailyTokens))),
                    ],
                    // Where the learning lives — plain text on this Mac, as
                    // the card's intro promises.
                    footer: GrowthPaths.root.path)

                budgetRow

                if !badRatio.isEmpty {
                    Text(badRatio)
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
                if version > 0 {
                    HStack(spacing: Airi.space2) {
                        Text(L("Harness version") + " v\(version)"
                             + (lastSummary.isEmpty ? "" : " · \(lastSummary)"))
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.neutral500)
                        Spacer()
                        Button(L("Roll back")) {
                            isProcessing = true
                            Task {
                                _ = try? PromotionGate.rollback()
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                isProcessing = false
                                refresh()
                            }
                        }
                        .controlSize(.small)
                        .disabled(isProcessing)
                        .help(L("Restore the version before the last change"))
                    }
                }
                if !canaryLine.isEmpty {
                    Text(canaryLine)
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
                if !skillNames.isEmpty {
                    Text(L("Skills") + ": " + skillNames.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(Airi.neutral500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !memoryCues.isEmpty {
                    Text(L("Memories") + ": " + memoryCues.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(Airi.neutral500)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !pending.isEmpty {
                    Text(L("Waiting for your approval"))
                        .font(Airi.captionFont.weight(.semibold))
                        .foregroundStyle(Airi.neutral900)
                        .padding(.top, Airi.space1)
                    ForEach(pending, id: \.id) { proposal in
                        HStack(spacing: Airi.space2) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(proposal.domain) · \(proposal.diff.count) " + L("files"))
                                    .font(Airi.captionFont)
                                    .foregroundStyle(Airi.neutral900)
                                Text(proposal.reason)
                                    .font(Airi.captionFont)
                                    .foregroundStyle(Airi.neutral500)
                                if !proposal.diff.isEmpty {
                                    Text(proposal.diff.joined(separator: " · "))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Airi.neutral500)
                                }
                            }
                            Spacer()
                            Button(L("Approve")) {
                                isProcessing = true
                                Task {
                                    _ = Evolver.approve(proposal.id)
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    isProcessing = false
                                    refresh()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isProcessing)
                            Button(L("Discard")) {
                                isProcessing = true
                                Task {
                                    Evolver.reject(proposal.id)
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    isProcessing = false
                                    refresh()
                                }
                            }
                            .controlSize(.small)
                            .disabled(isProcessing)
                        }
                    }
                }

                if !lessons.isEmpty {
                    Text(L("What it has learned"))
                        .font(Airi.captionFont.weight(.semibold))
                        .foregroundStyle(Airi.neutral900)
                        .padding(.top, Airi.space1)
                    ForEach(lessons.prefix(6), id: \.id) { lesson in
                        HStack(alignment: .top, spacing: Airi.space2) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lesson.lesson)
                                    .font(Airi.captionFont)
                                    .foregroundStyle(Airi.neutral900)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("[\(lesson.intent.rawValue)] " + lesson.cue)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Airi.neutral500)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button {
                                isProcessing = true
                                Task {
                                    _ = LessonLibrary.remove(lesson)
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    isProcessing = false
                                    refresh()
                                }
                            } label: {
                                if isProcessing {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "trash")
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isProcessing)
                            .help(L("Forget this lesson"))
                        }
                    }
                }
            }
        }
        .task { refresh() }
    }

    /// Daily token cap — editable here instead of only living in UserDefaults.
    /// `GrowthLedger.canSpend` reads `GrowthSettings.dailyTokens` on every
    /// model call, so a change takes effect on the next turn (no restart).
    private var budgetRow: some View {
        HStack(alignment: .center, spacing: Airi.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Daily spend limit"))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral700)
                Text(L("Hard cap on what the growth loop may spend per day — it stops once the cap is reached."))
                    .font(.system(size: 10))
                    .foregroundStyle(Airi.neutral500)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Airi.space2)
            HStack(spacing: 6) {
                TextField("", value: $dailyBudget, format: .number.grouping(.automatic))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 86)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Airi.neutral50))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Airi.neutral200, lineWidth: 1)
                    )
                Text("tk")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Airi.neutral400)
                Stepper("", value: $dailyBudget, in: Self.budgetRange, step: 25_000)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .onChange(of: dailyBudget) { _, _ in commitBudget() }
    }

    private static let budgetRange: ClosedRange<Int> = 10_000...1_000_000

    /// Clamp + persist, then refresh so the "Spent today" row and its usage
    /// bar follow the new cap immediately.
    private func commitBudget() {
        let clamped = min(Self.budgetRange.upperBound,
                          max(Self.budgetRange.lowerBound, dailyBudget))
        if clamped != dailyBudget { dailyBudget = clamped }
        guard GrowthSettings.dailyTokens != clamped else { return }
        GrowthSettings.dailyTokens = clamped
        refresh()
    }

    private func refresh() {
        let tree = HarnessStore.load()
        alwaysOn = HarnessSurface.alwaysOnChars(tree)
        let skills = SkillCatalog.skills(tree: tree)
        skillNames = skills.map(\.name)
        self.skills = skills.count
        let facts = MemoryBank.facts(tree: tree)
        memoryCues = facts.map(\.cue)
        self.facts = facts.count
        lessons = LessonLibrary.all().sorted { $0.createdAt > $1.createdAt }
        pending = Evolver.pending()
        spentToday = GrowthLedger.shared.spentToday()
        let versions = PromotionGate.versions()
        version = versions.last?.version ?? 0
        lastSummary = versions.last?.summary ?? ""
        lastParent = versions.last?.parent ?? 0

        // Gate ③ status: what is being watched right now (or last fired).
        if let canary = CanaryWatcher.state() {
            canaryLine = L("Canary: v\(canary.version) (\(canary.domain)) is being watched — auto-rollback fires on 2 bad turns in a row or a 20% regression")
        } else if let audit = GrowthPaths.read(CanaryWatcher.auditURL) {
            canaryLine = audit.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            canaryLine = ""
        }

        // "This week it went wrong N times out of M" — a fact, not a grade.
        let recent = TurnOutcomeLog.load(days: 7)
        if recent.count >= 5 {
            let bad = recent.filter { $0.verdict == .bad }.count
            badRatio = L("Last 7 days: \(recent.count) turns, \(bad) needed a retry")
        } else {
            badRatio = ""
        }
    }
}

// MARK: - Stats table

/// The "what it has learned so far" table: one row per behaviour fact, with
/// the number right-aligned and a slim usage bar for the two budgeted rows.
///
/// Deliberately NOT a `Table`: this is five fixed rows inside a settings card,
/// and `Table` brings its own scroll container, selection and header chrome
/// that fight the card layout. The column grid here is stable — title column
/// flexes, value and bar columns are fixed width, so every row lines up.
struct GrowthStatsTable: View {

    struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let value: String
        var suffix: String? = nil
        /// 0…1 fill for the usage bar; nil = no bar for this row.
        var fraction: Double? = nil
    }

    let items: [Item]
    /// Shown under the last row (e.g. where the data lives on disk).
    var footer: String? = nil

    private let valueColumn: CGFloat = 104
    private let barColumn: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Airi.neutral200.opacity(0.6))
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    Divider()
                        .overlay(Airi.neutral200.opacity(0.35))
                        .padding(.leading, 26)
                }
            }
            if let footer {
                Divider().overlay(Airi.neutral200.opacity(0.6))
                Text(footer)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Airi.neutral400)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusControl, style: .continuous)
                .fill(Airi.neutral50.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Airi.radiusControl, style: .continuous)
                .strokeBorder(Airi.neutral200.opacity(0.7), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("Metric"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L("Value"))
                .frame(width: valueColumn, alignment: .trailing)
            Text(L("Usage"))
                .frame(width: barColumn, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Airi.neutral400)
        .textCase(.uppercase)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Airi.neutral400)
                    .frame(width: 14)
                Text(item.title)
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral700)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(item.value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Airi.neutral950)
                if let suffix = item.suffix {
                    Text(suffix)
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Airi.neutral400)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(width: valueColumn, alignment: .trailing)

            usageBar(item.fraction)
                .frame(width: barColumn)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// Slim capsule gauge; turns amber past 90% of the budget so "nearly out"
    /// is visible without reading the numbers.
    private func usageBar(_ fraction: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Airi.neutral200.opacity(0.75))
                if let fraction {
                    let clamped = min(1, max(0, fraction))
                    Capsule()
                        .fill(clamped > 0.9 ? Airi.danger : Airi.primary)
                        .frame(width: max(3, geo.size.width * clamped))
                        .animation(.easeOut(duration: 0.35), value: clamped)
                }
            }
        }
        .frame(height: 4)
        .opacity(fraction == nil ? 0 : 1)
    }
}
