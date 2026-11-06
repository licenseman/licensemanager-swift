import Foundation

struct RetryPolicy: Sendable, Equatable {
    /// Delay before the first retry, in ms. Doubles after each failed attempt.
    var initialDelayMs: Double
    /// Cap on a single delay, in ms.
    var maxDelayMs: Double
    /// Total time across all attempts and waits, in ms.
    var budgetMs: Double

    /// When a caller is waiting on the result (startup without a valid stored
    /// token, `setLicenseKey`, `refresh`).
    static let interactive = RetryPolicy(initialDelayMs: 500, maxDelayMs: 5000, budgetMs: 30_000)
    static let background = RetryPolicy(initialDelayMs: 2000, maxDelayMs: 60_000, budgetMs: 5 * 60_000)
}

/// No attempt is started with less than this left in the budget.
private let minAttemptMs: Double = 1000

/// Runs `attempt` until it succeeds, a non-retryable error is thrown or the
/// budget runs out, waiting with exponential backoff and jitter in between.
/// Each attempt receives the time left in the budget, to bound its timeout.
/// Aborting `signal` stops retrying; the last error is thrown.
func withRetry<T: Sendable, E: Error>(
    time: any TimeSource,
    policy: RetryPolicy,
    signal: CancelSignal?,
    isRetryable: (E) -> Bool,
    attempt: (_ remainingMs: Double) async throws(E) -> T
) async throws(E) -> T {
    let deadline = time.now() + policy.budgetMs
    var delay = policy.initialDelayMs
    while true {
        do {
            return try await attempt(deadline - time.now())
        } catch {
            // Equal jitter: half fixed, half random, so retries keep spreading out.
            let wait = delay / 2 + time.random() * delay / 2
            if !isRetryable(error) || signal?.isAborted == true || time.now() + wait + minAttemptMs > deadline {
                throw error
            }
            if !(await time.sleep(ms: wait, signal: signal)) { throw error }
            delay = min(delay * 2, policy.maxDelayMs)
        }
    }
}
