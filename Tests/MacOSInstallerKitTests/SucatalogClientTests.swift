import Foundation
import Testing
@testable import MacOSInstallerKit

private func catalogFixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/mini-catalog", withExtension: "plist"))
    return try Data(contentsOf: url)
}

@Test("keeps only products that carry an installer payload")
func filtersToInstallerProducts() throws {
    let products = try SucatalogClient.parse(catalogFixture())

    let identifiers = Set(products.map(\.identifier))
    #expect(identifiers == ["142-16660", "061-26578"])
}

@Test("classifies modern and legacy products by payload shape")
func classifiesProductKind() throws {
    let products = try SucatalogClient.parse(catalogFixture())
    let modern = try #require(products.first { $0.identifier == "142-16660" })
    let legacy = try #require(products.first { $0.identifier == "061-26578" })

    #expect(modern.kind == .installAssistant)
    #expect(modern.installAssistantURL?.lastPathComponent == "InstallAssistant.pkg")
    #expect(legacy.kind == .legacyESD)
    #expect(legacy.legacyESDURLs.count == 2)
}

@Test("carries the English distribution URL and total payload size")
func carriesDistributionAndSize() throws {
    let products = try SucatalogClient.parse(catalogFixture())
    let modern = try #require(products.first { $0.identifier == "142-16660" })

    #expect(modern.distributionURL?.absoluteString == "https://swdist.apple.com/x/142-16660.English.dist")
    #expect(modern.totalSize == 15_296_950_272)
}

@Test("throws when the payload is not a property list")
func throwsOnNonPlist() {
    #expect(throws: (any Error).self) {
        try SucatalogClient.parse(Data("nonsense".utf8))
    }
}
