import SwiftUI

/// Clean-run audit trail — SwiftUI cousin of `mo history`.
/// Every record expands to the exact paths removed, their size, whether they
/// went to Trash or were permanently removed, and any per-path errors.
struct HistoryView: View {
    var onClose: (() -> Void)?

    @State private var records: [CleanRecord] = []
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("History"), subtitle: L("Audit log of every clean run"), onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            ScrollView {
                VStack(spacing: Airi.space3) {
                    if records.isEmpty {
                        EmptyStateCard(icon: "clock.arrow.circlepath",
                                       title: L("No runs recorded yet"),
                                       hint: L("Your first clean will show up here — every removed path is audited."),
                                       actionTitle: L("Start a clean")) {
                    // Was an empty closure — a dead button on the empty state.
                    WindowRouter.shared.showMain()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NotificationCenter.default.post(name: .moppetNavigateClean, object: nil)
                    }
                }
                    }
                    ForEach(records.reversed()) { record in
                        recordCard(record)
                    }
                }
                .padding(Airi.space4)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: Airi.space2) {
                Text("\(records.count) \(L("runs")) · \(totalFreed.bytesFormatted) \(L("freed in total"))")
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                Spacer()
                AiriButton(title: L("Reload"), icon: "arrow.clockwise", variant: .secondary) {
                    records = HistoryStore.load()
                    expanded = []
                }
                if !records.isEmpty {
                    AiriButton(title: L("Clear"), icon: "trash", variant: .destructive) {
                        confirmingClear = true
                    }
                }
            }
            .padding(Airi.space4)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider().overlay(Airi.neutral200.opacity(0.5)) }
        }
        .background(Airi.pageBackground.opacity(0.001))
        .confirmationDialog(
            Text(L("Clear all history?")),
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button(L("Clear"), role: .destructive) {
                HistoryStore.clear()
                records = []
                expanded = []
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(String(format: L("All %lld run records are erased. This cannot be undone."),
                        records.count))
        }
        .onAppear { records = HistoryStore.load() }
    }

    @State private var confirmingClear = false

    private var totalFreed: Int64 {
        records.reduce(0) { $0 + $1.freedBytes }
    }

    // MARK: - Record card

    private func recordCard(_ record: CleanRecord) -> some View {
        let isExpanded = expanded.contains(record.id)
        let failedCount = record.items.filter { !$0.success }.count
        return SettingsCard {
            VStack(spacing: 0) {
                Button {
                    withAnimation(Airi.entranceCurve) {
                        if isExpanded { expanded.remove(record.id) } else { expanded.insert(record.id) }
                    }
                } label: {
                    HStack(spacing: Airi.space3) {
                        Image(systemName: Self.icon(for: record.sectionTitles))
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(Airi.primary)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: Airi.radiusControl).fill(Airi.neutral100))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                .font(Airi.cardTitleFont)
                                .foregroundStyle(Airi.neutral950)
                            HStack(spacing: 6) {
                                Text(record.sectionTitles.joined(separator: " · "))
                                    .font(Airi.captionFont)
                                    .foregroundStyle(Airi.neutral500)
                                    .lineLimit(1)
                                if failedCount > 0 {
                                    Text(String(format: L("%lld failed"), failedCount))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Airi.danger)
                                }
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("+\(record.freedBytes.bytesFormatted)")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Airi.success)
                                .monospacedDigit()
                            Text("\(record.itemCount) \(L("paths"))")
                                .font(Airi.caption2Font)
                                .foregroundStyle(Airi.neutral500)
                                .monospacedDigit()
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Airi.neutral400)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .buttonStyle(.plain)
                if isExpanded {
                    Divider().overlay(Airi.neutral200.opacity(0.5))
                        .padding(.vertical, Airi.space2)
                    VStack(alignment: .leading, spacing: Airi.space2) {
                        Text(L("Deleted items"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Airi.neutral400)
                            .textCase(.uppercase)
                        ForEach(Array(record.items.enumerated()), id: \.offset) { _, item in
                            itemRow(item)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Item row

    private func itemRow(_ item: CleanRecordItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Airi.space2) {
            Image(systemName: item.success ? "checkmark.circle" : "xmark.circle")
                .font(Airi.footnoteFont)
                .foregroundStyle(item.success ? Airi.success : Airi.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.abbreviate(item.path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Airi.neutral700)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
                if let error = item.error, !item.success {
                    Text(error)
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.danger)
                }
            }
            Spacer(minLength: Airi.space2)
            modeChip(item.mode)
            Text(item.bytes > 0 ? item.bytes.bytesFormatted : "—")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Airi.neutral500)
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
        }
    }

    private func modeChip(_ mode: DeletionMode) -> some View {
        Text(mode == .trash ? L("Trash") : L("Permanent"))
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(mode == .trash ? Airi.neutral100 : Airi.warning.opacity(0.15)))
            .foregroundStyle(mode == .trash ? Airi.neutral500 : Airi.warning)
    }

    // MARK: - Helpers

    /// Record icon by operation type (first section title decides).
    private static func icon(for sectionTitles: [String]) -> String {
        let key = sectionTitles.first ?? ""
        if key.contains("AI") { return "brain" }
        if key.contains("Uninstall") { return "app.badge.minus" }
        if key.contains("Analyze") { return "magnifyingglass" }
        if key.contains("Purge") { return "flame" }
        return "sparkles"
    }

    /// `/Users/sean/Library/...` → `~/Library/...` so rows stay readable.
    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
