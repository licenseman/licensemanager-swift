import Foundation
import Testing

@testable import LicenseManagerKit

/// Port of the Electron SDK's `secure-store.test.ts`.
@Suite("secure store")
struct SecureStoreTests {
    @Suite("file fallback")
    final class FileFallback {
        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent("lm-a-\(UUID().uuidString)")
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("lm-b-\(UUID().uuidString)")

        deinit {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        func store(_ productID: String = "prod-1", _ dirs: [URL]? = nil) -> SecureStore {
            SecureStore(productID: productID, directories: dirs ?? [dirA, dirB], backend: nil)
        }

        @Test("returns nil for an unknown key")
        func unknownKey() {
            #expect(store().get(installIDKey) == nil)
        }

        @Test("round-trips a value")
        func roundTrips() {
            store().set(installIDKey, "secret")
            #expect(store().get(installIDKey) == "secret")
        }

        @Test("mirrors writes so a surviving copy is still readable")
        func mirrors() throws {
            store().set(installIDKey, "secret")
            // Simulate one location being wiped (e.g. app dir removed on uninstall).
            try FileManager.default.removeItem(at: dirA)
            #expect(store().get(installIDKey) == "secret")
        }

        @Test("deletes a value from every location")
        func deletes() {
            let store = store()
            store.set(installIDKey, "secret")
            store.delete(installIDKey)
            #expect(store.get(installIDKey) == nil)
            // Deleting a missing value is a no-op.
            store.delete(installIDKey)
        }

        @Test("isolates different productIds")
        func isolates() {
            let a = store("prod-a", [dirA])
            let b = store("prod-b", [dirB])
            a.set(installIDKey, "from-a")
            b.set(installIDKey, "from-b")
            #expect(a.get(installIDKey) == "from-a")
            #expect(b.get(installIDKey) == "from-b")
        }

        @Test("never writes a key verbatim in the filename, and keeps files private")
        func obscureFileNames() throws {
            store("prod-1", [dirA]).set(installIDKey, "secret")
            let names = try FileManager.default.contentsOfDirectory(atPath: dirA.path)
            #expect(names.count == 1)
            #expect(!names[0].contains("installId"))
            #expect(names[0].wholeMatch(of: /[0-9a-f]+\.dat/) != nil)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: dirA.appendingPathComponent(names[0]).path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            store("prod-1", [dirA]).set(installIDKey, "updated")
            #expect(store("prod-1", [dirA]).get(installIDKey) == "updated")
        }
    }

    @Suite("keychain backend")
    final class KeychainBackendTests {
        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent("lm-a-\(UUID().uuidString)")
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("lm-b-\(UUID().uuidString)")

        deinit {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        @Test("prefers the keychain over files and namespaces by productId")
        func prefersKeychain() {
            let backend = MemoryBackend()
            let a = SecureStore(productID: "prod-a", directories: [dirA], backend: backend)
            let b = SecureStore(productID: "prod-b", directories: [dirB], backend: backend)
            a.set(installIDKey, "from-a")
            b.set(installIDKey, "from-b")
            #expect(a.get(installIDKey) == "from-a")
            #expect(b.get(installIDKey) == "from-b")
            // Two distinct keychain items, no overlap.
            #expect(backend.items.current.count == 2)
            #expect(backend.items.current["dev.licensemanager.sdk::prod-a:installId"] == "from-a")
        }

        @Test("uses the configured keychain service and backfills from files")
        func backfills() {
            SecureStore(productID: "prod-1", directories: [dirA], backend: nil).set(installIDKey, "secret")
            let backend = MemoryBackend()
            let store = SecureStore(
                productID: "prod-1", directories: [dirA], service: "com.example.app", backend: backend)
            #expect(store.get(installIDKey) == "secret")
            #expect(backend.items.current == ["com.example.app::prod-1:installId": "secret"])
        }

        @Test("skips the keychain when useKeychain is false")
        func skipsKeychain() {
            #expect(Dependencies.live(useKeychain: false).secretBackend == nil)
            #expect(Dependencies.live(useKeychain: true).secretBackend is KeychainBackend)
            let signed = defaultUseKeychain(signingFlags: currentSigningFlags())
            #expect((Dependencies.live(useKeychain: nil).secretBackend != nil) == signed)
        }

        @Test("falls back to files when the keychain throws")
        func throwingKeychain() {
            let store = SecureStore(productID: "prod-1", directories: [dirA], backend: ThrowingBackend())
            store.set(installIDKey, "secret")
            #expect(store.get(installIDKey) == "secret")
            store.delete(installIDKey)
            #expect(store.get(installIDKey) == nil)
        }

        @Test("computes OS-appropriate default locations when no dirs are given")
        func defaultLocations() {
            let home = URL(fileURLWithPath: "/Users/jane")
            let dirs = SecureStore.defaultDirectories(namespace: "abc", home: home)
            #expect(
                dirs.map(\.path) == ["/Users/jane/Library/Application Support/.abc", "/Users/jane/Library/Caches/.abc"])
            // Read-only: avoid writing into the real home directory.
            let store = SecureStore(productID: "prod-\(UUID().uuidString)", backend: nil)
            #expect(store.get(installIDKey) == nil)
            #expect(store.directories.count == 2)
        }
    }
}
