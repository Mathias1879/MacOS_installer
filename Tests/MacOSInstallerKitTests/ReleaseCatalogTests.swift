import Foundation
import Testing
@testable import MacOSInstallerKit

private struct StubSource: InstallerSource {
    let origin: InstallerRelease.Origin
    let releases: [InstallerRelease]
    var error: (any Error)?

    func availableReleases() async throws -> [InstallerRelease] {
        if let error { throw error }
        return releases
    }
}

private func release(
    _ version: String,
    build: String,
    origin: InstallerRelease.Origin
) throws -> InstallerRelease {
    InstallerRelease(
        name: "macOS Test",
        version: try #require(OSVersion(version)),
        build: build,
        sizeBytes: 1000,
        origin: origin,
        payload: .softwareUpdate(version: version)
    )
}

@Test("prefers the local copy when two sources offer the same build")
func localWinsOverCatalog() async throws {
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .sucatalog, releases: [try release("26.7", build: "25G229", origin: .sucatalog)]),
        StubSource(origin: .local, releases: [try release("26.7", build: "25G229", origin: .local)]),
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.count == 1)
    #expect(result.releases.first?.origin == .local)
}

@Test("prefers the catalog over software update for the same build")
func catalogWinsOverSoftwareUpdate() async throws {
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .softwareUpdate, releases: [try release("26.7", build: "25G229", origin: .softwareUpdate)]),
        StubSource(origin: .sucatalog, releases: [try release("26.7", build: "25G229", origin: .sucatalog)]),
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.first?.origin == .sucatalog)
}

@Test("keeps distinct builds of the same version separate")
func keepsDistinctBuilds() async throws {
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .sucatalog, releases: [
            try release("26.7", build: "25G229", origin: .sucatalog),
            try release("26.7", build: "25G230", origin: .sucatalog),
        ])
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.map(\.build) == ["25G230", "25G229"])
}

@Test("excludes versions below the Mojave floor")
func excludesBelowMinimumVersion() async throws {
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .sucatalog, releases: [
            try release("10.13.6", build: "17G66", origin: .sucatalog),
            try release("10.14.6", build: "18G103", origin: .sucatalog),
        ])
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.map(\.build) == ["18G103"])
}

@Test("includes a release at exactly the Mojave floor and excludes anything below it")
func includesExactFloorExcludesBelow() async throws {
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .sucatalog, releases: [
            try release("10.13.6", build: "17G66", origin: .sucatalog),
            try release("10.14",   build: "18A391", origin: .sucatalog),
            try release("10.14.6", build: "18G103", origin: .sucatalog),
        ])
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.map(\.build) == ["18G103", "18A391"])
}

@Test("records a source failure without losing the other sources' results")
func oneFailingSourceDoesNotLoseOthers() async throws {
    struct Boom: Error {}
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .sucatalog, releases: [], error: Boom()),
        StubSource(origin: .local, releases: [try release("26.7", build: "25G229", origin: .local)]),
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.count == 1)
    #expect(result.failures.count == 1)
}

@Test("sorts newest version first")
func sortsNewestFirst() async throws {
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .sucatalog, releases: [
            try release("15.8", build: "24H23", origin: .sucatalog),
            try release("27.0", build: "26A428", origin: .sucatalog),
            try release("26.7", build: "25G229", origin: .sucatalog),
        ])
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.map { $0.version.description } == ["27.0", "26.7", "15.8"])
}
