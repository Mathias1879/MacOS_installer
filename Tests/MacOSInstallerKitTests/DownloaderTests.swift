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
