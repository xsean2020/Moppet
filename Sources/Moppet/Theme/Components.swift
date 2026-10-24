import SwiftUI
import AppKit

// MARK: - Window vibrancy (NSVisualEffectView, behind-window)

/// The signature macOS frosted-glass window background. Put behind the whole
/// window content; content surfaces (cards) stay solid for readability.
struct WindowVibrancy: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    /// Raw NSVisualEffectView swallows clicks and blocks TextField focus —
    /// pass every hit through to the SwiftUI content above it.
    final class PassThroughVibrancy: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassThroughVibrancy()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        // Thinner glass: dial the vibrancy layer back so the desktop shows
        // through more (light-mode vibrancy is especially milky at 1.0;
        // 0.7 after the user pushed for even more transparency at 0.8).
        view.alphaValue = 0.7
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

// MARK: - Window drag area (custom title bar support)

/// Plain NSView refuses window-drag; overriding the property makes it draggable.
final class DraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Custom title bar (AIRI style: floating icon+title pill, drag region)

struct AiriTitleBar: View {
    var body: some View {
        HStack(spacing: Airi.space2) {
            Color.clear.frame(width: 68) // room for traffic lights
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Airi.primary)
                Text("Moppet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Airi.neutral700)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Airi.neutral100.opacity(0.85))
            )
            .overlay(
                Capsule().strokeBorder(Airi.neutral200.opacity(0.6), lineWidth: 1)
            )
            Spacer()
        }
        .padding(.horizontal, Airi.space2)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(WindowDragArea())
    }
}

// MARK: - Page header (sticky, back arrow + 3xl title + small gray subtitle)

struct PageHeader: View {
    let title: String
    let subtitle: String
    var onBack: (() -> Void)?

    @State private var appeared = false

    var body: some View {
        HStack(alignment: .top, spacing: Airi.space3) {
            if let onBack {
                CircleIconButton(icon: "arrow.left", action: onBack)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle)
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                Text(title)
                    .font(Airi.pageTitleFont)
                    .foregroundStyle(Airi.neutral950)
            }
            Spacer()
        }
        .padding(.horizontal, Airi.space4)
        .padding(.top, Airi.space2)
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : 10)
        .onAppear {
            withAnimation(Airi.entranceCurve) { appeared = true }
        }
    }
}

struct CircleIconButton: View {
    let icon: String
    var action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Airi.primary : Airi.neutral700)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(hovering ? Airi.neutral100 : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(Airi.controlAnimation, value: pressed)
        .animation(Airi.controlAnimation, value: hovering)
        .onHover { hovering = $0; if $0 { pressed = false } }
        .onTapGesture {} // keep click on Button
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

// MARK: - Buttons (borderless, soft surface, press scale 0.95)

enum AiriButtonVariant { case primary, secondary, destructive }

struct AiriButton: View {
    let title: String
    var icon: String? = nil
    var variant: AiriButtonVariant = .primary
    var disabled: Bool = false
    var busy: Bool = false
    let action: () -> Void

    @State private var pressed = false

    private var surface: Color {
        switch variant {
        case .primary: return Airi.primary.opacity(0.85)
        case .secondary: return Airi.neutral200.opacity(0.75)
        case .destructive: return Airi.danger.opacity(0.85)
        }
    }
    private var foreground: Color {
        variant == .secondary ? Airi.neutral900 : Color.white
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Airi.space2) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: Airi.radiusControl, style: .continuous)
                    .fill(surface)
            )
            .opacity(disabled ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(Airi.controlAnimation, value: pressed)
        .onHover { _ in pressed = false }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !disabled { pressed = true } }
                .onEnded { _ in pressed = false }
        )
    }
}

// MARK: - Settings card (rounded-xl, neutral surface)

struct SettingsCard<Content: View>: View {
    var padding: CGFloat = Airi.space3
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Airi.space3) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                .fill(Airi.cardBackground)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                .strokeBorder(Airi.neutral200.opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - Ticking number (numericText transition)

/// Animated counter — wraps changes in withAnimation and the digits roll.
struct TickingNumber: View {
    let value: Int
    var body: some View {
        Text("\(value)")
            .contentTransition(.numericText(value: Double(value)))
            .monospacedDigit()
    }
}

// MARK: - Circular progress ring (animated trim)

struct ProgressRing: View {
    var progress: Double        // 0…1
    var lineWidth: CGFloat = 8
    var tint: Color = Airi.primary
    var track: Color = Airi.neutral200
    var showValue: Bool = false
    var valueText: String = ""

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.75), tint],
                                    center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            if showValue {
                Text(valueText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Airi.neutral700)
                    .monospacedDigit()
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: progress)
    }
}

// MARK: - Dot pattern texture (AIRI hover texture: 10px grid of 1px dots)

struct DotPattern: View {
    var spacing: CGFloat = 10
    var radius: CGFloat = 1
    var color: Color = Airi.neutral400
    var opacity: Double

    var body: some View {
        Canvas { context, size in
            let dotColor = color.opacity(0.35)
            var y: CGFloat = spacing
            while y < size.height {
                var x: CGFloat = spacing
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(dotColor))
                    x += spacing
                }
                y += spacing
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}

// MARK: - IconItemCard (AIRI's signature settings entry card)

struct IconItemCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var metadata: String? = nil
    let action: () -> Void

    @State private var hovering = false
    @State private var appeared = false
    private let entranceIndex: Double

    init(icon: String, title: String, subtitle: String, metadata: String? = nil,
         entranceIndex: Double = 0, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.metadata = metadata
        self.entranceIndex = entranceIndex
        self.action = action
    }

    var body: some View {
        Button(action: action) { cardContent }
            .buttonStyle(.plain)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .onAppear {
                withAnimation(Airi.entranceCurve.delay(entranceIndex * 0.05)) { appeared = true }
            }
            .onHover { hovering = $0 }
            .animation(Airi.cardAnimation, value: hovering)
    }

    private var cardContent: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                .fill(Airi.cardBackground)
            DotPattern(opacity: hovering ? 1 : 0)
                .clipShape(RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous))
            // watermark icon
            HStack {
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 64, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(hovering ? Airi.primary : Airi.neutral400)
                    .opacity(hovering ? 0.5 : 0.3)
                    .scaleEffect(hovering ? 1.2 : 1)
                    .padding(.trailing, 14)
                    .padding(.top, 10)
            }
            VStack(alignment: .leading, spacing: Airi.space1) {
                if let metadata {
                    Text(metadata)
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(hovering ? Airi.primary : Airi.neutral950)
                Text(subtitle)
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 28)
            }
            .padding(Airi.space4)
        }
        .frame(height: 132)
        .overlay(
            RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                .strokeBorder(
                    hovering ? Airi.primary.opacity(0.5) : Airi.neutral200.opacity(0.6),
                    lineWidth: hovering ? 2 : 1
                )
        )
        .shadow(color: Color.black.opacity(hovering ? 0.10 : 0), radius: 4, y: 4)
    }
}

// MARK: - Toggle row (settings-style labeled switch)

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Airi.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Airi.cardTitleFont).foregroundStyle(Airi.neutral950)
                if let subtitle {
                    Text(subtitle).font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

// MARK: - Reveal item row for scan results

struct FindingRow: View {
    let name: String
    let detail: String
    var body: some View {
        HStack(spacing: Airi.space2) {
            Image(systemName: "doc")
                .font(Airi.caption2Font)
                .foregroundStyle(Airi.neutral400)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Airi.captionFont).lineLimit(1).truncationMode(.middle)
                Text(detail).font(Airi.caption2Font).foregroundStyle(Airi.neutral500)
            }
            Spacer()
        }
    }
}

// MARK: - Empty state (nothing found / no search results / no history)

/// Friendly empty-state card: watermark icon + title + hint + optional
/// action. Replaces the previous "blank list / one gray caption" pattern.
struct EmptyStateCard: View {
    let icon: String
    let title: String
    var hint: String = ""
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Airi.space2) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Airi.neutral400)
                .opacity(0.7)
                .padding(.bottom, 2)
            Text(title)
                .font(Airi.emphasisFont)
                .foregroundStyle(Airi.neutral900)
                .multilineTextAlignment(.center)
            if !hint.isEmpty {
                Text(hint)
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                AiriButton(title: actionTitle, variant: .secondary, action: action)
                    .padding(.top, Airi.space1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Airi.space4)
        .padding(.horizontal, Airi.space3)
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                .fill(Airi.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                .strokeBorder(Airi.neutral200.opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - Completion feedback (haptics)

/// Auditory/haptic completion cues. The app had zero haptic feedback; the
/// pet celebrates visually, but a native macOS app should also tick the
/// trackpad on "big thing finished".
enum UXFeedback {
    /// Light alignment tick — scan finished / clean done / uninstall done.
    static func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
