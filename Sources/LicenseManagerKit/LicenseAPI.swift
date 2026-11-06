import Foundation

let defaultAPIBaseURL = "https://api.licensemanager.dev"
private let requestTimeoutMs: Double = 10_000

/// Server codes that are reported as-is; any other failure is a `network_error`.
private let knownServerCodes: Set<LicenseError.Code> = [
    .notFound, .licenseExpired, .versionNotAllowed, .machineLimitReached,
    .planLimitExceeded, .validationError, .internalError,
]

struct ValidateKeyRequest: Codable, Sendable, Equatable {
    var key: String
    var fingerprint: String
    var version: String
    var name: String
    var platform: String
}

/// Characters `encodeURIComponent` leaves as-is.
private let uriComponentAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
)

/// JavaScript's `encodeURIComponent`.
func encodeURIComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? value
}

/// Calls validate-key and returns the unverified license token.
///
/// - Parameter timeoutMs: Request timeout, capped at 10 seconds.
func postValidateKey(
    transport: any HTTPTransport,
    apiBaseURL: String,
    productID: String,
    request: ValidateKeyRequest,
    timeoutMs: Double = requestTimeoutMs
) async throws(LicenseError) -> (token: String, status: Int) {
    let response: HTTPResponse
    do {
        guard
            let url = URL(string: "\(apiBaseURL)/v1/products/\(encodeURIComponent(productID))/validate-key")
        else { throw URLError(.badURL) }
        response = try await transport.send(
            HTTPRequest(
                method: "POST",
                url: url,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(request),
                timeoutMs: max(0, min(timeoutMs, requestTimeoutMs))
            )
        )
    } catch {
        throw LicenseError(.networkError, "The license server could not be reached")
    }

    let json = try? JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed])
    guard (200..<300).contains(response.status) else {
        throw parseServerError(status: response.status, json: json)
    }
    guard let token = (json as? [String: Any])?["license"] as? String else {
        throw LicenseError(.invalidResponse, "The license server returned no token", status: response.status)
    }
    return (token, response.status)
}

/// Whether a failed validate-key call may succeed if repeated: the server was
/// unreachable, overloaded or failing. Answers about the key are final.
func isTransientError(_ error: LicenseError) -> Bool {
    guard let status = error.status else { return error.code == .networkError }
    return status >= 500 || status == 408 || status == 429
}

/// Maps an error response to a ``LicenseError``, branching on `code` only.
private func parseServerError(status: Int, json: Any?) -> LicenseError {
    let error = (json as? [String: Any])?["error"] as? [String: Any]
    let rawCode = error?["code"] as? String ?? ""
    let message = error?["message"] as? String ?? "License server answered \(status)"
    let code = LicenseError.Code(rawValue: rawCode).flatMap { knownServerCodes.contains($0) ? $0 : nil }
    var latest = LatestAllowedVersion.notApplicable
    if rawCode == LicenseError.Code.versionNotAllowed.rawValue {
        latest = (error?["latestAllowedVersion"] as? String).map { .version($0) } ?? .noneAllowed
    }
    return LicenseError(code ?? .networkError, message, status: status, latestAllowedVersion: latest)
}
