import Testing
@testable import MacOSInstallerKit

@Test("captures stdout and a zero exit code from a real process")
func realRunnerCapturesStandardOutput() throws {
    let runner = RealCommandRunner()

    let result = try runner.run("/bin/echo", ["hello"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
}

@Test("reports a non-zero exit code without throwing")
func realRunnerReportsFailureExitCode() throws {
    let runner = RealCommandRunner()

    let result = try runner.run("/usr/bin/false", [])

    #expect(result.exitCode != 0)
}

@Test("drains both pipes concurrently, so a child that floods stderr cannot deadlock")
func doesNotDeadlockWhenChildFloodsStderr() throws {
    let runner = RealCommandRunner()

    // 300 KB to stderr — far beyond the ~64 KB pipe buffer. Under a
    // sequential read of stdout-then-stderr this never returns.
    let result = try runner.run("/bin/sh", [
        "-c", "head -c 300000 /dev/zero | tr '\\0' 'x' >&2; echo done",
    ])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("done"))
    #expect(result.standardError.count == 300_000)
}
