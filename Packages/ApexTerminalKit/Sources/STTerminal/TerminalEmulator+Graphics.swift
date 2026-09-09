import Foundation

/// Pictures, and where they go in the grid (D-065).
///
/// Three protocols end in the same place. Sixel arrives as a DCS string, Kitty's as an APC
/// one, and iTerm2's as OSC 1337; each is decoded to pixels, filed in the screen's store, and
/// drawn over whole cells — the grid has no smaller unit, so a picture is stretched to the
/// cells it was given and each line it covers keeps a strip of it.
extension TerminalEmulator {
    /// How big one cell is in pixels, as the view measured it.
    ///
    /// The emulator cannot measure a font and the number of cells a picture covers depends on
    /// it, so the view says. The default is a plausible cell rather than a correct one: a
    /// picture that arrives before the first layout is better slightly the wrong size than
    /// absent.
    public struct CellSize: Sendable, Equatable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = max(1, width)
            self.height = max(1, height)
        }

        /// A cell about the size of 13-point Menlo, which is this app's default.
        public static let unmeasured = CellSize(width: 8, height: 17)
    }

    // MARK: - Sixel

    mutating func applySixel(_ sequence: DCSSequence) {
        guard let image = try? SixelDecoder.decode(
            Array(sequence.payload.utf8),
            parameters: sequence.parameters
        ) else { return }
        place(image, id: nil, columns: nil, rows: nil, movesCursorBelow: true)
    }

    // MARK: - Kitty

    mutating func applyKitty(_ payload: String, emit: (TerminalEvent) -> Void) {
        guard let command = KittyCommand.parse(Array(payload.utf8)) else { return }
        switch kitty.handle(command) {
        case .none:
            break
        case let .store(image, id):
            withActiveScreen { screen, _ in screen.images.insert(image, preferredID: id) }
        case let .display(id, columns, rows, movesCursor):
            guard activeScreen.images[id] != nil else {
                emit(.respond(Data("\u{1B}_Gi=\(id);ENOENT:no such image\u{1B}\\".utf8)))
                return
            }
            place(storedID: id, columns: columns, rows: rows, movesCursorBelow: movesCursor)
        case let .storeAndDisplay(image, id, columns, rows, movesCursor):
            place(image, id: id, columns: columns, rows: rows, movesCursorBelow: movesCursor)
        case let .delete(id):
            withActiveScreen { screen, _ in
                if let id { screen.removeImage(id) } else { screen.removeAllImages() }
            }
        case let .respond(body):
            emit(.respond(Data("\u{1B}_G\(body)\u{1B}\\".utf8)))
        }
    }

    // MARK: - iTerm2

    mutating func applyITerm2(_ payload: String) {
        guard let file = ITerm2File.parse(payload) else { return }
        // Without `inline=1` this asks the terminal to save a file the server chose onto the
        // device. Nothing here does that. A program that wants to show a picture says so.
        guard file.isInline, !file.data.isEmpty else { return }
        guard let image = try? SystemImageDecoder.decode(file.data) else { return }
        place(
            image,
            id: nil,
            columns: cells(for: file.width, per: cellSize.width, of: activeScreen.columns),
            rows: cells(for: file.height, per: cellSize.height, of: activeScreen.rows),
            movesCursorBelow: file.movesCursor
        )
    }

    /// iTerm2's sizes come in four spellings; the grid needs cells.
    func cells(for size: ITerm2File.Size, per cell: Int, of total: Int) -> Int? {
        switch size {
        case .auto: nil
        case let .cells(count): max(1, count)
        case let .pixels(count): max(1, (count + cell - 1) / cell)
        case let .percent(percent): max(1, total * max(0, min(percent, 100)) / 100)
        }
    }

    // MARK: - Placing

    mutating func place(
        _ image: TerminalImage,
        id: Int?,
        columns: Int?,
        rows: Int?,
        movesCursorBelow: Bool
    ) {
        var stored = 0
        withActiveScreen { screen, _ in stored = screen.images.insert(image, preferredID: id) }
        place(storedID: stored, columns: columns, rows: rows, movesCursorBelow: movesCursorBelow)
    }

    mutating func place(storedID id: Int, columns: Int?, rows: Int?, movesCursorBelow: Bool) {
        guard let image = activeScreen.images[id] else { return }
        let wide = columns ?? max(1, (image.width + cellSize.width - 1) / cellSize.width)
        let tall = rows ?? max(1, (image.height + cellSize.height - 1) / cellSize.height)
        withActiveScreen { screen, _ in
            screen.placeImage(id: id, columns: wide, rows: tall)
            guard movesCursorBelow else { return }
            // Where every terminal leaves it: the start of the line under the picture, so
            // whatever the program prints next does not land on top of what it just drew.
            if screen.cursor.row >= screen.scrollBottom {
                screen.scrollUp(1)
                screen.cursor.row = screen.scrollBottom
            } else {
                screen.cursor.row += 1
            }
            screen.cursor.column = 0
        }
    }
}
