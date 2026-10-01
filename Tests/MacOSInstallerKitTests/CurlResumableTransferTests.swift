import Foundation
import Testing
@testable import MacOSInstallerKit

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let remote = URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!

/// A `CommandRunner` that always throws, standing in for a curl binary that
/// cannot be launched at all (as opposed to one that launches and exits
/// non-zero, which `FakeCommandRunner` already covers via its unstubbed-exit
/// -127 default).
private struct ThrowingCommandRunner: CommandRunner, Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        throw CommandError.launchFailed(executable: executable, reason: "no such file")
    }
}

@Test("invokes curl with -- before the URL, passed as argv never shell-joined")
func curlArgvIncludesDoubleDashBeforeURL() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    let fake = FakeCommandRunner()

    // The exact argv curl must receive: CommandRunner takes executable and
    // arguments as a separate string and array, so there is no shell join to
    // misparse in the first place — this pins the array curl actually sees.
    let expectedArguments = [
        "-L", "-C", "-", "--fail", "--output", destination.path, "--", remote.absoluteString,
    ]
    fake.stub(
        CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        for: (["/usr/bin/curl"] + expectedArguments).joined(separator: " ")
    )

    let transfer = CurlResumableTransfer(commandRunner: fake, pollInterval: 0.01)
    try await transfer.transfer(from: remote, to: destination, startingAt: 0) { _ in }

    #expect(fake.invocations.count == 1)
    #expect(fake.invocations.first?.executable == "/usr/bin/curl")
    #expect(fake.invocations.first?.arguments == expectedArguments)
}

@Test("translates a curl launch failure into DownloadError.transferFailed")
func launchFailureBecomesDownloadError() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    let transfer = CurlResumableTransfer(commandRunner: ThrowingCommandRunner(), pollInterval: 0.01)

    do {
        try await transfer.transfer(from: remote, to: destination, startingAt: 0) { _ in }
        Issue.record("expected transfer(from:to:startingAt:progress:) to throw")
    } catch let error as DownloadError {
        guard case .transferFailed = error else {
            Issue.record("expected .transferFailed, got \(error)")
            return
        }
    } catch {
        Issue.record("expected a DownloadError, got \(type(of: error)): \(error)")
    }
}
