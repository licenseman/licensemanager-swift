import Foundation

/// Source of the machine component of the fingerprint.
public enum MachineFingerprint: Sendable {
    /// Used verbatim (then hashed).
    case value(String)
    /// Called once; its result is used verbatim (then hashed).
    case provider(@Sendable () async -> String)
}

extension LicenseManager {
    /// Optional settings of a ``LicenseManager``.
    public struct Options: Sendable {
        /// Machine component of the fingerprint. Defaults to the Mac's hardware
        /// UUID (`IOPlatformUUID`).
        public var fingerprint: MachineFingerprint?
        /// App version, sent on validation and checked offline against the
        /// license's max version. Defaults to `CFBundleShortVersionString` of
        /// the main bundle.
        public var version: String?
        /// Machine name shown in the dashboard. Defaults to the computer name
        /// (e.g. "Jane's MacBook Pro"), else the hostname.
        public var machineName: String?
        /// Platform shown in the dashboard. Defaults to the OS name and
        /// version, e.g. `macOS 26.5.1`.
        public var platform: String?
        /// How long the app must keep working offline, in seconds. The license
        /// is re-validated at 2/3 of the token lifetime, or earlier so that at
        /// least this much validity remains, but never sooner than 1 day after
        /// the last validation.
        public var minOfflineDuration: TimeInterval
        /// Keychain service the license data is stored under, the label macOS
        /// shows when it asks the user for their password. Defaults to the
        /// app's bundle id, else `dev.licensemanager.sdk`.
        public var keychainService: String?
        /// Store license data in the keychain. When false, only the file
        /// fallback is used. Defaults to false for unsigned and ad-hoc signed
        /// builds (`swift run`, "Sign to Run Locally"), whose signature changes
        /// on every build and would trigger keychain prompts; true otherwise.
        public var useKeychain: Bool?
        /// Overrides the API origin. Intended for tests.
        public var apiBaseURL: URL?
        /// Overrides the persistence locations. Intended for tests.
        public var storageDirectories: [URL]?

        /// Creates options. Every setting has a default.
        public init(
            fingerprint: MachineFingerprint? = nil,
            version: String? = nil,
            machineName: String? = nil,
            platform: String? = nil,
            minOfflineDuration: TimeInterval = 0,
            keychainService: String? = nil,
            useKeychain: Bool? = nil,
            apiBaseURL: URL? = nil,
            storageDirectories: [URL]? = nil
        ) {
            self.fingerprint = fingerprint
            self.version = version
            self.machineName = machineName
            self.platform = platform
            self.minOfflineDuration = minOfflineDuration
            self.keychainService = keychainService
            self.useKeychain = useKeychain
            self.apiBaseURL = apiBaseURL
            self.storageDirectories = storageDirectories
        }
    }
}
