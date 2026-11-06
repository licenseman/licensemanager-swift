// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "licensemanager-swift",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LicenseManagerKit", targets: ["LicenseManagerKit"])
    ],
    targets: [
        .target(
            name: "LicenseManagerKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(
            name: "LicenseManagerKitTests",
            dependencies: ["LicenseManagerKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
