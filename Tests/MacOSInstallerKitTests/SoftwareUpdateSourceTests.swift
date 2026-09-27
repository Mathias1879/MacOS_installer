import Foundation
import Testing
@testable import MacOSInstallerKit

private let realOutput = """
Finding available software
Software Update found the following full installers:
* Title: macOS 27 Golden Gate, Version: 27.0, Size: 17969056KiB, Build: 26A428, Deferred: NO
* Title: macOS Tahoe, Version: 26.7, Size: 17951133KiB, Build: 25G229, Deferred: NO
* Title: macOS Sequoia, Version: 15.8, Size: 15296950KiB, Build: 24H23, Deferred: NO
"""

@Test("parses Apple's full-installer listing into releases")
func parsesFullInstallerListing() async throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: realOutput, for: "/usr/sbin/softwareupdate --list-full-installers")
    let source = SoftwareUpdateSource(runner: runner)

    let releases = try await source.availableReleases()

    #expect(releases.count == 3)
    #expect(releases.map(\.build) == ["26A428", "25G229", "24H23"])
    let tahoe = try #require(releases.first { $0.build == "25G229" })
    #expect(tahoe.name == "macOS Tahoe")
    #expect(tahoe.version == OSVersion("26.7"))
    #expect(tahoe.origin == .softwareUpdate)
    #expect(tahoe.payload == .softwareUpdate(version: "26.7"))
    let goldenGate = try #require(releases.first { $0.build == "26A428" })
    #expect(goldenGate.name == "macOS 27 Golden Gate")
}

@Test("converts the KiB size field to bytes")
func convertsKibibytesToBytes() async throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: realOutput, for: "/usr/sbin/softwareupdate --list-full-installers")
    let source = SoftwareUpdateSource(runner: runner)

    let releases = try await source.availableReleases()
    let sequoia = try #require(releases.first { $0.build == "24H23" })

    #expect(sequoia.sizeBytes == 15_296_950 * 1024)
}

@Test("returns empty rather than throwing when no installers are offered")
func returnsEmptyWhenNothingOffered() async throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: "Finding available software\n", for: "/usr/sbin/softwareupdate --list-full-installers")
    let source = SoftwareUpdateSource(runner: runner)

    #expect(try await source.availableReleases().isEmpty)
}

@Test("ignores malformed lines instead of aborting the listing")
func ignoresMalformedLines() async throws {
    let output = """
    Software Update found the following full installers:
    * Title: macOS Tahoe, Version: 26.7, Size: 17951133KiB, Build: 25G229, Deferred: NO
    * Title: broken line with no fields
    """
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: output, for: "/usr/sbin/softwareupdate --list-full-installers")
    let source = SoftwareUpdateSource(runner: runner)

    let releases = try await source.availableReleases()
    #expect(releases.count == 1)
    #expect(releases.first?.build == "25G229")
}

@Test("throws when the command exits non-zero, carrying exit code and stderr")
func throwsOnNonZeroExit() async throws {
    let runner = FakeCommandRunner()
    runner.stub(
        CommandResult(exitCode: 1, standardOutput: "", standardError: "some failure"),
        for: "/usr/sbin/softwareupdate --list-full-installers"
    )
    let source = SoftwareUpdateSource(runner: runner)

    await #expect(throws: SoftwareUpdateSourceError.commandFailed(exitCode: 1, message: "some failure")) {
        try await source.availableReleases()
    }
}

@Test("returns empty, not throws, when exit is zero with no installers listed")
func returnsEmptyOnZeroExitWithNoInstallers() async throws {
    let runner = FakeCommandRunner()
    runner.stub(
        CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        for: "/usr/sbin/softwareupdate --list-full-installers"
    )
    let source = SoftwareUpdateSource(runner: runner)

    #expect(try await source.availableReleases().isEmpty)
}

@Test("skips a line whose Size field is missing rather than reporting zero bytes")
func skipsLineWithMissingSize() async throws {
    let output = """
    Software Update found the following full installers:
    * Title: macOS Tahoe, Version: 26.7, Build: 25G229, Deferred: NO
    """
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: output, for: "/usr/sbin/softwareupdate --list-full-installers")
    let source = SoftwareUpdateSource(runner: runner)

    #expect(try await source.availableReleases().isEmpty)
}
