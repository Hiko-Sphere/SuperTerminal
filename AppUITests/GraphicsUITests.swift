import UIKit
import XCTest

/// A picture drawn by a program on a real server, seen on the screen (D-065).
///
/// The decoders are proved against other implementations in the package's tests and the
/// session tests prove the picture reaches the model. This proves the last step, which
/// nothing else can: that it is *drawn* — by asking the shell for a block of an unmistakable
/// colour and then looking at the pixels of the app's own screen for it.
@MainActor
final class GraphicsUITests: XCTestCase {
    private lazy var app: XCUIApplication = {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launch()
        return app
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ST_UITEST_SEED"] == "1",
            "run scripts/ui-terminal-e2e.sh to provide a server"
        )
    }

    func testASixelFromTheShellIsDrawnOnTheScreen() throws {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Local Test Server")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()

        let terminal = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Terminal for")
        ).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))
        if terminal.isHittable { terminal.tap() }
        // The command below is full of shifted characters, and this simulator discards the
        // first modified key press delivered to a screen — measured in D-018. Spending it on
        // ⌘C, which the terminal consumes and which copies nothing when nothing is selected,
        // means the first character that counts is the first one typed.
        app.primeModifierKeysInTerminal()

        // Nothing on screen is this colour, which is the point of choosing it: sixel's
        // percentages `0;100;50` are red 0, green 255, blue 128.
        XCTAssertFalse(screenContainsTheColour(), "the colour must not already be on screen")

        // A 24×60 block, built by the shell so that the echo of the command cannot be
        // mistaken for the sequence. The `!` is inside single quotes, where neither bash
        // nor zsh performs history expansion.
        terminal.typeText(
            #"printf '\033P0;0;0q"1;1;24;60#0;2;0;100;50'; for b in 1 2 3 4 5 6 7 8 9 10; "#
                + #"do printf '#0!24~-'; done; printf '\033\\'"# + "\n"
        )

        let deadline = Date().addingTimeInterval(30)
        var drawn = false
        while Date() < deadline, !drawn {
            drawn = screenContainsTheColour()
            if !drawn { usleep(300_000) }
        }
        XCTAssertTrue(drawn, "the sixel should be drawn in the grid, not printed as text")
    }

    /// True when the app's screen carries a run of pixels the sixel's colour.
    ///
    /// A run rather than a pixel: one stray pixel of anything can come from text
    /// anti-aliasing, while eight in a row of a colour nothing else uses is a block.
    private func screenContainsTheColour() -> Bool {
        guard let cgImage = app.screenshot().image.cgImage else { return false }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return false }

        // Every fourth row: the block is a few hundred device pixels tall, so sampling is
        // dozens of chances rather than one, and a full scan of three million pixels in a
        // debug build is slow enough to matter inside a polling loop.
        for row in stride(from: 0, to: height, by: 4) {
            var run = 0
            for column in 0 ..< width {
                let index = (row * width + column) * 4
                // The tolerance covers the display's colour space and back; nothing else on
                // this screen is within reach of it.
                let matches = abs(Int(pixels[index]) - 0) <= 24
                    && abs(Int(pixels[index + 1]) - 255) <= 24
                    && abs(Int(pixels[index + 2]) - 128) <= 24
                run = matches ? run + 1 : 0
                if run >= 8 { return true }
            }
        }
        return false
    }
}
