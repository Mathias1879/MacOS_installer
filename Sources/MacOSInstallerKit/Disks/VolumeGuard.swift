import Foundation

/// Decides which volumes may be erased. Pure — no I/O — so every rule is
/// directly testable and no rule can depend on machine state at review time.
///
/// Refusals are absolute. There is deliberately no override flag: the spec
/// requires that internal and boot volumes are never selectable, not that they
/// are selectable with a warning.
public enum VolumeGuard {
    /// Spare capacity required beyond the installer itself.
    public static let headroomBytes: Int64 = 2_000_000_000

    public enum RefusalReason: Equatable, Sendable {
        case internalDisk
        case bootContainer
        case notMounted
        case wholeDisk
        case holdsProtectedPath(String)
        case tooSmall(capacityBytes: Int64, requiredBytes: Int64)

        public var userMessage: String {
            switch self {
            case .internalDisk:
                return "This is an internal disk. Only external drives can be used."
            case .bootContainer:
                return "This volume is part of your startup disk."
            case .notMounted:
                return "This volume isn't mounted, so it can't be written to."
            case .wholeDisk:
                return "This is a whole disk rather than a volume. Pick one of its volumes."
            case .holdsProtectedPath(let path):
                return "This volume holds files this operation needs (\(path))."
            case .tooSmall(let capacity, let required):
                return "This drive holds \(ByteSize.gigabytes(capacity)), "
                    + "but \(ByteSize.gigabytes(required)) is needed."
            }
        }

        /// A three-part explanation alongside `userMessage`. `userMessage`
        /// stays a single line for `VolumeTableFormatter`'s listing, which is
        /// a table cell, not an error report; this is what `CreateCommand`
        /// prints when a targeted `--volume` matches a refused volume by name
        /// or device identifier — see `VolumeTargetResolver.refusalReason(forExactMatch:among:)`,
        /// which `CreateCommand`'s `.none` branch calls before falling back to
        /// the generic listing.
        public var explanation: UserFacingError {
            switch self {
            case .internalDisk:
                return UserFacingError(
                    title: "This is an internal disk",
                    whatHappened: "Only external drives can be erased and used as installer media.",
                    whatItMeans: "Erasing an internal disk risks destroying this Mac's own data or "
                        + "its startup disk.",
                    whatToDoNext: [
                        "Connect an external USB drive",
                        "Run this command again and choose that drive instead",
                    ]
                )

            case .bootContainer:
                return UserFacingError(
                    title: "This volume is part of your startup disk",
                    whatHappened: "This volume is part of the disk macOS is currently running from.",
                    whatItMeans: "Erasing it would leave this Mac unable to start up.",
                    whatToDoNext: [
                        "Connect a different, external drive and choose that one instead",
                    ]
                )

            case .notMounted:
                return UserFacingError(
                    title: "This volume isn't mounted",
                    whatHappened: "This volume isn't mounted, so it can't be written to.",
                    whatItMeans: "macOS can see the drive but hasn't made this volume available yet.",
                    whatToDoNext: [
                        "Unplug the drive, wait a few seconds, and plug it back in",
                        "Run this command again",
                    ]
                )

            case .wholeDisk:
                return UserFacingError(
                    title: "This is a whole disk, not a volume",
                    whatHappened: "This is a whole disk rather than one of its volumes.",
                    whatItMeans: "This tool erases a single volume, not an entire physical disk.",
                    whatToDoNext: [
                        "Pick one of this disk's volumes instead",
                    ]
                )

            case .holdsProtectedPath(let path):
                return UserFacingError(
                    title: "This volume holds files this tool needs",
                    whatHappened: "This volume holds files this operation needs (\(path)).",
                    whatItMeans: "Erasing it would delete something this command is currently "
                        + "reading from.",
                    whatToDoNext: [
                        "Choose a different drive",
                    ]
                )

            case .tooSmall(let capacity, let required):
                return UserFacingError(
                    title: "This drive is too small",
                    whatHappened: "This drive holds \(ByteSize.gigabytes(capacity)), but "
                        + "\(ByteSize.gigabytes(required)) is needed.",
                    whatItMeans: "The installer and its working space don't fit in the space available.",
                    whatToDoNext: [
                        "Use a larger drive with at least \(ByteSize.gigabytes(required)) of free space",
                    ]
                )
            }
        }
    }

    public enum Verdict: Equatable, Sendable {
        case selectable
        case selectableWithWarning(String)
        case refused(RefusalReason)
    }

    public struct VolumeDecision: Equatable, Sendable {
        public let volume: Volume
        public let verdict: Verdict
    }

    /// Whether the typed-name confirmation must still be shown, even when the
    /// caller passed `--yes`.
    ///
    /// The spec's Safety Model lists a flagged volume (for example, one that
    /// looks like a Time Machine backup) as "Listed, flagged, requires typed
    /// name" — the typed prompt IS that row's control. `--yes` exists to skip
    /// confirmation for the ordinary case; it must not also silently remove
    /// the one control the spec requires for a warned volume, so a
    /// `.selectableWithWarning` verdict always requires the typed
    /// confirmation regardless of `yesFlag`.
    public static func requiresTypedConfirmation(yesFlag: Bool, verdict: Verdict) -> Bool {
        if case .selectableWithWarning = verdict { return true }
        return !yesFlag
    }

    /// `requiredBytes` is the installer's own size; headroom is added here so
    /// callers cannot forget it.
    public static func evaluate(
        volumes: [Volume],
        bootVolume: BootVolume,
        requiredBytes: Int64,
        protectedPaths: [String]
    ) -> [VolumeDecision] {
        let needed = max(0, requiredBytes) + headroomBytes

        return volumes.map { volume in
            VolumeDecision(volume: volume, verdict: verdict(
                for: volume, bootVolume: bootVolume, needed: needed, protectedPaths: protectedPaths
            ))
        }
    }

    private static func verdict(
        for volume: Volume,
        bootVolume: BootVolume,
        needed: Int64,
        protectedPaths: [String]
    ) -> Verdict {
        if volume.isInternal { return .refused(.internalDisk) }

        // Container comparison, not UUID comparison. `/` is a sealed snapshot
        // whose VolumeUUID differs from the boot volume's, so matching on UUID
        // would fail to recognise the startup disk. The boot container is
        // non-optional by design — see BootVolumeResolver — so this check can
        // never be skipped.
        if volume.apfsContainerReference == bootVolume.containerReference {
            return .refused(.bootContainer)
        }
        if volume.parentWholeDisk == bootVolume.parentWholeDisk {
            return .refused(.bootContainer)
        }

        if volume.isWholeDisk { return .refused(.wholeDisk) }
        guard let mountPoint = volume.mountPoint else { return .refused(.notMounted) }

        if let offending = protectedPaths.first(where: { isPath($0, under: mountPoint) }) {
            return .refused(.holdsProtectedPath(offending))
        }

        if volume.sizeBytes < needed {
            return .refused(.tooSmall(capacityBytes: volume.sizeBytes, requiredBytes: needed))
        }

        if volume.volumeName.localizedCaseInsensitiveContains("time machine") {
            return .selectableWithWarning("This looks like a Time Machine backup.")
        }

        return .selectable
    }

    /// Path containment by path component, case-insensitively and with Unicode
    /// canonically precomposed.
    ///
    /// APFS is case-insensitive by default, and the same path can arrive NFC
    /// from one API and NFD from another. A byte-exact comparison would report
    /// "not protected" for a volume that holds the file this run is reading,
    /// so the guard would offer to erase it.
    ///
    /// CALLER CONTRACT: `protectedPaths` must be absolute and already
    /// symlink-resolved. Resolving a symlink requires filesystem access and
    /// this type is deliberately pure, so the caller owns that step.
    private static func isPath(_ path: String, under mountPoint: String) -> Bool {
        let normalize: (String) -> String = {
            var s = $0.precomposedStringWithCanonicalMapping.lowercased()
            while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            return s
        }
        let p = normalize(path)
        let m = normalize(mountPoint)
        return p == m || p.hasPrefix(m + "/")
    }
}
