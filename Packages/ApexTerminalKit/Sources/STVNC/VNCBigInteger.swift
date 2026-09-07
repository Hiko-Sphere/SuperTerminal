import Foundation

/// Just enough unsigned arithmetic for one Diffie-Hellman exchange (D-031).
///
/// macOS Screen Sharing authenticates with a Diffie-Hellman exchange over a group the
/// server chooses, which needs modular exponentiation on numbers of up to 1024 bits.
/// Neither CryptoKit nor Security exposes that over an arbitrary group, so it is here.
///
/// The reduction is deliberately the schoolbook one — double, compare, conditionally
/// subtract — and never divides. Division is where a hand-written big integer goes wrong,
/// and nothing here is on a hot path: it runs twice, once per connection, on numbers small
/// enough that the difference is milliseconds.
struct VNCBigInteger: Equatable {
    /// Little-endian: `limbs[0]` is the least significant.
    private(set) var limbs: [UInt64]

    init(limbCount: Int) { limbs = [UInt64](repeating: 0, count: max(1, limbCount)) }

    /// Reads a big-endian number, widened to `limbCount` limbs.
    init(bigEndian bytes: [UInt8], limbCount: Int) {
        self.init(limbCount: limbCount)
        for byte in bytes {
            shiftLeftByte()
            limbs[0] |= UInt64(byte)
        }
    }

    init(_ value: UInt64, limbCount: Int) {
        self.init(limbCount: limbCount)
        limbs[0] = value
    }

    /// Big-endian bytes, left-padded to exactly `count` — the width the wire expects.
    func bigEndianBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0 ..< count {
            let byteIndex = count - 1 - index
            let limb = index / 8
            guard limb < limbs.count else { break }
            bytes[byteIndex] = UInt8(truncatingIfNeeded: limbs[limb] >> UInt64((index % 8) * 8))
        }
        return bytes
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    /// The position of the highest set bit, or nil when the number is zero.
    var highestSetBit: Int? {
        for index in stride(from: limbs.count - 1, through: 0, by: -1) where limbs[index] != 0 {
            return index * 64 + (63 - limbs[index].leadingZeroBitCount)
        }
        return nil
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 64
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt64(index % 64)) & 1 == 1
    }

    private mutating func shiftLeftByte() {
        var carry: UInt64 = 0
        for index in 0 ..< limbs.count {
            let next = limbs[index] >> 56
            limbs[index] = (limbs[index] << 8) | carry
            carry = next
        }
    }

    /// Doubles in place; returns the bit that fell off the top.
    private mutating func doubleInPlace() -> Bool {
        var carry: UInt64 = 0
        for index in 0 ..< limbs.count {
            let next = limbs[index] >> 63
            limbs[index] = (limbs[index] << 1) | carry
            carry = next
        }
        return carry == 1
    }

    /// Adds in place; returns the carry out of the top limb.
    private mutating func addInPlace(_ other: VNCBigInteger) -> Bool {
        var carry: UInt64 = 0
        for index in 0 ..< limbs.count {
            let (sum, overflowed) = limbs[index].addingReportingOverflow(other.limbs[index])
            let (total, overflowedAgain) = sum.addingReportingOverflow(carry)
            limbs[index] = total
            carry = (overflowed || overflowedAgain) ? 1 : 0
        }
        return carry == 1
    }

    private mutating func subtractInPlace(_ other: VNCBigInteger) {
        var borrow: UInt64 = 0
        for index in 0 ..< limbs.count {
            let (difference, underflowed) = limbs[index].subtractingReportingOverflow(other.limbs[index])
            let (total, underflowedAgain) = difference.subtractingReportingOverflow(borrow)
            limbs[index] = total
            borrow = (underflowed || underflowedAgain) ? 1 : 0
        }
    }

    /// `self < other`, comparing from the most significant limb down.
    private func isLess(than other: VNCBigInteger) -> Bool {
        for index in stride(from: limbs.count - 1, through: 0, by: -1) where limbs[index] != other.limbs[index] {
            return limbs[index] < other.limbs[index]
        }
        return false
    }

    /// `self` reduced modulo `modulus`, for a `self` of the same width. One pass over the
    /// bits: every step doubles what has been read so far and takes the modulus back off.
    func reduced(modulo modulus: VNCBigInteger) -> VNCBigInteger {
        var result = VNCBigInteger(limbCount: limbs.count)
        guard let top = highestSetBit else { return result }
        for index in stride(from: top, through: 0, by: -1) {
            let overflowed = result.doubleInPlace()
            if overflowed || !result.isLess(than: modulus) { result.subtractInPlace(modulus) }
            if bit(index) {
                let carried = result.addInPlace(VNCBigInteger(1, limbCount: limbs.count))
                if carried || !result.isLess(than: modulus) { result.subtractInPlace(modulus) }
            }
        }
        return result
    }

    /// `(self × other) mod modulus`, for operands already less than the modulus.
    func multiplied(by other: VNCBigInteger, modulo modulus: VNCBigInteger) -> VNCBigInteger {
        var result = VNCBigInteger(limbCount: limbs.count)
        guard let top = other.highestSetBit else { return result }
        for index in stride(from: top, through: 0, by: -1) {
            let overflowed = result.doubleInPlace()
            if overflowed || !result.isLess(than: modulus) { result.subtractInPlace(modulus) }
            if other.bit(index) {
                let carried = result.addInPlace(self)
                if carried || !result.isLess(than: modulus) { result.subtractInPlace(modulus) }
            }
        }
        return result
    }

    /// `self ^ exponent mod modulus`, square and multiply.
    func power(_ exponent: VNCBigInteger, modulo modulus: VNCBigInteger) -> VNCBigInteger {
        guard !modulus.isZero else { return VNCBigInteger(limbCount: limbs.count) }
        var result = VNCBigInteger(1, limbCount: limbs.count).reduced(modulo: modulus)
        let base = reduced(modulo: modulus)
        guard let top = exponent.highestSetBit else { return result }
        for index in stride(from: top, through: 0, by: -1) {
            result = result.multiplied(by: result, modulo: modulus)
            if exponent.bit(index) { result = result.multiplied(by: base, modulo: modulus) }
        }
        return result
    }
}
