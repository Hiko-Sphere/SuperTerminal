import Foundation

extension TerminalEmulator {
    /// Mutates whichever screen is currently active.
    mutating func withActiveScreenPublic(_ body: (inout TerminalScreen) -> Void) {
        if modes.alternateScreen {
            body(&alternateScreen)
        } else {
            body(&screen)
        }
    }

    var currentHyperlink: Int? { currentHyperlinkID }

    var titleValue: String { title }

    mutating func setTitle(_ newTitle: String) { title = newTitle }

    mutating func setCurrentHyperlink(_ identifier: Int?) { currentHyperlinkID = identifier }

    mutating func registerHyperlink(_ link: TerminalHyperlink) {
        let identifier = nextHyperlinkID
        nextHyperlinkID += 1
        hyperlinks[identifier] = link
        currentHyperlinkID = identifier
    }

    mutating func tabForward() {
        let stops = tabStops
        withActiveScreenPublic { screen in
            let next = stops.filter { $0 > screen.cursor.column }.min() ?? (screen.columns - 1)
            screen.cursor.column = min(next, screen.columns - 1)
            screen.pendingWrap = false
        }
    }

    mutating func tabBackward() {
        let stops = tabStops
        withActiveScreenPublic { screen in
            let previous = stops.filter { $0 < screen.cursor.column }.max() ?? 0
            screen.cursor.column = max(0, previous)
            screen.pendingWrap = false
        }
    }

    mutating func clearAllTabStops() { tabStops.removeAll() }

    mutating func removeTabStop(at column: Int) { tabStops.remove(column) }

    mutating func saveCursorState() {
        savedCursor = activeScreen.cursor
        savedAttributes = activeScreen.attributes
    }

    mutating func restoreCursorState() {
        if let cursor = savedCursor {
            withActiveScreenPublic { $0.cursor = cursor }
        }
        if let attributes = savedAttributes {
            withActiveScreenPublic { $0.attributes = attributes }
        }
    }

    /// Switches between the primary and alternate buffers.
    ///
    /// The alternate buffer is created fresh on entry and simply abandoned on exit, so
    /// the primary buffer — and the user's scrollback — comes back exactly as it was.
    /// That is what makes quitting `less` or `vim` leave the shell's output intact.
    mutating func switchAlternateScreen(to enable: Bool, clearOnEnter: Bool, saveCursor: Bool) {
        guard enable != modes.alternateScreen else { return }
        if enable {
            if saveCursor { saveCursorState() }
            alternateScreen = TerminalScreen(
                columns: screen.columns,
                rows: screen.rows,
                scrollbackLimit: 0
            )
            if !clearOnEnter { alternateScreen.attributes = screen.attributes }
            modes.alternateScreen = true
        } else {
            modes.alternateScreen = false
            if saveCursor { restoreCursorState() }
        }
    }

    mutating func applyOSC(command: Int, payload: String, emit: (TerminalEvent) -> Void) {
        switch command {
        case 0, 1, 2:
            // 0 sets both icon and window title, 1 the icon name, 2 the window title.
            // Control characters are stripped: the title is shown in the app's own
            // chrome, and a terminal that passes escape sequences through into its UI is
            // a classic injection route.
            let sanitised = String(payload.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
            title = String(sanitised.prefix(512))
            emit(.title(title))
        case 8:
            applyHyperlink(payload: payload)
        default:
            break
        }
    }

    /// OSC 8 — `OSC 8 ; params ; URI ST`. An empty URI ends the current link.
    private mutating func applyHyperlink(payload: String) {
        let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            currentHyperlinkID = nil
            return
        }
        let uri = String(parts[1])
        guard !uri.isEmpty else {
            currentHyperlinkID = nil
            return
        }
        // Only schemes that are safe to hand to the system opener are recorded. Anything
        // else — `javascript:`, `file:`, a custom app scheme — is dropped rather than
        // stored, so no later part of the UI can be tricked into opening it.
        let lowercased = uri.lowercased()
        let allowed = ["http://", "https://", "mailto:", "ftp://", "ftps://"]
        guard allowed.contains(where: { lowercased.hasPrefix($0) }), uri.count <= 2048 else {
            currentHyperlinkID = nil
            return
        }
        var identifier: String?
        for field in parts[0].split(separator: ":") where field.hasPrefix("id=") {
            identifier = String(field.dropFirst(3))
        }
        registerHyperlink(TerminalHyperlink(id: identifier, url: uri))
    }
}
