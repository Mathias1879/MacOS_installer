import Foundation
import Testing
@testable import MacOSInstallerKit

private func release(
    _ name: String,
    _ version: String,
    _ build: String,
    _ size: Int64,
    _ origin: InstallerRelease.Origin
) throws -> InstallerRelease {
    InstallerRelease(
        name: name,
        version: try #require(OSVersion(version)),
        build: build,
        sizeBytes: size,
        origin: origin,
        payload: .softwareUpdate(version: version)
    )
}

@Test("renders a header and one aligned row per release")
func rendersAlignedTable() throws {
    let output = ReleaseTableFormatter.render([
        try release("macOS Tahoe", "26.7", "25G229", 18_381_960_192, .sucatalog),
        try release("macOS Sequoia", "15.8", "24H23", 15_663_996_928, .local),
    ])

    let lines = output.split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    #expect(lines[0].contains("VERSION"))
    #expect(lines[1].contains("macOS Tahoe"))
    #expect(lines[1].contains("26.7"))
    #expect(lines[1].contains("25G229"))
    #expect(lines[2].contains("macOS Sequoia"))
}

@Test("marks a locally available release so no download is implied")
func marksLocalReleases() throws {
    let output = ReleaseTableFormatter.render([
        try release("macOS Sequoia", "15.8", "24H23", 15_663_996_928, .local)
    ])

    #expect(output.contains("on disk"))
}

@Test("renders a clear message for an empty list")
func rendersEmptyMessage() {
    #expect(ReleaseTableFormatter.render([]).contains("No macOS installers"))
}
