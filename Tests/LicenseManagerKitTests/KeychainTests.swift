import Foundation
import Testing

@testable import LicenseManagerKit

/// Round-trips through the real login keychain. Opt-in, because it may show
/// a keychain prompt: `LICENSEMANAGER_TEST_KEYCHAIN=1 swift test`.
@Suite(
    "keychain",
    .enabled(if: ProcessInfo.processInfo.environment["LICENSEMANAGER_TEST_KEYCHAIN"] != nil),
    .serialized
)
struct KeychainTests {
    let service = "dev.licensemanager.sdk.tests.\(UUID().uuidString)"
    let backend = KeychainBackend()

    @Test("round-trips, updates and deletes a generic password")
    func roundTrip() throws {
        let account = "prod-1:installId"
        defer { try? backend.delete(service: service, account: account) }
        #expect(try backend.get(service: service, account: account) == nil)
        try backend.set(service: service, account: account, value: "secret")
        #expect(try backend.get(service: service, account: account) == "secret")
        try backend.set(service: service, account: account, value: "updated")
        #expect(try backend.get(service: service, account: account) == "updated")
        try backend.delete(service: service, account: account)
        #expect(try backend.get(service: service, account: account) == nil)
        try backend.delete(service: service, account: account)
    }

    @Test("stores through SecureStore")
    func secureStore() {
        let store = SecureStore(productID: "prod-1", directories: [], service: service, backend: backend)
        store.set(licenseKeyKey, "KEY")
        #expect(store.get(licenseKeyKey) == "KEY")
        store.delete(licenseKeyKey)
        #expect(store.get(licenseKeyKey) == nil)
    }
}
