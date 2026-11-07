import SwiftUI
import AppKit

/// Startup items page — disable LaunchAgents/LaunchDaemons so apps stop
/// auto-starting at login and running in the background.
///
/// Layout: one compact summary strip (how many are on, rescan, how-it-works
/// popover) → one grouped list of items with a real macOS **switch** per row.
/// The old design hid the action behind a hover swap (status pill → button):
/// you had to discover it, and the pill said "已启用" in a colour nobody could
/// map to on/off. A switch is the platform's own on/off control and is
/// readable at a glance, which is what this page is for.
struct LaunchItemsView: View {
    var onClose: (() -> Void)?

    @State private var items: [LaunchItemsEngine.Item] = []
    @State private var hiddenSystem = 0
    @State private var scannedOnce = false
    @State private var scanning = false
    /// Keyed by PATH, not label: the same label installed in both
    /// ~/Library and /Library would light up two rows at once (§6.22).
    @State private var busyPath: String?
    @State private var outcomes: [LaunchItemsEngine.Outcome] = []
    @State private var showHowItWorks = false

    /// Offscreen probe hook (`--probe-render startup`): `.task` never fires in
    /// the probe's invisible window, so without a seed the render only shows
    /// the summary strip and a spinner — i.e. not the list this page is.
    static var debugSeed = false

    private var activeCount: Int {
        items.filter { !$0.disabled }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Startup"),
                       subtitle: L("Disable login agents & daemons — stop background auto-starts"),
                       onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            ScrollView {
                VStack(spacing: Airi.space3) {
                    summaryCard
                    if items.isEmpty {
                        if scanning { scanningCard } else if scannedOnce { emptyCard }
                    } else {
                        itemsCard
                    }
                    if !outcomes.isEmpty { outcomeList }
                    if !items.isEmpty { footerNote }
                }
                .padding(.horizontal, Airi.space4)
                .padding(.top, Airi.space3)
                .padding(.bottom, Airi.space4)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Airi.pageBackground.opacity(0.001))
        .task {
            if Self.debugSeed { seedForProbe(); return }
            guard !scannedOnce else { return }
            await scan()
        }
    }

    // MARK: - Summary

    /// Counts + the one action. The four-line "工作原理" paragraph used to sit
    /// here at full size and pushed the actual list below the fold; it now
    /// lives in a popover behind the ⓘ next to the count.
    private var summaryCard: some View {
        SettingsCard(padding: 14) {
            HStack(spacing: Airi.space2) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Airi.primary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Airi.primary.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(countLine)
                            .font(Airi.emphasisFont)
                            .foregroundStyle(Airi.neutral950)
                            .monospacedDigit()
                        Button { showHowItWorks.toggle() } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(Airi.neutral400)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("How this works"))
                        .popover(isPresented: $showHowItWorks, arrowEdge: .bottom) {
                            howItWorksPopover
                        }
                    }
                    Text(subtitleLine)
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Airi.space2)
                AiriButton(title: scannedOnce ? L("Rescan") : L("Scan"),
                           icon: "arrow.clockwise", variant: .secondary,
                           busy: scanning) {
                    Task { await scan() }
                }
            }
        }
    }

    private var countLine: String {
        guard scannedOnce else { return L("Scanning launch folders…") }
        return String(format: L("%1$lld active · %2$lld disabled"),
                      activeCount, items.count - activeCount)
    }

    private var subtitleLine: String {
        var parts: [String] = [L("Turning one off unloads it now and keeps it off — reversible, nothing is deleted.")]
        if hiddenSystem > 0 {
            parts.append(String(format: L("%lld Apple system items hidden"), hiddenSystem))
        }
        return parts.joined(separator: " · ")
    }

    private var howItWorksPopover: some View {
        VStack(alignment: .leading, spacing: Airi.space2) {
            Text(L("How this works"))
                .font(Airi.cardTitleFont)
                .foregroundStyle(Airi.neutral950)
            Text(L("Each row is a launchd plist from ~/Library/LaunchAgents, /Library/LaunchAgents or /Library/LaunchDaemons. Disabling sets its Disabled flag (persistent) and unloads it right away — reversible, nothing is deleted. Global items need an administrator password. Apple system items are hidden (disabling boot daemons can wedge macOS)."))
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral700)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 330, alignment: .leading)
        .padding(14)
    }

    // MARK: - List

    private var itemsCard: some View {
        GroupedCard {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { GroupedDivider() }
                LaunchItemRow(
                    item: item,
                    isBusy: busyPath == item.path,
                    onToggle: { Task { await toggle(item) } })
            }
        }
    }

    private var scanningCard: some View {
        HStack(spacing: Airi.space2) {
            ProgressView().controlSize(.small)
            Text(L("Scanning launch folders…"))
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral500)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
            .fill(Airi.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
            .strokeBorder(Airi.neutral200.opacity(0.6), lineWidth: 1)
            .allowsHitTesting(false))
    }

    private var emptyCard: some View {
        EmptyStateCard(icon: "power",
                       title: L("No third-party launch items found"),
                       hint: L("Nothing registers itself at login right now — apps you install later will appear here."),
                       actionTitle: L("Rescan")) {
            Task { await scan() }
        }
    }

    private var footerNote: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
            Text(L("newer apps may register via System Settings → Login Items"))
                .font(Airi.caption2Font)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Airi.neutral400)
        .padding(.leading, 2)
    }

    private var outcomeList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(outcomes) { outcome in
                outcomeRow(outcome)
            }
        }
    }

    // MARK: - Actions

    private func scan() async {
        scanning = true
        (items, hiddenSystem) = await LaunchItemsEngine.scan()
        scanning = false
        scannedOnce = true
    }

    private func toggle(_ item: LaunchItemsEngine.Item) async {
        busyPath = item.path
        // Path first: same label in two scopes must flip THIS row's file.
        let outcome = await LaunchItemsEngine.setEnabled(
            item.path, enabled: item.disabled)
        outcomes.append(outcome)
        if outcomes.count > 4 { outcomes.removeFirst(outcomes.count - 4) }
        // Rescan BEFORE clearing the busy flag: the row keeps its optimistic
        // switch position until the real value lands, so the knob never
        // bounces back and forth mid-operation.
        await scan()
        busyPath = nil
    }

    private func outcomeRow(_ outcome: LaunchItemsEngine.Outcome) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: outcome.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(outcome.success ? Airi.success : Airi.danger)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(outcome.label) → \(outcome.enabled ? L("Enabled") : L("Disabled"))")
                    .font(Airi.captionFont.weight(.medium))
                    .foregroundStyle(Airi.neutral900)
                    .lineLimit(1)
                Text(outcome.message)
                    .font(Airi.monoCaption2Font)
                    .foregroundStyle(Airi.neutral500)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Airi.radiusControl, style: .continuous)
            .fill((outcome.success ? Airi.success : Airi.danger).opacity(0.10)))
    }

    // MARK: - Probe seed

    /// Synthetic-but-plausible rows for the offscreen probe only. `program`
    /// points at real bundles where possible so the row shows a real app icon
    /// (the real page is a mix of app icons and generic plist documents).
    private func seedForProbe() {
        scanning = false
        scannedOnce = true
        hiddenSystem = 6
        func make(_ label: String, _ program: String,
                  _ scope: LaunchItemsEngine.Scope,
                  disabled: Bool = false, keepAlive: Bool = true) -> LaunchItemsEngine.Item {
            LaunchItemsEngine.Item(
                label: label,
                path: scope.directory + "/" + label + ".plist",
                scope: scope,
                program: program,
                runAtLoad: true, keepAlive: keepAlive,
                disabled: disabled, loaded: !disabled)
        }
        items = [
            make("com.docker.socket",
                 "/Applications/Docker.app/Contents/MacOS/com.docker.socket",
                 .globalDaemons),
            make("com.microsoft.update.agent",
                 "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app",
                 .globalAgents, disabled: true),
            make("com.jetbrains.toolbox",
                 "/Applications/JetBrains Toolbox.app",
                 .userAgents),
            make("com.dropbox.DropboxMacOffice.agent",
                 "/Applications/Dropbox.app/Contents/MacOS/Dropbox",
                 .userAgents),
            make("com.apple.SafariHistoryServiceAgent",
                 "/System/Applications/Safari.app",
                 .userAgents),
            make("homebrew.mxcl.dnsmasq",
                 "/opt/homebrew/opt/dnsmasq/bin/dnsmasq",
                 .globalDaemons, disabled: true, keepAlive: false),
        ]
    }
}

// MARK: - Row (icon · name · switch)

/// One launch item: real app icon when the program lives inside an .app
/// bundle (plist-only items keep the document icon), name + label/path, and a
/// switch that IS the state — no hover reveal, no separate status pill.
private struct LaunchItemRow: View {
    let item: LaunchItemsEngine.Item
    let isBusy: Bool
    var onToggle: () -> Void

    /// Optimistic switch position. Without it the knob would snap back to the
    /// old value for the second or two the shell/admin prompt takes, which
    /// reads as "the click didn't register".
    @State private var optimistic: Bool?

    private var isOn: Bool { optimistic ?? !item.disabled }

    private var binding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { newValue in
                guard newValue != isOn else { return }
                optimistic = newValue
                onToggle()
            })
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: Self.icon(for: item))
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(item.disabled ? 0.75 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.displayName)
                        .font(Airi.cardTitleFont)
                        .foregroundStyle(item.disabled ? Airi.neutral700 : Airi.neutral950)
                        .lineLimit(1)
                    if item.scope.needsAdmin {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Airi.warning)
                            .help(L("Needs an administrator password to change"))
                    }
                }
                Text("\(item.label) · \(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .font(Airi.monoCaption2Font)
                    .foregroundStyle(Airi.neutral500)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Airi.space2)
            // Fixed trailing box: the spinner appears to the LEFT of the
            // switch, so the switch itself never moves while an operation runs.
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                if ProbeRendering.enabled {
                    // macOS 26 NSSwitch paints no ON fill into an offscreen
                    // layer tree — draw the stand-in so probe renders show
                    // the real enabled/disabled state.
                    ProbeSwitch(isOn: isOn, tint: Airi.primary)
                        .opacity(isBusy ? 0.5 : 1)
                        .accessibilityLabel(Text(item.displayName))
                } else {
                    Toggle("", isOn: binding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .tint(Airi.primary)
                        .disabled(isBusy)
                        .accessibilityLabel(Text(item.displayName))
                }
            }
            .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        // The row owns no surface (the GroupedCard does) — only the switch is
        // interactive, so there is no hover highlight to fake clickability.
        .help(Self.tooltip(for: item))
        // Real value landed → drop the optimistic override.
        .onChange(of: item.disabled) { _, _ in optimistic = nil }
        // Operation finished without changing the item (refused / failed) →
        // also drop it, so the knob falls back to the truth.
        .onChange(of: isBusy) { _, busy in if !busy { optimistic = nil } }
    }

    /// App icon when the program lives inside an .app bundle; the generic
    /// plist document icon otherwise.
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
