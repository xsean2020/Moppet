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

    var body: some View {
        ScrollView {
            VStack(spacing: Airi.space3) {
                header
                diskCard
                cleanStatsCard
                quickActions
                statusRow
            }
            .padding(Airi.space4)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Airi.pageBackground.opacity(0.001))
        .onAppear {
            disk = DiskInfo.snapshot()
            ai = AISettings.load()
            // Rollout enumeration reads every session file — keep it off the
            // main thread so the dashboard appears instantly.
            Task {
                let count = await Task.detached {
                    BrainRollout.listSessions(limit: 50).total
                }.value
                recentSessions = count
                // The audit log is a file read + JSON decode — keep it off
                // the main thread like the session count above.
                let loaded = await Task.detached { HistoryStore.totals() }.value
                withAnimation(Airi.controlAnimation) { totals = loaded }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Airi.space3) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(Airi.pageTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Text(String(format: L("%@ is on the desktop. Everything below is previewed before anything is deleted."),
                            PetIdentity.name))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
            }
            Spacer()
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

    private var diskCard: some View {
        SettingsCard(padding: Airi.space4) {
            HStack(alignment: .center, spacing: Airi.space4) {
                ProgressRing(progress: disk.usedFraction,
                             lineWidth: 10,
                             tint: diskTint,
                             showValue: true,
                             valueText: disk.usedFraction.percentFormatted,
                             valueFontSize: 16)
                    .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 6) {
                    Text(disk.volumeName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Airi.neutral950)
                    Text(String(format: L("%@ used · %@ free of %@"),
                                disk.usedBytes.bytesFormatted,
                                disk.freeBytes.bytesFormatted,
                                disk.totalBytes.bytesFormatted))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                        .monospacedDigit()
                    Text(String(format: L("%@ free"), disk.freeBytes.bytesFormatted))
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(diskTint)
                        .monospacedDigit()
                }
                Spacer()
            }
        }
        .animation(Airi.controlAnimation, value: disk.usedFraction)
    }

    // MARK: - Lifetime cleanup stats

    /// "How much junk has this app removed for me?" — the one number the
    /// dashboard was missing. Everything comes from HistoryStore.totals().
    private var cleanStatsCard: some View {
        Button {
            navigate(.history)
        } label: {
            SettingsCard {
                HStack(alignment: .center, spacing: Airi.space4) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(L("Cleaned so far"))
                                .font(Airi.captionFont)
                                .foregroundStyle(Airi.neutral500)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Airi.neutral400)
                        }
                        Text(totals.map { $0.totalBytes.bytesFormatted } ?? "—")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .foregroundStyle(Airi.primary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(statsDetail)
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.neutral500)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Airi.space3)
                    VStack(alignment: .trailing, spacing: 6) {
                        splitBar
                        legend
                    }
                    .frame(width: 168)
                }
            }
        }
        .buttonStyle(.plain)
        .help(L("Open the cleanup history"))
    }

    /// "12 runs · last 2026-10-27 13:06 · 1,204 paths"
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
            parts.append(String(format: L("last %@"),
                                last.formatted(date: .abbreviated, time: .shortened)))
        }
        return parts.joined(separator: " · ")
    }

    /// Permanent vs Trash proportion — trash bytes are recoverable, so the
    /// split matters more than the total alone.
    private var splitBar: some View {
        GeometryReader { geo in
            let permanent = CGFloat(totals?.permanentBytes ?? 0)
            let trash = CGFloat(totals?.trashBytes ?? 0)
            let sum = max(permanent + trash, 1)
            let permWidth = geo.size.width * (permanent / sum)
            ZStack(alignment: .leading) {
                Capsule().fill(Airi.neutral200.opacity(0.6))
                HStack(spacing: 2) {
                    Capsule().fill(Airi.danger.opacity(0.75))
                        .frame(width: max(0, permWidth - 1))
                    Capsule().fill(Airi.primary.opacity(0.75))
                }
            }
        }
        .frame(height: 8)
        .animation(Airi.controlAnimation, value: totals?.totalBytes ?? 0)
    }

    private var legend: some View {
        VStack(alignment: .trailing, spacing: 2) {
            legendRow(color: Airi.danger, label: L("Permanent"),
                      bytes: totals?.permanentBytes ?? 0)
            legendRow(color: Airi.primary, label: L("Trash"),
                      bytes: totals?.trashBytes ?? 0)
        }
    }

    private func legendRow(color: Color, label: String, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color.opacity(0.8)).frame(width: 6, height: 6)
            Text(label)
                .font(Airi.caption2Font)
                .foregroundStyle(Airi.neutral500)
            Text(bytes.bytesFormatted)
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
                       title: ai.isConfigured ? "\(ai.vendor.displayName)" : L("AI not configured"),
                       detail: ai.isConfigured ? ai.model : L("Settings → AI Provider"),
                       tint: ai.isConfigured ? Airi.success : Airi.warning) {
                navigate(.settings)
            }
            statusChip(icon: "bubble.left.and.bubble.right",
                       title: "\(recentSessions) \(L("chat sessions"))",
                       detail: L("rollout JSONL history"),
                       tint: Airi.primary) { openChat() }
            statusChip(icon: "server.rack",
                       title: L("MCP server"),
                       detail: "\(ToolRegistry.tools.count) \(L("tools")) · --mcp",
                       tint: Airi.primary) { navigate(.settings) }
            Spacer(minLength: 0)
        }
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
                        .font(.system(size: 10, weight: .medium))
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
    }
}
