# ``LicenseManagerKit``

License key activation, validation and offline checks for native macOS apps, with [LicenseManager](https://licensemanager.dev/macos).

## Overview

Create one ``LicenseManager`` when the app starts, with your product id and its Ed25519 public key from the dashboard. It validates the stored license key on every launch, keeps working offline on a signed token, re-validates in the background and detects clock tampering. Gate paid features on ``LicenseState/active``.

```swift
import LicenseManagerKit

let licenseManager = try LicenseManager(productID: "your-product-id", publicKey: publicKeyPEM)

switch await licenseManager.ready() {
case .active: showApp()
case .missingKey: showActivation()
default: showLocked()
}
```

In SwiftUI, observe it with ``LicenseObserver``.

The full guide is at [licensemanager.dev/docs/macos](https://licensemanager.dev/docs/macos).

## Topics

### Essentials

- ``LicenseManager``
- ``LicenseManager/Options``
- ``LicenseState``

### SwiftUI

- ``LicenseObserver``

### Errors

- ``LicenseError``
- ``ConfigError``

### Details

- ``OfflineState``
- ``LatestAllowedVersion``
- ``MachineFingerprint``
