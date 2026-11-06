# macOS (Swift) SDK: specification

Feature-equivalent port of `@licenseman/electron` (v1.3.0, `~/projects/licensemanager-electron`) to native macOS apps written in Swift (SwiftUI or AppKit). When this spec and the Electron code disagree on a behavior not listed under [intentional differences](#3-intentional-differences), **the Electron code wins**: read the matching file before changing a module.

## 1. Goals and non-goals

Goals:
- Same features and behavior as the Electron SDK 1.3.0: one license state, validation on every launch, offline tokens, background renewal with backoff, the same error codes, clock tampering detection, machine fingerprint, keychain storage with a file fallback and backfill, configurable keychain service, customer portal link, OS version and computer name sent to the dashboard.
- Idiomatic Swift 6: strict concurrency, `async`/`await`, typed throws, `Sendable` types, DocC documentation on every public symbol.
- A SwiftUI-friendly layer (`LicenseObserver`, an `ObservableObject`), usable from AppKit too. No drop-in views: the example app shows the screens.
- Works in sandboxed (Mac App Store style) and non-sandboxed (direct download, notarized) apps.
- Byte-compatible storage and fingerprint with the Electron and Tauri SDKs for non-sandboxed apps, so an app moving from Electron or Tauri to Swift keeps its activations and its machine slot.
- Zero third-party dependencies: CryptoKit (Ed25519), Foundation (`URLSession`, JSON), Security (keychain, code signature), IOKit (machine id), SystemConfiguration (computer name).
- Same engineering standard as the other SDK repos: CI on every PR, ≥ 80% line coverage, Changesets PR flow, automatic release on merge.

Non-goals for 1.0:
- iOS, iPadOS, watchOS, tvOS, visionOS (no stable machine id comparable to desktop; needs its own spec). The package declares `.macOS(.v13)` only.
- Mac Catalyst.
- Ready-made SwiftUI views (activation window, locked screen).
- CocoaPods or Carthage. SwiftPM only (Xcode "Add Package Dependencies…").
- Any change to the API: the SDK only calls `POST /v1/products/{productId}/validate-key`, like the Electron SDK.

## 2. Deliverables

| | Name | Path | Distribution |
| --- | --- | --- | --- |
| Swift package | `licensemanager-swift`, library product and module `LicenseManagerKit` | repo root (`Package.swift`, `Sources/`) | git tags (SwiftPM), listed on the Swift Package Index |
| Example app | `LicenseManagerExample` (not a product) | `Examples/LicenseManagerExample` | |
| API docs | DocC catalog | `Sources/LicenseManagerKit/LicenseManagerKit.docc` | built and hosted by the Swift Package Index (`.spi.yml`) |

Repo: `github.com/licenseman/licensemanager-swift`, MIT.

**Why `LicenseManagerKit` and not `LicenseManager`.** The main type is `LicenseManager`. A module with the same name as one of its types (or a type named like the module) breaks qualified lookup in Swift (`LicenseManager.LicenseState` resolves to the type, not the module), a long-standing compiler limitation. The `Kit` suffix is the Apple convention for frameworks.

**Why it isn't generated.** The SDKs in `licensemanager/packages/sdks` are generated from the OpenAPI spec for backends calling the API with an `lm_` key. This package is the Swift version of `@licenseman/electron`: a client-side state machine calling one endpoint without an API key. It calls that endpoint by hand (`LicenseAPI.swift` ports `license-api.ts`), so the error mapping, timeout and retry rules can be reviewed line by line against Electron.

### Repository layout

```
licensemanager-swift/
├── Package.swift                         # swift-tools-version 6.0, .macOS(.v13), library LicenseManagerKit
├── Sources/LicenseManagerKit/
│   ├── LicenseManager.swift              # public facade (license-manager.ts public API)
│   ├── LicenseEngine.swift               # actor with the state machine (license-manager.ts private methods)
│   ├── Options.swift                     # LicenseManager.Options, MachineFingerprint, ConfigError
│   ├── LicenseState.swift                # LicenseState, OfflineState, LatestAllowedVersion, lockedStates (license-state.ts)
│   ├── LicenseError.swift                # LicenseError, LicenseError.Code (license-errors.ts)
│   ├── LicenseAPI.swift                  # validate-key client, isTransient (license-api.ts)
│   ├── LicenseToken.swift                # TokenVerifier (JWS + Ed25519), computeRefreshAt (license-token.ts)
│   ├── Retry.swift                       # withRetry, RetryPolicy (retry.ts)
│   ├── ClockGuard.swift                  # ClockGuard (clock.ts)
│   ├── Fingerprint.swift                 # machine id, hashMachineValue (fingerprint.ts)
│   ├── SecureStore.swift                 # SecureStore, SecretBackend, KeychainBackend (secure-store.ts)
│   ├── Environment.swift                 # defaultPlatform, defaultMachineName, bundle id, version, signing (environment.ts)
│   ├── Version.swift                     # isVersionAllowed (version.ts)
│   ├── SDKInfo.swift                     # sdkName, sdkVersion (written by scripts/sync-version.mjs)
│   ├── Runtime.swift                     # TimeSource, CancelSignal, HTTPTransport (+ live implementations)
│   ├── LicenseObserver.swift             # SwiftUI ObservableObject
│   └── LicenseManagerKit.docc/           # DocC: landing page + articles
├── Tests/LicenseManagerKitTests/         # Swift Testing; one file per Electron test file + compat + keychain
│   └── Support/                          # FakeTime, FakeTransport, MemoryBackend, token signing helpers
├── Examples/LicenseManagerExample/       # SwiftUI app (own Package.swift, depends on ../..)
├── scripts/
│   ├── sync-version.mjs                  # package.json version → SDKInfo.swift (11.3)
│   └── compat/electron-store.mjs         # cross-SDK test with @licenseman/electron (10.5)
├── .github/workflows/{ci.yml,release.yml}
├── .github/dependabot.yml
├── .changeset/{config.json,README.md}
├── package.json                          # private; tooling only (changesets)
├── pnpm-lock.yaml, pnpm-workspace.yaml, .nvmrc (24)
├── .swift-format
├── .spi.yml
├── CHANGELOG.md                          # written by Changesets
├── LICENSE
└── README.md
```

## 3. Intentional differences

Everything else must match the Electron SDK 1.3.0.

| Electron | Swift | Why |
| --- | --- | --- |
| Empty `productId`/`publicKey` throw a plain `Error`; an invalid `publicKey` fails at first verification. | `LicenseManager.init` throws `ConfigError` (`.missingProductID`, `.missingPublicKey`, `.invalidPublicKey`, `.missingVersion`). | A wrong key is a developer error: fail at startup, not in the field. |
| `version` defaults to `app.getVersion()`; outside Electron, a missing version throws on first request. | Defaults to `CFBundleShortVersionString` of `Bundle.main`; none and no option: `ConfigError.missingVersion` at init. | No Electron to ask. |
| `useKeychain` defaults to `app.isPackaged`. | Defaults to true unless the running app is unsigned or ad-hoc signed (`SecCodeCopySigningInformation`, flag `kSecCodeSignatureAdhoc`), e.g. `swift run` or "Sign to Run Locally". | Same intent: development builds whose signature changes on every build never trigger keychain prompts. |
| `keychainService` defaults to `CFBundleIdentifier` read from `<exe>/../../Info.plist`. | `Bundle.main.bundleIdentifier`, else `dev.licensemanager.sdk`. | Same value, native API. |
| Machine id: runs `ioreg -rd1 -c IOPlatformExpertDevice`. | Reads `IOPlatformUUID` from `IOPlatformExpertDevice` with IOKit, lowercased. | Same string; spawning processes is forbidden in the App Sandbox. |
| Machine name: runs `scutil --get ComputerName`. | `SCDynamicStoreCopyComputerName`, else `Host.current().localizedName`, else `gethostname`. | Same value, no process. |
| Platform: reads `ProductVersion` from `SystemVersion.plist`. | Same plist, else `ProcessInfo.operatingSystemVersion` (`major.minor[.patch]`). | Same value. |
| Getters: `getState()`, `getLicenseKey()`, `getPortalUrl()`… | Properties: `state`, `licenseKey`, `portalURL` (`URL`), `latestAllowedVersion`, `offlineState`, `isClockTampered`. Methods: `ready()`, `setLicenseKey(_:)`, `refresh()`, `fingerprint()`, `dispose()`. | Swift API Design Guidelines. |
| `getLatestAllowedVersion()` returns `string \| null \| undefined`. | `LatestAllowedVersion` enum: `.notApplicable`, `.noneAllowed`, `.version(String)`. | No `undefined` in Swift. |
| `getOfflineState()` → `{ mode, validUntil, remainingMs }`. | `OfflineState`: `.online`, `.offline(validUntil: Date?, remaining: TimeInterval)`. | Idiomatic. |
| `minOfflineDurationMs` (ms). | `minOfflineDuration: TimeInterval` (seconds). | Apple convention. |
| `onStateChange(fn)` returns an unsubscribe function; listener exceptions are swallowed. | `onStateChange(_:)` returns a `LicenseManager.Subscription` (call `cancel()`, or let it deinit); `states` is an `AsyncStream<LicenseState>` that yields the current state, then every change. Listeners can't throw. | Idiomatic; no exceptions to swallow in Swift. |
| `setLicenseKey` throws `LicenseError`. | `throws(LicenseError)` (typed throws). | Exhaustive `catch` without casting. |
| | `LicenseObserver` (`@MainActor`, `ObservableObject`) publishes `state`, `offlineState`, `latestAllowedVersion`, `licenseKeyHint`, and wraps `activate(key:)`, `refresh()`, `openPortal()`. | SwiftUI apps. |
| Storage directories use `os.homedir()`. | `FileManager.default.homeDirectoryForCurrentUser`, which is the app container in a sandboxed app. | A sandboxed app can't write outside its container. Electron compatibility of the files therefore only holds for non-sandboxed apps; the keychain items still match. |

## 4. Compatibility contract with the Electron and Tauri SDKs

The same product on the same Mac must read the same stored values and compute the same fingerprint, whichever SDK runs. Constants and formats, all copied from the Electron code:

| Item | Value |
| --- | --- |
| Keychain item | Generic password (`kSecClassGenericPassword`) in the login (file-based) keychain: never set `kSecUseDataProtectionKeychain`. Same item class and attributes as `@napi-rs/keyring` / `apple-native-keyring-store` (`SecKeychainAddGenericPassword`). |
| Keychain service | `keychainService` option, else the bundle id, else `dev.licensemanager.sdk` |
| Keychain account | `{productId}:{key}` where key is `installId`, `licenseKey`, `licenseToken` or `lastSeen` |
| Keychain value | UTF-8 bytes of the string |
| File namespace | `hex(sha256("dev.licensemanager.sdk:" + productId))[0..32]` (always the fixed string, even with a custom `keychainService`) |
| File name | `hex(sha256(key))[0..24] + ".dat"`, mode `0o600` |
| File dirs | `~/Library/Application Support/.{ns}`, `~/Library/Caches/.{ns}` |
| Install id | 32 random bytes (`SecRandomCopyBytes`), standard base64 with padding |
| Machine component | `base64(sha256(raw machine id))`, standard base64 with padding |
| Fingerprint | `{machine}:{installId}:{productId}` |
| `lastSeen` value | standard base64 of the decimal milliseconds string |

Golden vectors (same as `tauri-specs.md` §4), hard-coded in the tests:

| Input | Output |
| --- | --- |
| namespace for productId `x7Kp2QaZ` | `ea8ac6eca49d93514868857bb07922b4` |
| file name for `installId` | `ca8a5f3f684e28ccf496a00b.dat` |
| file name for `licenseKey` | `4d7f38bbfba5e53684683337.dat` |
| file name for `licenseToken` | `110af1ca6fb7b596b2a37cc3.dat` |
| file name for `lastSeen` | `758c78e59ed6d3a1649c33a8.dat` |
| machine hash of `4c4c4544-0042-3510-8051-b4c04f4b4e32` | `WDpaNFX/NZW0yp1UEWsHi36rKjpX4d0zVnasSsrpJOA=` |
| `lastSeen` encoding of `1767225600000` (2026-01-01T00:00:00Z) | `MTc2NzIyNTYwMDAwMA==` |

Known limits, documented on the migration docs page:
- A keychain item created by the Electron or Tauri app is owned by that app's code signature: the Swift app gets a one-time "allow access" prompt. If the user denies it, the file fallback still holds the values (non-sandboxed apps).
- Electron ≥ 1.2 uses the bundle id as keychain service, Electron 1.1 and Tauri use `dev.licensemanager.sdk`. Set `keychainService` to the previous app's value when the bundle id changes; otherwise the files backfill the new service.
- Sandboxed apps only see files in their container, so a move from a non-sandboxed Electron app to a sandboxed Swift app relies on the keychain alone.
- The MAC address fallback (only when IOKit returns no UUID) mimics libuv's interface order; rare, accepted.

## 5. Swift API

Every public symbol has DocC documentation. Module `LicenseManagerKit`.

```swift
public final class LicenseManager: Sendable {
    public static let sdkName = "licensemanager-swift"
    public static let sdkVersion: String            // written by scripts/sync-version.mjs

    public init(productID: String, publicKey: String, options: Options = Options()) throws(ConfigError)

    public var state: LicenseState { get }
    public func ready() async -> LicenseState
    public func onStateChange(_ listener: @escaping @Sendable (LicenseState) -> Void) -> Subscription
    public var states: AsyncStream<LicenseState> { get }

    public func setLicenseKey(_ key: String) async throws(LicenseError) -> LicenseState
    public func refresh() async -> LicenseState

    public var licenseKey: String? { get }
    public var portalURL: URL { get }
    public var latestAllowedVersion: LatestAllowedVersion { get }
    public var offlineState: OfflineState { get }
    public func fingerprint() async -> String
    public var isClockTampered: Bool { get }
    public func dispose()

    public struct Options: Sendable {
        public var fingerprint: MachineFingerprint?   // default: IOPlatformUUID
        public var version: String?                   // default: CFBundleShortVersionString
        public var machineName: String?               // default: computer name
        public var platform: String?                  // default: "macOS 26.5.1"
        public var minOfflineDuration: TimeInterval   // default: 0
        public var keychainService: String?           // default: bundle id, else dev.licensemanager.sdk
        public var useKeychain: Bool?                 // default: false when unsigned/ad-hoc signed, else true
        public var apiBaseURL: URL?                   // tests; trailing slashes trimmed
        public var storageDirectories: [URL]?         // tests
        public init(...)                              // memberwise, every parameter defaulted
    }

    public final class Subscription: Sendable { public func cancel() }   // also cancels on deinit
}

public enum MachineFingerprint: Sendable {
    case value(String)
    case provider(@Sendable () async -> String)
}

public enum LicenseState: String, Sendable, Codable, CaseIterable {
    case loading = "LOADING", missingKey = "MISSING_KEY", active = "ACTIVE", invalidKey = "INVALID_KEY",
         expired = "EXPIRED", versionNotAllowed = "VERSION_NOT_ALLOWED",
         machineLimitReached = "MACHINE_LIMIT_REACHED", offlineExpired = "OFFLINE_EXPIRED",
         clockTampered = "CLOCK_TAMPERED"
}

public enum OfflineState: Sendable, Equatable { case online; case offline(validUntil: Date?, remaining: TimeInterval) }
public enum LatestAllowedVersion: Sendable, Equatable { case notApplicable, noneAllowed, version(String) }

public struct LicenseError: Error, Sendable, Equatable, LocalizedError {
    public enum Code: String, Sendable, Codable, CaseIterable {
        case notFound = "not_found", licenseExpired = "license_expired", versionNotAllowed = "version_not_allowed",
             machineLimitReached = "machine_limit_reached", planLimitExceeded = "plan_limit_exceeded",
             validationError = "validation_error", internalError = "internal_error",
             networkError = "network_error", invalidResponse = "invalid_response"
    }
    public let code: Code
    public let message: String
    public let status: Int?
    public let latestAllowedVersion: LatestAllowedVersion
    public var isLocking: Bool { get }
}

public enum ConfigError: Error, Sendable, Equatable { case missingProductID, missingPublicKey, invalidPublicKey(String), missingVersion }

@MainActor
public final class LicenseObserver: ObservableObject {
    public init(manager: LicenseManager)
    @Published public private(set) var state: LicenseState
    @Published public private(set) var offlineState: OfflineState
    @Published public private(set) var latestAllowedVersion: LatestAllowedVersion
    @Published public private(set) var licenseKeyHint: String?     // last 5 characters
    public var portalURL: URL { get }
    public func activate(key: String) async throws(LicenseError) -> LicenseState
    public func refresh() async
    public func openPortal()                                         // NSWorkspace.shared.open(portalURL)
}
```

The state strings (`"ACTIVE"`…) and error codes (`"not_found"`…) are the `rawValue`s and match the Electron ones exactly.

## 6. Behavior

Port `license-manager.ts` method by method. Concurrency model: `LicenseManager` is a thin `Sendable` facade over `LicenseEngine`, an actor that holds all mutable state and runs the state machine (the actor serializes work like the JS event loop; interleaving happens only at `await`, like in JS). The engine mirrors the values read by the synchronous getters (`state`, `licenseKey`, `latestAllowedVersion`, offline flag and token expiry, clock tampered) into a lock-protected snapshot (`OSAllocatedUnfairLock`), updated before listeners run.

### 6.1 Construction
1. Validate options (`ConfigError`), parse the public key once, resolve `version` (option, else bundle version).
2. Build `SecureStore(productID, storageDirectories, service, useKeychain)`, `TokenVerifier`, `ClockGuard` (starts its first check and the hourly loop).
3. Read `licenseKey` from the store synchronously. No key: state is `MISSING_KEY` before `init` returns (Electron sets it synchronously in the constructor too).
4. Start `init` in a `Task`; `ready()` awaits its value.

### 6.2 `init`
- No key: `MISSING_KEY`, no request.
- Key: check the stored token (6.6). If `ACTIVE`, keep the payload, state `ACTIVE`, resolve `ready`, and revalidate in the background with the background policy. Otherwise revalidate with the interactive policy and resolve `ready` with its result.
- After every `await`, return early if the key changed meanwhile (`setLicenseKey` ran).

### 6.3 `setLicenseKey(_:)`
Trim whitespace and newlines (keep case). Empty: `validation_error` "The license key is empty", no request. Request with the interactive policy; on success store `licenseKey`, set the key, activate. On failure throw the error, store and state untouched.

### 6.4 `refresh()`
Await `ready`; without a key return the state; else revalidate with the interactive policy. Never throws.

### 6.5 Revalidate / activate / lock / offline
- **revalidate(key, policy)**: clear the timer; request; success: activate. Error: locking code: lock; anything else: validate offline.
- **activate**: store `licenseToken`, keep the payload, online, reset retry delay to 5 min, latest allowed version `.notApplicable`, state `ACTIVE`, schedule next.
- **lock(code, latest)**: delete `licenseToken`, drop payload, online, latest allowed version from the error for `version_not_allowed` only, state from `lockedStates`. No timer.
- **validate offline**: offline, check the stored token, take its state (`latestAllowedVersion = .notApplicable` when it says `VERSION_NOT_ALLOWED`), schedule next, then double the retry delay (cap 1 h).

### 6.6 Stored token check
Await the clock guard's first check. Tampered: `CLOCK_TAMPERED`. No token or verification fails: `OFFLINE_EXPIRED`. Token's `mv` excludes the app version: `VERSION_NOT_ALLOWED` (token kept). Else `ACTIVE` with the payload.

### 6.7 Scheduling
- `ACTIVE` with a payload: `at = computeRefreshAt(payload, minOffline)`; if offline `at = max(at, now + retryDelay)`; then `at = min(at, exp)`.
- `OFFLINE_EXPIRED`, `CLOCK_TAMPERED`, or `VERSION_NOT_ALLOWED` while offline: `at = now + retryDelay`.
- Otherwise no timer. Nothing after `dispose` or without a key.
- Arm in steps of at most 60 minutes, re-reading the **wall clock** (`Date`) at each step. Sleeps use the monotonic clock, which stops during system sleep: the step re-arm is what catches up.
- `computeRefreshAt`: `min(iat + 2/3 lifetime, max(exp - minOffline, iat + 1 day))`, in milliseconds.

### 6.8 Requests
- One in-flight request per `(key, policy)`, shared by callers; cleared when it settles. A caller with another policy starts its own request.
- Body: `{ key, fingerprint, version, name, platform }`, JSON, `POST {api}/v1/products/{percent-encoded productId}/validate-key` (encoding = `encodeURIComponent`). Timeout per attempt: `min(10 s, remaining budget)`, floor 0. `URLSession` with an ephemeral configuration (no cache, no cookies).
- Response: non-2xx: parse `{ error: { code, message, latestAllowedVersion } }`; unknown codes become `network_error` (status kept); message defaults to "License server answered {status}"; `latestAllowedVersion` only read for `version_not_allowed` (non-string = `.noneAllowed`). Unparsable body = empty. 2xx without a string `license`: `invalid_response` "The license server returned no token". Connection error / timeout: `network_error` "The license server could not be reached", no status.
- Token failing verification after a 2xx: `invalid_response` "The license token failed verification" with the status.
- Transient = `network_error` without status, or status ≥ 500, 408, 429.
- Machine name: option, else looked up once (shared lookup).

### 6.9 Retry
`withRetry(attempt, isRetryable, policy, signal)`: deadline = now + budget; on error, wait = `delay/2 + random*delay/2`; stop (throw the error) if not retryable, aborted, or `now + wait + 1 s > deadline`; sleep (returns early on abort and throws the last error); delay = `min(delay*2, max)`. Policies: interactive 500 ms / 5 s / 30 s budget, background 2 s / 60 s / 5 min.

### 6.10 Token verification
Hand-written compact JWS verification (the token format is fixed, no JWT library needed):
- Three base64url segments; header JSON must have `alg: "EdDSA"` (anything else, including `none`, fails) and no `crit`.
- Signature: Ed25519 over `header.payload` ASCII with `Curve25519.Signing.PublicKey` (CryptoKit). The key comes from the SPKI PEM: base64 body, DER must be 44 bytes starting with `302a300506032b6570032100`.
- Claims, like `jose.jwtVerify` with leeway 0 (`now` = floor(epoch seconds)): `aud` equals productId (string, or array containing it); `sub` equals key; `exp` if present must be a number and `exp > now`; `nbf` if present must be a number and `nbf <= now`; `iat` if present must be a number.
- Then `fp` must equal `fingerprint()`, `iat` and `exp` must be numbers. `mv`: string, or `null`/missing for every version.

### 6.11 Version check
`isVersionAllowed(version, mv)`: same regex `^\s*v?(\d+)(?:\.(\d+))?`, same rules (unparsable either side: allowed). Used offline only.

### 6.12 Clock guard
On construction and every 60 min: `HEAD https://google.com`, no cache, 5 s timeout, parse the `Date` header (RFC 1123, `en_US_POSIX`). Reachable: tampered = `|now - network| > 5 min`, store `lastSeen = network`. Unreachable or no header: tampered if `now < lastSeen`; store `now` if greater or missing. Never throws. `ready` resolves after the first check.

### 6.13 Fingerprint
`fingerprint()` cached after the first call. Machine raw value: IOKit `IOPlatformUUID`, lowercased, whitespace and quotes stripped. Failure or empty: first up-and-running, non-loopback interface with an IPv4/IPv6 address whose link-layer address isn't `00:00:00:00:00:00` (libuv order), lowercased; else `gethostname()` lowercased. Never fails. Option `.value`/`.provider` replaces the raw value (still hashed).

### 6.14 Secure store
`get`: keychain, else first readable non-empty file; a value found in a file is written back to the keychain. `set`: keychain (errors ignored) and every file dir (create intermediate dirs, write atomically, `0o600`). `delete`: keychain (ignored) and every file. Keychain skipped when `useKeychain` is false. Backend injectable through a `SecretBackend` protocol for tests (an in-memory map, a throwing backend, or none).

### 6.15 Listeners
State changes only notify when the state differs. The snapshot is updated before listeners run; listeners run on the engine, outside any lock, in subscription order; `states` continuations get the new value at the same time.

### 6.16 Dispose
Sets disposed, aborts the root `CancelSignal` (stops retry sleeps, the scheduler and the clock loop), clears the timer. Idempotent, synchronous. A request already sent completes but its result is ignored when disposed. `states` streams finish.

### 6.17 Constants

| Constant | Value |
| --- | --- |
| Default API base URL | `https://api.licensemanager.dev` |
| Portal base URL | `https://app.licensemanager.dev/portal` |
| Request timeout | 10 s |
| Offline retry backoff | 5 min doubling to 60 min |
| Max timer step | 60 min |
| Min refresh interval from `minOfflineDuration` | 1 day |
| Min attempt time left in retry budget | 1 s |
| Clock check interval / timeout / tolerance | 60 min / 5 s / 5 min |
| Time URL | `https://google.com` |
| Default keychain service / file namespace salt | `dev.licensemanager.sdk` |

## 7. Platform requirements

- macOS 13 Ventura or later; Swift 6.0 or later (Xcode 16+). `swiftLanguageModes: [.v6]`.
- Sandboxed apps need the `com.apple.security.network.client` entitlement (documented; the SDK logs nothing and fails as `network_error` without it).
- Hardened runtime and notarization need nothing special.

## 8. SwiftUI layer

`LicenseObserver` subscribes to the engine's internal snapshot stream (state, online flag, latest allowed version, key), so `offlineState` updates also when only the online flag changes. Usage:

```swift
@main
struct MyApp: App {
    @StateObject private var license = LicenseObserver(manager: .shared)
    var body: some Scene {
        WindowGroup {
            switch license.state {
            case .loading: ProgressView()
            case .active: ContentView()
            case .missingKey: ActivationView()
            default: LockedView()
            }
        }
        .environmentObject(license)
    }
}
```

Docs explain that checks that matter must call `LicenseManager.state` (or `await ready()`) where the feature runs, not only hide UI.

## 9. Tests

Swift Testing (`import Testing`), `@testable import LicenseManagerKit`. Target: every Electron test has a Swift counterpart with the same name (as `@Test("…")` display names), so parity is reviewable. Coverage ≥ 80% of lines in `Sources/` (`swift test --enable-code-coverage`, checked with `llvm-cov report` in CI).

### 9.1 Test infrastructure (internal, not public API)
- `HTTPTransport` protocol: `FakeTransport` with a request log and a scripted handler for validate-key and the clock's `HEAD`, like Electron's `fetchMock`.
- `TimeSource` protocol (`now()` in ms, `sleep(ms, signal) async -> Bool`): `FakeTime` with virtual time, `advance(ms)` firing due sleepers in order and letting async work settle, `jump(ms)` for wall clock jumps (`vi.setSystemTime`).
- `SecretBackend` protocol: `MemoryBackend`, `ThrowingBackend`, or `nil` (files only).
- Ed25519 key pairs from CryptoKit per test run, SPKI PEM export, a JWS signer, plus a second key for "signed by another key".

### 9.2 Tests to port

| Electron file | Swift suite |
| --- | --- |
| `license-state.test.ts` | `LicenseStateTests`: startup (5 + 4 locking + 5 fallback + 4 offline), max version (6), token verification (6), setLicenseKey (6), retries (7), computeRefreshAt (5), automatic refresh (7) |
| `license-manager.test.ts` | `LicenseManagerTests`: constructor validation (plus invalid PEM, missing version), fingerprint (4), clock tamper offline (4) and network (5), portal URL (2), dispose |
| `secure-store.test.ts` | `SecureStoreTests`: file fallback (6), keychain (5) |
| `fingerprint.test.ts` | `FingerprintTests`: option value / provider, IOKit value normalization, fallbacks, hash |
| `environment.test.ts` | `EnvironmentTests`: platform from plist / fallback from `OperatingSystemVersion`, machine name fallback chain, keychain default from signing flags |
| `version.test.ts` | `VersionTests`: the full table |
| `index.test.ts` | `PublicAPITests`: sdk name and version |

New tests: golden vectors (§4); in-flight deduplication; `LicenseObserver` publishes state and offline changes; `LicenseAPI` against a scripted transport (error parsing, unknown codes, non-JSON body, timeouts, 2xx without token); JWS edge cases (bad segments, `crit`, `aud` arrays, `nbf` in the future).

### 9.3 Cross-SDK compatibility
`scripts/compat/electron-store.mjs` installs `@licenseman/electron` (without optional deps, so it uses files only), creates a `LicenseManager` with `storageDirs: [dir]` and `fingerprint: "compat-machine"`, and writes `expected.json` (fingerprint, install id). `CompatTests` (enabled by `LICENSEMANAGER_COMPAT_DIR`) open the same dir with no keychain and the same machine value and must produce the same fingerprint and install id; then write a value that `electron-store.mjs read` reads back (reverse direction).

### 9.4 Real keychain
`KeychainTests`, enabled by `LICENSEMANAGER_TEST_KEYCHAIN=1`: round-trip, update and delete through the login keychain with a random service. Run in CI on macOS.

### 9.5 Example app
`Examples/LicenseManagerExample`: SwiftUI app with activation, locked and app views driven by `LicenseObserver`, a "Manage license" button opening the portal, and an action gated on `.active` in code. Built in CI (`swift build --package-path Examples/LicenseManagerExample`). Product id and public key at the top of `ExampleApp.swift`, pointing to a test product for manual QA.

## 10. CI and release

### 10.1 `ci.yml` (PRs, and called by release)

```yaml
name: CI
on:
  pull_request:
  workflow_call:
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
permissions:
  contents: read
jobs:
  changeset:   # identical to the Electron SDK's job
  lint:        # macos-latest: swift format lint --strict --recursive Sources Tests Examples Package.swift
  test:        # macos-latest: swift build -Xswiftc -warnings-as-errors; swift test --enable-code-coverage
               # (+ LICENSEMANAGER_TEST_KEYCHAIN=1); coverage ≥ 80% via llvm-cov report; upload coverage
  example:     # swift build --package-path Examples/LicenseManagerExample
  compat:      # node scripts/compat/electron-store.mjs write; swift test --filter CompatTests
  docs:        # swift package dump-package sanity + DocC build via `xcrun docc` is left to SPI (.spi.yml)
```

Runners: `macos-latest` (the package is macOS only). Actions pinned to major versions like the other repos (`actions/checkout@v4`, `pnpm/action-setup@v4`, `actions/setup-node@v4`, `actions/upload-artifact@v4`). Swift: the toolchain of the runner's default Xcode (`xcodebuild -version` printed in the log); `Package.swift` declares tools 6.0.

### 10.2 `release.yml` (push to `main`)

Same skeleton as the Electron repo:
1. `ci` job reusing `ci.yml`.
2. `release` job (`contents: write`, `pull-requests: write`): checkout (full history), pnpm, node, `pnpm install --frozen-lockfile`, `changesets/action@v1` with `version: pnpm run version` and `publish: pnpm release` (`release` is a no-op echo: SwiftPM has no registry).
3. Auto-merge the "Version Packages" PR (`gh pr merge --merge --delete-branch`), check out the merge commit.
4. **Create the release**: read `version` from `package.json`; if tag `X.Y.Z` doesn't exist, extract the `## X.Y.Z` section of `CHANGELOG.md` and run `gh release create X.Y.Z --target <commit that set the version> --title X.Y.Z --notes-file …`. Tags are bare semver (`1.0.0`), the SwiftPM convention.

"Publishing" is the tag: SwiftPM resolves versions from git tags, and the Swift Package Index (once the package is listed) picks up new tags automatically and rebuilds the docs. Re-running the workflow is a no-op once the tag exists.

### 10.3 Versioning
- Changesets is the single source of truth, with one private package (`licensemanager-swift`). Every PR needs a changeset (or `pnpm changeset --empty`).
- `"version": "changeset version && node scripts/sync-version.mjs"`: copies the version into `SDKInfo.swift` so `LicenseManager.sdkVersion` follows. The "Version Packages" PR thus bumps `package.json`, `CHANGELOG.md` and `SDKInfo.swift` together.
- `.changeset/config.json`: same as Electron with `repo: licenseman/licensemanager-swift` and `privatePackages: { version: true, tag: false }` (tags are made by the release step).
- Semver on the Swift API: a source-breaking change is a major.

### 10.4 Repo setup (same as the Electron and Tauri repos)
- Public, MIT, issues on; wiki, projects and discussions off.
- Description: "Swift SDK for LicenseManager: license key activation, validation and offline checks in native macOS apps."
- Homepage: `https://licensemanager.dev/docs/macos`.
- Topics: `swift`, `swiftui`, `macos`, `sdk`, `licensing`, `license-key`, `license-activation`, `license-management`, `licensemanager`, `software-licensing`, `desktop-app`.
- Actions: default workflow permissions "read", "Allow GitHub Actions to create and approve pull requests" on (Changesets PR).
- Branch protection on `main`: PR + required checks.
- Dependabot: `github-actions`, `npm`, `swift`, weekly, grouped.
- `.spi.yml`: `documentation_targets: [LicenseManagerKit]`, platform macOS.

## 11. README

One `README.md`, same sections as the Tauri README: Install (Xcode and `Package.swift`), Usage (setup, activation screen with SwiftUI, gating features, AppKit), License state, Validation, Device fingerprint, Persistence, Clock-tamper detection, App Sandbox and distribution, Development, Releasing, License. Each section links to its page on `licensemanager.dev/docs/macos`. Badges: Swift Package Index (Swift versions, platforms), CI.

## 12. Acceptance checklist (1.0)

- [ ] Every row of 9.2 has a passing test with the matching name.
- [ ] Golden vectors and the cross-SDK compat job pass.
- [ ] CI green; coverage ≥ 80%; `swift format lint --strict` clean; no warnings.
- [ ] Example app activates a test key, survives offline on the stored token, locks on an expired key, and shows `CLOCK_TAMPERED` offline after moving the clock back.
- [ ] Sandboxed build of the example app (with `network.client`) activates and persists.
- [ ] An app moved from the Electron SDK to this SDK on the same Mac stays `ACTIVE` without a new activation, and the dashboard still shows one machine.
- [ ] A Changesets PR bumps the version; merging it creates the tag and the GitHub release; re-running the workflow is a no-op.
- [ ] Listed on the Swift Package Index, docs built there.
- [ ] Docs section `/docs/macos` and landing page `/macos` live.

## 13. Open questions

1. iOS support after 1.0: keychain is shared, but there's no stable device id (identifierForVendor resets on reinstall) and no Electron behavior to match; needs its own spec.
2. Should `LicenseManager` offer a `shared` singleton configured from `Info.plist`? Not in 1.0: the public key stays in code, like the other SDKs.
3. The clock check calls `google.com`, like Electron. Any change should be made in all SDKs at once.
4. App Store receipts: apps sold on the Mac App Store are paid through Apple and don't need license keys; a hybrid model (store + direct) works by shipping two builds. Revisit if users ask for receipt-based activation.
