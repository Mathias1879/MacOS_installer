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

    await #expect(throws: DownloadError.sizeMismatch(expected: 10, actual: 4)) {
        _ = try await Downloader(transfer: transfer)
            .download(from: remote, to: destination, expectedBytes: 10) { _, _ in }
    }
}

@Test("reports cumulative progress against the expected total")
func reportsProgress() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("01234".utf8).write(to: destination)
    let transfer = FakeTransfer(payload: Data("0123456789".utf8))

    final class Box: @unchecked Sendable { var seen: [(Int64, Int64)] = [] }
    let box = Box()

    _ = try await Downloader(transfer: transfer)
        .download(from: remote, to: destination, expectedBytes: 10) { done, total in
            box.seen.append((done, total))
        }

    // Progress must account for the 5 bytes already on disk, not just the 5 transferred.
    #expect(box.seen.last?.0 == 10)
    #expect(box.seen.last?.1 == 10)
}
