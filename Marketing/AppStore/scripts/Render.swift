// Lays the captured screenshots out on the store canvas.
//
// Deterministic on purpose: the same raw images and the same `shotlist.json` produce the
// same bytes every time, so a change in the output means a change in the app or in the
// copy — never in the tool.
//
// The canvas is white, the type is black, and the only other mark is a hairline. The
// screenshot inside it is untouched: scaled by a single factor, both axes the same, never
// recoloured, never retouched, never cropped through anything the app drew.
//
// Run through `render.sh`, which is what documents the invocation.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// Everything about how one canvas is laid out, in that canvas's own pixels.
struct Layout {
    let width: Int
    let height: Int
    let margin: CGFloat
    /// Where the index mark sits, measured down from the top.
    let indexTop: CGFloat
    let indexSize: CGFloat
    let titleTop: CGFloat
    let titleSize: CGFloat
    let titleLeading: CGFloat
    let subtitleGap: CGFloat
    let subtitleSize: CGFloat
    let subtitleLeading: CGFloat
    /// Gap between the hairline under the caption and the top of the screenshot.
    let ruleGap: CGFloat
    /// How wide the screenshot is drawn.
    let shotWidth: CGFloat

    static let iphone = Layout(
        width: 1320, height: 2868, margin: 140,
        indexTop: 150, indexSize: 34,
        titleTop: 226, titleSize: 84, titleLeading: 100,
        subtitleGap: 30, subtitleSize: 38, subtitleLeading: 52,
        ruleGap: 56, shotWidth: 1040
    )

    /// App Store Connect's iPhone 6.5" slot. The same proportions as the 6.9" canvas,
    /// scaled to the shorter panel rather than re-tuned, so the two sets read as one.
    static let iphone65 = Layout(
        width: 1284, height: 2778, margin: 136,
        indexTop: 145, indexSize: 33,
        titleTop: 219, titleSize: 82, titleLeading: 97,
        subtitleGap: 29, subtitleSize: 37, subtitleLeading: 50,
        ruleGap: 54, shotWidth: 1012
    )

    static let ipad = Layout(
        width: 2732, height: 2048, margin: 188,
        indexTop: 120, indexSize: 34,
        titleTop: 186, titleSize: 88, titleLeading: 104,
        subtitleGap: 28, subtitleSize: 40, subtitleLeading: 54,
        ruleGap: 48, shotWidth: 2000
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

    func title(forPad isPad: Bool) -> String { (isPad ? titleIpad : nil) ?? title }
    func subtitle(forPad isPad: Bool) -> String { (isPad ? subtitleIpad : nil) ?? subtitle }
}

// MARK: - Drawing

let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

/// A context with no alpha channel at all, so nothing downstream can reintroduce one:
/// Apple rejects a screenshot that carries transparency.
func makeContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
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
    // Chinese face for characters San Francisco does not carry, which is why the Chinese
    // canvases need no font of their own.
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontTraitsAttribute: [kCTFontWeightTrait: weight],
    ] as CFDictionary)
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
    return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
}

/// Draws wrapped text and returns the height it used.
@discardableResult
func draw(
    _ text: String,
    in context: CGContext,
    at top: CGFloat,
    left: CGFloat,
    width: CGFloat,
    font ctFont: CTFont,
    leading: CGFloat,
    tracking: CGFloat = 0
) -> CGFloat {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    paragraph.minimumLineHeight = leading
    paragraph.maximumLineHeight = leading
    let attributed = NSAttributedString(string: text, attributes: [
        .font: ctFont,
        .foregroundColor: black,
        .paragraphStyle: paragraph,
        .kern: tracking,
    ] as [NSAttributedString.Key: Any])

    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let bounds = CGSize(width: width, height: .greatestFiniteMagnitude)
    let used = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRange(location: 0, length: 0), nil, bounds, nil
    )
    let height = ceil(used.height)
    let path = CGPath(
        rect: CGRect(x: left, y: CGFloat(context.height) - top - height, width: width, height: height),
        transform: nil
    )
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, context)
    return height
}

func measure(_ text: String, width: CGFloat, font ctFont: CTFont, leading: CGFloat) -> CGFloat {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = leading
    paragraph.maximumLineHeight = leading
    let attributed = NSAttributedString(string: text, attributes: [
        .font: ctFont, .paragraphStyle: paragraph,
    ] as [NSAttributedString.Key: Any])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let used = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRange(location: 0, length: 0), nil,
        CGSize(width: width, height: .greatestFiniteMagnitude), nil
    )
    return ceil(used.height)
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

/// Rounds the screenshot's corners and outlines it with a hairline.
///
/// A restrained frame rather than a device mock-up: no bezel art, no glass, no shadow —
/// and nothing that could be mistaken for Apple hardware imagery.
func drawScreenshot(_ image: CGImage, in context: CGContext, rect: CGRect, radius: CGFloat) {
    context.saveGState()
    let clip = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(clip)
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

/// How one screenshot was placed, so the validator can prove it was not stretched.
struct Placement: Encodable {
    let final: String
    let raw: String
    let rawWidth: Int
    let rawHeight: Int
    let drawnWidth: Double
    let drawnHeight: Double
}

var placements: [Placement] = []

@discardableResult
func render(shot: Shot, raw: URL, layout: Layout, isPad: Bool, total: Int, to output: URL) -> CGRect {
    let context = makeContext(width: layout.width, height: layout.height)
    let contentWidth = CGFloat(layout.width) - layout.margin * 2

    // "01 / 06" — the position in the story, set small and wide.
    draw(
        "\(shot.index) / \(String(format: "%02d", total))",
        in: context, at: layout.indexTop, left: layout.margin, width: contentWidth,
        font: font(size: layout.indexSize, weight: 0.3),
        leading: layout.indexSize * 1.2, tracking: layout.indexSize * 0.18
    )

    let titleFont = font(size: layout.titleSize, weight: 0.42)
    let titleHeight = draw(
        shot.title(forPad: isPad),
        in: context, at: layout.titleTop, left: layout.margin, width: contentWidth,
        font: titleFont, leading: layout.titleLeading, tracking: -layout.titleSize * 0.015
    )

    let subtitleTop = layout.titleTop + titleHeight + layout.subtitleGap
    let subtitleFont = font(size: layout.subtitleSize, weight: 0)
    let subtitleHeight = draw(
        shot.subtitle(forPad: isPad),
        in: context, at: subtitleTop, left: layout.margin, width: contentWidth,
        font: subtitleFont, leading: layout.subtitleLeading
    )

    // The hairline that separates what is said from what is shown.
    let ruleY = subtitleTop + subtitleHeight + layout.ruleGap
    context.setStrokeColor(black)
    context.setLineWidth(2)
    context.move(to: CGPoint(x: layout.margin, y: CGFloat(layout.height) - ruleY))
    context.addLine(to: CGPoint(x: CGFloat(layout.width) - layout.margin, y: CGFloat(layout.height) - ruleY))
    context.strokePath()

    let image = loadImage(raw)
    let scale = layout.shotWidth / CGFloat(image.width)
    let shotHeight = CGFloat(image.height) * scale
    let shotTop = ruleY + layout.ruleGap
    let available = CGFloat(layout.height) - shotTop - layout.margin
    // Never stretched: if the picture will not fit, both axes shrink by the same factor.
    let fitted = min(1, available / shotHeight)
    let finalWidth = layout.shotWidth * fitted
    let finalHeight = shotHeight * fitted
    let rect = CGRect(
        x: (CGFloat(layout.width) - finalWidth) / 2,
        y: CGFloat(layout.height) - shotTop - finalHeight,
        width: finalWidth,
        height: finalHeight
    )
    drawScreenshot(image, in: context, rect: rect, radius: finalWidth * 0.045)

    guard let rendered = context.makeImage() else { fatalError("could not render \(output.path)") }
    write(rendered, to: output)
    return rect
}

/// One sheet showing every final image at a glance, at roughly the size the store shows
/// them — which is the only size at which a title is either readable or not.
func contactSheet(images: [URL], columns: Int, cellWidth: Int, to output: URL) {
    let loaded = images.map { loadImage($0) }
    guard !loaded.isEmpty else { return }
    let padding = 40
    let label = 0
    let cells = loaded.map { image -> (CGImage, Int) in
        (image, Int((CGFloat(cellWidth) / CGFloat(image.width)) * CGFloat(image.height)))
    }
    let rows = Int(ceil(Double(cells.count) / Double(columns)))
    var rowHeights: [Int] = []
    for row in 0 ..< rows {
        let slice = cells[(row * columns) ..< min((row + 1) * columns, cells.count)]
        rowHeights.append(slice.map(\.1).max() ?? 0)
    }
    let width = columns * cellWidth + (columns + 1) * padding
    let height = rowHeights.reduce(0, +) + (rows + 1) * padding + rows * label
    let context = makeContext(width: width, height: height)

    var y = padding
    for row in 0 ..< rows {
        for column in 0 ..< columns {
            let index = row * columns + column
            guard index < cells.count else { continue }
            let (image, cellHeight) = cells[index]
            let x = padding + column * (cellWidth + padding)
            let rect = CGRect(
                x: CGFloat(x), y: CGFloat(height - y - cellHeight),
                width: CGFloat(cellWidth), height: CGFloat(cellHeight)
            )
            context.draw(image, in: rect)
            context.setStrokeColor(black)
            context.setLineWidth(1)
            context.stroke(rect)
        }
        y += rowHeights[row] + padding + label
    }
    guard let rendered = context.makeImage() else { fatalError("could not render the contact sheet") }
    write(rendered, to: output)
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: Render.swift <Marketing/AppStore path>\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: arguments[1])
let shotlist = try JSONDecoder().decode(
    [String: [Shot]].self,
    from: Data(contentsOf: root.appendingPathComponent("scripts/shotlist.json"))
)

let devices: [(key: String, folder: String, layout: Layout, isPad: Bool)] = [
    ("iphone", "iphone-6.9", .iphone, false),
    ("iphone65", "iphone-6.5", .iphone65, false),
    ("ipad", "ipad-13", .ipad, true),
]

var written = 0
var missing: [String] = []
for (locale, shots) in shotlist.sorted(by: { $0.key < $1.key }) {
    for device in devices {
        for (position, shot) in shots.enumerated() {
            let raw = root
                .appendingPathComponent("raw/\(device.key)/\(locale)/\(shot.name).png")
            guard FileManager.default.fileExists(atPath: raw.path) else {
                missing.append(raw.path.replacingOccurrences(of: root.path + "/", with: ""))
                continue
            }
            let output = root.appendingPathComponent(
                "final/\(locale)/\(device.folder)/\(String(format: "%02d", position + 1))-\(shot.name).png"
            )
            let image = loadImage(raw)
            let rect = render(
                shot: shot, raw: raw, layout: device.layout, isPad: device.isPad,
                total: shots.count, to: output
            )
            placements.append(Placement(
                final: output.path.replacingOccurrences(of: root.path + "/", with: ""),
                raw: raw.path.replacingOccurrences(of: root.path + "/", with: ""),
                rawWidth: image.width, rawHeight: image.height,
                drawnWidth: Double(rect.width), drawnHeight: Double(rect.height)
            ))
            written += 1
        }
    }

    // The sheet puts the phone story and the iPad story side by side, in order.
    for device in devices {
        let folder = root.appendingPathComponent("final/\(locale)/\(device.folder)")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard !files.isEmpty else { continue }
        contactSheet(
            images: files,
            columns: device.isPad ? 3 : files.count,
            cellWidth: device.isPad ? 900 : 440,
            to: root.appendingPathComponent("preview/\(locale)-\(device.folder)-contact-sheet.png")
        )
    }

    // And one sheet per locale: the phone row above the iPad row, in order. This is the
    // sheet the "does this read as one product, at the size the store shows it" check
    // actually looks at.
    func finals(_ folder: String) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("final/\(locale)/\(folder)"), includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }
    let phone = finals("iphone-6.9")
    let phone65 = finals("iphone-6.5")
    let pad = finals("ipad-13")
    if !phone.isEmpty {
        contactSheet(
            images: phone + phone65 + pad, columns: phone.count, cellWidth: 440,
            to: root.appendingPathComponent("preview/\(locale)-contact-sheet.png")
        )
    }
}

// What the validator reads to prove nothing was stretched to reach a size.
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try? encoder.encode(placements).write(to: root.appendingPathComponent("build/placements.json"))

if !missing.isEmpty {
    FileHandle.standardError.write(Data("missing raw captures:\n  \(missing.joined(separator: "\n  "))\n".utf8))
}
print("  → \(written) final images")
exit(missing.isEmpty ? 0 : 1)
