import SwiftUI

/// Progress of a destructive batch.
///
/// Every delete flow in the app reports through this one shape, so "is it
/// working or did it freeze?" always gets the same answer in the same place.
/// A batch that cannot be counted (one shell task, one `tmutil` call) uses
/// `total == 0`, which renders a spinning ring instead of a percentage — the
/// honest signal, rather than a fake 0 %.
struct BatchProgress: Equatable {
    var title: String
    var done: Int = 0
    /// 0 → the work is not countable; the ring spins.
    var total: Int = 0
    /// What is being worked on right now (app name, snapshot id, path…).
    var detail: String?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    var isIndeterminate: Bool { total <= 0 }

    var percentText: String { "\(Int((fraction * 100).rounded()))%" }

    /// "7 / 12" — nil for indeterminate work (no count to show).
    var countText: String? { total > 0 ? "\(done) / \(total)" : nil }
}

/// Centered modal shown while a destructive batch runs: dim, opaque card,
/// ring, counts. It swallows clicks, so a second destructive action can never
/// race the one already in flight.
///
/// The card is deliberately OPAQUE (`Airi.pageBackground`) instead of the
/// theme's `cardBackground`: that token is 60 % glass so wallpapers tint
/// through, which let the page's own spinner, labels and buttons show through
/// the modal and made the numbers unreadable.
struct BatchProgressOverlay: View {
    let progress: BatchProgress

    var body: some View {
        ZStack {
            Color.black.opacity(0.30)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                // Absorb clicks: no Rescan, no second delete, no row selection.
                .onTapGesture {}

            VStack(spacing: Airi.space3) {
                Group {
                    if progress.isIndeterminate {
                        SpinningRing(lineWidth: 10)
                    } else {
                        ProgressRing(progress: progress.fraction,
                                     lineWidth: 10,
                                     showValue: true,
                                     valueText: progress.percentText,
                                     valueFontSize: 18)
                    }
                }
                .frame(width: 104, height: 104)

                VStack(spacing: 2) {
                    Text(progress.title)
                        .font(Airi.bodyFont.weight(.medium))
                        .foregroundStyle(Airi.neutral900)
                        .multilineTextAlignment(.center)
                    if let count = progress.countText {
                        Text(count)
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.neutral500)
                            .monospacedDigit()
                    }
                    if let detail = progress.detail, !detail.isEmpty {
                        Text(detail)
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral400)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.top, 1)
                    }
                }
            }
            .padding(Airi.space4)
            .frame(width: 216)
            .background(
                RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                    .fill(Airi.pageBackground)
                    .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                    .strokeBorder(Airi.neutral200.opacity(0.7), lineWidth: 1)
            )
        }
        .transition(.opacity)
    }
}

/// Indeterminate ring: a quarter arc orbiting the track. Used when the work
/// has no item count — a spinner alone gives no sense of the surface it
/// belongs to, and a fake percentage would be a lie.
private struct SpinningRing: View {
    var lineWidth: CGFloat = 10
    @State private var spin = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(Airi.neutral200, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.24)
                .stroke(
                    AngularGradient(colors: [Airi.primary.opacity(0.35), Airi.primary],
                                    center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(spin))
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        spin = 360
                    }
                }
        }
    }
}

/// Keeps a progress overlay on screen long enough to register.
///
/// A three-file delete finishes inside a single frame: the overlay would
/// appear and vanish before the eye caught it, which reads as a glitch rather
/// than as feedback.
@MainActor
enum BatchProgressHold {
    static func until(_ startedAt: Date, minimum: TimeInterval = 0.45) async {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed < minimum else { return }
        try? await Task.sleep(nanoseconds: UInt64((minimum - elapsed) * 1_000_000_000))
    }
}
