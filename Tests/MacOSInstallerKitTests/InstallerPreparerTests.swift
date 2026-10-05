import Foundation
import Testing
@testable import MacOSInstallerKit

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private enum StubAssemblerError: Error, Equatable {
    case shouldNotHaveBeenCalled
}

/// Records every call and returns a stubbed result. Mirrors FakeCommandRunner's
/// lock-protected, `@unchecked Sendable` style since `AssemblyStrategy` is
/// invoked from an async context.
private final class FakeAssembler: AssemblyStrategy, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: Result<URL, Error>
    private var recordedInvocations: [(payload: URL, expectedAppName: String)] = []

    init(outcome: Result<URL, Error>) {
        self.outcome = outcome
    }

    var invocations: [(payload: URL, expectedAppName: String)] {
        lock.lock(); defer { lock.unlock() }
        return recordedInvocations
    }

    func assemble(payloadAt payload: URL, expectedAppName: String) throws -> URL {
        lock.lock()
        recordedInvocations.append((payload, expectedAppName))
        lock.unlock()
        return try outcome.get()
    }
}

private func release(
    payload: InstallerRelease.Payload,
    sizeBytes: Int64 = 18_000_000_000,
    digest: String? = nil
) -> InstallerRelease {
    InstallerRelease(
        name: "macOS Tahoe", version: OSVersion("26.7")!, build: "25G229",
        sizeBytes: sizeBytes, origin: .sucatalog, payload: payload, digest: digest
    )
}

@Test("returns a local application unchanged, without downloading or assembling")
func localApplicationPassesThrough() async throws {
    let localPath = URL(fileURLWithPath: "/Applications/Install macOS Tahoe.app")
    let transfer = FakeTransfer(payload: Data())
    let assembler = FakeAssembler(outcome: .failure(StubAssemblerError.shouldNotHaveBeenCalled))
    let preparer = InstallerPreparer(
        downloader: Downloader(transfer: transfer), assembler: assembler
    )

    let app = try await preparer.prepare(release(payload: .localApplication(path: localPath))) { _ in }

    #expect(app == localPath)
    #expect(transfer.offsets.isEmpty)
    #expect(assembler.invocations.isEmpty)
}

@Test("downloads, verifies the published digest, and assembles an installAssistant payload")
func installAssistantDownloadsVerifiesAndAssembles() async throws {
    let cacheDir = try tempDir(); defer { try? FileManager.default.removeItem(at: cacheDir) }
    let payloadBytes = Data("pkg-bytes".utf8)
    let digest = DigestVerifier.sha1Hex(of: payloadBytes)
    let expectedApp = cacheDir.appendingPathComponent("Install macOS Tahoe.app")

    let transfer = FakeTransfer(payload: payloadBytes)
    let assembler = FakeAssembler(outcome: .success(expectedApp))
    let preparer = InstallerPreparer(
        downloader: Downloader(transfer: transfer),
        assembler: assembler,
        cacheDirectory: cacheDir
    )

    final class Box: @unchecked Sendable { var messages: [String] = [] }
    let box = Box()

    let url = URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!
    let app = try await preparer.prepare(
        release(payload: .installAssistant(url: url), sizeBytes: Int64(payloadBytes.count), digest: digest)
    ) { box.messages.append($0) }

    #expect(app == expectedApp)
    #expect(transfer.offsets == [0])
    #expect(assembler.invocations.count == 1)
    #expect(assembler.invocations[0].expectedAppName == "Install macOS Tahoe")
    #expect(box.messages.contains { $0.contains("Checking the download") })
    #expect(box.messages.contains { $0.contains("Installing the macOS installer app") })
}

@Test("skips digest verification when the catalog published none")
func installAssistantWithoutDigestSkipsVerification() async throws {
    let cacheDir = try tempDir(); defer { try? FileManager.default.removeItem(at: cacheDir) }
    let payloadBytes = Data("pkg-bytes".utf8)
    let expectedApp = cacheDir.appendingPathComponent("Install macOS Tahoe.app")

    let transfer = FakeTransfer(payload: payloadBytes)
    let assembler = FakeAssembler(outcome: .success(expectedApp))
    let preparer = InstallerPreparer(
        downloader: Downloader(transfer: transfer),
        assembler: assembler,
        cacheDirectory: cacheDir
    )

    final class Box: @unchecked Sendable { var messages: [String] = [] }
    let box = Box()

    let url = URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!
    _ = try await preparer.prepare(
        release(payload: .installAssistant(url: url), sizeBytes: Int64(payloadBytes.count), digest: nil)
    ) { box.messages.append($0) }

    #expect(!box.messages.contains { $0.contains("Checking the download") })
}

@Test("throws a digest mismatch rather than assembling a corrupted download")
func installAssistantWithWrongDigestFailsBeforeAssembling() async throws {
    let cacheDir = try tempDir(); defer { try? FileManager.default.removeItem(at: cacheDir) }
    let payloadBytes = Data("pkg-bytes".utf8)
    let wrongDigest = String(repeating: "0", count: 40)

    let transfer = FakeTransfer(payload: payloadBytes)
    let assembler = FakeAssembler(outcome: .failure(StubAssemblerError.shouldNotHaveBeenCalled))
    let preparer = InstallerPreparer(
        downloader: Downloader(transfer: transfer),
        assembler: assembler,
        cacheDirectory: cacheDir
    )

    let url = URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!
    await #expect(throws: (any Error).self) {
        _ = try await preparer.prepare(
            release(
                payload: .installAssistant(url: url), sizeBytes: Int64(payloadBytes.count), digest: wrongDigest
            )
        ) { _ in }
    }
    #expect(assembler.invocations.isEmpty)
}

@Test("deletes the cached package when its digest does not match, so a future run re-downloads instead of failing forever")
func digestMismatchDeletesTheCorruptedPackage() async throws {
    let cacheDir = try tempDir(); defer { try? FileManager.default.removeItem(at: cacheDir) }
    let payloadBytes = Data("pkg-bytes".utf8)
    let wrongDigest = String(repeating: "0", count: 40)
    let build = "25G229"
    let expectedPkg = cacheDir.appendingPathComponent("InstallAssistant-\(build).pkg")

    let transfer = FakeTransfer(payload: payloadBytes)
    let assembler = FakeAssembler(outcome: .failure(StubAssemblerError.shouldNotHaveBeenCalled))
    let preparer = InstallerPreparer(
        downloader: Downloader(transfer: transfer),
        assembler: assembler,
        cacheDirectory: cacheDir
    )

    let url = URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!
    await #expect(throws: (any Error).self) {
        _ = try await preparer.prepare(
            release(
                payload: .installAssistant(url: url), sizeBytes: Int64(payloadBytes.count), digest: wrongDigest
            )
        ) { _ in }
    }

    #expect(FileManager.default.fileExists(atPath: expectedPkg.path) == false)
}

@Test("deletes the cached package when its size does not match, so a future run re-downloads instead of failing forever")
func sizeMismatchDeletesTheStalePackage() async throws {
    let cacheDir = try tempDir(); defer { try? FileManager.default.removeItem(at: cacheDir) }
    let build = "25G229"
    let expectedPkg = cacheDir.appendingPathComponent("InstallAssistant-\(build).pkg")
    // Pre-seed the cache with a file whose size already matches what the
    // release claims as `sizeBytes`, but whose transferred payload (below)
    // is a different length, so `Downloader` skips the transfer, re-checks
    // the on-disk size, and throws `sizeMismatch` because the two disagree.
    try Data(repeating: 0, count: 9).write(to: expectedPkg)

    let transfer = FakeTransfer(payload: Data("pkg-bytes".utf8))
    let assembler = FakeAssembler(outcome: .failure(StubAssemblerError.shouldNotHaveBeenCalled))
    let preparer = InstallerPreparer(
        downloader: Downloader(transfer: transfer),
        assembler: assembler,
        cacheDirectory: cacheDir
    )

    let url = URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!
    await #expect(throws: (any Error).self) {
        _ = try await preparer.prepare(
            release(payload: .installAssistant(url: url), sizeBytes: 123)
        ) { _ in }
    }

    #expect(FileManager.default.fileExists(atPath: expectedPkg.path) == false)
}

@Test("re-downloads once on a digest mismatch before giving up")
func reDownloadsOnceOnDigestMismatch() async throws {
    let cacheDir = try tempDir(); defer { try? FileManager.default.removeItem(at: cacheDir) }
    // A transfer that yields corrupt bytes on every attempt: the digest
    // check fails identically each time, so the preparer must make exactly
    // two download attempts (the original plus one re-download) before
    // giving up — never looping indefinitely.
    let payloadBytes = Data("pkg-bytes".utf8)
    let wrongDigest = String(repeating: "0", count: 40)

    let transfer = FakeTransfer(payload: payloadBytes)
    let assembler = FakeAssembler(outcome: .failure(StubAssemblerError.shouldNotHaveBeenCalled))
    let preparer = InstallerPreparer(
        downloader: Downloader(transfer: transfer),
        assembler: assembler,
        cacheDirectory: cacheDir
    )

    let url = URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!
    await #expect(throws: (any Error).self) {
        _ = try await preparer.prepare(
            release(
                payload: .installAssistant(url: url), sizeBytes: Int64(payloadBytes.count), digest: wrongDigest
            )
        ) { _ in }
    }

    // One original transfer plus one re-download, never more: the counter
    // is `transfer.offsets.count`, i.e. how many times the fake's
    // `transfer(from:to:startingAt:progress:)` was actually invoked.
    #expect(transfer.offsets.count == 2)
    #expect(assembler.invocations.isEmpty)
}

@Test("fails clearly, not with a crash, for a legacy ESD payload")
func legacyESDFailsClearly() async throws {
    let transfer = FakeTransfer(payload: Data())
    let assembler = FakeAssembler(outcome: .failure(StubAssemblerError.shouldNotHaveBeenCalled))
    let preparer = InstallerPreparer(downloader: Downloader(transfer: transfer), assembler: assembler)

    await #expect(throws: InstallerPreparationError.legacyAssemblyNotSupported) {
        _ = try await preparer.prepare(release(payload: .legacyESD(urls: []))) { _ in }
    }
    #expect(InstallerPreparationError.legacyAssemblyNotSupported.userMessage.contains("not supported yet"))
}

@Test("tells the user to run softwareupdate --fetch-full-installer for a softwareUpdate payload")
func softwareUpdatePayloadTellsUserToFetchFirst() async throws {
    let transfer = FakeTransfer(payload: Data())
    let assembler = FakeAssembler(outcome: .failure(StubAssemblerError.shouldNotHaveBeenCalled))
    let preparer = InstallerPreparer(downloader: Downloader(transfer: transfer), assembler: assembler)

    await #expect(throws: InstallerPreparationError.softwareUpdateOnly(version: "26.7")) {
        _ = try await preparer.prepare(release(payload: .softwareUpdate(version: "26.7"))) { _ in }
    }
    #expect(
        InstallerPreparationError.softwareUpdateOnly(version: "26.7").userMessage
            .contains("softwareupdate --fetch-full-installer")
    )
}
