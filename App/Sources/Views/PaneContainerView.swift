import SwiftUI

/// Whether the pane a view is drawn in should put its items in the navigation bar.
///
/// On a phone the panes share one bar — the pushed route's — because a nested
/// `NavigationStack` per pane pops the outer stack (measured: splitting from the Session
/// menu returned the app to the connection list). Two panes both filling that one bar
/// would give a person two identical Session menus and no way to tell which pane either
/// acts on, so only the focused pane fills it.
private struct PaneContributesToolbarKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var paneContributesToolbar: Bool {
        get { self[PaneContributesToolbarKey.self] }
        set { self[PaneContributesToolbarKey.self] = newValue }
    }
}

/// Draws a ``PaneLayout``: several terminals, several screens, or any mixture, at once.
///
/// The tree is recursive so the view is too. Each split measures itself and hands each half
/// the space its fraction asks for, which keeps the arithmetic in one place and means a
/// deeply nested arrangement needs no special case.
///
/// The focused pane is marked with a border rather than a shadow or a glow: on a screen that
/// is mostly dark terminal text, a one-point accent edge is the quietest thing that still
/// reads at a glance, and it survives Increase Contrast and Differentiate Without Colour —
/// which a colour-only cue would not, so the focused pane also says so to VoiceOver.
struct PaneContainerView: View {
    @Binding var layout: PaneLayout
    /// True where the panes have no navigation bar of their own — a phone — so only the
    /// focused pane may fill the one bar they share.
    var panesShareOneToolbar = false
    /// Builds the view for one pane's content. Passed in so this file knows nothing about
    /// terminals or screens: it is a layout, and layouts should not care.
    ///
    /// The pane's own id comes with it, because a pane whose session has ended has to be able
    /// to offer to show something else *here* — which means naming the pane to replace (D-074).
    let content: (PaneLayout.Content, UUID) -> AnyView

    var body: some View {
        if let root = layout.root {
            node(root)
        } else {
            EmptyStateView(
                title: String(localized: "No session"),
                message: String(localized: "Choose a connection to open a terminal."),
                systemImage: "terminal"
            )
        }
    }

    /// `AnyView` because the function calls itself: an opaque return type cannot be
    /// defined in terms of itself, and a pane tree is recursive by nature. The cost is
    /// bounded — a screen holds a handful of panes, not a list of thousands — and the
    /// alternative is a fixed maximum depth, which is a worse thing to owe a user.
    private func node(_ tree: PaneLayout.Node) -> AnyView {
        switch tree {
        case let .leaf(id, paneContent):
            AnyView(pane(id: id, content: paneContent))
        case let .split(id, axis, leading, trailing, fraction):
            AnyView(
                SplitView(
                    axis: axis,
                    fraction: fraction,
                    onResize: { layout.resize(id, to: $0) },
                    first: { node(leading) },
                    second: { node(trailing) }
                )
            )
        }
    }

    private func pane(id: UUID, content paneContent: PaneLayout.Content) -> some View {
        let isFocused = layout.focused == id
        return content(paneContent, id)
            .environment(\.paneContributesToolbar, panesShareOneToolbar ? isFocused : true)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .strokeBorder(
                        isFocused ? DesignTokens.Color.accent : DesignTokens.Color.separator,
                        lineWidth: isFocused ? 2 : 1
                    )
            }
            // A tap anywhere in a pane focuses it, which is what people expect from every
            // other tiling interface. `simultaneousGesture` so the terminal underneath
            // still receives its own taps: focusing must not cost a keystroke.
            .simultaneousGesture(TapGesture().onEnded { layout.focus(id) })
            // Announced by a marker *inside* the pane rather than by labelling the pane
            // itself. Labelling the container collapses it into a single element and hides
            // everything in it — measured: the focused pane's terminal disappeared from
            // the accessibility tree entirely, which for VoiceOver means the pane someone
            // is typing into is the one they cannot read.
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(
                        isFocused
                            ? String(localized: "Pane, focused")
                            : String(localized: "Pane")
                    )
                    .accessibilityAddTraits(isFocused ? [.isSelected] : [])
                    .accessibilityIdentifier("pane-marker")
            }
    }
}

/// One division of the space, with a divider that can be dragged.
private struct SplitView<First: View, Second: View>: View {
    let axis: PaneLayout.Axis
    let fraction: Double
    let onResize: (Double) -> Void
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging = false

    /// Wide enough to grab with a finger without stealing space from the panes. Apple's own
    /// guidance is a 44-point target; the visible line is thinner and the *hit* area is not.
    private static var dividerThickness: CGFloat { 8 }
    private static var dividerHitArea: CGFloat { 44 }

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let firstLength = max(0, (total - Self.dividerThickness) * fraction)
            let secondLength = max(0, total - Self.dividerThickness - firstLength)

            container {
                first()
                    .frame(
                        width: axis == .horizontal ? firstLength : nil,
                        height: axis == .vertical ? firstLength : nil
                    )
                divider(total: total)
                second()
                    .frame(
                        width: axis == .horizontal ? secondLength : nil,
                        height: axis == .vertical ? secondLength : nil
                    )
            }
        }
    }

    @ViewBuilder
    private func container<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0) { content() }
        } else {
            VStack(spacing: 0) { content() }
        }
    }

    private func divider(total: CGFloat) -> some View {
        ZStack {
            // The visible line, and a larger invisible target around it.
            Rectangle()
                .fill(dragging ? DesignTokens.Color.accent : DesignTokens.Color.separator)
                .frame(
                    width: axis == .horizontal ? Self.dividerThickness : nil,
                    height: axis == .vertical ? Self.dividerThickness : nil
                )
            Color.clear
                .frame(
                    width: axis == .horizontal ? Self.dividerHitArea : nil,
                    height: axis == .vertical ? Self.dividerHitArea : nil
                )
                .contentShape(Rectangle())
        }
        .frame(
            width: axis == .horizontal ? Self.dividerThickness : nil,
            height: axis == .vertical ? Self.dividerThickness : nil
        )
        // Follows the finger exactly — no animation on the drag itself, because a divider
        // that lags behind the touch feels broken rather than smooth. The only animated
        // part is the colour, and Reduce Motion turns even that off.
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !dragging {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { dragging = true }
                    }
                    guard total > 0 else { return }
                    let position = axis == .horizontal ? value.location.x : value.location.y
                    onResize(position / total)
                }
                .onEnded { _ in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { dragging = false }
                }
        )
        .hoverEffect(.highlight)
        .accessibilityElement()
        .accessibilityLabel(
            axis == .horizontal
                ? String(localized: "Vertical divider")
                : String(localized: "Horizontal divider")
        )
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
        .accessibilityHint(String(localized: "Adjust to resize the panes"))
        // Adjustable, so the divider can be moved without a drag — the only way it is
        // reachable with VoiceOver or Voice Control.
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment: onResize(fraction + step)
            case .decrement: onResize(fraction - step)
            @unknown default: break
            }
        }
    }
}
