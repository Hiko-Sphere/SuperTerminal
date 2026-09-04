import Foundation

/// Runs a real OpenSSH `sshd` on an ephemeral port for integration tests.
///
/// This is a genuine SSH server — the same binary the user's servers run — not a
/// simulation. Testing the client against a hand-written stand-in would prove only
/// that the client agrees with the stand-in; the point of these tests is to prove it
/// agrees with OpenSSH.
///
/// The server runs unprivileged with its own host keys, its own `authorized_keys` and
/// its own working directory under a temporary path, so it cannot interfere with the
/// machine's real SSH configuration.
public final class OpenSSHTestServer: @unchecked Sendable {
    public struct Fixtures: Sendable {
        public let root: URL
        public let port: Int
        public let username: String
        /// PEM text of an unencrypted Ed25519 client key present in `authorized_keys`.
        public let clientPrivateKeyPEM: String
        /// PEM text of the same key, encrypted with ``clientKeyPassphrase``.
        public let encryptedClientPrivateKeyPEM: String
        public let clientKeyPassphrase: String
        /// PEM text of an unencrypted ECDSA P-256 client key in `authorized_keys`.
        public let clientECDSAPrivateKeyPEM: String
        /// The server's Ed25519 host key in `authorized_keys` one-line form.
        public let hostKeyOpenSSH: String
    }

    public enum StartupError: Error, CustomStringConvertible {
        case sshdMissing(String)
        case keygenFailed(String)
        case didNotListen(String)

        public var description: String {
            switch self {
            case let .sshdMissing(path): "sshd was not found at \(path); integration tests need OpenSSH installed"
            case let .keygenFailed(detail): "ssh-keygen failed: \(detail)"
            case let .didNotListen(log): "sshd did not start listening. Log:\n\(log)"
            }
        }
    }

    private static let sshdPath = "/usr/sbin/sshd"
    private static let keygenPath = "/usr/bin/ssh-keygen"

    public let fixtures: Fixtures
    private let process: Process
    private let logURL: URL

    public init() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.sshdPath) else {
            throw StartupError.sshdMissing(Self.sshdPath)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-sshd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let port = try Self.reserveEphemeralPort()
        let username = NSUserName()

        try Self.keygen(["-t", "ed25519", "-f", root.appendingPathComponent("host_ed25519").path, "-N", "", "-q", "-C", "st-test-host"])
        try Self.keygen(["-t", "ecdsa", "-b", "256", "-f", root.appendingPathComponent("host_ecdsa").path, "-N", "", "-q", "-C", "st-test-host"])
        try Self.keygen(["-t", "ed25519", "-f", root.appendingPathComponent("client_ed25519").path, "-N", "", "-q", "-C", "st-test-client"])
        try Self.keygen(["-t", "ecdsa", "-b", "256", "-f", root.appendingPathComponent("client_ecdsa").path, "-N", "", "-q", "-C", "st-test-client-ecdsa"])

        let passphrase = "correct horse battery staple"
        let encryptedPath = root.appendingPathComponent("client_ed25519_encrypted")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("client_ed25519"),
            to: encryptedPath
        )
        try Self.keygen(["-p", "-f", encryptedPath.path, "-P", "", "-N", passphrase, "-q"])

        let authorizedKeys = try String(contentsOf: root.appendingPathComponent("client_ed25519.pub"), encoding: .utf8)
            + (try String(contentsOf: root.appendingPathComponent("client_ecdsa.pub"), encoding: .utf8))
        let authorizedKeysURL = root.appendingPathComponent("authorized_keys")
        try authorizedKeys.write(to: authorizedKeysURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedKeysURL.path)

        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(root.appendingPathComponent("host_ed25519").path)
        HostKey \(root.appendingPathComponent("host_ecdsa").path)
        PidFile \(root.appendingPathComponent("sshd.pid").path)
        AuthorizedKeysFile \(authorizedKeysURL.path)
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PermitUserEnvironment no
        AcceptEnv ST_TEST_*
        LogLevel DEBUG1
        """
        let configURL = root.appendingPathComponent("sshd_config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        logURL = root.appendingPathComponent("sshd.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshdPath)
        process.arguments = ["-f", configURL.path, "-D", "-e"]
        process.standardError = logHandle
        process.standardOutput = logHandle
        try process.run()

        fixtures = Fixtures(
            root: root,
            port: port,
            username: username,
            clientPrivateKeyPEM: try String(contentsOf: root.appendingPathComponent("client_ed25519"), encoding: .utf8),
            encryptedClientPrivateKeyPEM: try String(contentsOf: encryptedPath, encoding: .utf8),
            clientKeyPassphrase: passphrase,
            clientECDSAPrivateKeyPEM: try String(contentsOf: root.appendingPathComponent("client_ecdsa"), encoding: .utf8),
            hostKeyOpenSSH: try String(contentsOf: root.appendingPathComponent("host_ed25519.pub"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )

        try waitUntilListening(port: port)
    }

    /// The server's Ed25519 host key fingerprint, for pinning assertions.
    public var hostKeyOpenSSHLine: String { fixtures.hostKeyOpenSSH }

    public func log() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    /// Stops the server and removes its temporary directory.
    ///
    /// `Process.waitUntilExit()` is deliberately not used: it blocks the calling thread
    /// indefinitely, and when several suites tear down at once on Swift Concurrency's
    /// cooperative pool that is enough to starve the pool and hang the whole run.
    /// SIGKILL plus a bounded poll gives the same guarantee — the port is free before we
    /// return — without ever parking a cooperative thread for long.
    public func shutDown() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                usleep(20_000)
            }
        }
        try? FileManager.default.removeItem(at: fixtures.root)
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func waitUntilListening(port: Int, timeout: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.canConnect(port: port) { return }
            guard process.isRunning else { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw StartupError.didNotListen(log())
    }

    private static func canConnect(port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Binds port 0, reads back the assigned port, then releases it.
    ///
    /// There is an inherent race between releasing and sshd binding, but using a
    /// kernel-assigned port is still far more reliable than picking a fixed one when
    /// several test suites run at once.
    private static func reserveEphemeralPort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw StartupError.didNotListen("could not create a probe socket") }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw StartupError.didNotListen("could not bind a probe socket") }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketFD, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else { throw StartupError.didNotListen("could not read the probe socket's port") }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private static func keygen(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: keygenPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw StartupError.keygenFailed(detail)
        }
    }
}
