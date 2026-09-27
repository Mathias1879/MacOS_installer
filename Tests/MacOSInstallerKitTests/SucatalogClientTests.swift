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

@Test("reports notAPropertyList for data that is not a property list at all")
func throwsNotAPropertyListOnGarbage() {
    #expect(throws: SucatalogParseError.notAPropertyList) {
        try SucatalogClient.parse(Data("nonsense".utf8))
    }
}

@Test("reports missingProductsDictionary for a valid plist with no Products key")
func throwsMissingProductsForValidPlistWithoutProducts() throws {
    let plist: [String: Any] = ["CatalogVersion": 2, "ApplePostURL": "https://example.invalid"]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

    #expect(throws: SucatalogParseError.missingProductsDictionary) {
        try SucatalogClient.parse(data)
    }
}

@Test("sums totalSize across all packages of a legacy product with two packages")
func sumsLegacyTotalSizeAcrossTwoPackages() throws {
    let plist: [String: Any] = ["Products": [
        "999-00002": [
            "PostDate": Date(timeIntervalSince1970: 0),
            "Packages": [
                ["URL": "https://swcdn.apple.com/x/BaseSystem.pkg", "Size": 100],
                ["URL": "https://swcdn.apple.com/x/InstallESDDmg.pkg", "Size": 200],
            ],
        ]
    ]]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

    let products = try SucatalogClient.parse(data)
    let legacy = try #require(products.first { $0.identifier == "999-00002" })

    #expect(legacy.kind == .legacyESD)
    #expect(legacy.totalSize == 300)
}

@Test("drops a package whose Size is missing rather than reporting it as zero bytes")
func dropsPackageWithMissingSize() throws {
    let plist: [String: Any] = ["Products": [
        "999-00001": [
            "PostDate": Date(timeIntervalSince1970: 0),
            "Packages": [["URL": "https://swcdn.apple.com/x/InstallAssistant.pkg"]],
        ]
    ]]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

    let products = try SucatalogClient.parse(data)

    // The sole package is unusable, so the product is not an installer at all.
    #expect(products.isEmpty)
}
