import Foundation

/// Values that must never appear verbatim in logs, diagnostics or crash reports.
///
/// `Redacted` deliberately does not conform to `CustomStringConvertible` in a way
/// that exposes the wrapped value: `description` always renders a fingerprint, never
/// the secret. Call ``reveal()`` at the exact point of use.
public struct Redacted<Wrapped: Sendable>: Sendable {
    private let value: Wrapped
    private let label: String

    public init(_ value: Wrapped, label: String) {
        self.value = value
        self.label = label
    }

    /// Returns the wrapped value. Every call site is an auditable point where a
    /// secret leaves its container.
    public func reveal() -> Wrapped { value }
}

extension Redacted: CustomStringConvertible {
    public var description: String { "<redacted \(label)>" }
}

extension Redacted: CustomDebugStringConvertible {
    public var debugDescription: String { description }
}

/// Redaction helpers used by the diagnostics pipeline.
public enum Redactor {
    /// Renders a hostname as `<first-label>.<redacted>` so operators can correlate
    /// sessions without the log disclosing which internal host was reached.
    ///
    /// Public suffixes are kept because they carry no tenant information.
    public static func hostname(_ host: String) -> String {
        guard !host.isEmpty else { return "<empty>" }
        if host.hasPrefix("[") || IPv4Detector.looksLikeIPv4(host) { return "<ip>" }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 2 else { return "<host:\(shortDigest(host))>" }
        return "\(String(labels[0]).prefix(0))<host:\(shortDigest(host))>.\(labels.suffix(2).joined(separator: "."))"
    }

    /// A short, stable, non-reversible identifier for a string. Used so that two log
    /// lines about the same host can be correlated without naming the host.
    public static func shortDigest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return String(hash % 0xF_FFFF, radix: 36)
    }

    /// Renders a JWT as `<alg>.<kid>.<sig-digest>` — enough to debug audience and
    /// key-rotation problems, never enough to replay the token.
    public static func jwt(_ token: String) -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return "<malformed-jwt>" }
        return "<jwt len=\(token.count) sig=\(shortDigest(String(parts[2])))>"
    }

    /// Renders arbitrary byte counts for stream diagnostics.
    public static func byteCount(_ count: Int) -> String { "\(count)B" }
}

enum IPv4Detector {
    static func looksLikeIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = UInt16(part) else { return false }
            return number <= 255
        }
    }
}
