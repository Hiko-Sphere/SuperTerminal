import Testing
@testable import STTerminal

/// Cell width is where terminal emulators most often disagree with the programs running
/// inside them. A remote program lays out its output assuming a particular width for
/// every character; disagreeing by one cell is what makes `vim` overwrite its status
/// line and CJK text tear.
@Suite("Character width")
struct CharacterWidthTests {
    @Test("Latin text occupies one cell per character")
    func latinIsSingleWidth() {
        for character in "Hello, world! 123 @#$%" {
            #expect(CharacterWidth.of(character) == 1, "\(character) should be one cell")
        }
    }

    @Test(
        "CJK ideographs, kana and hangul occupy two cells",
        arguments: ["中", "文", "日", "本", "語", "한", "글", "あ", "ア", "！", "０"]
    )
    func cjkIsDoubleWidth(character: Character) {
        #expect(CharacterWidth.of(character) == 2)
    }

    @Test("Halfwidth kana stays one cell")
    func halfwidthKanaIsSingleWidth() {
        #expect(CharacterWidth.of("ｱ") == 1)
        #expect(CharacterWidth.of("ﾊ") == 1)
    }

    @Test("Combining marks add no width to their base character")
    func combiningMarksAddNoWidth() {
        // "e" followed by U+0301 COMBINING ACUTE ACCENT is one grapheme, one cell.
        let composed: Character = "e\u{0301}"
        #expect(composed.unicodeScalars.count == 2)
        #expect(CharacterWidth.of(composed) == 1)
        #expect(CharacterWidth.ofScalar(Unicode.Scalar(0x0301)!) == 0)
    }

    @Test("Emoji occupy two cells, including sequences joined with ZWJ")
    func emojiIsDoubleWidth() {
        #expect(CharacterWidth.of("😀") == 2)
        #expect(CharacterWidth.of("🇯🇵") == 2)
        // A family emoji is several code points joined by U+200D; the joiners and the
        // components must not each claim a cell.
        #expect(CharacterWidth.of("👨‍👩‍👧‍👦") == 2)
    }

    @Test("A text-presentation symbol becomes wide when given an emoji variation selector")
    func variationSelectorForcesEmojiWidth() {
        // U+2764 alone is a narrow dingbat; with U+FE0F it renders as a wide emoji.
        #expect(CharacterWidth.of("\u{2764}") == 1)
        #expect(CharacterWidth.of("\u{2764}\u{FE0F}") == 2)
    }

    @Test("Control characters never claim a cell")
    func controlsAreZeroWidth() {
        #expect(CharacterWidth.ofScalar(Unicode.Scalar(0x00)) == 0)
        #expect(CharacterWidth.ofScalar(Unicode.Scalar(0x1B)) == 0)
        #expect(CharacterWidth.ofScalar(Unicode.Scalar(0x7F)) == 0)
        #expect(CharacterWidth.ofScalar(Unicode.Scalar(0x9B)) == 0)
    }

    @Test("The range tables are sorted and non-overlapping, so binary search is valid")
    func tablesAreWellFormed() {
        for table in [eastAsianWideRanges, zeroWidthMarkRanges] {
            for index in 1 ..< table.count {
                #expect(
                    table[index - 1].upperBound < table[index].lowerBound,
                    "ranges must be sorted and disjoint at index \(index)"
                )
            }
        }
    }
}
