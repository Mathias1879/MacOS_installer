import Foundation
import Testing
@testable import MacOSInstallerKit

private struct KnownFailure: Error, Explainable {
    var explanation: UserFacingError {
        UserFacingError(
            title: "Couldn't do the thing",
            whatHappened: "The thing did not happen.",
            whatItMeans: "Something was wrong with the thing.",
            whatToDoNext: ["Try the thing again"]
        )
    }
    var technicalDetail: String { "KnownFailure: exit 3, stderr: nope" }
}

private struct UnknownFailure: Error {}

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("uses an Explainable error's own three-part explanation")
func usesExplainableExplanation() {
    let result = explain(KnownFailure(), log: nil)

    #expect(result.title == "Couldn't do the thing")
    #expect(result.whatToDoNext == ["Try the thing again"])
}

@Test("writes the technical detail to the log and references it in the message")
func logsTechnicalDetail() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let log = DiagnosticLog(directory: dir, clock: { Date(timeIntervalSince1970: 1_790_000_000) })

    let result = explain(KnownFailure(), log: log)

    let reference = try #require(result.logReference)
    #expect(reference.hasSuffix(".log"))

    let written = try String(
        contentsOf: dir.appendingPathComponent(
            DateFormatter.logDateFormatter.string(from: Date(timeIntervalSince1970: 1_790_000_000)) + ".log"
        ),
        encoding: .utf8
    )
    #expect(written.contains("exit 3"))
    #expect(written.contains("nope"))
}

@Test("an unexplainable error still produces a three-part message, never raw enum text")
func wrapsUnknownErrors() {
    let result = explain(UnknownFailure(), log: nil)

    // The user must never see `UnknownFailure()`; they get a real message and
    // the raw text goes to the log instead.
    #expect(result.title.isEmpty == false)
    #expect(result.whatHappened.contains("UnknownFailure") == false)
    #expect(result.whatToDoNext.isEmpty == false)
}

@Test("an unexplainable error's raw description is preserved in the log")
func logsUnknownErrorDescription() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let log = DiagnosticLog(directory: dir, clock: { Date(timeIntervalSince1970: 1_790_000_000) })

    _ = explain(UnknownFailure(), log: log)

    let written = try String(
        contentsOf: dir.appendingPathComponent(
            DateFormatter.logDateFormatter.string(from: Date(timeIntervalSince1970: 1_790_000_000)) + ".log"
        ),
        encoding: .utf8
    )
    #expect(written.contains("UnknownFailure"))
}
