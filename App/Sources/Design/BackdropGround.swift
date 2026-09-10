import CoreGraphics
import Foundation
import UIKit

/// A baked ground: one opaque bitmap, and the size it is meant to be drawn at (D-077).
///
/// `@unchecked Sendable` because a `CGImage` is immutable once made, and a bake finishing on a
/// background task has to hand one back to the main actor.
struct BakedGround: @unchecked Sendable {
    let image: CGImage
    let pixelSize: CGSize
    /// The same thing in points, which is what the drawing code works in.
    let pointSize: CGSize
}

/// Everything that decides what a ground looks like.
///
/// Deliberately **without** the pane's rectangle: one picture per window, with panes offsetting
/// into it. Key it by the pane and a split screen shows one crop per pane, which reads as a
/// rendering fault rather than as a wallpaper.
struct GroundKey: Hashable, Sendable {
    var backdropID: UUID
    var strength: Backdrop.Strength
    /// Doubles rounded to thousandths, so a key stays `Hashable` without floating-point equality.
    var softnessMilli: Int
    var extraDimmingMilli: Int
    var placement: Backdrop.Placement
    var windowPixelWidth: Int
    var windowPixelHeight: Int
    var background: RGBColor

    init(backdrop: Backdrop, background: RGBColor, windowPixelSize: CGSize) {
        backdropID = backdrop.id
        strength = backdrop.strength
        softnessMilli = Int((backdrop.softness * 1000).rounded())
        extraDimmingMilli = Int((backdrop.extraDimming * 1000).rounded())
        placement = backdrop.placement
        windowPixelWidth = Int(windowPixelSize.width.rounded())
        windowPixelHeight = Int(windowPixelSize.height.rounded())
        self.background = background
    }
}

/// What `TerminalRenderView` needs from the world to draw a ground.
///
/// A protocol so a test can hand it a stub that counts how often a bake was asked for — which is
/// the only honest way to assert "drawing never bakes".
@MainActor
protocol BackdropGroundProviding: AnyObject {
    /// The ground for this wallpaper, theme and window, or nil while one is being made.
    ///
    /// Never blocks: a terminal that waited for a wallpaper would be a terminal that stuttered on
    /// a wallpaper. The first ask starts a bake and returns nil; the flat theme colour is drawn
    /// meanwhile, and the view is asked to redraw when the bitmap is ready.
    func ground(for backdrop: Backdrop, background: RGBColor, windowPixelSize: CGSize) -> BakedGround?
}
