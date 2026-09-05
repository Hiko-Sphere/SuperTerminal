import Foundation

/// X11 keysyms, the vocabulary RFB KeyEvent speaks. Printable characters map to their
/// Unicode keysym; the keys a terminal user reaches for have their own numbers.
public enum VNCKeysym {
    public static let backspace: UInt32 = 0xFF08, tab: UInt32 = 0xFF09, `return`: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B, delete: UInt32 = 0xFFFF
    public static let home: UInt32 = 0xFF50, left: UInt32 = 0xFF51, up: UInt32 = 0xFF52, right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54, pageUp: UInt32 = 0xFF55, pageDown: UInt32 = 0xFF56, end: UInt32 = 0xFF57
    public static let insert: UInt32 = 0xFF63
    public static let capsLock: UInt32 = 0xFFE5, space: UInt32 = 0x20
    public static let shiftLeft: UInt32 = 0xFFE1, controlLeft: UInt32 = 0xFFE3, altLeft: UInt32 = 0xFFE9, superLeft: UInt32 = 0xFFEB
    public static func function(_ n: Int) -> UInt32 { 0xFFBE + UInt32(n - 1) }

    /// The keysym for a character: Latin-1 as itself, everything else as 0x01000000 + code point.
    public static func forCharacter(_ scalar: Unicode.Scalar) -> UInt32 {
        scalar.value < 0x100 ? scalar.value : 0x0100_0000 + scalar.value
    }
}
