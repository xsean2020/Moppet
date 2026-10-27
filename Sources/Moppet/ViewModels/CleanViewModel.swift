import Foundation
import Observation

/// Drives the clean flow: configure → scanning → review → cleaning → done.
/// SwiftUI counterpart of mole's interactive section flow with its
/// dry-run-first (preview before delete) contract.
@Observable
final class CleanViewModel {

    enum Phase { case configure, scanning, review, cleaning, done }

    // MARK: - Section state

    @Observable
    final class ItemState: Identifiable {
        var id: String { item.id }
        let item: CleanItem
        /// Persisted on every change: the view (and its checkboxes) is
        /// recreated on each navigation, so an un-persisted selection reset
        /// to the defaults and re-scanned items the user had unchecked.
        /// `didSet` does not fire from init, so seeding stays side-effect free.
        var selected: Bool {
            didSet {
                guard oldValue != selected else { return }
                CleanSelectionStore.setSelected(id: item.id, selected)
            }
        }
        var result: ItemScanResult?
        /// Fine-grained: unchecked findings are kept even when the item runs.
        var excludedFindings: Set<String> = []

        init(item: CleanItem) {
            self.item = item
            self.selected = CleanSelectionStore.isSelected(item)
        }

        var totalBytes: Int64 { result?.totalBytes ?? 0 }
        var findingCount: Int { result?.findings.count ?? 0 }

        var activeFindings: [Finding] {
            guard let result else { return [] }
            return result.findings.filter { !excludedFindings.contains($0.id) }
        }
        var activeBytes: Int64 {
            activeFindings.reduce(0) { $0 + $1.bytes }
        }
    }

    @Observable
    final class SectionState: Identifiable {
        var id: String { section.id }
        let section: CleanSection
        var items: [ItemState]
        var expanded = false

        init(section: CleanSection) {
            self.section = section
            self.items = section.items.map(ItemState.init)
        }

        var selected: Bool {
            get { items.allSatisfy(\.selected) }
            set { for i in items.indices { items[i].selected = newValue } }
        }
        var partiallySelected: Bool {
            items.contains(where: { $0.selected }) && !items.allSatisfy({ $0.selected })
        }
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.totalBytes } }
        var findingCount: Int { items.reduce(0) { $0 + $1.findingCount } }
        var scannedBytes: Int64 {
            items.filter(\.selected).reduce(0) { $0 + $1.activeBytes }
        }
    }

    // MARK: - Observable state

    var sections: [SectionState] = RuleLibrary.sections.map(SectionState.init)
    var phase: Phase = .configure
    var progressMessage = ""
    var completedItems = 0
    var totalItems = 0
    var cleanProgressDone = 0
    var cleanProgressTotal = 0
    var outcomes: [CleanOutcome] = []
    var lastRecord: CleanRecord?
    var lastError: String?

    // MARK: - Derived

    var reviewBytes: Int64 {
        sections.reduce(0) { $0 + $1.scannedBytes }
    }
    var reviewCount: Int {
        // Active findings only — per-finding exclusions (the review tree's
        // checkboxes) must shrink the confirmed count, or the confirmation
        // dialog overstates what will be removed.
        sections.reduce(0) { acc, s in
            acc + s.items.filter(\.selected).reduce(0) { $0 + $1.activeFindings.count }
        }
    }
    /// Sections the review page renders: only those with selected items that
    /// actually have scan findings. Unselected (or finding-free) sections
    /// stay hidden — showing their cards with "0 paths" on the review screen
    /// blurs what the pending clean covers and invites toggle mistakes.
    var reviewSections: [SectionState] {
        sections.filter { section in
            section.items.contains { $0.selected && $0.findingCount > 0 }
        }
    }
    var freedBytes: Int64 {
        outcomes.filter(\.success).reduce(0) { $0 + $1.bytes }
    }
    var failureCount: Int { outcomes.filter { !$0.success }.count }

    var selectedItems: [CleanItem] {
        sections.flatMap { $0.items.filter(\.selected).map(\.item) }
    }
    var selectedFindings: [Finding] {
        sections.flatMap { section in
            section.items
                .filter(\.selected)
                .flatMap(\.activeFindings)
        }
    }

    // MARK: - Actions

    /// Task handle so the scanning phase can be cancelled from the UI.
    /// Generation-guarded: the old task's trailing `scanTask = nil` used to
    /// erase a NEWER task's handle, letting a third scan run concurrently.
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var isCleaning = false

    @MainActor
    func reset() {
        for section in sections {
            section.expanded = false
            for i in section.items.indices {
                section.items[i].result = nil
                // Keep what the user chose — "Adjust selection" used to
                // silently re-check everything they had unticked.
                section.items[i].selected = CleanSelectionStore.isSelected(section.items[i].item)
                section.items[i].excludedFindings = []
            }
        }
        outcomes = []
        lastRecord = nil
        lastError = nil
        progressMessage = ""
        phase = .configure
    }

    /// Global select-all / clear-all for the configure page. The per-section
    /// tri-state only covered one section at a time; users asked for one tap
    /// across every section. `selected`'s didSet persists each change.
    @MainActor
    func selectAll() {
        for section in sections {
            for i in section.items.indices { section.items[i].selected = true }
        }
    }

    @MainActor
    func deselectAll() {
        for section in sections {
            for i in section.items.indices { section.items[i].selected = false }
        }
    }

    /// UI entry point: runs scan() as a cancellable task. A second tap while
    /// scanning is ignored (the Cancel button is the way out).
    @MainActor
    func startScan() {
        guard scanTask == nil else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanTask = Task { @MainActor in
            await self.scan()
            if generation == self.scanGeneration {
                self.scanTask = nil
            }
        }
    }

    /// Abort a running scan and drop back to the configure phase with the
    /// user's checkboxes intact.
    @MainActor
    func cancelScan() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        progressMessage = ""
        phase = .configure
        PetBus.shared.settle()
    }

    @MainActor
    func scan() async {
        phase = .scanning
        progressMessage = "Scanning…"
        // The desktop pet mirrors the main window's flow too — before this,
        // only AI-tool scans / quick scans / uninstall made the pet react.
        PetBus.shared.say(L("Scanning…"), state: .scanning)
        let items = selectedItems
        totalItems = items.count
        completedItems = 0

        // Progress fires on task-group threads; @Observable state must be
        // mutated on main (the direct write was a real data race).
        let results = await ScanEngine.scan(items: items) { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progressMessage = message
                self.completedItems += 1
            }
        }

        // Cancelled mid-scan → discard partial results, keep selections.
        guard !Task.isCancelled else { return }

        // Attach results back to section state. Per-finding exclusions are
        // carried over by PATH: a rescan used to silently re-check files the
        // user had explicitly unchecked — then Clean deleted them.
        var byItem: [String: ItemScanResult] = [:]
        for r in results { byItem[r.item.id] = r }
        for section in sections {
            for i in section.items.indices {
                let previousExclusions = section.items[i].excludedFindings
                let previousURLs = Set((section.items[i].result?.findings ?? [])
                    .filter { previousExclusions.contains($0.id) }
                    .map(\.url.path))
                section.items[i].result = byItem[section.items[i].item.id]
                if let newFindings = section.items[i].result?.findings {
                    section.items[i].excludedFindings = Set(
                        newFindings.filter { previousURLs.contains($0.url.path) }.map(\.id))
                } else {
                    section.items[i].excludedFindings = []
                }
            }
        }
        phase = .review
        let total = reviewBytes
        if reviewCount == 0 {
            PetBus.shared.say(L("Nothing to clean ✨"), state: .celebrating)
        } else {
            PetBus.shared.say(
                String(format: L("Found %lld paths (%@)"), reviewCount, total.bytesFormatted),
                state: .celebrating)
        }
    }

    @MainActor
    func clean() async {
        guard !isCleaning else { return }
        let findings = selectedFindings
        guard !findings.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }
        phase = .cleaning
        cleanProgressDone = 0
        cleanProgressTotal = findings.count
        let requested = findings.reduce(0) { $0 + $1.bytes }

        let results = await CleanExecutor.clean(findings: findings) { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cleanProgressDone = done
                self.cleanProgressTotal = total
            }
        }
        outcomes = results

        // Name what was actually cleaned (item level), deduped: the old list
        // used section titles and included sections that were never touched
        // (`findingCount > 0` ignored selection), so History described runs
        // that did not match the deletion.
        let cleanedItemIDs = Set(findings.map(\.itemID))
        var seenItems: Set<String> = []
        let sectionTitles = sections.flatMap(\.items)
            .filter { cleanedItemIDs.contains($0.id) && seenItems.insert($0.id).inserted }
            .map(\.item.name)
        let record = CleanRecord(
            date: Date(),
            sectionTitles: sectionTitles,
            requestedBytes: requested,
            freedBytes: freedBytes,
            itemCount: findings.count,
            items: results.map {
                CleanRecordItem(path: $0.path, bytes: $0.bytes,
                                mode: $0.mode,
                                success: $0.success, error: $0.error)
            }, source: .clean)
        HistoryStore.append(record)
        lastRecord = record
        phase = .done
        PetBus.shared.say(String(format: L("Freed %@"), freedBytes.bytesFormatted) + " ✨",
                          state: .celebrating)
    }
}
