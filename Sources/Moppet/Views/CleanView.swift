import SwiftUI

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
        .onChange(of: viewModel.phase) { _, phase in
            if phase == .done { UXFeedback.success() }
        }
    }

    private var title: String {
        switch viewModel.phase {
        case .configure, .scanning: L("Clean")
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

    private var trashNotice: String {
        let trashCount = viewModel.selectedFindings.filter { finding in
            RuleLibrary.sections.flatMap(\.items)
                .first(where: { $0.id == finding.itemID })?.mode == .trash
        }.count
        return trashCount > 0
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
                    ForEach(viewModel.sections) { section in
                        sectionCard(section)
                    }
                }
                .padding(Airi.space4)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            bottomBar {
                // Scope preview: named chips of every section that has ticked
                // items, so "what will Scan cover" is on screen BEFORE the
                // click — the "selected installers, browsers got scanned"
                // report came from invisible scope.
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
                }
                Text(String(format: L("%1$lld of %2$lld categories selected"),
                            viewModel.selectedItems.count,
                            viewModel.sections.reduce(0) { $0 + $1.items.count }))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                    .monospacedDigit()
                // Global select-all / clear-all — the section tri-state only
                // acted on one section, so "scan everything" needed N taps.
                Button(L("Select all")) { viewModel.selectAll() }
                    .buttonStyle(.plain)
                    .font(Airi.captionFont.weight(.medium))
                    .foregroundStyle(Airi.primary)
                    .accessibilityLabel(Text(L("Select all")))
                Button(L("Deselect all")) { viewModel.deselectAll() }
                    .buttonStyle(.plain)
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                    .accessibilityLabel(Text(L("Deselect all")))
                Spacer()
                AiriButton(title: L("Scan"), icon: "magnifyingglass") {
                    viewModel.startScan()
                }
                .disabled(viewModel.selectedItems.isEmpty)
            }
        }
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

    private func sectionCard(_ section: CleanViewModel.SectionState) -> some View {
        SettingsCard {
            HStack(spacing: Airi.space3) {
                Image(systemName: section.section.icon)
                    .font(.system(size: 18, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Airi.primary)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: Airi.radiusControl).fill(Airi.neutral100))
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.section.title).font(Airi.cardTitleFont).foregroundStyle(Airi.neutral950)
                    Text(section.section.subtitle).font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                }
                Spacer()
                Button {
                    withAnimation(Airi.controlAnimation) { section.expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Airi.neutral500)
                        // Rotate instead of swapping up/down — the glyph swap
                        // was abrupt; rotation animates with the same spring.
                        .rotationEffect(.degrees(section.expanded ? 180 : 0))
                        // A 10pt glyph was a 10pt hit target — "insensitive"
                        // on macOS 26. Pad it to a comfortable square.
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Counts + tristate master check: a partially-ticked section
                // used to render its Toggle as OFF (allSatisfy), so "Browsers
                // off + Installers on" scanned the browsers anyway.
                Text(String(format: L("%1$lld / %2$lld"),
                            section.items.filter(\.selected).count,
                            section.items.count))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
                    .monospacedDigit()
                SectionTriState(section: section) { newValue in
                    section.selected = newValue
                }
            }

            if section.expanded {
                VStack(spacing: Airi.space2) {
                    ForEach(section.items) { itemState in
                        let binding = Binding(
                            get: { itemState.selected },
                            set: { itemState.selected = $0 }
                        )
                        ToggleRow(
                            title: itemState.item.name,
                            subtitle: itemState.item.detail,
                            isOn: binding
                        )
                        .padding(.horizontal, Airi.space1)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Airi.radiusControl)
                                .fill(Airi.neutral50.opacity(0.6))
                        )
                        if itemState.item.warning != nil {
                            Text(itemState.item.warning!)
                                .font(Airi.caption2Font)
                                .foregroundStyle(Airi.warning)
                                .padding(.leading, Airi.space1)
                        }
                    }
                }
                .padding(.top, Airi.space1)
                // Fade + a subtle top-anchored scale. The old
                // `.move(edge: .top)` slid the body in from ABOVE its slot, so
                // it overlapped the header while the card height sprang —
                // that was the "broken" expand animation.
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
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
                .frame(maxWidth: 680)
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
                .frame(maxWidth: 680)
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
