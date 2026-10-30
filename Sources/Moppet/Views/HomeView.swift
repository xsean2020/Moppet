import SwiftUI
import AppKit

/// Dashboard — the main window landing page: disk snapshot, quick actions
/// and AI/pet status. Module navigation lives in the window sidebar.
struct HomeView: View {
    var navigate: (Route) -> Void
    var openChat: () -> Void

    @State private var disk = DiskInfo.snapshot()
    @State private var ai = AISettings.load()
    @State private var recentSessions = 0
    /// Lifetime cleanup totals from the audit log (nil until loaded).
    @State private var totals: HistoryStore.Totals?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: Airi.space3) {
                header
                // Disk pressure and lifetime savings answer the two questions
                // the dashboard exists for, so they share one row. Stacked
                // vertically they each wasted half their width on a Spacer.
                HStack(alignment: .top, spacing: Airi.space3) {
                    diskCard
                    cleanStatsCard
                }
                quickActions
                statusRow
            }
            .padding(Airi.space4)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Airi.pageBackground.opacity(0.001))
        .onAppear {
            disk = DiskInfo.snapshot()
            ai = AISettings.load()
        }
        // Rollout enumeration reads every session file — keep it off the
        // main thread so the dashboard appears instantly.
        .task {
            let count = await Task.detached {
                BrainRollout.listSessions(limit: 50).total
            }.value
            recentSessions = count
            // The audit log is a file read + JSON decode — keep it off
            // the main thread like the session count above.
            let loaded = await Task.detached { HistoryStore.totals() }.value
            if reduceMotion {
                totals = loaded
            } else {
                withAnimation(Airi.controlAnimation) { totals = loaded }
            }
        }
        // Disk numbers used to be frozen at launch. Refresh on window
        // activation and once a minute so a long-lived window stays honest.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                disk = DiskInfo.snapshot()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            disk = DiskInfo.snapshot()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Airi.space3) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(Airi.pageTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Text(String(format: L("%@ is on the desktop. Everything below is previewed before anything is deleted."),
                            PetIdentity.name))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Airi.space2)
            // The dashboard's first question is "what can I clean now?" —
            // give it one obvious, solid action instead of four equal cards.
            AiriButton(title: L("Scan for cleanable items"), icon: "magnifyingglass") {
                CleanLaunch.requestScan()
                navigate(.clean)
            }
            .fixedSize(horizontal: true, vertical: false)
            .help(L("Open the clean page and scan the current selection"))
            .accessibilityLabel(Text(L("Scan for cleanable items")))
        }
        .padding(.top, Airi.space2)
    }

    /// Time-of-day greeting over the user's macOS account name — the old
    /// "Hi Sean" was hardcoded to one user (and ignored renames of the pet).
    private var greeting: String {
        let userName = NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"
        let hour = Calendar.current.component(.hour, from: Date())
        let timeKey: String
        switch hour {
        case 5..<12: timeKey = L("Good morning")
        case 12..<18: timeKey = L("Good afternoon")
        default: timeKey = L("Good evening")
        }
        return "\(timeKey), \(userName) 👋"
    }

    // MARK: - Disk

    /// Ring color tracks disk pressure — the dashboard card is the first
    /// thing on screen, so the state should read at a glance.
    private var diskTint: Color {
        switch disk.usedFraction {
        case ..<0.75: return Airi.success
        case ..<0.90: return Airi.warning
        default: return Airi.danger
        }
    }

    /// Only rendered when the ring is no longer green. Orange at 19pt on a
    /// white card measured 2:1, so the numeral stays neutral and the hue
    /// moves into a small badge instead.
    private var diskPressureLabel: String? {
        switch disk.usedFraction {
        case ..<0.75: return nil
        case ..<0.90: return L("Tight")
        default: return L("Very low")
        }
    }

    /// One-decimal strings that satisfy `used + free == total` when a reader
    /// adds them up (see `Int64.diskDisplay`).
    private var diskDisplay: (used: String, free: String, total: String) {
        Int64.diskDisplay(total: disk.totalBytes, free: disk.freeBytes)
    }

    private var diskCard: some View {
        SettingsCard(padding: Airi.space4) {
            HStack(alignment: .center, spacing: Airi.space3) {
                ProgressRing(progress: disk.usedFraction,
                             lineWidth: 9,
                             tint: diskTint,
                             showValue: true,
                             valueText: disk.usedFraction.percentFormatted,
                             valueFontSize: 15)
                    .frame(width: 82, height: 82)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(disk.volumeName)
                            .font(Airi.emphasisFont)
                            .foregroundStyle(Airi.neutral950)
                            .lineLimit(1)
                        if let pressure = diskPressureLabel {
                            Text(pressure)
                                .font(Airi.caption2Font.weight(.medium))
                                .foregroundStyle(Airi.warningStrong)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Airi.warningStrong.opacity(0.12)))
                        }
                    }
                    Text(String(format: L("%@ used of %@"),
                                diskDisplay.used,
                                diskDisplay.total))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(diskDisplay.free)
                            .font(Airi.metricSmallFont)
                            .foregroundStyle(Airi.neutral900)
                            .monospacedDigit()
                        Text(L("Available"))
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral500)
                    }
                    .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 116, maxHeight: .infinity,
                   alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : Airi.controlAnimation, value: disk.usedFraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(format: L("%@ used of %@"),
                                         diskDisplay.used, diskDisplay.total))
                            + Text(", ") + Text(diskDisplay.free) + Text(" ")
                            + Text(L("Available")))
    }

    // MARK: - Lifetime cleanup stats

    /// "How much junk has this app removed for me?" — the one number the
    /// dashboard was missing. Everything comes from HistoryStore.totals().
    private var cleanStatsCard: some View {
        Button {
            navigate(.history)
        } label: {
            SettingsCard(padding: Airi.space4) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(L("Cleaned so far"))
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.neutral500)
                        Image(systemName: "chevron.right")
                            .font(Airi.caption2Font.weight(.semibold))
                            .foregroundStyle(Airi.neutral400)
                    }
                    Text(totals.map { $0.totalBytes.bytesFormatted1 } ?? "—")
                        .font(Airi.metricFont)
                        // The loading placeholder should read as absence, not
                        // as a tiny blue metric line.
                        .foregroundStyle(totals == nil ? Airi.neutral400 : Airi.primary600)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .padding(.top, 2)
                    Text(statsDetail)
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    Spacer(minLength: Airi.space2)
                    splitBar
                    legend
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, minHeight: 116, maxHeight: .infinity,
                       alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .help(L("Open the cleanup history"))
        .accessibilityLabel(Text(L("Cleaned so far") + ": " + (totals.map { $0.totalBytes.bytesFormatted1 } ?? "—")))
    }

    /// "12 runs · 1,204 paths · 3 hours ago"
    private var statsDetail: String {
        guard let totals else { return L("Reading history…") }
        guard totals.runs > 0 else {
            return L("No runs yet — your first clean will show up here.")
        }
        var parts: [String] = [String(format: L("%lld runs"), totals.runs)]
        if totals.itemCount > 0 {
            parts.append(String(format: L("%lld paths"), totals.itemCount))
        }
        if let last = totals.lastRun {
            // "12 runs · 1,204 paths · 3 hours ago" — no "last" prefix, which
            // read as "最近 3小时前" once the timestamp turned relative.
            parts.append(L10n.relativeDate(last))
        }
        return parts.joined(separator: " · ")
    }

    /// Permanent vs Trash proportion — trash bytes are recoverable, so the
    /// split matters more than the total alone.
    private var splitBar: some View {
        GeometryReader { geo in
            let permanent = CGFloat(totals?.permanentBytes ?? 0)
            let trash = CGFloat(totals?.trashBytes ?? 0)
            let sum = permanent + trash
            ZStack(alignment: .leading) {
                Capsule().fill(Airi.neutral200.opacity(0.6))
                // No history yet (or all-zero runs) must read as an empty
                // track — the old expanding HStack painted a full green bar.
                if sum > 0 {
                    HStack(spacing: 2) {
                        Capsule().fill(Airi.danger.opacity(0.75))
                            .frame(width: max(0, geo.size.width * (permanent / sum) - 1))
                        Capsule().fill(Airi.successStrong.opacity(0.75))
                            .frame(width: max(0, geo.size.width * (trash / sum) - 1))
                    }
                }
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : Airi.controlAnimation, value: totals?.totalBytes ?? 0)
    }

    private var legend: some View {
        HStack(spacing: Airi.space3) {
            legendRow(color: Airi.danger, label: L("Permanent"),
                      bytes: totals?.permanentBytes ?? 0)
            // Green = recoverable. Blue was the brand/interaction colour, so
            // "Trash" read as "normal/good" next to red "Permanent".
            legendRow(color: Airi.successStrong, label: L("Trash"),
                      bytes: totals?.trashBytes ?? 0)
            Spacer(minLength: 0)
        }
    }

    private func legendRow(color: Color, label: String, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color.opacity(0.8)).frame(width: 6, height: 6)
            Text(label)
                .font(Airi.caption2Font)
                .foregroundStyle(Airi.neutral500)
            Text(bytes.bytesFormatted1)
                .font(Airi.caption2Font)
                .foregroundStyle(Airi.neutral700)
                .monospacedDigit()
        }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Airi.space3),
                            GridItem(.flexible(), spacing: Airi.space3)],
                  spacing: Airi.space3) {
            // No mono eyebrow tags ("mo uninstall" etc.) — titles + subtitles
            // only; the tags duplicated mole command names users never type.
            IconItemCard(icon: "paintbrush",
                         title: L("Quick Clean"),
                         subtitle: L("Scan caches, logs, dev artifacts & installers, then review"),
                         entranceIndex: 0) { navigate(.clean) }
            IconItemCard(icon: "bubble.left.and.bubble.right.fill",
                         title: L("Ask the Brain"),
                         subtitle: ai.isConfigured
                            ? L("Codex-style agent with shell, patches & cleaning tools")
                            : L("Add an API key in Settings to enable the agent"),
                         entranceIndex: 1) { openChat() }
            IconItemCard(icon: "square.and.arrow.down.on.square",
                         title: L("Uninstall Apps"),
                         subtitle: L("Trash apps and sweep their leftovers"),
                         entranceIndex: 2) { navigate(.uninstall) }
            IconItemCard(icon: "shippingbox",
                         title: L("Purge Projects"),
                         subtitle: L("node_modules & friends across your code folders"),
                         entranceIndex: 3) { navigate(.purge) }
        }
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(spacing: Airi.space3) {
            statusChip(icon: "brain.head.profile",
                       title: ai.isConfigured ? ai.model : L("AI not configured"),
                       detail: ai.isConfigured ? vendorLabel : L("Settings → AI Provider"),
                       tint: ai.isConfigured ? Airi.success : Airi.warning) {
                navigate(.settings)
            }
            statusChip(icon: "bubble.left.and.bubble.right",
                       title: "\(recentSessions) \(L("chat sessions"))",
                       detail: L("Chat history"),
                       tint: Airi.primary) { openChat() }
            statusChip(icon: "server.rack",
                       title: L("MCP server"),
                       detail: String(format: L("%lld tools available"), ToolRegistry.tools.count),
                       tint: Airi.primary) { navigate(.settings) }
            Spacer(minLength: 0)
        }
    }

    /// "Custom OpenAI-compatible" is implementation language; outside the
    /// provider picker it becomes "Custom endpoint". An active profile shows
    /// its own name instead.
    private var vendorLabel: String {
        // A custom profile's display name is often just the model id again
        // ("GROK4.7" under "grok-4.7"). The useful subtitle is what kind of
        // endpoint it is, so keep the generic label for `.custom`.
        ai.vendor == .custom ? L("Custom endpoint") : ai.vendor.displayName
    }

    private func statusChip(icon: String, title: String, detail: String,
                            tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(Airi.footnoteFont)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(Airi.caption2Font.weight(.medium))
                        .foregroundStyle(Airi.neutral800)
                        .lineLimit(1)
                    Text(detail)
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral500)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Airi.neutral100)
            )
            .overlay(Capsule().strokeBorder(Airi.neutral200.opacity(0.7), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title). \(detail)"))
    }
}
