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

@Test("values that compare equal also hash equal, so Set and Dictionary dedupe correctly")
func hashingAgreesWithEquality() throws {
    let short = try #require(OSVersion("15.8"))
    let padded = try #require(OSVersion("15.8.0"))
    let doublePadded = try #require(OSVersion("15.8.0.0"))

    #expect(short == padded)
    #expect(short.hashValue == padded.hashValue)

    // The property that actually matters downstream: equal versions
    // collapse to one entry.
    #expect(Set([short, padded, doublePadded]).count == 1)
    #expect(Set([short, try #require(OSVersion("15.8.1"))]).count == 2)

    var counts: [OSVersion: Int] = [:]
    counts[short, default: 0] += 1
    counts[padded, default: 0] += 1
    #expect(counts.count == 1)
    #expect(counts[doublePadded] == 2)
}

@Test("zero versions normalize consistently")
func zeroVersionsHashConsistently() throws {
    let zero = try #require(OSVersion("0"))
    let zeroZero = try #require(OSVersion("0.0"))

    #expect(zero == zeroZero)
    #expect(Set([zero, zeroZero]).count == 1)
}

@Test("rejects negative components")
func rejectsNegativeComponents() {
    #expect(OSVersion("-1") == nil)
    #expect(OSVersion("15.-8") == nil)
}

@Test("major reports the leading component")
func majorReportsLeadingComponent() throws {
    #expect(try #require(OSVersion("10.14.6")).major == 10)
    #expect(try #require(OSVersion("26.7")).major == 26)
}
