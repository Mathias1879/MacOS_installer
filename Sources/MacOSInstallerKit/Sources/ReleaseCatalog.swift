import Foundation

/// Merges every source into one list. A source that fails is recorded and
/// skipped rather than taking the whole listing down — an offline machine with
/// a local installer should still be able to use it.
public struct ReleaseCatalog {
    public struct Result: Sendable {
        public let releases: [InstallerRelease]
        public let failures: [String]
    }

    /// The oldest macOS this tool will write media for.
    public static let minimumSupportedVersion = OSVersion("10.14")!

    private let sources: [any InstallerSource]
    private let minimumVersion: OSVersion

    public init(
        sources: [any InstallerSource],
        minimumVersion: OSVersion = ReleaseCatalog.minimumSupportedVersion
    ) {
        self.sources = sources
        self.minimumVersion = minimumVersion
    }

    public func allReleases() async -> Result {
        var collected: [InstallerRelease] = []
        var failures: [String] = []

        for source in sources {
            do {
                collected.append(contentsOf: try await source.availableReleases())
            } catch {
                failures.append("\(source.origin): \(error)")
            }
        }

        // sizeBytes > 0 is a fail-closed gate, not an optimisation: a later
        // phase refuses a target USB drive when its capacity is below
        // installer size + 2 GB headroom. A release that reaches the caller
        // reporting 0 bytes would make that check pass trivially and permit
        // an oversized installer onto an undersized drive. Every source is
        // hardened to drop what it cannot size, but this filter is the single
        // choke point all three flow through — do not remove it.
        let eligible = collected.filter { $0.version >= minimumVersion && $0.sizeBytes > 0 }

        // Same version+build from two sources collapses to the higher-precedence one.
        var best: [ReleaseIdentity: InstallerRelease] = [:]
        for release in eligible {
            if let existing = best[release.identity], existing.origin >= release.origin {
                continue
            }
            best[release.identity] = release
        }

        // Dictionary iteration order is unspecified, but the output is still
        // deterministic: keys are unique ReleaseIdentity values, so two entries
        // that compare equal on version must differ in build. The comparator is
        // therefore a total order with no ties, and the sorted result does not
        // depend on the order values came out of the dictionary.
        let sorted = best.values.sorted {
            if $0.version != $1.version { return $0.version > $1.version }
            return $0.build > $1.build
        }

        return Result(releases: sorted, failures: failures)
    }
}
