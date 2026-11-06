# LicenseManager for macOS (Swift)

[![CI](https://github.com/licenseman/licensemanager-swift/actions/workflows/release.yml/badge.svg)](https://github.com/licenseman/licensemanager-swift/actions/workflows/release.yml)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flicenseman%2Flicensemanager-swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/licenseman/licensemanager-swift)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flicenseman%2Flicensemanager-swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/licenseman/licensemanager-swift)

Swift SDK for [LicenseManager](https://licensemanager.dev/macos): license key activation, validation and offline checks in native macOS apps (SwiftUI or AppKit).

It is the native version of [`@licenseman/electron`](https://github.com/licenseman/licensemanager-electron) and [`tauri-plugin-licensemanager`](https://github.com/licenseman/licensemanager-tauri), with the same behavior and the same storage: an app moving from Electron or Tauri to Swift keeps its activations. No dependencies: CryptoKit, Foundation, Security and IOKit only.

Full docs: [licensemanager.dev/docs/macos](https://licensemanager.dev/docs/macos) · API reference: [Swift Package Index](https://swiftpackageindex.com/licenseman/licensemanager-swift/documentation/licensemanagerkit)

## Install

[Docs](https://licensemanager.dev/docs/macos/setup)

In Xcode: **File > Add Package Dependencies…**, enter `https://github.com/licenseman/licensemanager-swift`, and add the `LicenseManagerKit` library to your app target. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/licenseman/licensemanager-swift", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "LicenseManagerKit", package: "licensemanager-swift"),
    ]),
]
```

Requires macOS 13 or later and Swift 6 (Xcode 16 or later). Sandboxed apps need the **Outgoing Connections (Client)** capability (`com.apple.security.network.client`).

## Usage

[Docs](https://licensemanager.dev/docs/macos/setup)

Create one `LicenseManager` when the app starts:

```swift
import LicenseManagerKit

// Ed25519 public key from the Security page. Hard-code it: never load it from
// a file or fetch it at runtime.
let licenseManager = try! LicenseManager(
    productID: "your-product-id",
    publicKey: """
    -----BEGIN PUBLIC KEY-----
    MCowBQYDK2VwAyEA…
    -----END PUBLIC KEY-----
    """,
    options: .init(minOfflineDuration: 14 * 24 * 60 * 60)
    // .init(fingerprint:version:machineName:platform:keychainService:useKeychain:)
)
```

An empty product id, an invalid public key, or no version (no `version` option and no `CFBundleShortVersionString`) throws a `ConfigError`.

### Activation screen (SwiftUI)

[Docs](https://licensemanager.dev/docs/macos/swiftui)

`LicenseObserver` publishes the license for SwiftUI:

```swift
@main
struct MyApp: App {
    @StateObject private var license = LicenseObserver(manager: licenseManager)

    var body: some Scene {
        WindowGroup {
            switch license.state {
            case .loading: ProgressView()
            case .active: ContentView()
            case .missingKey: ActivationView()
            default: LockedView()   // expired, invalid key, too many Macs…
            }
        }
        .environmentObject(license)
    }
}

struct ActivationView: View {
    @EnvironmentObject private var license: LicenseObserver
    @State private var key = ""
    @State private var error: LicenseError?

    var body: some View {
        Form {
            TextField("License key", text: $key)
            Button("Activate") {
                Task {
                    do throws(LicenseError) {
                        try await license.activate(key: key)
                    } catch {
                        self.error = error   // branch on error.code
                    }
                }
            }
        }
    }
}
```

`license.openPortal()` opens the customer portal, where customers renew and manage their machines. `license.offlineState`, `license.latestAllowedVersion` and `license.licenseKeyHint` (last 5 characters) are published too.

### Gating features

[Docs](https://licensemanager.dev/docs/macos/activation)

Hiding a button isn't enough: check the license where the paid feature runs.

```swift
func exportPDF() throws {
    guard licenseManager.state == .active else { throw AppError.licenseRequired }
    // …
}
```

`LicenseManager` is `Sendable` and works from any thread or actor: `state`, `ready()`, `setLicenseKey(_:)`, `refresh()`, `offlineState`, `latestAllowedVersion`, `portalURL`, `licenseKey`, `fingerprint()`, `isClockTampered`, `onStateChange(_:)` (returns a `Subscription`, cancelled when released) and `states` (an `AsyncStream` of the current state, then every change).

### License state

[Docs](https://licensemanager.dev/docs/macos/license-states)

| State | Meaning |
| --- | --- |
| `.loading` | Startup validation in progress. |
| `.missingKey` | No key stored yet: ask the user for one. |
| `.active` | Valid license, verified online or with the stored token. |
| `.invalidKey` | The key doesn't exist for this product (`not_found`). |
| `.expired` | The license expired (`license_expired`). |
| `.versionNotAllowed` | The license doesn't include this version. `latestAllowedVersion` is `.version("2.3.1")` or `.noneAllowed`. |
| `.machineLimitReached` | The license is active on its maximum number of Macs. |
| `.offlineExpired` | The server can't be reached and there is no valid stored token. |
| `.clockTampered` | The server can't be reached and the system clock was moved back. |

The raw values (`"ACTIVE"`…) are the same strings as in the Electron and Tauri SDKs.

## Validation

[Docs](https://licensemanager.dev/docs/macos/validation)

The stored key is validated online on every launch. The token the server returns is a JWT, verified like an offline token (EdDSA signature, product, key, machine fingerprint and expiry) and stored in the keychain.

When the stored token is valid, `ready()` returns `.active` right away and the online validation runs in the background; a refused license then switches the state. Otherwise `ready()` waits for the server.

`setLicenseKey(_:)` validates a key the user typed (trimmed, case kept) and stores it only on success. On failure it throws a `LicenseError` whose `code` is a server code (`.notFound`, `.licenseExpired`, `.versionNotAllowed`, `.machineLimitReached`, `.planLimitExceeded`, `.validationError`, `.internalError`) or `.networkError` / `.invalidResponse`, with `status` and `latestAllowedVersion` when the server sent them. The current license is left untouched. Branch on `code` (or `isLocking`), never on `message`.

Only the four license errors lock the app. When the server can't be reached, times out, or answers another error, the SDK falls back to the stored token until it expires.

The key is re-validated in the background at 2/3 of the token lifetime. Set `minOfflineDuration` to re-validate earlier, so that at least that much offline time remains; it never moves re-validation within 1 day of the last one. While offline, retries back off from 5 minutes to 1 hour. Timers re-check the wall clock at least hourly, so system sleep can't delay a validation by more than an hour. Call `refresh()` to re-validate on demand, e.g. after the customer renewed.

Each validation retries transient failures (network errors, timeouts, 408, 429 and 5xx) with exponential backoff and jitter: for up to 30 seconds when a caller is waiting (startup without a valid stored token, `setLicenseKey(_:)`, `refresh()`), and up to 5 minutes for background validations. Answers about the key are never retried.

`version` (defaults to `CFBundleShortVersionString`), `platform` (e.g. `macOS 26.5.1`) and `machineName` (the computer name, e.g. "Jane's MacBook Pro") are sent with every validation. While offline, `version` is also checked against the token's max version (`mv`): a stored token for 2.x refuses 3.0 with `.versionNotAllowed` until the server can be reached, since online the server's answer is authoritative.

## Device fingerprint

[Docs](https://licensemanager.dev/docs/macos/fingerprint)

The fingerprint is a stable identifier unique to the Mac, installation and product: `{sha256 of the machine id}:{random install id}:{product id}`. The install id is stored in the keychain (see below), so it survives uninstall/reinstall.

The machine id defaults to the Mac's hardware UUID (`IOPlatformUUID`, read with IOKit, so it works in the App Sandbox), falling back to a hardware MAC address or the hostname. Override it with a fixed string or a function (still hashed):

```swift
.init(fingerprint: .provider { await myMachineID() })
```

## Persistence

[Docs](https://licensemanager.dev/docs/macos/storage)

The install id, last-seen timestamp, license key and token are stored as generic passwords in the login keychain, under the service `keychainService` (defaults to the bundle id) and the account `{productId}:{name}`, and mirrored to redundant, non-obvious files in `~/Library/Application Support` and `~/Library/Caches` (inside the container for sandboxed apps).

The keychain is skipped by default for unsigned and ad-hoc signed builds (`swift run`, "Sign to Run Locally"), whose signature changes on every build and would trigger a keychain prompt each time; pass `useKeychain: true` to force it.

Items and files are the same as the Electron and Tauri SDKs': an app moving to Swift keeps its activation and its machine slot. A keychain item created by the previous app is owned by its code signature, so the Swift build gets a one-time "allow access" prompt; if the user denies it, the files still hold the values (non-sandboxed apps). See [migrating from Electron or Tauri](https://licensemanager.dev/docs/macos/migrating-from-electron).

## Clock-tamper detection

[Docs](https://licensemanager.dev/docs/macos/clock-tampering)

On startup and every hour, the SDK compares the system clock with the `Date` header of `https://google.com`: more than 5 minutes apart means the clock was moved. Offline, it records the newest time it has seen, and an earlier time later means the clock was rolled back. `isClockTampered` is then `true`, and while offline the stored token is refused with `.clockTampered`. Checks never fail and never block the app.

## App Sandbox and distribution

[Docs](https://licensemanager.dev/docs/macos/distribution)

The SDK works in sandboxed and non-sandboxed apps, with the hardened runtime and notarized: it spawns no process and only needs outgoing connections. License keys are for apps you sell yourself (direct download); apps sold on the Mac App Store are paid through Apple.

## Development

```sh
swift build
swift test                                    # unit tests (Swift Testing)
swift format lint --strict --recursive Sources Tests Examples Package.swift
swift run --package-path Examples/LicenseManagerExample
```

With the Command Line Tools only (no Xcode), point SwiftPM at the Swift Testing framework:

```sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L
```

`Examples/LicenseManagerExample` is a SwiftUI app with activation, locked and licensed views and a feature gated on `.active`; set your test product's id and public key at the top of `ExampleApp.swift`.

Slower checks:

```sh
LICENSEMANAGER_TEST_KEYCHAIN=1 swift test               # real login keychain
node scripts/compat/electron-store.mjs write /tmp/compat  # then:
LICENSEMANAGER_COMPAT_DIR=/tmp/compat swift test --filter CompatibilityTests
node scripts/compat/electron-store.mjs read /tmp/compat
```

The compat check makes sure this SDK and `@licenseman/electron` read each other's stored values and compute the same fingerprint. [swift-specs.md](swift-specs.md) is the specification of the port.

## Releasing

Versions are managed with [Changesets](https://github.com/changesets/changesets) (Node is only used for release tooling):

1. Run `pnpm changeset` and commit the generated file with your change (`pnpm changeset --empty` for none).
2. On merge to `main`, the release workflow opens a "Version Packages" PR that bumps `package.json`, `LicenseManager.sdkVersion` and `CHANGELOG.md`, and merges it.
3. It then tags the version (`1.2.3`, no `v`) and creates the GitHub release. SwiftPM resolves versions from tags, and the [Swift Package Index](https://swiftpackageindex.com/licenseman/licensemanager-swift) picks them up and rebuilds the docs.

## License

[MIT](LICENSE)
