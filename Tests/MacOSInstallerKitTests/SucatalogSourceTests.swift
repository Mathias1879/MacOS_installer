import Foundation
import Testing
@testable import MacOSInstallerKit

private let catalogURL = URL(string: "https://swscan.apple.com/test.sucatalog")!
private let distURL = URL(string: "https://swdist.apple.com/x/142-16660.English.dist")!
private let legacyDistURL = URL(string: "https://swdist.apple.com/x/061-26578.English.dist")!

private func miniCatalogData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/mini-catalog", withExtension: "plist"))
    return try Data(contentsOf: url)
}

private func sequoiaDistData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/sequoia.dist", withExtension: nil))
    return try Data(contentsOf: url)
}

/// Hand-built (not a fixture file) `.dist` payload for an older release, used
/// to prove the join produces more than one release and that they sort
/// correctly by version, not just that the newest one parses.
private func catalinaDistData() -> Data {
    Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <installer-gui-script minSpecVersion="2">
        <pkg-ref id="MajorOSInfo" packageIdentifier="com.apple.pkg.MajorOSInfo"/>
        <title>macOS Catalina</title>
        <options customize="never" require-scripts="false"/>
        <auxinfo>
            <dict>
                <key>BUILD</key>
                <string>19H15</string>
                <key>VERSION</key>
                <string>10.15.7</string>
            </dict>
        </auxinfo>
    </installer-gui-script>
    """.utf8)
}

/// Builds catalog plist data from scratch, so a test can shape products in
/// ways the shared `mini-catalog` fixture does not (e.g. a product missing
/// its `Distributions` key entirely).
private func catalogData(products: [String: [String: Any]]) throws -> Data {
    let root: [String: Any] = ["Products": products]
    return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
}

@Test("builds releases by joining catalog products to their distribution files, sorted newest first")
func buildsReleasesFromCatalogAndDistributions() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.stub(try miniCatalogData(), for: catalogURL)
    fetcher.stub(try sequoiaDistData(), for: distURL)
    fetcher.stub(catalinaDistData(), for: legacyDistURL)
    let source = SucatalogSource(
        fetcher: fetcher,
        resolver: CatalogURLResolver(fetcher: fetcher, candidates: [catalogURL])
    )

    let releases = try await source.availableReleases()

    // Assert the full ordered array: an assertion on `.first` alone would
    // still pass under a reversed or deleted sort comparator.
    #expect(releases.map { $0.version.description } == ["15.8", "10.15.7"])

    let sequoia = try #require(releases.first { $0.build == "24H23" })
    #expect(sequoia.name == "macOS Sequoia")
    #expect(sequoia.version == OSVersion("15.8"))
    #expect(sequoia.origin == .sucatalog)
    #expect(sequoia.payload == .installAssistant(url: URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!))
    #expect(sequoia.digest == "01e1be1b5ea751633fdeb70c3824e56b76d2cf1a")

    let catalina = try #require(releases.first { $0.build == "19H15" })
    #expect(catalina.name == "macOS Catalina")
    #expect(catalina.version == OSVersion("10.15.7"))
    // The legacy product has no Digest in the catalog, and that must survive
    // the whole product -> release path, not just the package parse.
    #expect(catalina.digest == nil)
}

@Test("throws when every catalog product's distribution is unavailable")
func throwsWhenAllDistributionsUnavailable() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.stub(try miniCatalogData(), for: catalogURL)
    // Neither the InstallAssistant .dist nor the legacyESD .dist is stubbed,
    // so every installer-kind product in the mini catalog is unreachable.
    let source = SucatalogSource(
        fetcher: fetcher,
        resolver: CatalogURLResolver(fetcher: fetcher, candidates: [catalogURL])
    )

    await #expect(throws: SucatalogSourceError.allDistributionsUnavailable(productCount: 2)) {
        try await source.availableReleases()
    }
}

@Test("keeps the releases it could build when only some distributions fail")
func partialDistributionFailureKeepsSurvivors() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.stub(try miniCatalogData(), for: catalogURL)
    fetcher.stub(try sequoiaDistData(), for: distURL)
    // legacyDistURL is deliberately left unstubbed.
    let source = SucatalogSource(
        fetcher: fetcher,
        resolver: CatalogURLResolver(fetcher: fetcher, candidates: [catalogURL])
    )

    let releases = try await source.availableReleases()

    #expect(releases.count == 1)
    #expect(releases.first?.build == "24H23")
}

@Test("drops a product whose distribution file was fetched but is not parsable")
func dropsProductWithMalformedDistribution() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.stub(try miniCatalogData(), for: catalogURL)
    // Successfully "fetched" but not XML at all, exercising the
    // `try? DistributionParser.parse` failure path rather than a 404.
    fetcher.stub(Data("not xml".utf8), for: distURL)
    fetcher.stub(catalinaDistData(), for: legacyDistURL)
    let source = SucatalogSource(
        fetcher: fetcher,
        resolver: CatalogURLResolver(fetcher: fetcher, candidates: [catalogURL])
    )

    let releases = try await source.availableReleases()

    #expect(releases.count == 1)
    #expect(releases.first?.build == "19H15")
}

@Test("drops a product with no distribution URL rather than fetching one")
func dropsProductWithNoDistributionsKey() async throws {
    let fetcher = FakeDataFetcher()
    let data = try catalogData(products: [
        "142-16660": [
            "PostDate": Date(timeIntervalSince1970: 0),
            "Distributions": ["English": distURL.absoluteString],
            "Packages": [
                [
                    "URL": "https://swcdn.apple.com/x/InstallAssistant.pkg",
                    "Size": 15_296_950_272,
                ] as [String: Any],
            ],
        ],
        "999-00000": [
            "PostDate": Date(timeIntervalSince1970: 0),
            // No "Distributions" key at all.
            "Packages": [
                [
                    "URL": "https://swcdn.apple.com/x/InstallAssistant.pkg",
                    "Size": 15_296_950_272,
                ] as [String: Any],
            ],
        ],
    ])
    fetcher.stub(data, for: catalogURL)
    fetcher.stub(try sequoiaDistData(), for: distURL)
    let source = SucatalogSource(
        fetcher: fetcher,
        resolver: CatalogURLResolver(fetcher: fetcher, candidates: [catalogURL])
    )

    let releases = try await source.availableReleases()

    #expect(releases.count == 1)
    #expect(releases.first?.build == "24H23")
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
