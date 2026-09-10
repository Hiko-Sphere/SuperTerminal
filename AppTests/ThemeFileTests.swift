import CoreGraphics
import Foundation
import STCore
import Testing

@testable import ApexTerminal

/// Reading and writing `.itermcolors`, the only palette format every terminal already speaks
/// (D-079).
///
/// The fixtures below are the actual XML a terminal writes, not a dictionary assembled in
/// memory: the failure this format invites is a reader that works on the plist it was tested
/// against and not on the file on disk — a `<real>` read as a `<string>`, a colour space
/// ignored, a key spelled differently.
@Suite("iTerm colour files")
struct ThemeFileTests {
    /// A complete file in the shape iTerm 3 writes: sixteen ANSI colours plus the four roles
    /// this app uses, every component a `<real>`, every colour tagged sRGB.
    private func file(
        colourSpace: String? = "sRGB",
        omitting: Set<String> = [],
        componentsAsStrings: Bool = false,
        ansi: [(Double, Double, Double)]? = nil,
        background: (Double, Double, Double) = (0.05, 0.06, 0.09)
    ) -> Data {
        func colour(_ red: Double, _ green: Double, _ blue: Double) -> String {
            let value: (Double) -> String = { componentsAsStrings ? "<string>\($0)</string>" : "<real>\($0)</real>" }
            let space = colourSpace.map { "<key>Color Space</key><string>\($0)</string>" } ?? ""
            return """
            <dict>\(space)
            <key>Alpha Component</key><real>1</real>
            <key>Red Component</key>\(value(red))
            <key>Green Component</key>\(value(green))
            <key>Blue Component</key>\(value(blue))
            </dict>
            """
        }
        var body = ""
        let palette = ansi ?? (0 ..< 16).map { (Double($0) / 15, 0.25, 0.5) }
        for (index, rgb) in palette.enumerated() {
            body += "<key>Ansi \(index) Color</key>\(colour(rgb.0, rgb.1, rgb.2))\n"
        }
        let roles: [(String, (Double, Double, Double))] = [
            ("Background Color", background),
            ("Foreground Color", (0.85, 0.86, 0.88)),
            ("Cursor Color", (1, 0.75, 0)),
            ("Selection Color", (0.2, 0.3, 0.5)),
        ]
        for (key, rgb) in roles where !omitting.contains(key) {
            body += "<key>\(key)</key>\(colour(rgb.0, rgb.1, rgb.2))\n"
        }
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)</dict>
        </plist>
        """.utf8)
    }

    @Test("A file a terminal wrote becomes a theme")
    func reads() throws {
        let theme = try ITermColorsFile.theme(from: file(), named: "Deep Sea")

        #expect(theme.name == "Deep Sea")
        #expect(theme.ansi.count == 16)
        // 0.05 × 255 = 12.75, which rounds to 13. A reader that truncated would give 12.
        #expect(theme.background == RGBColor(red: 13, green: 15, blue: 23))
        #expect(theme.foreground == RGBColor(red: 217, green: 219, blue: 224))
        #expect(theme.cursor == RGBColor(red: 255, green: 191, blue: 0))
        #expect(theme.selection == RGBColor(red: 51, green: 77, blue: 128))
        #expect(theme.ansi[0] == RGBColor(red: 0, green: 64, blue: 128))
        #expect(theme.ansi[15] == RGBColor(red: 255, green: 64, blue: 128))
        // An id of its own, so importing a palette can never collide with a built-in theme.
        #expect(theme.isCustom)
        #expect(!TerminalTheme.builtIn.map(\.id).contains(theme.id))
    }

    @Test("Two imports of the same file are two themes, not one")
    func importsAreDistinct() throws {
        let first = try ITermColorsFile.theme(from: file(), named: "Deep Sea")
        let second = try ITermColorsFile.theme(from: file(), named: "Deep Sea")
        #expect(first.id != second.id)
    }

    @Test("Components written as strings are read as numbers")
    func stringComponents() throws {
        // Some generators write <string>0.5</string>. A reader that only accepts NSNumber
        // rejects those files with "missing colour 0", which is not what is wrong with them.
        let theme = try ITermColorsFile.theme(from: file(componentsAsStrings: true), named: "S")
        #expect(theme.background == RGBColor(red: 13, green: 15, blue: 23))
    }

    @Test("A file written before colour spaces existed still reads")
    func noColourSpace() throws {
        let theme = try ITermColorsFile.theme(from: file(colourSpace: nil), named: "Old")
        #expect(theme.background == RGBColor(red: 13, green: 15, blue: 23))
    }

    @Test("A P3 file is converted rather than read as if it were sRGB")
    func displayP3IsConverted() throws {
        // Driven from the other end so the assertion cannot be tautological: take a colour
        // known in sRGB, ask Core Graphics what a Display P3 file would have to contain to
        // *mean* that colour, put those components in the file — and require the reader to
        // hand the original colour back.
        let wanted = RGBColor(red: 214, green: 90, blue: 60)
        let asP3 = try #require(components(of: wanted, in: CGColorSpace.displayP3))

        let converted = try ITermColorsFile.theme(
            from: file(colourSpace: "P3", ansi: Array(repeating: asP3, count: 16)),
            named: "Wide"
        )
        // Within one 8-bit step: two colour-space conversions and a round to integers.
        #expect(abs(Int(converted.ansi[0].red) - Int(wanted.red)) <= 1)
        #expect(abs(Int(converted.ansi[0].green) - Int(wanted.green)) <= 1)
        #expect(abs(Int(converted.ansi[0].blue) - Int(wanted.blue)) <= 1)

        // The same numbers with the space claiming sRGB must give a visibly different
        // colour — which is what proves the field is consulted rather than ignored.
        let ignored = try ITermColorsFile.theme(
            from: file(colourSpace: "sRGB", ansi: Array(repeating: asP3, count: 16)),
            named: "Narrow"
        )
        #expect(ignored.ansi[0] != converted.ansi[0])
        #expect(Int(ignored.ansi[0].green) - Int(converted.ansi[0].green) > 4)
    }

    /// What `colour` looks like written in `space`, as 0…1 components.
    private func components(of colour: RGBColor, in space: CFString) -> (Double, Double, Double)? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let target = CGColorSpace(name: space),
              let converted = CGColor(colorSpace: sRGB, components: [
                  Double(colour.red) / 255, Double(colour.green) / 255, Double(colour.blue) / 255, 1,
              ])?.converted(to: target, intent: .relativeColorimetric, options: nil),
              let parts = converted.components, parts.count >= 3
        else { return nil }
        return (Double(parts[0]), Double(parts[1]), Double(parts[2]))
    }

    @Test("Which side of light and dark is measured, not named")
    func appearanceIsMeasured() throws {
        // The same name for both. A file carries no light/dark flag at all, and its name is
        // not evidence — "Solarized Light" and "Solarized Dark" differ by a word.
        let ink = try ITermColorsFile.theme(from: file(background: (0.05, 0.06, 0.09)), named: "Anything")
        let paper = try ITermColorsFile.theme(from: file(background: (0.96, 0.96, 0.94)), named: "Anything")
        #expect(ink.appearance == .dark)
        #expect(paper.appearance == .light)
    }

    @Test("A file missing a colour says which one")
    func missingColour() {
        let data = file(omitting: ["Background Color"])
        #expect(throws: STError.self) {
            _ = try ITermColorsFile.theme(from: data, named: "Broken")
        }
        do {
            _ = try ITermColorsFile.theme(from: data, named: "Broken")
            Issue.record("a file with no background should not import")
        } catch let error as STError {
            #expect(error.category == .configuration)
            #expect(error.message.contains("background"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Something that is not a colour scheme is refused")
    func notAPlist() {
        #expect(throws: STError.self) {
            _ = try ITermColorsFile.theme(from: Data("not a plist at all".utf8), named: "X")
        }
        // A plist that is not a colour scheme is refused for the right reason: it parses, and
        // then has no colours in it.
        let empty = try! PropertyListSerialization.data(fromPropertyList: ["hello": "world"], format: .xml, options: 0)
        #expect(throws: STError.self) {
            _ = try ITermColorsFile.theme(from: empty, named: "X")
        }
    }

    @Test("A theme written out and read back is the same theme")
    func roundTrip() throws {
        let original = try ITermColorsFile.theme(from: file(), named: "Deep Sea")
        let written = try ITermColorsFile.data(for: original)
        let back = try ITermColorsFile.theme(from: written, named: "Deep Sea")

        #expect(back.background == original.background)
        #expect(back.foreground == original.foreground)
        #expect(back.cursor == original.cursor)
        #expect(back.selection == original.selection)
        #expect(back.ansi == original.ansi)
        #expect(back.appearance == original.appearance)
    }

    @Test("What is written is a property list a terminal can open")
    func writesRealPlist() throws {
        let written = try ITermColorsFile.data(for: .midnight)
        let root = try #require(
            PropertyListSerialization.propertyList(from: written, format: nil) as? [String: Any]
        )
        for index in 0 ..< 16 {
            let colour = try #require(root["Ansi \(index) Color"] as? [String: Any])
            #expect(colour["Color Space"] as? String == "sRGB")
            #expect(colour["Red Component"] is NSNumber)
        }
        #expect(root["Background Color"] != nil)
        #expect(root["Foreground Color"] != nil)
    }
}
