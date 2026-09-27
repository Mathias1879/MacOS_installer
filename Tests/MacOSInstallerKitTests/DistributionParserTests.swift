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

@Test("throws when the title element is absent")
func throwsOnMissingTitle() throws {
    let data = try fixture("no-title.dist")

    #expect(throws: DistributionParseError.missingTitle) {
        try DistributionParser.parse(data)
    }
}

@Test("throws when the build key is absent from auxinfo")
func throwsOnMissingBuild() throws {
    let data = try fixture("no-build.dist")

    #expect(throws: DistributionParseError.missingBuild) {
        try DistributionParser.parse(data)
    }
}

@Test("throws when the version value cannot be parsed as an OSVersion")
func throwsOnUnparsableVersion() throws {
    let data = try fixture("bad-version.dist")

    #expect(throws: DistributionParseError.unparsableVersion("Tahoe")) {
        try DistributionParser.parse(data)
    }
}

@Test("uses document-level title and ignores title inside auxinfo")
func ignoresTitleInsideAuxInfo() throws {
    let info = try DistributionParser.parse(fixture("title-in-auxinfo.dist"))

    // The fixture places the nested title BEFORE the document-level title.
    // WITHOUT the `where !inAuxInfo` guard, the first title encountered
    // (from inside auxinfo) would be captured, and the nil-check would
    // prevent the correct document-level title from overwriting it.
    // This ordering makes the test guard-dependent.
    #expect(info.title == "macOS Sequoia")
}

@Test("clears pending key when encountering unexpected element type, preventing mis-pairing")
func doesNotMisPairKeyWithWrongValue() throws {
    let data = try fixture("version-with-intervening-integer.dist")

    // The VERSION key should not pair with the "11.0" string that comes after <integer>.
    // Instead, the parser should fail to find VERSION (since <integer> clears pendingKey).
    #expect(throws: DistributionParseError.missingVersion) {
        try DistributionParser.parse(data)
    }
}
