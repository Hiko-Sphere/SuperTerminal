import Foundation

/// Minimal, allocation-conscious JOSE parsing limited to what Cloudflare Access
/// emits: compact-serialised JWS with a single signature.
///
/// This type deliberately performs **no** validation of its own. Splitting parsing
/// from verification keeps "I decoded this" and "I trust this" impossible to confuse
/// at a call site — the verifier is the only thing that produces a
/// ``VerifiedAccessJWT``.
public struct ParsedJWT: Sendable, Equatable {
    /// The raw compact serialisation, retained so the signature can be recomputed.
    public let compact: String
    public let header: JOSEHeader
    /// The decoded payload bytes, before any claim-specific interpretation.
    public let payload: Data
    public let signature: Data
    /// `base64url(header) + "." + base64url(payload)` — the exact bytes a JWS
    /// signature covers.
    public let signingInput: Data

    public struct JOSEHeader: Sendable, Equatable, Decodable {
        public let alg: String
        public let kid: String?
        public let typ: String?
    }

    public init(compact: String) throws {
        let segments = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw AccessError.malformedToken("expected 3 JWS segments, found \(segments.count)")
        }
        guard
            let headerData = Base64URL.decode(String(segments[0])),
            let payloadData = Base64URL.decode(String(segments[1])),
            let signatureData = Base64URL.decode(String(segments[2]))
        else {
            throw AccessError.malformedToken("JWS segment is not valid base64url")
        }
        guard let signingInput = "\(segments[0]).\(segments[1])".data(using: .ascii) else {
            throw AccessError.malformedToken("JWS signing input is not ASCII")
        }

        self.compact = compact
        header = try JSONDecoder().decode(JOSEHeader.self, from: headerData)
        payload = payloadData
        signature = signatureData
        self.signingInput = signingInput
    }

    public func decodePayload<T: Decodable>(as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: payload)
        } catch {
            throw AccessError.malformedToken("JWT payload did not decode as \(T.self): \(error)")
        }
    }
}

/// base64url (RFC 7515 §2) without padding.
public enum Base64URL {
    public static func decode(_ string: String) -> Data? {
        var value = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder == 2 { value += "==" } else if remainder == 3 { value += "=" } else if remainder == 1 { return nil }
        return Data(base64Encoded: value)
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The `aud` claim is a string in some Cloudflare responses and an array in others.
/// This wrapper normalises both spellings to a set.
public struct AudienceClaim: Sendable, Equatable, Decodable {
    public let values: [String]

    public init(values: [String]) { self.values = values }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            values = [single]
        } else if let many = try? container.decode([String].self) {
            values = many
        } else {
            throw AccessError.malformedToken("aud claim is neither a string nor an array of strings")
        }
    }

    public func contains(_ audience: String) -> Bool { values.contains(audience) }
}
