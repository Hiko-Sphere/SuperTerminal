import Foundation

/// A decoded image, as RGBA bytes (D-065).
///
/// The terminal package does not draw; it decodes. The result is *premultiplied* RGBA, which
/// is the one arrangement Core Graphics will draw — so the multiplication happens once, in the
/// decoder, rather than on every frame. Sixel and Kitty's raw formats are opaque or fully
/// transparent, where premultiplied and straight are the same bytes; the difference only shows
/// in a PNG with partial alpha, and there ImageIO has already done it.
public struct TerminalImage: Sendable, Equatable {
    /// The most pixels one picture may have. Four bytes each, so this is 64 MB of decoded
    /// data at the limit — an amount a phone can hold, unlike the two gigabytes a hostile
    /// `"1;1;60000;60000` would otherwise ask for.
    public static let maximumPixels = 16_000_000

    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes, row-major, R, G, B, A, premultiplied.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public enum ImageDecodingError: Error, Equatable, Sendable {
    /// The stream asked for more pixels than the terminal will hold for one image.
    case tooLarge(pixels: Int)
    /// Nothing was drawn.
    case empty
    /// The payload is not the format it claimed to be.
    case malformed(String)
}

/// Where a picture sits in the grid (D-065).
///
/// A slice belongs to a line rather than to the screen, which is what makes scrolling and
/// scrollback carry pictures without any of them knowing about pictures: the line moves, and
/// the part of the image drawn on it moves with it. A width change is the exception, and
/// `TerminalScreen.resize` says why.
public struct ImageSlice: Sendable, Equatable {
    /// The image in the screen's store.
    public var imageID: Int
    /// Which row of the picture, in cells, this line shows.
    public var imageRow: Int
    /// Which column of the picture the strip starts at, in cells. Not always zero: writing
    /// a character into the middle of a picture splits its strip in two.
    public var imageColumn: Int
    /// The first column on the line.
    public var column: Int
    /// How many cells wide the strip is.
    public var columns: Int
    /// The whole picture's size in cells, which is what the renderer scales it to.
    public var totalColumns: Int
    public var totalRows: Int

    public init(
        imageID: Int,
        imageRow: Int,
        imageColumn: Int = 0,
        column: Int,
        columns: Int,
        totalColumns: Int,
        totalRows: Int
    ) {
        self.imageID = imageID
        self.imageRow = imageRow
        self.imageColumn = imageColumn
        self.column = column
        self.columns = columns
        self.totalColumns = totalColumns
        self.totalRows = totalRows
    }

    /// The columns this strip covers on its line.
    public var range: Range<Int> { column ..< (column + columns) }
}

/// The pictures a screen is holding, and the budget it holds them within (D-065).
///
/// A terminal that kept every picture a program drew would be a memory leak with a scrollback
/// setting. The store is bounded in bytes; when it is full the oldest images are dropped,
/// which is what makes a session that runs `img2sixel` in a loop survive.
public struct TerminalImageStore: Sendable, Equatable {
    /// Total decoded pixels held at once. 64 MB, which is a few full-screen pictures.
    public static let maximumBytes = 64 << 20

    private var images: [Int: TerminalImage] = [:]
    /// Insertion order, oldest first, for eviction.
    private var order: [Int] = []
    private var bytes = 0
    private var nextID = 1

    public init() {}

    public var count: Int { images.count }
    public var byteCount: Int { bytes }

    public subscript(id: Int) -> TerminalImage? { images[id] }

    /// Stores an image and returns the id it was filed under.
    ///
    /// `preferredID` is Kitty's `i=`: a program may name its own images and ask for them
    /// again later. Everything else is given the next number.
    @discardableResult
    public mutating func insert(_ image: TerminalImage, preferredID: Int? = nil) -> Int {
        let id = preferredID ?? nextID
        nextID = max(nextID, id + 1)
        remove(id)
        images[id] = image
        order.append(id)
        bytes += image.pixels.count
        evictIfNeeded()
        return id
    }

    public mutating func remove(_ id: Int) {
        guard let image = images.removeValue(forKey: id) else { return }
        bytes -= image.pixels.count
        order.removeAll { $0 == id }
    }

    public mutating func removeAll() {
        images.removeAll()
        order.removeAll()
        bytes = 0
    }

    /// Drops the oldest until the budget is met.
    ///
    /// Oldest-first rather than least-used: a terminal's pictures are almost always used once
    /// as they scroll past, and the ones a program means to keep it re-sends or re-displays by
    /// id, which puts them back.
    private mutating func evictIfNeeded() {
        while bytes > Self.maximumBytes, let oldest = order.first {
            remove(oldest)
        }
    }
}
