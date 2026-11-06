import Foundation
import LicenseManagerKit
import Testing

/// Port of the Electron SDK's `index.test.ts`, without `@testable`: only the public API.
@Suite("public API")
struct PublicAPITests {
    @Test("exports the SDK name and LicenseManager")
    func exports() {
        #expect(LicenseManager.sdkName == "licensemanager-swift")
        #expect(LicenseManager.sdkVersion.wholeMatch(of: /\d+\.\d+\.\d+.*/) != nil)
    }

    @Test("uses the same state and error strings as the other SDKs")
    func rawValues() {
        #expect(
            LicenseState.allCases.map(\.rawValue) == [
                "LOADING", "MISSING_KEY", "ACTIVE", "INVALID_KEY", "EXPIRED", "VERSION_NOT_ALLOWED",
                "MACHINE_LIMIT_REACHED", "OFFLINE_EXPIRED", "CLOCK_TAMPERED",
            ])
        #expect(
            LicenseError.Code.allCases.map(\.rawValue) == [
                "not_found", "license_expired", "version_not_allowed", "machine_limit_reached", "plan_limit_exceeded",
                "validation_error", "internal_error", "network_error", "invalid_response",
            ])
        #expect(
            LicenseError.Code.allCases.filter(\.isLocking) == [
                .notFound, .licenseExpired, .versionNotAllowed, .machineLimitReached,
            ])
    }

    @Test("describes errors")
    func describesErrors() {
        let error = LicenseError(.notFound, "No such key", status: 404)
        #expect(error.errorDescription == "No such key")
        #expect(error.description == "LicenseError(not_found, status 404): No such key")
        #expect(error.isLocking)
        #expect(!LicenseError(.networkError, "x").isLocking)
    }

    @Test("rejects an invalid configuration from the public initializer")
    func publicInitializer() {
        #expect(throws: ConfigError.missingProductID) {
            try LicenseManager(productID: "", publicKey: "x")
        }
    }
}
