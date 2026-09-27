import Foundation
import Testing
@testable import MacOSInstallerKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

@Test("extracts title, version and build from a real distribution file")
func parsesRealDistribution() throws {
    let info = try DistributionParser.parse(fixture("sequoia.dist"))

    #expect(info.title == "macOS Sequoia")
    #expect(info.build == "24H23")
    #expect(info.version == OSVersion("15.8"))
}

@Test("throws when the version key is absent rather than inventing one")
func throwsOnMissingVersion() throws {
    let data = try fixture("no-version.dist")

    #expect(throws: DistributionParseError.missingVersion) {
        try DistributionParser.parse(data)
    }
}

@Test("throws on data that is not XML at all")
func throwsOnGarbage() {
    let data = Data("not xml".utf8)

    #expect(throws: (any Error).self) {
        try DistributionParser.parse(data)
    }
}
