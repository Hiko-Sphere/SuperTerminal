import Foundation

/// The arithmetic that keeps text readable over a photograph (D-077).
///
/// Pure: no UIKit, no actor, no I/O — so it can be checked against published constants rather
/// than eyeballed. Everything here is WCAG 2.1's relative luminance and contrast ratio, plus one
/// solve.
///
/// **The contract.** A picture is allowed to cost contrast, but a *bounded* amount. Writing
/// `b = Lbg + 0.05` for the theme background and `c = Lg + 0.05` for a tile of the finished
/// ground, require every cell-sized tile to satisfy
///
///     max(c / b, b / c) ≤ T
///
/// Then for **any** ink luminance `L`, writing `a = L + 0.05`, the ratio of "contrast on the
/// flat theme" to "contrast over the ground" is:
///
/// * `L` outside `[Lbg, Lg]` — exactly `c / b` or `b / c`, both bounded by `T`
/// * `L` between them — `a² / (b · c)` or `b · c / a²`, largest at an endpoint, again `T`
///
/// So one bound on the ground covers all 16 ANSI colours, the whole 256-colour cube and the
/// default foreground at once, without enumerating any of them. That is why the contract is
/// stated about the ground rather than about the text.
///
/// **The band is multiplicative, and that is not a detail.** An additive band —
/// `|Lg − Lbg| ≤ (T − 1)(Lbg + 0.05)`, which is the obvious way to write it — is asymmetric: it
/// permits `c` as low as `b(2 − T)`, and a ground *darker* than the theme then costs `1 / (2 − T)`,
/// which at `T = 1.25` is 1.33, not 1.25. The bound was written that way first and the test
/// below caught it on the dark side of every theme.
///
/// **What this does not prove.** Dim text (`SGR 2`, drawn at 0.6 alpha) moves with the ground
/// and is asserted by test rather than argued. Hue is not covered at all: blending toward a
/// near-neutral background leaves roughly a tenth of the picture's chroma. The interface says
/// "text keeps about 80% of this theme's contrast" and never claims a WCAG level.
enum GroundLegibility {
    /// sRGB's electro-optical transfer function, per channel.
    static func linearise(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    static func luminance(_ colour: RGBColor) -> Double {
        let r = linearise(Double(colour.red) / 255)
        let g = linearise(Double(colour.green) / 255)
        let b = linearise(Double(colour.blue) / 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func ratio(_ first: RGBColor, _ second: RGBColor) -> Double {
        let a = luminance(first) + 0.05
        let b = luminance(second) + 0.05
        return max(a, b) / min(a, b)
    }

    /// The colour `photo` becomes once `ground` is painted over it at `alpha`.
    ///
    /// Per channel in **encoded** sRGB, because that is what `CGContext.fill` with an alpha
    /// actually does in an sRGB context. Modelling it in linear light would predict a ground
    /// Core Graphics does not produce, and the whole contract is a claim about the pixels that
    /// end up on the screen.
    static func blend(_ photo: RGBColor, toward ground: RGBColor, alpha: Double) -> RGBColor {
        let a = min(max(alpha, 0), 1)
        func mix(_ p: UInt8, _ g: UInt8) -> UInt8 {
            let value = Double(p) * (1 - a) + Double(g) * a
            return UInt8(min(max(value.rounded(), 0), 255))
        }
        return RGBColor(
            red: mix(photo.red, ground.red),
            green: mix(photo.green, ground.green),
            blue: mix(photo.blue, ground.blue)
        )
    }

    /// How much contrast a ground of this colour costs against this background: the factor by
    /// which every ink's contrast ratio is divided.
    ///
    /// Symmetric by construction — a ground brighter than the theme and one darker by the same
    /// proportion cost the same.
    static func cost(ground: RGBColor, background: RGBColor) -> Double {
        let c = luminance(ground) + 0.05
        let b = luminance(background) + 0.05
        return max(c / b, b / c)
    }

    /// The smallest amount of the theme's background that has to be painted over the picture for
    /// every tile to sit inside the band.
    ///
    /// Bisection is sound here and it is worth saying why: the blend is linear in `alpha` per
    /// channel, sRGB's transfer function is monotone, and the luminance weights are positive —
    /// so the distance from `Lbg` decreases monotonically as `alpha` rises, and there is one
    /// smallest solution.
    ///
    /// Both extremes are solved and the larger answer wins: a dark theme is bound by the
    /// ceiling, a light theme by the floor, and the contract is on *every* tile.
    static func solve(
        ceiling: RGBColor,
        floor: RGBColor,
        background: RGBColor,
        factor: Double
    ) -> Double {
        max(
            solveOne(extreme: ceiling, background: background, factor: factor),
            solveOne(extreme: floor, background: background, factor: factor)
        )
    }

    private static func solveOne(extreme: RGBColor, background: RGBColor, factor: Double) -> Double {
        func distance(at alpha: Double) -> Double {
            cost(ground: blend(extreme, toward: background, alpha: alpha), background: background)
        }
        let target = factor
        // Already inside the band with no dimming at all: a picture the colour of the theme.
        if distance(at: 0) <= target { return 0 }

        var low = 0.0
        var high = 1.0
        // Twenty-four halvings put the answer well inside a 255th of a channel, which is finer
        // than anything that can be drawn.
        for _ in 0 ..< 24 {
            let middle = (low + high) / 2
            if distance(at: middle) <= target {
                high = middle
            } else {
                low = middle
            }
        }
        return high
    }
}
