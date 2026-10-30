import SwiftUI
import AppKit

/// Sidebar grouping by job, not by implementation: Dashboard → free up space →
/// keep the machine healthy → read the reports, with History/Settings last
/// (macOS convention).
///
/// Band labels name the *category*, never a row: "Clean" over a row also
/// called "Clean" just made the top of the sidebar look doubled. Rows stay
/// the concrete actions; the header is the umbrella.
enum RouteGroup {
    // Computed (not stored) so a language switch re-resolves L() — a stored
    // static would keep the first language's band labels for the whole run.
    static var top: [(label: String, routes: [Route])] {
        [("", [.dashboard])]
    }
    static var cleaning: [(label: String, routes: [Route])] {
        // Uninstall before Orphans: residue is what uninstalling leaves behind.
        [(L("Space Cleanup"), [.clean, .uninstall, .orphans, .purge, .slim])]
    }
    static var system: [(label: String, routes: [Route])] {
        [(L("Maintenance"), [.hogs, .largeFiles, .optimize, .startup])]
    }
    static var insights: [(label: String, routes: [Route])] {
        [(L("Insights"), [.status, .analyze])]
    }
    static var bottom: [(label: String, routes: [Route])] {
        [("", [.history, .settings])]
    }
}

/// The window's navigation panel: brand header, grouped route list, pet footer.
///
/// Spacing is a single ladder, not a pile of magic numbers — the constants live
/// in `Airi` so the panel reads as one system:
///   • the brand row clears the traffic lights instead of colliding with
///     them — `sidebarBrandTopInset` is added on top of the 32pt titlebar
///     safe-area inset SwiftUI already applies under `hiddenTitleBar`;
///   • rows are `Airi.sidebarRowHeight` tall with a 1pt seam, so the list
///     reads as a column of 32pt targets rather than a cramped stack;
///   • bands are separated by whitespace (`Airi.sidebarBandGap`), never by
///     rules — the eye parses groups from air, not from lines.
struct SidebarPanel: View {
    @Binding var route: Route

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section(RouteGroup.top, bandGap: 0)
                    section(RouteGroup.cleaning, bandGap: Airi.sidebarBandGap)
                    section(RouteGroup.system, bandGap: Airi.sidebarBandGap)
                    section(RouteGroup.insights, bandGap: Airi.sidebarBandGap)
                    // History/Settings live in the same flow as the modules:
                    // pinning them to the bottom left a ~200pt hole between
                    // "Insights" and the pair at ordinary window heights. They
                    // stay reachable because the list scrolls at the minimum
                    // window height.
                    section(RouteGroup.bottom, bandGap: Airi.sidebarBandGap)
                }
                .padding(.horizontal, Airi.sidebarListInset)
                .padding(.bottom, Airi.space1)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Liquid Glass (macOS 26+) already gives NavigationSplitView a sidebar
        // material; stacking ultraThinMaterial on top double-blurs it and reads
        // as a milky band. Keep the explicit material only pre-26.
        .background(OSCompat.usesLiquidGlass
                    ? AnyShapeStyle(Color.clear)
                    : AnyShapeStyle(.ultraThinMaterial))
        // Keep the sidebar a usable width when the window narrows — without
        // a floor, .balanced style crushes it until row titles wrap mid-word.
        .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 288)
    }

    // MARK: - Brand

    private var brandHeader: some View {
        HStack(spacing: 8) {
            Image(nsImage: MoppetBrandIcon.image)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
            Text("Moppet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Airi.neutral950)
                .kerning(-0.1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Airi.sidebarEdgeInset)
        // Clears the traffic lights (they sit in the top ~28pt under
        // `hiddenTitleBar`) and then some, so the header stops crowding the
        // window controls.
        .padding(.top, Airi.sidebarBrandTopInset)
        .padding(.bottom, 12)
    }

    // MARK: - Sections

    /// One labelled band of routes ("Space Cleanup", "Maintenance", …).
    /// Empty label = no section header (the Dashboard band).
    @ViewBuilder
    private func section(_ rows: [(label: String, routes: [Route])],
                         bandGap: CGFloat) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            VStack(alignment: .leading, spacing: 0) {
                if !row.label.isEmpty {
                    Text(row.label)
                        .font(Airi.sidebarSectionFont)
                        .tracking(Self.headerTracking(row.label))
                        .foregroundStyle(Airi.sidebarSectionLabel)
                        .textCase(.uppercase)
                        // Aligns with the icon column, not the pill edge —
                        // the label belongs to the rows' content, not to the
                        // selection chrome.
                        .padding(.leading, Airi.sidebarRowPadding)
                        .padding(.bottom, 4)
                }
                VStack(alignment: .leading, spacing: Airi.sidebarRowGap) {
                    ForEach(row.routes) { item in
                        rowView(item)
                    }
                }
            }
            .padding(.top, bandGap)
        }
    }

    private func rowView(_ item: Route) -> some View {
        SidebarRowButton(item: item, isActive: route == item) {
            route = item
        }
        .keyboardShortcut(RootView.routeShortcut(item))
    }

    /// Letter-spacing is a Latin typographic device: applied to CJK it reads as
    /// "空 间 清 理" — a row of isolated characters. Latin uppercase gets a
    /// touch of tracking; anything containing CJK gets none.
    private static func headerTracking(_ label: String) -> CGFloat {
        let hasCJK = label.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value)      // CJK ideographs
                || (0x3000...0x303F).contains(scalar.value) // CJK punctuation
        }
        return hasCJK ? 0 : 0.6
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 7) {
            // Outline paw: the filled glyph was the heaviest mark in the whole
            // panel and read as a stray sticker next to 1.5pt line icons.
            Image(systemName: "pawprint")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Airi.neutral500)
            Text(String(format: L("%@ · desktop pet"), PetIdentity.name))
                .font(Airi.footnoteFont)
                .foregroundStyle(Airi.neutral500)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                PetPanelController.shared.isVisible
                    ? PetPanelController.shared.hide()
                    : PetPanelController.shared.show()
            } label: {
                Image(systemName: PetPanelVisibilityFlag.shared.visible
                      ? "eye" : "eye.slash")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Airi.neutral500)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Show / hide the pet"))
        }
        .padding(.horizontal, Airi.sidebarEdgeInset)
        .padding(.vertical, 9)
        // A full-bleed 1px rule under the list read as a hard seam. The footer
        // is an extension of the panel, so the only separation left is a
        // hairline that fades out at both ends.
        .overlay(alignment: .top) {
            LinearGradient(colors: [Airi.hairline.opacity(0),
                                    Airi.hairline,
                                    Airi.hairline,
                                    Airi.hairline.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
                .padding(.horizontal, Airi.space2)
        }
    }
}

/// Sidebar row: 32pt target, 8pt continuous pill, accent wash instead of a
/// saturated fill.
///
/// The selected state deliberately stays quiet — macOS System Settings uses a
/// low-alpha accent tint plus accent text, not a glowing capsule. A shadow and
/// a semibold title on top of that made the row shout.
private struct SidebarRowButton: View {
    let item: Route
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    private var fill: Color {
        if isActive { return Airi.sidebarSelectionFill }
        return hovering ? Airi.sidebarHoverFill : .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    // One stroke weight for every glyph: SF Symbols inherit
                    // weight from the font, so a single .medium 13pt font is
                    // what keeps 14 different symbols looking like one set.
                    .font(.system(size: 13, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(isActive ? Airi.primary : Airi.neutral500)
                    .frame(width: 18, height: 18)
                    // The icon bounces whenever its row BECOMES active —
                    // the selection change reads as an event, not a repaint.
                    .symbolEffect(.bounce, value: isActive)
                Text(item.title)
                    .font(isActive ? Airi.sidebarRowActiveFont : Airi.sidebarRowFont)
                    .foregroundStyle(isActive ? Airi.primary : Airi.neutral800)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Airi.sidebarRowPadding)
            .frame(maxWidth: .infinity, minHeight: Airi.sidebarRowHeight,
                   alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Airi.sidebarRowRadius, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: Airi.sidebarRowRadius,
                                           style: .continuous))
            .scaleEffect(pressed ? 0.985 : 1)
        }
        .buttonStyle(.plain)
        // macOS 26 paints a blue keyboard-focus ring on the first focusable
        // sidebar row at launch, so the *inactive* Dashboard row looked
        // "selected" right next to the real active pill. Selection is already
        // conveyed by the pill + ⌘1–9, so suppress the focus effect here.
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(Airi.hoverAnimation, value: hovering)
        .animation(Airi.hoverAnimation, value: isActive)
        .animation(Airi.hoverAnimation, value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
