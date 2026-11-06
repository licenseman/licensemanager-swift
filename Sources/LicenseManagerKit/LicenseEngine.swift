import Foundation

let installIDKey = "installId"
let licenseKeyKey = "licenseKey"
let licenseTokenKey = "licenseToken"

private let minute: Double = 60 * 1000
/// Retry backoff between scheduled re-validations while the server is unreachable.
private let retryInitialMs = 5 * minute
private let retryMaxMs = 60 * minute
/// Longest single timer. Longer waits are re-armed in steps, re-checking the
/// wall clock each time, so system sleep or clock changes can't push a
/// validation far past its target date.
let maxTimerStepMs = 60 * minute

/// Everything the engine talks to. Live in apps, fakes in tests.
struct Dependencies: Sendable {
    var transport: any HTTPTransport = URLSessionTransport()
    var time: any TimeSource = LiveTime()
    /// Nil keeps only the file fallback.
    var secretBackend: (any SecretBackend)? = KeychainBackend()
    var machineIDSources = MachineIDSources()
    var machineName: @Sendable () -> String = { defaultMachineName() }

    /// The real thing; without a keychain when `useKeychain` (or its default) is false.
    static func live(useKeychain: Bool?) -> Dependencies {
        var deps = Dependencies()
        if !(useKeychain ?? defaultUseKeychain(signingFlags: currentSigningFlags())) {
            deps.secretBackend = nil
        }
        return deps
    }
}

/// What the synchronous getters of ``LicenseManager`` read.
struct Snapshot: Sendable, Equatable {
    var state: LicenseState
    var key: String?
    var online = true
    var tokenExp: Double?
    var latestAllowedVersion = LatestAllowedVersion.notApplicable
}

/// Listeners and streams, registered synchronously from any thread.
final class Listeners: Sendable {
    private struct State {
        var nextID = 0
        var state: [Int: @Sendable (LicenseState) -> Void] = [:]
        var streams: [Int: AsyncStream<LicenseState>.Continuation] = [:]
        var snapshots: [Int: AsyncStream<Snapshot>.Continuation] = [:]
        var finished = false
    }

    private let registry = Locked(State())

    func add(_ listener: @escaping @Sendable (LicenseState) -> Void) -> Int {
        registry.withLock { registry in
            registry.nextID += 1
            registry.state[registry.nextID] = listener
            return registry.nextID
        }
    }

    func remove(_ id: Int) {
        registry.withLock { registry in
            registry.state[id] = nil
            registry.streams[id] = nil
            registry.snapshots[id] = nil
        }
    }

    func stateStream(current: () -> LicenseState) -> AsyncStream<LicenseState> {
        let (stream, continuation) = AsyncStream<LicenseState>.makeStream(bufferingPolicy: .unbounded)
        registry.withLock { registry in
            continuation.yield(current())
            if registry.finished {
                continuation.finish()
                return
            }
            registry.nextID += 1
            let id = registry.nextID
            registry.streams[id] = continuation
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
        return stream
    }

    func snapshotStream(current: () -> Snapshot) -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        registry.withLock { registry in
            continuation.yield(current())
            if registry.finished {
                continuation.finish()
                return
            }
            registry.nextID += 1
            let id = registry.nextID
            registry.snapshots[id] = continuation
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
        return stream
    }

    func notify(_ state: LicenseState) {
        let (listeners, streams) = registry.withLock { registry in
            (registry.state.sorted { $0.key < $1.key }.map(\.value), Array(registry.streams.values))
        }
        for stream in streams { stream.yield(state) }
        for listener in listeners { listener(state) }
    }

    func notify(_ snapshot: Snapshot) {
        for stream in registry.withLock({ Array($0.snapshots.values) }) {
            stream.yield(snapshot)
        }
    }

    func finish() {
        let (streams, snapshots) = registry.withLock { registry in
            registry.finished = true
            defer {
                registry.streams = [:]
                registry.snapshots = [:]
            }
            return (Array(registry.streams.values), Array(registry.snapshots.values))
        }
        streams.forEach { $0.finish() }
        snapshots.forEach { $0.finish() }
    }
}

/// Port of the private side of the Electron SDK's `LicenseManager`. The actor
/// serializes work like the JavaScript event loop: state can only change
/// between `await`s, where the guards on the key mirror the Electron ones.
actor LicenseEngine {
    private let productID: String
    private let fingerprintOption: MachineFingerprint?
    private let version: String
    private let platform: String
    private let minOfflineMs: Double
    private let apiBaseURL: String
    private let store: SecureStore
    private let verifier: TokenVerifier
    private let clock: ClockGuard
    private let deps: Dependencies
    private let listeners: Listeners
    private let published: Locked<Snapshot>
    /// Aborted on dispose, to stop pending retries, timers and the clock loop.
    private let root: CancelSignal

    private var machineName: String?
    private var machineNameLookup: Task<String, Never>?
    private var cachedFingerprint: String?
    private var key: String? { didSet { publish() } }
    private var state: LicenseState { didSet { publish() } }
    /// Payload of the current valid token.
    private var token: TokenPayload? { didSet { publish() } }
    /// False once a request failed to reach a definitive server answer.
    private var online = true { didSet { publish() } }
    private var latestAllowedVersion = LatestAllowedVersion.notApplicable { didSet { publish() } }
    private var retryDelayMs = retryInitialMs
    private var timer: CancelSignal?
    private var inflight: (id: Int, key: String, policy: RetryPolicy, task: Task<ValidatedToken, any Error>)?
    private var nextInflightID = 0

    init(
        productID: String,
        options: LicenseManager.Options,
        version: String,
        store: SecureStore,
        verifier: TokenVerifier,
        clock: ClockGuard,
        deps: Dependencies,
        listeners: Listeners,
        published: Locked<Snapshot>,
        root: CancelSignal
    ) {
        self.productID = productID
        fingerprintOption = options.fingerprint
        self.version = version
        machineName = options.machineName
        platform = options.platform ?? defaultPlatform()
        minOfflineMs = max(0, options.minOfflineDuration * 1000)
        var base = options.apiBaseURL?.absoluteString ?? defaultAPIBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        apiBaseURL = base
        self.store = store
        self.verifier = verifier
        self.clock = clock
        self.deps = deps
        self.listeners = listeners
        self.published = published
        self.root = root
        let snapshot = published.current
        key = snapshot.key
        state = snapshot.state
    }

    private var disposed: Bool {
        root.isAborted
    }

    // MARK: Public operations

    func fingerprint() async -> String {
        if let cachedFingerprint { return cachedFingerprint }
        let machine = await resolveMachineFingerprint(fingerprintOption, sources: deps.machineIDSources)
        if let cachedFingerprint { return cachedFingerprint }
        let fingerprint = "\(machine):\(getOrCreateInstallID()):\(productID)"
        cachedFingerprint = fingerprint
        return fingerprint
    }

    func setLicenseKey(_ input: String) async throws(LicenseError) -> LicenseState {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw LicenseError(.validationError, "The license key is empty")
        }
        let validated = try await request(key, .interactive)
        store.set(licenseKeyKey, key)
        self.key = key
        activate(validated)
        return state
    }

    func refresh(ready: Task<LicenseState, Never>) async -> LicenseState {
        _ = await ready.value
        guard let key else { return state }
        return await revalidate(key, .interactive)
    }

    func dispose() {
        clearTimer()
    }

    // MARK: State machine

    func start() async -> LicenseState {
        guard let key else {
            setState(.missingKey)
            return state
        }
        let stored = await checkStoredToken(key)
        guard self.key == key else { return state }
        guard case .active(let payload) = stored else {
            return await revalidate(key, .interactive)
        }
        token = payload
        setState(.active)
        // Confirm with the server without holding up startup.
        Task { _ = await self.revalidate(key, .background) }
        return state
    }

    /// Validates online; on an error that says nothing about the license,
    /// falls back to the stored token. Never throws.
    private func revalidate(_ key: String, _ policy: RetryPolicy) async -> LicenseState {
        clearTimer()
        do {
            let validated = try await request(key, policy)
            guard self.key == key else { return state }
            activate(validated)
        } catch {
            guard self.key == key else { return state }
            if error.isLocking {
                lock(error.code, error.latestAllowedVersion)
            } else {
                await validateOffline(key)
            }
        }
        return state
    }

    /// Stores a freshly validated token and schedules its refresh.
    private func activate(_ validated: ValidatedToken) {
        store.set(licenseTokenKey, validated.token)
        token = validated.payload
        online = true
        retryDelayMs = retryInitialMs
        latestAllowedVersion = .notApplicable
        setState(.active)
        scheduleNext()
    }

    /// The server refused the license: drops the token and stops refreshing.
    private func lock(_ code: LicenseError.Code, _ latest: LatestAllowedVersion) {
        store.delete(licenseTokenKey)
        token = nil
        online = true
        latestAllowedVersion = code == .versionNotAllowed ? normalizeLatest(latest) : .notApplicable
        setState(lockedStates[code] ?? .invalidKey)
    }

    private func normalizeLatest(_ latest: LatestAllowedVersion) -> LatestAllowedVersion {
        if case .notApplicable = latest { return .noneAllowed }
        return latest
    }

    /// Server unreachable: trusts the stored token, unless the clock was rolled
    /// back or the token's max version excludes this app version.
    private func validateOffline(_ key: String) async {
        online = false
        let stored = await checkStoredToken(key)
        guard self.key == key else { return }
        if case .active(let payload) = stored {
            token = payload
        } else {
            token = nil
        }
        if case .refused(.versionNotAllowed) = stored {
            latestAllowedVersion = .notApplicable
        }
        setState(stored.state)
        scheduleNext()
        retryDelayMs = min(retryDelayMs * 2, retryMaxMs)
    }

    private enum StoredToken {
        case active(TokenPayload)
        case refused(LicenseState)

        var state: LicenseState {
            switch self {
            case .active: .active
            case .refused(let state): state
            }
        }
    }

    /// What the stored token allows without asking the server.
    private func checkStoredToken(_ key: String) async -> StoredToken {
        await clock.ready.value
        if clock.isTampered { return .refused(.clockTampered) }
        guard let stored = store.get(licenseTokenKey) else { return .refused(.offlineExpired) }
        let payload: TokenPayload
        do {
            payload = try await verifier.verify(stored, key: key, nowMs: deps.time.now()) {
                await self.fingerprint()
            }
        } catch {
            return .refused(.offlineExpired)
        }
        // Keep the token: it works again if the app is downgraded.
        if !isVersionAllowed(version, maxVersion: payload.mv) { return .refused(.versionNotAllowed) }
        return .active(payload)
    }

    // MARK: Scheduling

    /// Arms the next re-validation: at the refresh point when online; when
    /// offline, retries with backoff but never later than the token expiry.
    private func scheduleNext() {
        clearTimer()
        guard !disposed, let key else { return }
        let now = deps.time.now()
        var at: Double
        if state == .active, let token {
            at = computeRefreshAt(iat: token.iat, exp: token.exp, minOfflineMs: minOfflineMs)
            if !online { at = max(at, now + retryDelayMs) }
            at = min(at, token.exp * 1000)
        } else if state == .offlineExpired || state == .clockTampered
            // Refused by the stored token: the server has the final word.
            || (state == .versionNotAllowed && !online)
        {
            at = now + retryDelayMs
        } else {
            return
        }
        arm(key, at)
    }

    private func arm(_ key: String, _ at: Double) {
        let signal = CancelSignal(parent: root)
        timer = signal
        let delay = min(max(0, at - deps.time.now()), maxTimerStepMs)
        let time = deps.time
        Task {
            guard await time.sleep(ms: delay, signal: signal) else { return }
            await self.timerFired(key, at, signal)
        }
    }

    private func timerFired(_ key: String, _ at: Double, _ signal: CancelSignal) async {
        guard timer === signal, !signal.isAborted else { return }
        timer = nil
        if deps.time.now() < at {
            arm(key, at)
        } else {
            _ = await revalidate(key, .background)
        }
    }

    private func clearTimer() {
        timer?.abort()
        timer = nil
    }

    // MARK: Requests

    /// Calls validate-key, sharing one in-flight request per key and policy,
    /// so a caller is never held up by a longer background retry budget.
    private func request(_ key: String, _ policy: RetryPolicy) async throws(LicenseError) -> ValidatedToken {
        let task: Task<ValidatedToken, any Error>
        if let inflight, inflight.key == key, inflight.policy == policy {
            task = inflight.task
        } else {
            nextInflightID += 1
            let id = nextInflightID
            task = Task {
                do {
                    let validated = try await self.fetchToken(key, policy)
                    self.clearInflight(id)
                    return validated
                } catch {
                    self.clearInflight(id)
                    throw error
                }
            }
            inflight = (id, key, policy, task)
        }
        do {
            return try await task.value
        } catch let error as LicenseError {
            throw error
        } catch {
            throw LicenseError(.networkError, "Validation failed")
        }
    }

    private func clearInflight(_ id: Int) {
        if inflight?.id == id { inflight = nil }
    }

    /// Looks up the default machine name once, sharing concurrent lookups.
    private func lookupMachineName() async -> String {
        if let machineName { return machineName }
        let lookup = machineNameLookup ?? Task.detached { [deps] in deps.machineName() }
        machineNameLookup = lookup
        let name = await lookup.value
        machineName = name
        return name
    }

    private func fetchToken(_ key: String, _ policy: RetryPolicy) async throws(LicenseError) -> ValidatedToken {
        let body = ValidateKeyRequest(
            key: key,
            fingerprint: await fingerprint(),
            version: version,
            name: await lookupMachineName(),
            platform: platform
        )
        let (transport, apiBaseURL, productID) = (deps.transport, apiBaseURL, productID)
        let (token, status) = try await withRetry(
            time: deps.time,
            policy: policy,
            signal: root,
            isRetryable: isTransientError
        ) { (remainingMs) async throws(LicenseError) in
            try await postValidateKey(
                transport: transport,
                apiBaseURL: apiBaseURL,
                productID: productID,
                request: body,
                timeoutMs: remainingMs
            )
        }
        do {
            let payload = try await verifier.verify(token, key: key, nowMs: deps.time.now()) {
                await self.fingerprint()
            }
            return ValidatedToken(token: token, payload: payload)
        } catch {
            throw LicenseError(.invalidResponse, "The license token failed verification", status: status)
        }
    }

    // MARK: Helpers

    private func setState(_ newState: LicenseState) {
        guard newState != state else { return }
        state = newState
        listeners.notify(newState)
    }

    private func publish() {
        let snapshot = Snapshot(
            state: state,
            key: key,
            online: online,
            tokenExp: token?.exp,
            latestAllowedVersion: latestAllowedVersion
        )
        let changed = published.withLock { current in
            defer { current = snapshot }
            return current != snapshot
        }
        if changed { listeners.notify(snapshot) }
    }

    private func getOrCreateInstallID() -> String {
        if let existing = store.get(installIDKey) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        let created = Data(bytes).base64EncodedString()
        store.set(installIDKey, created)
        return created
    }
}
