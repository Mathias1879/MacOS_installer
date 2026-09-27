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
    let tahoe = try #require(releases.first { $0.build == "25G229" })
    #expect(tahoe.name == "macOS Tahoe")
    #expect(tahoe.version == OSVersion("26.7"))
    #expect(tahoe.origin == .softwareUpdate)
    #expect(tahoe.payload == .softwareUpdate(version: "26.7"))
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

    #expect(try await source.availableReleases().count == 1)
}
