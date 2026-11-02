import SwiftUI

/// One-shot hand-off from the dashboard: "Scan for cleanable items" navigates
/// to Clean and asks it to start the read-only scan immediately. A persisted
/// flag survives the route swap (the view is rebuilt after navigation).
enum CleanLaunch {
    private static let key = "clean.autoScan"

    static func requestScan() {
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Returns true at most once per request.
    static func consumeScanRequest() -> Bool {
        guard UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.set(false, forKey: key)
        return true
    }
}

/// The clean flow — mole's dry-run-first contract rendered as a native UI:
/// choose sections → scan (preview) → review findings → confirm → clean.
struct CleanView: View {
    var onClose: (() -> Void)?

    @State private var viewModel = CleanViewModel()
    @State private var showConfirmation = false
    /// Review-tree cap: findings beyond the first 30 per item are hidden
    /// until expanded — but they stay SELECTED, so the cap must be visibly
    /// disclosed (see the "show N more" row), never silent.
    @State private var expandedItems: Set<String> = []
    /// Per-item "findings visible" (the row disclosure). Kept separate from
    /// `expandedItems`, which lifts the 30-path cap once the row is open.
    @State private var openItems: Set<String> = []
    /// Running browsers that hold the caches we're about to clean — quitting
    /// them first is required for the clean to actually take effect.
    @State private var browsersToQuit: [BrowserProcesses.Browser] = []
    @State private var showBrowserPrompt = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: title, subtitle: subtitle, onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Phase swaps cross-fade instead of hard-cutting. Cheap:
                // the heavy review tree is only built in its own phase.
                .animation(Airi.entranceCurve, value: viewModel.phase)
        }
        .background(Airi.pageBackground.opacity(0.001))
        .confirmationDialog(
            Text(String(format: L("Remove %lld items (%@)?"),
                        viewModel.reviewCount, viewModel.reviewBytes.bytesFormatted)),
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("Clean"), role: .destructive) {
                // A running browser keeps rewriting / locking its cache, so a
                // clean would be incomplete. Ask before quitting it.
                let itemIDs = Set(viewModel.selectedFindings.map(\.itemID))
                let running = BrowserProcesses.running(for: itemIDs)
                if running.isEmpty {
                    Task { await viewModel.clean() }
                } else {
                    browsersToQuit = running
                    // Let the confirm dialog dismiss before the alert presents.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showBrowserPrompt = true
                    }
                }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            // Scope summary: the dialog must state WHAT is being cleaned, or
            // a section that was left selected by default reads as "it cleaned
            // everything I never chose".
            Text(selectionSummary + "\n" + trashNotice)
        }
        .alert(
            Text(String(format: L("Quit %@ first?"),
                        browsersToQuit.map(\.name).joined(separator: ", "))),
            isPresented: $showBrowserPrompt
        ) {
            Button(L("Quit & Clean"), role: .destructive) {
                let browsers = browsersToQuit
                Task {
                    await BrowserProcesses.quit(browsers)
                    await viewModel.clean()
                }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Browser caches can only be cleared while the browser is closed — a running browser keeps rewriting them. Unsaved tabs/forms may be lost (most browsers restore tabs on relaunch)."))
        }
        .onAppear {
            // Offscreen probe hook (`--probe-clean-render … expanded`): opens
            // the first section so the expanded row body is inspectable.
            if Self.debugExpandFirstSection, let first = viewModel.sections.first {
                first.expanded = true
            }
            // Dashboard CTA: start the same scan the page's Scan button runs,
            // but only when there is a selection to measure.
            guard CleanLaunch.consumeScanRequest(),
                  !viewModel.selectedItems.isEmpty else { return }
            viewModel.startScan()
        }
        .onChange(of: viewModel.phase) { _, phase in
            if phase == .done { UXFeedback.success() }
        }
    }

    private var title: String {
        switch viewModel.phase {
        case .configure, .scanning: L("Cache Clean")
        case .review: L("Review")
        case .cleaning: L("Cleaning")
        case .done: L("Done")
        }
    }

    private var subtitle: String {
        switch viewModel.phase {
        case .configure: L("Pick what to look for — nothing is deleted before you confirm")
        case .scanning: L("Measuring candidates — read-only pass")
        case .review: L("Deselect anything you want to keep, then clean")
        case .cleaning: L("Removing selected items")
        case .done: L("Summary of this run")
        }
    }

    /// Section names covered by the pending clean — the user-visible answer
    /// to "what exactly will this remove?".
    private var selectionSummary: String {
        String(format: L("Cleaning scope: %@"), viewModel.reviewSections
            .map(\.section.title).joined(separator: ", "))
    }

    /// Ids whose findings are moved to the Trash rather than unlinked.
    /// Computed once: the notice used to flatten the ENTIRE rule library
    /// (every section × every item) for every finding on every body pass,
    /// and short-circuiting `contains` is enough — the sentence only needs
    /// to know whether ANY of the selected findings is a Trash-mode item.
    private static let trashItemIDs: Set<String> = Set(
        RuleLibrary.sections.flatMap(\.items).filter { $0.mode == .trash }.map(\.id))

    private var trashNotice: String {
        let hasTrashItem = viewModel.selectedFindings.contains {
            Self.trashItemIDs.contains($0.itemID)
        }
        return hasTrashItem
            ? L("Installers and archives go to the Trash (recoverable); caches and logs are removed permanently.")
            : L("Caches and logs are removed permanently. This cannot be undone.")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .configure: configurePhase
        case .scanning: scanningPhase
        case .review: reviewPhase
        case .cleaning: cleaningPhase
        case .done: donePhase
        }
    }

    // MARK: - Configure

    private var configurePhase: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Airi.space3) {
                    if !Permissions.hasFullDiskAccess {
                        fdaBanner
                    }
                    scopeSummaryCard
                    sectionGroupCard
                    // One quiet reassurance line under the list — it fills the
                    // dead space a short page always had and repeats the
                    // page's contract where the eye lands after scanning rows.
                    Text(L("Read-only scan — files are removed only after you confirm"))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral400)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                .padding(.horizontal, Airi.space4)
                .padding(.top, Airi.space3)
                .padding(.bottom, Airi.space4)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            configureBar
        }
    }

    // MARK: Configure — coverage summary

    /// Coverage summary: the page's single focal point. Four identical slabs
    /// gave the eye nowhere to start and left the counts/checks stranded at
    /// the far right edge of a mostly empty row; a ring + rule count + the two
    /// bulk actions answers "what will Scan cover" before any scrolling.
    private var scopeSummaryCard: some View {
        let totalRules = viewModel.sections.reduce(0) { $0 + $1.items.count }
        let pickedRules = viewModel.selectedItems.count
        let pickedSections = viewModel.sections.filter { $0.items.contains(where: \.selected) }.count
        let fraction = totalRules > 0 ? Double(pickedRules) / Double(totalRules) : 0
        return SettingsCard(padding: 14) {
            HStack(spacing: Airi.space3) {
                ProgressRing(progress: fraction,
                             lineWidth: 4,
                             showValue: true,
                             valueText: "\(Int((fraction * 100).rounded()))%",
                             valueFontSize: 10)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("%1$lld of %2$lld rules selected"),
                                pickedRules, totalRules))
                        .font(Airi.emphasisFont)
                        .foregroundStyle(Airi.neutral950)
                        .monospacedDigit()
                    Text(String(format: L("%1$lld of %2$lld categories selected"),
                                pickedSections, viewModel.sections.count))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                        .monospacedDigit()
                }
                Spacer(minLength: Airi.space2)
                // Global select-all / clear-all — the section tri-state only
                // acted on one section, so "scan everything" needed N taps.
                bulkChip(L("Select all"), tint: Airi.primary) { viewModel.selectAll() }
                bulkChip(L("Deselect all"), tint: Airi.neutral500) { viewModel.deselectAll() }
            }
        }
    }

    private func bulkChip(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Airi.captionFont.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Airi.neutral100.opacity(0.9)))
                .overlay(Capsule().strokeBorder(Airi.neutral200.opacity(0.8), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    // MARK: Configure — grouped section list

    /// All sections in ONE grouped card with hairline seams (System Settings
    /// style). Separate cards read as four unrelated slabs, each with a wide
    /// empty middle; a single list makes the group a unit and lets the row
    /// controls sit right after the copy instead of at the window edge.
    private var sectionGroupCard: some View {
        GroupedCard {
            ForEach(Array(viewModel.sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 { GroupedDivider() }
                sectionRow(section)
            }
        }
    }

    /// One section row: icon chip · title/subtitle · count pill · tri-state
    /// check · disclosure. Order runs left→right from "what is this" to "is it
    /// in scope" to "open it" — the old chevron-then-count-then-check order
    /// read backwards and floated the chevron in empty space.
    private func sectionRow(_ section: CleanViewModel.SectionState) -> some View {
        let ticked = section.items.filter(\.selected).count
        let total = section.items.count
        return VStack(spacing: 0) {
            HStack(spacing: Airi.space2) {
                Button {
                    withAnimation(Airi.controlAnimation) { section.expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.section.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Airi.primary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Airi.primary.opacity(0.12))
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.section.title)
                                .font(Airi.cardTitleFont)
                                .foregroundStyle(Airi.neutral950)
                                .lineLimit(1)
                            Text(section.section.subtitle)
                                .font(Airi.captionFont)
                                .foregroundStyle(Airi.neutral500)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: Airi.space2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("\(ticked)/\(total)")
                    .font(Airi.caption2Font.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(ticked == 0 ? Airi.neutral500 : Airi.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Airi.neutral100.opacity(0.9)))
                    .overlay(Capsule().strokeBorder(Airi.neutral200.opacity(0.7), lineWidth: 1))

                SectionTriState(section: section) { section.selected = $0 }

                Button {
                    withAnimation(Airi.controlAnimation) { section.expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Airi.neutral400)
                        // Rotate instead of swapping up/down — the glyph swap
                        // was abrupt; rotation animates with the same spring.
                        .rotationEffect(.degrees(section.expanded ? 180 : 0))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if section.expanded {
                VStack(spacing: 2) {
                    ForEach(section.items) { itemState in
                        itemRow(itemState)
                    }
                }
                .padding(8)
                // Inset panel: the expanded rules read as a sub-list of THIS
                // section instead of floating loose between two hairlines.
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Airi.neutral50.opacity(0.35))
                )
                .padding(.leading, 52)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
                // Fade only. The card clips its rows (Components.GroupedCard),
                // so the panel is revealed by the card's own height animation;
                // the extra `.scale(anchor: .top)` fought that clip and made the
                // panel look like it slid out ahead of the card.
                .transition(.opacity)
            }
        }
    }

    /// One rule inside an expanded section. A checkbox, not a switch: this is
    /// a multi-select list (switches read as settings that apply immediately),
    /// and it matches the review page's per-path checkboxes.
    private func itemRow(_ itemState: CleanViewModel.ItemState) -> some View {
        HStack(spacing: Airi.space2) {
            Toggle("", isOn: Binding(
                get: { itemState.selected },
                set: { itemState.selected = $0 }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(itemState.item.name)
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral900)
                    .lineLimit(1)
                Text(itemState.item.detail)
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Airi.space2)
            if let warning = itemState.item.warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.warning)
                    .help(warning)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // Out-of-scope rules recede instead of looking equally armed — but
        // stay legible: below ~0.7 the 10pt detail line disappears entirely.
        .opacity(itemState.selected ? 1 : 0.7)
        .animation(Airi.hoverAnimation, value: itemState.selected)
    }

    // MARK: Configure — action bar

    /// Scope chips on the left (what Scan covers), one primary action on the
    /// right. The bulk actions moved up into the summary card so this bar
    /// holds exactly one decision.
    private var configureBar: some View {
        HStack(spacing: Airi.space2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(viewModel.sections.filter { $0.items.contains(where: \.selected) }) { section in
                        HStack(spacing: 4) {
                            Image(systemName: section.section.icon)
                                .font(.system(size: 9, weight: .medium))
                            Text(String(format: L("%1$@ (%2$lld/%3$lld)"),
                                        section.section.title,
                                        section.items.filter(\.selected).count,
                                        section.items.count))
                                .font(Airi.caption2Font)
                                .lineLimit(1)
                        }
                        .foregroundStyle(Airi.neutral700)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Airi.neutral100.opacity(0.8)))
                        .overlay(Capsule().strokeBorder(Airi.neutral200.opacity(0.7), lineWidth: 1))
                    }
                }
                .padding(.vertical, 1)
            }
            Spacer(minLength: Airi.space2)
            AiriButton(title: scanButtonTitle, icon: "magnifyingglass") {
                viewModel.startScan()
            }
            .disabled(viewModel.selectedItems.isEmpty)
        }
        .padding(.horizontal, Airi.space4)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(Airi.neutral200.opacity(0.5)) }
    }

    /// Count in the action label: "Scan 12 rules" tells the user the scope of
    /// the click without reading the chips first.
    private var scanButtonTitle: String {
        let count = viewModel.selectedItems.count
        return count == 0 ? L("Scan") : String(format: L("Scan %lld rules"), count)
    }

    /// Full Disk Access guidance (gap-analysis P0): without FDA the TCC-
    /// protected trees are invisible, so scans "look empty" and users read
    /// the app as broken. One card at the top, one click into Settings.
    private var fdaBanner: some View {
        SettingsCard(padding: Airi.space3) {
            HStack(spacing: Airi.space3) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18))
                    .foregroundStyle(Airi.warning)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: Airi.radiusControl).fill(Airi.neutral100))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Full Disk Access is off"))
                        .font(Airi.cardTitleFont)
                        .foregroundStyle(Airi.neutral950)
                    Text(L("Some locations (Mail, Messages, Safari data) can't be scanned without it — the scan may look emptier than reality."))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
                Spacer()
                AiriButton(title: L("Open Settings"), icon: "arrow.up.right.square") {
                    Task { @MainActor in Permissions.openFullDiskAccessSettings() }
                }
            }
        }
    }

    /// macOS-style tristate master check for one section: filled check =
    /// every item ticked, filled minus = SOME ticked, empty square = none.
    /// Click: empty → select all; partial/full → clear. A plain Toggle cannot
    /// render the mixed state, which misread partially-ticked sections as off.
    private struct SectionTriState: View {
        let section: CleanViewModel.SectionState
        let onChange: (Bool) -> Void

        @State private var hovering = false

        private var ticked: Int { section.items.filter(\.selected).count }
        private var state: Int {   // 0 none · 1 partial · 2 all
            ticked == 0 ? 0 : (ticked == section.items.count ? 2 : 1)
        }

        var body: some View {
            Button {
                // Empty → select all; partial/full → clear (partial → clear is
                // the safe direction: don't WIDEN the deletion scope by one
                // stray click). The condition used to be `state != 0`, which
                // made empty AND full sections both no-ops — clicking the
                // checkbox appeared completely dead.
                onChange(state == 0)
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state == 0 ? Airi.neutral400 : Airi.primary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(state == 0 ? Color.clear
                                  : hovering ? Airi.primary.opacity(0.22)
                                  : Airi.primary.opacity(0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(state == 0 ? Airi.neutral200 : Color.clear,
                                          lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .scaleEffect(hovering ? 1.08 : 1)
            .animation(Airi.hoverAnimation, value: hovering)
            .animation(Airi.hoverAnimation, value: state)
            .onHover { hovering = $0 }
            .help(sectionHint)
            .accessibilityLabel(Text(sectionHint))
        }

        private var symbol: String {
            switch state {
            case 2: "checkmark.square.fill"
            case 1: "minus.square.fill"
            default: "checkmark.square"
            }
        }

        private var sectionHint: String {
            switch state {
            case 2: L("All items selected — click to clear")
            case 1: L("Some items selected — click to clear the section")
            default: L("No items selected — click to select all")
            }
        }
    }

    // MARK: - Scanning

    private var scanningPhase: some View {
        VStack(spacing: Airi.space3) {
            Spacer()
            ProgressRing(
                progress: viewModel.totalItems > 0
                    ? Double(viewModel.completedItems) / Double(viewModel.totalItems) : 0,
                lineWidth: 10,
                showValue: true,
                valueText: "\(Int(Double(viewModel.completedItems) / Double(max(viewModel.totalItems, 1)) * 100))%"
            )
            .frame(width: 84, height: 84)
            Text(viewModel.progressMessage.isEmpty ? L("Scanning…") : viewModel.progressMessage)
                .font(.system(size: 14))
                .foregroundStyle(Airi.neutral700)
            HStack(spacing: 4) {
                TickingNumber(value: viewModel.completedItems)
                    .foregroundStyle(Airi.neutral900)
                Text("/ \(viewModel.totalItems) \(L("locations"))")
            }
            .font(Airi.captionFont)
            .foregroundStyle(Airi.neutral500)
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: viewModel.completedItems)
            AiriButton(title: L("Cancel"), icon: "xmark", variant: .secondary) {
                viewModel.cancelScan()
            }
            .padding(.top, Airi.space2)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Review

    private var reviewPhase: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Airi.space3) {
                    if viewModel.reviewSections.isEmpty {
                        EmptyStateCard(icon: "sparkles",
                                       title: L("Nothing to clean"),
                                       hint: L("The scan found no reclaimable space in the selected sections."),
                                       actionTitle: L("Adjust selection")) { viewModel.reset() }
                            .padding(.top, Airi.space4)
                    } else {
                        totalBanner
                        ForEach(viewModel.reviewSections) { section in
                            reviewSection(section)
                        }
                    }
                }
                .padding(Airi.space4)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            bottomBar {
                AiriButton(title: L("Rescan"), icon: "arrow.clockwise", variant: .secondary) {
                    expandedItems = []
                    openItems = []
                    viewModel.startScan()
                }
                AiriButton(title: String(format: L("Clean %@"), viewModel.reviewBytes.bytesFormatted),
                           icon: "trash",
                           variant: .destructive) {
                    showConfirmation = true
                }
                .disabled(viewModel.reviewCount == 0)
            }
        }
    }

    private var totalBanner: some View {
        SettingsCard(padding: Airi.space4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("%lld paths · %@"),
                                viewModel.reviewCount, viewModel.reviewBytes.bytesFormatted))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Airi.neutral950)
                    Text(trashNotice)
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
                Spacer()
                Image(systemName: "trash")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Airi.danger.opacity(0.7))
            }
        }
    }

    /// Review tree: OutlineGroup over item → findings, with per-finding
    /// checkboxes (unchecking keeps that path).
    private func reviewSection(_ section: CleanViewModel.SectionState) -> some View {
        let activePaths = section.items.filter(\.selected)
            .reduce(0) { $0 + $1.activeFindings.count }
        return SettingsCard {
            HStack(spacing: Airi.space3) {
                Image(systemName: section.section.icon)
                    .font(.system(size: 16, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Airi.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.section.title).font(Airi.cardTitleFont).foregroundStyle(Airi.neutral950)
                    // Counts must read off the selected items' active
                    // findings — `section.selected` is an allSatisfy, so a
                    // partially-selected section would otherwise label its
                    // listed paths "0 paths" (looks broken, invites
                    // toggle-mashing to "fix" it).
                    Text(String(format: L("%@ across %lld paths"),
                                section.scannedBytes.bytesFormatted, activePaths))
                        .font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                }
                Spacer()
                // No section-level toggle on the review page: switching a
                // section off here removed its card entirely (reviewSections
                // filters on `selected`) with no way to re-include short of
                // restarting the flow — a mis-tap silently shrank the clean.
            }

            ForEach(section.items.filter { $0.selected && $0.findingCount > 0 }) { itemState in
                itemTree(itemState)
            }
        }
    }

    /// One item's review subtree. A big, fully-clickable header row toggles
    /// the findings; a full-width "Show all N paths" lifts the 30-path cap.
    /// Replaces the old OutlineGroup, where the parent could stay collapsed
    /// while a tiny 10pt "Show all" did nothing visible and was hard to hit.
    private func itemTree(_ itemState: CleanViewModel.ItemState) -> some View {
        let findings = itemState.result?.findings ?? []
        let total = findings.count
        let cap = Self.findingCap
        let isOpen = openItems.contains(itemState.id)
        let showAll = expandedItems.contains(itemState.id)
        let visible = showAll ? findings : Array(findings.prefix(cap))
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(Airi.controlAnimation) {
                    if isOpen { openItems.remove(itemState.id) }
                    else { openItems.insert(itemState.id) }
                }
            } label: {
                HStack(spacing: Airi.space2) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Airi.neutral500)
                        .frame(width: 14)
                    Image(systemName: itemState.item.mode == .trash ? "trash" : "folder")
                        .font(Airi.footnoteFont)
                        .foregroundStyle(Airi.primary.opacity(0.7))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(itemState.item.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Airi.neutral900)
                            .lineLimit(1)
                        Text(String(format: L("%1$@ · %2$lld of %3$lld paths"),
                                    itemState.activeBytes.bytesFormatted,
                                    itemState.activeFindings.count, total))
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral500)
                    }
                    Spacer()
                    if itemState.item.warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.warning)
                            .help(itemState.item.warning ?? "")
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())   // whole row is the hit target
            }
            .buttonStyle(.plain)

            if isOpen {
                // Bulk include/exclude for THIS item's findings — the last
                // chance to decide exactly which paths get deleted.
                HStack(spacing: 12) {
                    Button(L("Select all")) {
                        withAnimation(Airi.controlAnimation) {
                            itemState.excludedFindings.removeAll()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Airi.caption2Font.weight(.medium))
                    .foregroundStyle(Airi.primary)
                    Button(L("Deselect all")) {
                        withAnimation(Airi.controlAnimation) {
                            itemState.excludedFindings = Set(findings.map(\.id))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
                    Spacer()
                    Text("\(itemState.activeFindings.count)/\(total)")
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral500)
                        .monospacedDigit()
                }
                .padding(.leading, 22)
                .padding(.vertical, 3)
                ForEach(visible) { finding in
                    findingRow(finding, itemState: itemState)
                }
                if total > cap {
                    Button {
                        withAnimation(Airi.controlAnimation) {
                            if showAll { expandedItems.remove(itemState.id) }
                            else { expandedItems.insert(itemState.id) }
                        }
                    } label: {
                        Label(showAll ? L("Show less") : String(format: L("Show all %lld paths"), total),
                              systemImage: showAll ? "chevron.up" : "chevron.down")
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.primary)
                            // Full-width, padded hit target (was a 10pt label).
                            .padding(.vertical, 7)
                            .padding(.leading, 22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Review-tree page size (see `itemTree` for the disclosure row).
    static let findingCap = 30

    /// Offscreen render probe (`--probe-clean-render … expanded`): start with
    /// the first section open so the row-body layout can be inspected.
    static var debugExpandFirstSection = false

    /// One finding row: include/exclude checkbox + name + size.
    private func findingRow(_ finding: Finding, itemState: CleanViewModel.ItemState) -> some View {
        HStack(spacing: Airi.space2) {
            Toggle("", isOn: Binding(
                get: { !itemState.excludedFindings.contains(finding.id) },
                set: { include in
                    if include {
                        itemState.excludedFindings.remove(finding.id)
                    } else {
                        itemState.excludedFindings.insert(finding.id)
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .labelsHidden()
            Image(systemName: "doc")
                .font(Airi.caption2Font)
                .foregroundStyle(Airi.neutral400)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(Airi.neutral900)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(format: L("%@ · %lld files"),
                            finding.bytes.bytesFormatted, finding.fileCount))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
            }
            Spacer()
        }
        .padding(.leading, 22)
        .padding(.vertical, 1)
    }

    // MARK: - Cleaning

    private var cleaningPhase: some View {
        VStack(spacing: Airi.space3) {
            Spacer()
            ProgressRing(
                progress: Double(viewModel.cleanProgressDone) / Double(max(viewModel.cleanProgressTotal, 1)),
                lineWidth: 10,
                tint: Airi.danger,
                showValue: true,
                valueText: "\(Int(Double(viewModel.cleanProgressDone) / Double(max(viewModel.cleanProgressTotal, 1)) * 100))%"
            )
            .frame(width: 84, height: 84)
            HStack(spacing: 4) {
                TickingNumber(value: viewModel.cleanProgressDone)
                    .foregroundStyle(Airi.neutral900)
                Text("/ \(viewModel.cleanProgressTotal)")
            }
            .font(.system(size: 14))
            .foregroundStyle(Airi.neutral700)
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: viewModel.cleanProgressDone)
            Text(L("Trash-routed items are recoverable from the Trash"))
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral500)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Done

    private var donePhase: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Airi.space3) {
                    SettingsCard(padding: Airi.space4) {
                        VStack(alignment: .leading, spacing: Airi.space2) {
                            HStack(spacing: Airi.space2) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Airi.success)
                                Text(String(format: L("Freed %@"), viewModel.freedBytes.bytesFormatted))
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Airi.neutral950)
                            }
                            Text(String(format: L("%lld items processed · %lld failed"),
                                        viewModel.outcomes.count, viewModel.failureCount))
                                .font(Airi.captionFont)
                                .foregroundStyle(Airi.neutral500)
                            if viewModel.failureCount > 0 {
                                let failures = viewModel.outcomes.filter { !$0.success }.prefix(8)
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                                        FindingRow(name: (failure.path as NSString).lastPathComponent,
                                                   detail: failure.error ?? L("failed"))
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                    if let record = viewModel.lastRecord {
                        SettingsCard {
                            Text(String(format: L("Recorded to history — %lld audited paths"),
                                        record.itemCount))
                                .font(Airi.captionFont)
                                .foregroundStyle(Airi.neutral500)
                        }
                    }
                }
                .padding(Airi.space4)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            bottomBar {
                AiriButton(title: L("Back to start"), icon: "arrow.counterclockwise",
                           variant: .secondary) { viewModel.reset() }
                AiriButton(title: L("Done"), icon: "checkmark") { onClose?() }
            }
        }
    }

    // MARK: - Bottom bar

    private func bottomBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Airi.space2) {
            Spacer()
            content()
        }
        .padding(Airi.space4)
        // Glass, not a solid neutral100 slab — the bar sits on the vibrancy
        // window and a hard fill broke the frosted-card language.
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(Airi.neutral200.opacity(0.5)) }
    }
}
