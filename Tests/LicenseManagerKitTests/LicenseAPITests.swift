import Foundation
import Testing

@testable import LicenseManagerKit

/// The validate-key client against a scripted server.
@Suite("license API")
struct LicenseAPITests {
    let transport = FakeTransport()
    let request = ValidateKeyRequest(key: "K", fingerprint: "F", version: "1.0.0", name: "N", platform: "macOS")

    func post(timeoutMs: Double = 10_000) async -> Result<String, LicenseError> {
        do {
            return .success(
                try await postValidateKey(
                    transport: transport, apiBaseURL: "https://api.test", productID: "a/b", request: request,
                    timeoutMs: timeoutMs
                ).token
            )
        } catch {
            return .failure(error)
        }
    }

    func respond(_ response: HTTPResponse) {
        transport.validate = { _ in response }
    }

    @Test("returns the token and encodes the product id")
    func token() async throws {
        respond(ok("tok"))
        #expect(await post() == .success("tok"))
        let call = try #require(transport.validateCalls.first)
        #expect(call.request.url.absoluteString == "https://api.test/v1/products/a%2Fb/validate-key")
        #expect(call.body == request)
        #expect(call.request.timeoutMs == 10_000)
    }

    @Test("caps the timeout at 10 seconds and the remaining budget")
    func timeout() async throws {
        respond(ok("tok"))
        _ = await post(timeoutMs: 60_000)
        _ = await post(timeoutMs: 2500)
        _ = await post(timeoutMs: -5)
        #expect(transport.validateCalls.map(\.request.timeoutMs) == [10_000, 2500, 0])
    }

    @Test("parses error bodies")
    func errorBody() async {
        respond(fail(403, "version_not_allowed", ["latestAllowedVersion": "1.9.0", "message": "Too new"]))
        let error = await post().error
        #expect(
            error == LicenseError(.versionNotAllowed, "Too new", status: 403, latestAllowedVersion: .version("1.9.0")))
    }

    @Test("reads latestAllowedVersion only for version_not_allowed")
    func latestOnlyForVersion() async {
        respond(fail(404, "not_found", ["latestAllowedVersion": "1.9.0"]))
        #expect(await post().error?.latestAllowedVersion == .notApplicable)
        respond(fail(403, "version_not_allowed", ["latestAllowedVersion": 3]))
        #expect(await post().error?.latestAllowedVersion == .noneAllowed)
    }

    @Test("maps unknown codes and bodies to network_error with the status")
    func unknownCodes() async {
        respond(fail(418, "teapot"))
        #expect(await post().error == LicenseError(.networkError, "nope", status: 418))
        respond(HTTPResponse(status: 502, body: Data("<html>".utf8)))
        #expect(await post().error == LicenseError(.networkError, "License server answered 502", status: 502))
        respond(json(500, ["error": "flat"]))
        #expect(await post().error?.code == .networkError)
    }

    @Test("reports a 2xx without a token as invalid_response")
    func noToken() async {
        respond(json(200, ["license": 42]))
        #expect(
            await post().error == LicenseError(.invalidResponse, "The license server returned no token", status: 200))
        respond(HTTPResponse(status: 200, body: Data("not json".utf8)))
        #expect(await post().error?.code == .invalidResponse)
    }

    @Test("reports connection errors and timeouts as network_error without status")
    func connectionErrors() async {
        transport.validate = { _ in throw TimeoutError() }
        #expect(await post().error == LicenseError(.networkError, "The license server could not be reached"))
    }

    @Test("tells transient errors apart")
    func transient() {
        #expect(isTransientError(LicenseError(.networkError, "")))
        #expect(!isTransientError(LicenseError(.invalidResponse, "")))
        for status in [500, 503, 408, 429] {
            #expect(isTransientError(LicenseError(.networkError, "", status: status)))
        }
        for status in [400, 402, 404, 418, 422] {
            #expect(!isTransientError(LicenseError(.networkError, "", status: status)))
        }
    }

    @Test("encodes like encodeURIComponent")
    func uriEncoding() {
        #expect(encodeURIComponent("a/b c?d=é&e!~*'()") == "a%2Fb%20c%3Fd%3D%C3%A9%26e!~*'()")
    }

    @Test(
        "talks to a real server",
        .enabled(if: ProcessInfo.processInfo.environment["LICENSEMANAGER_TEST_NETWORK"] != nil))
    func realTransport() async throws {
        let response = try await URLSessionTransport().send(
            HTTPRequest(method: "HEAD", url: timeURL, timeoutMs: 5000)
        )
        #expect(response.headers["date"].flatMap(parseHTTPDate) != nil)
    }
}
