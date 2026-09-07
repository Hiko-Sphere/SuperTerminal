import Foundation
import NIOCore
import NIOPosix
import STTestSupport
import Testing
@testable import STVNC

/// Every claim here is checked against LibVNCServer — the reference server library behind
/// x11vnc and many others — run as a local process that serves a known pattern and logs
/// the input it receives (D-022). Nothing is mocked: the bytes cross a real socket.
@Suite("VNC client against LibVNCServer", .serialized)
struct VNCClientTests {
    private static let encodingSets: [[RFB.Encoding]] = [
        [.zrle], [.hextile], [.rre], [.raw], [.copyRect, .raw], RFB.Encoding.preferred,
    ]

    /// The pattern the server draws: pixel (x, y) is R = x, G = y, B = x ^ y, masked to
    /// a byte, converted by the server into the client's own pixel format.
    private func expectPattern(_ framebuffer: RFBFramebuffer, comment: String) {
        #expect(framebuffer.width == 320 && framebuffer.height == 200, "\(comment): size")
        for (x, y) in [(10, 20), (300, 190), (0, 0), (319, 199), (77, 3)] {
            let p = framebuffer.pixel(x: x, y: y)
            #expect(p.r == UInt8(x & 255) && p.g == UInt8(y & 255) && p.b == UInt8((x ^ y) & 255),
                    "\(comment): pixel (\(x),\(y)) = r\(p.r) g\(p.g) b\(p.b)")
        }
    }

    @Test("Each encoding decodes the pattern the server sends", arguments: encodingSets)
    func decodesPattern(encodings: [RFB.Encoding]) async throws {
        let server = try VNCTestServer(password: nil)
        defer { server.shutDown() }
        let group = MultiThreadedEventLoopGroup.singleton
        let client = try await VNCClient.connect(
            host: "127.0.0.1", port: server.port,
            options: .init(encodings: encodings + [.desktopSize]), group: group
        )
        var updates = 0
        let deadline = ContinuousClock.now + .seconds(5)
        for await event in client.events {
            if case .framebufferUpdated = event { updates += 1 }
            if updates >= 2 || ContinuousClock.now > deadline { break }
        }
        #expect(updates >= 2, "the server repaints a square every 500 ms; two updates must arrive")
        expectPattern(client.framebuffer, comment: "\(encodings)")
        await client.close()
    }

    @Test("The toggling square arrives as incremental updates and lands where it should")
    func incrementalUpdatesChangePixels() async throws {
        let server = try VNCTestServer(password: nil)
        defer { server.shutDown() }
        let group = MultiThreadedEventLoopGroup.singleton
        let client = try await VNCClient.connect(host: "127.0.0.1", port: server.port, options: .init(), group: group)
        var seen: Set<UInt8> = []
        let deadline = ContinuousClock.now + .seconds(4)
        for await event in client.events {
            if case .framebufferUpdated = event {
                seen.insert(client.framebuffer.pixel(x: 120, y: 100).r)
            }
            if seen.isSuperset(of: [0, 255]) || ContinuousClock.now > deadline { break }
        }
        #expect(seen.isSuperset(of: [0, 255]), "the square inside (100,80)-(140,120) alternates black and white; saw \(seen)")
        // Outside the square nothing changed.
        let p = client.framebuffer.pixel(x: 10, y: 20)
        #expect(p.r == 10 && p.g == 20 && p.b == 10 ^ 20)
        await client.close()
    }

    @Test("VNC Authentication with the classic DES challenge is accepted, and a wrong password is refused")
    func passwordAuthentication() async throws {
        let server = try VNCTestServer(password: "s3cret")
        defer { server.shutDown() }
        let group = MultiThreadedEventLoopGroup.singleton
        let client = try await VNCClient.connect(host: "127.0.0.1", port: server.port, options: .init(password: "s3cret"), group: group)
        #expect(client.framebuffer.width == 320)
        await client.close()

        await #expect(throws: VNCError.self) {
            _ = try await VNCClient.connect(host: "127.0.0.1", port: server.port, options: .init(password: "wrong"), group: group)
        }
        await #expect(throws: VNCError.passwordRequired) {
            _ = try await VNCClient.connect(host: "127.0.0.1", port: server.port, options: .init(), group: group)
        }
    }

    @Test("Pointer, key and clipboard events reach the server as sent")
    func inputArrives() async throws {
        let server = try VNCTestServer(password: nil)
        defer { server.shutDown() }
        let group = MultiThreadedEventLoopGroup.singleton
        let client = try await VNCClient.connect(host: "127.0.0.1", port: server.port, options: .init(), group: group)
        client.sendPointer(buttons: 0, x: 12, y: 34)
        client.sendPointer(buttons: 1, x: 12, y: 34)
        client.sendPointer(buttons: 0, x: 12, y: 34)
        client.sendPointer(buttons: 4, x: 300, y: 199)
        client.sendKey(keysym: VNCKeysym.forCharacter("a"), down: true)
        client.sendKey(keysym: VNCKeysym.forCharacter("a"), down: false)
        client.sendKey(keysym: VNCKeysym.return, down: true)
        client.sendKey(keysym: VNCKeysym.forCharacter("é"), down: true)
        client.sendCutText("hello")
        let log = try await server.waitForLog(containing: "cut hello", timeout: .seconds(5))
        #expect(log.contains("pointer 0 12 34"))
        #expect(log.contains("pointer 1 12 34"))
        #expect(log.contains("pointer 4 300 199"))
        #expect(log.contains("key down 0x0061"))
        #expect(log.contains("key up 0x0061"))
        #expect(log.contains("key down 0xff0d"))
        #expect(log.contains("key down 0x00e9"), "Latin-1 characters are their own keysyms")
        await client.close()
    }

    @Test("Closing the server ends the event stream with a reason the app can show")
    func serverGoingAwayIsReported() async throws {
        let server = try VNCTestServer(password: nil)
        let group = MultiThreadedEventLoopGroup.singleton
        let client = try await VNCClient.connect(host: "127.0.0.1", port: server.port, options: .init(), group: group)
        server.shutDown()
        var closed = false
        let deadline = ContinuousClock.now + .seconds(5)
        for await event in client.events {
            if case .closed = event { closed = true; break }
            if ContinuousClock.now > deadline { break }
        }
        #expect(closed)
    }
}
