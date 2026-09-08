import Foundation
import NIOTransportServices
import STCore
import STSSH

/// Every forwarding rule running on one SSH connection (D-045).
///
/// A forward lives exactly as long as the connection under it. That is not a limitation
/// worked around here, it is the truth being made visible: iOS suspends an app that is not
/// on screen, and a suspended app's sockets stop being served. Nothing in this file claims
/// otherwise, and the interface above it says so where a person can read it, rather than
/// letting them discover it when a tunnel they were relying on has quietly been dead for
/// an hour.
public actor ForwardingSession {
    private let connection: SSHConnection
    private let group: NIOTSEventLoopGroup
    private let log: STLogger
    private var running: [PortForward.ID: Running] = [:]

    private struct Running {
        var rule: PortForward
        var state: PortForwardState
        var counter: TrafficCounter
        var local: LocalForwardListener?
        var remote: RemoteForwardListener?
    }

    public init(connection: SSHConnection, group: NIOTSEventLoopGroup, log: STLogger = .disabled) {
        self.connection = connection
        self.group = group
        self.log = log.child(subsystem: "forwarding")
    }

    /// Starts a rule, and reports what happened. Never throws: a rule that could not start
    /// is a state the interface shows, not an error the caller has to catch — several
    /// rules start together and one refusing must not stop the rest.
    @discardableResult
    public func start(_ rule: PortForward) async -> PortForwardState {
        if let existing = running[rule.id], existing.state.isRunning { return existing.state }
        let counter = running[rule.id]?.counter ?? TrafficCounter()
        counter.reset()
        running[rule.id] = Running(rule: rule, state: .starting, counter: counter, local: nil, remote: nil)

        do {
            switch rule.kind {
            case .local, .dynamic:
                let listener = LocalForwardListener(
                    rule: rule, connection: connection, counter: counter, group: group, log: log
                )
                let port = try await listener.start()
                running[rule.id] = Running(
                    rule: rule, state: .running(port: port), counter: counter, local: listener, remote: nil
                )
            case .remote:
                let listener = RemoteForwardListener(
                    rule: rule, connection: connection, counter: counter, group: group, log: log
                )
                let port = try await listener.start()
                running[rule.id] = Running(
                    rule: rule, state: .running(port: port), counter: counter, local: nil, remote: listener
                )
            }
        } catch {
            let failure = error as? STError
            running[rule.id] = Running(
                rule: rule,
                state: .failed(
                    message: failure?.message ?? String(localized: "The forward could not be started.", bundle: .module),
                    recovery: failure?.recoverySuggestion
                ),
                counter: counter,
                local: nil,
                remote: nil
            )
        }
        return running[rule.id]?.state ?? .stopped
    }

    public func stop(_ id: PortForward.ID) async {
        guard let entry = running[id] else { return }
        running[id]?.state = .stopped
        await entry.local?.stop()
        await entry.remote?.stop()
        running[id] = Running(rule: entry.rule, state: .stopped, counter: entry.counter, local: nil, remote: nil)
    }

    /// Stops everything. Called when the connection goes, so that a rule never reports
    /// itself as running over a connection that no longer exists.
    public func stopAll() async {
        for id in running.keys { await stop(id) }
    }

    public func state(of id: PortForward.ID) -> PortForwardState {
        running[id]?.state ?? .stopped
    }

    public func traffic(of id: PortForward.ID) -> PortForwardTraffic {
        running[id]?.counter.snapshot ?? PortForwardTraffic()
    }

    /// Everything at once, for a view that redraws on a timer rather than asking per row.
    public func snapshot() -> [PortForward.ID: PortForwardSnapshot] {
        running.mapValues { PortForwardSnapshot(state: $0.state, traffic: $0.counter.snapshot) }
    }
}

public struct PortForwardSnapshot: Sendable, Equatable {
    public var state: PortForwardState
    public var traffic: PortForwardTraffic

    public init(state: PortForwardState, traffic: PortForwardTraffic) {
        self.state = state
        self.traffic = traffic
    }
}
