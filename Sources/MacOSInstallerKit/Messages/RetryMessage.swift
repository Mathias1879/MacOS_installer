import Foundation

/// Renders a single terminal line for a retried transfer attempt.
///
/// Routes the failure through `Explainable` rather than interpolating `error`
/// directly. Interpolating the raw error renders its Swift value syntax —
/// `Transfer attempt 1 failed (transferFailed("curl exited 7: Could not
/// resolve host")); retrying in 1.0 seconds…` — to a first-time user. That is
/// the exact anti-pattern `Explainable.swift`'s doc comment records as already
/// fixed, and this project has shipped it twice before (see
/// `ExplanationWordingTests.explanationsDoNotLeakRawSwiftSyntax`).
///
/// The attempt number and wait are kept as-is: they are genuinely useful and
/// contain no error-type information to leak.
public func retryMessage(attempt: Int, wait: Duration, error: any Error) -> String {
    let cause = (error as? any Explainable)?.explanation.whatHappened ?? "the connection failed"
    return "Transfer attempt \(attempt) failed (\(cause)); retrying in \(wait)…"
}
