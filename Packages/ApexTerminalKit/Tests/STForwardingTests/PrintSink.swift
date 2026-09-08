import Foundation
import STCore

/// Prints log records while a test runs, so a forward that silently does nothing can be
/// asked what it thinks it is doing.
final class PrintSink: STLogSink, @unchecked Sendable {
    func write(_ record: STLogRecord) {
        FileHandle.standardError.write(Data("[\(record.subsystem)] \(record.message) \(record.fields)\n".utf8))
    }
}

extension STLogger {
    /// Silent unless `ST_FORWARD_LOG` is set, so a failing forward can be asked what it
    /// thinks it is doing without every other run drowning in it.
    static var forTests: STLogger {
        guard ProcessInfo.processInfo.environment["ST_FORWARD_LOG"] != nil else { return .disabled }
        return STLogger(subsystem: "test", sinks: [PrintSink()], minimumLevel: .debug)
    }
}
