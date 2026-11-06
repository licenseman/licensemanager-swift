import Foundation
import Testing

@testable import LicenseManagerKit

/// Port of the Electron SDK's `environment.test.ts`.
@Suite("environment")
struct EnvironmentTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lm-env-\(UUID().uuidString)")

    func plist(_ contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("SystemVersion.plist")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("uses the macOS ComputerName")
    func computerName() {
        #expect(
            defaultMachineName(computerName: { "Jane’s MacBook Pro\n" }, hostname: { "mac.home" })
                == "Jane’s MacBook Pro")
    }

    @Test("falls back to the hostname on failure or empty output")
    func hostnameFallback() {
        #expect(defaultMachineName(computerName: { nil }, hostname: { "mac.home" }) == "mac.home")
        #expect(defaultMachineName(computerName: { "\n" }, hostname: { "mac.home" }) == "mac.home")
        #expect(!currentHostname().isEmpty)
        #expect(!defaultMachineName().isEmpty)
    }

    @Test("includes the macOS version")
    func macOSVersion() throws {
        let url = try plist(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>ProductName</key><string>macOS</string><key>ProductVersion</key>
            \t<string>26.5.1</string></dict></plist>
            """
        )
        #expect(defaultPlatform(systemVersionPlist: url) == "macOS 26.5.1")
    }

    @Test("falls back to the OS version, then bare macOS")
    func fallsBack() {
        let missing = dir.appendingPathComponent("missing.plist")
        let v = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        #expect(defaultPlatform(systemVersionPlist: missing, operatingSystemVersion: v) == "macOS 15.0")
        let p = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1)
        #expect(defaultPlatform(systemVersionPlist: missing, operatingSystemVersion: p) == "macOS 14.6.1")
        let none = OperatingSystemVersion(majorVersion: 0, minorVersion: 0, patchVersion: 0)
        #expect(defaultPlatform(systemVersionPlist: missing, operatingSystemVersion: none) == "macOS")
        #expect(defaultPlatform().hasPrefix("macOS "))
    }

    @Test("uses the keychain only for properly signed builds")
    func keychainDefault() {
        #expect(defaultUseKeychain(signingFlags: nil) == false)
        #expect(defaultUseKeychain(signingFlags: 0x0002) == false)
        #expect(defaultUseKeychain(signingFlags: 0x0002 | 0x20000) == false)
        #expect(defaultUseKeychain(signingFlags: 0) == true)
        #expect(defaultUseKeychain(signingFlags: 0x10000) == true)
        // Whatever signs the test runner, reading the flags must not fail.
        _ = currentSigningFlags()
    }

    @Test("reads the bundle id and version")
    func bundle() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let empty = try #require(Bundle(url: dir))
        #expect(appBundleIdentifier(empty) == nil)
        #expect(appVersion(empty) == nil)
        let app = dir.appendingPathComponent("My.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.my</string>\
            <key>CFBundleShortVersionString</key><string>2.3.1</string></dict></plist>
            """.utf8
        ).write(to: app.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: dir.appendingPathComponent("My.app")))
        #expect(appBundleIdentifier(bundle) == "com.example.my")
        #expect(appVersion(bundle) == "2.3.1")
    }
}
