import Foundation
import Security
import SystemConfiguration

/// OS name and version shown in the dashboard, e.g. `macOS 26.5.1`.
func defaultPlatform(
    systemVersionPlist: URL = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"),
    operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
) -> String {
    if let version = productVersion(plist: systemVersionPlist) {
        return "macOS \(version)"
    }
    let version = operatingSystemVersion
    guard version.majorVersion > 0 else { return "macOS" }
    let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
    return "macOS \(version.majorVersion).\(version.minorVersion)\(patch)"
}

/// `ProductVersion` from SystemVersion.plist, e.g. `26.5.1`.
private func productVersion(plist url: URL) -> String? {
    guard
        let data = try? Data(contentsOf: url),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dict = plist as? [String: Any],
        let version = (dict["ProductVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !version.isEmpty
    else { return nil }
    return version
}

/// The user-facing computer name (e.g. "Jane's MacBook Pro", unlike the
/// network hostname), else the hostname. Never fails.
func defaultMachineName(
    computerName: () -> String? = { SCDynamicStoreCopyComputerName(nil, nil) as String? },
    hostname: () -> String = currentHostname
) -> String {
    if let name = computerName()?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
        return name
    }
    return hostname()
}

/// `gethostname()`, like Node's `os.hostname()`.
func currentHostname() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else {
        return ProcessInfo.processInfo.hostName
    }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The running app's bundle identifier.
func appBundleIdentifier(_ bundle: Bundle = .main) -> String? {
    guard let id = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
        return nil
    }
    return id
}

/// The running app's version (`CFBundleShortVersionString`).
func appVersion(_ bundle: Bundle = .main) -> String? {
    guard
        let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespaces),
        !version.isEmpty
    else { return nil }
    return version
}

/// `kSecCodeSignatureAdhoc`.
private let adhocFlag: UInt32 = 0x0002

/// Signing flags of the running process, or nil when it is unsigned.
func currentSigningFlags() -> UInt32? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
        return nil
    }
    var info: CFDictionary?
    guard
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess,
        let dict = info as? [String: Any],
        dict[kSecCodeInfoIdentifier as String] != nil
    else { return nil }
    return (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
}

/// Whether to use the keychain by default: not for unsigned or ad-hoc signed
/// builds, whose signature changes on every build.
func defaultUseKeychain(signingFlags: UInt32?) -> Bool {
    guard let flags = signingFlags else { return false }
    return flags & adhocFlag == 0
}
