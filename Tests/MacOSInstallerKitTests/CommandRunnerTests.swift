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
