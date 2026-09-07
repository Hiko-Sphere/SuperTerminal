import Foundation

/// The DES variant VNC Authentication uses: the password is the key, truncated or
/// zero-padded to 8 bytes, with the bits of every byte reversed (a historical quirk every
/// VNC implementation reproduces), applied in ECB to each half of the 16-byte challenge.
/// It is 56-bit DES and offers no real protection; the app says so (D-022). It is here
/// because servers still require it, and it is written out rather than pulled in because
/// no dependency worth trusting exposes this exact form.
enum VNCDES {
    static func encryptChallenge(_ challenge: [UInt8], password: String) -> [UInt8] {
        precondition(challenge.count == 16)
        var key = [UInt8](repeating: 0, count: 8)
        for (index, byte) in password.utf8.prefix(8).enumerated() {
            key[index] = reverseBits(byte)
        }
        let schedule = keySchedule(key)
        return encryptBlock(Array(challenge[0 ..< 8]), schedule) + encryptBlock(Array(challenge[8 ..< 16]), schedule)
    }

    static func reverseBits(_ byte: UInt8) -> UInt8 {
        var value = byte
        var result: UInt8 = 0
        for _ in 0 ..< 8 {
            result = (result << 1) | (value & 1)
            value >>= 1
        }
        return result
    }

    // MARK: - Standard DES (FIPS 46-3), encryption only

    private static let pc1: [Int] = [
        57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4,
    ]
    private static let pc2: [Int] = [
        14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32,
    ]
    private static let shifts: [Int] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    private static let ip: [Int] = [
        58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
        57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
    ]
    private static let fp: [Int] = [
        40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
        36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
    ]
    private static let expansion: [Int] = [
        32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
        16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
    ]
    private static let pBox: [Int] = [
        16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
    ]
    private static let sBoxes: [[Int]] = [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
         4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
         0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
         13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
         10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
         4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
         9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
         1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
         7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ]

    private static func bit(_ bytes: [UInt8], _ position: Int) -> UInt8 {
        // Positions are 1-based, most significant bit first, as in the standard's tables.
        let index = position - 1
        return (bytes[index / 8] >> (7 - UInt8(index % 8))) & 1
    }

    private static func permute(_ bytes: [UInt8], _ table: [Int], bits: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (bits + 7) / 8)
        for (i, position) in table.prefix(bits).enumerated() where bit(bytes, position) == 1 {
            out[i / 8] |= 0x80 >> UInt8(i % 8)
        }
        return out
    }

    private static func keySchedule(_ key: [UInt8]) -> [[UInt8]] {
        let permuted = permute(key, pc1, bits: 56)
        var c: UInt32 = 0, d: UInt32 = 0
        for i in 0 ..< 28 {
            c |= UInt32(bit(permuted, i + 1)) << (27 - i)
            d |= UInt32(bit(permuted, i + 29)) << (27 - i)
        }
        var subkeys: [[UInt8]] = []
        for round in 0 ..< 16 {
            for _ in 0 ..< shifts[round] {
                c = ((c << 1) | (c >> 27)) & 0x0FFF_FFFF
                d = ((d << 1) | (d >> 27)) & 0x0FFF_FFFF
            }
            var cd = [UInt8](repeating: 0, count: 7)
            for i in 0 ..< 28 {
                if (c >> (27 - i)) & 1 == 1 { cd[i / 8] |= 0x80 >> UInt8(i % 8) }
                if (d >> (27 - i)) & 1 == 1 { cd[(i + 28) / 8] |= 0x80 >> UInt8((i + 28) % 8) }
            }
            subkeys.append(permute(cd, pc2, bits: 48))
        }
        return subkeys
    }

    private static func feistel(_ right: UInt32, _ subkey: [UInt8]) -> UInt32 {
        var rightBytes = [UInt8](repeating: 0, count: 4)
        for i in 0 ..< 4 { rightBytes[i] = UInt8((right >> (24 - 8 * i)) & 0xFF) }
        let expanded = permute(rightBytes, expansion, bits: 48)
        var mixed = [UInt8](repeating: 0, count: 6)
        for i in 0 ..< 6 { mixed[i] = expanded[i] ^ subkey[i] }
        var output: UInt32 = 0
        for box in 0 ..< 8 {
            let base = box * 6
            var six = 0
            for j in 0 ..< 6 { six = (six << 1) | Int(bit(mixed, base + j + 1)) }
            let row = ((six & 0x20) >> 4) | (six & 1)
            let column = (six >> 1) & 0xF
            output = (output << 4) | UInt32(sBoxes[box][row * 16 + column])
        }
        var outBytes = [UInt8](repeating: 0, count: 4)
        for i in 0 ..< 4 { outBytes[i] = UInt8((output >> (24 - 8 * i)) & 0xFF) }
        let permuted = permute(outBytes, pBox, bits: 32)
        return permuted.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func encryptBlock(_ block: [UInt8], _ subkeys: [[UInt8]]) -> [UInt8] {
        let permuted = permute(block, ip, bits: 64)
        var left = permuted[0 ..< 4].reduce(0) { ($0 << 8) | UInt32($1) }
        var right = permuted[4 ..< 8].reduce(0) { ($0 << 8) | UInt32($1) }
        for subkey in subkeys {
            let next = left ^ feistel(right, subkey)
            left = right
            right = next
        }
        var preOutput = [UInt8](repeating: 0, count: 8)
        for i in 0 ..< 4 {
            preOutput[i] = UInt8((right >> (24 - 8 * i)) & 0xFF)
            preOutput[4 + i] = UInt8((left >> (24 - 8 * i)) & 0xFF)
        }
        return permute(preOutput, fp, bits: 64)
    }
}
