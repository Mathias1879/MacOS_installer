import Foundation
import Testing
@testable import MacOSInstallerKit

private func release(
    _ name: String,
    _ version: String,
    _ build: String,
    _ size: Int64,
    _ origin: InstallerRelease.Origin,
    payload: InstallerRelease.Payload? = nil
) throws -> InstallerRelease {
    InstallerRelease(
        name: name,
        version: try #require(OSVersion(version)),
        build: build,
        sizeBytes: size,
        origin: origin,
        payload: payload ?? .softwareUpdate(version: version)
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

// MARK: - C3: unusable rows are marked, not just silently offered

@Test("marks a softwareUpdate-payload release as not directly usable")
func marksSoftwareUpdatePayloadAsUnusable() throws {
    let output = ReleaseTableFormatter.render([
        try release(
            "macOS Tahoe", "26.7", "25G229", 18_381_960_192, .softwareUpdate,
            payload: .softwareUpdate(version: "26.7")
        )
    ])

    #expect(output.contains("cannot be used directly"))
    #expect(output.contains("softwareupdate --fetch-full-installer"))
}

@Test("marks a legacyESD-payload release as not supported yet")
func marksLegacyESDPayloadAsUnusable() throws {
    let output = ReleaseTableFormatter.render([
        try release("macOS Catalina", "10.15", "19G2021", 8_000_000_000, .sucatalog, payload: .legacyESD(urls: []))
    ])

    #expect(output.contains("not supported yet"))
}

@Test("does not mark a usable release with any unusable note")
func doesNotMarkUsableReleases() throws {
    let url = URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!
    let output = ReleaseTableFormatter.render([
        try release(
            "macOS Tahoe", "26.7", "25G229", 18_381_960_192, .sucatalog,
            payload: .installAssistant(url: url)
        ),
        try release(
            "macOS Sequoia", "15.8", "24H23", 15_663_996_928, .local,
            payload: .localApplication(path: URL(fileURLWithPath: "/Applications/Install macOS Sequoia.app"))
        ),
    ])

    #expect(output.contains("cannot be used directly") == false)
    #expect(output.contains("not supported yet") == false)
}
