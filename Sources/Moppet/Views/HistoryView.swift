import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                if !records.isEmpty {
                    AiriButton(title: L("Export CSV"), icon: "square.and.arrow.up", variant: .secondary) {
                        export(.csv)
                    }
                    AiriButton(title: L("Export JSON"), icon: "square.and.arrow.up", variant: .secondary) {
                        export(.json)
                    }
                    AiriButton(title: L("Export PDF"), icon: "square.and.arrow.up", variant: .secondary) {
                        exportPDF()
                    }
                }
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
                        let source = Self.resolvedSource(record)
                        Image(systemName: source.icon)
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(Airi.primary)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: Airi.radiusControl).fill(Airi.neutral100))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                // Which menu produced this run — the question
                                // an audit log has to answer first.
                                Text(source.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Airi.primary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Airi.primary.opacity(0.12)))
                                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(Airi.captionFont)
                                    .foregroundStyle(Airi.neutral500)
                                    .monospacedDigit()
                            }
                            HStack(spacing: 6) {
                                Text(record.sectionTitles.joined(separator: " · "))
                                    .font(Airi.cardTitleFont)
                                    .foregroundStyle(Airi.neutral900)
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
                    // Whole-row hit target. The Spacer in the middle is empty
                    // space (not hit-testable), so previously only the text or
                    // chevron responded — "you had to click precisely".
                    .contentShape(Rectangle())
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

    // MARK: - Export (gap-analysis P0: dry-run / audit report export)

    private enum ExportFormat {
        case csv, json
        var fileExtension: String { self == .csv ? "csv" : "json" }
        var prompt: String { self == .csv ? L("Export history as CSV") : L("Export history as JSON") }
    }

    /// Save-panel driven export. Written on the main actor (NSSavePanel is
    /// AppKit UI); file IO is a single atomic write.
    @MainActor
    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.title = format.prompt
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = "moppet-history-\(Date().formatted(.iso8601.year().month().day())).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch format {
            case .csv:
                try HistoryStore.csvExport(records: records)
                    .write(to: url, atomically: true, encoding: .utf8)
            case .json:
                try HistoryStore.jsonExport(records: records).write(to: url, options: .atomic)
            }
        } catch {
            // Export failure must be visible, not silent — the audit log is
            // the app's evidence trail.
            let alert = NSAlert()
            alert.messageText = L("Export failed")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// PDF report: a readable audit document (runs + per-path rows) printed
    /// straight to a chosen file via NSPrintOperation's .save disposition.
    @MainActor
    private func exportPDF() {
        let panel = NSSavePanel()
        panel.title = L("Export history as PDF")
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "moppet-history-\(Date().formatted(.iso8601.year().month().day())).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let report = Self.buildPDFReport(records)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 840))
        textView.string = report
        textView.font = NSFont.userFixedPitchFont(ofSize: 9)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.sizeToFit()

        let printInfo = NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        printInfo.topMargin = 36; printInfo.bottomMargin = 36
        printInfo.leftMargin = 36; printInfo.rightMargin = 36

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
    }

    /// Plain-text audit report — one section per run, one line per path.
    /// (Non-actor: pure string building, shared with future doc exports.)
    static func buildPDFReport(_ records: [CleanRecord]) -> String {
        var lines: [String] = []
        let title = L("Moppet — Clean History Export")
        lines.append(title)
        lines.append(String(format: L("Exported %@ · %lld runs"),
                            ISO8601DateFormatter().string(from: Date()), Int64(records.count)))
        lines.append(String(repeating: "=", count: 64))
        let formatter = ISO8601DateFormatter()
        for record in records.reversed() {
            let source = (record.source?.rawValue ?? resolvedSource(record).rawValue)
            lines.append("")
            lines.append("\(formatter.string(from: record.date)) · \(source) · \(record.sectionTitles.joined(separator: ", "))")
            lines.append(String(format: L("Freed %@ in %lld paths"),
                                record.freedBytes.bytesFormatted, Int64(record.itemCount)))
            for item in record.items {
                let mark = item.success ? "✓" : "✗"
                let mode = item.mode == .trash ? L("Trash") : L("Permanent")
                let error = item.error.map { " — \($0)" } ?? ""
                lines.append("  \(mark) [\(mode)] \(item.path) (\(item.bytes.bytesFormatted))\(error)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    /// Record icon by operation type (first section title decides).
    /// Records written before `source` existed are mapped from their
    /// section titles so old and new rows still show a menu badge.
    static func resolvedSource(_ record: CleanRecord) -> RecordSource {
        if let source = record.source { return source }
        let key = record.sectionTitles.first ?? ""
        if key.contains("Uninstall (batch)") { return .uninstallBatch }
        if key.contains("Uninstall") { return .uninstall }
        if key.contains("AI Agent") { return .aiAgent }
        if key.contains("Analyze") { return .analyze }
        if key.contains("Purge") { return .purge }
        if key.contains("Slim") { return .slim }
        if key.contains("Startup") { return .startup }
        if key.contains("Optimize") { return .optimize }
        return .clean
    }

    /// `/Users/sean/Library/...` → `~/Library/...` so rows stay readable.
    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
