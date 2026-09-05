import Foundation
import Testing
@testable import SuperTerminal

/// Platform detection is a pure reading of what a server prints (D-019). The strings here
/// are what real systems print: `uname -s` on macOS, Linux and the BSDs, `cmd /c ver` on
/// Windows, and the two shells' complaints when `uname` does not exist there.
@Suite("Server platform")
struct HostPlatformTests {
    @Test("uname names the POSIX systems")
    func unameIsEnough() {
        #expect(HostPlatform.detect(unameOutput: "Darwin\n", windowsVersionOutput: nil) == .macOS)
        #expect(HostPlatform.detect(unameOutput: "Linux\n", windowsVersionOutput: nil) == .linux)
        #expect(HostPlatform.detect(unameOutput: "FreeBSD\n", windowsVersionOutput: nil) == .bsd)
        #expect(HostPlatform.detect(unameOutput: "OpenBSD\n", windowsVersionOutput: nil) == .bsd)
        #expect(HostPlatform.detect(unameOutput: "SunOS\n", windowsVersionOutput: nil) == .other)
        #expect(HostPlatform.detect(unameOutput: "MINGW64_NT-10.0-22631\n", windowsVersionOutput: nil) == .windows)
    }

    @Test("Windows is read from ver when uname is missing, whatever shell complained")
    func windowsFallsBackToVer() {
        let ver = "\nMicrosoft Windows [Version 10.0.22631.4037]\n"
        #expect(HostPlatform.detect(unameOutput: nil, windowsVersionOutput: ver) == .windows)
        // cmd's complaint arrives on stderr, so uname output is empty and ver decides.
        #expect(HostPlatform.detect(unameOutput: "", windowsVersionOutput: ver) == .windows)
        // A shell that echoes its complaint to stdout must not be read as a kernel name.
        let powershell = "uname : The term 'uname' is not recognized as the name of a cmdlet, function, script file, or operable program."
        #expect(HostPlatform.detect(unameOutput: powershell, windowsVersionOutput: ver) == .windows)
        #expect(HostPlatform.detect(unameOutput: "'uname' is not recognized as an internal or external command", windowsVersionOutput: nil) == nil)
    }

    @Test("Nothing usable leaves the record alone")
    func noAnswerIsNoGuess() {
        #expect(HostPlatform.detect(unameOutput: nil, windowsVersionOutput: nil) == nil)
        #expect(HostPlatform.detect(unameOutput: "  \n", windowsVersionOutput: "") == nil)
    }

    @Test("A record written before the field existed decodes, and the hand-set value wins")
    func recordsBeforeTheFieldDecode() throws {
        let json = """
        {"id":"7B1F0C3E-3A57-4E0C-9E63-5F2A6D9C1B22","name":"Old","hostname":"old.example",
         "port":22,"username":"me","transport":{"directTCP":{}},"credentials":[],"tags":[],
         "terminalType":"xterm-256color","environment":{}}
        """
        var host = try JSONDecoder().decode(Host.self, from: Data(json.utf8))
        #expect(host.platformOverride == nil)
        #expect(host.detectedPlatform == nil)
        #expect(host.effectivePlatform == nil)
        host.detectedPlatform = .linux
        #expect(host.effectivePlatform == .linux)
        host.platformOverride = .windows
        #expect(host.effectivePlatform == .windows, "what the user set outranks what was detected")
        let back = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))
        #expect(back.platformOverride == .windows && back.detectedPlatform == .linux)
    }

    @Test("Recording the same detection twice writes the store once")
    @MainActor func detectionDoesNotChurnTheStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostStore(directory: directory)
        let host = Host(name: "Box", hostname: "box.example", username: "me", credentials: [.password])
        store.add(host)
        var writes = 0
        store.didChange = { writes += 1 }
        store.recordDetectedPlatform(.macOS, forHostID: host.id)
        store.recordDetectedPlatform(.macOS, forHostID: host.id)
        #expect(writes == 1, "a repeat of what is known must not touch the store or wake sync")
        #expect(store.hosts.first?.effectivePlatform == .macOS)
        store.recordDetectedPlatform(.linux, forHostID: UUID())
        #expect(writes == 1, "an unknown host is ignored")
    }
}
