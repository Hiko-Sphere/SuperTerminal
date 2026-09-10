import Foundation

/// A picture behind the terminal — the record, not the pixels (D-077).
///
/// The photograph lives in ``BackdropStore`` as two files; this is the few hundred bytes that
/// describe it. That separation is not tidiness: ``TerminalTheme`` is `Equatable` and drives a
/// `didSet` in `TerminalRenderView`, and `updateUIView` runs on every chunk of output, so
/// anything travelling that path is compared on every keystroke. A record with no pixels can be.
///
/// What is *not* here is an opacity. The dimming is solved at bake time from the picture's own
/// measured extremes and the theme's background, because the dim that keeps Midnight legible is
/// not the dim that keeps Daylight legible — a stored alpha would quietly mean something
/// different after a light/dark switch.
struct Backdrop: Codable, Equatable, Sendable {
    var id: UUID

    /// How much contrast the picture is allowed to cost, named rather than dialled.
    var strength: Strength

    /// Extra dimming on top of what was solved, 0 to 0.5. Only ever *added*: a person may
    /// prefer a quieter picture, and may not talk the app below the contract.
    var extraDimming: Double

    /// Blur, applied when the picture is imported and re-applied from the unblurred master when
    /// this changes — never per frame, and never on top of an already blurred image.
    var softness: Double

    var placement: Placement

    /// The channel-wise maximum over the picture's tile means, measured at import.
    ///
    /// Channel-wise, and of tile *means* — not the brightest tile by luminance, which is not a
    /// valid bound because luminance ordering does not imply channel-wise ordering, and not
    /// per-pixel extremes, because one white pixel under a glyph stroke must not decide whether
    /// a whole screen of text can be read.
    var ceilingRGB: RGBColor
    /// The channel-wise minimum over the same tile means. A dark theme is bound by the ceiling
    /// and a light theme by the floor, and the contract is on every tile, so both are solved.
    var floorRGB: RGBColor

    var pixelWidth: Int
    var pixelHeight: Int

    enum Strength: String, Codable, CaseIterable, Sendable, Identifiable {
        case subtle
        case balanced
        case bold

        var id: String { rawValue }

        /// The most a picture may divide the theme's contrast by.
        var factor: Double {
            switch self {
            case .subtle: 1.10
            case .balanced: 1.25
            case .bold: 1.40
            }
        }

        var title: String {
            switch self {
            case .subtle: String(localized: "Subtle")
            case .balanced: String(localized: "Balanced")
            case .bold: String(localized: "Bold")
            }
        }

        /// What it costs, in the only terms that can be proved: the share of this theme's
        /// contrast the text keeps. Never "AA compliant" — the claim is bounded degradation.
        var consequence: String {
            let kept = Int((100 / factor).rounded())
            return String(
                localized: "Text keeps about \(kept)% of this theme's contrast.",
                comment: "Explains what a backdrop strength costs. The placeholder is a percentage."
            )
        }
    }

    enum Placement: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Fills the window, cropping whichever axis overflows. What a wallpaper does.
        case fill
        /// The whole picture, letterboxed against the theme's background colour.
        case fit

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fill: String(localized: "Fill")
            case .fit: String(localized: "Fit")
            }
        }
    }

    static let extraDimmingRange: ClosedRange<Double> = 0 ... 0.5
    static let softnessRange: ClosedRange<Double> = 0 ... 1

    /// Decodes a record written by a build that did not have every field yet, rather than
    /// throwing away someone's wallpaper because a version added a control.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        strength = try values.decodeIfPresent(Strength.self, forKey: .strength) ?? .balanced
        extraDimming = try values.decodeIfPresent(Double.self, forKey: .extraDimming) ?? 0
        softness = try values.decodeIfPresent(Double.self, forKey: .softness) ?? 0
        placement = try values.decodeIfPresent(Placement.self, forKey: .placement) ?? .fill
        ceilingRGB = try values.decode(RGBColor.self, forKey: .ceilingRGB)
        floorRGB = try values.decode(RGBColor.self, forKey: .floorRGB)
        pixelWidth = try values.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0
        pixelHeight = try values.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
    }

    init(
        id: UUID,
        strength: Strength = .balanced,
        extraDimming: Double = 0,
        softness: Double = 0,
        placement: Placement = .fill,
        ceilingRGB: RGBColor,
        floorRGB: RGBColor,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.strength = strength
        self.extraDimming = extraDimming
        self.softness = softness
        self.placement = placement
        self.ceilingRGB = ceilingRGB
        self.floorRGB = floorRGB
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
