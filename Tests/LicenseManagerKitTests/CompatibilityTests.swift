import Foundation
import Testing

@testable import LicenseManagerKit

/// The values the Electron and Tauri SDKs compute for the same inputs
/// (`tauri-specs.md` §4), so an app moving between SDKs keeps its activations.
@Suite("compatibility with the Electron and Tauri SDKs")
struct CompatibilityTests {
    @Test("golden vectors")
    func goldenVectors() {
        #expect(SecureStore.namespace(productID: "x7Kp2QaZ") == "ea8ac6eca49d93514868857bb07922b4")
        #expect(SecureStore.fileName(key: "installId") == "ca8a5f3f684e28ccf496a00b.dat")
        #expect(SecureStore.fileName(key: "licenseKey") == "4d7f38bbfba5e53684683337.dat")
        #expect(SecureStore.fileName(key: "licenseToken") == "110af1ca6fb7b596b2a37cc3.dat")
        #expect(SecureStore.fileName(key: "lastSeen") == "758c78e59ed6d3a1649c33a8.dat")
        #expect(
            hashMachineValue("4c4c4544-0042-3510-8051-b4c04f4b4e32") == "WDpaNFX/NZW0yp1UEWsHi36rKjpX4d0zVnasSsrpJOA=")
        #expect(encodeTimestamp(1_767_225_600_000) == "MTc2NzIyNTYwMDAwMA==")
        #expect(decodeTimestamp("MTc2NzIyNTYwMDAwMA==") == 1_767_225_600_000)
        #expect(defaultKeychainService == "dev.licensemanager.sdk")
    }

    @Test("same storage locations and install id format")
    func storageLocations() async throws {
        let h = Harness()
        let fp = try await h.fingerprint()
        let parts = fp.split(separator: ":")
        #expect(parts.count == 3)
        #expect(Data(base64Encoded: String(parts[1]))?.count == 32)
        #expect(h.backend.items.current.keys.contains("dev.licensemanager.sdk::x7Kp2QaZ:installId"))
        let file = h.dir.appendingPathComponent("ca8a5f3f684e28ccf496a00b.dat")
        #expect(try String(contentsOf: file, encoding: .utf8) == String(parts[1]))
    }

    /// Run by CI after `node scripts/compat/electron-store.mjs write <dir>`:
    /// reads what `@licenseman/electron` stored, then writes for the reverse check.
    @Test(
        "reads and writes the same files as @licenseman/electron",
        .enabled(if: ProcessInfo.processInfo.environment["LICENSEMANAGER_COMPAT_DIR"] != nil)
    )
    func electronStore() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LICENSEMANAGER_COMPAT_DIR"]!)
        let expected =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: dir.appendingPathComponent("expected.json"))
            ) as! [String: String]
        let storage = dir.appendingPathComponent("storage")
        let manager = try LicenseManager(
            productID: expected["productId"]!,
            publicKey: signingKey.publicKeyPEM,
            options: .init(
                fingerprint: .value(expected["machine"]!),
                version: "1.0.0",
                apiBaseURL: URL(string: "http://127.0.0.1:9"),
                storageDirectories: [storage]
            ),
            deps: Dependencies(transport: FakeTransport(), time: FakeTime(start: start), secretBackend: nil)
        )
        defer { manager.dispose() }
        #expect(await manager.fingerprint() == expected["fingerprint"])
        let store = SecureStore(productID: expected["productId"]!, directories: [storage], backend: nil)
        #expect(store.get(installIDKey) == expected["installId"])
        store.set(licenseKeyKey, "WRITTEN-BY-SWIFT")
    }
}
