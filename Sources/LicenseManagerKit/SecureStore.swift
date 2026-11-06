import CryptoKit
import Foundation
import Security

/// Default keychain service when the app has no bundle id, and the salt of the
/// per-product file namespace (kept stable so fallback files never move).
let defaultKeychainService = "dev.licensemanager.sdk"

/// An OS secret store. Injected in tests.
protocol SecretBackend: Sendable {
    func get(service: String, account: String) throws -> String?
    func set(service: String, account: String, value: String) throws
    func delete(service: String, account: String) throws
}

struct KeychainError: Error {
    let status: OSStatus
}

/// Generic passwords in the login keychain: the same items as the Electron
/// SDK (`@napi-rs/keyring`) and the Tauri SDK (`keyring`) create.
///
/// The file-based keychain is used on purpose (no
/// `kSecUseDataProtectionKeychain`): it is the one the other SDKs write to.
struct KeychainBackend: SecretBackend {
    private func query(_ service: String, _ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func get(service: String, account: String) throws -> String? {
        var query = query(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func set(service: String, account: String, value: String) throws {
        let data = Data(value.utf8)
        let query = query(service, account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// Per-product persistence for small secret strings (install id, last-seen
/// timestamp, license key and token).
///
/// Primary backend is the keychain. Values are also mirrored to redundant,
/// non-obvious files, so they survive when the keychain is unavailable or
/// refuses access. Every entry is namespaced by product id, so several apps
/// using the SDK never read or overwrite each other's values.
final class SecureStore: Sendable {
    let productID: String
    let service: String
    let directories: [URL]
    private let backend: (any SecretBackend)?

    init(
        productID: String,
        directories: [URL]? = nil,
        service: String? = nil,
        backend: (any SecretBackend)? = KeychainBackend()
    ) {
        self.productID = productID
        self.service = (service?.isEmpty ?? true) ? defaultKeychainService : service!
        self.backend = backend
        self.directories = directories ?? Self.defaultDirectories(namespace: Self.namespace(productID: productID))
    }

    /// GUID-looking per-product id with no "license" marker.
    static func namespace(productID: String) -> String {
        String(hexSHA256("\(defaultKeychainService):\(productID)").prefix(32))
    }

    /// Obscure, stable file name per key (no readable marker).
    static func fileName(key: String) -> String {
        "\(hexSHA256(key).prefix(24)).dat"
    }

    static func defaultDirectories(
        namespace: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let hidden = ".\(namespace)"
        return [
            home.appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent(hidden, isDirectory: true),
            home.appendingPathComponent("Library/Caches", isDirectory: true)
                .appendingPathComponent(hidden, isDirectory: true),
        ]
    }

    func get(_ key: String) -> String? {
        if let value = keychainGet(key) { return value }
        let fromFile = fileGet(key)
        // Backfill the keychain, e.g. after the service name changed.
        if let fromFile { keychainSet(key, fromFile) }
        return fromFile
    }

    func set(_ key: String, _ value: String) {
        keychainSet(key, value)
        for directory in directories {
            let url = directory.appendingPathComponent(Self.fileName(key: key))
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    try Data(value.utf8).write(to: url)
                } else {
                    FileManager.default.createFile(
                        atPath: url.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]
                    )
                }
            } catch {
                // best effort per location
            }
        }
    }

    func delete(_ key: String) {
        if let backend {
            try? backend.delete(service: service, account: account(key))
        }
        for directory in directories {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.fileName(key: key)))
        }
    }

    private func account(_ key: String) -> String {
        "\(productID):\(key)"
    }

    private func keychainGet(_ key: String) -> String? {
        guard let backend else { return nil }
        return (try? backend.get(service: service, account: account(key))) ?? nil
    }

    private func keychainSet(_ key: String, _ value: String) {
        try? backend?.set(service: service, account: account(key), value: value)
    }

    private func fileGet(_ key: String) -> String? {
        for directory in directories {
            let url = directory.appendingPathComponent(Self.fileName(key: key))
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return nil
    }
}

func hexSHA256(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}
