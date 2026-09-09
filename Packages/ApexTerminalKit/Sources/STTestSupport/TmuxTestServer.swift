import Foundation

/// A real OpenSSH server with a real tmux behind it, in a container (D-057).
///
/// This machine has no tmux, and installing one on a developer's machine to make a test
/// pass is not this project's business. A container has the version the tests were written
/// against, pinned by the image tag, so what the client is talking to is stock tmux rather
/// than a hand-written stand-in — which matters more here than usual, because control mode
/// is a protocol with almost no specification and several shapes that only a running server
/// will tell you about.
public final class TmuxTestServer: @unchecked Sendable {
    public struct Fixtures: Sendable {
        public let host: String
        public let port: Int
        public let username: String
        public let password: String
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

    /// Whether this machine can run the container at all. A missing Docker makes the tests
    /// skip rather than fail: that is a fact about the machine, not about the client.
    public static var isAvailable: Bool { KeyboardInteractiveTestServer.isAvailable }

    public init(username: String = "tmuxtest") throws {
        guard let docker = KeyboardInteractiveTestServer.dockerPath else { throw StartupError.dockerMissing }
        let info = Self.run(docker, ["info", "--format", "{{.ServerVersion}}"])
        guard info.status == 0 else { throw StartupError.dockerNotRunning(info.output) }

        try Self.buildImageIfNeeded(docker: docker)

        containerName = "st-tmux-\(UUID().uuidString.prefix(8))"
        // Docker arbitrates the port rather than this process choosing one: asking the
        // kernel for a free port and then handing the number to Docker is a race, and one
        // that was actually lost in this repository once (D-054).
        var chosen: Int?
        for candidate in 8450 ... 8499 {
            let start = Self.run(docker, [
                "run", "--rm", "-d",
                "--name", containerName,
                "-p", "127.0.0.1:\(candidate):22",
                Self.imageTag,
            ])
            if start.status == 0 {
                chosen = candidate
                break
            }
            _ = Self.run(docker, ["rm", "-f", containerName])
        }
        guard let port = chosen else { throw StartupError.containerFailed("no free port in 8450–8499") }

        fixtures = Fixtures(host: "127.0.0.1", port: port, username: username, password: Self.password)

        do {
            try Self.waitUntilListening(host: "127.0.0.1", port: port)
        } catch {
            shutDown()
            throw error
        }
    }

    deinit { shutDown() }

    public func shutDown() {
        guard !stopped, let docker = KeyboardInteractiveTestServer.dockerPath else { return }
        stopped = true
        _ = Self.run(docker, ["rm", "-f", containerName])
    }

    // MARK: - The image

    static let imageTag = "apexterminal-tmux:2"
    static let password = "correct horse battery staple"

    static let dockerfile = """
    FROM debian:bookworm-slim

    RUN apt-get update \\
     && apt-get install -y --no-install-recommends openssh-server tmux \\
     && rm -rf /var/lib/apt/lists/* \\
     && mkdir -p /run/sshd

    RUN useradd -m -s /bin/bash tmuxtest \\
     && echo 'tmuxtest:\(password)' | chpasswd

    RUN printf '%s\\n' \\
          'Port 22' 'PermitRootLogin no' 'PubkeyAuthentication no' \\
          'PasswordAuthentication yes' 'LogLevel DEBUG1' \\
        > /etc/ssh/sshd_config.d/tmux.conf

    RUN ssh-keygen -A

    CMD ["/usr/sbin/sshd", "-D", "-e"]
    """

    private static func buildImageIfNeeded(docker: String) throws {
        if run(docker, ["image", "inspect", imageTag]).status == 0 { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-tmux-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try dockerfile.write(to: directory.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        let build = run(docker, ["build", "-q", "-t", imageTag, directory.path])
        guard build.status == 0 else { throw StartupError.imageBuildFailed(build.output) }
    }

    private static func waitUntilListening(host: String, port: Int, timeout: TimeInterval = 60) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if canConnect(host: host, port: port) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw StartupError.neverListened("no connection to \(host):\(port) within \(Int(timeout))s")
    }

    /// Connected is not the same as ready. Docker's port proxy accepts a connection as soon
    /// as the container starts, well before `sshd` inside it binds anything, so a plain
    /// connect returns true and the handshake that follows then waits for a server that is
    /// not there — measured: two tests failed with "the SSH handshake did not complete in
    /// time" until this read the greeting instead.
    private static func canConnect(host: String, port: Int) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(socketDescriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 64)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let read = recv(socketDescriptor, &buffer, buffer.count, 0)
        return read > 0 && String(decoding: buffer[0 ..< read], as: UTF8.self).hasPrefix("SSH-2.0-")
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, String(describing: error))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
