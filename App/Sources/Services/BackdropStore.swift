import CoreGraphics
import Foundation
import STCore
import UIKit

/// Where the wallpaper's pixels live (D-077).
///
/// Two files per picture, not one:
///
/// * `<uuid>-master.jpg` — decoded, oriented, downscaled, **unblurred**
/// * `<uuid>-soft.jpg` — the master blurred at the current softness
///
/// Two, because blurring an already blurred picture compounds: moving the Softness control back
/// towards zero has to re-bake from the master, or the picture only ever gets muddier.
///
/// Not the App Group container. The File Provider extension has no business seeing a wallpaper,
/// and a shared container is a wider surface than this needs.
@MainActor
final class BackdropStore {
    private let directory: URL
    private let log: STLogger
    /// The soft picture, decoded once. One entry: there is one wallpaper.
    private var cached: (id: UUID, image: CGImage)?

    init(directory: URL, log: STLogger) {
        self.directory = directory.appendingPathComponent("Backdrop", isDirectory: true)
        self.log = log.child(subsystem: "backdrop")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var url = self.directory
        var values = URLResourceValues()
        // A wallpaper is recoverable by choosing it again; it does not belong in a backup.
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Writing

    /// Imports a picture and returns the record describing it.
    @discardableResult
    func store(data: Data, softness: Double, strength: Backdrop.Strength, placement: Backdrop.Placement) throws -> Backdrop {
        let imported = try BackdropBaker.importPicture(data, softness: softness)
        let id = UUID()
        try write(imported.master, to: masterURL(id))
        try write(imported.soft, to: softURL(id))
        cached = (id, imported.soft)
        log.info("stored a backdrop", ["pixels": "\(imported.master.width)×\(imported.master.height)"])
        return Backdrop(
            id: id,
            strength: strength,
            softness: softness,
            placement: placement,
            ceilingRGB: imported.ceilingRGB,
            floorRGB: imported.floorRGB,
            pixelWidth: imported.master.width,
            pixelHeight: imported.master.height
        )
    }

    /// Re-blurs from the master and re-measures, which is what changing Softness has to do.
    func resoften(_ backdrop: Backdrop, softness: Double) throws -> Backdrop {
        guard let master = decode(masterURL(backdrop.id)) else {
            throw STError(
                category: .internalError,
                message: String(localized: "That picture is no longer on this device.")
            )
        }
        let soft = BackdropBaker.softened(master, softness: softness)
        try write(soft, to: softURL(backdrop.id))
        cached = (backdrop.id, soft)
        let (ceiling, floor) = BackdropBaker.extremes(of: soft)
        var updated = backdrop
        updated.softness = softness
        updated.ceilingRGB = ceiling
        updated.floorRGB = floor
        return updated
    }

    func remove(_ id: UUID) {
        if cached?.id == id { cached = nil }
        try? FileManager.default.removeItem(at: masterURL(id))
        try? FileManager.default.removeItem(at: softURL(id))
    }

    /// Everything, for the UI-test reset.
    func removeAll() {
        cached = nil
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Reading

    /// The blurred picture, ready to be baked against a theme.
    func soft(_ id: UUID) -> CGImage? {
        if let cached, cached.id == id { return cached.image }
        guard let image = decode(softURL(id)) else { return nil }
        cached = (id, image)
        return image
    }

    func has(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: softURL(id).path)
    }

    // MARK: - Files

    private func masterURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString)-master.jpg") }
    private func softURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString)-soft.jpg") }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.92) else {
            throw STError(
                category: .internalError,
                message: String(localized: "That picture could not be saved.")
            )
        }
        // `atomicAndProtected` rather than `[.atomic, .completeFileProtection]`: the latter makes
        // the write *fail* on Mac Catalyst, which this project has already measured (D-070).
        try data.write(to: url, options: .atomicAndProtected)
    }

    private func decode(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return BackdropBaker.decodeDownscaled(data)
    }
}
