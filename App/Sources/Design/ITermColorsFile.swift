import CoreGraphics
import Foundation
import STCore
import UniformTypeIdentifiers

/// Reads and writes iTerm2's `.itermcolors` palette files.
///
/// This is the only palette format every terminal on every platform can already produce, so
/// it is how a palette somebody already has gets *into* this app — and how one made here
/// leaves again for their laptop. Nothing is bundled: shipping a collection of other people's
/// palettes would be shipping other people's work, and the point of the workshop is that the
/// colours are the user's own.
///
/// The file is an XML property list of colour dictionaries keyed by role:
///
///     Ansi 0 Color … Ansi 15 Color, Background Color, Foreground Color,
///     Cursor Color, Selection Color   (and several this app has no use for)
///
/// Each value carries `Red`/`Green`/`Blue Component` as 0…1 reals and, since iTerm 3, a
/// `Color Space`. Files written before that have no space at all.
enum ITermColorsFile {
    static let fileExtension = "itermcolors"

    /// The type used for the import and export panels.
    ///
    /// `UTType(filenameExtension:)` invents a dynamic type when nothing on the device claims
    /// the extension, and a dynamic type still matches files that carry it — which is the
    /// normal case on a phone, where iTerm2 is not installed.
    static var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .propertyList
    }

    // MARK: - Reading

    /// - Parameter name: what to call the theme; the file itself carries no name, so the
    ///   caller passes the file's own (`Solarized Dark.itermcolors` → `Solarized Dark`).
    static func theme(from data: Data, named name: String) throws -> TerminalTheme {
        guard let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw STError(
                category: .configuration,
                message: String(localized: "That is not a colour-scheme file."),
                recoverySuggestion: String(localized: "Choose a file exported from a terminal as .itermcolors.")
            )
        }

        var ansi: [RGBColor] = []
        for index in 0 ..< 16 {
            guard let colour = colour(root["Ansi \(index) Color"]) else {
                throw STError(
                    category: .configuration,
                    message: String(localized: "That colour scheme is missing colour \(index)."),
                    recoverySuggestion: String(localized: "A terminal palette needs all sixteen ANSI colours. Export it again from the terminal it came from.")
                )
            }
            ansi.append(colour)
        }
        guard let background = colour(root["Background Color"]) else {
            throw STError(
                category: .configuration,
                message: String(localized: "That colour scheme has no background colour."),
                recoverySuggestion: String(localized: "Export it again from the terminal it came from.")
            )
        }
        // Everything below the background has a defensible fallback, so a file that omits it
        // still imports rather than being refused over a colour the user may never see.
        let foreground = colour(root["Foreground Color"]) ?? ansi[7]
        let cursor = colour(root["Cursor Color"]) ?? foreground
        let selection = colour(root["Selection Color"]) ?? ansi[4]

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return TerminalTheme(
            id: TerminalTheme.newCustomID(),
            name: trimmed.isEmpty ? String(localized: "Imported Theme") : trimmed,
            background: background,
            foreground: foreground,
            cursor: cursor,
            selection: selection,
            ansi: ansi,
            // Measured from the background rather than guessed from the file's name, which
            // is the only thing here that can actually be wrong: a palette called "light"
            // with an ink background would put the app's light/dark choice on the wrong side.
            appearance: TerminalTheme.appearance(forBackground: background)
        )
    }

    private static func colour(_ value: Any?) -> RGBColor? {
        guard let dictionary = value as? [String: Any],
              let red = component(dictionary["Red Component"]),
              let green = component(dictionary["Green Component"]),
              let blue = component(dictionary["Blue Component"])
        else { return nil }
        return convert(red: red, green: green, blue: blue, space: dictionary["Color Space"] as? String)
    }

    /// Real numbers arrive as `NSNumber` from an XML plist and as `String` from the handful
    /// of generators that write `<string>0.5</string>`.
    private static func component(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// Converts one colour into sRGB, which is the only space this app stores.
    ///
    /// `P3` goes through Core Graphics rather than through a matrix written here: colour
    /// conversion is exactly the sort of thing to take from the system framework that owns
    /// it. `Calibrated` — Apple's old generic RGB — is read as sRGB, which is what the
    /// format's own producers assume in practice; the two differ by less than the step
    /// between adjacent 8-bit values over most of the range, and no public `CGColorSpace`
    /// name on iOS spells the non-linear generic profile.
    private static func convert(red: Double, green: Double, blue: Double, space: String?) -> RGBColor {
        if let space, space.localizedCaseInsensitiveContains("p3"),
           let converted = displayP3(red: red, green: green, blue: blue) {
            return converted
        }
        return RGBColor(clamping: red, green, blue)
    }

    private static func displayP3(red: Double, green: Double, blue: Double) -> RGBColor? {
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let colour = CGColor(colorSpace: p3, components: [red, green, blue, 1]),
              let converted = colour.converted(to: sRGB, intent: .relativeColorimetric, options: nil),
              let components = converted.components, components.count >= 3
        else { return nil }
        // A P3 colour outside the sRGB gamut converts to components outside 0…1; clamping is
        // what makes the result a colour rather than a number.
        return RGBColor(clamping: Double(components[0]), Double(components[1]), Double(components[2]))
    }

    // MARK: - Writing

    /// The theme as an `.itermcolors` file, so a palette made here opens in the terminal on
    /// the user's laptop. Written in sRGB, stated explicitly rather than left to the reader
    /// to assume.
    static func data(for theme: TerminalTheme) throws -> Data {
        var root: [String: Any] = [:]
        for (index, colour) in theme.ansi.enumerated() {
            root["Ansi \(index) Color"] = dictionary(for: colour)
        }
        root["Background Color"] = dictionary(for: theme.background)
        root["Foreground Color"] = dictionary(for: theme.foreground)
        root["Cursor Color"] = dictionary(for: theme.cursor)
        root["Cursor Text Color"] = dictionary(for: theme.background)
        root["Selection Color"] = dictionary(for: theme.selection)
        root["Selected Text Color"] = dictionary(for: theme.foreground)
        root["Bold Color"] = dictionary(for: theme.foreground)
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    private static func dictionary(for colour: RGBColor) -> [String: Any] {
        [
            "Color Space": "sRGB",
            "Alpha Component": 1.0,
            "Red Component": Double(colour.red) / 255,
            "Green Component": Double(colour.green) / 255,
            "Blue Component": Double(colour.blue) / 255,
        ]
    }
}

extension RGBColor {
    /// A colour from 0…1 components, with anything outside brought back to the edge.
    init(clamping red: Double, _ green: Double, _ blue: Double) {
        func channel(_ value: Double) -> UInt8 {
            guard value.isFinite else { return 0 }
            return UInt8((value * 255).rounded().clamped(to: 0 ... 255))
        }
        self.init(red: channel(red), green: channel(green), blue: channel(blue))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
