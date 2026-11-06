import Foundation
import Testing

@testable import LicenseManagerKit

@Suite("license observer")
@MainActor
final class LicenseObserverTests {
    let h = Harness()

    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @Test("publishes state, key hint and offline changes")
    func publishes() async throws {
        h.serveValid()
        let lm = try h.make()
        let observer = LicenseObserver(manager: lm)
        #expect(observer.state == .missingKey)
        #expect(observer.licenseKeyHint == nil)
        #expect(observer.portalURL == lm.portalURL)

        #expect(try await observer.activate(key: licenseKey) == .active)
        await eventually { observer.state == .active }
        #expect(observer.state == .active)
        #expect(observer.licenseKeyHint == "B3JDF")
        #expect(observer.offlineState == .online)

        // Server unreachable at the next refresh: still active, now offline.
        h.transport.validate = { _ in throw URLError(.notConnectedToInternet) }
        await h.advance(2 * week)
        for _ in 0..<60 { await h.advance(5000) }
        await eventually { observer.offlineState != .online }
        #expect(observer.state == .active)
        guard case .offline(let validUntil, _) = observer.offlineState else {
            Issue.record("expected offline")
            return
        }
        #expect(validUntil != nil)
    }

    @Test("publishes the latest allowed version and refreshes")
    func latestAllowedVersion() async throws {
        try await h.seed()
        h.transport.validate = { _ in fail(403, "version_not_allowed", ["latestAllowedVersion": "2.2.0"]) }
        let lm = try h.make()
        let observer = LicenseObserver(manager: lm)
        _ = await lm.ready()
        await h.advance(0)
        await eventually { observer.state == .versionNotAllowed }
        #expect(observer.latestAllowedVersion == .version("2.2.0"))

        h.serveValid()
        await observer.refresh()
        await eventually { observer.state == .active }
        #expect(observer.latestAllowedVersion == .notApplicable)
    }
}
