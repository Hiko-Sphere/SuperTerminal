import SwiftUI
import UIKit

/// The wallpaper behind everything, including the parts of the screen the grid does not reach
/// (D-077).
///
/// The terminal draws its own slice of the ground, but it stops at the grid's edge — so without
/// this there is a flat band under the notch and above the home indicator, which is exactly where
/// the eye goes. This draws the same baked bitmap, anchored to the same window, so the two agree
/// pixel for pixel rather than approximately.
struct BackdropSurface: UIViewRepresentable {
    let backdrop: Backdrop
    let background: RGBColor
    let provider: any BackdropGroundProviding

    func makeUIView(context: Context) -> BackdropSurfaceView {
        let view = BackdropSurfaceView()
        view.isUserInteractionEnabled = false
        view.isOpaque = false
        view.provider = provider
        view.inputs = .init(backdrop: backdrop, background: background)
        return view
    }

    func updateUIView(_ view: BackdropSurfaceView, context: Context) {
        view.provider = provider
        view.inputs = .init(backdrop: backdrop, background: background)
    }
}

/// Draws one baked ground and nothing else.
final class BackdropSurfaceView: UIView {
    struct Inputs: Equatable {
        var backdrop: Backdrop
        var background: RGBColor
    }

    weak var provider: (any BackdropGroundProviding)?
    var inputs: Inputs? {
        didSet { if inputs != oldValue { setNeedsDisplay() } }
    }

    private var groundOrigin: CGPoint = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        let origin = window.map { convert(CGPoint.zero, to: $0) } ?? .zero
        if origin != groundOrigin {
            groundOrigin = origin
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let inputs, let provider else { return }
        let points = window?.bounds.size ?? bounds.size
        guard points.width > 0, points.height > 0 else { return }
        let scale = window?.screen.scale ?? contentScaleFactor
        guard let ground = provider.ground(
            for: inputs.backdrop,
            background: inputs.background,
            windowPixelSize: CGSize(width: points.width * scale, height: points.height * scale)
        ) else {
            // Still baking: the theme's own colour, which is what the terminal shows too.
            context.setFillColor(inputs.background.cgColor)
            context.fill(rect)
            return
        }
        // Quartz-native here — this view does not flip, so the image is drawn into a y-up space
        // with the same window anchoring the terminal uses.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(ground.image, in: CGRect(
            x: -groundOrigin.x,
            y: bounds.height + groundOrigin.y - ground.pointSize.height,
            width: ground.pointSize.width,
            height: ground.pointSize.height
        ))
        context.restoreGState()
    }
}
