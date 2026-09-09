import Crypto
import Foundation

/// A real OpenSSH server that accepts **only** keyboard-interactive authentication, with
/// two prompts in one exchange.
///
/// This machine's own `sshd` cannot be used for this. macOS builds it without PAM, so its
/// keyboard-interactive support falls back to BSD auth and asks for the login password of
/// a real account — nothing a test may know or type. A Linux container can, and the
/// server inside it is stock OpenSSH: the client under test is talking to the same
/// implementation it will meet in the world, not to a hand-written stand-in.
///
/// The PAM stack is `pam_unix` followed by `pam_google_authenticator`, so the exchange has
/// the shape that matters: a password prompt, then a one-time code prompt, both delivered
/// as `SSH_MSG_USERAUTH_INFO_REQUEST` and both answered before the server decides.
public final class KeyboardInteractiveTestServer: @unchecked Sendable {
    public struct Fixtures: Sendable {
        public let host: String
        public let port: Int
        public let username: String
        public let password: String
        /// The shared secret behind the second prompt, base32 as `pam_google_authenticator`
        /// stores it. Test-only: it is baked into the image.
        public let totpSecret: String
    }

    public enum StartupError: Error, CustomStringConvertible {
        case dockerMissing
        case dockerNotRunning(String)
        case imageBuildFailed(String)
        case containerFailed(String)
        case neverListened(String)

        public var description: String {
            switch self {
            case .dockerMissing: "docker is not installed"
            case let .dockerNotRunning(detail): "docker is not running: \(detail)"
            case let .imageBuildFailed(detail): "could not build the image: \(detail)"
            case let .containerFailed(detail): "could not start the container: \(detail)"
            case let .neverListened(detail): "the server never accepted a connection: \(detail)"
            }
        }
    }

    public let fixtures: Fixtures
    private let containerName: String
    private var stopped = false

    /// Whether this machine can run the container at all. Tests skip rather than fail
    /// when it cannot: a missing Docker is a property of the machine, and a red test that
    /// means "you have no Docker" teaches nothing.
    public static var isAvailable: Bool {
        guard let docker = dockerPath else { return false }
        return run(docker, ["info", "--format", "{{.ServerVersion}}"]).status == 0
    }

    static var dockerPath: String? {
        for path in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    public init(username: String = "kbdtest") throws {
        guard let docker = Self.dockerPath else { throw StartupError.dockerMissing }
        let info = Self.run(docker, ["info", "--format", "{{.ServerVersion}}"])
        guard info.status == 0 else { throw StartupError.dockerNotRunning(info.output) }

        try Self.buildImageIfNeeded(docker: docker)

        let port = try Self.freePort()
        containerName = "st-kbdi-\(UUID().uuidString.prefix(8))"
        let start = Self.run(docker, [
            "run", "--rm", "-d",
            "--name", containerName,
            "-p", "127.0.0.1:\(port):22",
            Self.imageTag,
        ])
        guard start.status == 0 else { throw StartupError.containerFailed(start.output) }

        fixtures = Fixtures(
            host: "127.0.0.1",
            port: port,
            username: username,
            password: Self.password,
            totpSecret: Self.totpSecret
        )

        // A container that is running is not yet a server that is listening.
        do {
            try Self.waitUntilListening(host: "127.0.0.1", port: port)
        } catch {
            shutDown()
            throw error
        }
    }

    deinit { shutDown() }

    public func shutDown() {
        guard !stopped, let docker = Self.dockerPath else { return }
        stopped = true
        _ = Self.run(docker, ["rm", "-f", containerName])
    }

    /// The server's log, for tests that need to assert on what it actually did.
    public func log() -> String {
        guard let docker = Self.dockerPath else { return "" }
        return Self.run(docker, ["logs", containerName]).output
    }

    // MARK: - The one-time code

    /// RFC 6238, over CryptoKit's HMAC-SHA1.
    ///
    /// This computes a code; it does not implement a primitive. The hashing is Apple's,
    /// and the arithmetic around it is the four lines the RFC specifies. It exists only so
    /// a test can answer the server's second question.
    public static func timeBasedCode(secret: String, at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let key = SymmetricKey(data: base32Decode(secret))
        let digest = withUnsafeBytes(of: &counter) { counterBytes in
            Array(HMAC<Insecure.SHA1>.authenticationCode(for: Data(counterBytes), using: key))
        }
        let offset = Int(digest[digest.count - 1] & 0x0F)
        let truncated =
            (UInt32(digest[offset] & 0x7F) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])
        return String(format: "%06u", truncated % 1_000_000)
    }

    static func base32Decode(_ text: String) -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var value = 0
        var output = Data()
        for character in text.uppercased() where character != "=" {
            guard let index = alphabet.firstIndex(of: character) else { continue }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                output.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return output
    }

    // MARK: - The image

    static let imageTag = "apexterminal-kbdi:2"
    static let password = "correct horse battery staple"
    static let totpSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    /// The Dockerfile, written out and built on first use. Kept in code rather than in a
    /// file beside the tests so that what the server is configured to do is readable next
    /// to the tests that depend on it.
    static let dockerfile = """
    FROM debian:bookworm-slim

    RUN apt-get update \\
     && apt-get install -y --no-install-recommends openssh-server libpam-google-authenticator \\
     && rm -rf /var/lib/apt/lists/* \\
     && mkdir -p /run/sshd

    RUN useradd -m -s /bin/bash kbdtest \\
     && echo 'kbdtest:\(password)' | chpasswd

    # The TOTP secret, in the format pam_google_authenticator reads. The options make it
    # deterministic enough for a test: a wide window so a slow build does not straddle a
    # boundary, and no reuse so a replayed code is refused.
    RUN printf '%s\\n' \\
          '\(totpSecret)' \\
          '" TOTP_AUTH' \\
          '" WINDOW_SIZE 17' \\
          '" DISALLOW_REUSE' \\
        > /home/kbdtest/.google_authenticator \\
     && chown kbdtest:kbdtest /home/kbdtest/.google_authenticator \\
     && chmod 400 /home/kbdtest/.google_authenticator

    # Two prompts in one keyboard-interactive exchange: the account password, then the code.
    RUN printf '%s\\n' \\
          'auth required pam_unix.so' \\
          'auth required pam_google_authenticator.so' \\
          'account required pam_unix.so' \\
          'session required pam_unix.so' \\
        > /etc/pam.d/sshd

    RUN printf '%s\\n' \\
          'Port 22' \\
          'PermitRootLogin no' \\
          'PubkeyAuthentication no' \\
          'PasswordAuthentication no' \\
          'KbdInteractiveAuthentication yes' \\
          'UsePAM yes' \\
          'AuthenticationMethods keyboard-interactive' \\
          'LogLevel DEBUG1' \\
        > /etc/ssh/sshd_config.d/kbdi.conf

    RUN ssh-keygen -A
    CMD ["/usr/sbin/sshd", "-D", "-e"]
    """

    private static func buildImageIfNeeded(docker: String) throws {
        let existing = run(docker, ["image", "inspect", imageTag, "--format", "{{.Id}}"])
        if existing.status == 0 { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-kbdi-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try dockerfile.write(
            to: directory.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )

        let build = run(docker, ["build", "-t", imageTag, directory.path], timeout: 600)
        guard build.status == 0 else { throw StartupError.imageBuildFailed(build.output) }
    }

    private static func freePort() throws -> Int {
        // Asking the kernel avoids the guesswork, and the ephemeral range is left alone so
        // an outbound connection cannot claim the port between here and the container.
        for candidate in 8300 ... 8399 {
            let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard socketDescriptor >= 0 else { continue }
            defer { close(socketDescriptor) }
            var reuse: Int32 = 1
            setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(candidate).bigEndian
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 { return candidate }
        }
        throw StartupError.containerFailed("no free port between 8300 and 8399")
    }

    private static func waitUntilListening(host: String, port: Int) throws {
        let deadline = Date().addingTimeInterval(30)
        var lastError = "timed out"
        while Date() < deadline {
            let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard socketDescriptor >= 0 else { continue }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr(host)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connected == 0 {
                // Listening is not the same as being sshd. Read the greeting, the way
                // OpenSSHTestServer does, so a stale listener cannot pass for the server.
                var buffer = [UInt8](repeating: 0, count: 64)
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(
                    socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                    socklen_t(MemoryLayout<timeval>.size)
                )
                let read = recv(socketDescriptor, &buffer, buffer.count, 0)
                close(socketDescriptor)
                if read > 0, String(decoding: buffer[0 ..< read], as: UTF8.self).hasPrefix("SSH-2.0-") {
                    return
                }
                lastError = "something answered on \(port) but did not greet as SSH"
            } else {
                close(socketDescriptor)
                lastError = "connection refused on \(port)"
            }
            usleep(250_000)
        }
        throw StartupError.neverListened(lastError)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) -> (
        status: Int32, output: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch { return (-1, String(describing: error)) }

        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while process.isRunning, Date() < deadline {
            data.append(handle.availableData)
            usleep(50_000)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        data.append(handle.readDataToEndOfFile())
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
