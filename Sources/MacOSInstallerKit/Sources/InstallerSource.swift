import Foundation

/// A place macOS installers can be obtained from. Implementations answer what
/// is available; obtaining the bytes is a later concern.
public protocol InstallerSource: Sendable {
    var origin: InstallerRelease.Origin { get }
    func availableReleases() async throws -> [InstallerRelease]
}
