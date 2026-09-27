import Foundation
import Testing
@testable import MacOSInstallerKit

/// Builds a minimal directory that looks like an installer app.
private func makeInstallerApp(
    in directory: URL,
    displayName: String,
    version: String,
    build: String
) throws -> URL {
    let app = directory.appendingPathComponent("\(displayName).app")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

    let info: [String: Any] = [
        "CFBundleDisplayName": displayName,
        "DTPlatformVersion": version,
        "DTSDKBuild": build,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return app
}

@Test("discovers installer applications in the search directories")
func discoversInstallerApps() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let app = try makeInstallerApp(in: root, displayName: "Install macOS Tahoe", version: "26.7", build: "25G229")
    let source = LocalInstallerSource(searchDirectories: [root])

    let releases = try await source.availableReleases()

    #expect(releases.count == 1)
    let release = try #require(releases.first)
    #expect(release.name == "Install macOS Tahoe")
    #expect(release.version == OSVersion("26.7"))
    #expect(release.build == "25G229")
    #expect(release.origin == .local)
    // Normalize path the same way the implementation does
    let normalizedPath = app.path.hasSuffix("/") ? String(app.path.dropLast()) : app.path
    #expect(release.payload == .localApplication(path: URL(fileURLWithPath: normalizedPath)))
}

@Test("ignores applications that are not macOS installers")
func ignoresNonInstallerApps() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try makeInstallerApp(in: root, displayName: "Safari", version: "26.7", build: "25G229")
    let source = LocalInstallerSource(searchDirectories: [root])

    #expect(try await source.availableReleases().isEmpty)
}

@Test("returns empty for a directory that does not exist")
func returnsEmptyForMissingDirectory() async throws {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let source = LocalInstallerSource(searchDirectories: [missing])

    #expect(try await source.availableReleases().isEmpty)
}

@Test("skips installer apps with computed size of 0")
func skipsInstallerAppsWithZeroSize() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Create an app bundle directory with no files (traversal will sum to 0)
    // This simulates a bundle that is unreadable or corrupted
    let app = root.appendingPathComponent("Install macOS Sonoma.app")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    // No Info.plist is created, so allocatedSize will return 0

    let source = LocalInstallerSource(searchDirectories: [root])
    let releases = try await source.availableReleases()

    #expect(releases.isEmpty)
}

@Test("sorts releases by version, newest first")
func sortsReleasesByVersionNewestFirst() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Create three bundles with different versions
    _ = try makeInstallerApp(in: root, displayName: "Install macOS Sequoia", version: "15.0", build: "24A335")
    _ = try makeInstallerApp(in: root, displayName: "Install macOS Sonoma", version: "14.0", build: "23A344")
    _ = try makeInstallerApp(in: root, displayName: "Install macOS Ventura", version: "13.0", build: "22A400")

    let source = LocalInstallerSource(searchDirectories: [root])
    let releases = try await source.availableReleases()

    #expect(releases.count == 3)
    #expect(releases[0].version == OSVersion("15.0"))
    #expect(releases[1].version == OSVersion("14.0"))
    #expect(releases[2].version == OSVersion("13.0"))
}

@Test("skips bundles with malformed Info.plist")
func skipsBundlesWithMalformedInfoPlist() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Create a valid bundle
    let validApp = try makeInstallerApp(in: root, displayName: "Install macOS Tahoe", version: "26.7", build: "25G229")

    // Create a bundle with an invalid Info.plist (malformed XML)
    let invalidApp = root.appendingPathComponent("Install macOS Broken.app")
    let contents = invalidApp.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try "not valid xml".write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

    let source = LocalInstallerSource(searchDirectories: [root])
    let releases = try await source.availableReleases()

    // Only the valid bundle should be returned
    #expect(releases.count == 1)
    let release = try #require(releases.first)
    #expect(release.name == "Install macOS Tahoe")
    let normalizedValidPath = validApp.path.hasSuffix("/") ? String(validApp.path.dropLast()) : validApp.path
    #expect(release.payload == .localApplication(path: URL(fileURLWithPath: normalizedValidPath)))
}

@Test("skips bundles with missing required Info.plist keys")
func skipsBundlesWithMissingInfoPlistKeys() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Create a valid bundle
    let validApp = try makeInstallerApp(in: root, displayName: "Install macOS Tahoe", version: "26.7", build: "25G229")

    // Create a bundle missing required keys
    let incompleteApp = root.appendingPathComponent("Install macOS Incomplete.app")
    let contents = incompleteApp.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

    let info: [String: Any] = [
        "CFBundleDisplayName": "Install macOS Incomplete",
        // Missing DTPlatformVersion and DTSDKBuild
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))

    let source = LocalInstallerSource(searchDirectories: [root])
    let releases = try await source.availableReleases()

    // Only the valid bundle should be returned
    #expect(releases.count == 1)
    let release = try #require(releases.first)
    #expect(release.name == "Install macOS Tahoe")
    let normalizedValidPath = validApp.path.hasSuffix("/") ? String(validApp.path.dropLast()) : validApp.path
    #expect(release.payload == .localApplication(path: URL(fileURLWithPath: normalizedValidPath)))
}
