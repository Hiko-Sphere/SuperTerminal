import Foundation

// Spawns a real `sshd`, so it exists only where a process can be spawned. An iOS
// test target links this module for the parts that can run there — the relay used to
// break a connection on purpose — and must not fail to build over this one.
#if os(macOS)


/// Runs a real OpenSSH `sshd` on an ephemeral port for integration tests.
///
/// **Run the package's tests with `--no-parallel`.** Starting a server blocks the thread it
/// is constructed on while it polls for sshd to answer, and in an `async` test that thread
/// belongs to Swift Concurrency's cooperative pool. One or two at a time is harmless;
/// enough suites doing it at once starves the pool, and the tasks waiting on an SSH
/// handshake elsewhere never get a thread to resume on — reported, thirty seconds later,
/// as a transport failure in whichever suite drew the short straw. Measured on 2026-09-08:
/// six parallel runs of the full package, four with one such failure, never the same test
/// twice; the same suite with `--no-parallel` passes and takes 113 seconds instead of 35.
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
        /// PEM text of an unencrypted RSA client key in `authorized_keys`.
        public let clientRSAPrivateKeyPEM: String
        /// A key that is deliberately **not** in `authorized_keys`, together with the
        /// certificate an authority issued for it (D-046). A connection that succeeds
        /// with this key succeeded because of the certificate and for no other reason.
        public let certifiedClientPrivateKeyPEM: String
        public let clientCertificateOpenSSH: String
        /// The authority's own public key, for a client that wants to trust it.
        public let certificateAuthorityPublicKey: String
        /// The certificate the server presents for its own host key, when it was asked
        /// to. Empty when the server offers a bare host key.
        public let hostCertificateOpenSSH: String
        /// The server's Ed25519 host key in `authorized_keys` one-line form.
        public let hostKeyOpenSSH: String
    }

    /// Host key types the test server can be configured to offer.
    /// How the server treats OpenSSH certificates (D-046).
    public struct CertificateOptions: Sendable {
        /// Whether sshd trusts the authority for user certificates (`TrustedUserCAKeys`).
        public var trustsAuthority: Bool
        /// Whether sshd presents a certificate for its own host key.
        public var presentsHostCertificate: Bool
        /// The principal the client's certificate is issued for. `nil` means the user the
        /// tests log in as, which is what makes a certificate usable.
        public var userPrincipal: String?
        public var keyID: String
        /// `ssh-keygen -V`, so a test can issue one that has already expired.
        public var validity: String
        /// The host name the host certificate is issued for.
        public var hostPrincipal: String
        public var hostValidity: String

        public init(
            trustsAuthority: Bool = false,
            presentsHostCertificate: Bool = false,
            userPrincipal: String? = nil,
            keyID: String = "st-test-user-cert",
            validity: String = "-5m:+60m",
            hostPrincipal: String = "127.0.0.1",
            hostValidity: String = "-5m:+60m"
        ) {
            self.trustsAuthority = trustsAuthority
            self.presentsHostCertificate = presentsHostCertificate
            self.userPrincipal = userPrincipal
            self.keyID = keyID
            self.validity = validity
            self.hostPrincipal = hostPrincipal
            self.hostValidity = hostValidity
        }
    }

    public enum HostKeyAlgorithm: String, Sendable, Hashable {
        case ed25519
        case ecdsa
        case rsa
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

    /// - Parameter extraAuthorizedKeys: additional `authorized_keys` lines to trust, so a
    ///   test can prove a key it generated itself is accepted by a real server.
    /// - Parameters:
    ///   - extraAuthorizedKeys: additional `authorized_keys` lines to trust.
    ///   - hostKeyAlgorithms: which host keys the server offers. Restricting this to RSA
    ///     is how a client's RSA host-key support is proved: with no Ed25519 or ECDSA host
    ///     key present, a connection can only succeed through RSA.
    ///   - ciphers: when set, restricts the server's `Ciphers` and `MACs` lists. Narrowing
    ///     this to the CTR family is how a client's non-GCM support is proved: with AES-GCM
    ///     unavailable, a connection can only succeed through the other scheme.
    /// - Parameters:
    ///   - certificateOptions: how the server treats OpenSSH certificates (D-046). The
    ///     authority and the client's certificate are always created, because they cost a
    ///     key generation and make the fixtures useful; what these change is whether the
    ///     *server* trusts the authority and whether it presents a certificate of its own.
    public init(
        extraAuthorizedKeys: [String] = [],
        hostKeyAlgorithms: Set<HostKeyAlgorithm> = [.ed25519, .ecdsa],
        ciphers: (ciphers: String, macs: String)? = nil,
        certificateOptions: CertificateOptions = .init()
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: Self.sshdPath) else {
            throw StartupError.sshdMissing(Self.sshdPath)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-sshd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let username = NSUserName()

        if hostKeyAlgorithms.contains(.ed25519) {
            try Self.keygen(["-t", "ed25519", "-f", root.appendingPathComponent("host_ed25519").path, "-N", "", "-q", "-C", "st-test-host"])
        }
        if hostKeyAlgorithms.contains(.ecdsa) {
            try Self.keygen(["-t", "ecdsa", "-b", "256", "-f", root.appendingPathComponent("host_ecdsa").path, "-N", "", "-q", "-C", "st-test-host"])
        }
        if hostKeyAlgorithms.contains(.rsa) {
            try Self.keygen(["-t", "rsa", "-b", "3072", "-f", root.appendingPathComponent("host_rsa").path, "-N", "", "-q", "-C", "st-test-host"])
        }
        try Self.keygen(["-t", "ed25519", "-f", root.appendingPathComponent("client_ed25519").path, "-N", "", "-q", "-C", "st-test-client"])
        // The authority, the key it vouches for, and the certificate itself. The key is
        // never added to `authorized_keys`; that is what makes a successful login with it
        // evidence about certificates rather than about key files.
        try Self.keygen(["-t", "ed25519", "-f", root.appendingPathComponent("ca").path, "-N", "", "-q", "-C", "st-test-ca"])
        try Self.keygen(["-t", "ed25519", "-f", root.appendingPathComponent("client_certified").path, "-N", "", "-q", "-C", "st-test-certified"])
        try Self.keygen([
            "-s", root.appendingPathComponent("ca").path,
            "-I", certificateOptions.keyID,
            "-n", certificateOptions.userPrincipal ?? NSUserName(),
            "-V", certificateOptions.validity,
            root.appendingPathComponent("client_certified.pub").path,
        ])
        try Self.keygen(["-t", "ecdsa", "-b", "256", "-f", root.appendingPathComponent("client_ecdsa").path, "-N", "", "-q", "-C", "st-test-client-ecdsa"])
        try Self.keygen(["-t", "rsa", "-b", "3072", "-f", root.appendingPathComponent("client_rsa").path, "-N", "", "-q", "-C", "st-test-client-rsa"])

        let passphrase = "correct horse battery staple"
        let encryptedPath = root.appendingPathComponent("client_ed25519_encrypted")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("client_ed25519"),
            to: encryptedPath
        )
        try Self.keygen(["-p", "-f", encryptedPath.path, "-P", "", "-N", passphrase, "-q"])

        var authorizedKeys = try String(contentsOf: root.appendingPathComponent("client_ed25519.pub"), encoding: .utf8)
            + (try String(contentsOf: root.appendingPathComponent("client_ecdsa.pub"), encoding: .utf8))
            + (try String(contentsOf: root.appendingPathComponent("client_rsa.pub"), encoding: .utf8))
        for line in extraAuthorizedKeys {
            authorizedKeys += line.hasSuffix("\n") ? line : line + "\n"
        }
        let authorizedKeysURL = root.appendingPathComponent("authorized_keys")
        try authorizedKeys.write(to: authorizedKeysURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedKeysURL.path)

        // The server's own certificate, when asked for. `-h` marks it a host certificate;
        // the principal is the name a client will connect to.
        var hostCertificateLine = ""
        if certificateOptions.presentsHostCertificate, hostKeyAlgorithms.contains(.ed25519) {
            try Self.keygen([
                "-s", root.appendingPathComponent("ca").path,
                "-h",
                "-I", "st-test-host-cert",
                "-n", certificateOptions.hostPrincipal,
                "-V", certificateOptions.hostValidity,
                root.appendingPathComponent("host_ed25519.pub").path,
            ])
            hostCertificateLine = "HostCertificate \(root.appendingPathComponent("host_ed25519-cert.pub").path)"
        }

        let hostKeyLines = hostKeyAlgorithms
            .sorted { $0.rawValue < $1.rawValue }
            .map { algorithm -> String in
                switch algorithm {
                case .ed25519: "HostKey \(root.appendingPathComponent("host_ed25519").path)"
                case .ecdsa: "HostKey \(root.appendingPathComponent("host_ecdsa").path)"
                case .rsa: "HostKey \(root.appendingPathComponent("host_rsa").path)"
                }
            }
            .joined(separator: "\n")

        logURL = root.appendingPathComponent("sshd.log")

        // Start on a port, and make sure the thing now answering on it is really this
        // sshd. The port is chosen by binding zero and letting go, so there is a window in
        // which something else can take it — and when it does, the old check ("can I
        // connect?") was satisfied by the thief. The test then handshook with whatever was
        // there, timed out thirty seconds later, and reported a transport failure in a
        // suite that had done nothing wrong. Reading the greeting removes the ambiguity,
        // and a stolen port simply costs another attempt.
        var startedProcess: Process?
        var startedPort = 0
        var lastFailure = "sshd did not start"
        for _ in 0 ..< 5 {
            let port = try Self.reserveEphemeralPort()
            let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        \(hostKeyLines)
        PidFile \(root.appendingPathComponent("sshd.pid").path)
        AuthorizedKeysFile \(authorizedKeysURL.path)
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PermitUserEnvironment no
        AcceptEnv ST_TEST_*
        \(certificateOptions.trustsAuthority ? "TrustedUserCAKeys \(root.appendingPathComponent("ca.pub").path)" : "")
        \(hostCertificateLine)
        Subsystem sftp internal-sftp
        \(ciphers.map { "Ciphers \($0.ciphers)\nMACs \($0.macs)" } ?? "")
        LogLevel DEBUG1
        """
            let configURL = root.appendingPathComponent("sshd_config")
            try config.write(to: configURL, atomically: true, encoding: .utf8)

            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let logHandle = try FileHandle(forWritingTo: logURL)

            let candidate = Process()
            candidate.executableURL = URL(fileURLWithPath: Self.sshdPath)
            candidate.arguments = ["-f", configURL.path, "-D", "-e"]
            candidate.standardError = logHandle
            candidate.standardOutput = logHandle
            try candidate.run()
            Self.watch(sshd: candidate.processIdentifier, root: root)

            if Self.waitUntilSSHAnswers(port: port, process: candidate) {
                startedProcess = candidate
                startedPort = port
                break
            }
            lastFailure = (try? String(contentsOf: logURL, encoding: .utf8)) ?? lastFailure
            if candidate.isRunning { kill(candidate.processIdentifier, SIGKILL) }
        }
        guard let started = startedProcess else { throw StartupError.didNotListen(lastFailure) }
        process = started
        let port = startedPort

        fixtures = Fixtures(
            root: root,
            port: port,
            username: username,
            clientPrivateKeyPEM: try String(contentsOf: root.appendingPathComponent("client_ed25519"), encoding: .utf8),
            encryptedClientPrivateKeyPEM: try String(contentsOf: encryptedPath, encoding: .utf8),
            clientKeyPassphrase: passphrase,
            clientECDSAPrivateKeyPEM: try String(contentsOf: root.appendingPathComponent("client_ecdsa"), encoding: .utf8),
            clientRSAPrivateKeyPEM: try String(contentsOf: root.appendingPathComponent("client_rsa"), encoding: .utf8),
            certifiedClientPrivateKeyPEM: try String(contentsOf: root.appendingPathComponent("client_certified"), encoding: .utf8),
            clientCertificateOpenSSH: try String(contentsOf: root.appendingPathComponent("client_certified-cert.pub"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            certificateAuthorityPublicKey: try String(contentsOf: root.appendingPathComponent("ca.pub"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            hostCertificateOpenSSH: (try? String(contentsOf: root.appendingPathComponent("host_ed25519-cert.pub"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            hostKeyOpenSSH: try String(
                contentsOf: root.appendingPathComponent(
                    hostKeyAlgorithms.contains(.ed25519) ? "host_ed25519.pub" : "host_rsa.pub"
                ),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        )
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

    /// Ties the server's life to this process's.
    ///
    /// `shutDown()` and `deinit` cover every path on which the test process keeps
    /// running. They cover none on which it does not: a run killed from outside, or a
    /// crash, left every server listening — over a hundred were found on one machine.
    /// A separate shell polls for this process and kills the server when it is gone; it
    /// costs one sleeping process per server and exits by itself when the run ends.
    private static func watch(sshd: Int32, root: URL) {
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 1; done; kill -9 \"$2\" 2>/dev/null; rm -rf \"$3\"",
            "st-sshd-watchdog",
            String(ProcessInfo.processInfo.processIdentifier),
            String(sshd),
            root.path,
        ]
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        // A watchdog that cannot start leaves things exactly as they were before it
        // existed, so its failure is not the server's.
        try? watchdog.run()
    }

    /// Whether an SSH server — this one — is answering on the port.
    private static func waitUntilSSHAnswers(port: Int, process: Process, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if greetsAsSSH(port: port) { return true }
            guard process.isRunning else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Connects and reads the first few bytes, which an SSH server sends unprompted.
    ///
    /// Anything else on the port — a forwarding listener from another test, a stray
    /// process — either says something different or says nothing, and both answer the
    /// question this is really asking: is the server we just started the one here?
    private static func greetsAsSSH(port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return false }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4)
        let read = recv(socketFD, &buffer, buffer.count, 0)
        guard read == 4 else { return false }
        return buffer == Array("SSH-".utf8)
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

#endif
