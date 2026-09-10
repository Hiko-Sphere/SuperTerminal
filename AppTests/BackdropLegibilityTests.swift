import Foundation
import Testing

@testable import ApexTerminal

/// The contract that lets a photograph sit behind a shell (D-077).
///
/// A picture behind text is the feature every terminal gets wrong, and it is always the same
/// mistake: a free opacity slider, which makes illegibility the user's fault. Here the dimming
/// is *solved* — from the picture's own measured extremes and the theme's background — so that
/// the ground can never cost more contrast than the strength the person chose.
///
/// These are the arithmetic. They check a published constant, then the bound itself against every
/// colour the terminal can draw, then the two properties the solver relies on.
@Suite("Backdrop legibility")
struct BackdropLegibilityTests {
    private let white = RGBColor(hex: 0xFFFFFF)
    private let black = RGBColor(hex: 0x000000)

    /// Every colour a program can ask for: the 16 ANSI slots, the default ink, and the 256-cube
    /// sampled often enough to catch a systematic error without taking a second.
    private func everyInk(of theme: TerminalTheme) -> [RGBColor] {
        var inks = theme.ansi
        inks.append(theme.foreground)
        for index in stride(from: 0, through: 255, by: 8) {
            inks.append(theme.resolve(.indexed(UInt8(index)), isForeground: true, bold: false))
        }
        return inks
    }

    @Test("White on black is 21:1, which is the number the standard publishes")
    func pinsTheArithmeticToAPublishedConstant() {
        #expect(abs(GroundLegibility.ratio(white, black) - 21.0) < 0.0001)
        #expect(abs(GroundLegibility.luminance(white) - 1.0) < 0.0001)
        #expect(abs(GroundLegibility.luminance(black)) < 0.0001)
    }

    @Test("The ground never costs more contrast than the strength promised")
    func theBoundHoldsForEveryInk() {
        for theme in [TerminalTheme.midnight, .daylight, .highContrast] {
            for strength in Backdrop.Strength.allCases {
                // The worst picture there is: pure white somewhere and pure black somewhere.
                let alpha = GroundLegibility.solve(
                    ceiling: white,
                    floor: black,
                    background: theme.background,
                    factor: strength.factor
                )
                for extreme in [white, black] {
                    let ground = GroundLegibility.blend(extreme, toward: theme.background, alpha: alpha)
                    for ink in everyInk(of: theme) {
                        let flat = GroundLegibility.ratio(ink, theme.background)
                        let overGround = GroundLegibility.ratio(ink, ground)
                        #expect(
                            flat / overGround <= strength.factor + 1e-9,
                            "\(theme.id)/\(strength.rawValue): \(flat) → \(overGround)"
                        )
                    }
                }
            }
        }
    }

    @Test("Dim text is inside the factor too — asserted, because the proof does not cover it")
    func dimTextStaysInsideTheFactor() {
        // `SGR 2` is drawn at 0.6 alpha over whatever is behind it, so it moves *with* the
        // ground. The contract's algebra is about opaque ink; this is the case it does not
        // reach, so it is measured rather than argued.
        for theme in [TerminalTheme.midnight, .daylight] {
            let alpha = GroundLegibility.solve(
                ceiling: white, floor: black,
                background: theme.background,
                factor: Backdrop.Strength.balanced.factor
            )
            for extreme in [white, black] {
                let ground = GroundLegibility.blend(extreme, toward: theme.background, alpha: alpha)
                for ink in everyInk(of: theme) {
                    let dimFlat = GroundLegibility.blend(ink, toward: theme.background, alpha: 0.4)
                    let dimOverGround = GroundLegibility.blend(ink, toward: ground, alpha: 0.4)
                    let flat = GroundLegibility.ratio(dimFlat, theme.background)
                    let over = GroundLegibility.ratio(dimOverGround, ground)
                    #expect(flat / over <= Backdrop.Strength.balanced.factor + 1e-9)
                }
            }
        }
    }

    @Test("A light theme still gets a picture")
    func aLightThemeIsNotSilentlyExcluded() {
        // The standing guard against re-introducing an absolute contrast floor. Daylight's own
        // dim foreground is 4.15:1 against its own background with *no* picture at all, so a
        // 4.5:1 floor would solve to "no picture" for every light-theme user — a feature that
        // silently does nothing, with nothing on screen to explain it.
        let alpha = GroundLegibility.solve(
            ceiling: white, floor: black,
            background: TerminalTheme.daylight.background,
            factor: Backdrop.Strength.balanced.factor
        )
        #expect(alpha < 0.95, "Daylight solved to \(alpha), which would leave no picture visible")
    }

    @Test("The solved dimming is the number the interface quotes")
    func pinsTheMeasuredConstants() {
        // Worst case on purpose: a picture containing both pure white and pure black. A real
        // photograph has a narrower range and keeps far more of itself — which is the whole
        // reason the extremes are measured per picture instead of assumed.
        let expected: [(TerminalTheme, Backdrop.Strength, Double)] = [
            (.midnight, .subtle, 0.9597),
            (.midnight, .balanced, 0.9131),
            (.midnight, .bold, 0.8792),
            (.daylight, .subtle, 0.9582),
            (.daylight, .balanced, 0.9024),
            (.daylight, .bold, 0.8546),
        ]
        for (theme, strength, value) in expected {
            let alpha = GroundLegibility.solve(
                ceiling: white, floor: black,
                background: theme.background,
                factor: strength.factor
            )
            #expect(abs(alpha - value) < 0.002, "\(theme.id)/\(strength.rawValue) solved to \(alpha)")
        }
    }

    @Test("A gentler picture keeps more of itself")
    func aNarrowerPictureSurvivesBetter() {
        // The argument for measuring each picture rather than assuming the worst: a photograph
        // whose tiles sit in a narrow band needs far less dimming to meet the same promise.
        let background = TerminalTheme.midnight.background
        let harsh = GroundLegibility.solve(
            ceiling: white, floor: black, background: background,
            factor: Backdrop.Strength.balanced.factor
        )
        let gentle = GroundLegibility.solve(
            ceiling: RGBColor(hex: 0x3A3F4B), floor: RGBColor(hex: 0x0B0D12),
            background: background,
            factor: Backdrop.Strength.balanced.factor
        )
        #expect(gentle < harsh, "a low-contrast picture should need less dimming")
        #expect(gentle < 0.6, "and should still be plainly visible; solved to \(gentle)")
    }

    @Test("A ground the colour of the theme needs no dimming at all")
    func nothingToCorrect() {
        let background = TerminalTheme.midnight.background
        let alpha = GroundLegibility.solve(
            ceiling: background, floor: background,
            background: background,
            factor: Backdrop.Strength.subtle.factor
        )
        #expect(alpha == 0)
    }

    @Test("The cost falls as the dimming rises, which is what licenses bisection")
    func theSolveIsMonotone() {
        for background in [TerminalTheme.midnight.background, TerminalTheme.daylight.background] {
            for extreme in [white, black] {
                var previous = Double.infinity
                for step in 0 ... 100 {
                    let alpha = Double(step) / 100
                    let ground = GroundLegibility.blend(extreme, toward: background, alpha: alpha)
                    let cost = GroundLegibility.cost(ground: ground, background: background)
                    #expect(cost <= previous + 1e-9, "not monotone at \(alpha)")
                    previous = cost
                }
            }
        }
    }

    @Test("An additive band would be asymmetric, which is the bug this contract had first")
    func theBandHasToBeMultiplicative() {
        // Kept as a test because the additive form is the one anybody would write down. With
        // `T = 1.25` it permits a ground at `b(2 - T)` = 0.75b, and a ground *darker* than the
        // theme by that much costs `b / 0.75b` = 1.33 — over the promise, on the dark side of
        // every theme.
        let background = TerminalTheme.midnight.background
        let b = GroundLegibility.luminance(background) + 0.05
        let factor = Backdrop.Strength.balanced.factor
        let additiveFloor = b * (2 - factor) - 0.05
        #expect(b / (additiveFloor + 0.05) > factor, "the additive band is where the bug was")
        // The multiplicative one is symmetric: both ends cost exactly the factor.
        let multiplicativeFloor = b / factor - 0.05
        #expect(abs(b / (multiplicativeFloor + 0.05) - factor) < 1e-9)
    }

    @Test("The channel-wise ceiling really is a bound on every tile")
    func theCeilingIsConservative() {
        // Guards against the tempting shortcut of keeping "the brightest tile by luminance":
        // luminance ordering does not imply channel-wise ordering, so that is not a bound.
        var generator = SeededGenerator(seed: 20_260_910)
        let background = TerminalTheme.midnight.background
        for _ in 0 ..< 500 {
            let tiles = (0 ..< 8).map { _ in
                RGBColor(
                    red: UInt8.random(in: 0 ... 255, using: &generator),
                    green: UInt8.random(in: 0 ... 255, using: &generator),
                    blue: UInt8.random(in: 0 ... 255, using: &generator)
                )
            }
            let ceiling = RGBColor(
                red: tiles.map(\.red).max() ?? 0,
                green: tiles.map(\.green).max() ?? 0,
                blue: tiles.map(\.blue).max() ?? 0
            )
            for alpha in [0.25, 0.5, 0.75, 0.9] {
                let bound = GroundLegibility.luminance(
                    GroundLegibility.blend(ceiling, toward: background, alpha: alpha)
                )
                for tile in tiles {
                    let actual = GroundLegibility.luminance(
                        GroundLegibility.blend(tile, toward: background, alpha: alpha)
                    )
                    #expect(actual <= bound + 1e-9)
                }
            }
        }
    }
}

/// Written out rather than taken from the system, so a failure repeats.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
