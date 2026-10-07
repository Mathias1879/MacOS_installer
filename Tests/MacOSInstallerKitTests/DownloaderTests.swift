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

@Test("a retry resumes from wherever the previous attempt actually got to, not just its starting offset")
func retryResumesFromPartial() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("012".utf8).write(to: destination)
    struct Boom: Error {}
    // Writes 4 more bytes before throwing, so the first attempt actually
    // advances the file from 3 bytes to 7 before failing. A `FakeTransfer`
    // that throws before writing anything (the old fixture) can never tell
    // this test apart from a buggy `Downloader` that hoists `alreadyHave` out
    // of the retry loop and recomputes it only once: both would report [3, 3].
    let transfer = FakeTransfer(payload: Data("0123456789".utf8), error: Boom(), bytesBeforeThrowing: 4)

    _ = try? await Downloader(
        transfer: transfer, maximumAttempts: 2, backoff: { _ in .zero }
    ).download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    // The second attempt must start at 3 + 4 = 7, not 3 again — proving
    // `alreadyHave` is recomputed per attempt rather than hoisted out of the
    // loop, which is exactly the property this test is named for. Exact
    // values, not just "strictly increasing", per fix round 2 Finding 3.
    #expect(transfer.offsets == [3, 7])
}

@Test("the final attempt succeeds when the transfer wrote the complete file before throwing")
func finalAttemptSucceedsWhenFileIsActuallyComplete() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    struct Boom: Error {}
    // curl can write every expected byte and still exit non-zero — the
    // payload lands intact and the process reports failure anyway.
    let transfer = FakeTransfer(payload: Data("0123456789".utf8), error: Boom(), bytesBeforeThrowing: 10)

    // maximumAttempts: 1 makes this the final (and only) attempt, so there is
    // no next iteration's `alreadyHave >= expectedBytes` check to self-heal
    // the false failure. `download` must not throw.
    _ = try await Downloader(
        transfer: transfer, maximumAttempts: 1, backoff: { _ in .zero }
    ).download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    #expect(try Data(contentsOf: destination) == Data("0123456789".utf8))
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

@Test("the combined worst case across both retry layers stays under a chosen ceiling")
func combinedWorstCaseRetryTimeStaysUnderCeiling() {
    let backoff = Downloader.defaultBackoff
    let maximumAttempts = Downloader.defaultMaximumAttempts
    let maximumDigestAttempts = InstallerPreparer.maximumDigestAttempts

    // One `Downloader.download` call's worst-case backoff: a wait after
    // every failed attempt except the last — same computation as
    // `totalBackoffAcrossDefaultAttemptsIsBounded`, which only covers this
    // one `Downloader` in isolation.
    let perDownloadWait = (1..<maximumAttempts).reduce(Duration.zero) { $0 + backoff($1) }

    // `InstallerPreparer.downloadAndVerify` retries a whole download-and-verify
    // cycle up to `maximumDigestAttempts` times on a recurring digest
    // mismatch, so the two retry layers compound: worst case is
    // `maximumDigestAttempts` full `Downloader` retry cycles, one after
    // another, and `maximumAttempts` transfer attempts within each.
    let combinedWorstCaseWait = perDownloadWait * maximumDigestAttempts
    let combinedWorstCaseAttempts = maximumAttempts * maximumDigestAttempts

    // 15s is chosen as a ceiling comfortably above the 6s (2 x 3s) this
    // produces today — today's two layers compound to double
    // `totalBackoffAcrossDefaultAttemptsIsBounded`'s own 10s ceiling — but
    // well short of a user concluding the tool has hung. A future bump to
    // EITHER `Downloader.defaultMaximumAttempts` or
    // `InstallerPreparer.maximumDigestAttempts` that silently pushed the
    // combined wait past 15s fails here, computed from both named constants
    // rather than from a copied literal.
    #expect(combinedWorstCaseWait < .seconds(15))
    #expect(combinedWorstCaseAttempts == 6)
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
