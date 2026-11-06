import Foundation

/// A value guarded by a lock, readable and writable from any thread.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value {
        withLock { $0 }
    }

    func set(_ newValue: Value) {
        withLock { $0 = newValue }
    }
}

/// Equivalent of an `AbortSignal`: aborting it runs its handlers once, and
/// aborts its children.
final class CancelSignal: @unchecked Sendable {
    private struct State {
        var aborted = false
        var nextID = 0
        var handlers: [Int: @Sendable () -> Void] = [:]
    }

    private let state = Locked(State())
    private let parent: CancelSignal?
    private var parentHandler: Int?

    init(parent: CancelSignal? = nil) {
        self.parent = parent
        guard let parent else { return }
        let id = parent.addHandler { [weak self] in self?.abort() }
        if let id {
            parentHandler = id
        } else {
            state.withLock { $0.aborted = true }
        }
    }

    var isAborted: Bool {
        state.withLock { $0.aborted }
    }

    /// Registers `handler`, or returns nil without calling it when already aborted.
    func addHandler(_ handler: @escaping @Sendable () -> Void) -> Int? {
        state.withLock { state in
            if state.aborted { return nil }
            state.nextID += 1
            state.handlers[state.nextID] = handler
            return state.nextID
        }
    }

    func removeHandler(_ id: Int?) {
        guard let id else { return }
        _ = state.withLock { $0.handlers.removeValue(forKey: id) }
    }

    func abort() {
        let handlers: [@Sendable () -> Void]? = state.withLock { state in
            if state.aborted { return nil }
            state.aborted = true
            defer { state.handlers = [:] }
            return state.handlers.sorted { $0.key < $1.key }.map(\.value)
        }
        guard let handlers else { return }
        parent?.removeHandler(parentHandler)
        for handler in handlers {
            handler()
        }
    }
}

/// Wall clock and timers. Injected so tests can run on virtual time.
protocol TimeSource: Sendable {
    /// Wall clock time, in milliseconds since 1970.
    func now() -> Double
    /// Waits `ms` milliseconds. Returns false as soon as `signal` aborts.
    func sleep(ms: Double, signal: CancelSignal?) async -> Bool
    /// A random number in `0..<1`, for retry jitter.
    func random() -> Double
}

/// Real time: `Date` for the wall clock, Dispatch (monotonic) for timers.
struct LiveTime: TimeSource {
    func now() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    func random() -> Double {
        Double.random(in: 0..<1)
    }

    func sleep(ms: Double, signal: CancelSignal?) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumed = Locked(false)
            let resume: @Sendable (Bool) -> Void = { value in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            let handlerID = Locked<Int?>(nil)
            if let signal {
                guard let id = signal.addHandler({ resume(false) }) else {
                    resume(false)
                    return
                }
                handlerID.set(id)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(max(0, ms).rounded(.up)))) {
                // Drop the handler, so long-lived signals don't accumulate them.
                signal?.removeHandler(handlerID.current)
                resume(true)
            }
        }
    }
}

struct HTTPRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    /// Total time allowed for the request, in milliseconds.
    var timeoutMs: Double
}

struct HTTPResponse: Sendable {
    var status: Int
    /// Header names are lowercased.
    var headers: [String: String] = [:]
    var body = Data()
}

/// Sends HTTP requests. Injected so tests can script the server.
protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

struct TimeoutError: Error {}

/// `URLSession` with no cache and no cookies, and a total timeout per request.
struct URLSessionTransport: HTTPTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let timeout = max(0.001, request.timeoutMs / 1000)
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let finalRequest = urlRequest
        return try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            group.addTask {
                let (data, response) = try await Self.session.data(for: finalRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                var headers: [String: String] = [:]
                for (name, value) in http.allHeaderFields {
                    if let name = name as? String, let value = value as? String {
                        headers[name.lowercased()] = value
                    }
                }
                return HTTPResponse(status: http.statusCode, headers: headers, body: data)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimeoutError() }
            return first
        }
    }
}
