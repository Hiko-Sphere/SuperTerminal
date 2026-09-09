import Foundation
import Testing

@testable import STTerminal

/// Sixel, against data a different implementation produced (D-065).
///
/// The two pictures here were encoded by ImageMagick — chosen because it is not this code,
/// so agreeing with it means agreeing with the format rather than with itself. Each is small
/// enough that every pixel is checked, and the expected pixels are written out from the rule
/// that drew the original rather than copied from what the decoder happened to produce.
@Suite("Sixel graphics")
struct SixelTests {
    /// `magick checker.png sixel:-` for an 8×14 image of 2×3 red and blue blocks. Fourteen
    /// rows is deliberately not a multiple of six: the last band is a partial one, and the
    /// raster attributes are what say where the picture stops.
    static let checker = """
    "1;1;8;14#0;2;100;0;0#1;2;0;50;100#0FFwwFFww$#1wwFFwwFF-#0FFwwFFww$#1wwFFwwFF-#0BB??BB$#1??BB??BB-
    """

    /// `magick bands.png sixel:-` for 64×12 in four horizontal bands, which the encoder
    /// expresses with `!64` run-lengths rather than 64 characters.
    static let bands = """
    "1;1;64;12#0;2;0;0;0#1;2;0;100;0#2;2;100;0;100#3;2;100;100;100#0!64F$#3!64w-#1!64F$#2!64w-
    """

    @Test("A picture another encoder produced decodes to the picture it came from")
    func decodesACheckerboard() throws {
        let image = try SixelDecoder.decode(Array(Self.checker.utf8))
        #expect(image.width == 8)
        #expect(image.height == 14)

        var expected: [UInt8] = []
        for y in 0 ..< 14 {
            for x in 0 ..< 8 {
                let red = (x / 2 + y / 3) % 2 == 0
                expected.append(contentsOf: red ? [255, 0, 0, 255] : [0, 128, 255, 255])
            }
        }
        #expect(image.pixels == expected)
    }

    @Test("Run lengths are the same picture as writing every character")
    func decodesRunLengths() throws {
        let image = try SixelDecoder.decode(Array(Self.bands.utf8))
        #expect(image.width == 64)
        #expect(image.height == 12)

        let colours: [[UInt8]] = [[0, 0, 0, 255], [255, 255, 255, 255], [0, 255, 0, 255], [255, 0, 255, 255]]
        var expected: [UInt8] = []
        for y in 0 ..< 12 {
            for _ in 0 ..< 64 { expected.append(contentsOf: colours[y / 3]) }
        }
        #expect(image.pixels == expected)
    }

    @Test("DEC's colour wheel is not the usual one")
    func convertsHLS() {
        // ImageMagick decodes `#0;1;<h>;<l>;<s>` to these, which is how the rotation was
        // settled rather than guessed: 0° is blue, 120° red, 240° green.
        let cases: [(Int, Int, Int, (UInt8, UInt8, UInt8))] = [
            (0, 50, 100, (0, 0, 255)),
            (120, 50, 100, (255, 0, 0)),
            (240, 50, 100, (0, 255, 0)),
            (60, 25, 40, (89, 38, 89)),
        ]
        for (hue, lightness, saturation, want) in cases {
            let colour = SixelDecoder.colourFrom(system: 1, first: hue, second: lightness, third: saturation)
            #expect((colour.red, colour.green, colour.blue) == want, "hue \(hue)")
        }
    }

    @Test("Percentages become bytes the way every other decoder rounds them")
    func convertsRGBPercentages() {
        #expect(SixelDecoder.percentToByte(0) == 0)
        #expect(SixelDecoder.percentToByte(50) == 128)
        #expect(SixelDecoder.percentToByte(100) == 255)
        // Out of range is clamped rather than wrapped: `#0;2;900;0;0` is not white-hot red.
        #expect(SixelDecoder.percentToByte(900) == 255)
        #expect(SixelDecoder.percentToByte(-5) == 0)
    }

    @Test("A picture that would not fit in memory is refused, not attempted")
    func refusesEnormousImages() {
        #expect(throws: ImageDecodingError.self) {
            try SixelDecoder.decode(Array("\"1;1;60000;60000#0;2;100;0;0~".utf8))
        }
    }

    @Test("A stream that draws nothing is not a picture")
    func refusesEmptyImages() {
        // Both of these would otherwise put an invisible rectangle in the grid and scroll
        // the screen to make room for it.
        #expect(throws: ImageDecodingError.self) { try SixelDecoder.decode([]) }
        #expect(throws: ImageDecodingError.self) {
            try SixelDecoder.decode(Array("\"1;1;4;6#0;2;100".utf8))
        }
    }

    @Test("Without raster attributes the size is what the data reached")
    func sizesFromTheData() throws {
        // Ten sixels wide on the first band, four on the second: 10 × 12.
        let image = try SixelDecoder.decode(Array("#0;2;100;0;0!10~-!4~".utf8))
        #expect(image.width == 10)
        #expect(image.height == 12)
    }

    @Test("Bytes that are not sixel produce a picture, not a hang")
    func survivesGarbage() throws {
        // Every byte from 0x3F to 0x7E is a legal sixel, so text *is* a picture; what
        // matters is that nothing here loops, over-reads or grows without bound.
        let image = try SixelDecoder.decode(Array("\u{01}\u{02}hello world\u{7F}".utf8))
        #expect(image.width > 0)
        #expect(image.height == 6)
    }
}
