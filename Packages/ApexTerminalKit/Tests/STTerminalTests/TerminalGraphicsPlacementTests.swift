import Foundation
import Testing

@testable import STTerminal

/// Where a picture goes once it has been decoded (D-065).
///
/// The decoders are tested against other implementations elsewhere. What is tested here is the
/// part that is this terminal's own: a picture occupies whole cells, scrolls with the text,
/// goes away when something writes over it, and cannot make a screen grow without bound.
@Suite("Pictures in the grid")
struct TerminalGraphicsPlacementTests {
    /// A one-band sixel, six pixels tall and twelve wide, in one colour.
    static let sixel = "\u{1B}P0;0;0q\"1;1;12;6#0;2;100;0;0#0!12~\u{1B}\\"

    static func emulator(columns: Int = 40, rows: Int = 10, cell: (Int, Int) = (6, 6)) -> TerminalEmulator {
        var emulator = TerminalEmulator(columns: columns, rows: rows)
        emulator.cellSize = TerminalEmulator.CellSize(width: cell.0, height: cell.1)
        return emulator
    }

    @Test("A sixel is drawn where the cursor is, in as many cells as it is pixels wide")
    func placesASixel() {
        var emulator = Self.emulator()
        _ = emulator.feed(Array(Self.sixel.utf8))

        let screen = emulator.activeScreen
        #expect(screen.images.count == 1)
        let slices = screen.lines[0].imageSlices
        #expect(slices.count == 1)
        // Twelve pixels across six-pixel cells is two columns; six pixels tall is one row.
        #expect(slices.first?.columns == 2)
        #expect(slices.first?.totalRows == 1)
        #expect(slices.first?.column == 0)
        // And the cursor is on the line below, which is where the next output belongs.
        #expect(screen.cursor.row == 1)
        #expect(screen.cursor.column == 0)
    }

    @Test("The cell size the view measured is what decides how many cells a picture takes")
    func cellSizeDecidesTheFootprint() {
        var small = Self.emulator(cell: (3, 3))
        _ = small.feed(Array(Self.sixel.utf8))
        // The same twelve-by-six picture in three-pixel cells is four columns and two rows.
        #expect(small.activeScreen.lines[0].imageSlices.first?.columns == 4)
        #expect(small.activeScreen.lines[0].imageSlices.first?.totalRows == 2)
        #expect(small.activeScreen.lines[1].imageSlices.first?.imageRow == 1)
    }

    @Test("A picture scrolls with the text it was drawn beside")
    func scrollsWithTheText() {
        var emulator = Self.emulator(rows: 4)
        _ = emulator.feed(Array(Self.sixel.utf8))
        #expect(emulator.activeScreen.lines[0].imageSlices.count == 1)

        // Four newlines push the picture's line off the top and into history.
        _ = emulator.feed(Array("\r\n\r\n\r\n\r\n".utf8))
        let screen = emulator.activeScreen
        #expect(screen.lines.allSatisfy { $0.imageSlices.isEmpty }, "it has left the visible screen")
        #expect(screen.scrollback.contains { !$0.imageSlices.isEmpty }, "and it is in the history")
    }

    @Test("Writing over a picture erases the part that was written over")
    func writingErasesWhatItCovers() {
        var emulator = Self.emulator()
        // A picture eight columns wide, so there is a middle to write into.
        _ = emulator.feed(Array("\u{1B}P0;0;0q\"1;1;48;6#0;2;100;0;0#0!48~\u{1B}\\".utf8))
        #expect(emulator.activeScreen.lines[0].imageSlices.first?.columns == 8)

        // Back to the picture's line and one character into its middle. The flush is not
        // ceremony: the parser holds the last character in case a combining mark follows it.
        _ = emulator.feed(Array("\u{1B}[1;4Hx".utf8))
        _ = emulator.flush()
        let slices = emulator.activeScreen.lines[0].imageSlices
        // The strip is split in two around the character, rather than the whole row going.
        #expect(slices.count == 2)
        #expect(slices.map(\.columns) == [3, 4])
        #expect(slices.last?.imageColumn == 4, "the right half still knows which part of the picture it is")
    }

    @Test("Erasing a line takes its pictures with it")
    func erasingTakesThePicture() {
        var emulator = Self.emulator()
        _ = emulator.feed(Array(Self.sixel.utf8))
        _ = emulator.feed(Array("\u{1B}[1;1H\u{1B}[2K".utf8))
        #expect(emulator.activeScreen.lines[0].imageSlices.isEmpty)
    }

    @Test("A picture drawn by a full-screen program goes when the program does")
    func alternateScreenKeepsItsOwn() {
        var emulator = Self.emulator()
        _ = emulator.feed(Array("\u{1B}[?1049h".utf8))
        _ = emulator.feed(Array(Self.sixel.utf8))
        #expect(emulator.activeScreen.images.count == 1)
        _ = emulator.feed(Array("\u{1B}[?1049l".utf8))
        #expect(emulator.activeScreen.images.count == 0, "the shell's screen never had it")
    }

    @Test("A narrower window drops the pictures rather than re-slicing them")
    func widthChangesDropPictures() {
        var emulator = Self.emulator()
        _ = emulator.feed(Array(Self.sixel.utf8))
        #expect(emulator.activeScreen.images.count == 1)

        // Fewer rows rewraps nothing, so the picture stays.
        emulator.resize(columns: 40, rows: 8)
        #expect(emulator.activeScreen.images.count == 1, "a height change does not rewrap")

        // A narrower screen rebuilds every line from its cells, and a strip is tied to the
        // columns it covered. The pixels go too, rather than sitting in the store unreferenced.
        emulator.resize(columns: 20, rows: 8)
        #expect(emulator.activeScreen.images.count == 0)
        #expect(emulator.activeScreen.lines.allSatisfy { $0.imageSlices.isEmpty })
    }

    @Test("Kitty is answered, and a picture it stores can be shown later")
    func kittyStoresThenDisplays() {
        var emulator = Self.emulator()
        // Six red-ish pixels, 3×2, stored under id 9 and not displayed.
        let payload = Data([UInt8](repeating: 200, count: 18)).base64EncodedString()
        _ = emulator.feed(Array("\u{1B}_Ga=t,f=24,s=3,v=2,i=9;\(payload)\u{1B}\\".utf8))
        #expect(emulator.activeScreen.images.count == 1)
        #expect(emulator.activeScreen.lines.allSatisfy { $0.imageSlices.isEmpty }, "storing does not draw")

        _ = emulator.feed(Array("\u{1B}_Ga=p,i=9\u{1B}\\".utf8))
        #expect(emulator.activeScreen.lines[0].imageSlices.first?.imageID == 9)
    }

    @Test("`C=1` means the cursor stays where it was, and its absence means it does not")
    func kittyHonoursTheCursorPolicy() {
        let payload = Data([UInt8](repeating: 200, count: 18)).base64EncodedString()

        var moves = Self.emulator()
        _ = moves.feed(Array("\u{1B}_Ga=T,f=24,s=3,v=2;\(payload)\u{1B}\\".utf8))
        #expect(moves.activeScreen.cursor.row == 1, "the cursor belongs under the picture")
        #expect(moves.activeScreen.cursor.column == 0)

        var stays = Self.emulator()
        _ = stays.feed(Array("\u{1B}_Ga=T,f=24,s=3,v=2,C=1;\(payload)\u{1B}\\".utf8))
        #expect(stays.activeScreen.cursor.row == 0, "C=1 asks for the cursor to be left alone")
        #expect(stays.activeScreen.cursor.column == 0)
        #expect(!stays.activeScreen.lines[0].imageSlices.isEmpty, "and the picture is still drawn")
    }

    @Test("Displaying a picture that was never sent says so rather than drawing nothing")
    func kittyAnswersForAMissingImage() {
        var emulator = Self.emulator()
        let events = emulator.feed(Array("\u{1B}_Ga=p,i=404\u{1B}\\".utf8))
        let responses = events.compactMap { event -> String? in
            guard case let .respond(data) = event else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        #expect(responses.contains { $0.contains("ENOENT") })
    }

    @Test("iTerm2 draws only what says it is inline")
    func iTerm2NeedsInline() {
        // The same PNG twice: once asking to be shown, once asking to be saved.
        let png = KittyGraphicsTests.tinyPNG
        var shown = Self.emulator()
        _ = shown.feed(Array("\u{1B}]1337;File=inline=1;size=6:\(png)\u{07}".utf8))
        #expect(shown.activeScreen.images.count == 1)

        var saved = Self.emulator()
        _ = saved.feed(Array("\u{1B}]1337;File=name=Zg==;size=6:\(png)\u{07}".utf8))
        #expect(saved.activeScreen.images.count == 0, "a download request is not a picture")
    }

    @Test("A terminal cannot be made to hold pictures without limit")
    func theStoreIsBounded() {
        var store = TerminalImageStore()
        // Each of these is a megabyte; the budget is 64.
        let megabyte = TerminalImage(width: 512, height: 512, pixels: [UInt8](repeating: 0, count: 512 * 512 * 4))
        for _ in 0 ..< 100 { store.insert(megabyte) }
        #expect(store.byteCount <= TerminalImageStore.maximumBytes)
        #expect(store.count < 100)
    }
}
