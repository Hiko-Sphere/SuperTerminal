import CoreGraphics
import Foundation
import STCore
import UIKit

/// Bakes grounds off the main actor and keeps them (D-077).
///
/// One image per window rather than per pane: `TerminalRenderView.imageCache` is per-instance, so
/// a four-pane iPad would otherwise hold four copies of the same photograph, each the size of the
/// screen.
///
/// Asking for a ground never blocks. The first ask starts a bake and returns nil, the terminal
/// draws its flat theme colour in the meantime, and the callback invalidates once the bitmap is
/// ready — which is the difference between a wallpaper and a stutter.
@MainActor
final class BackdropGroundCache: BackdropGroundProviding {
    private let store: BackdropStore
    private let log: STLogger
    private let cache = NSCache<CacheKey, CacheEntry>()
    private var inFlight: Set<GroundKey> = []
    /// Called when a bake finishes, so whoever is showing a terminal can redraw.
    var onGroundReady: (() -> Void)?

    init(store: BackdropStore, log: STLogger) {
        self.store = store
        self.log = log.child(subsystem: "backdrop.ground")
        // Four full-screen grounds on the largest iPad, give or take. Beyond that the oldest go.
        cache.totalCostLimit = 64 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cache.removeAllObjects() }
        }
    }

    func ground(for backdrop: Backdrop, background: RGBColor, windowPixelSize: CGSize) -> BakedGround? {
        let key = GroundKey(backdrop: backdrop, background: background, windowPixelSize: windowPixelSize)
        if let entry = cache.object(forKey: CacheKey(key)) { return entry.ground }
        guard !inFlight.contains(key), let soft = store.soft(backdrop.id) else { return nil }
        inFlight.insert(key)
        bake(key, backdrop: backdrop, background: background, soft: soft)
        return nil
    }

    /// Throws away everything baked. Called when the wallpaper or the theme changes.
    func invalidate() {
        cache.removeAllObjects()
        inFlight.removeAll()
    }

    private func bake(_ key: GroundKey, backdrop: Backdrop, background: RGBColor, soft: CGImage) {
        // The record already carries the picture's measured extremes; re-deriving them here would
        // measure the same pixels again for every theme the same wallpaper is baked against.
        let pixelSize = CGSize(width: key.windowPixelWidth, height: key.windowPixelHeight)
        let scale = UIScreen.main.scale
        Task.detached(priority: .userInitiated) {
            let baked = BackdropBaker.bakeGround(
                soft: soft,
                backdrop: backdrop,
                background: background,
                pixelSize: pixelSize
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                inFlight.remove(key)
                guard let baked else { return }
                let ground = BakedGround(
                    image: baked,
                    pixelSize: CGSize(width: baked.width, height: baked.height),
                    pointSize: CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
                )
                cache.setObject(CacheEntry(ground), forKey: CacheKey(key), cost: baked.width * baked.height * 4)
                log.debug("baked a ground", ["pixels": "\(baked.width)×\(baked.height)"])
                onGroundReady?()
            }
        }
    }

    /// `NSCache` needs objects, and a `Hashable` struct is not one.
    private final class CacheKey: NSObject {
        let key: GroundKey
        init(_ key: GroundKey) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? CacheKey)?.key == key }
    }

    private final class CacheEntry: NSObject {
        let ground: BakedGround
        init(_ ground: BakedGround) { self.ground = ground }
    }
}
