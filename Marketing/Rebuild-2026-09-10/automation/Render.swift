// Lays the captures onto the store canvases.
//
// Deterministic on purpose: the same raw images and the same `shotlist.json` produce the
// same bytes, so a re-render is a check rather than a new opinion. CoreGraphics and
// CoreText only — no image is redrawn, retouched, or generated. The app's own pixels are
// composited unchanged; the canvas around them is drawn from the constants below.
//
// Two layouts, not one scaled twice: a phone is a vertical stack, a 13-inch landscape iPad
// is two columns. See app-store/SCREENSHOT_DESIGN.md.
//
// Usage:  swift Render.swift <rebuild-root>

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// Everything the canvas needs. Values are in pixels of the finished image.
struct Layout {
    let width: Int
    let height: Int
    let margin: CGFloat

    let indexSize: CGFloat
    let indexTracking: CGFloat

    let titleSize: CGFloat
    let titleLeading: CGFloat
    let titleMaxLines: Int

    let subtitleSize: CGFloat
    let subtitleLeading: CGFloat
    let subtitleMaxLines: Int

    let gapAfterIndex: CGFloat
    let gapAfterTitle: CGFloat
    let gapAfterSubtitle: CGFloat
    let gapAfterRule: CGFloat

    let cornerRadius: CGFloat

    /// A phone stacks caption over capture; an iPad puts the caption in a left column.
    let isColumnar: Bool
    /// Columnar only: the caption column's share of the canvas width.
    let captionColumnShare: CGFloat

    var contentWidth: CGFloat { CGFloat(width) - margin * 2 }

    /// The 6.9-inch canvas, and the ratio every other phone size is derived from.
    static let iphone69 = Layout(
        width: 1320, height: 2868, margin: 140,
        indexSize: 32, indexTracking: 2.6,
        titleSize: 86, titleLeading: 100, titleMaxLines: 2,
        subtitleSize: 38, subtitleLeading: 52, subtitleMaxLines: 3,
        gapAfterIndex: 44, gapAfterTitle: 30, gapAfterSubtitle: 44, gapAfterRule: 64,
        cornerRadius: 48, isColumnar: false, captionColumnShare: 0
    )

    /// App Store Connect's 6.5-inch slot. The 6.9-inch canvas scaled to the shorter panel
    /// rather than re-tuned, so the two phone sets read as one piece of work.
    static let iphone65: Layout = {
        let k = 2778.0 / 2868.0
        return Layout(
            width: 1284, height: 2778, margin: round(140 * k),
            indexSize: round(32 * k), indexTracking: 2.5,
            titleSize: round(86 * k), titleLeading: round(100 * k), titleMaxLines: 2,
            subtitleSize: round(38 * k), subtitleLeading: round(52 * k), subtitleMaxLines: 3,
            gapAfterIndex: round(44 * k), gapAfterTitle: round(30 * k),
            gapAfterSubtitle: round(44 * k), gapAfterRule: round(64 * k),
            cornerRadius: 46, isColumnar: false, captionColumnShare: 0
        )
    }()

    /// The iPad 13-inch canvas, landscape — a different layout, not a bigger phone.
    static let ipad13 = Layout(
        width: 2732, height: 2048, margin: 96,
        indexSize: 34, indexTracking: 2.8,
        titleSize: 92, titleLeading: 108, titleMaxLines: 4,
        subtitleSize: 42, subtitleLeading: 58, subtitleMaxLines: 4,
        gapAfterIndex: 46, gapAfterTitle: 32, gapAfterSubtitle: 46, gapAfterRule: 0,
        cornerRadius: 40, isColumnar: true, captionColumnShare: 0.29
    )
}

// MARK: - Input

struct Shot: Decodable {
    let name: String
    let index: String
    let title: String
    let subtitle: String
    let titleIpad: String?
    let subtitleIpad: String?

    func title(isPad: Bool) -> String { isPad ? (titleIpad ?? title) : title }
    func subtitle(isPad: Bool) -> String { isPad ? (subtitleIpad ?? subtitle) : subtitle }
}

// MARK: - Drawing

let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let subtitleGrey = CGColor(red: 0.227, green: 0.227, blue: 0.227, alpha: 1)
let indexGrey = CGColor(red: 0.541, green: 0.541, blue: 0.541, alpha: 1)

/// A context with no alpha channel at all, so nothing downstream can reintroduce one:
/// Apple rejects a screenshot that carries transparency.
func makeContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fatalError("could not make a \(width)×\(height) context") }
    context.setFillColor(white)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    return context
}

func font(size: CGFloat, weight: CGFloat) -> CTFont {
    // The system font, in the weight asked for. CoreText falls back to the system's own
    // Chinese faces for characters San Francisco does not carry, which is why the Chinese
    // canvases need no font of their own.
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontTraitsAttribute: [kCTFontWeightTrait: weight],
    ] as CFDictionary)
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
    return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
}

/// Han characters have no descenders to separate lines, so Chinese sets a little tighter.
func leading(_ base: CGFloat, for text: String) -> CGFloat {
    let isHan = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    return isHan ? round(base * 0.92) : base
}

func attributed(
    _ text: String, font ctFont: CTFont, colour: CGColor,
    leading lineHeight: CGFloat, tracking: CGFloat
) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    // Chinese lines must not begin with closing punctuation; CoreText's own line-breaking
    // handles this when the paragraph knows it is not Latin-only.
    paragraph.lineBreakMode = .byWordWrapping
    return NSAttributedString(string: text, attributes: [
        .font: ctFont,
        .foregroundColor: colour,
        .paragraphStyle: paragraph,
        .kern: tracking,
    ] as [NSAttributedString.Key: Any])
}

func measure(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
    let framesetter = CTFramesetterCreateWithAttributedString(string)
    let used = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRange(location: 0, length: 0), nil,
        CGSize(width: width, height: .greatestFiniteMagnitude), nil
    )
    return ceil(used.height)
}

@discardableResult
func draw(
    _ string: NSAttributedString, in context: CGContext,
    at top: CGFloat, left: CGFloat, width: CGFloat
) -> CGFloat {
    let height = measure(string, width: width)
    let framesetter = CTFramesetterCreateWithAttributedString(string)
    let path = CGPath(
        rect: CGRect(x: left, y: CGFloat(context.height) - top - height, width: width, height: height),
        transform: nil
    )
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, context)
    return height
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fatalError("could not read \(url.path)") }
    return image
}

func write(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("could not write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not finalize \(url.path)") }
}

/// Rounds the capture's corners and outlines it with a hairline.
///
/// A restrained frame rather than a device mock-up: no bezel art, no glass, no shadow, and
/// nothing that could be mistaken for Apple hardware imagery.
func drawScreenshot(_ image: CGImage, in context: CGContext, rect: CGRect, radius: CGFloat) {
    context.saveGState()
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.draw(image, in: rect)
    context.restoreGState()

    context.saveGState()
    context.setStrokeColor(black)
    context.setLineWidth(2)
    context.addPath(CGPath(
        roundedRect: rect.insetBy(dx: 1, dy: 1),
        cornerWidth: radius, cornerHeight: radius, transform: nil
    ))
    context.strokePath()
    context.restoreGState()
}

/// How one capture was placed, so the validator can prove it was not stretched.
struct Placement: Encodable {
    let final: String
    let raw: String
    let rawWidth: Int
    let rawHeight: Int
    let drawnX: Double
    let drawnY: Double
    let drawnWidth: Double
    let drawnHeight: Double
    let canvasWidth: Int
    let canvasHeight: Int
}

// MARK: - The two layouts

func render(shot: Shot, raw: URL, layout: Layout, total: Int, to output: URL) -> Placement {
    let context = makeContext(width: layout.width, height: layout.height)
    let image = loadImage(raw)
    let isPad = layout.isColumnar

    let indexText = attributed(
        "\(shot.index) / \(String(format: "%02d", total))",
        font: font(size: layout.indexSize, weight: 0.3), colour: indexGrey,
        leading: layout.indexSize * 1.2, tracking: layout.indexTracking
    )
    let titleText = shot.title(isPad: isPad)
    let subtitleText = shot.subtitle(isPad: isPad)
    let title = attributed(
        titleText, font: font(size: layout.titleSize, weight: 0.62), colour: black,
        leading: leading(layout.titleLeading, for: titleText), tracking: -0.5
    )
    let subtitle = attributed(
        subtitleText, font: font(size: layout.subtitleSize, weight: 0), colour: subtitleGrey,
        leading: leading(layout.subtitleLeading, for: subtitleText), tracking: 0
    )

    let captionWidth = isPad
        ? round(CGFloat(layout.width) * layout.captionColumnShare)
        : layout.contentWidth

    // Refuse to ship an overflowing caption rather than drawing one.
    let titleLines = Int(round(measure(title, width: captionWidth) / leading(layout.titleLeading, for: titleText)))
    let subtitleLines = Int(round(measure(subtitle, width: captionWidth) / leading(layout.subtitleLeading, for: subtitleText)))
    if titleLines > layout.titleMaxLines {
        fatalError("\(output.lastPathComponent): the title needs \(titleLines) lines, the layout allows \(layout.titleMaxLines) — shorten it")
    }
    if subtitleLines > layout.subtitleMaxLines {
        fatalError("\(output.lastPathComponent): the subtitle needs \(subtitleLines) lines, the layout allows \(layout.subtitleMaxLines) — shorten it")
    }

    let placement: CGRect

    if isPad {
        // Two columns. The caption block is vertically centred in the left column; the
        // capture is centred in the right and scaled to fit whole, because an iPad
        // screenshot's whole width is the thing being shown.
        let indexHeight = measure(indexText, width: captionWidth)
        let titleHeight = measure(title, width: captionWidth)
        let subtitleHeight = measure(subtitle, width: captionWidth)
        let ruleLength = min(captionWidth, 260)
        let blockHeight = indexHeight + layout.gapAfterIndex
            + titleHeight + layout.gapAfterTitle
            + subtitleHeight + layout.gapAfterSubtitle + 2

        var y = (CGFloat(layout.height) - blockHeight) / 2
        draw(indexText, in: context, at: y, left: layout.margin, width: captionWidth)
        y += indexHeight + layout.gapAfterIndex
        draw(title, in: context, at: y, left: layout.margin, width: captionWidth)
        y += titleHeight + layout.gapAfterTitle
        draw(subtitle, in: context, at: y, left: layout.margin, width: captionWidth)
        y += subtitleHeight + layout.gapAfterSubtitle

        context.setFillColor(black)
        context.fill(CGRect(x: layout.margin, y: CGFloat(layout.height) - y - 2, width: ruleLength, height: 2))

        let captureLeft = layout.margin + captionWidth + layout.margin * 0.55
        let available = CGSize(
            width: CGFloat(layout.width) - captureLeft - layout.margin,
            height: CGFloat(layout.height) - layout.margin * 2
        )
        let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        placement = CGRect(
            x: captureLeft + (available.width - drawn.width) / 2,
            y: (CGFloat(layout.height) - drawn.height) / 2,
            width: drawn.width, height: drawn.height
        )
    } else {
        // A vertical stack. The capture is the full content width and runs off the bottom
        // where it is taller than the space left: the top of a phone screen carries the
        // information, and shrinking it would cost legibility at browse size.
        var y = layout.margin
        y += draw(indexText, in: context, at: y, left: layout.margin, width: captionWidth)
        y += layout.gapAfterIndex
        y += draw(title, in: context, at: y, left: layout.margin, width: captionWidth)
        y += layout.gapAfterTitle
        y += draw(subtitle, in: context, at: y, left: layout.margin, width: captionWidth)
        y += layout.gapAfterSubtitle

        context.setFillColor(black)
        context.fill(CGRect(x: layout.margin, y: CGFloat(layout.height) - y - 2, width: captionWidth, height: 2))
        y += layout.gapAfterRule

        let scale = captionWidth / CGFloat(image.width)
        let drawn = CGSize(width: captionWidth, height: CGFloat(image.height) * scale)
        placement = CGRect(
            x: layout.margin,
            y: CGFloat(layout.height) - y - drawn.height,
            width: drawn.width, height: drawn.height
        )
    }

    drawScreenshot(image, in: context, rect: placement, radius: layout.cornerRadius)

    guard let rendered = context.makeImage() else { fatalError("could not render \(output.path)") }
    write(rendered, to: output)

    return Placement(
        final: output.lastPathComponent, raw: raw.lastPathComponent,
        rawWidth: image.width, rawHeight: image.height,
        drawnX: Double(placement.origin.x), drawnY: Double(placement.origin.y),
        drawnWidth: Double(placement.width), drawnHeight: Double(placement.height),
        canvasWidth: layout.width, canvasHeight: layout.height
    )
}

// MARK: - Contact sheets

func contactSheet(images: [URL], columns: Int, cellWidth: Int, to output: URL) {
    guard !images.isEmpty else { return }
    let loaded = images.map { loadImage($0) }
    let gutter = 24
    let cellHeights = loaded.map { Int(CGFloat(cellWidth) * CGFloat($0.height) / CGFloat($0.width)) }
    let rows = Int(ceil(Double(loaded.count) / Double(columns)))
    var rowHeights: [Int] = []
    for row in 0 ..< rows {
        let slice = cellHeights[(row * columns) ..< min((row + 1) * columns, cellHeights.count)]
        rowHeights.append(slice.max() ?? 0)
    }
    let width = columns * cellWidth + (columns + 1) * gutter
    let height = rowHeights.reduce(0, +) + (rows + 1) * gutter
    let context = makeContext(width: width, height: height)

    var y = gutter
    for row in 0 ..< rows {
        for column in 0 ..< columns {
            let index = row * columns + column
            guard index < loaded.count else { break }
            let image = loaded[index]
            let cellHeight = cellHeights[index]
            let rect = CGRect(
                x: gutter + column * (cellWidth + gutter),
                y: height - y - cellHeight,
                width: cellWidth, height: cellHeight
            )
            context.draw(image, in: rect)
            context.setStrokeColor(indexGrey)
            context.setLineWidth(1)
            context.stroke(rect)
        }
        y += rowHeights[row] + gutter
    }
    guard let sheet = context.makeImage() else { fatalError("could not render \(output.path)") }
    write(sheet, to: output)
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: Render.swift <rebuild-root>\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: arguments[1])
let shotlists = try JSONDecoder().decode(
    [String: [Shot]].self,
    from: Data(contentsOf: root.appendingPathComponent("automation/shotlist.json"))
)

// device key in raw-screenshots/ → folder in screenshots/ → layout
let devices: [(String, String, Layout)] = [
    ("iphone69", "iphone-6.9", .iphone69),
    ("iphone65", "iphone-6.5", .iphone65),
    ("ipad", "ipad-13", .ipad13),
]

var placements: [String: [Placement]] = [:]
var produced = 0

for (locale, shots) in shotlists.sorted(by: { $0.key < $1.key }) {
    for (rawKey, folder, layout) in devices {
        let rawDirectory = root
            .appendingPathComponent("app-store/raw-screenshots/\(rawKey)/\(locale)")
        guard FileManager.default.fileExists(atPath: rawDirectory.path) else {
            FileHandle.standardError.write(Data("skipping \(locale)/\(rawKey): no captures\n".utf8))
            continue
        }
        for shot in shots {
            let raw = rawDirectory.appendingPathComponent("\(shot.index)-\(shot.name).png")
            guard FileManager.default.fileExists(atPath: raw.path) else {
                FileHandle.standardError.write(Data("missing capture \(raw.path)\n".utf8))
                continue
            }
            let output = root.appendingPathComponent(
                "app-store/screenshots/\(locale)/\(folder)/\(shot.index)-\(shot.name).png"
            )
            let placement = render(shot: shot, raw: raw, layout: layout, total: shots.count, to: output)
            placements["\(locale)/\(folder)", default: []].append(placement)
            produced += 1
        }
    }

    // One sheet per locale, phones above the iPad, so a whole listing can be judged at once.
    func finals(_ folder: String) -> [URL] {
        let directory = root.appendingPathComponent("app-store/screenshots/\(locale)/\(folder)")
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    let phone = finals("iphone-6.9")
    if !phone.isEmpty {
        contactSheet(
            images: phone + finals("iphone-6.5") + finals("ipad-13"),
            columns: phone.count, cellWidth: 400,
            to: root.appendingPathComponent("app-store/preview/\(locale)-contact-sheet.png")
        )
    }
}

let manifest = try JSONEncoder().encode(placements)
try manifest.write(to: root.appendingPathComponent("automation/build/placements.json"))
print("  → \(produced) final images")
