import Foundation

/// Leading `major[.minor]` numbers of a version, ignoring patch and suffixes.
private func parseMajorMinor(_ version: String) -> (major: Int, minor: Int?)? {
    var rest = Substring(version).drop(while: { $0.isWhitespace })
    if rest.first == "v" { rest = rest.dropFirst() }
    let majorDigits = rest.prefix(while: { $0.isASCII && $0.isNumber })
    guard !majorDigits.isEmpty, let major = Int(majorDigits) else { return nil }
    rest = rest.dropFirst(majorDigits.count)
    guard rest.first == "." else { return (major, nil) }
    let minorDigits = rest.dropFirst().prefix(while: { $0.isASCII && $0.isNumber })
    guard !minorDigits.isEmpty, let minor = Int(minorDigits) else { return (major, nil) }
    return (major, minor)
}

/// Whether a license token's `mv` claim allows `version`. `mv` is a major
/// (`"2"`: all 2.x.x and older), a major.minor (`"2.3"`: all 2.3.x and older),
/// or nil (every version). A value that can't be parsed allows the version:
/// the server stays the authoritative check.
func isVersionAllowed(_ version: String, maxVersion: String?) -> Bool {
    guard let maxVersion else { return true }
    guard let max = parseMajorMinor(maxVersion), let current = parseMajorMinor(version) else {
        return true
    }
    let minor = current.minor ?? 0
    if current.major != max.major { return current.major < max.major }
    guard let maxMinor = max.minor else { return true }
    return minor <= maxMinor
}
