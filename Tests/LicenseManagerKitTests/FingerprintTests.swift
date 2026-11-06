import CryptoKit
import Foundation
import Testing

@testable import LicenseManagerKit

/// Port of the Electron SDK's `fingerprint.test.ts`.
@Suite("fingerprint")
struct FingerprintTests {
    @Test("hashes a verbatim string")
    func verbatim() async {
        #expect(await resolveMachineFingerprint(.value("my-machine")) == hashMachineValue("my-machine"))
    }

    @Test("awaits a provider")
    func provider() async {
        #expect(await resolveMachineFingerprint(.provider { "async-value" }) == hashMachineValue("async-value"))
    }

    @Test("normalizes the macOS IOPlatformUUID")
    func normalizesUUID() async {
        let sources = MachineIDSources(
            platformUUID: { " \"ABCDEF12-3456-7890-ABCD-EF1234567890\"\n" }, macAddress: { nil }, hostname: { "h" }
        )
        #expect(readMachineID(sources) == "abcdef12-3456-7890-abcd-ef1234567890")
        #expect(
            await resolveMachineFingerprint(nil, sources: sources)
                == hashMachineValue("abcdef12-3456-7890-abcd-ef1234567890"))
    }

    @Test("falls back to the MAC address when the UUID is missing or empty")
    func macFallback() {
        for uuid in [nil, "", "  "] as [String?] {
            let sources = MachineIDSources(
                platformUUID: { uuid }, macAddress: { "AA:BB:CC:DD:EE:FF" }, hostname: { "h" })
            #expect(readMachineID(sources) == "aa:bb:cc:dd:ee:ff")
        }
    }

    @Test("falls back to the hostname without a MAC address")
    func hostnameFallback() {
        let sources = MachineIDSources(platformUUID: { nil }, macAddress: { nil }, hostname: { "Janes-Mac.local" })
        #expect(readMachineID(sources) == "janes-mac.local")
    }

    @Test("reads a real machine id on this Mac")
    func realMachineID() {
        let uuid = readPlatformUUID()
        #expect(uuid?.isEmpty == false)
        #expect(normalizeMachineID(uuid) == uuid?.lowercased())
        #expect(!readMachineID().isEmpty)
        if let mac = firstMACAddress() {
            #expect(mac.wholeMatch(of: /([0-9a-f]{2}:){5}[0-9a-f]{2}/) != nil)
        }
    }

    @Test("is a stable base64 sha256 digest")
    func stableDigest() {
        #expect(hashMachineValue("x") == Data(SHA256.hash(data: Data("x".utf8))).base64EncodedString())
    }
}
