# licensemanager-swift

## 1.1.0

### Minor Changes

- [`ccf41ce`](https://github.com/licenseman/licensemanager-swift/commit/ccf41cedcad7207f0df0c5b61abf8eab8c55eb4d) Thanks [@nick-keller](https://github.com/nick-keller)! - Send a `User-Agent` header naming the SDK, its version, and the macOS version and architecture (`licensemanager-swift/1.1.0 (macOS 15.1; arm64)`), so the dashboard can tell where validations come from.

## 1.0.0

### Major Changes

- [`2893318`](https://github.com/licenseman/licensemanager-swift/commit/289331895c11f71afcf69bca1f90754aa8abfe19) Thanks [@nick-keller](https://github.com/nick-keller)! - First release of the Swift SDK for native macOS apps: `LicenseManagerKit`, a port of `@licenseman/electron` 1.3.0 with compatible keychain items, storage and fingerprint, plus `LicenseObserver` for SwiftUI.
