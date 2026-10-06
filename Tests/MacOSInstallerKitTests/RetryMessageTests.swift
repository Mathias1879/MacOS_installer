import Foundation
import Testing
@testable import MacOSInstallerKit

/// Finding 1 of Task 9's fix round 2: the retry notice used to interpolate
/// the raw error directly, so a `DownloadError.transferFailed` rendered as
/// `Transfer attempt 1 failed (transferFailed("curl exited 7: Could not
/// resolve host")); retrying in 1.0 seconds…` — raw Swift value syntax in
/// front of a first-time user. `retryMessage` now goes through `Explainable`
/// instead.
@Test("retry message for a DownloadError.transferFailed leaks no raw Swift value syntax")
func retryMessageDoesNotLeakRawSwiftSyntax() throws {
    // Same shape as `ExplanationWordingTests.explanationsDoNotLeakRawSwiftSyntax`:
    // an identifier directly abutting `(` and a labelled argument is code,
    // not prose that a human would write.
    let rawValueSyntax = try NSRegularExpression(
        pattern: "[A-Za-z_][A-Za-z0-9_]*\\([A-Za-z_][A-Za-z0-9_]*:"
    )

    let message = retryMessage(
        attempt: 1,
        wait: .seconds(1),
        error: DownloadError.transferFailed("curl exited 7: Could not resolve host")
    )

    let match = rawValueSyntax.firstMatch(in: message, range: NSRange(message.startIndex..., in: message))
    let leaked = match.flatMap { Range($0.range, in: message) }.map { String(message[$0]) }

    #expect(leaked == nil, "retry message leaks raw Swift syntax '\(leaked ?? "")': \(message)")
}

@Test("retry message keeps the attempt number and wait, and names the real cause")
func retryMessageKeepsAttemptAndWaitAndCause() {
    let message = retryMessage(
        attempt: 2,
        wait: .seconds(2),
        error: DownloadError.transferFailed("curl exited 7: Could not resolve host")
    )

    #expect(message.contains("attempt 2"))
    #expect(message.contains("2.0 seconds") || message.contains("retrying in 2"))
    #expect(message.contains("curl exited 7: Could not resolve host"))
}

@Test("retry message falls back to a generic cause for an error that isn't Explainable")
func retryMessageFallsBackForNonExplainableError() {
    struct Boom: Error {}

    let message = retryMessage(attempt: 1, wait: .seconds(1), error: Boom())

    #expect(message.contains("the connection failed"))
    #expect(message.contains("Boom") == false)
}
