import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ApexTerminal

/// Turning a photograph into a ground (D-077).
///
/// Everything expensive happens once, at import or at bake, and never on the drawing path. These
/// check that it really is once, and that the once is right.
@Suite("Backdrop baking")
@MainActor
struct BackdropBakeTests {
    /// A picture with a known bright half and a known dark half, so its measured extremes are
    /// predictable rather than whatever a photograph happens to contain.
    private func makePicture(width: Int = 256, height: Int = 128) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(RGBColor(hex: 0xF0F0F0).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(RGBColor(hex: 0x101010).cgColor)
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    private func jpeg(_ image: CGImage, orientation: CGImagePropertyOrientation? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation.rawValue }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func makeStore() -> (BackdropStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "backdrop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (BackdropStore(directory: directory, log: .disabled), directory)
    }

    @Test("A baked ground is exactly the size asked for, and has no alpha to composite")
    func theGroundIsExactAndOpaque() throws {
        let picture = makePicture()
        let backdrop = Backdrop(
            id: UUID(),
            ceilingRGB: RGBColor(hex: 0xF0F0F0),
            floorRGB: RGBColor(hex: 0x101010),
            pixelWidth: picture.width,
            pixelHeight: picture.height
        )
        let baked = try #require(BackdropBaker.bakeGround(
            soft: picture,
            backdrop: backdrop,
            background: TerminalTheme.midnight.background,
            pixelSize: CGSize(width: 640, height: 480)
        ))
        #expect(baked.width == 640)
        #expect(baked.height == 480)
        // Opaque, so the blit that draws it has nothing to composite.
        #expect(baked.alphaInfo == .noneSkipLast)
    }

    @Test("A photograph taken in portrait is not stored on its side")
    func orientationIsHonoured() throws {
        // Orientation 6 means "rotate 90° clockwise to display", so a 256×128 raster is a
        // 128×256 picture. Without `kCGImageSourceCreateThumbnailWithTransform` it arrives
        // lying down, which is the classic wallpaper bug.
        let data = jpeg(makePicture(width: 256, height: 128), orientation: .right)
        let decoded = try #require(BackdropBaker.decodeDownscaled(data))
        #expect(decoded.width == 128)
        #expect(decoded.height == 256)
    }

    @Test("The measured extremes come from tile means, not from single pixels")
    func extremesAreMeasuredFromTiles() {
        let (ceiling, floor) = BackdropBaker.extremes(of: makePicture())
        // The picture is half 0xF0 and half 0x10; averaging over tiles keeps both ends.
        #expect(ceiling.red > 0xE0)
        #expect(floor.red < 0x30)
    }

    @Test("Changing softness re-blurs the master rather than the blurred copy")
    func softnessDoesNotCompound() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try store.store(data: jpeg(makePicture()), softness: 0, strength: .balanced, placement: .fill)
        let blurred = try store.resoften(original, softness: 1)
        let backAgain = try store.resoften(blurred, softness: 0)

        // Back where it started, within a rounding step. Re-blurring an already blurred picture
        // would compound, and the way back to sharp would not exist.
        #expect(abs(Int(backAgain.ceilingRGB.red) - Int(original.ceilingRGB.red)) <= 2)
        #expect(abs(Int(backAgain.floorRGB.red) - Int(original.floorRGB.red)) <= 2)
    }

    @Test("Softening a picture never asks for more dimming")
    func softeningNeverCostsMore() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let background = TerminalTheme.midnight.background

        let sharp = try store.store(data: jpeg(makePicture()), softness: 0, strength: .balanced, placement: .fill)
        let soft = try store.resoften(sharp, softness: 1)

        // The claim the Softness control makes to the person using it: blurring flattens a
        // picture, and a flatter picture needs less taken off it.
        #expect(
            BackdropBaker.dimming(for: soft, background: background)
                <= BackdropBaker.dimming(for: sharp, background: background) + 1e-9
        )
    }

    @Test("Removing a picture takes both of its files")
    func removingDeletesBoth() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let backdrop = try store.store(data: jpeg(makePicture()), softness: 0.2, strength: .subtle, placement: .fit)
        #expect(store.has(backdrop.id))
        store.remove(backdrop.id)
        #expect(!store.has(backdrop.id))

        let left = (try? FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Backdrop"), includingPropertiesForKeys: nil
        )) ?? []
        #expect(left.isEmpty, "both the master and the blurred copy should be gone, found \(left)")
    }

    @Test("Extra dimming only ever takes more off, never less")
    func extraDimmingIsOneWay() {
        let backdrop = Backdrop(
            id: UUID(),
            extraDimming: 0.5,
            ceilingRGB: RGBColor(hex: 0xFFFFFF),
            floorRGB: RGBColor(hex: 0x000000),
            pixelWidth: 10, pixelHeight: 10
        )
        var plain = backdrop
        plain.extraDimming = 0
        let background = TerminalTheme.midnight.background
        #expect(BackdropBaker.dimming(for: backdrop, background: background)
            > BackdropBaker.dimming(for: plain, background: background))
        // And it can never reach the point of hiding the picture entirely.
        #expect(BackdropBaker.dimming(for: backdrop, background: background) < 1)
    }
}
