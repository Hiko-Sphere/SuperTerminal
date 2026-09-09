import Foundation

/// How the screen is divided between several sessions at once (D-055).
///
/// A tree rather than a list, because that is what splitting actually produces: splitting a
/// pane replaces *it* with two, and splitting one of those again divides only that half. A
/// flat grid cannot express "a terminal on the left, and on the right a screen above a
/// second terminal", which is the arrangement people build within a minute of being able to.
///
/// Everything here is a value. Layout arithmetic is where this kind of feature goes wrong —
/// a pane that cannot be closed, a fraction that drifts to zero, a focus that points at
/// something no longer on screen — and those are exactly the bugs that are cheap to catch
/// in a test and expensive to notice by hand.
struct PaneLayout: Equatable, Sendable {
    /// What a single pane is showing.
    enum Content: Equatable, Hashable, Sendable {
        case terminal(UUID)
        case screen(UUID)
        /// A tmux session, whose own windows and panes are drawn inside this one (D-059).
        /// The app does not split a tmux pane: in a tmux session the server owns the
        /// arrangement, and two things deciding it would fight.
        case tmux(UUID)

        var sessionID: UUID {
            switch self {
            case let .terminal(id), let .screen(id), let .tmux(id): id
            }
        }
    }

    enum Axis: Equatable, Sendable {
        /// Panes side by side.
        case horizontal
        /// Panes one above the other.
        case vertical
    }

    indirect enum Node: Equatable, Sendable {
        case leaf(id: UUID, content: Content)
        /// `fraction` is how much of the axis the *first* child gets.
        case split(id: UUID, axis: Axis, first: Node, second: Node, fraction: Double)

        var id: UUID {
            switch self {
            case let .leaf(id, _), let .split(id, _, _, _, _): id
            }
        }
    }

    private(set) var root: Node?
    /// The pane keystrokes go to. Always a leaf that exists, or `nil` when nothing is open.
    private(set) var focused: UUID?

    /// A split may not make either side smaller than this fraction of its axis. Dragging a
    /// divider to the edge is how a pane becomes impossible to see and therefore impossible
    /// to close.
    static let minimumFraction = 0.15

    /// How many panes are open. What the UI counts to decide whether closing one is
    /// "close this pane" or "close the session".
    var paneCount: Int { root.map(Self.count) ?? 0 }

    /// Every pane, left to right and top to bottom — the order focus moves in.
    var panes: [(id: UUID, content: Content)] {
        guard let root else { return [] }
        return Self.leaves(of: root)
    }

    var focusedContent: Content? {
        guard let focused else { return nil }
        return panes.first { $0.id == focused }?.content
    }

    // MARK: - Building

    init() {}

    /// Starts with one pane.
    init(content: Content) {
        let id = UUID()
        root = .leaf(id: id, content: content)
        focused = id
    }

    /// Replaces everything with a single pane. What tapping a connection in the list does:
    /// choosing a session is not the same gesture as splitting.
    mutating func show(_ content: Content) {
        let id = UUID()
        root = .leaf(id: id, content: content)
        focused = id
    }

    /// Splits the focused pane, putting `content` in the new half, and focuses it.
    ///
    /// With nothing open this is the same as ``show(_:)`` — splitting an empty screen can
    /// only mean "show this".
    @discardableResult
    mutating func split(_ content: Content, axis: Axis) -> UUID {
        guard let root, let focused else {
            let id = UUID()
            self.root = .leaf(id: id, content: content)
            self.focused = id
            return id
        }
        let newID = UUID()
        self.root = Self.replacing(focused, in: root) { existing in
            .split(id: UUID(), axis: axis, first: existing, second: .leaf(id: newID, content: content), fraction: 0.5)
        }
        self.focused = newID
        return newID
    }

    /// Removes a pane. Its sibling takes the space, which is what makes closing feel like
    /// the inverse of splitting rather than a rearrangement.
    mutating func close(_ paneID: UUID) {
        guard let root else { return }
        let before = panes.map(\.id)
        self.root = Self.removing(paneID, from: root)

        guard let remaining = self.root else {
            focused = nil
            return
        }
        if focused == paneID || !Self.leaves(of: remaining).contains(where: { $0.id == focused }) {
            // Focus the neighbour that was next to it, so closing a pane leaves the
            // keyboard somewhere predictable rather than at the start.
            let order = before.filter { id in Self.leaves(of: remaining).contains { $0.id == id } }
            let index = before.firstIndex(of: paneID) ?? 0
            focused = order.first { before.firstIndex(of: $0) ?? 0 >= index } ?? order.last
        }
    }

    /// Closes every pane showing this session — used when the session itself ends, which
    /// can happen while several panes are looking at it.
    mutating func closeAll(showing content: Content) {
        for pane in panes where pane.content == content {
            close(pane.id)
        }
    }

    mutating func focus(_ paneID: UUID) {
        guard panes.contains(where: { $0.id == paneID }) else { return }
        focused = paneID
    }

    /// Moves focus to the next pane, wrapping. The keyboard equivalent of tapping one.
    mutating func focusNext(reverse: Bool = false) {
        let order = panes.map(\.id)
        guard !order.isEmpty else { return }
        guard let focused, let index = order.firstIndex(of: focused) else {
            self.focused = order.first
            return
        }
        let step = reverse ? -1 : 1
        let next = (index + step + order.count) % order.count
        self.focused = order[next]
    }

    /// Moves a divider. `fraction` is clamped so neither side can be squeezed out of view.
    mutating func resize(_ splitID: UUID, to fraction: Double) {
        guard let root else { return }
        self.root = Self.map(root) { node in
            guard case let .split(id, axis, first, second, _) = node, id == splitID else { return node }
            let clamped = min(max(fraction, Self.minimumFraction), 1 - Self.minimumFraction)
            return .split(id: id, axis: axis, first: first, second: second, fraction: clamped)
        }
    }

    // MARK: - Tree operations

    private static func count(_ node: Node) -> Int {
        switch node {
        case .leaf: 1
        case let .split(_, _, first, second, _): count(first) + count(second)
        }
    }

    private static func leaves(of node: Node) -> [(id: UUID, content: Content)] {
        switch node {
        case let .leaf(id, content): [(id, content)]
        case let .split(_, _, first, second, _): leaves(of: first) + leaves(of: second)
        }
    }

    /// Rebuilds the tree with `transform` applied to the node with this identifier.
    private static func replacing(_ id: UUID, in node: Node, _ transform: (Node) -> Node) -> Node {
        if node.id == id { return transform(node) }
        guard case let .split(splitID, axis, first, second, fraction) = node else { return node }
        return .split(
            id: splitID,
            axis: axis,
            first: replacing(id, in: first, transform),
            second: replacing(id, in: second, transform),
            fraction: fraction
        )
    }

    /// Removes a leaf, collapsing the split that held it.
    private static func removing(_ id: UUID, from node: Node) -> Node? {
        switch node {
        case let .leaf(leafID, _):
            return leafID == id ? nil : node
        case let .split(splitID, axis, first, second, fraction):
            let newFirst = removing(id, from: first)
            let newSecond = removing(id, from: second)
            switch (newFirst, newSecond) {
            case let (.some(a), .some(b)):
                return .split(id: splitID, axis: axis, first: a, second: b, fraction: fraction)
            // A split with one child is not a split: it collapses, which is what makes the
            // tree shrink back rather than accumulating empty containers.
            case let (.some(only), nil), let (nil, .some(only)):
                return only
            case (nil, nil):
                return nil
            }
        }
    }

    private static func map(_ node: Node, _ transform: (Node) -> Node) -> Node {
        let mapped = transform(node)
        guard case let .split(id, axis, first, second, fraction) = mapped else { return mapped }
        return .split(
            id: id,
            axis: axis,
            first: map(first, transform),
            second: map(second, transform),
            fraction: fraction
        )
    }
}
