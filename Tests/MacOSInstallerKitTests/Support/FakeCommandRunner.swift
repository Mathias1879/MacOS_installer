import Foundation
@testable import MacOSInstallerKit

/// Records every invocation and returns stubbed results. The recording is what
/// lets tests assert that a destructive command was *not* issued.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var stubs: [String: CommandResult] = [:]
    private var throwErrors: [String: Error] = [:]
    private(set) var invocations: [(executable: String, arguments: [String])] = []

    /// Stub by the full command line, e.g. "/usr/sbin/softwareupdate --list-full-installers".
    func stub(_ result: CommandResult, for commandLine: String) {
        lock.lock(); defer { lock.unlock() }
        stubs[commandLine] = result
    }

    func stub(standardOutput: String, for commandLine: String) {
        stub(
            CommandResult(exitCode: 0, standardOutput: standardOutput, standardError: ""),
            for: commandLine
        )
    }

    /// Makes `run` throw `error` for this exact command line, instead of
    /// returning a stubbed result — standing in for a command that never
    /// launched at all (e.g. `Process.run()` itself failing), as opposed to
    /// one that launched and exited non-zero.
    func throwError(_ error: Error, for commandLine: String) {
        lock.lock(); defer { lock.unlock() }
        throwErrors[commandLine] = error
    }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        invocations.append((executable, arguments))
        let key = ([executable] + arguments).joined(separator: " ")
        if let error = throwErrors[key] {
            throw error
        }
        return stubs[key] ?? CommandResult(
            exitCode: 127,
            standardOutput: "",
            standardError: "FakeCommandRunner: unstubbed command '\(key)'. "
                + "Stub it explicitly — a silent success here would let a test "
                + "believe a destructive command succeeded when it never ran."
        )
    }

    /// True if any invocation's command line contains `fragment`.
    func didInvoke(containing fragment: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return invocations.contains { ([$0.executable] + $0.arguments).joined(separator: " ").contains(fragment) }
    }
}
