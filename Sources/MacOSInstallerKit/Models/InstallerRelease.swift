import Foundation

/// Identifies a release independently of where it was found, so the same macOS
/// build discovered by two sources deduplicates to one entry.
public struct ReleaseIdentity: Hashable, Sendable {
    public let version: OSVersion
    public let build: String
}

public struct InstallerRelease: Equatable, Sendable {
    /// Ordered by precedence: a higher case wins when two sources offer the
    /// same build. Local wins because it needs no download.
    public enum Origin: Int, Comparable, Sendable {
        case softwareUpdate = 0
        case sucatalog = 1
        case local = 2

        public static func < (lhs: Origin, rhs: Origin) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// How the installer application is obtained. The assembler chosen later
    /// switches on this.
    public enum Payload: Equatable, Sendable {
        case installAssistant(url: URL)
        case legacyESD(urls: [URL])
        case localApplication(path: URL)
        case softwareUpdate(version: String)
    }

    public let name: String
    public let version: OSVersion
    public let build: String
    public let sizeBytes: Int64
    public let origin: Origin
    public let payload: Payload

    public init(
        name: String,
        version: OSVersion,
        build: String,
        sizeBytes: Int64,
        origin: Origin,
        payload: Payload
    ) {
        self.name = name
        self.version = version
        self.build = build
        self.sizeBytes = sizeBytes
        self.origin = origin
        self.payload = payload
    }

    public var identity: ReleaseIdentity {
        ReleaseIdentity(version: version, build: build)
    }

    /// Big Sur (11) introduced the single-package InstallAssistant format.
    /// Anything older uses the undocumented chunked ESD layout.
    public var requiresLegacyAssembly: Bool {
        version.major < 11
    }

    public var displaySize: String {
        let gigabytes = Double(sizeBytes) / 1_000_000_000
        return String(format: "%.1f GB", gigabytes)
    }
}
