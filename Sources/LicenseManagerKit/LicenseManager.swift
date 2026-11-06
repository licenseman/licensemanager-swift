import Foundation

private let portalBaseURL = "https://app.licensemanager.dev/portal"

/// Entry point of the LicenseManager SDK for macOS apps.
///
/// Create one instance when the app starts and keep it for the app's
/// lifetime. On creation it validates the stored license key (in the
/// background when the stored token is valid) and starts an hourly
/// clock-tamper check; call ``dispose()`` to stop background work.
///
/// ```swift
/// let license = try LicenseManager(
///     productID: "x7Kp2QaZ",
///     publicKey: """
///     -----BEGIN PUBLIC KEY-----
///     MCowBQYDK2VwAyEA…
///     -----END PUBLIC KEY-----
///     """
/// )
/// switch await license.ready() {
/// case .active: showApp()
/// case .missingKey: showActivation()
/// default: showLocked()
/// }
/// ```
public final class LicenseManager: Sendable {
    private let productID: String
    private let engine: LicenseEngine
    private let clock: ClockGuard
    private let time: any TimeSource
    private let listeners = Listeners()
    private let published: Locked<Snapshot>
    private let root = CancelSignal()
    private let readyTask: Task<LicenseState, Never>

    /// Creates the license manager and starts validating the stored key.
    ///
    /// - Parameters:
    ///   - productID: Identifies the product, from the dashboard.
    ///   - publicKey: The product's Ed25519 public key (SPKI PEM), from the
    ///     dashboard, used to verify license tokens offline.
    ///   - options: Optional settings.
    /// - Throws: ``ConfigError`` when a parameter is empty or invalid, or
    ///   when there is no version option and the main bundle has none.
    public convenience init(
        productID: String,
        publicKey: String,
        options: Options = Options()
    ) throws(ConfigError) {
        try self.init(
            productID: productID,
            publicKey: publicKey,
            options: options,
            deps: .live(useKeychain: options.useKeychain)
        )
    }

    init(
        productID: String,
        publicKey: String,
        options: Options,
        deps: Dependencies,
        bundle: Bundle = .main
    ) throws(ConfigError) {
        guard !productID.isEmpty else { throw .missingProductID }
        guard !publicKey.isEmpty else { throw .missingPublicKey }
        let key = try parsePublicKey(publicKey)
        guard let version = options.version ?? appVersion(bundle) else { throw .missingVersion }

        self.productID = productID
        time = deps.time
        let store = SecureStore(
            productID: productID,
            directories: options.storageDirectories,
            service: options.keychainService ?? appBundleIdentifier(bundle),
            backend: deps.secretBackend
        )
        clock = ClockGuard(store: store, transport: deps.transport, time: deps.time, signal: root)
        let storedKey = store.get(licenseKeyKey)
        published = Locked(Snapshot(state: storedKey == nil ? .missingKey : .loading, key: storedKey))
        let engine = LicenseEngine(
            productID: productID,
            options: options,
            version: version,
            store: store,
            verifier: TokenVerifier(publicKey: key, productID: productID),
            clock: clock,
            deps: deps,
            listeners: listeners,
            published: published,
            root: root
        )
        self.engine = engine
        readyTask = Task { await engine.start() }
    }

    deinit {
        dispose()
    }

    /// Stable per-machine, per-install, per-product fingerprint: the sha256 of
    /// the machine component, mixed with a hidden random install id. Cached
    /// after the first call.
    public func fingerprint() async -> String {
        await engine.fingerprint()
    }

    /// The current license state.
    public var state: LicenseState {
        published.current.state
    }

    /// Returns the state once startup validation has completed, or as soon
    /// as the stored token is found valid; the online validation then
    /// continues in the background.
    public func ready() async -> LicenseState {
        await readyTask.value
    }

    /// Calls `listener` on every state change, until the returned
    /// subscription is cancelled or released.
    public func onStateChange(_ listener: @escaping @Sendable (LicenseState) -> Void) -> Subscription {
        let id = listeners.add(listener)
        return Subscription { [listeners] in listeners.remove(id) }
    }

    /// The current state, then every change. Finishes on ``dispose()``.
    public var states: AsyncStream<LicenseState> {
        listeners.stateStream { published.current.state }
    }

    /// Every change of the values read by the getters, for ``LicenseObserver``.
    var snapshots: AsyncStream<Snapshot> {
        listeners.snapshotStream { published.current }
    }

    /// The stored license key, or nil before one was set.
    public var licenseKey: String? {
        published.current.key
    }

    /// Link to the customer portal for this product, where customers manage
    /// their license and machines.
    public var portalURL: URL {
        URL(string: "\(portalBaseURL)/\(encodeURIComponent(productID))")!
    }

    /// In state ``LicenseState/versionNotAllowed``: the latest version the
    /// license allows, or ``LatestAllowedVersion/noneAllowed``.
    /// ``LatestAllowedVersion/notApplicable`` otherwise, and when the refusal
    /// came from the stored token while offline.
    public var latestAllowedVersion: LatestAllowedVersion {
        published.current.latestAllowedVersion
    }

    /// Whether the last validation reached the server. When offline, the app
    /// keeps running on the stored token until `validUntil`.
    public var offlineState: OfflineState {
        Self.offlineState(published.current, nowMs: time.now())
    }

    static func offlineState(_ snapshot: Snapshot, nowMs: Double) -> OfflineState {
        if snapshot.online { return .online }
        guard snapshot.state == .active, let exp = snapshot.tokenExp else {
            return .offline(validUntil: nil, remaining: 0)
        }
        let expiresAt = exp * 1000
        return .offline(
            validUntil: Date(timeIntervalSince1970: expiresAt / 1000),
            remaining: max(0, expiresAt - nowMs) / 1000
        )
    }

    /// Validates a key the user typed and, on success, stores it and
    /// activates. The key is trimmed but its case is kept.
    ///
    /// - Throws: ``LicenseError`` when validation fails for any reason,
    ///   including the server being unreachable. Nothing is stored and the
    ///   current state is left untouched.
    @discardableResult
    public func setLicenseKey(_ key: String) async throws(LicenseError) -> LicenseState {
        try await engine.setLicenseKey(key)
    }

    /// Re-validates the stored key now, e.g. after the customer renewed an
    /// expired license. Never throws.
    @discardableResult
    public func refresh() async -> LicenseState {
        await engine.refresh(ready: readyTask)
    }

    /// True once the system clock was found rolled back or far from network time.
    public var isClockTampered: Bool {
        clock.isTampered
    }

    /// Stops the clock check, scheduled re-validations and retries, and
    /// finishes ``states``. Idempotent.
    public func dispose() {
        guard !root.isAborted else { return }
        root.abort()
        listeners.finish()
        let engine = engine
        Task { await engine.dispose() }
    }

    /// A state change subscription. Cancelled when released.
    public final class Subscription: Sendable {
        private let onCancel: Locked<(@Sendable () -> Void)?>

        init(_ onCancel: @escaping @Sendable () -> Void) {
            self.onCancel = Locked(onCancel)
        }

        deinit {
            cancel()
        }

        /// Stops calling the listener.
        public func cancel() {
            let onCancel = onCancel.withLock { value in
                defer { value = nil }
                return value
            }
            onCancel?()
        }
    }
}
