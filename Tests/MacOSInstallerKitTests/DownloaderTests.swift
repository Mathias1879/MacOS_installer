import Foundation
import Testing
@testable import MacOSInstallerKit

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let remote = URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!

@Test("downloads a whole file from offset zero when nothing is present")
func downloadsFromScratch() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    let transfer = FakeTransfer(payload: Data("0123456789".utf8))

    _ = try await Downloader(transfer: transfer)
        .download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    #expect(transfer.offsets == [0])
    #expect(try Data(contentsOf: destination) == Data("0123456789".utf8))
}

@Test("resumes from the size of an existing partial file instead of restarting")
func resumesFromPartial() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("0123".utf8).write(to: destination)
    let transfer = FakeTransfer(payload: Data("0123456789".utf8))

    _ = try await Downloader(transfer: transfer)
        .download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    #expect(transfer.offsets == [4])
    #expect(try Data(contentsOf: destination) == Data("0123456789".utf8))
}

@Test("skips the transfer entirely when the file is already complete")
func skipsWhenComplete() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("0123456789".utf8).write(to: destination)
    let transfer = FakeTransfer(payload: Data("0123456789".utf8))

    _ = try await Downloader(transfer: transfer)
        .download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    #expect(transfer.offsets.isEmpty)
}

@Test("throws sizeMismatch when the finished file is not the expected length")
func throwsOnSizeMismatch() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    let transfer = FakeTransfer(payload: Data("0123".utf8))

    await #expect(throws: DownloadError.sizeMismatch(expected: 10, actual: 4, path: destination.path)) {
        _ = try await Downloader(transfer: transfer)
            .download(from: remote, to: destination, expectedBytes: 10) { _, _ in }
    }
}

@Test("reports cumulative progress that accounts for bytes already on disk")
func reportsProgressIncludingResumedBytes() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    // 3 bytes already present out of 10, so the resumed total (3 + 7 = 10)
    // is distinguishable from the bytes transferred in this run (7).
    try Data("012".utf8).write(to: destination)
    let transfer = FakeTransfer(payload: Data("0123456789".utf8))

    final class Box: @unchecked Sendable { var seen: [(Int64, Int64)] = [] }
    let box = Box()

    _ = try await Downloader(transfer: transfer)
        .download(from: remote, to: destination, expectedBytes: 10) { done, total in
            box.seen.append((done, total))
        }

    // Full sequence, not just the last value: the pre-transfer report must
    // already account for the 3 bytes on disk, and the mid-transfer report
    // must be 3 + 7, not 7. Asserting only `.last` cannot distinguish them,
    // because the unconditional final callback is always (10, 10).
    #expect(box.seen.map(\.0) == [3, 10, 10])
    #expect(box.seen.allSatisfy { $0.1 == 10 })
}

@Test("retries a failing transfer up to the attempt limit, then throws")
func retriesThenThrows() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    struct Boom: Error {}
    let transfer = FakeTransfer(payload: Data("0123456789".utf8), error: Boom())

    await #expect(throws: (any Error).self) {
        _ = try await Downloader(
            transfer: transfer, maximumAttempts: 3, backoff: { _ in .zero }
        ).download(from: remote, to: destination, expectedBytes: 10) { _, _ in }
    }

    // Three attempts, not one.
    #expect(transfer.offsets.count == 3)
}

@Test("a retry resumes from the partial file rather than restarting")
func retryResumesFromPartial() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("012".utf8).write(to: destination)
    struct Boom: Error {}
    let transfer = FakeTransfer(payload: Data("0123456789".utf8), error: Boom())

    _ = try? await Downloader(
        transfer: transfer, maximumAttempts: 2, backoff: { _ in .zero }
    ).download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    // Both attempts start at 3 — restarting an 18 GB download from zero is not
    // a recovery strategy.
    #expect(transfer.offsets == [3, 3])
}

@Test("succeeds without retrying when the first attempt works")
func noRetryOnSuccess() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    let transfer = FakeTransfer(payload: Data("0123456789".utf8))

    _ = try await Downloader(
        transfer: transfer, maximumAttempts: 3, backoff: { _ in .zero }
    ).download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    #expect(transfer.offsets.count == 1)
}

@Test("backoff returns the exact documented durations, not merely a growing shape")
func backoffReturnsExactDurations() {
    let backoff = Downloader.defaultBackoff
    // A bare `backoff(1) < backoff(2)` ordering check would pass for
    // `.seconds(attempt * 1000)` just as happily as for the 1s/2s/4s this
    // type actually promises — pin the exact values instead.
    #expect(backoff(1) == .seconds(1))
    #expect(backoff(2) == .seconds(2))
    #expect(backoff(3) == .seconds(4))
    #expect(backoff(4) == .seconds(8))
}

@Test("total backoff across the default attempt limit stays under 10 seconds")
func totalBackoffAcrossDefaultAttemptsIsBounded() {
    let backoff = Downloader.defaultBackoff
    let defaultMaximumAttempts = Downloader.defaultMaximumAttempts

    // Waits happen after every failed attempt except the last one, so with
    // 3 attempts there are 2 waits: backoff(1) + backoff(2) = 1s + 2s = 3s.
    let totalWait = (1..<defaultMaximumAttempts).reduce(Duration.zero) { $0 + backoff($1) }

    // 10s is chosen as a ceiling well above the 3s this produces today, so a
    // future bump of `maximumAttempts` that silently pushed the total wait
    // past 10 seconds — heading toward a multi-minute stall — fails here
    // instead of only showing up as a user complaint about a frozen install.
    #expect(totalWait < .seconds(10))
}

@Test("fires onRetry once per retry, with the attempt number, but not on a first-attempt success")
func onRetryFiresOncePerRetryNotOnSuccess() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    struct Boom: Error {}
    let failingTransfer = FakeTransfer(payload: Data("0123456789".utf8), error: Boom())

    final class Box: @unchecked Sendable { var attempts: [Int] = [] }
    let box = Box()

    await #expect(throws: (any Error).self) {
        _ = try await Downloader(
            transfer: failingTransfer, maximumAttempts: 3, backoff: { _ in .zero },
            onRetry: { attempt, _, _ in box.attempts.append(attempt) }
        ).download(from: remote, to: destination, expectedBytes: 10) { _, _ in }
    }

    // Retried after attempt 1 and attempt 2, but not after attempt 3 — that
    // one exhausts the limit and throws instead of retrying again.
    #expect(box.attempts == [1, 2])

    let successfulTransfer = FakeTransfer(payload: Data("0123456789".utf8))
    final class SuccessBox: @unchecked Sendable { var attempts: [Int] = [] }
    let successBox = SuccessBox()

    let otherDestination = destination.deletingLastPathComponent().appendingPathComponent("other.pkg")
    _ = try await Downloader(
        transfer: successfulTransfer, maximumAttempts: 3, backoff: { _ in .zero },
        onRetry: { attempt, _, _ in successBox.attempts.append(attempt) }
    ).download(from: remote, to: otherDestination, expectedBytes: 10) { _, _ in }

    #expect(successBox.attempts.isEmpty)
}
