import CryptoKit
import Foundation

@testable import LicenseManagerKit

let productID = "x7Kp2QaZ"
let licenseKey = "7KQ2M-X9ZPA-H4TRC-WN6EY-B3JDF"
let hour: Double = 60 * 60 * 1000
let day = 24 * hour
let week = 7 * day
/// 2026-01-01T00:00:00Z, in ms.
let start: Double = 1_767_225_600_000

struct TestError: Error {}

// MARK: Virtual time

/// Virtual time, the equivalent of `vi.useFakeTimers`: sleepers only wake up
/// when the test advances time.
final class FakeTime: TimeSource, @unchecked Sendable {
    private struct Sleeper {
        var id: Int
        var deadline: Double
        var continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var monotonic: Double
        var wallOffset: Double = 0
        var nextID = 0
        var sleepers: [Sleeper] = []
        var randomValue = 0.5
    }

    private let state: Locked<State>

    init(start: Double) {
        state = Locked(State(monotonic: start))
    }

    func now() -> Double {
        state.withLock { $0.monotonic + $0.wallOffset }
    }

    func random() -> Double {
        state.withLock { $0.randomValue }
    }

    func sleep(ms: Double, signal: CancelSignal?) async -> Bool {
        await withCheckedContinuation { continuation in
            let id: Int = state.withLock { state in
                state.nextID += 1
                state.sleepers.append(
                    Sleeper(id: state.nextID, deadline: state.monotonic + max(0, ms), continuation: continuation)
                )
                return state.nextID
            }
            guard let signal else { return }
            let handler = signal.addHandler { [weak self] in self?.cancel(id) }
            if handler == nil { cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        let sleeper: Sleeper? = state.withLock { state in
            guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
            return state.sleepers.remove(at: index)
        }
        sleeper?.continuation.resume(returning: false)
    }

    /// Number of pending sleepers.
    var pending: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Moves time forward, waking every sleeper due on the way in order and
    /// letting the work they start settle before moving on.
    func advance(_ ms: Double) async {
        await settle()
        let target = state.withLock { $0.monotonic + ms }
        while true {
            let due: Sleeper? = state.withLock { state in
                guard
                    let index = state.sleepers.indices
                        .filter({ state.sleepers[$0].deadline <= target })
                        .min(by: { state.sleepers[$0].deadline < state.sleepers[$1].deadline })
                else { return nil }
                let sleeper = state.sleepers.remove(at: index)
                state.monotonic = max(state.monotonic, sleeper.deadline)
                return sleeper
            }
            guard let due else { break }
            due.continuation.resume(returning: true)
            await settle()
        }
        state.withLock { $0.monotonic = target }
        await settle()
    }

    /// Moves the wall clock without firing timers, like `vi.setSystemTime`.
    func jump(_ ms: Double) {
        state.withLock { $0.wallOffset += ms }
    }

    /// Lets work started by resumed sleepers run to its next suspension.
    func settle() async {
        for _ in 0..<4 {
            for _ in 0..<20 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 300_000)
        }
    }
}

// MARK: Scripted server

/// Scripted HTTP server, the equivalent of the Electron tests' `fetchMock`.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Call: Sendable {
        var request: HTTPRequest
        var body: ValidateKeyRequest?
    }

    typealias Validate = @Sendable (ValidateKeyRequest) async throws -> HTTPResponse
    typealias Head = @Sendable () async throws -> HTTPResponse

    private let calls = Locked<[Call]>([])
    private let validateHandler = Locked<Validate>({ _ in throw URLError(.notConnectedToInternet) })
    private let headHandler = Locked<Head>({ throw URLError(.notConnectedToInternet) })

    /// Validate-key handler; receives the parsed request body. Offline by default.
    var validate: Validate {
        get { validateHandler.current }
        set { validateHandler.set(newValue) }
    }

    /// Clock guard's network time. Offline by default.
    var head: Head {
        get { headHandler.current }
        set { headHandler.set(newValue) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = request.body.flatMap { try? JSONDecoder().decode(ValidateKeyRequest.self, from: $0) }
        calls.withLock { $0.append(Call(request: request, body: body)) }
        if request.url.path.hasSuffix("/validate-key") {
            return try await validate(body!)
        }
        return try await head()
    }

    var validateCalls: [Call] {
        calls.current.filter { $0.request.url.path.hasSuffix("/validate-key") }
    }

    var validateCount: Int {
        validateCalls.count
    }
}

func ok(_ token: String) -> HTTPResponse {
    json(200, ["license": token])
}

func fail(_ status: Int, _ code: String, _ extra: [String: Any] = [:]) -> HTTPResponse {
    var error: [String: Any] = ["code": code, "message": "nope"]
    error.merge(extra) { $1 }
    return json(status, ["error": error])
}

func json(_ status: Int, _ object: Any) -> HTTPResponse {
    HTTPResponse(
        status: status,
        headers: ["content-type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: object)
    )
}

func dateResponse(_ ms: Double) -> HTTPResponse {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return HTTPResponse(status: 200, headers: ["date": formatter.string(from: Date(timeIntervalSince1970: ms / 1000))])
}

// MARK: Keychain

/// In-memory keychain.
final class MemoryBackend: SecretBackend, @unchecked Sendable {
    let items = Locked<[String: String]>([:])

    func get(service: String, account: String) throws -> String? {
        items.current["\(service)::\(account)"]
    }

    func set(service: String, account: String, value: String) throws {
        items.withLock { $0["\(service)::\(account)"] = value }
    }

    func delete(service: String, account: String) throws {
        _ = items.withLock { $0.removeValue(forKey: "\(service)::\(account)") }
    }
}

/// A keychain that fails every call.
struct ThrowingBackend: SecretBackend {
    func get(service: String, account: String) throws -> String? { throw TestError() }
    func set(service: String, account: String, value: String) throws { throw TestError() }
    func delete(service: String, account: String) throws { throw TestError() }
}

// MARK: Tokens

struct SigningKey: Sendable {
    let privateKey = Curve25519.Signing.PrivateKey()

    var publicKeyPEM: String {
        let der =
            Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
            + privateKey.publicKey.rawRepresentation
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PUBLIC KEY-----\n\(body)\n-----END PUBLIC KEY-----\n"
    }
}

let signingKey = SigningKey()
let otherSigningKey = SigningKey()

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func base64URL(json object: Any) -> String {
    base64URL(try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

/// Signs a compact JWS over `claims` with `header`.
func signJWS(_ claims: [String: Any], header: [String: Any] = ["alg": "EdDSA"], key: SigningKey = signingKey)
    -> String
{
    let input = "\(base64URL(json: header)).\(base64URL(json: claims))"
    let signature = try! key.privateKey.signature(for: Data(input.utf8))
    return "\(input).\(base64URL(signature))"
}

/// A license token like the server issues.
func sign(
    fp: String,
    sub: String = licenseKey,
    aud: String = productID,
    mv: String? = nil,
    lifetimeMs: Double = 3 * week,
    issuedAt: Double,
    key: SigningKey = signingKey
) -> String {
    let iat = (issuedAt / 1000).rounded(.down)
    return signJWS(
        [
            "fp": fp,
            "mv": mv.map { $0 as Any } ?? NSNull(),
            "aud": aud,
            "sub": sub,
            "iat": iat,
            "nbf": iat - 2 * 60 * 60,
            "exp": iat + (lifetimeMs / 1000).rounded(.down),
        ],
        key: key
    )
}

// MARK: Harness

/// Per-test environment: temp storage, virtual time, scripted server and
/// in-memory keychain, like the Electron tests' `beforeEach`.
final class Harness: @unchecked Sendable {
    let dir: URL
    let time = FakeTime(start: start)
    let transport = FakeTransport()
    let backend = MemoryBackend()
    private(set) var manager: LicenseManager?

    init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lm-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        manager?.dispose()
        try? FileManager.default.removeItem(at: dir)
    }

    var deps: Dependencies {
        Dependencies(
            transport: transport,
            time: time,
            secretBackend: backend,
            machineIDSources: MachineIDSources(
                platformUUID: { "test-machine" }, macAddress: { nil }, hostname: { "test-host" }
            ),
            machineName: { "Test Machine" }
        )
    }

    /// A bundle without an Info.plist, so the keychain service and version
    /// never come from the test runner.
    var emptyBundle: Bundle {
        Bundle(url: dir)!
    }

    @discardableResult
    func make(
        productID: String = productID,
        _ configure: (inout LicenseManager.Options) -> Void = { _ in }
    ) throws -> LicenseManager {
        manager?.dispose()
        var options = LicenseManager.Options(
            fingerprint: .value("fixed-machine"),
            version: "2.3.1",
            machineName: "Test Machine",
            apiBaseURL: URL(string: "https://api.test"),
            storageDirectories: [dir]
        )
        configure(&options)
        let manager = try LicenseManager(
            productID: productID,
            publicKey: signingKey.publicKeyPEM,
            options: options,
            deps: deps,
            bundle: emptyBundle
        )
        self.manager = manager
        return manager
    }

    func store(productID: String = productID) -> SecureStore {
        SecureStore(productID: productID, directories: [dir], backend: backend)
    }

    /// Fingerprint of this test install, without triggering any validation.
    func fingerprint() async throws -> String {
        let manager = try make()
        let fingerprint = await manager.fingerprint()
        manager.dispose()
        self.manager = nil
        return fingerprint
    }

    func sign(
        fp: String,
        sub: String = licenseKey,
        aud: String = productID,
        mv: String? = nil,
        lifetimeMs: Double = 3 * week,
        issuedAt: Double? = nil,
        key: SigningKey = signingKey
    ) -> String {
        LicenseManagerKitTests.sign(
            fp: fp, sub: sub, aud: aud, mv: mv, lifetimeMs: lifetimeMs, issuedAt: issuedAt ?? time.now(), key: key
        )
    }

    /// Server issuing valid tokens for whatever key and fingerprint it gets.
    func serveValid(lifetimeMs: Double = 3 * week) {
        transport.validate = { [unowned self] body in
            ok(self.sign(fp: body.fingerprint, sub: body.key, lifetimeMs: lifetimeMs))
        }
    }

    func seed(lifetimeMs: Double = 3 * week, issuedAt: Double? = nil) async throws {
        let fp = try await fingerprint()
        store().set(licenseKeyKey, licenseKey)
        store().set(licenseTokenKey, sign(fp: fp, lifetimeMs: lifetimeMs, issuedAt: issuedAt))
    }

    func advance(_ ms: Double) async {
        await time.advance(ms)
    }

    /// Awaits `operation`, advancing virtual time so validation retries can run out.
    func settle<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let done = Locked(false)
        let task = Task {
            let value = await operation()
            done.set(true)
            return value
        }
        while !done.current { await time.advance(5000) }
        return await task.value
    }
}

extension Result {
    var error: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

extension LicenseManager {
    /// `setLicenseKey` as a `Result`, for assertions.
    func trySetLicenseKey(_ key: String) async -> Result<LicenseState, LicenseError> {
        do {
            return .success(try await setLicenseKey(key))
        } catch {
            return .failure(error)
        }
    }
}
