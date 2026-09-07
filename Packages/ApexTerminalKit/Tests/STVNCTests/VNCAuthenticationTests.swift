import CommonCrypto
import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import STVNC

/// The security types that authenticate an account rather than a single shared secret
/// (D-031): macOS Screen Sharing's Diffie-Hellman exchange, and VeNCrypt.
@Suite("VNC authentication", .serialized)
struct VNCAuthenticationTests {
    // MARK: - The arithmetic

    /// Exchanges computed by Python's arbitrary-precision integers, which owe nothing to
    /// the implementation under test. Without these the end-to-end test below would only
    /// prove that the client agrees with itself.
    private struct Vector {
        let keyLength: Int
        let prime: String
        let generator: UInt64
        let privateKey: String
        let expectedPublicKey: String
        let serverPublicKey: String
        let expectedSharedSecret: String
    }

    private static let vectors: [Vector] = [
        Vector(
            keyLength: 64,
            prime: "8d9e27ccc68acc0af8902202034923e2972b8a7699e708e44100fff58087fe28969423470a074efc190909dc95af883f74988d474e6248915ffb9efbe3607173",
            generator: 2,
            privateKey: "0039791c0d71f0dbe10c7964ad5d38e01d9c44f51e4f8c5e27e2b5d94cc16685b740c072e36ce22fe00e2ab0dc2a660d419e825e32da2aeff8d8f320efdc2ddd",
            expectedPublicKey: "024cba4be95cf8dcb378d3ea1d17c4d71de395f57a2f6304ee3132b69fb6e1a09e95a67aad777dae4adbaaf73d9249a38b9a83236af58df6e830b8b16ea98741",
            serverPublicKey: "67411068f9ede86dcddc7f1fd24187faffedde50a3bf240ae182f05cbdf4d8c176148b5ac56476be327c41898f1f893ba1e7060a5bdc6aa0447e15f97ccbf4c2",
            expectedSharedSecret: "50a96db633ba3dabc9424316c047745ebfcfaafeeec9ba5691ba60ff8f1f883a5d40e0e33ebd3e39d32f3280e01386b6ffb3b3faf4ae99961d141b203978d71e"
        ),
        Vector(
            keyLength: 128,
            prime: "d8b6fdef806863337958345861d7b9d6c7e99381fcc2d4dbf683bb9bd442242a8a2d54d2fb67ea43da96ecbd8d052943007a270ae2b29ea1b864f9c3bf94c6b60a51a28d0c0f25203428b9fdf54663948e1f20c6b3f204bd2ee962d9d88b113ac3d15f443d82256758a9cb402fdb8f756fe498067dd2259a8760df360e867b1d",
            generator: 2,
            privateKey: "0027272bb2811ea51c9c8631aec4efdd15e744ceb89285dfd9d05dbae5727e9d22b593a7954746e3a587c5236c443052bcec1b874b08588490f1713fa1ce2b7fdda37097e05af14f86ce0164d95220e365ed0651b27a1a5dcdc210a137e87d520e8d7a19311600af2cbfdc3b4ef148bcf4afd10d686cfdbb7bd964a309eaecc5",
            expectedPublicKey: "d12bd26f7d89c83884c2acc8eeebc6230d90dccf01b1a481a20c9d3831f8d5c615156267f82f3b4c797d9da41683e0844fa00ee1519c7cd9bc9a8460bbe109794200c3d4a2389092cadcf69d7ba766735c9644afd6235417736e58ad431c634520ce2d7539cafb9ea7d87f0a94fda9e31f781f63a2095051795ad1fc5b703bea",
            serverPublicKey: "7653e7c3b550baa917b6b9fab6655b707551d61f977fab1e24c8cd74078e5f122c5d7a45afbb079e7c07e0a0499f3d75f62d06b00eef8320a7c0319dff79ff6ae8c2af02205b7438cc84645ed0e79adeb996672e29f0a2f428b3d1da96d36731500d338b187cea9a0c78fcb752e2e3bed8b08bc0356d923b08765fe899aabeb6",
            expectedSharedSecret: "c3d0200f61a843f9007eaae9da9be361cf73a2ed2c98a632da095ef96ac1743e8d17b3741c4beaf13640c9fed028c880f8b4fddfd7b1e4bff0fed0f58ea40dfc56fbb816e0829e71f50f9624de82d0dc95d6a805fc5452402dd62bc46db7cd947a3dc3f678421c6c310d4f98e4a7d59c95d843bcac7bf880e1f775074b6b1afc"
        ),
    ]

    private static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start ... hex.index(after: start)], radix: 16)!
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    @Test("Modular exponentiation agrees with an arbitrary-precision implementation")
    func modularExponentiation() throws {
        for vector in Self.vectors {
            let limbs = (vector.keyLength + 7) / 8 + 1
            let prime = VNCBigInteger(bigEndian: Self.bytes(vector.prime), limbCount: limbs)
            let secret = VNCBigInteger(bigEndian: Self.bytes(vector.privateKey), limbCount: limbs)
            let generator = VNCBigInteger(vector.generator, limbCount: limbs)
            let serverPublic = VNCBigInteger(bigEndian: Self.bytes(vector.serverPublicKey), limbCount: limbs)

            let publicKey = generator.power(secret, modulo: prime).bigEndianBytes(count: vector.keyLength)
            #expect(Self.hex(publicKey) == vector.expectedPublicKey, "\(vector.keyLength * 8)-bit public key")

            let shared = serverPublic.power(secret, modulo: prime).bigEndianBytes(count: vector.keyLength)
            #expect(Self.hex(shared) == vector.expectedSharedSecret, "\(vector.keyLength * 8)-bit shared secret")
        }
    }

    @Test("Small identities the arithmetic must satisfy")
    func arithmeticIdentities() {
        let limbs = 3
        let modulus = VNCBigInteger(97, limbCount: limbs)
        let base = VNCBigInteger(5, limbCount: limbs)
        // 5^0 = 1, 5^1 = 5, and 5^96 = 1 modulo the prime 97 (Fermat).
        #expect(base.power(VNCBigInteger(0, limbCount: limbs), modulo: modulus) == VNCBigInteger(1, limbCount: limbs))
        #expect(base.power(VNCBigInteger(1, limbCount: limbs), modulo: modulus) == VNCBigInteger(5, limbCount: limbs))
        #expect(base.power(VNCBigInteger(96, limbCount: limbs), modulo: modulus) == VNCBigInteger(1, limbCount: limbs))
        // A number wider than the modulus reduces before it is used.
        #expect(VNCBigInteger(1000, limbCount: limbs).reduced(modulo: modulus) == VNCBigInteger(30, limbCount: limbs))
        // Round-tripping the wire form of a number keeps every byte.
        let wire = Self.bytes("0102030405060708090a0b0c0d0e0f10")
        #expect(VNCBigInteger(bigEndian: wire, limbCount: 3).bigEndianBytes(count: 16) == wire)
    }

    @Test("AES-128 matches the published answer for the published key")
    func aesKnownAnswer() throws {
        // FIPS-197 appendix B/C.1.
        let key = Data(Self.bytes("000102030405060708090a0b0c0d0e0f"))
        let plaintext = Self.bytes("00112233445566778899aabbccddeeff")
        let ciphertext = try VNCAppleAuthentication.aes128ECBEncrypt(plaintext, key: key)
        #expect(Self.hex(ciphertext) == "69c4e0d86a7b0430d8cdb78070b4c55a")
    }

    // MARK: - The exchange, end to end

    /// The server's half of the Apple exchange, so the client's answer is checked by
    /// something that has to undo it rather than by re-running the client's own steps.
    private struct AppleServer {
        let keyLength: Int
        let prime: VNCBigInteger
        let generator: VNCBigInteger
        let privateKey: VNCBigInteger
        let limbs: Int

        init(vector: Vector) {
            keyLength = vector.keyLength
            limbs = (vector.keyLength + 7) / 8 + 1
            prime = VNCBigInteger(bigEndian: VNCAuthenticationTests.bytes(vector.prime), limbCount: limbs)
            generator = VNCBigInteger(vector.generator, limbCount: limbs)
            // Any exponent will do for the server's half; this one keeps the test quick.
            privateKey = VNCBigInteger(bigEndian: VNCAuthenticationTests.bytes(vector.privateKey), limbCount: limbs)
        }

        var publicKey: VNCBigInteger { generator.power(privateKey, modulo: prime) }

        /// What the server puts on the wire to open the exchange.
        func challenge() -> [UInt8] {
            var bytes: [UInt8] = []
            bytes.append(contentsOf: [0, UInt8(generator.bigEndianBytes(count: 1)[0])])
            bytes.append(contentsOf: [UInt8(keyLength >> 8), UInt8(keyLength & 255)])
            bytes.append(contentsOf: prime.bigEndianBytes(count: keyLength))
            bytes.append(contentsOf: publicKey.bigEndianBytes(count: keyLength))
            return bytes
        }

        /// Undoes what the client did, and reports the credentials it finds.
        func readCredentials(from response: [UInt8]) throws -> (username: String, password: String) {
            #expect(response.count == VNCAppleAuthentication.credentialsLength + keyLength)
            let ciphertext = Array(response.prefix(VNCAppleAuthentication.credentialsLength))
            let clientPublic = VNCBigInteger(
                bigEndian: Array(response.suffix(keyLength)),
                limbCount: limbs
            )
            let shared = clientPublic.power(privateKey, modulo: prime)
            let key = Data(Insecure.MD5.hash(data: Data(shared.bigEndianBytes(count: keyLength))))
            let plaintext = try Self.decrypt(ciphertext, key: key)
            return (Self.field(plaintext, at: 0), Self.field(plaintext, at: 64))
        }

        private static func field(_ block: [UInt8], at offset: Int) -> String {
            let slice = block[offset ..< offset + 64]
            let end = slice.firstIndex(of: 0) ?? slice.endIndex
            return String(decoding: block[offset ..< end], as: UTF8.self)
        }

        private static func decrypt(_ ciphertext: [UInt8], key: Data) throws -> [UInt8] {
            var output = [UInt8](repeating: 0, count: ciphertext.count)
            var moved = 0
            let status = key.withUnsafeBytes { keyBytes in
                ciphertext.withUnsafeBufferPointer { source in
                    output.withUnsafeMutableBufferPointer { destination in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, kCCKeySizeAES128, nil,
                            source.baseAddress, source.count,
                            destination.baseAddress, destination.count, &moved
                        )
                    }
                }
            }
            #expect(status == kCCSuccess)
            return output
        }
    }

    @Test("A Mac's exchange carries the account name and password, and only the server can read them")
    func appleExchange() throws {
        for vector in Self.vectors {
            let server = AppleServer(vector: vector)
            var buffer = ByteBuffer(bytes: server.challenge())
            let challenge = try #require(try VNCAppleAuthentication.readChallenge(from: &buffer))
            #expect(buffer.readableBytes == 0, "the whole challenge was consumed")

            let padding = (0 ..< 128).map { UInt8($0) }
            let response = try VNCAppleAuthentication.response(
                to: challenge,
                username: "screen-user",
                password: "a password with spaces",
                privateKey: Self.bytes(vector.privateKey),
                padding: padding
            )
            let credentials = try server.readCredentials(from: response)
            #expect(credentials.username == "screen-user")
            #expect(credentials.password == "a password with spaces")

            // Nothing recognisable is on the wire: the block is encrypted, not merely padded.
            let ciphertext = Array(response.prefix(128))
            #expect(!Self.hex(ciphertext).contains(Self.hex(Array("screen-user".utf8))))
        }
    }

    @Test("An incomplete challenge is waited for rather than half-read")
    func appleChallengeWaits() throws {
        let server = AppleServer(vector: Self.vectors[0])
        let whole = server.challenge()
        var buffer = ByteBuffer(bytes: whole.dropLast())
        #expect(try VNCAppleAuthentication.readChallenge(from: &buffer) == nil)
        #expect(buffer.readableBytes == whole.count - 1, "and nothing was consumed")
        buffer.writeBytes([whole[whole.count - 1]])
        #expect(try VNCAppleAuthentication.readChallenge(from: &buffer) != nil)
    }

    @Test("A key length no server would send is refused before anything is allocated")
    func absurdKeyLength() {
        var buffer = ByteBuffer(bytes: [0, 2, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 16))
        #expect(throws: VNCError.self) { _ = try VNCAppleAuthentication.readChallenge(from: &buffer) }
    }

    @Test("Credentials too long for the format are refused rather than truncated")
    func overlongCredentials() {
        #expect(throws: VNCError.self) {
            try VNCAppleAuthentication.validate(username: String(repeating: "u", count: 64), password: "short")
        }
        #expect(throws: Never.self) {
            try VNCAppleAuthentication.validate(username: String(repeating: "u", count: 63), password: "short")
        }
    }

    // MARK: - Choosing a security type

    @Test("The security type chosen is the best one the credentials allow")
    func securityChoice() throws {
        let none = RFB.SecurityType.noAuthentication.rawValue
        let vnc = RFB.SecurityType.vncAuthentication.rawValue
        let apple = RFB.SecurityType.appleRemoteDesktop.rawValue
        let veNCrypt = RFB.SecurityType.veNCrypt.rawValue

        // None wins whenever offered: the server wants no secret, so asking for one would
        // be inventing a requirement it does not have.
        #expect(try RFB.chooseSecurity(offered: [none, vnc, apple], hasUsername: true, hasPassword: true) == none)
        // A Mac offering both: the account exchange, which encrypts the password.
        #expect(try RFB.chooseSecurity(offered: [apple, vnc], hasUsername: true, hasPassword: true) == apple)
        // The same Mac with no user name given falls back to the shared-password type.
        #expect(try RFB.chooseSecurity(offered: [apple, vnc], hasUsername: false, hasPassword: true) == vnc)
        #expect(try RFB.chooseSecurity(offered: [vnc], hasUsername: false, hasPassword: true) == vnc)
        #expect(try RFB.chooseSecurity(offered: [veNCrypt], hasUsername: true, hasPassword: true) == veNCrypt)

        // And when nothing on offer can be completed, the error says which thing is missing.
        #expect(throws: VNCError.credentialsRequired) {
            _ = try RFB.chooseSecurity(offered: [apple], hasUsername: false, hasPassword: true)
        }
        // With the user name already given it is the password that is missing, and that one
        // is asked for on the spot rather than sending the user back to the editor.
        #expect(throws: VNCError.passwordRequired) {
            _ = try RFB.chooseSecurity(offered: [apple], hasUsername: true, hasPassword: false)
        }
        #expect(throws: VNCError.passwordRequired) {
            _ = try RFB.chooseSecurity(offered: [vnc], hasUsername: false, hasPassword: false)
        }
        #expect(throws: VNCError.noAcceptableSecurity([99])) {
            _ = try RFB.chooseSecurity(offered: [99], hasUsername: true, hasPassword: true)
        }
    }

    // MARK: - VeNCrypt, through the handshake itself

    /// A channel with the handler in it, wound forward to the point where the client has
    /// chosen VeNCrypt. Returns the choice it made along with the channel, and leaves
    /// nothing of the version exchange in the outbound queue for a test to trip over.
    private func handshake(options: VNCClient.Options) throws -> (channel: EmbeddedChannel, chose: UInt8?) {
        let (events, continuation) = AsyncStream<VNCEvent>.makeStream(bufferingPolicy: .unbounded)
        _ = events
        let channel = EmbeddedChannel()
        let ready = channel.eventLoop.makePromise(of: RFB.ServerInit.self)
        // The promise is answered or failed by the handler; without a listener a failure
        // is an unhandled error at teardown.
        ready.futureResult.whenComplete { _ in }
        try channel.pipeline.syncOperations.addHandler(
            RFBClientHandler(options: options, framebuffer: RFBFramebuffer(width: 1, height: 1), events: continuation, ready: ready)
        )
        var server = ByteBuffer()
        server.writeString("RFB 003.008\n")
        server.writeInteger(UInt8(1))
        server.writeInteger(RFB.SecurityType.veNCrypt.rawValue)
        try channel.writeInbound(server)
        return (channel, try written(channel).last)
    }

    /// Everything the client has written, as bytes.
    private func written(_ channel: EmbeddedChannel) throws -> [UInt8] {
        var bytes: [UInt8] = []
        while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
            bytes.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        }
        return bytes
    }

    private func subtypes(_ values: [UInt32]) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(values.count))
        for value in values { buffer.writeInteger(value) }
        return buffer
    }

    @Test("VeNCrypt agrees a version, then sends the user name and password it was given")
    func veNCryptPlain() throws {
        let (channel, chose) = try handshake(options: .init(
            username: "remote-user", password: "secret", allowsPlaintextAuthentication: true
        ))
        defer { _ = try? channel.finish() }
        #expect(chose == RFB.SecurityType.veNCrypt.rawValue, "the client chose VeNCrypt")

        try channel.writeInbound(ByteBuffer(bytes: [0, 2]))              // server speaks 0.2
        #expect(try written(channel) == [0, 2], "and answered with the version it speaks")

        try channel.writeInbound(ByteBuffer(bytes: [0]))                 // the version is accepted
        try channel.writeInbound(subtypes([RFB.VeNCryptSubtype.plain.rawValue]))

        var reply = ByteBuffer(bytes: try written(channel))
        #expect(reply.readInteger(as: UInt32.self) == RFB.VeNCryptSubtype.plain.rawValue)
        // The version reply was drained above, so what is left is the sub-type and the
        // credentials — nothing else can have been written.
        let lengths = (reply.readInteger(as: UInt32.self), reply.readInteger(as: UInt32.self))
        let usernameLength = try #require(lengths.0)
        let passwordLength = try #require(lengths.1)
        #expect(usernameLength == 11 && passwordLength == 6)
        #expect(reply.readString(length: Int(usernameLength)) == "remote-user")
        #expect(reply.readString(length: Int(passwordLength)) == "secret")
    }

    @Test("A password would go across a direct connection in the clear, so VeNCrypt Plain is refused")
    func veNCryptPlainRefusedInTheClear() throws {
        let (channel, _) = try handshake(options: .init(
            username: "remote-user", password: "secret", allowsPlaintextAuthentication: false
        ))
        defer { _ = try? channel.finish() }
        try channel.writeInbound(ByteBuffer(bytes: [0, 2]))
        try channel.writeInbound(ByteBuffer(bytes: [0]))
        try channel.writeInbound(subtypes([RFB.VeNCryptSubtype.plain.rawValue]))

        // The client closed rather than sending it, and nothing of the password went out.
        #expect(!channel.isActive, "the connection was closed instead")
        let sent = try written(channel)
        #expect(!sent.contains(Array("secret".utf8)), "and the password was never written")
    }

    @Test("The challenge sub-type is preferred to the one that sends the password as it is")
    func veNCryptPrefersTheChallenge() throws {
        let (channel, _) = try handshake(options: .init(
            username: "remote-user", password: "secret", allowsPlaintextAuthentication: true
        ))
        defer { _ = try? channel.finish() }
        try channel.writeInbound(ByteBuffer(bytes: [0, 2]))
        try channel.writeInbound(ByteBuffer(bytes: [0]))
        _ = try written(channel)                                      // the version reply
        try channel.writeInbound(subtypes([
            RFB.VeNCryptSubtype.plain.rawValue, RFB.VeNCryptSubtype.vncAuthentication.rawValue,
        ]))
        var reply = ByteBuffer(bytes: try written(channel))
        #expect(reply.readInteger(as: UInt32.self) == RFB.VeNCryptSubtype.vncAuthentication.rawValue)
        #expect(reply.readableBytes == 0, "and no credentials followed it")

        // …and the client then answers the classic challenge, which proves it moved on to it.
        try channel.writeInbound(ByteBuffer(bytes: [UInt8](repeating: 7, count: 16)))
        #expect(try written(channel).count == 16, "the challenge was answered")
    }

    @Test("A server that only offers VeNCrypt's own TLS is told so rather than left hanging")
    func veNCryptTLSOnly() throws {
        let (channel, _) = try handshake(options: .init(username: "u", password: "p"))
        defer { _ = try? channel.finish() }
        try channel.writeInbound(ByteBuffer(bytes: [0, 2]))
        try channel.writeInbound(ByteBuffer(bytes: [0]))
        try channel.writeInbound(subtypes([
            RFB.VeNCryptSubtype.tlsPlain.rawValue, RFB.VeNCryptSubtype.x509Plain.rawValue,
        ]))
        #expect(!channel.isActive, "the connection was closed")
    }
}
