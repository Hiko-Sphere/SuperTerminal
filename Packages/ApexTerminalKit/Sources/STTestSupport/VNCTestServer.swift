import Foundation

// A real VNC server for the client's tests: LibVNCServer, the library behind x11vnc and
// many others, driving a small C program that serves a known pattern and logs every
// pointer, key and clipboard event it receives. Compiled once per test process against
// the Homebrew-installed library and run on an ephemeral port; a watchdog shell kills it
// when the test process is gone, the way the OpenSSH test server is guarded (D-022).
#if os(macOS)

public final class VNCTestServer: @unchecked Sendable {
    public enum StartupError: Error, CustomStringConvertible {
        case libraryMissing(String)
        case compileFailed(String)
        case didNotListen(String)

        public var description: String {
            switch self {
            case let .libraryMissing(path): "LibVNCServer was not found at \(path); install it with `brew install libvncserver`"
            case let .compileFailed(output): "the VNC test server did not compile:\n\(output)"
            case let .didNotListen(log): "the VNC test server did not start listening. Log:\n\(log)"
            }
        }
    }

    public let port: Int
    public let logURL: URL
    private let process: Process
    private let root: URL

    private static let libraryPrefixes = ["/opt/homebrew/opt/libvncserver", "/usr/local/opt/libvncserver"]
    private static let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/vnc-test-server.c")
    private static let binary: Result<URL, Error> = compile()

    /// Compiles the server once per process into a temporary directory.
    private static func compile() -> Result<URL, Error> {
        guard let prefix = libraryPrefixes.first(where: { FileManager.default.fileExists(atPath: $0 + "/include/rfb/rfb.h") }) else {
            return .failure(StartupError.libraryMissing(libraryPrefixes.joined(separator: " or ")))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("st-vnc-build-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("vnc-test-server")
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-O2", "-o", output.path, sourceURL.path, "-I\(prefix)/include", "-L\(prefix)/lib", "-lvncserver", "-Wl,-rpath,\(prefix)/lib"]
        let pipe = Pipe()
        cc.standardError = pipe
        cc.standardOutput = pipe
        do { try cc.run() } catch { return .failure(error) }
        cc.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard cc.terminationStatus == 0 else { return .failure(StartupError.compileFailed(text)) }
        return .success(output)
    }

    public init(password: String?) throws {
        let binary = try Self.binary.get()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("st-vnc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        logURL = root.appendingPathComponent("events.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        port = try Self.reserveEphemeralPort()
        process = Process()
        process.executableURL = binary
        process.arguments = [String(port), logURL.path] + (password.map { [$0] } ?? [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        Self.watch(pid: process.processIdentifier, root: root)
        _ = try waitForLog(containingSync: "listening", timeout: 10)
    }

    /// Waits until the server's event log contains `needle`, returning the whole log.
    public func waitForLog(containing needle: String, timeout: Duration) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if log.contains(needle) { return log }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw StartupError.didNotListen((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
    }

    private func waitForLog(containingSync needle: String, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if log.contains(needle) { return log }
            guard process.isRunning else { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw StartupError.didNotListen((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
    }

    public func shutDown() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: root)
    }

    deinit { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

    private static func watch(pid: Int32, root: URL) {
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 1; done; kill -9 \"$2\" 2>/dev/null; rm -rf \"$3\"",
                              "st-vnc-watchdog", String(ProcessInfo.processInfo.processIdentifier), String(pid), root.path]
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try? watchdog.run()
    }

    private static func reserveEphemeralPort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw StartupError.didNotListen("no probe socket") }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw StartupError.didNotListen("could not bind a probe socket") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
        return Int(UInt16(bigEndian: actual.sin_port))
    }
}
#endif
