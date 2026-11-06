import Foundation

/// A failed license validation. Branch on ``code``, never on ``message``.
public struct LicenseError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    /// Error codes returned by the validate-key endpoint, plus SDK-side codes
    /// for failures that never reached a definitive server answer.
    ///
    /// The raw values are the same strings as in the Electron and Tauri SDKs.
    public enum Code: String, Sendable, Codable, CaseIterable {
        /// The key does not exist for this product.
        case notFound = "not_found"
        /// The license expiration date has passed.
        case licenseExpired = "license_expired"
        /// The license doesn't include this app version.
        case versionNotAllowed = "version_not_allowed"
        /// The license is active on its maximum number of machines.
        case machineLimitReached = "machine_limit_reached"
        /// The vendor's plan limit was reached.
        case planLimitExceeded = "plan_limit_exceeded"
        /// The request was invalid, e.g. an empty key.
        case validationError = "validation_error"
        /// The server failed.
        case internalError = "internal_error"
        /// Server unreachable, timed out, or answered with an unknown error.
        case networkError = "network_error"
        /// Server answered but its token failed verification.
        case invalidResponse = "invalid_response"

        /// True for codes that say something about the customer's license, and
        /// therefore lock the app. Every other failure is treated like the
        /// server being unreachable.
        public var isLocking: Bool {
            lockedStates[self] != nil
        }
    }

    /// What went wrong.
    public let code: Code
    /// Human-readable description, for logs. Don't branch on it.
    public let message: String
    /// HTTP status, when the server answered.
    public let status: Int?
    /// For ``Code/versionNotAllowed``: the latest version the license allows.
    public let latestAllowedVersion: LatestAllowedVersion

    /// Creates an error.
    public init(
        _ code: Code,
        _ message: String,
        status: Int? = nil,
        latestAllowedVersion: LatestAllowedVersion = .notApplicable
    ) {
        self.code = code
        self.message = message
        self.status = status
        self.latestAllowedVersion = latestAllowedVersion
    }

    /// True when the license itself was refused (the app should lock).
    public var isLocking: Bool {
        code.isLocking
    }

    public var errorDescription: String? {
        message
    }

    public var description: String {
        "LicenseError(\(code.rawValue)\(status.map { ", status \($0)" } ?? "")): \(message)"
    }
}

/// A mistake in the SDK configuration, thrown by ``LicenseManager/init(productID:publicKey:options:)``.
public enum ConfigError: Error, Sendable, Equatable, LocalizedError {
    /// `productID` is empty.
    case missingProductID
    /// `publicKey` is empty.
    case missingPublicKey
    /// `publicKey` isn't an Ed25519 public key in SPKI PEM format.
    case invalidPublicKey(String)
    /// No `version` option and the main bundle has no `CFBundleShortVersionString`.
    case missingVersion

    public var errorDescription: String? {
        switch self {
        case .missingProductID: "productID is required"
        case .missingPublicKey: "publicKey is required"
        case .invalidPublicKey(let reason): "publicKey is not an Ed25519 SPKI PEM key: \(reason)"
        case .missingVersion:
            "version is required when the main bundle has no CFBundleShortVersionString"
        }
    }
}
