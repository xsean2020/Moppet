import SwiftUI

/// `mo slim` page — universal-binary slimming: list apps carrying Intel code
/// on Apple Silicon, pick some, strip their x86_64/i386 slices on verified
/// copies (originals go to the Trash as the rollback).
struct SlimView: View {
    var onClose: (() -> Void)?

    @State private var candidates: [SlimEngine.Candidate] = []
    @State private var selected: Set<UUID> = []
    @State private var scanning = false
    @State private var slimming = false
    @State private var outcomes: [SlimEngine.Outcome] = []
    @State private var confirming = false
    @State private var scannedOnce = false

    private var archNote: String {
        SlimEngine.hostIsAppleSilicon
            ? "Apple Silicon — removing Intel code is safe after verification"
            : "Intel Mac — slimming is disabled (removing x86_64 would leave apps unusable here)"
    }

    private var selectedBytes: Int64 {
        candidates.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.intelBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Slim"), subtitle: L("Remove Intel code from universal apps (mo slim)"), onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            ScrollView {
                VStack(spacing: Airi.space3) {
                    introCard
                    if scanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Scanning applications…")).font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                        }
                        .padding(.top, 20)
                    }
                    ForEach(candidates) { candidate in
                        candidateRow(candidate)
                    }
                    if scannedOnce && candidates.isEmpty && !scanning {
                        Text(L("No universal apps with Intel code found"))
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.neutral500)
                            .padding(.top, 16)
                    }
                    if !candidates.isEmpty {
                        HStack {
                            Text(String(format: L("%1$lld selected · %2$@"),
                                        selected.count, selectedBytes.bytesFormatted))
                                .font(Airi.captionFont)
                                .foregroundStyle(Airi.neutral500)
                                .monospacedDigit()
                            Spacer()
                            AiriButton(title: L("Select all"), variant: .secondary) {
                                selected = Set(candidates.map(\.id))
                            }
                            AiriButton(title: slimmingNow.map { L("Slimming") + " \($0)…" } ?? L("Slim"),
                                       icon: "scissors", variant: .destructive,
                                       disabled: selected.isEmpty || slimming,
                                       busy: slimming) {
                                confirming = true
                            }
                        }
                    }
                    ForEach(outcomes) { outcome in
                        outcomeRow(outcome)
                    }
                }
                .padding(Airi.space4)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Airi.pageBackground.opacity(0.001))
        .sheet(isPresented: $confirming) {
            slimConfirm
        }
        .task {
            guard !scannedOnce else { return }
            await scan()
        }
    }

    private var introCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Text(L("How slimming works")).font(Airi.cardTitleFont)
                Text(String(format: L("Each selected app is copied, its Intel slices (x86_64/i386) removed with lipo, re-signed and code-signature-verified — only then does the original move to the Trash and the slimmed copy takes its place. App Store, Apple and running apps are never touched. An app update restores the Intel code. %@."), archNote))
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

    private func candidateRow(_ candidate: SlimEngine.Candidate) -> some View {
        let isSelected = selected.contains(candidate.id)
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Airi.primary : Airi.neutral400)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Airi.neutral900)
                Text(String(format: L("%1$@ · %2$lld universal binaries"), candidate.path, candidate.binaries.count))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(candidate.intelBytes.bytesFormatted)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Airi.neutral900)
                Text(L("Intel code"))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral400)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusCard)
                .fill(isSelected ? Airi.primary.opacity(0.06) : Airi.cardBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selected.remove(candidate.id) } else { selected.insert(candidate.id) }
        }
    }

    private func outcomeRow(_ outcome: SlimEngine.Outcome) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: outcome.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(outcome.success ? Airi.success : Airi.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Airi.neutral900)
                Text(outcome.message)
                    .font(Airi.monoCaption2Font)
                    .foregroundStyle(Airi.neutral700)
                    .textSelection(.enabled)
            }
            Spacer()
            if outcome.success {
                Text("−\(outcome.savedBytes.bytesFormatted)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Airi.success)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusCard)
                .fill(Airi.neutral100.opacity(0.6))
        )
    }

    private var slimConfirm: some View {
        VStack(alignment: .leading, spacing: Airi.space3) {
            Label(String(format: L("Slim %lld apps?"), selected.count), systemImage: "scissors")
                .font(.system(size: 14, weight: .medium))
            Text(String(format: L("Intel slices (%@) will be removed from verified copies; originals move to the Trash as the rollback. Apps re-signed ad-hoc may ask for confirmation on first launch."),
                        selectedBytes.bytesFormatted))
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral500)
            HStack {
                Spacer()
                AiriButton(title: L("Cancel"), variant: .secondary) { confirming = false }
                AiriButton(title: L("Slim"), variant: .destructive) {
                    confirming = false
                    Task { await slim() }
                }
            }
        }
        .padding(Airi.space4)
        .frame(width: 420)
    }

    private func scan() async {
        scanning = true
        candidates = await SlimEngine.scan()
        selected = selected.filter { id in candidates.contains { $0.id == id } }
        scanning = false
        scannedOnce = true
    }

    @State private var slimmingNow: String?

    private func slim() async {
        let picks = candidates.filter { selected.contains($0.id) }
        guard !picks.isEmpty else { return }
        slimming = true
        outcomes = await SlimEngine.slim(picks) { name in
            Task { @MainActor in slimmingNow = name }
        }
        slimmingNow = nil
        slimming = false
        selected = []
        await scan()   // refresh sizes after slimming
    }
}
