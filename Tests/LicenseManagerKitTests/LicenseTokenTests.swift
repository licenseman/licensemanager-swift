import CryptoKit
import Foundation
import Testing

@testable import LicenseManagerKit

/// JWS verification edge cases.
@Suite("license token")
struct LicenseTokenTests {
    let verifier = TokenVerifier(publicKey: signingKey.privateKey.publicKey, productID: productID)
    let now = start

    func claims(_ changes: [String: Any?] = [:]) -> [String: Any] {
        let iat = (start / 1000).rounded(.down)
        var claims: [String: Any] = [
            "fp": "FP", "mv": NSNull(), "aud": productID, "sub": licenseKey, "iat": iat, "exp": iat + 3600,
        ]
        for (key, value) in changes { claims[key] = value }
        return claims
    }

    func verify(_ token: String) async -> Result<TokenPayload, TokenError> {
        do {
            return .success(try await verifier.verify(token, key: licenseKey, nowMs: now) { "FP" })
        } catch {
            return .failure(error)
        }
    }

    @Test("accepts a valid token")
    func valid() async {
        let payload = try? await verify(signJWS(claims(["mv": "2.3"]))).get()
        #expect(
            payload
                == TokenPayload(
                    iat: (start / 1000).rounded(.down), exp: (start / 1000).rounded(.down) + 3600, mv: "2.3"))
    }

    @Test("accepts an audience array")
    func audienceArray() async {
        #expect(await verify(signJWS(claims(["aud": ["other", productID]]))).error == nil)
        #expect(await verify(signJWS(claims(["aud": ["other"]]))).error != nil)
    }

    @Test("rejects malformed tokens")
    func malformed() async {
        for token in ["", "a.b", "a.b.c.d", "!!.e30.sig", "e30.e30.", "\(base64URL(json: ["alg": "EdDSA"])).e30.AAAA"] {
            #expect(await verify(token).error != nil, "\(token)")
        }
    }

    @Test("rejects other algorithms and crit headers")
    func headers() async {
        #expect(await verify(signJWS(claims(), header: ["alg": "ES256"])).error == TokenError("unexpected alg"))
        #expect(
            await verify(signJWS(claims(), header: ["alg": "EdDSA", "crit": ["b64"]])).error
                == TokenError("unsupported crit"))
    }

    @Test("checks the time claims without leeway")
    func timeClaims() async {
        let nowSeconds = (start / 1000).rounded(.down)
        #expect(await verify(signJWS(claims(["exp": nowSeconds]))).error == TokenError("expired"))
        #expect(await verify(signJWS(claims(["nbf": nowSeconds + 1]))).error == TokenError("not yet valid"))
        #expect(await verify(signJWS(claims(["nbf": nowSeconds]))).error == nil)
        #expect(await verify(signJWS(claims(["exp": "soon"]))).error == TokenError("invalid exp"))
        #expect(await verify(signJWS(claims(["nbf": true]))).error == TokenError("invalid nbf"))
        #expect(await verify(signJWS(claims(["iat": "x"]))).error == TokenError("invalid iat"))
        #expect(await verify(signJWS(claims(["iat": nil]))).error == TokenError("token without iat or exp"))
        #expect(await verify(signJWS(claims(["exp": nil]))).error == TokenError("token without iat or exp"))
    }

    @Test("checks the subject, machine and max version")
    func claimsChecks() async {
        #expect(await verify(signJWS(claims(["sub": "other"]))).error == TokenError("unexpected sub"))
        #expect(await verify(signJWS(claims(["fp": "other"]))).error == TokenError("token of another machine"))
        #expect(await verify(signJWS(claims(["mv": 2]))).error == TokenError("invalid mv"))
        #expect(await verify(signJWS(claims(["mv": nil]))).error == nil)
    }

    @Test("parses PEM public keys")
    func pem() throws {
        #expect(
            try parsePublicKey(signingKey.publicKeyPEM).rawRepresentation
                == signingKey.privateKey.publicKey.rawRepresentation)
        #expect(throws: ConfigError.self) {
            try parsePublicKey("-----BEGIN PUBLIC KEY-----\n@@@\n-----END PUBLIC KEY-----")
        }
        #expect(throws: ConfigError.self) { try parsePublicKey(Data(repeating: 1, count: 44).base64EncodedString()) }
    }
}
