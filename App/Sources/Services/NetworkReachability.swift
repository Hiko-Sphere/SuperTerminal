import Foundation
import Network
import Observation

/// Whether the device has a usable network, and when that changes.
///
/// A phone's connection does not fail once and stay failed: it goes away in a lift and
/// comes back, moves from Wi-Fi to cellular mid-command, and drops for a second when a VPN
/// reconnects. Waiting out a backoff while the network is already back is the difference
/// between a terminal that feels resilient and one that feels broken.
///
/// A change of *interface* matters as much as a loss of connectivity: moving from Wi-Fi to
/// cellular changes the source address, so every existing TCP connection is dead even
/// though the path is satisfied the whole way through.
@Observable
@MainActor
final class NetworkReachability {
    private(set) var isOnline: Bool = true
    private(set) var interface: Interface = .unknown

    /// Increments whenever the usable path changes in a way that invalidates open
    /// connections, so a session can tell "still the same network" from "a different one".
    private(set) var pathGeneration: Int = 0

    enum Interface: String, Sendable {
        case wifi = "Wi-Fi"
        case cellular = "Cellular"
        case wired = "Wired"
        case other = "Other"
        case unknown = "Unknown"
        case none = "Offline"

        /// Kept apart from the raw value: a raw value has to be a compile-time literal, so
        /// the name shown in the reconnection banner is the only part that can follow the
        /// device's language.
        var displayName: String {
            switch self {
            case .wifi: String(localized: "Wi-Fi")
            case .cellular: String(localized: "Cellular")
            case .wired: String(localized: "Wired")
            case .other: String(localized: "Other")
            case .unknown: String(localized: "Unknown")
            case .none: String(localized: "Offline")
            }
        }
    }

    private let monitor = NWPathMonitor()
    private var observers: [UUID: @MainActor (Int) -> Void] = [:]

    init(start: Bool = true) {
        guard start else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.apply(path) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.superterminal.path"))
    }

    deinit { monitor.cancel() }

    /// Fires when the path changes to one that could carry a new connection.
    ///
    /// A stream rather than a poll: a session that is waiting thirty seconds for its next
    /// attempt should be woken the moment the network returns, not thirty seconds later.
    var usablePathChanges: AsyncStream<Int> {
        AsyncStream { continuation in
            let id = UUID()
            observers[id] = { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.observers[id] = nil }
            }
        }
    }

    private func apply(_ path: NWPath) {
        let nowOnline = path.status == .satisfied
        let nowInterface: Interface = {
            guard nowOnline else { return .none }
            if path.usesInterfaceType(.wifi) { return .wifi }
            if path.usesInterfaceType(.cellular) { return .cellular }
            if path.usesInterfaceType(.wiredEthernet) { return .wired }
            if path.usesInterfaceType(.other) { return .other }
            return .unknown
        }()

        let changed = nowOnline != isOnline || nowInterface != interface
        isOnline = nowOnline
        interface = nowInterface
        guard changed else { return }
        pathGeneration += 1
        // Only a path that can carry traffic is worth waking anyone for.
        guard nowOnline else { return }
        for observe in observers.values { observe(pathGeneration) }
    }

    #if DEBUG
    /// Drives the monitor by hand so the reconnection behaviour can be tested without a
    /// real network to break.
    func simulate(online: Bool, interface: Interface) {
        let changed = online != isOnline || interface != self.interface
        isOnline = online
        self.interface = interface
        guard changed else { return }
        pathGeneration += 1
        guard online else { return }
        for observe in observers.values { observe(pathGeneration) }
    }
    #endif
}
