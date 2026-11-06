import Foundation
import Testing

@testable import LicenseManagerKit

/// Port of the Electron SDK's `license-state.test.ts`.
@Suite("license state")
struct LicenseStateTests {
    @Suite("startup")
    final class Startup {
        let h = Harness()

        @Test("is MISSING_KEY without a stored key, and makes no request")
        func missingKey() async throws {
            let lm = try h.make()
            #expect(lm.state == .missingKey)
            #expect(await lm.ready() == .missingKey)
            await h.advance(0)
            #expect(h.transport.validateCount == 0)
        }

        @Test("starts LOADING and always validates online")
        func startsLoading() async throws {
            try await h.seed()
            h.serveValid()
            let lm = try h.make()
            #expect(lm.state == .loading)
            #expect(await lm.ready() == .active)
            await h.advance(0)
            #expect(h.transport.validateCount == 1)
            #expect(lm.offlineState == .online)
        }

        @Test("resolves from a valid stored token without waiting for the server")
        func resolvesFromStoredToken() async throws {
            try await h.seed()
            let time = h.time
            h.transport.validate = { _ in
                _ = await time.sleep(ms: .infinity, signal: nil)
                throw TestError()
            }
            let lm = try h.make()
            #expect(await lm.ready() == .active)
            await h.advance(0)
            #expect(h.transport.validateCount == 1)
            #expect(lm.offlineState == .online)
        }

        @Test("waits for the server without a valid stored token")
        func waitsForServer() async throws {
            try await h.seed(lifetimeMs: week, issuedAt: start - 2 * week)
            let calls = Locked(0)
            h.transport.validate = { [h] body in
                calls.withLock { $0 += 1 }
                return calls.current < 3 ? fail(503, "unavailable") : ok(h.sign(fp: body.fingerprint, sub: body.key))
            }
            let lm = try h.make()
            #expect(await h.settle { await lm.ready() } == .active)
            #expect(h.transport.validateCount == 3)
            #expect(lm.offlineState == .online)
        }

        @Test("sends the documented request")
        func documentedRequest() async throws {
            try await h.seed()
            h.serveValid()
            let lm = try h.make {
                $0.machineName = "Jane's MacBook"
                $0.platform = "macOS"
            }
            _ = await lm.ready()
            await h.advance(0)
            let call = try #require(h.transport.validateCalls.first)
            #expect(call.request.url.absoluteString == "https://api.test/v1/products/\(productID)/validate-key")
            #expect(call.request.method == "POST")
            #expect(call.request.headers["Content-Type"] == "application/json")
            #expect(
                call.body
                    == ValidateKeyRequest(
                        key: licenseKey,
                        fingerprint: await lm.fingerprint(),
                        version: "2.3.1",
                        name: "Jane's MacBook",
                        platform: "macOS"
                    )
            )
        }

        @Test(
            "locks on a refusal and drops the token",
            arguments: [
                (404, "not_found", LicenseState.invalidKey),
                (403, "license_expired", .expired),
                (403, "version_not_allowed", .versionNotAllowed),
                (403, "machine_limit_reached", .machineLimitReached),
            ]
        )
        func locks(status: Int, code: String, state: LicenseState) async throws {
            try await h.seed()
            h.transport.validate = { _ in
                fail(status, code, code == "version_not_allowed" ? ["latestAllowedVersion": "2.3.1"] : [:])
            }
            let lm = try h.make()
            // The stored token is valid: the refusal arrives in the background.
            #expect(await lm.ready() == .active)
            await h.advance(0)
            #expect(lm.state == state)
            #expect(h.store().get(licenseTokenKey) == nil)
            #expect(lm.licenseKey == licenseKey)
            if code == "version_not_allowed" {
                #expect(lm.latestAllowedVersion == .version("2.3.1"))
            }
        }

        enum Failure: String, CaseIterable, Sendable {
            case networkError = "network error"
            case planLimitExceeded = "402 plan_limit_exceeded"
            case internalError = "500 internal_error"
            case validationError = "422 validation_error"
            case unknownCode = "unknown code"

            var response: HTTPResponse? {
                switch self {
                case .networkError: nil
                case .planLimitExceeded: fail(402, "plan_limit_exceeded")
                case .internalError: fail(500, "internal_error")
                case .validationError: fail(422, "validation_error")
                case .unknownCode: fail(418, "teapot")
                }
            }
        }

        @Test("falls back to the stored token", arguments: Failure.allCases)
        func fallsBack(failure: Failure) async throws {
            try await h.seed(lifetimeMs: 3 * week, issuedAt: start - day)
            h.transport.validate = { _ in
                guard let response = failure.response else { throw URLError(.notConnectedToInternet) }
                return response
            }
            let lm = try h.make()
            #expect(await lm.ready() == .active)
            // Background validation gives up within 5 minutes.
            for _ in 0..<60 { await h.advance(5000) }
            #expect(lm.state == .active)
            let expiresAt = (start - day + 3 * week) / 1000
            #expect(
                lm.offlineState
                    == .offline(
                        validUntil: Date(timeIntervalSince1970: expiresAt),
                        remaining: (expiresAt * 1000 - h.time.now()) / 1000
                    )
            )
        }

        @Test("is OFFLINE_EXPIRED when offline with an expired token")
        func offlineExpired() async throws {
            try await h.seed(lifetimeMs: week, issuedAt: start - 2 * week)
            let lm = try h.make()
            #expect(await h.settle { await lm.ready() } == .offlineExpired)
            #expect(lm.offlineState == .offline(validUntil: nil, remaining: 0))
        }

        @Test("is OFFLINE_EXPIRED when offline without a token")
        func offlineWithoutToken() async throws {
            _ = try await h.fingerprint()
            h.store().set(licenseKeyKey, licenseKey)
            let lm = try h.make()
            #expect(await h.settle { await lm.ready() } == .offlineExpired)
        }

        @Test("is CLOCK_TAMPERED when offline and the clock went back")
        func clockTampered() async throws {
            try await h.seed()
            h.store().set(lastSeenKey, encodeTimestamp(start + day))
            let lm = try h.make()
            #expect(await h.settle { await lm.ready() } == .clockTampered)
        }

        @Test("trusts the server over a tampered clock")
        func trustsServer() async throws {
            try await h.seed()
            h.store().set(lastSeenKey, encodeTimestamp(start + day))
            h.serveValid()
            let lm = try h.make()
            #expect(await h.settle { await lm.ready() } == .active)
        }
    }

    @Suite("max version (mv) offline")
    final class MaxVersion {
        let h = Harness()

        func seed(mv: String?) async throws {
            let fp = try await h.fingerprint()
            h.store().set(licenseKeyKey, licenseKey)
            h.store().set(licenseTokenKey, h.sign(fp: fp, mv: mv))
        }

        @Test("mv allows version", arguments: [("2", "2.3.1"), ("2.3", "2.3.1"), ("3", "2.3.1"), (nil, "9.0.0")])
        func allows(mv: String?, version: String) async throws {
            try await seed(mv: mv)
            let lm = try h.make { $0.version = version }
            #expect(await h.settle { await lm.ready() } == .active)
        }

        @Test("mv refuses version and keeps the token", arguments: [("2", "3.0.0"), ("2.3", "2.4.0")])
        func refuses(mv: String, version: String) async throws {
            try await seed(mv: mv)
            let lm = try h.make { $0.version = version }
            #expect(await h.settle { await lm.ready() } == .versionNotAllowed)
            #expect(lm.latestAllowedVersion == .notApplicable)
            #expect(h.store().get(licenseTokenKey) != nil)
        }

        @Test("lets the server override mv once reachable")
        func serverOverrides() async throws {
            try await seed(mv: "2")
            let lm = try h.make { $0.version = "3.0.0" }
            #expect(await h.settle { await lm.ready() } == .versionNotAllowed)

            // Time-limited updates: the server allows 3.0.0 although an old token said "2".
            h.serveValid()
            await h.advance(5 * 60 * 1000)
            #expect(lm.state == .active)
        }
    }

    @Suite("token verification")
    final class TokenVerification {
        let h = Harness()

        enum BadToken: String, CaseIterable, Sendable {
            case anotherProduct = "another product"
            case anotherKey = "another key"
            case anotherMachine = "another machine"
            case anotherSigningKey = "another signing key"
            case expired = "an expired token"
            case unsigned = "an unsigned token"
        }

        @Test("rejects a token", arguments: BadToken.allCases)
        func rejects(token kind: BadToken) async throws {
            h.transport.validate = { [h] body in
                let fp = body.fingerprint
                return switch kind {
                case .anotherProduct: ok(h.sign(fp: fp, aud: "other"))
                case .anotherKey: ok(h.sign(fp: fp, sub: "OTHER-KEY"))
                case .anotherMachine: ok(h.sign(fp: "other-machine"))
                case .anotherSigningKey: ok(h.sign(fp: fp, key: otherSigningKey))
                case .expired: ok(h.sign(fp: fp, lifetimeMs: hour, issuedAt: start - day))
                case .unsigned:
                    ok(
                        "\(base64URL(json: ["alg": "none"])).\(base64URL(json: ["aud": productID, "sub": licenseKey, "fp": fp]))."
                    )
                }
            }
            let lm = try h.make()
            _ = await lm.ready()
            let error = await lm.trySetLicenseKey(licenseKey).error
            #expect(error?.code == .invalidResponse)
            #expect(error?.status == 200)
            #expect(lm.state == .missingKey)
            #expect(h.store().get(licenseTokenKey) == nil)
        }
    }

    @Suite("setLicenseKey")
    final class SetLicenseKey {
        let h = Harness()

        @Test("activates and persists key and token")
        func activates() async throws {
            h.serveValid()
            let lm = try h.make()
            _ = await lm.ready()
            let states = Locked<[LicenseState]>([])
            let subscription = lm.onStateChange { state in states.withLock { $0.append(state) } }

            #expect(try await lm.setLicenseKey("  \(licenseKey)\n") == .active)
            #expect(states.current == [.active])
            #expect(lm.licenseKey == licenseKey)
            #expect(h.store().get(licenseKeyKey) == licenseKey)
            #expect(h.store().get(licenseTokenKey) != nil)
            subscription.cancel()
        }

        @Test("keeps the key's case")
        func keepsCase() async throws {
            h.serveValid()
            let lm = try h.make()
            _ = await lm.ready()
            try await lm.setLicenseKey("abc-def")
            #expect(h.transport.validateCalls.last?.body?.key == "abc-def")
        }

        @Test("throws on a refused key and leaves the current license alone")
        func refusedKey() async throws {
            try await h.seed()
            h.serveValid()
            let lm = try h.make()
            _ = await lm.ready()
            await h.advance(0)
            let token = h.store().get(licenseTokenKey)

            h.transport.validate = { _ in fail(404, "not_found") }
            let error = await lm.trySetLicenseKey("TYPO").error
            #expect(error?.code == .notFound)
            #expect(error?.status == 404)
            #expect(lm.state == .active)
            #expect(lm.licenseKey == licenseKey)
            #expect(h.store().get(licenseTokenKey) == token)
        }

        @Test("throws network_error when offline")
        func offline() async throws {
            let lm = try h.make()
            _ = await lm.ready()
            let result = await h.settle { await lm.trySetLicenseKey(licenseKey) }
            #expect(result.error?.code == .networkError)
            #expect(lm.state == .missingKey)
            #expect(h.store().get(licenseKeyKey) == nil)
        }

        @Test("reports latestAllowedVersion")
        func latestAllowedVersion() async throws {
            h.transport.validate = { _ in fail(403, "version_not_allowed", ["latestAllowedVersion": NSNull()]) }
            let lm = try h.make()
            _ = await lm.ready()
            let error = await lm.trySetLicenseKey(licenseKey).error
            #expect(error?.code == .versionNotAllowed)
            #expect(error?.latestAllowedVersion == .noneAllowed)
            #expect(error?.isLocking == true)
        }

        @Test("rejects an empty key without a request")
        func emptyKey() async throws {
            let lm = try h.make()
            _ = await lm.ready()
            #expect(await lm.trySetLicenseKey("   ").error?.code == .validationError)
            #expect(h.transport.validateCount == 0)
        }
    }

    @Suite("retries")
    final class Retries {
        let h = Harness()

        @Test("retries transient failures on setLicenseKey")
        func retriesTransient() async throws {
            let lm = try h.make()
            _ = await lm.ready()
            let calls = Locked(0)
            h.transport.validate = { [h] body in
                calls.withLock { $0 += 1 }
                return calls.current < 3 ? fail(503, "unavailable") : ok(h.sign(fp: body.fingerprint, sub: body.key))
            }
            let result = await h.settle { await lm.trySetLicenseKey(licenseKey) }
            #expect(result == .success(LicenseState.active))
            #expect(h.transport.validateCount == 3)
        }

        @Test(
            "does not retry final answers",
            arguments: [(404, "not_found"), (402, "plan_limit_exceeded"), (422, "validation_error")]
        )
        func noRetry(status: Int, code: String) async throws {
            let lm = try h.make()
            _ = await lm.ready()
            h.transport.validate = { _ in fail(status, code) }
            let result = await h.settle { await lm.trySetLicenseKey(licenseKey) }
            #expect(result.error?.code.rawValue == code)
            #expect(h.transport.validateCount == 1)
        }

        @Test("gives up on setLicenseKey within 30 seconds")
        func givesUp() async throws {
            let lm = try h.make()
            _ = await lm.ready()
            let startedAt = h.time.now()
            let failedAt = Locked<Double>(0)
            let time = h.time
            let result = await h.settle {
                let result = await lm.trySetLicenseKey(licenseKey)
                failedAt.set(time.now())
                return result
            }
            #expect(result.error?.code == .networkError)
            #expect(h.transport.validateCount > 1)
            #expect(failedAt.current - startedAt <= 30 * 1000)
        }

        @Test("retries longer in the background")
        func retriesInBackground() async throws {
            h.serveValid()
            let lm = try h.make()
            _ = await lm.ready()
            try await lm.setLicenseKey(licenseKey)

            let calls = Locked(0)
            h.transport.validate = { [h] body in
                calls.withLock { $0 += 1 }
                if calls.current < 8 { throw URLError(.notConnectedToInternet) }
                return ok(h.sign(fp: body.fingerprint, sub: body.key))
            }
            await h.advance(2 * week)
            for _ in 0..<60 where calls.current < 8 { await h.advance(5000) }
            await h.advance(0)
            #expect(calls.current == 8)
            #expect(lm.offlineState == .online)
        }

        @Test("stops retrying after dispose")
        func stopsAfterDispose() async throws {
            let lm = try h.make()
            _ = await lm.ready()
            let task = Task { await lm.trySetLicenseKey(licenseKey) }
            await h.advance(0)
            lm.dispose()
            let result = await h.settle { await task.value }
            #expect(result.error?.code == .networkError)
            #expect(h.transport.validateCount == 1)
        }
    }

    @Suite("computeRefreshAt")
    struct ComputeRefreshAt {
        func at(_ lifetimeMs: Double, _ minOfflineMs: Double) -> Double {
            computeRefreshAt(iat: 0, exp: lifetimeMs / 1000, minOfflineMs: minOfflineMs)
        }

        @Test("refreshes at 2/3 of the lifetime")
        func twoThirds() {
            #expect(at(3 * week, 0) == 2 * week)
        }

        @Test("keeps minOfflineDuration of validity")
        func keepsMinOffline() {
            #expect(at(3 * week, 1.5 * week) == 1.5 * week)
        }

        @Test("ignores minOfflineDuration below the 2/3 margin")
        func ignoresSmallMinOffline() {
            #expect(at(3 * week, 2 * day) == 2 * week)
        }

        @Test("never refreshes within a day because of minOfflineDuration")
        func neverWithinADay() {
            #expect(at(3 * week, 10 * week) == day)
        }

        @Test("still refreshes short tokens at 2/3")
        func shortTokens() {
            #expect(at(hour, 10 * week) == 2 * hour / 3)
        }
    }

    @Suite("automatic refresh")
    final class AutomaticRefresh {
        let h = Harness()

        func activate(_ configure: (inout LicenseManager.Options) -> Void = { _ in }) async throws -> LicenseManager {
            let lm = try h.make(configure)
            _ = await lm.ready()
            try await lm.setLicenseKey(licenseKey)
            return lm
        }

        @Test("re-validates at 2/3 of the token lifetime")
        func revalidatesAtTwoThirds() async throws {
            h.serveValid()
            let lm = try await activate()
            #expect(h.transport.validateCount == 1)

            await h.advance(2 * week - 1000)
            #expect(h.transport.validateCount == 1)
            await h.advance(1000)
            #expect(h.transport.validateCount == 2)
            #expect(lm.state == .active)
        }

        @Test("honours minOfflineDuration")
        func honoursMinOffline() async throws {
            h.serveValid()
            _ = try await activate { $0.minOfflineDuration = 1.5 * week / 1000 }

            await h.advance(1.5 * week - 1000)
            #expect(h.transport.validateCount == 1)
            await h.advance(1000)
            #expect(h.transport.validateCount == 2)
        }

        @Test("goes offline on failure, retries with backoff, then expires")
        func offlineBackoffExpiry() async throws {
            h.serveValid(lifetimeMs: 3 * day)
            let lm = try await activate()

            h.transport.validate = { _ in fail(500, "internal_error") }
            await h.advance(2 * day - 1000)
            #expect(h.transport.validateCount == 1)
            // Retried for up to 5 min before giving up.
            for _ in 0..<60 { await h.advance(5000) }
            let afterFirstRound = h.transport.validateCount
            #expect(afterFirstRound > 2)
            #expect(lm.state == .active)
            guard case .offline = lm.offlineState else {
                Issue.record("expected offline")
                return
            }

            // Then 5 min until the next round.
            await h.advance(4 * 60 * 1000)
            #expect(h.transport.validateCount == afterFirstRound)
            await h.advance(2 * 60 * 1000)
            #expect(h.transport.validateCount > afterFirstRound)

            await h.advance(day)
            #expect(lm.state == .offlineExpired)

            h.serveValid(lifetimeMs: 3 * day)
            await h.advance(hour)
            #expect(lm.state == .active)
            #expect(lm.offlineState == .online)
        }

        @Test("locks when the license is refused at refresh")
        func locksAtRefresh() async throws {
            h.serveValid()
            let lm = try await activate()

            h.transport.validate = { _ in fail(403, "license_expired") }
            await h.advance(2 * week)
            #expect(lm.state == .expired)

            // No more scheduled validations once locked.
            await h.advance(10 * week)
            #expect(h.transport.validateCount == 2)

            h.serveValid()
            #expect(await lm.refresh() == .active)
        }

        @Test("handles lifetimes longer than the max timer step")
        func longLifetimes() async throws {
            h.serveValid(lifetimeMs: 90 * day)
            _ = try await activate()

            await h.advance(60 * day - 1000)
            #expect(h.transport.validateCount == 1)
            await h.advance(1000)
            #expect(h.transport.validateCount == 2)
        }

        @Test("catches up within an hour when the wall clock jumps ahead")
        func wallClockJump() async throws {
            h.serveValid()
            _ = try await activate()

            // Simulates system sleep: wall time moves past the refresh point without timers firing.
            h.time.jump(2 * week)
            await h.advance(hour)
            #expect(h.transport.validateCount == 2)
        }

        @Test("stops after dispose")
        func stopsAfterDispose() async throws {
            h.serveValid()
            let lm = try await activate()
            lm.dispose()
            await h.advance(3 * week)
            #expect(h.transport.validateCount == 1)
        }
    }
}
