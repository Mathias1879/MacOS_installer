import Foundation
import Testing
@testable import MacOSInstallerKit

private let catalogURL = URL(string: "https://swscan.apple.com/test.sucatalog")!
private let distURL = URL(string: "https://swdist.apple.com/x/142-16660.English.dist")!

private func miniCatalogData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/mini-catalog", withExtension: "plist"))
    return try Data(contentsOf: url)
}

private func sequoiaDistData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/sequoia.dist", withExtension: nil))
    return try Data(contentsOf: url)
}

@Test("builds releases by joining catalog products to their distribution files")
func buildsReleasesFromCatalogAndDistributions() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.stub(try miniCatalogData(), for: catalogURL)
    fetcher.stub(try sequoiaDistData(), for: distURL)
    let source = SucatalogSource(
        fetcher: fetcher,
        resolver: CatalogURLResolver(fetcher: fetcher, candidates: [catalogURL])
    )

    let releases = try await source.availableReleases()

    let sequoia = try #require(releases.first { $0.build == "24H23" })
    #expect(sequoia.name == "macOS Sequoia")
    #expect(sequoia.version == OSVersion("15.8"))
    #expect(sequoia.origin == .sucatalog)
    #expect(sequoia.payload == .installAssistant(url: URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!))
}

@Test("skips products whose distribution file cannot be fetched rather than failing wholesale")
func skipsUnfetchableDistributions() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.stub(try miniCatalogData(), for: catalogURL)
    // sequoia .dist is deliberately not stubbed, and the legacy one never is.
    let source = SucatalogSource(
        fetcher: fetcher,
        resolver: CatalogURLResolver(fetcher: fetcher, candidates: [catalogURL])
    )

    let releases = try await source.availableReleases()

    #expect(releases.isEmpty)
}

@Test("reports its origin as sucatalog")
func reportsOrigin() {
    let fetcher = FakeDataFetcher()
    let source = SucatalogSource(
        fetcher: fetcher,
        resolver: CatalogURLResolver(fetcher: fetcher, candidates: [catalogURL])
    )

    #expect(source.origin == .sucatalog)
}
