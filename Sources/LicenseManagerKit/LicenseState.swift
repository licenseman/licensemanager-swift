import Foundation

/// The license state of the app. Gate features on ``active``.
///
/// The raw values are the same strings as in the Electron and Tauri SDKs.
public enum LicenseState: String, Sendable, Codable, CaseIterable {
    /// Startup validation in progress.
    case loading = "LOADING"
    /// No license key stored yet: ask the user for one.
    case missingKey = "MISSING_KEY"
    /// Valid license, verified online or with the stored token.
    case active = "ACTIVE"
    /// The key does not exist for this product.
    case invalidKey = "INVALID_KEY"
    /// The license expiration date has passed.
    case expired = "EXPIRED"
    /// The license doesn't include this app version. See ``LicenseManager/latestAllowedVersion``.
    case versionNotAllowed = "VERSION_NOT_ALLOWED"
    /// The license is active on its maximum number of machines.
    case machineLimitReached = "MACHINE_LIMIT_REACHED"
    /// Server unreachable and no valid stored token.
    case offlineExpired = "OFFLINE_EXPIRED"
    /// Server unreachable and the system clock was rolled back.
    case clockTampered = "CLOCK_TAMPERED"
}

/// Whether the last validation reached the license server.
public enum OfflineState: Sendable, Equatable {
    /// The last validation got a definitive answer from the server.
    case online
    /// The server couldn't be reached: the app runs on the stored token.
    ///
    /// - Parameters:
    ///   - validUntil: Expiry of the stored token, or nil when there is no valid token.
    ///   - remaining: Time left before `validUntil`, in seconds; 0 without a valid token.
    case offline(validUntil: Date?, remaining: TimeInterval)
}

/// In state ``LicenseState/versionNotAllowed``: the latest version the license allows.
public enum LatestAllowedVersion: Sendable, Equatable {
    /// Not in state ``LicenseState/versionNotAllowed``, or the refusal came from
    /// the stored token while offline (it only knows the max version, not the
    /// latest release).
    case notApplicable
    /// The license allows no released version.
    case noneAllowed
    /// The latest version the license allows, e.g. `2.3.1`.
    case version(String)
}

/// State the app locks into when the server refuses the license.
let lockedStates: [LicenseError.Code: LicenseState] = [
    .notFound: .invalidKey,
    .licenseExpired: .expired,
    .versionNotAllowed: .versionNotAllowed,
    .machineLimitReached: .machineLimitReached,
]
