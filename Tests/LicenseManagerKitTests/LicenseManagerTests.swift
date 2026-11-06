import Foundation
import Testing

@testable import LicenseManagerKit

/// `<base64 sha256 of machine>:<base64 install id>:<productId>`
func matchesFingerprintPattern(_ fingerprint: String, productID: String) -> Bool {
    fingerprint.wholeMatch(of: try! Regex("^[A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=:\(productID)$")) != nil
}

/// Port of the Electron SDK's `license-manager.test.ts`.
@Suite("license manager")
struct LicenseManagerTests {
    @Suite("constructor validation")
    final class ConstructorValidation {
        let h = Harness()

        func make(productID: String = "p", publicKey: String = signingKey.publicKeyPEM, version: String? = "1.0.0")
            throws(ConfigError)
        {
            _ = try LicenseManager(
                productID: productID,
                publicKey: publicKey,
                options: .init(version: version, storageDirectories: [h.dir]),
                deps: h.deps,
                bundle: h.emptyBundle
            )
        }

        @Test("requires productId and publicKey")
        func requiresIDs() {
            #expect(throws: ConfigError.missingProductID) { try self.make(productID: "") }
            #expect(throws: ConfigError.missingPublicKey) { try self.make(publicKey: "") }
        }

        @Test("rejects a public key that isn't an Ed25519 SPKI PEM")
        func invalidPublicKey() {
            #expect(throws: ConfigError.self) { try self.make(publicKey: "pub") }
            let rsa =
                "-----BEGIN PUBLIC KEY-----\nMFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf\n-----END PUBLIC KEY-----"
            #expect(throws: ConfigError.self) { try self.make(publicKey: rsa) }
        }

        @Test("requires a version when the bundle has none")
        func requiresVersion() {
            #expect(throws: ConfigError.missingVersion) { try self.make(version: nil) }
        }

        @Test("describes configuration errors")
        func describesErrors() {
            #expect(ConfigError.missingProductID.errorDescription == "productID is required")
            #expect(ConfigError.missingVersion.errorDescription?.contains("CFBundleShortVersionString") == true)
            #expect(ConfigError.invalidPublicKey("x").errorDescription?.contains("Ed25519") == true)
        }
    }

    @Suite("fingerprint")
    final class Fingerprint {
        let h = Harness()

        @Test("is stable and mixes machine, install ID and product")
        func stable() async throws {
            let lm = try h.make(productID: "prod-1")
            let fp = await lm.fingerprint()
            #expect(matchesFingerprintPattern(fp, productID: "prod-1"))
            #expect(await lm.fingerprint() == fp)
        }

        @Test("persists the install ID so the fingerprint is stable across instances")
        func persistsInstallID() async throws {
            let first = await try h.make().fingerprint()
            let second = await try h.make().fingerprint()
            #expect(second == first)
        }

        @Test("differs per product")
        func differsPerProduct() async throws {
            let a = await try h.make(productID: "prod-a").fingerprint()
            let b = await try h.make(productID: "prod-b").fingerprint()
            #expect(a != b)
        }

        @Test("honours a custom async fingerprint function")
        func customProvider() async throws {
            let lm = try h.make(productID: "p") { $0.fingerprint = .provider { "custom" } }
            let fp = await lm.fingerprint()
            #expect(matchesFingerprintPattern(fp, productID: "p"))
            #expect(fp.hasPrefix("\(hashMachineValue("custom")):"))
        }

        @Test("uses the machine id by default")
        func defaultMachineID() async throws {
            let lm = try h.make(productID: "p") { $0.fingerprint = nil }
            #expect(await lm.fingerprint().hasPrefix("\(hashMachineValue("test-machine")):"))
        }
    }

    @Suite("clock tamper detection (offline fallback)")
    final class ClockOffline {
        let h = Harness()

        func readLastSeen() -> Double? {
            decodeTimestamp(h.store(productID: "prod-1").get(lastSeenKey))
        }

        @Test("records the current time on construction")
        func recordsTime() async throws {
            try h.make(productID: "prod-1")
            await h.advance(0)
            #expect(readLastSeen() == start)
        }

        @Test("flags a backwards clock jump")
        func flagsBackwardsJump() async throws {
            h.store(productID: "prod-1").set(lastSeenKey, encodeTimestamp(start + 4 * hour))
            let lm = try h.make(productID: "prod-1")
            await h.advance(0)
            #expect(lm.isClockTampered)
        }

        @Test("runs hourly and keeps the stored time monotonic on forward progress")
        func runsHourly() async throws {
            let lm = try h.make(productID: "prod-1")
            await h.advance(0)
            #expect(!lm.isClockTampered)
            await h.advance(hour)
            #expect(!lm.isClockTampered)
            #expect(readLastSeen() == start + hour)
        }

        @Test("flags tampering when a scheduled run sees an earlier time")
        func flagsScheduledRun() async throws {
            let lm = try h.make(productID: "prod-1")
            await h.advance(0)
            #expect(!lm.isClockTampered)
            h.time.jump(-3 * hour)
            await h.advance(hour)
            #expect(lm.isClockTampered)
        }
    }

    @Suite("clock tamper detection (network time)")
    final class ClockNetwork {
        let h = Harness()

        func serveTime(_ ms: Double) {
            h.transport.head = { dateResponse(ms) }
        }

        @Test("flags a system clock behind network time")
        func behind() async throws {
            serveTime(start + day)
            let lm = try h.make()
            await h.advance(0)
            #expect(lm.isClockTampered)
        }

        @Test("flags a system clock ahead of network time")
        func ahead() async throws {
            serveTime(start - day)
            let lm = try h.make()
            await h.advance(0)
            #expect(lm.isClockTampered)
        }

        @Test("tolerates small skew from network time")
        func smallSkew() async throws {
            serveTime(start + 60_000)
            let lm = try h.make()
            await h.advance(0)
            #expect(!lm.isClockTampered)
        }

        @Test("trusts network time over a stored value from the future")
        func trustsNetwork() async throws {
            h.store().set(lastSeenKey, encodeTimestamp(start + day))
            serveTime(start)
            let lm = try h.make()
            await h.advance(0)
            #expect(!lm.isClockTampered)
            // Stored value is reset to network time, so going offline later
            // does not false-flag against the bogus future value.
            #expect(decodeTimestamp(h.store().get(lastSeenKey)) == start)
        }

        @Test("falls back to the stored value when the Date header is missing")
        func missingHeader() async throws {
            h.transport.head = { HTTPResponse(status: 200) }
            h.store().set(lastSeenKey, encodeTimestamp(start + 4 * hour))
            let lm = try h.make()
            await h.advance(0)
            #expect(lm.isClockTampered)
        }

        @Test("sends a HEAD request to the time URL")
        func headRequest() async throws {
            serveTime(start)
            try h.make()
            await h.advance(0)
            #expect(h.transport.validateCount == 0)
            #expect(timeURL.absoluteString == "https://google.com")
        }
    }

    @Suite("portalURL")
    final class PortalURL {
        let h = Harness()

        @Test("links to the product's portal")
        func links() throws {
            #expect(
                try h.make(productID: "prod-1").portalURL.absoluteString
                    == "https://app.licensemanager.dev/portal/prod-1")
        }

        @Test("encodes the product ID")
        func encodes() throws {
            #expect(
                try h.make(productID: "a/b c").portalURL.absoluteString
                    == "https://app.licensemanager.dev/portal/a%2Fb%20c")
        }
    }

    @Suite("dispose")
    final class Dispose {
        let h = Harness()

        @Test("stops the interval")
        func stopsInterval() async throws {
            let lm = try h.make()
            await h.advance(0)
            #expect(h.time.pending > 0)
            lm.dispose()
            lm.dispose()  // idempotent
            await h.advance(0)
            #expect(h.time.pending == 0)
        }

        @Test("finishes the state stream")
        func finishesStream() async throws {
            let lm = try h.make()
            let states = lm.states
            lm.dispose()
            var received: [LicenseState] = []
            for await state in states { received.append(state) }
            #expect(received == [.missingKey])
            var afterDispose: [LicenseState] = []
            for await state in lm.states { afterDispose.append(state) }
            #expect(afterDispose == [.missingKey])
        }
    }

    @Suite("listeners")
    final class Listeners {
        let h = Harness()

        @Test("streams the current state, then every change")
        func streams() async throws {
            h.serveValid()
            let lm = try h.make()
            _ = await lm.ready()
            var iterator = lm.states.makeAsyncIterator()
            #expect(await iterator.next() == .missingKey)
            try await lm.setLicenseKey(licenseKey)
            #expect(await iterator.next() == .active)
        }

        @Test("stops calling a cancelled or released listener")
        func cancelled() async throws {
            h.serveValid()
            let lm = try h.make()
            _ = await lm.ready()
            let calls = Locked(0)
            var subscription: LicenseManager.Subscription? = lm.onStateChange { _ in calls.withLock { $0 += 1 } }
            _ = subscription
            subscription = nil
            try await lm.setLicenseKey(licenseKey)
            #expect(calls.current == 0)
        }

        @Test("shares one request between concurrent refreshes")
        func sharesRequests() async throws {
            try await h.seed()
            h.serveValid()
            let lm = try h.make()
            _ = await lm.ready()
            await h.advance(0)
            let before = h.transport.validateCount
            async let a = lm.refresh()
            async let b = lm.refresh()
            #expect(await [a, b] == [.active, .active])
            #expect(h.transport.validateCount == before + 1)
        }
    }
}
