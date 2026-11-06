import CryptoKit
import Foundation

private let day: Double = 24 * 60 * 60 * 1000
/// Never re-validate sooner than this after a validation because of `minOfflineDuration`.
private let minRefreshIntervalMs = day

/// DER prefix of an Ed25519 SubjectPublicKeyInfo, followed by the 32-byte key.
private let ed25519SPKIPrefix: [UInt8] = [
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
]

/// Claims of a verified license token.
struct TokenPayload: Sendable, Equatable {
    /// Issued at, in seconds since 1970.
    var iat: Double
    /// Expiry, in seconds since 1970.
    var exp: Double
    /// Max app version the license allows (`"2"`, `"2.3"`), or nil for all.
    var mv: String?
}

struct ValidatedToken: Sendable {
    var token: String
    var payload: TokenPayload
}

struct TokenError: Error, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// Parses an Ed25519 public key in SPKI PEM format.
func parsePublicKey(_ pem: String) throws(ConfigError) -> Curve25519.Signing.PublicKey {
    let body =
        pem
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
        .joined()
    guard let der = Data(base64Encoded: body) else {
        throw .invalidPublicKey("not base64")
    }
    guard der.count == 44, Array(der.prefix(12)) == ed25519SPKIPrefix else {
        throw .invalidPublicKey("not an Ed25519 SPKI key")
    }
    do {
        return try Curve25519.Signing.PublicKey(rawRepresentation: der.suffix(32))
    } catch {
        throw .invalidPublicKey("\(error)")
    }
}

func base64URLDecode(_ string: Substring) -> Data? {
    guard string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else { return nil }
    var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    switch base64.count % 4 {
    case 0: break
    case 2: base64 += "=="
    case 3: base64 += "="
    default: return nil
    }
    return Data(base64Encoded: base64)
}

/// Verifies license tokens against the product's public key.
struct TokenVerifier: Sendable {
    let publicKey: Curve25519.Signing.PublicKey
    let productID: String

    /// Verifies signature and claims, as documented for offline validation:
    /// the same checks as `jose.jwtVerify` with `algorithms: ["EdDSA"]`,
    /// audience and subject, and no clock tolerance; then the machine.
    func verify(
        _ token: String,
        key: String,
        nowMs: Double,
        fingerprint: @Sendable () async -> String
    ) async throws(TokenError) -> TokenPayload {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw TokenError("not a compact JWS") }
        guard
            let headerData = base64URLDecode(parts[0]),
            let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else { throw TokenError("invalid header") }
        guard header["alg"] as? String == "EdDSA" else { throw TokenError("unexpected alg") }
        guard header["crit"] == nil else { throw TokenError("unsupported crit") }
        guard let signature = base64URLDecode(parts[2]), !signature.isEmpty else {
            throw TokenError("invalid signature")
        }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard publicKey.isValidSignature(signature, for: signingInput) else {
            throw TokenError("signature verification failed")
        }
        guard
            let payloadData = base64URLDecode(parts[1]),
            let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw TokenError("invalid payload") }

        let now = (nowMs / 1000).rounded(.down)
        switch claims["aud"] {
        case let aud as String where aud == productID: break
        case let aud as [Any] where aud.contains(where: { $0 as? String == productID }): break
        default: throw TokenError("unexpected aud")
        }
        guard claims["sub"] as? String == key else { throw TokenError("unexpected sub") }
        let iat = number(claims["iat"])
        let exp = number(claims["exp"])
        if claims["iat"] != nil, iat == nil { throw TokenError("invalid iat") }
        if claims["exp"] != nil {
            guard let exp else { throw TokenError("invalid exp") }
            if exp <= now { throw TokenError("expired") }
        }
        if claims["nbf"] != nil {
            guard let nbf = number(claims["nbf"]) else { throw TokenError("invalid nbf") }
            if nbf > now { throw TokenError("not yet valid") }
        }
        guard claims["fp"] as? String == (await fingerprint()) else {
            throw TokenError("token of another machine")
        }
        guard let iat, let exp else { throw TokenError("token without iat or exp") }
        let mv: String?
        switch claims["mv"] {
        case nil, is NSNull: mv = nil
        case let value as String: mv = value
        default: throw TokenError("invalid mv")
        }
        return TokenPayload(iat: iat, exp: exp, mv: mv)
    }

    /// A JSON number (not a boolean, which `JSONSerialization` also bridges to `NSNumber`).
    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.doubleValue
    }
}

/// When to re-validate a token, in ms since 1970: at 2/3 of its lifetime, or
/// earlier to keep `minOfflineMs` of validity, though `minOfflineMs` never
/// pulls it within 1 day of issue.
func computeRefreshAt(iat: Double, exp: Double, minOfflineMs: Double) -> Double {
    let issuedAt = iat * 1000
    let expiresAt = exp * 1000
    let twoThirds = issuedAt + (expiresAt - issuedAt) * 2 / 3
    let keepOffline = max(expiresAt - minOfflineMs, issuedAt + minRefreshIntervalMs)
    return min(twoThirds, keepOffline)
}
