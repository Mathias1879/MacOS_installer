import Foundation
import Testing
@testable import MacOSInstallerKit

private func makeRelease(
    name: String = "macOS Tahoe",
    version: String = "26.7",
    build: String = "25G229",
    sizeBytes: Int64 = 18_381_960_192,
    origin: InstallerRelease.Origin = .sucatalog
) throws -> InstallerRelease {
    InstallerRelease(
        name: name,
        version: try #require(OSVersion(version)),
        build: build,
        sizeBytes: sizeBytes,
        origin: origin,
        payload: .installAssistant(url: URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!)
    )
}

@Test("identity is version plus build, ignoring origin")
func identityIgnoresOrigin() throws {
    let fromCatalog = try makeRelease(origin: .sucatalog)
    let fromLocal = try makeRelease(origin: .local)

    #expect(fromCatalog.identity == fromLocal.identity)
}

@Test("origin precedence ranks local above catalog above software update")
func originPrecedence() {
    #expect(InstallerRelease.Origin.local > InstallerRelease.Origin.sucatalog)
    #expect(InstallerRelease.Origin.sucatalog > InstallerRelease.Origin.softwareUpdate)
}

@Test("versions below Big Sur require legacy assembly")
func legacyAssemblyThreshold() throws {
    #expect(try makeRelease(version: "10.14.6").requiresLegacyAssembly)
    #expect(try makeRelease(version: "10.15.7").requiresLegacyAssembly)
    #expect(try makeRelease(version: "11.7.10").requiresLegacyAssembly == false)
    #expect(try makeRelease(version: "26.7").requiresLegacyAssembly == false)
}

@Test("display size is rendered in gigabytes with one decimal")
func displaySizeInGigabytes() throws {
    let release = try makeRelease(sizeBytes: 18_381_960_192)

    #expect(release.displaySize == "18.4 GB")
}
