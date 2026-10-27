import SwiftUI
import AppKit

/// Startup items page — disable LaunchAgents/LaunchDaemons so apps stop
/// auto-starting at login and running in the background. One row per item:
/// real app icon (plist items get the document icon), status pill that
/// becomes action buttons on hover (Disable/Enable),
/// Apple's own items hidden by count.
struct LaunchItemsView: View {
    var onClose: (() -> Void)?

    @State private var items: [LaunchItemsEngine.Item] = []
    @State private var hiddenSystem = 0
    @State private var scannedOnce = false
    @State private var scanning = false
    @State private var busyLabel: String?
    @State private var outcomes: [LaunchItemsEngine.Outcome] = []

    private var activeCount: Int {
        items.filter { !$0.disabled }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Startup"), subtitle: L("Disable login agents & daemons — stop background auto-starts"), onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            ScrollView {
                VStack(spacing: Airi.space2) {
                    introCard
                    if scanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Scanning launch folders…")).font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                        }
                        .padding(.top, 20)
                    }
                    ForEach(items) { item in
                        LaunchItemRow(
                            item: item,
                            isBusy: busyLabel == item.label,
                            onToggle: { Task { await toggle(item) } })
                    }
                    if scannedOnce && items.isEmpty && !scanning {
                        Text(L("No third-party launch items found"))
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.neutral500)
                            .padding(.top, 16)
                    }
                    if !items.isEmpty {
                        Text(summaryFooter)
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.neutral500)
                    }
                    ForEach(outcomes) { outcome in
                        outcomeRow(outcome)
                    }
                }
                .padding(Airi.space4)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Airi.pageBackground.opacity(0.001))
        .task {
            guard !scannedOnce else { return }
            await scan()
        }
    }

    private var summaryFooter: String {
        var parts = [String(format: L("%1$lld active · %2$lld disabled"),
                            activeCount, items.count - activeCount)]
        if hiddenSystem > 0 {
            parts.append(String(format: L("%lld Apple system items hidden"), hiddenSystem))
        }
        parts.append(L("newer apps may register via System Settings → Login Items"))
        return parts.joined(separator: " · ")
    }

    private var introCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Text(L("How this works")).font(Airi.cardTitleFont)
                Text(L("Each row is a launchd plist from ~/Library/LaunchAgents, /Library/LaunchAgents or /Library/LaunchDaemons. Disabling sets its Disabled flag (persistent) and unloads it right away — reversible, nothing is deleted. Global items need an administrator password. Apple system items are hidden (disabling boot daemons can wedge macOS)."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                HStack {
                    AiriButton(title: scannedOnce ? L("Rescan") : L("Scan"),
                               icon: "magnifyingglass", disabled: scanning) {
                        Task { await scan() }
                    }
                }
            }
        }
    }

    private func scan() async {
        scanning = true
        (items, hiddenSystem) = await LaunchItemsEngine.scan()
        scanning = false
        scannedOnce = true
    }

    private func toggle(_ item: LaunchItemsEngine.Item) async {
        busyLabel = item.label
        // Path first: same label in two scopes must flip THIS row's file.
        let outcome = await LaunchItemsEngine.setEnabled(
            item.path, enabled: item.disabled)
        outcomes.append(outcome)
        if outcomes.count > 6 { outcomes.removeFirst(outcomes.count - 6) }
        busyLabel = nil
        await scan()
    }

    private func outcomeRow(_ outcome: LaunchItemsEngine.Outcome) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: outcome.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(outcome.success ? Airi.success : Airi.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(outcome.label) → \(outcome.enabled ? L("Enable") : L("Disable"))")
                    .font(Airi.footnoteFont.weight(.medium))
                    .foregroundStyle(Airi.neutral900)
                Text(outcome.message)
                    .font(Airi.monoCaption2Font)
                    .foregroundStyle(Airi.neutral700)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusCard)
                .fill(Airi.neutral100.opacity(0.6))
        )
    }
}

// MARK: - Row (icon · name · status pill → hover actions)

/// One launch item, reference-design style: real app icon when the program
/// lives inside an .app bundle (plist-only items keep the document icon),
/// a status pill (● Enabled / ● Disabled) that swaps to action buttons
/// while hovered.
private struct LaunchItemRow: View {
    let item: LaunchItemsEngine.Item
    let isBusy: Bool
    var onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: Self.icon(for: item))
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(Airi.cardTitleFont)
                        .foregroundStyle(Airi.neutral900)
                        .lineLimit(1)
                    if item.scope.needsAdmin {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 9))
                            .foregroundStyle(Airi.warning)
                    }
                }
                Text("\(item.label) · \(item.path)")
                    .font(Airi.monoCaption2Font)
                    .foregroundStyle(Airi.neutral500)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small)
            } else if hovering {
                HStack(spacing: Airi.space1) {
                    AiriButton(title: item.disabled ? L("Enable") : L("Disable"),
                               variant: item.disabled ? .primary : .secondary) {
                        onToggle()
                    }
                }
                .transition(.opacity)
            } else {
                statusPill
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusCard)
                .fill(hovering ? Airi.primary.opacity(0.04) : Airi.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Airi.radiusCard)
                .strokeBorder(Airi.neutral200.opacity(hovering ? 0.9 : 0.6), lineWidth: 1)
                // Decorative border — on macOS 26 the stroke shape is
                // hit-tested across its whole bounds and swallowed the row's
                // toggle/button clicks. Never let it intercept.
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Airi.controlAnimation) { self.hovering = hovering }
        }
        .help(Self.tooltip(for: item))
    }

    /// Idle-state badge: green dot = enabled (starts at login), gray = disabled.
    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(item.disabled ? Airi.neutral400 : Airi.success)
                .frame(width: 7, height: 7)
            Text(item.disabled ? L("Disabled") : L("Enabled"))
                .font(Airi.caption2Font)
                .foregroundStyle(item.disabled ? Airi.neutral500 : Airi.neutral900)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Airi.neutral100.opacity(0.7)))
    }

    /// App icon when the program lives inside an .app bundle; the generic
    /// plist document icon otherwise (matches the reference design).
    private static func icon(for item: LaunchItemsEngine.Item) -> NSImage {
        var target = item.program
        if let range = target.range(of: ".app/Contents/") {
            target = String(target[..<range.lowerBound]) + ".app"
        }
        if FileManager.default.fileExists(atPath: target) {
            return NSWorkspace.shared.icon(forFile: target)
        }
        return NSWorkspace.shared.icon(forFile: item.path)
    }

    private static func tooltip(for item: LaunchItemsEngine.Item) -> String {
        var parts: [String] = [item.label]
        if item.runAtLoad { parts.append("RunAtLoad") }
        if item.keepAlive { parts.append("KeepAlive") }
        if item.loaded { parts.append(L("loaded")) }
        if item.scope.needsAdmin { parts.append(L("Needs an administrator password to change")) }
        return parts.joined(separator: " · ")
    }
}
