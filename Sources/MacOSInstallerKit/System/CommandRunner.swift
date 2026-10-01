import Foundation

/// The outcome of a subprocess invocation.
public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum CommandError: Error, Equatable {
    case launchFailed(executable: String, reason: String)
}

/// Every subprocess in this library goes through this protocol so tests can
/// substitute a recording fake. Nothing outside `RealCommandRunner` may use
/// `Foundation.Process` directly.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
}

/// Lock-protected holder for bytes read on a background queue. The Swift 6
/// compiler cannot see that `NSLock` makes a captured `var` safe to mutate
/// from a concurrent closure, so the mutable state is isolated inside an
/// `@unchecked Sendable` box instead — the same pattern already used for
/// recording fakes elsewhere in this codebase (e.g. `FakeCommandRunner`).
private final class PipeDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) {
        lock.withLock { value = data }
    }

    var current: Data {
        lock.withLock { value }
    }
}

public struct RealCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(
                executable: executable,
                reason: error.localizedDescription
            )
        }

        // Both pipes must be drained concurrently. Reading one to EOF before
        // touching the other deadlocks any child that fills the ~64 KB buffer
        // of the unread pipe — curl's progress meter does so in ~10 minutes,
        // and createinstallmedia can do so mid-erase.
        let group = DispatchGroup()
        let outBox = PipeDataBox()
        let errBox = PipeDataBox()

        group.enter()
        DispatchQueue.global().async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outBox.current, as: UTF8.self),
            standardError: String(decoding: errBox.current, as: UTF8.self)
        )
    }
}
