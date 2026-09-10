import CoreGraphics
import Foundation
import STTerminal
import Testing
import UIKit

@testable import ApexTerminal

/// What the drawing path does with a wallpaper, asserted structurally (D-077).
///
/// Not by stopwatch. `RenderPerformanceTests` records that a with-versus-without wall-clock
/// comparison was tried, measured within one per cent, and proved nothing either way. What can be
/// proved is the *shape*: that drawing never bakes, and that the ground does not move with the
/// dirty rectangle.
@Suite("Backdrop rendering")
@MainActor
struct BackdropRenderTests {
    /// Counts what it is asked for, and hands back a ground of a fixed size.
    private final class CountingProvider: BackdropGroundProviding {
        private(set) var asks: [(backdrop: Backdrop, background: RGBColor, pixelSize: CGSize)] = []
        private let ground: BakedGround?

        init(pointSize: CGSize, scale: CGFloat) {
            let width = Int(pointSize.width * scale)
            let height = Int(pointSize.height * scale)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            context.setFillColor(RGBColor(hex: 0x304050).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ground = context.makeImage().map {
                BakedGround(
                    image: $0,
                    pixelSize: CGSize(width: width, height: height),
                    pointSize: pointSize
                )
            }
        }

        func ground(for backdrop: Backdrop, background: RGBColor, windowPixelSize: CGSize) -> BakedGround? {
            asks.append((backdrop, background, windowPixelSize))
            return ground
        }
    }

    private func makeBackdrop() -> Backdrop {
        Backdrop(
            id: UUID(),
            ceilingRGB: RGBColor(hex: 0xF0F0F0),
            floorRGB: RGBColor(hex: 0x101010),
            pixelWidth: 800,
            pixelHeight: 600
        )
    }

    private func makeView(provider: CountingProvider) -> TerminalRenderView {
        let view = TerminalRenderView()
        view.theme = .midnight
        view.fontSize = 13
        let metrics = TerminalRenderView.metrics(forFontSize: 13)
        view.frame = CGRect(
            x: 0, y: 0,
            width: metrics.cellWidth * 80,
            height: metrics.cellHeight * 24
        )
        var screen = TerminalScreen(columns: 80, rows: 24)
        for character in "hello" { screen.write(character) }
        view.update(screen: screen)
        view.groundProvider = provider
        view.groundInputs = .init(backdrop: makeBackdrop(), background: TerminalTheme.midnight.background)
        return view
    }

    private func render(_ view: TerminalRenderView, rect: CGRect) {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        _ = renderer.image { context in
            UIGraphicsPushContext(context.cgContext)
            view.draw(rect)
            UIGraphicsPopContext()
        }
    }

    @Test("Drawing asks for a ground but never bakes one")
    func drawingNeverBakes() {
        let provider = CountingProvider(pointSize: CGSize(width: 800, height: 600), scale: 2)
        let view = makeView(provider: provider)

        for _ in 0 ..< 60 { render(view, rect: view.bounds) }

        #expect(provider.asks.count == 60, "every frame should ask")
        // Every ask identical, so a cache answers all but the first. If the key moved with the
        // frame, every frame would be a fresh bake — which is the whole performance argument.
        let first = provider.asks[0]
        for ask in provider.asks {
            #expect(ask.pixelSize == first.pixelSize)
            #expect(ask.backdrop == first.backdrop)
            #expect(ask.background == first.background)
        }
    }

    @Test("The ground does not move with the dirty rectangle")
    func theGroundRectIsInvariant() {
        let provider = CountingProvider(pointSize: CGSize(width: 800, height: 600), scale: 2)
        let view = makeView(provider: provider)

        render(view, rect: view.bounds)
        let whole = view.lastGroundDrawRect
        // What the cursor blink invalidates: a couple of cells, twice a second. Derive the
        // ground's rectangle from that and the whole photograph is squeezed into two character
        // cells, for ever.
        let metrics = TerminalRenderView.metrics(forFontSize: 13)
        render(view, rect: CGRect(x: 0, y: 0, width: metrics.cellWidth * 2, height: metrics.cellHeight))
        #expect(view.lastGroundDrawRect == whole, "the ground followed the dirty rectangle")
        #expect(whole != nil)
    }

    @Test("With no wallpaper the drawing path is untouched")
    func noBackdropAsksForNothing() {
        let provider = CountingProvider(pointSize: CGSize(width: 800, height: 600), scale: 2)
        let view = makeView(provider: provider)
        view.groundInputs = nil

        render(view, rect: view.bounds)

        #expect(provider.asks.isEmpty, "a terminal with no picture must not consult the cache at all")
        #expect(view.lastGroundDrawRect == nil)
    }
}
