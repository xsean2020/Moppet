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
                Task { await viewModel.clean() }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            // Scope summary: the dialog must state WHAT is being cleaned, or
            // a section that was left selected by default reads as "it cleaned
            // everything I never chose".
            Text(selectionSummary + "\n" + trashNotice)
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
                    ForEach(viewModel.sections) { section in
                        sectionCard(section)
                    }
                }
                .padding(Airi.space4)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            bottomBar {
                // Scope preview: the Scan button covers exactly the ticked
                // items — make that visible so "why did it scan that?" can't
                // happen silently.
                Text(String(format: L("%1$lld of %2$lld categories selected"),
                            viewModel.selectedItems.count,
                            viewModel.sections.reduce(0) { $0 + $1.items.count }))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                    .monospacedDigit()
                Spacer()
                AiriButton(title: L("Scan"), icon: "magnifyingglass") {
                    viewModel.startScan()
                }
                .disabled(viewModel.selectedItems.isEmpty)
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
                    Image(systemName: section.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Airi.neutral500)
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
                .transition(.opacity.combined(with: .move(edge: .top)))
                .padding(.top, Airi.space1)
            }
        }
    }

    /// macOS-style tristate master check for one section: filled check =
    /// every item ticked, filled minus = SOME ticked, empty square = none.
    /// Click cycles none→all / partial→all / all→none. A plain Toggle cannot
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
                onChange(state == 2 ? false : true)
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
            case 1: L("Some items selected — click to select all")
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

    private func itemTree(_ itemState: CleanViewModel.ItemState) -> some View {
        let nodes = treeNodes(for: itemState)
        let total = itemState.result?.findings.count ?? 0
        let cap = Self.findingCap
        let isExpanded = expandedItems.contains(itemState.id)
        // Cap applied only when collapsed; expanding shows everything.
        let visibleNodes: [CleanView.TreeNode] = isExpanded || total <= cap
            ? nodes
            : nodes.map { node in
                var copy = node
                copy.children = node.children.map { Array($0.prefix(cap)) }
                return copy
            }
        return VStack(alignment: .leading, spacing: 2) {
            OutlineGroup(visibleNodes, children: \.children) { node in
                treeNodeRow(node, itemState: itemState)
            }
            if total > cap {
                Button {
                    withAnimation(Airi.controlAnimation) {
                        if isExpanded { expandedItems.remove(itemState.id) }
                        else { expandedItems.insert(itemState.id) }
                    }
                } label: {
                    Label(isExpanded ? L("Show less") : String(format: L("Show all %lld paths"), total),
                          systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.primary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 26)
                .padding(.vertical, 3)
            }
        }
    }

    /// Review-tree page size (see `itemTree` for the disclosure row).
    static let findingCap = 30

    // Tree node: item → findings (two-level OutlineGroup payload).
    struct TreeNode: Identifiable {
        let id: String
        let name: String
        let detail: String
        let bytes: Int64
        let finding: Finding?
        var children: [TreeNode]? = nil
    }

    private func treeNodes(for itemState: CleanViewModel.ItemState) -> [TreeNode] {
        guard let result = itemState.result else { return [] }
        return [
            TreeNode(
                id: "item-\(itemState.id)",
                name: itemState.item.name,
                detail: String(format: L("%1$@ · %2$lld of %3$lld paths"),
                               itemState.activeBytes.bytesFormatted,
                               itemState.activeFindings.count, result.findings.count),
                bytes: itemState.activeBytes,
                finding: nil,
                children: result.findings.map { finding in
                    TreeNode(
                        id: finding.id,
                        name: finding.lastPathComponent,
                        detail: String(format: L("%@ · %lld files"),
                                       finding.bytes.bytesFormatted, finding.fileCount),
                        bytes: finding.bytes,
                        finding: finding
                    )
                }
            )
        ]
    }

    private func treeNodeRow(_ node: TreeNode, itemState: CleanViewModel.ItemState) -> some View {
        HStack(spacing: Airi.space2) {
            if let finding = node.finding {
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
            } else {
                Image(systemName: itemState.item.mode == .trash ? "trash" : "folder")
                    .font(Airi.footnoteFont)
                    .foregroundStyle(Airi.primary.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(.system(size: node.finding == nil ? 13 : 12))
                    .foregroundStyle(Airi.neutral900)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(node.detail)
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
            }
            Spacer()
            if node.finding == nil, itemState.item.warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.warning)
                    .help(itemState.item.warning ?? "")
            }
        }
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
