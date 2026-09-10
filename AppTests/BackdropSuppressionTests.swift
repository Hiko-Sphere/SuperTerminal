import Foundation
import Testing

@testable import ApexTerminal

/// When the wallpaper is not shown, and whether the person is told (D-077).
///
/// Reduce Transparency, Increase Contrast and Differentiate Without Colour are all requests for
/// fewer things behind text. A fainter photograph is still a photograph behind text, so the
/// picture is turned **off** rather than dimmed further — and something on screen has to say so,
/// or a person who chose a picture sees no picture and nothing connects the two.
@Suite("Backdrop suppression")
@MainActor
struct BackdropSuppressionTests {
    private var backdrop: Backdrop {
        Backdrop(
            id: UUID(),
            ceilingRGB: RGBColor(hex: 0xFFFFFF),
            floorRGB: RGBColor(hex: 0x000000),
            pixelWidth: 100,
            pixelHeight: 100
        )
    }

    @Test("Each of the three accessibility settings takes the picture away")
    func eachSettingSuppresses() {
        let resolver = BackdropResolver()
        #expect(resolver.backdrop(backdrop, reduceTransparency: true, increaseContrast: false, differentiateWithoutColor: false) == nil)
        #expect(resolver.backdrop(backdrop, reduceTransparency: false, increaseContrast: true, differentiateWithoutColor: false) == nil)
        #expect(resolver.backdrop(backdrop, reduceTransparency: false, increaseContrast: false, differentiateWithoutColor: true) == nil)
        // And with none of them, the picture is shown.
        #expect(resolver.backdrop(backdrop, reduceTransparency: false, increaseContrast: false, differentiateWithoutColor: false) != nil)
    }

    @Test("Each one explains itself")
    func eachSettingSaysWhy() throws {
        let resolver = BackdropResolver()
        let reasons = [
            resolver.suppressionReason(reduceTransparency: true, increaseContrast: false, differentiateWithoutColor: false),
            resolver.suppressionReason(reduceTransparency: false, increaseContrast: true, differentiateWithoutColor: false),
            resolver.suppressionReason(reduceTransparency: false, increaseContrast: false, differentiateWithoutColor: true),
        ]
        for reason in reasons {
            let text = try #require(reason)
            #expect(!text.isEmpty)
        }
        // Three different settings, three different sentences: "it is off for some reason" is not
        // an explanation anyone can act on.
        #expect(Set(reasons.compactMap { $0 }).count == 3)
        #expect(resolver.suppressionReason(reduceTransparency: false, increaseContrast: false, differentiateWithoutColor: false) == nil)
    }

    @Test("A per-host theme does not survive Increase Contrast")
    func contrastBeatsAHostTheme() {
        // This failed before D-077. `TerminalThemeResolver`'s own docstring says the high-contrast
        // theme is chosen automatically so that nobody has to discover a terminal-specific
        // setting — but the per-host override returned first, so anyone who had ever picked a
        // theme for one server stopped getting high contrast on it.
        let settings = AppSettings(defaults: UserDefaults(suiteName: "contrast-\(UUID())")!)
        let resolved = TerminalThemeResolver(settings: settings).theme(
            colorScheme: .dark,
            differentiateWithoutColor: false,
            increaseContrast: true,
            hostOverride: "daylight"
        )
        #expect(resolved.id == "high-contrast")
    }

    @Test("A record written before a control existed still decodes")
    func anOlderRecordSurvives() throws {
        // Someone's wallpaper must not vanish because a later version added a setting.
        let json = """
        {
          "id": "5D0A6C1E-6C5E-4E0E-9E4C-0E9B1F2A3B4C",
          "ceilingRGB": { "red": 240, "green": 240, "blue": 240 },
          "floorRGB": { "red": 16, "green": 16, "blue": 16 }
        }
        """
        let decoded = try JSONDecoder().decode(Backdrop.self, from: Data(json.utf8))
        #expect(decoded.strength == .balanced)
        #expect(decoded.placement == .fill)
        #expect(decoded.extraDimming == 0)
        #expect(decoded.softness == 0)
        #expect(decoded.ceilingRGB.red == 240)
    }
}
