import Combine
import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// Publishes a ``LicenseManager``'s state for SwiftUI views.
///
/// ```swift
/// @main
/// struct MyApp: App {
///     @StateObject private var license = LicenseObserver(manager: licenseManager)
///
///     var body: some Scene {
///         WindowGroup {
///             switch license.state {
///             case .loading: ProgressView()
///             case .active: ContentView()
///             case .missingKey: ActivationView()
///             default: LockedView()
///             }
///         }
///         .environmentObject(license)
///     }
/// }
/// ```
@MainActor
public final class LicenseObserver: ObservableObject {
    /// The observed manager.
    public let manager: LicenseManager
    /// The current license state.
    @Published public private(set) var state: LicenseState
    /// Whether the last validation reached the server.
    @Published public private(set) var offlineState: OfflineState
    /// See ``LicenseManager/latestAllowedVersion``.
    @Published public private(set) var latestAllowedVersion: LatestAllowedVersion
    /// The last 5 characters of the stored key, to show which key is in use
    /// without displaying all of it.
    @Published public private(set) var licenseKeyHint: String?

    private var task: Task<Void, Never>?

    /// Starts observing `manager`.
    public init(manager: LicenseManager) {
        self.manager = manager
        state = manager.state
        offlineState = manager.offlineState
        latestAllowedVersion = manager.latestAllowedVersion
        licenseKeyHint = manager.licenseKey.map { String($0.suffix(5)) }
        let snapshots = manager.snapshots
        task = Task { [weak self] in
            for await snapshot in snapshots {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    deinit {
        task?.cancel()
    }

    private func apply(_ snapshot: Snapshot) {
        if state != snapshot.state { state = snapshot.state }
        let offline = manager.offlineState
        if offlineState != offline { offlineState = offline }
        if latestAllowedVersion != snapshot.latestAllowedVersion {
            latestAllowedVersion = snapshot.latestAllowedVersion
        }
        let hint = snapshot.key.map { String($0.suffix(5)) }
        if licenseKeyHint != hint { licenseKeyHint = hint }
    }

    /// Link to the customer portal. See ``LicenseManager/portalURL``.
    public var portalURL: URL {
        manager.portalURL
    }

    /// Validates and stores a key the user typed. See ``LicenseManager/setLicenseKey(_:)``.
    @discardableResult
    public func activate(key: String) async throws(LicenseError) -> LicenseState {
        try await manager.setLicenseKey(key)
    }

    /// Re-validates the stored key now. See ``LicenseManager/refresh()``.
    public func refresh() async {
        await manager.refresh()
    }

    #if canImport(AppKit)
        /// Opens the customer portal in the default browser.
        public func openPortal() {
            NSWorkspace.shared.open(portalURL)
        }
    #endif
}
