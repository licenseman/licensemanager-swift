import Testing

@testable import LicenseManagerKit

/// Port of the Electron SDK's `version.test.ts`.
@Suite("isVersionAllowed")
struct VersionTests {
    @Test(
        "version with mv",
        arguments: [
            ("2.3.1", nil, true),
            ("2.9.9", "2", true),
            ("1.0.0", "2", true),
            ("3.0.0", "2", false),
            ("2.3.9", "2.3", true),
            ("2.2.0", "2.3", true),
            ("1.9.0", "2.3", true),
            ("2.4.0", "2.3", false),
            ("3.0.0", "2.3", false),
            ("2", "2.3", true),
            ("v2.3.1", "2.3", true),
            ("2.4.0-beta.1", "2.3", false),
            ("2.3.1", "garbage", true),
            ("garbage", "2.3", true),
            (" 2.3.1", "2.3.x", true),
        ] as [(String, String?, Bool)]
    )
    func allowed(version: String, mv: String?, expected: Bool) {
        #expect(isVersionAllowed(version, maxVersion: mv) == expected)
    }
}
