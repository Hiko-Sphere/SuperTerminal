import Foundation
import Testing

@testable import STTerminal

/// The Kitty graphics protocol (D-065).
@Suite("Kitty graphics")
struct KittyGraphicsTests {
    /// Three red-green-blue-yellow-cyan-magenta pixels over two rows, in each of the three
    /// formats Kitty defines. The alpha in the last two is deliberate: straight alpha is what
    /// the protocol sends and premultiplied is what Core Graphics draws, and the point of the
    /// test below is that both routes end at the same bytes.
    static let pixels: [(UInt8, UInt8, UInt8, UInt8)] = [
        (255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255),
        (255, 255, 0, 255), (0, 255, 255, 128), (255, 0, 255, 0),
    ]

    static func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

    static var rgba: [UInt8] { pixels.flatMap { [$0.0, $0.1, $0.2, $0.3] } }
    static var rgb: [UInt8] { pixels.flatMap { [$0.0, $0.1, $0.2] } }

    static func command(_ control: String, _ payload: String = "") -> KittyCommand {
        KittyCommand.parse(Array("G\(control);\(payload)".utf8))!
    }

    @Test("An APC sequence that is not Kitty's is not Kitty's")
    func ignoresOtherAPCSequences() {
        #expect(KittyCommand.parse(Array("Xsomething".utf8)) == nil)
        #expect(KittyCommand.parse([]) == nil)
        #expect(KittyCommand.parse(Array("Ga=q,i=31".utf8))?.keys == ["a": "q", "i": "31"])
    }

    @Test("A picture split across chunks is the picture")
    func joinsChunks() {
        var session = KittyGraphicsSession()
        let encoded = Self.base64(Self.rgb)
        let split = encoded.count / 2 / 4 * 4
        #expect(session.handle(Self.command("a=T,f=24,s=3,v=2,i=7,m=1", String(encoded.prefix(split)))) == .none)
        guard case let .storeAndDisplay(image, id, _, _, _) =
            session.handle(Self.command("i=7,m=0", String(encoded.dropFirst(split))))
        else {
            Issue.record("the last chunk should complete the picture")
            return
        }
        #expect(id == 7)
        #expect(image.width == 3)
        #expect(image.height == 2)
    }

    @Test("The same picture as raw pixels and as PNG is the same bytes")
    func agreesWithItself() throws {
        let raw = try KittyImageDecoder.decode(Self.command("a=T,f=32,s=3,v=2", Self.base64(Self.rgba)))
        // A PNG of the same six pixels, written by Pillow.
        let png = try KittyImageDecoder.decode(Self.command("a=T,f=100", Self.tinyPNG))
        #expect(raw.width == png.width)
        #expect(raw.height == png.height)
        #expect(raw.pixels == png.pixels, "straight alpha must be premultiplied the same way ImageIO does it")
    }

    @Test("What cannot work over a network connection says so")
    func refusesWhatItCannotDo() {
        var session = KittyGraphicsSession()
        // `t=f`, `t=t` and `t=s` name a file on the machine running the program. Over SSH
        // that is the server, and this app is not on it.
        for medium in ["f", "t", "s"] {
            guard case let .respond(body) = session.handle(Self.command("a=T,t=\(medium),f=100", "L3RtcC94")) else {
                Issue.record("medium \(medium) should be answered")
                continue
            }
            #expect(body.contains("ENOTSUPPORTED"))
        }
    }

    @Test("A terminal that does not answer a query makes programs guess")
    func answersQueries() {
        var session = KittyGraphicsSession()
        #expect(session.handle(Self.command("a=q,i=31")) == .respond("i=31;OK"))
        // `q=1` is "tell me only if it went wrong", `q=2` is "tell me nothing".
        #expect(session.handle(Self.command("a=q,i=31,q=1")) == .none)
        #expect(session.handle(Self.command("a=T,t=f,f=100,q=2", "eA==")) == .none)
    }

    @Test("Deleting is by id or everything, and anything else is refused rather than guessed")
    func deletes() {
        var session = KittyGraphicsSession()
        #expect(session.handle(Self.command("a=d")) == .delete(id: nil))
        #expect(session.handle(Self.command("a=d,d=i,i=7")) == .delete(id: 7))
        guard case let .respond(body) = session.handle(Self.command("a=d,d=c")) else {
            Issue.record("an unsupported selector should be answered")
            return
        }
        #expect(body.contains("ENOTSUPPORTED"))
    }

    @Test("A raw picture that does not say how big it is, is not a picture")
    func refusesRawWithoutASize() {
        #expect(throws: ImageDecodingError.self) {
            try KittyImageDecoder.decode(Self.command("a=T,f=24", Self.base64(Self.rgb)))
        }
        #expect(throws: ImageDecodingError.self) {
            try KittyImageDecoder.decode(Self.command("a=T,f=24,s=3,v=2", "AAAA"))
        }
    }

    /// The same six pixels as a PNG, written by Pillow — a different implementation, so
    /// agreeing with it is agreeing with the format.
    static let tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAHUlEQVR4nGP4z8DwHwwZ/v9nAlEMDP8b/zMwMAIAiTMJfAt+NkIAAAAASUVORK5CYII="
}
