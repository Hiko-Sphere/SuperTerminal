import STTerminal
import SwiftUI
import UIKit

/// A terminal colour scheme.
///
/// Themes are data, not code, so a user-defined theme is the same thing as a built-in
/// one. The 16 ANSI colours are stored explicitly rather than derived, because remote
/// programs address them by index and expect the classic meanings — colour 1 is "error
/// red" to every program that has ever printed a diagnostic.
public struct TerminalTheme: Sendable, Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let background: RGBColor
    public let foreground: RGBColor
    public let cursor: RGBColor
    public let selection: RGBColor
    /// ANSI 0–7 followed by their bright counterparts 8–15.
    public let ansi: [RGBColor]
    /// Whether this theme is meant for a light or dark appearance, so the app can pick a
    /// sensible default that matches the system.
    public let appearance: Appearance

    public enum Appearance: String, Sendable, Codable {
        case light
        case dark
    }

    public init(
        id: String,
        name: String,
        background: RGBColor,
        foreground: RGBColor,
        cursor: RGBColor,
        selection: RGBColor,
        ansi: [RGBColor],
        appearance: Appearance
    ) {
        precondition(ansi.count == 16, "a terminal theme needs all 16 ANSI colours")
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
        self.appearance = appearance
    }

    /// Resolves a terminal colour to something drawable.
    ///
    /// The 256-colour cube and greyscale ramp are computed rather than stored: they are
    /// defined by a formula that every terminal agrees on, and a 240-entry table would be
    /// 240 chances to typo one.
    public func resolve(_ color: TerminalColor, isForeground: Bool, bold: Bool) -> RGBColor {
        switch color {
        case .default:
            return isForeground ? foreground : background
        case let .rgb(red, green, blue):
            return RGBColor(red: red, green: green, blue: blue)
        case let .indexed(index):
            let value = Int(index)
            if value < 8 {
                // Bold text historically brightened the colour. Programs still rely on
                // it for emphasis, so honour it for the first eight only.
                return ansi[bold && isForeground ? value + 8 : value]
            }
            if value < 16 { return ansi[value] }
            if value < 232 {
                let offset = value - 16
                let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
                return RGBColor(
                    red: steps[(offset / 36) % 6],
                    green: steps[(offset / 6) % 6],
                    blue: steps[offset % 6]
                )
            }
            let grey = UInt8(clamping: 8 + (value - 232) * 10)
            return RGBColor(red: grey, green: grey, blue: grey)
        }
    }
}

public struct RGBColor: Sendable, Equatable, Hashable, Codable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    public var swiftUIColor: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

public extension TerminalTheme {
    /// The default dark theme. Its own palette rather than a copy of any product's:
    /// a near-neutral ink background with colours chosen to stay distinguishable at
    /// small sizes.
    static let midnight = TerminalTheme(
        id: "midnight",
        name: "Midnight",
        background: RGBColor(hex: 0x11131A),
        foreground: RGBColor(hex: 0xD7DAE3),
        cursor: RGBColor(hex: 0x6FA8FF),
        selection: RGBColor(hex: 0x2A3346),
        ansi: [
            RGBColor(hex: 0x1B1E27), RGBColor(hex: 0xE06C75), RGBColor(hex: 0x76C08A),
            RGBColor(hex: 0xD8A657), RGBColor(hex: 0x6FA8FF), RGBColor(hex: 0xC08BE0),
            RGBColor(hex: 0x56B6C2), RGBColor(hex: 0xABB2BF),
            RGBColor(hex: 0x4B5263), RGBColor(hex: 0xFF8189), RGBColor(hex: 0x8CE0A0),
            RGBColor(hex: 0xF0C070), RGBColor(hex: 0x8CBCFF), RGBColor(hex: 0xD5A5F0),
            RGBColor(hex: 0x6FD2DE), RGBColor(hex: 0xE6E9F0),
        ],
        appearance: .dark
    )

    /// A light theme with enough contrast to stay readable outdoors, which is where a
    /// phone actually gets used.
    static let daylight = TerminalTheme(
        id: "daylight",
        name: "Daylight",
        background: RGBColor(hex: 0xFBFBFD),
        foreground: RGBColor(hex: 0x21242C),
        cursor: RGBColor(hex: 0x1E62C8),
        selection: RGBColor(hex: 0xCFE0F7),
        ansi: [
            RGBColor(hex: 0x2E3138), RGBColor(hex: 0xC0392B), RGBColor(hex: 0x1E7A3C),
            RGBColor(hex: 0x9A6700), RGBColor(hex: 0x1E62C8), RGBColor(hex: 0x8A3FBF),
            RGBColor(hex: 0x0E7490), RGBColor(hex: 0x5A6070),
            RGBColor(hex: 0x767C8A), RGBColor(hex: 0xE04B3A), RGBColor(hex: 0x2A9D53),
            RGBColor(hex: 0xB88400), RGBColor(hex: 0x2F7BE0), RGBColor(hex: 0xA455D8),
            RGBColor(hex: 0x1594B4), RGBColor(hex: 0x2E3138),
        ],
        appearance: .light
    )

    /// A high-contrast theme for the accessibility setting of the same name.
    static let highContrast = TerminalTheme(
        id: "high-contrast",
        name: "High Contrast",
        background: RGBColor(hex: 0x000000),
        foreground: RGBColor(hex: 0xFFFFFF),
        cursor: RGBColor(hex: 0xFFFF00),
        selection: RGBColor(hex: 0x0050B0),
        ansi: [
            RGBColor(hex: 0x000000), RGBColor(hex: 0xFF5C5C), RGBColor(hex: 0x4CE04C),
            RGBColor(hex: 0xFFD24C), RGBColor(hex: 0x5CA8FF), RGBColor(hex: 0xE07CFF),
            RGBColor(hex: 0x4CE0E0), RGBColor(hex: 0xE8E8E8),
            RGBColor(hex: 0x8A8A8A), RGBColor(hex: 0xFF8C8C), RGBColor(hex: 0x8CFF8C),
            RGBColor(hex: 0xFFE68C), RGBColor(hex: 0x8CC8FF), RGBColor(hex: 0xF0B4FF),
            RGBColor(hex: 0x8CFFFF), RGBColor(hex: 0xFFFFFF),
        ],
        appearance: .dark
    )

    static let builtIn: [TerminalTheme] = [.midnight, .daylight, .highContrast]
}
