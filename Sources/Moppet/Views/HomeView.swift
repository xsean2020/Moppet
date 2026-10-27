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

    var body: some View {
        ScrollView {
            VStack(spacing: Airi.space3) {
                header
                diskCard
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
