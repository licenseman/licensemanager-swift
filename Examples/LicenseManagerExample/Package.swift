// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LicenseManagerExample",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "LicenseManagerExample",
            dependencies: [.product(name: "LicenseManagerKit", package: "licensemanager-swift")]
        )
    ],
    swiftLanguageModes: [.v6]
)
