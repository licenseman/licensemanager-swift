import Foundation

private let minute: Double = 60 * 1000
/// How often the clock-tamper check runs, after the initial run.
let clockCheckIntervalMs = 60 * minute
/// Server whose HTTP `Date` header is the trusted source of current time.
let timeURL = URL(string: "https://google.com")!
private let timeRequestTimeoutMs: Double = 5000
/// How far the system clock may drift from network time, in either direction,
/// before it counts as tampering. Covers the `Date` header's 1 s precision and
/// request latency.
private let clockSkewToleranceMs = 5 * minute

let lastSeenKey = "lastSeen"

/// Detects system clock rollback. Checks once on construction and then every
/// hour, until its signal aborts.
final class ClockGuard: Sendable {
    private let store: SecureStore
    private let transport: any HTTPTransport
    private let time: any TimeSource
    private let tampered = Locked(false)
    /// Completes once the initial check has run.
    let ready: Task<Void, Never>

    init(store: SecureStore, transport: any HTTPTransport, time: any TimeSource, signal: CancelSignal) {
        self.store = store
        self.transport = transport
        self.time = time
        let checker = Checker(store: store, transport: transport, time: time, tampered: tampered)
        ready = Task { await checker.check() }
        Task {
            while await time.sleep(ms: clockCheckIntervalMs, signal: signal) {
                await checker.check()
            }
        }
    }

    /// True once a backwards clock jump has been observed.
    var isTampered: Bool {
        tampered.current
    }

    private struct Checker: Sendable {
        let store: SecureStore
        let transport: any HTTPTransport
        let time: any TimeSource
        let tampered: Locked<Bool>

        /// Network time is trusted above all: when reachable, the system clock
        /// is compared against it and the stored last-seen time is reset to it.
        /// Only when offline does the check fall back to the stored maximum,
        /// where a time earlier than it signals clock tampering.
        func check() async {
            if let networkNow = await fetchNetworkTime() {
                tampered.set(abs(time.now() - networkNow) > clockSkewToleranceMs)
                store.set(lastSeenKey, encodeTimestamp(networkNow))
                return
            }
            let now = time.now()
            let previous = decodeTimestamp(store.get(lastSeenKey))
            if let previous, now < previous {
                tampered.set(true)
                return
            }
            if previous == nil || now > previous! {
                store.set(lastSeenKey, encodeTimestamp(now))
            }
        }

        /// Current time according to the time URL's `Date` header, in ms, or
        /// nil when offline or the header is missing or unparsable.
        private func fetchNetworkTime() async -> Double? {
            guard
                let response = try? await transport.send(
                    HTTPRequest(method: "HEAD", url: timeURL, timeoutMs: timeRequestTimeoutMs)
                ),
                let header = response.headers["date"]
            else { return nil }
            return parseHTTPDate(header)
        }
    }
}

/// Parses an HTTP `Date` header (RFC 1123, or RFC 850 / asctime), in ms since 1970.
func parseHTTPDate(_ value: String) -> Double? {
    let formats = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"]
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    for format in formats {
        formatter.dateFormat = format
        if let date = formatter.date(from: value.trimmingCharacters(in: .whitespaces)) {
            return date.timeIntervalSince1970 * 1000
        }
    }
    return nil
}

/// Stores the integer as base64 to lightly obscure it.
func encodeTimestamp(_ ms: Double) -> String {
    Data(String(Int64(ms)).utf8).base64EncodedString()
}

func decodeTimestamp(_ value: String?) -> Double? {
    guard let value, let data = Data(base64Encoded: value) else { return nil }
    let digits = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    let prefix = digits.prefix { $0.isNumber || $0 == "-" }
    return Int64(prefix).map(Double.init)
}
