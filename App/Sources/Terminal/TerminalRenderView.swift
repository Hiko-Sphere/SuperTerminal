import CoreText
import STTerminal
import UIKit

/// Draws a terminal grid with Core Text.
///
/// ## Why Core Text rather than a text view or Metal
///
/// A `UITextView` is the wrong shape entirely: a terminal is a fixed grid of cells with
/// per-cell attributes, not flowing text, and reflowing paragraph layout on every frame
/// of `top` output would be ruinous. Metal is the right answer once glyph throughput
/// dominates, but it is a large amount of machinery to earn before there is anything to
/// measure. Core Text sits where the evidence currently points: the drawing cost is
/// bounded by the visible rows, and it gets correct shaping, ligature suppression and
/// fallback fonts for free — which matters enormously for CJK and emoji.
///
/// The structure here keeps that decision reversible: layout produces a list of runs,
/// and only ``drawRuns(_:in:)`` knows they are drawn with Core Text.
final class TerminalRenderView: UIView {
    /// One horizontal run of cells sharing the same attributes, which is the unit both
    /// background fills and glyph drawing work in.
    struct Run {
        var text: String
        var column: Int
        var width: Int
        var attributes: CellAttributes
    }

    struct Metrics: Equatable {
        var cellWidth: CGFloat
        var cellHeight: CGFloat
        var baselineOffset: CGFloat
        var underlineOffset: CGFloat
        var underlineThickness: CGFloat
    }

    // MARK: - Configuration

    var theme: TerminalTheme = .midnight {
        didSet { if theme != oldValue { refreshAppearance() } }
    }

    var fontSize: CGFloat = 13 {
        didSet { if fontSize != oldValue { rebuildFonts() } }
    }

    /// The font family, or empty for the system's monospaced face (D-063).
    var fontFamily: String = TerminalFont.systemFamily {
        didSet { if fontFamily != oldValue { rebuildFonts() } }
    }

    /// Line height as a multiple of what the font asks for.
    var lineHeightMultiple: CGFloat = 1 {
        didSet { if lineHeightMultiple != oldValue { rebuildFonts() } }
    }

    /// Whether the font's ligatures are drawn. Off draws each cell's glyph on its own,
    /// which is what a grid means by a column.
    var ligaturesEnabled = false {
        didSet { if ligaturesEnabled != oldValue { setNeedsDisplay() } }
    }

    /// Rows scrolled back from the live screen. Zero means the bottom.
    var scrollbackOffset: Int = 0 {
        didSet { if scrollbackOffset != oldValue { setNeedsDisplay() } }
    }

    var showsCursor = true {
        didSet { if showsCursor != oldValue { setNeedsDisplay() } }
    }

    /// Selected region, in absolute coordinates that include scrollback.
    ///
    /// Absolute rather than screen-relative so a selection made three screens back stays
    /// on the text it was made on as new output arrives.
    var selection: TerminalRange? {
        didSet { if selection != oldValue { setNeedsDisplay() } }
    }

    /// Search hits to highlight, also in absolute coordinates.
    var searchMatches: [TerminalRange] = [] {
        didSet { setNeedsDisplay() }
    }

    /// The match the user is currently on, drawn more strongly than the rest.
    var focusedMatch: TerminalRange? {
        didSet { if focusedMatch != oldValue { setNeedsDisplay() } }
    }

    /// Text an input method is still assembling, drawn under the cursor with the
    /// underline that marks it as uncommitted (D-039). Empty in every language that does
    /// not compose.
    var composition: String = "" {
        didSet { if composition != oldValue { setNeedsDisplay() } }
    }

    /// Where the cursor is, for positioning an input method's candidate list.
    func cursorOriginForComposition() -> (origin: CGPoint, width: CGFloat, height: CGFloat)? {
        guard let screen else { return nil }
        return (
            CGPoint(
                x: CGFloat(screen.cursor.column) * metrics.cellWidth,
                y: CGFloat(screen.cursor.row) * metrics.cellHeight
            ),
            metrics.cellWidth,
            metrics.cellHeight
        )
    }

    private(set) var metrics = Metrics(
        cellWidth: 8,
        cellHeight: 16,
        baselineOffset: 12,
        underlineOffset: 2,
        underlineThickness: 1
    )

    private var regularFont: UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldFont: UIFont = .monospacedSystemFont(ofSize: 13, weight: .bold)
    private var italicFont: UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldItalicFont: UIFont = .monospacedSystemFont(ofSize: 13, weight: .bold)

    private var screen: TerminalScreen?

    /// The absolute index of the last row, scrollback included; nil before any content.
    var lastRow: Int? {
        guard let screen else { return nil }
        let total = screen.scrollback.count + screen.lines.count
        return total > 0 ? total - 1 : nil
    }
    private var cursorVisibleInBlink = true
    private var blinkTimer: Timer?

    // MARK: - Lifecycle

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        layer.drawsAsynchronously = false
        rebuildFonts()
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalRenderView is created in code, never from a storyboard")
    }

    // MARK: - Content

    /// Hands the view a new screen to draw.
    func update(screen: TerminalScreen) {
        self.screen = screen
        // Pictures the screen has forgotten must not be held here either: its store is
        // bounded, and this cache would be the thing keeping the pixels alive (D-065).
        if !imageCache.isEmpty, imageCache.count != screen.images.count {
            imageCache = imageCache.filter { screen.images[$0.key] != nil }
        }
        setNeedsDisplay()
    }

    /// The grid size that fits the current bounds.
    func gridSize(for size: CGSize) -> (columns: Int, rows: Int) {
        let columns = max(1, Int(floor(size.width / metrics.cellWidth)))
        let rows = max(1, Int(floor(size.height / metrics.cellHeight)))
        return (columns, rows)
    }

    /// Converts a point to a position in the buffer's absolute coordinate space.
    func position(at point: CGPoint) -> TerminalPosition? {
        guard let screen else { return nil }
        let column = min(max(0, Int(point.x / metrics.cellWidth)), max(0, screen.columns - 1))
        let displayRow = min(max(0, Int(point.y / metrics.cellHeight)), max(0, screen.rows - 1))
        return TerminalPosition(row: absoluteRow(forDisplayRow: displayRow), column: column)
    }

    /// The on-screen rectangle covering a selection, for a drag preview.
    ///
    /// Clipped to what is visible: a selection can reach far back into the scrollback,
    /// and a preview the height of the whole buffer is not a preview.
    func boundingRect(of range: TerminalRange) -> CGRect {
        guard let screen else { return .null }
        let normalised = range.normalised
        let firstVisible = screen.scrollback.count - min(scrollbackOffset, screen.scrollback.count)
        let topRow = max(normalised.start.row - firstVisible, 0)
        let bottomRow = min(normalised.end.row - firstVisible, screen.rows - 1)
        guard topRow <= bottomRow else { return .null }

        let spansOneRow = normalised.start.row == normalised.end.row
        let leftColumn = spansOneRow || normalised.isBlock
            ? min(normalised.start.column, normalised.end.column)
            : 0
        let rightColumn = spansOneRow || normalised.isBlock
            ? max(normalised.start.column, normalised.end.column)
            : max(screen.columns - 1, 0)

        return CGRect(
            x: CGFloat(leftColumn) * metrics.cellWidth,
            y: CGFloat(topRow) * metrics.cellHeight,
            width: CGFloat(rightColumn - leftColumn + 1) * metrics.cellWidth,
            height: CGFloat(bottomRow - topRow + 1) * metrics.cellHeight
        ).intersection(bounds)
    }

    /// The absolute index of a visible row, taking the scrollback offset into account.
    func absoluteRow(forDisplayRow displayRow: Int) -> Int {
        guard let screen else { return displayRow }
        let firstVisible = screen.scrollback.count - min(scrollbackOffset, screen.scrollback.count)
        return firstVisible + displayRow
    }

    // MARK: - Fonts

    private func rebuildFonts() {
        let faces = TerminalFont.faces(family: fontFamily, size: fontSize)
        regularFont = faces.regular
        boldFont = faces.bold
        italicFont = Self.italicised(regularFont)
        boldItalicFont = Self.italicised(boldFont)
        metrics = Self.metrics(forFontSize: fontSize, family: fontFamily, lineHeightMultiple: lineHeightMultiple)
        setNeedsDisplay()
    }

    /// The cell size for a font size, without a view.
    ///
    /// A tmux window has to tell the server how many cells it is showing before it has any
    /// pane to measure — tmux decides the arrangement from that number — so the same
    /// arithmetic the view uses is available on its own rather than duplicated with a
    /// guess (D-059).
    static func metrics(
        forFontSize fontSize: CGFloat,
        family: String = TerminalFont.systemFamily,
        lineHeightMultiple: CGFloat = 1
    ) -> Metrics {
        let regularFont = TerminalFont.faces(family: family, size: fontSize).regular
        // Monospaced by construction, so any glyph's advance is the cell width. `M` is
        // used because it is present in every font that could be substituted.
        let advance = ("M" as NSString).size(withAttributes: [.font: regularFont]).width
        let ascent = regularFont.ascender
        let descent = -regularFont.descender
        let leading = regularFont.leading
        let lineHeight = (ascent + descent + leading).rounded(.up)

        return Metrics(
            cellWidth: max(1, advance.rounded(.toNearestOrEven)),
            cellHeight: max(1, (lineHeight * max(lineHeightMultiple, 0.5)).rounded(.up)),
            baselineOffset: ascent,
            underlineOffset: max(1, descent * 0.4),
            underlineThickness: max(1, (fontSize / 14).rounded(.up))
        )
    }

    private static func italicised(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private func refreshAppearance() {
        backgroundColor = UIColor(cgColor: theme.background.cgColor)
        setNeedsDisplay()
    }

    private func font(for attributes: CellAttributes) -> UIFont {
        switch (attributes.bold, attributes.italic) {
        case (true, true): boldItalicFont
        case (true, false): boldFont
        case (false, true): italicFont
        case (false, false): regularFont
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let screen else { return }

        context.setFillColor(theme.background.cgColor)
        context.fill(rect)

        // Core Text draws in a bottom-up coordinate space; flipping once here keeps every
        // coordinate below in UIKit's top-down space.
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let displayed = displayedLines(from: screen)
        let firstVisibleRow = max(0, Int(rect.minY / metrics.cellHeight))
        let lastVisibleRow = min(displayed.count - 1, Int(rect.maxY / metrics.cellHeight))
        guard firstVisibleRow <= lastVisibleRow else { return }

        for row in firstVisibleRow ... lastVisibleRow {
            drawLine(displayed[row], row: row, in: context)
        }

        if showsCursor, scrollbackOffset == 0 {
            drawCursor(screen: screen, in: context)
        }
        if !composition.isEmpty, scrollbackOffset == 0 {
            drawComposition(screen: screen, in: context)
        }
    }

    /// Draws what an input method is still assembling, over the cells the cursor sits on
    /// and underlined (D-039). Without this a Chinese user types blind: the syllables have
    /// not been sent to the shell, so the shell cannot echo them, so nothing appears.
    private func drawComposition(screen: TerminalScreen, in context: CGContext) {
        let x = CGFloat(screen.cursor.column) * metrics.cellWidth
        let top = CGFloat(screen.cursor.row) * metrics.cellHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: regularFont,
            .foregroundColor: theme.foreground,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: composition, attributes: attributes)
        )
        let width = max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), metrics.cellWidth)

        // The composition covers whatever the shell last drew there; painting the
        // background first stops the two overlapping into an unreadable smear.
        context.setFillColor(theme.background.cgColor)
        context.fill(CGRect(x: x, y: top, width: width, height: metrics.cellHeight))

        context.textPosition = CGPoint(x: x, y: bounds.height - top - metrics.baselineOffset)
        CTLineDraw(line, context)

        // The underline is the platform convention for text that has not been committed.
        context.setStrokeColor(theme.foreground.cgColor)
        context.setLineWidth(1)
        let underline = bounds.height - top - metrics.cellHeight + 1
        context.move(to: CGPoint(x: x, y: underline))
        context.addLine(to: CGPoint(x: x + width, y: underline))
        context.strokePath()
    }

    /// The rows to draw, taking the scrollback offset into account.
    private func displayedLines(from screen: TerminalScreen) -> [TerminalLine] {
        guard scrollbackOffset > 0 else { return screen.lines }
        let history = screen.scrollback
        let offset = min(scrollbackOffset, history.count)
        let fromHistory = history.suffix(offset)
        let fromScreen = screen.lines.prefix(max(0, screen.rows - offset))
        return Array(fromHistory) + Array(fromScreen)
    }

    private func drawLine(_ line: TerminalLine, row: Int, in context: CGContext) {
        let runs = coalesce(line)
        let top = CGFloat(row) * metrics.cellHeight
        let flippedTop = bounds.height - top - metrics.cellHeight
        guard !runs.isEmpty || !line.imageSlices.isEmpty else { return }

        // Backgrounds first, as one fill per run: filling per cell would multiply the
        // draw calls by the column count for no visual difference.
        for run in runs {
            let attributes = effectiveAttributes(run.attributes)
            let background = theme.resolve(attributes.background, isForeground: false, bold: false)
            guard background != theme.background else { continue }
            context.setFillColor(background.cgColor)
            context.fill(CGRect(
                x: CGFloat(run.column) * metrics.cellWidth,
                y: flippedTop,
                width: CGFloat(run.width) * metrics.cellWidth,
                height: metrics.cellHeight
            ))
        }

        // Over the backgrounds and under everything else: a picture covers the cells it was
        // given, and a selection drawn over it must still be visible (D-065).
        if !line.imageSlices.isEmpty {
            drawImageSlices(line, flippedTop: flippedTop, in: context)
        }

        // Selection and search highlights are painted per cell over the run backgrounds,
        // because a selection boundary rarely lines up with an attribute boundary.
        drawHighlights(row: row, lineWidth: line.width, flippedTop: flippedTop, in: context)

        drawRuns(runs, atFlippedTop: flippedTop, in: context)
    }

    // MARK: - Pictures (D-065)

    /// Decoded pictures as Core Graphics images, so a redraw does not copy pixels again.
    /// Keyed by the id the screen's store filed them under.
    private var imageCache: [Int: CGImage] = [:]

    private func cachedImage(_ id: Int, in screen: TerminalScreen) -> CGImage? {
        if let cached = imageCache[id] { return cached }
        guard let image = screen.images[id],
              let provider = CGDataProvider(data: Data(image.pixels) as CFData)
        else { return nil }
        let made = CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            // Premultiplied because that is the one arrangement Core Graphics draws, and the
            // decoders premultiply once rather than the renderer doing it every frame.
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
        imageCache[id] = made
        return made
    }

    /// Draws the strips of any pictures this line carries.
    ///
    /// The whole picture is drawn each time, clipped to the one row being painted. That is
    /// what makes a picture half-scrolled off the top show its lower half, without any of the
    /// slicing arithmetic living in the emulator.
    private func drawImageSlices(_ line: TerminalLine, flippedTop: CGFloat, in context: CGContext) {
        guard let screen else { return }
        for slice in line.imageSlices {
            guard let image = cachedImage(slice.imageID, in: screen) else { continue }
            let visible = CGRect(
                x: CGFloat(slice.column) * metrics.cellWidth,
                y: flippedTop,
                width: CGFloat(slice.columns) * metrics.cellWidth,
                height: metrics.cellHeight
            )
            let whole = CGRect(
                x: visible.minX - CGFloat(slice.imageColumn) * metrics.cellWidth,
                y: flippedTop - CGFloat(slice.totalRows - 1 - slice.imageRow) * metrics.cellHeight,
                width: CGFloat(slice.totalColumns) * metrics.cellWidth,
                height: CGFloat(slice.totalRows) * metrics.cellHeight
            )
            context.saveGState()
            context.clip(to: visible)
            context.draw(image, in: whole)
            context.restoreGState()
        }
    }

    private func drawRuns(_ runs: [Run], atFlippedTop flippedTop: CGFloat, in context: CGContext) {
        for run in runs where !run.text.isEmpty {
            let attributes = effectiveAttributes(run.attributes)
            guard !attributes.invisible else { continue }
            let foreground = theme.resolve(attributes.foreground, isForeground: true, bold: attributes.bold)
            let color = attributes.dim
                ? foreground.cgColor.copy(alpha: 0.6) ?? foreground.cgColor
                : foreground.cgColor

            let attributed = NSAttributedString(string: run.text, attributes: [
                .font: font(for: attributes),
                .foregroundColor: UIColor(cgColor: color),
                // Ligatures merge `!=` or `->` into a single glyph, which breaks the
                // one-character-per-cell invariant the grid depends on — so they are off
                // unless somebody asked for them, having chosen a font that has them
                // (D-063).
                .ligature: ligaturesEnabled ? 1 : 0,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(
                x: CGFloat(run.column) * metrics.cellWidth,
                y: flippedTop + (metrics.cellHeight - metrics.baselineOffset)
            )
            CTLineDraw(ctLine, context)

            if attributes.underline || attributes.doubleUnderline || attributes.strikethrough {
                context.setStrokeColor(color)
                context.setLineWidth(metrics.underlineThickness)
                let x0 = CGFloat(run.column) * metrics.cellWidth
                let x1 = x0 + CGFloat(run.width) * metrics.cellWidth
                if attributes.underline || attributes.doubleUnderline {
                    let y = flippedTop + metrics.underlineOffset
                    context.stroke(CGRect(x: x0, y: y, width: x1 - x0, height: 0))
                    if attributes.doubleUnderline {
                        let y2 = y + metrics.underlineThickness * 2
                        context.stroke(CGRect(x: x0, y: y2, width: x1 - x0, height: 0))
                    }
                }
                if attributes.strikethrough {
                    let y = flippedTop + metrics.cellHeight / 2
                    context.stroke(CGRect(x: x0, y: y, width: x1 - x0, height: 0))
                }
            }
        }
    }

    /// Applies inverse video, which swaps foreground and background rather than being a
    /// drawing flag — otherwise every drawing site would have to remember it.
    private func effectiveAttributes(_ attributes: CellAttributes) -> CellAttributes {
        guard attributes.inverse else { return attributes }
        var swapped = attributes
        swapped.foreground = attributes.background == .default ? .default : attributes.background
        swapped.background = attributes.foreground == .default ? .default : attributes.foreground
        if attributes.background == .default, attributes.foreground == .default {
            swapped.foreground = .indexed(0)
            swapped.background = .indexed(7)
        }
        return swapped
    }

    /// Groups adjacent cells that share attributes into runs.
    ///
    /// This is the renderer's main optimisation: a row of uniformly styled text becomes
    /// one Core Text line rather than one per cell. Internal rather than private so a test
    /// can assert the run count directly — measuring it through wall-clock time is
    /// dominated by fixed per-frame cost and gives a flaky answer.
    func coalesce(_ line: TerminalLine) -> [Run] {
        var runs: [Run] = []
        var current: Run?

        for column in 0 ..< line.width {
            let cell = line[column]
            if cell.isWideContinuation {
                // The continuation cell has no glyph of its own; it only widens the run
                // so the background fill covers both halves.
                current?.width += 1
                continue
            }
            let character = cell.character ?? " "
            if var run = current, run.attributes == cell.attributes {
                run.text.append(character)
                run.width += 1
                current = run
            } else {
                if let run = current { runs.append(run) }
                current = Run(text: String(character), column: column, width: 1, attributes: cell.attributes)
            }
        }
        if let run = current { runs.append(run) }
        return runs
    }

    private func drawCursor(screen: TerminalScreen, in context: CGContext) {
        guard screen.cursor.isVisible, cursorVisibleInBlink || !screen.cursor.blinks else { return }
        let x = CGFloat(screen.cursor.column) * metrics.cellWidth
        let top = CGFloat(screen.cursor.row) * metrics.cellHeight
        let flippedTop = bounds.height - top - metrics.cellHeight

        context.setFillColor(theme.cursor.cgColor)
        switch screen.cursor.style {
        case .block:
            let rect = CGRect(x: x, y: flippedTop, width: metrics.cellWidth, height: metrics.cellHeight)
            if isFirstResponder {
                context.fill(rect)
                // Redraw the character in the background colour so it stays legible
                // inside a filled block.
                let cell = screen.lines[screen.cursor.row][screen.cursor.column]
                if let character = cell.character {
                    let attributed = NSAttributedString(string: String(character), attributes: [
                        .font: regularFont,
                        .foregroundColor: UIColor(cgColor: theme.background.cgColor),
                        .ligature: 0,
                    ])
                    context.textPosition = CGPoint(x: x, y: flippedTop + (metrics.cellHeight - metrics.baselineOffset))
                    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                }
            } else {
                // An unfocused terminal shows a hollow cursor, which is how a person
                // tells at a glance which split has the keyboard.
                context.setStrokeColor(theme.cursor.cgColor)
                context.setLineWidth(1)
                context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }
        case .underline:
            context.fill(CGRect(
                x: x,
                y: flippedTop,
                width: metrics.cellWidth,
                height: max(2, metrics.underlineThickness * 2)
            ))
        case .bar:
            context.fill(CGRect(
                x: x,
                y: flippedTop,
                width: max(2, metrics.underlineThickness * 2),
                height: metrics.cellHeight
            ))
        }
    }

    private func drawHighlights(row: Int, lineWidth: Int, flippedTop: CGFloat, in context: CGContext) {
        let absolute = absoluteRow(forDisplayRow: row)
        for column in 0 ..< lineWidth {
            let position = TerminalPosition(row: absolute, column: column)
            let color: CGColor?
            if selection?.contains(position) == true {
                color = theme.selection.cgColor
            } else if focusedMatch?.contains(position) == true {
                color = theme.cursor.cgColor.copy(alpha: 0.55)
            } else if searchMatches.contains(where: { $0.contains(position) }) {
                color = theme.selection.cgColor.copy(alpha: 0.7)
            } else {
                color = nil
            }
            guard let color else { continue }
            context.setFillColor(color)
            context.fill(CGRect(
                x: CGFloat(column) * metrics.cellWidth,
                y: flippedTop,
                width: metrics.cellWidth,
                height: metrics.cellHeight
            ))
        }
    }

    // MARK: - Cursor blink

    /// Starts or stops the blink timer.
    ///
    /// The timer runs only while the view is focused and the user has not asked to
    /// reduce motion: a blinking cursor is an animation, and for some people it is a
    /// genuinely painful one.
    func setBlinkEnabled(_ enabled: Bool) {
        blinkTimer?.invalidate()
        blinkTimer = nil
        cursorVisibleInBlink = true
        guard enabled else {
            setNeedsDisplay()
            return
        }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            // Scheduled timers fire on the main run loop, so this is already the main
            // actor; `assumeIsolated` states that rather than hopping through a Task and
            // making the cursor blink at the mercy of scheduling.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cursorVisibleInBlink.toggle()
                self.setNeedsDisplay(self.cursorRect())
            }
        }
    }

    private func cursorRect() -> CGRect {
        guard let screen else { return .zero }
        return CGRect(
            x: CGFloat(screen.cursor.column) * metrics.cellWidth,
            y: CGFloat(screen.cursor.row) * metrics.cellHeight,
            width: metrics.cellWidth * 2,
            height: metrics.cellHeight
        )
    }
}
