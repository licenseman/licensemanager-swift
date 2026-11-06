import CryptoKit
import Foundation
import IOKit

/// Hashes a raw machine value into a stable, opaque base64 digest.
func hashMachineValue(_ raw: String) -> String {
    Data(SHA256.hash(data: Data(raw.utf8))).base64EncodedString()
}

/// Where the default machine id comes from. Injected in tests.
struct MachineIDSources: Sendable {
    var platformUUID: @Sendable () -> String? = readPlatformUUID
    var macAddress: @Sendable () -> String? = firstMACAddress
    var hostname: @Sendable () -> String = currentHostname
}

/// The Mac's hardware UUID, the `IOPlatformUUID` that `ioreg -rd1 -c
/// IOPlatformExpertDevice` prints (and the Electron SDK reads).
func readPlatformUUID() -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(
        service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue()
    return value as? String
}

/// Normalizes a machine id like the Electron SDK: no `=`, whitespace or
/// quotes, lowercased. Nil when nothing is left.
func normalizeMachineID(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let value = String(
        raw.unicodeScalars.filter {
            $0 != "=" && $0 != "\"" && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    ).lowercased()
    return value.isEmpty ? nil : value
}

/// The OS machine id, normalized; on failure a hardware MAC address, then the
/// hostname. Never fails.
func readMachineID(_ sources: MachineIDSources = MachineIDSources()) -> String {
    if let id = normalizeMachineID(sources.platformUUID()) { return id }
    if let mac = sources.macAddress() { return mac.lowercased() }
    return sources.hostname().lowercased()
}

/// Resolves the machine component of the fingerprint, returning its base64
/// sha256 digest.
func resolveMachineFingerprint(
    _ option: MachineFingerprint?,
    sources: MachineIDSources = MachineIDSources()
) async -> String {
    let raw: String
    switch option {
    case .value(let value): raw = value
    case .provider(let provider): raw = await provider()
    case nil: raw = readMachineID(sources)
    }
    return hashMachineValue(raw)
}

/// First MAC address of an up, running, non-loopback interface with an IP
/// address, in `getifaddrs` order, like Node's `os.networkInterfaces()`.
func firstMACAddress() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }

    var links: [String: String] = [:]
    var candidates: [String] = []
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let entry = pointer.pointee
        guard let addr = entry.ifa_addr else { continue }
        let name = String(cString: entry.ifa_name)
        let family = Int32(addr.pointee.sa_family)
        if family == AF_LINK {
            let mac = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String? in
                let length = Int(dl.pointee.sdl_alen)
                guard length == 6 else { return nil }
                let offset = Int(dl.pointee.sdl_nlen)
                return withUnsafeBytes(of: dl.pointee.sdl_data) { bytes -> String? in
                    guard offset + length <= bytes.count else { return nil }
                    return bytes[offset..<(offset + length)].map { String(format: "%02x", $0) }
                        .joined(separator: ":")
                }
            }
            if let mac { links[name] = mac }
            continue
        }
        let flags = Int32(entry.ifa_flags)
        guard
            flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
            family == AF_INET || family == AF_INET6
        else { continue }
        if !candidates.contains(name) { candidates.append(name) }
    }
    return candidates.lazy.compactMap { links[$0] }.first { $0 != "00:00:00:00:00:00" }
}
