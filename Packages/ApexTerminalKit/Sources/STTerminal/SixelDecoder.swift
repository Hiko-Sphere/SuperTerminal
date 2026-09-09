import Foundation

/// Sixel graphics, as defined by DEC's Level 2 sixel and used by `img2sixel`, `gnuplot`,
/// `lsix` and every program that draws pictures into a terminal (D-065).
///
/// The data is six vertical pixels per character: byte − 0x3F, bit 0 the topmost. A band is
/// six pixel rows; `-` starts the next band, `$` returns to the left of the current one,
/// `#Pc` selects a colour register and `#Pc;Pu;Px;Py;Pz` defines one, `!Pn` repeats the next
/// character. That is the whole format, and the reason it is worth having is that it is the
/// only picture protocol old enough that ordinary server-side tools already emit it.
public enum SixelDecoder {
    /// Decodes sixel data.
    ///
    /// `parameters` are the DCS parameters — P1 aspect ratio, P2 background mode, P3 grid
    /// size — and none of them changes the pixels here. P1 and P3 describe a VT's own screen
    /// geometry, which this terminal does not have. P2 says whether pixels the data never
    /// writes take the current background colour or stay transparent, and the answer is the
    /// same either way once the picture is drawn over a terminal that has already painted its
    /// own background: they are left transparent, and the background shows through. Taking
    /// the parameter is what lets a caller pass what it parsed without pretending it was
    /// read.
    public static func decode(_ payload: [UInt8], parameters: [Int?] = []) throws -> TerminalImage {
        var registers = defaultPalette()
        var canvas = Canvas(maximumPixels: TerminalImage.maximumPixels)

        var index = payload.startIndex
        var colour = 0
        var repeatCount = 1

        while index < payload.endIndex {
            let byte = payload[index]
            switch byte {
            case 0x21: // ! — repeat introducer
                index += 1
                let (value, next) = readNumber(payload, from: index)
                repeatCount = max(1, min(value ?? 1, 1 << 20))
                index = next

            case 0x22: // " — raster attributes: pan;pad;width;height
                index += 1
                let numbers = readNumbers(payload, from: &index, limit: 4)
                if numbers.count >= 4, let width = numbers[2], let height = numbers[3] {
                    try canvas.reserve(width: width, height: height)
                }

            case 0x23: // # — colour register
                index += 1
                let numbers = readNumbers(payload, from: &index, limit: 5)
                guard let register = numbers.first ?? nil else { break }
                if numbers.count >= 5,
                   let system = numbers[1], let first = numbers[2],
                   let second = numbers[3], let third = numbers[4] {
                    registers[register & 0xFF] = colourFrom(
                        system: system, first: first, second: second, third: third
                    )
                }
                colour = register & 0xFF

            case 0x24: // $ — back to the left of this band
                canvas.carriageReturn()
                index += 1
                repeatCount = 1

            case 0x2D: // - — next band
                canvas.nextBand()
                index += 1
                repeatCount = 1

            case 0x3F ... 0x7E: // the sixels themselves
                try canvas.write(
                    bits: byte - 0x3F,
                    times: repeatCount,
                    colour: registers[colour]
                )
                repeatCount = 1
                index += 1

            default:
                // Whitespace between bands is legal and everything else is ignorable: a
                // stream that cannot be understood must not stop the ones that can.
                index += 1
            }
        }

        return try canvas.image()
    }

    // MARK: - Numbers

    private static func readNumber(_ payload: [UInt8], from start: Int) -> (Int?, Int) {
        var index = start
        var value: Int?
        while index < payload.endIndex, payload[index] >= 0x30, payload[index] <= 0x39 {
            value = min((value ?? 0) * 10 + Int(payload[index] - 0x30), 1 << 24)
            index += 1
        }
        return (value, index)
    }

    /// Reads up to `limit` `;`-separated numbers, leaving `index` on the first byte after.
    private static func readNumbers(_ payload: [UInt8], from index: inout Int, limit: Int) -> [Int?] {
        var numbers: [Int?] = []
        while numbers.count < limit {
            let (value, next) = readNumber(payload, from: index)
            numbers.append(value)
            index = next
            guard index < payload.endIndex, payload[index] == 0x3B else { break }
            index += 1
        }
        return numbers
    }

    // MARK: - Colour

    /// `Pu` 1 is HLS and 2 is RGB, both in percentages. DEC's hue is not the usual one:
    /// 0° is blue, 120° red, 240° green, which is why the conversion rotates it.
    static func colourFrom(system: Int, first: Int, second: Int, third: Int) -> Colour {
        switch system {
        case 1:
            return hlsToRGB(hue: first, lightness: second, saturation: third)
        default:
            return Colour(
                red: percentToByte(first),
                green: percentToByte(second),
                blue: percentToByte(third)
            )
        }
    }

    static func percentToByte(_ value: Int) -> UInt8 {
        let clamped = max(0, min(value, 100))
        return UInt8((clamped * 255 + 50) / 100)
    }

    static func hlsToRGB(hue: Int, lightness: Int, saturation: Int) -> Colour {
        let lum = Double(max(0, min(lightness, 100))) / 100
        let sat = Double(max(0, min(saturation, 100))) / 100
        // DEC's 0° is blue; the usual colour wheel's 0° is red.
        let degrees = Double(((hue % 360) + 360 + 240) % 360)
        let chroma = (1 - abs(2 * lum - 1)) * sat
        let sector = degrees / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: (red, green, blue) = (chroma, second, 0)
        case 1: (red, green, blue) = (second, chroma, 0)
        case 2: (red, green, blue) = (0, chroma, second)
        case 3: (red, green, blue) = (0, second, chroma)
        case 4: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        let match = lum - chroma / 2
        return Colour(
            red: unitToByte(red + match),
            green: unitToByte(green + match),
            blue: unitToByte(blue + match)
        )
    }

    private static func unitToByte(_ value: Double) -> UInt8 {
        UInt8(max(0, min((value * 255).rounded(), 255)))
    }

    public struct Colour: Sendable, Equatable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8
    }

    /// The palette a sixel stream starts with. DEC defined sixteen; anything beyond is
    /// black until the stream defines it, which is what other terminals do.
    static func defaultPalette() -> [Colour] {
        let sixteen: [(Int, Int, Int)] = [
            (0, 0, 0), (20, 20, 80), (80, 13, 13), (20, 80, 20),
            (80, 20, 80), (20, 80, 80), (80, 80, 20), (53, 53, 53),
            (26, 26, 26), (33, 33, 60), (60, 26, 26), (33, 60, 33),
            (60, 33, 60), (33, 60, 60), (60, 60, 33), (80, 80, 80),
        ]
        var palette = sixteen.map {
            Colour(red: percentToByte($0.0), green: percentToByte($0.1), blue: percentToByte($0.2))
        }
        palette.append(contentsOf: Array(repeating: Colour(red: 0, green: 0, blue: 0), count: 256 - palette.count))
        return palette
    }

    // MARK: - Canvas

    /// A growing RGBA canvas.
    ///
    /// Sixel does not have to declare its size — the raster attributes are a hint that most
    /// encoders send and some do not — so the canvas grows to what was drawn, doubles its
    /// width rather than reallocating per character, and refuses to grow past what a phone
    /// should hold for one picture.
    struct Canvas {
        let maximumPixels: Int
        /// Allocated size, which can be larger than the picture.
        private(set) var width = 0
        private(set) var height = 0
        private var pixels: [UInt8] = []
        private var cursorX = 0
        private var bandTop = 0
        /// The size the raster attributes declared, if they did. A band is always six rows
        /// tall, so a picture whose height is not a multiple of six would otherwise end up
        /// with a strip of transparent pixels the sender never asked for; declaring the
        /// size is how the format says where to stop.
        private var declaredWidth = 0
        private var declaredHeight = 0
        /// How far the data actually reached, which is the size when nothing was declared.
        private var drawnWidth = 0
        private var drawnHeight = 0

        init(maximumPixels: Int) {
            self.maximumPixels = maximumPixels
        }

        mutating func reserve(width newWidth: Int, height newHeight: Int) throws {
            guard newWidth > 0, newHeight > 0 else { return }
            declaredWidth = min(newWidth, Self.dimensionCap)
            declaredHeight = min(newHeight, Self.dimensionCap)
            try grow(toWidth: declaredWidth, height: declaredHeight)
        }

        mutating func carriageReturn() {
            cursorX = 0
        }

        mutating func nextBand() {
            bandTop += 6
            cursorX = 0
        }

        mutating func write(bits: UInt8, times: Int, colour: Colour) throws {
            guard times > 0 else { return }
            try grow(toWidth: cursorX + times, height: bandTop + 6)
            let span = min(times, max(0, width - cursorX))
            if bits != 0, span > 0 {
                for offset in 0 ..< 6 where bits & (1 << UInt8(offset)) != 0 {
                    let row = bandTop + offset
                    guard row < height else { continue }
                    var index = (row * width + cursorX) * 4
                    for _ in 0 ..< span {
                        pixels[index] = colour.red
                        pixels[index + 1] = colour.green
                        pixels[index + 2] = colour.blue
                        pixels[index + 3] = 255
                        index += 4
                    }
                    drawnHeight = max(drawnHeight, row + 1)
                }
                drawnWidth = max(drawnWidth, cursorX + span)
            }
            cursorX += times
        }

        static let dimensionCap = 1 << 16

        /// Grows the allocation, keeping what is already drawn.
        ///
        /// Growing the height is an append; growing the width has to move every row, which
        /// is why the width doubles instead of following the data one character at a time.
        private mutating func grow(toWidth newWidth: Int, height newHeight: Int) throws {
            var wantedWidth = min(newWidth, Self.dimensionCap)
            var wantedHeight = min(newHeight, Self.dimensionCap)
            if declaredWidth > 0 { wantedWidth = min(wantedWidth, declaredWidth) }
            if declaredHeight > 0 { wantedHeight = min(wantedHeight, declaredHeight) }
            guard wantedWidth > width || wantedHeight > height else { return }

            var targetWidth = max(width, wantedWidth)
            if targetWidth > width, declaredWidth == 0 {
                targetWidth = min(max(targetWidth, width * 2), Self.dimensionCap)
            }
            let targetHeight = max(height, wantedHeight)
            let count = targetWidth * targetHeight
            guard count <= maximumPixels else { throw ImageDecodingError.tooLarge(pixels: count) }

            if targetWidth == width {
                pixels.append(contentsOf: repeatElement(0, count: (targetHeight - height) * width * 4))
            } else {
                var grown = [UInt8](repeating: 0, count: count * 4)
                if width > 0, height > 0 {
                    for row in 0 ..< height {
                        let source = row * width * 4
                        let destination = row * targetWidth * 4
                        grown.replaceSubrange(
                            destination ..< (destination + width * 4),
                            with: pixels[source ..< (source + width * 4)]
                        )
                    }
                }
                pixels = grown
            }
            width = targetWidth
            height = targetHeight
        }

        /// The picture: the size the sender declared, or what the data reached.
        func image() throws -> TerminalImage {
            // A stream that declared a size and then drew nothing is not a picture. Taking
            // its word for it would put an invisible rectangle in the grid and scroll the
            // screen for it, which is worse than ignoring a sequence nobody can see.
            guard drawnWidth > 0, drawnHeight > 0 else { throw ImageDecodingError.empty }
            let finalWidth = declaredWidth > 0 ? min(declaredWidth, width) : drawnWidth
            let finalHeight = declaredHeight > 0 ? min(declaredHeight, height) : drawnHeight
            guard finalWidth > 0, finalHeight > 0 else { throw ImageDecodingError.empty }
            guard finalWidth != width || finalHeight != height else {
                return TerminalImage(width: width, height: height, pixels: pixels)
            }
            var cropped = [UInt8](repeating: 0, count: finalWidth * finalHeight * 4)
            for row in 0 ..< finalHeight {
                let source = row * width * 4
                let destination = row * finalWidth * 4
                cropped.replaceSubrange(
                    destination ..< (destination + finalWidth * 4),
                    with: pixels[source ..< (source + finalWidth * 4)]
                )
            }
            return TerminalImage(width: finalWidth, height: finalHeight, pixels: cropped)
        }
    }
}
