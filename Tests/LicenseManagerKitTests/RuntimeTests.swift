import Foundation
import Testing

@testable import LicenseManagerKit

@Suite("runtime")
struct RuntimeTests {
    @Test("live time sleeps, and wakes early on abort")
    func liveTime() async {
        let time = LiveTime()
        #expect(abs(time.now() - Date().timeIntervalSince1970 * 1000) < 1000)
        #expect((0..<1).contains(time.random()))
        #expect(await time.sleep(ms: 5, signal: nil))
        #expect(await time.sleep(ms: 5, signal: CancelSignal()))

        let signal = CancelSignal()
        let task = Task { await time.sleep(ms: 60_000, signal: signal) }
        try? await Task.sleep(nanoseconds: 5_000_000)
        signal.abort()
        #expect(await task.value == false)
        #expect(await time.sleep(ms: 60_000, signal: signal) == false)
    }

    @Test("signals abort their children once")
    func signals() {
        let root = CancelSignal()
        let child = CancelSignal(parent: root)
        let calls = Locked(0)
        _ = child.addHandler { calls.withLock { $0 += 1 } }
        let removed = child.addHandler { calls.withLock { $0 += 100 } }
        child.removeHandler(removed)
        root.abort()
        root.abort()
        #expect(child.isAborted)
        #expect(calls.current == 1)
        #expect(child.addHandler {} == nil)
        #expect(CancelSignal(parent: root).isAborted)
    }

    @Test("the URLSession transport fails fast on an unreachable host")
    func transportFailure() async {
        let request = HTTPRequest(
            method: "POST", url: URL(string: "http://127.0.0.1:9/x")!, headers: ["X": "1"], body: Data(),
            timeoutMs: 2000)
        await #expect(throws: (any Error).self) { try await URLSessionTransport().send(request) }
    }

    @Test("the URLSession transport enforces its total timeout")
    func transportTimeout() async throws {
        // A listening socket that never answers.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(fd, 1)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        let started = Date()
        let request = HTTPRequest(method: "HEAD", url: URL(string: "http://127.0.0.1:\(port)/")!, timeoutMs: 200)
        await #expect(throws: (any Error).self) { try await URLSessionTransport().send(request) }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("parses HTTP dates")
    func httpDates() {
        #expect(parseHTTPDate("Thu, 01 Jan 2026 00:00:00 GMT") == 1_767_225_600_000)
        #expect(parseHTTPDate("Thursday, 01-Jan-26 00:00:00 GMT") == 1_767_225_600_000)
        #expect(parseHTTPDate("Thu Jan 1 00:00:00 2026") == 1_767_225_600_000)
        #expect(parseHTTPDate("yesterday") == nil)
        #expect(decodeTimestamp("!!") == nil)
        #expect(decodeTimestamp(nil) == nil)
    }
}
