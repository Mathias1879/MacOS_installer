import Foundation

public struct BootVolume: Equatable, Sendable {
    public let deviceIdentifier: String
    /// Non-optional by design. An Optional here would let a caller write
    /// `candidate.container == boot.container`, which is TRUE when both are
    /// nil — silently marking unrelated volumes as the startup disk. Every
    /// supported host (macOS 13+) boots from APFS, so a missing container is
    /// an error, not a state to reason about.
    public let containerReference: String
    public let parentWholeDisk: String
}

public enum BootVolumeResolverError: Error, Equatable {
    case cannotIdentifyBootVolume(String)
}

/// This is a deliberate refusal, not a bug: the tool stopped ON PURPOSE
/// because it could not confirm, with certainty, which APFS container the
/// running system booted from. Offering a volume list without that
/// confirmation risks showing the startup disk itself as an erasable target —
/// so it refuses to proceed rather than guess. The explanation must say it
/// stopped on purpose to protect the startup disk, not hand back the generic
/// "this is a gap in the tool" fallback.
extension BootVolumeResolverError: Explainable {
    public var explanation: UserFacingError {
        switch self {
        case .cannotIdentifyBootVolume:
            return UserFacingError(
                title: "Couldn't confirm your startup disk",
                whatHappened: "This tool could not confirm which disk macOS is currently running from.",
                whatItMeans: "It stopped on purpose, to protect your startup disk: without that "
                    + "confirmation, it cannot guarantee the startup disk is excluded from the drives "
                    + "offered for erasure.",
                whatToDoNext: [
                    "Run this command again",
                    "If it keeps failing, open an issue and attach the log file below",
                ]
            )
        }
    }

    public var technicalDetail: String {
        switch self {
        case .cannotIdentifyBootVolume(let detail):
            return "BootVolumeResolverError.cannotIdentifyBootVolume detail=\(detail)"
        }
    }
}

/// Determines which APFS container the running system booted from.
///
/// This exists as its own type because the obvious implementation is wrong.
/// On a modern macOS, `/` is a sealed SNAPSHOT (e.g. `disk3s1s1`) whose
/// `VolumeUUID` differs from the underlying boot volume `Macintosh HD`
/// (`disk3s1`). Comparing a candidate's UUID against the UUID reported for
/// `/` therefore fails to recognise the real boot volume, and a guard built
/// that way would offer the startup disk as a target for erasure.
///
/// Both the snapshot and the boot volume report the same
/// `APFSContainerReference`, so the container is the reliable key.
public struct BootVolumeResolver {
    public static let diskutilPath = "/usr/sbin/diskutil"

    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    public func resolve() throws -> BootVolume {
        let result = try runner.run(Self.diskutilPath, ["info", "-plist", "/"])

        guard result.exitCode == 0 else {
            throw BootVolumeResolverError.cannotIdentifyBootVolume(
                "diskutil exited \(result.exitCode): "
                    + result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let volume: Volume
        do {
            volume = try DiskutilClient.parseInfo(Data(result.standardOutput.utf8))
        } catch {
            throw BootVolumeResolverError.cannotIdentifyBootVolume("unparsable diskutil output: \(error)")
        }

        guard let container = volume.apfsContainerReference else {
            throw BootVolumeResolverError.cannotIdentifyBootVolume(
                "diskutil reported no APFS container for / (device \(volume.deviceIdentifier))"
            )
        }

        return BootVolume(
            deviceIdentifier: volume.deviceIdentifier,
            containerReference: container,
            parentWholeDisk: volume.parentWholeDisk
        )
    }
}
