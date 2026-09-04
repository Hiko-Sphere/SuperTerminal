import Foundation
import os

/// Severity levels used across SuperTerminal.
public enum STLogLevel: Int, Sendable, Comparable, Codable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4

    public static func < (lhs: STLogLevel, rhs: STLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}

/// A single structured log record. Fields are pre-redacted by the caller; the log
/// pipeline never sees raw secrets, so exporting a diagnostics bundle is safe by
/// construction rather than by a scrubbing pass.
public struct STLogRecord: Sendable, Codable {
    public let timestamp: Date
    public let level: STLogLevel
    public let subsystem: String
    public let message: String
    public let fields: [String: String]

    public init(
        timestamp: Date = Date(),
        level: STLogLevel,
        subsystem: String,
        message: String,
        fields: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.message = message
        self.fields = fields
    }

    public var rendered: String {
        let sortedFields = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let suffix = sortedFields.isEmpty ? "" : " \(sortedFields)"
        return "[\(level.label)] \(subsystem): \(message)\(suffix)"
    }
}

/// Sink protocol so tests can assert on emitted records and the app can fan out to
/// both `OSLog` and the in-memory diagnostics ring buffer.
public protocol STLogSink: Sendable {
    func write(_ record: STLogRecord)
}

/// Thread-safe fan-out logger.
public struct STLogger: Sendable {
    private let subsystem: String
    private let sinks: [any STLogSink]
    private let minimumLevel: STLogLevel

    public init(subsystem: String, sinks: [any STLogSink], minimumLevel: STLogLevel = .info) {
        self.subsystem = subsystem
        self.sinks = sinks
        self.minimumLevel = minimumLevel
    }

    public func child(subsystem childSubsystem: String) -> STLogger {
        STLogger(subsystem: "\(subsystem).\(childSubsystem)", sinks: sinks, minimumLevel: minimumLevel)
    }

    public func log(_ level: STLogLevel, _ message: String, _ fields: [String: String] = [:]) {
        guard level >= minimumLevel else { return }
        let record = STLogRecord(level: level, subsystem: subsystem, message: message, fields: fields)
        for sink in sinks { sink.write(record) }
    }

    public func debug(_ message: String, _ fields: [String: String] = [:]) { log(.debug, message, fields) }
    public func info(_ message: String, _ fields: [String: String] = [:]) { log(.info, message, fields) }
    public func notice(_ message: String, _ fields: [String: String] = [:]) { log(.notice, message, fields) }
    public func warning(_ message: String, _ fields: [String: String] = [:]) { log(.warning, message, fields) }
    public func error(_ message: String, _ fields: [String: String] = [:]) { log(.error, message, fields) }

    /// A logger that discards everything. Used as a default so no code path is forced
    /// to invent a sink just to compile.
    public static let disabled = STLogger(subsystem: "disabled", sinks: [], minimumLevel: .error)
}

/// Bridges structured records into the unified logging system.
public struct OSLogSink: STLogSink {
    private let logger: os.Logger

    public init(subsystem: String, category: String) {
        logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func write(_ record: STLogRecord) {
        // Records are pre-redacted, but they are still marked private so that they
        // are elided from sysdiagnose captures taken on someone else's device.
        switch record.level {
        case .debug: logger.debug("\(record.rendered, privacy: .private)")
        case .info: logger.info("\(record.rendered, privacy: .private)")
        case .notice: logger.notice("\(record.rendered, privacy: .private)")
        case .warning: logger.warning("\(record.rendered, privacy: .private)")
        case .error: logger.error("\(record.rendered, privacy: .private)")
        }
    }
}

/// Bounded in-memory buffer backing the exportable diagnostics report.
public final class RingBufferLogSink: STLogSink, @unchecked Sendable {
    private let capacity: Int
    private var storage: [STLogRecord] = []
    private let lock = NSLock()

    public init(capacity: Int = 2000) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public func write(_ record: STLogRecord) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(record)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public func snapshot() -> [STLogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
    }
}
