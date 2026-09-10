import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import STCore
import UniformTypeIdentifiers

/// Turns a photograph into something a terminal can be drawn on top of (D-077).
///
/// Everything expensive happens here, and none of it happens per frame. A terminal redraws on
/// every arriving chunk and on every cursor blink; a Core Image pass or a bilinear downscale on
/// that path would be a dropped frame per keystroke. So: decode once, blur once, measure once,
/// and bake one opaque bitmap at exactly the size it will be blitted at.
///
/// `nonisolated` on purpose — it holds no state and touches no UI, so a bake can run off the main
/// actor while the terminal keeps drawing the flat theme colour.
enum BackdropBaker {
    /// The longest edge a stored picture keeps: comfortably above the largest iPad's long edge in
    /// points at 2×, so a full-screen ground is never upscaled, and far below what a phone camera
    /// produces.
    static let maximumMasterEdge: CGFloat = 4096
    /// A ceiling on one baked ground, in pixels. Beyond this the bake is done to fit and the blit
    /// scales — visually free, because the picture is already blurred.
    static let maximumGroundPixels = 12_000_000
    /// The side of the squares the picture is reduced to before its extremes are taken.
    ///
    /// Roughly a cell: the contract is about what sits behind one character, so a bright speck
    /// smaller than a glyph stroke must not decide how dark the whole screen goes.
    static let tileEdge = 16

    struct Imported {
        /// Decoded, oriented, downscaled — and *not* blurred, so softness can change later
        /// without blurring an already blurred picture.
        let master: CGImage
        let soft: CGImage
        let ceilingRGB: RGBColor
        let floorRGB: RGBColor
    }

    // MARK: - Importing

    static func importPicture(_ data: Data, softness: Double) throws -> Imported {
        guard let master = decodeDownscaled(data) else {
            throw STError(
                category: .internalError,
                message: String(localized: "That picture could not be read."),
                recoverySuggestion: String(localized: "Try a different photo, or export it as JPEG or PNG first.")
            )
        }
        let soft = softened(master, softness: softness)
        let (ceiling, floor) = extremes(of: soft)
        return Imported(master: master, soft: soft, ceilingRGB: ceiling, floorRGB: floor)
    }

    /// Decodes at most ``maximumMasterEdge`` on the long side, without ever decoding the whole
    /// picture.
    ///
    /// ImageIO's thumbnail path is the documented way to do that, and
    /// `kCGImageSourceCreateThumbnailWithTransform` is what applies the EXIF orientation — which
    /// is the difference between a photograph taken in portrait and one lying on its side.
    static func decodeDownscaled(_ data: Data, maximumEdge: CGFloat = maximumMasterEdge) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// One Gaussian pass, always from the unblurred master.
    ///
    /// The extent is clamped first: `CIGaussianBlur` samples transparent black outside an image's
    /// bounds, which is what produces the faded border people report as a bug.
    static func softened(_ master: CGImage, softness: Double) -> CGImage {
        let amount = min(max(softness, 0), 1)
        guard amount > 0 else { return master }
        // Proportional to the picture, so the same setting looks the same on any photograph.
        let radius = amount * Double(min(master.width, master.height)) / 24
        let input = CIImage(cgImage: master)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return master }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let blurred = CIContext().createCGImage(output, from: input.extent)
        else { return master }
        return blurred
    }

    /// The channel-wise extremes over the picture's tile means.
    ///
    /// Reduced by drawing into a context one sixteenth the size, which is a box average per tile
    /// and one pass. Channel-wise, and of *means*: the brightest tile by luminance is not a valid
    /// bound, because luminance ordering does not imply channel-wise ordering.
    static func extremes(of image: CGImage) -> (ceiling: RGBColor, floor: RGBColor) {
        let width = max(1, image.width / tileEdge)
        let height = max(1, image.height / tileEdge)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            // A picture that cannot be measured is treated as the worst one there is, so the
            // contract is still met — never as a benign one.
            return (RGBColor(hex: 0xFFFFFF), RGBColor(hex: 0x000000))
        }
        var ceiling = (r: UInt8(0), g: UInt8(0), b: UInt8(0))
        var floor = (r: UInt8(255), g: UInt8(255), b: UInt8(255))
        for index in stride(from: 0, to: pixels.count, by: 4) {
            ceiling.r = max(ceiling.r, pixels[index])
            ceiling.g = max(ceiling.g, pixels[index + 1])
            ceiling.b = max(ceiling.b, pixels[index + 2])
            floor.r = min(floor.r, pixels[index])
            floor.g = min(floor.g, pixels[index + 1])
            floor.b = min(floor.b, pixels[index + 2])
        }
        return (
            RGBColor(red: ceiling.r, green: ceiling.g, blue: ceiling.b),
            RGBColor(red: floor.r, green: floor.g, blue: floor.b)
        )
    }

    // MARK: - Baking

    /// How much of the theme's background has to go over this picture, for this theme.
    ///
    /// Solved rather than stored: the dimming that keeps Midnight legible is not the dimming that
    /// keeps Daylight legible, so a number saved with the picture would quietly mean something
    /// else after a light/dark switch. `extraDimming` is only ever added — someone may want a
    /// quieter picture, and may not talk the app below what it promised.
    static func dimming(for backdrop: Backdrop, background: RGBColor) -> Double {
        let solved = GroundLegibility.solve(
            ceiling: backdrop.ceilingRGB,
            floor: backdrop.floorRGB,
            background: background,
            factor: backdrop.strength.factor
        )
        let extra = min(max(backdrop.extraDimming, 0), Backdrop.extraDimmingRange.upperBound)
        return min(1, solved + extra * (1 - solved))
    }

    /// The finished ground: one opaque bitmap, at exactly the size it will be drawn at.
    ///
    /// Filling the background and then drawing the picture *at* `1 - dimming` produces
    /// `photo·(1−α) + background·α` in one pass, and leaves a bitmap with no alpha channel — so
    /// the blit that follows has no compositing to do at all.
    static func bakeGround(
        soft: CGImage,
        backdrop: Backdrop,
        background: RGBColor,
        pixelSize: CGSize
    ) -> CGImage? {
        let capped = cap(pixelSize)
        let width = Int(capped.width.rounded())
        let height = Int(capped.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(background.cgColor)
        context.fill(bounds)
        context.interpolationQuality = .high
        context.setAlpha(1 - dimming(for: backdrop, background: background))
        let source = CGSize(width: soft.width, height: soft.height)
        switch backdrop.placement {
        case .fill: context.draw(soft, in: aspectFill(source, in: bounds))
        case .fit: context.draw(soft, in: aspectFit(source, in: bounds))
        }
        return context.makeImage()
    }

    /// Keeps one ground inside ``maximumGroundPixels``, preserving its shape.
    static func cap(_ size: CGSize) -> CGSize {
        let pixels = size.width * size.height
        guard pixels > CGFloat(maximumGroundPixels), pixels > 0 else { return size }
        let scale = (CGFloat(maximumGroundPixels) / pixels).squareRoot()
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// Covers `bounds` entirely, cropping whichever axis overflows.
    static func aspectFill(_ source: CGSize, in bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return bounds }
        let scale = max(bounds.width / source.width, bounds.height / source.height)
        return centred(source, scaledBy: scale, in: bounds)
    }

    /// Shows the whole picture, letterboxed against the theme's background.
    static func aspectFit(_ source: CGSize, in bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return bounds }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return centred(source, scaledBy: scale, in: bounds)
    }

    private static func centred(_ source: CGSize, scaledBy scale: CGFloat, in bounds: CGRect) -> CGRect {
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
