import Testing
@testable import MacOSInstallerKit

@Test("parses a dotted version into integer components")
func parsesDottedVersion() throws {
    let version = try #require(OSVersion("10.14.6"))

    #expect(version.components == [10, 14, 6])
    #expect(version.description == "10.14.6")
}

@Test("rejects a version containing non-numeric components")
func rejectsNonNumericVersion() {
    #expect(OSVersion("Tahoe") == nil)
    #expect(OSVersion("") == nil)
    #expect(OSVersion("26.beta") == nil)
}

@Test("orders versions numerically, not lexically")
func ordersNumerically() throws {
    let mojave = try #require(OSVersion("10.14.6"))
    let sequoia = try #require(OSVersion("15.8"))
    let tahoe = try #require(OSVersion("26.7"))

    #expect(mojave < sequoia)
    #expect(sequoia < tahoe)
    // The case string comparison gets wrong:
    #expect(try #require(OSVersion("26.9")) < #require(OSVersion("26.10")))
}

@Test("treats missing trailing components as zero")
func treatsMissingComponentsAsZero() throws {
    #expect(try #require(OSVersion("15.8")) == #require(OSVersion("15.8.0")))
    #expect(try #require(OSVersion("15.8")) < #require(OSVersion("15.8.1")))
}
