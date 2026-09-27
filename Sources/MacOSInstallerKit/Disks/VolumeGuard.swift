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
                return "This drive holds \(Self.gigabytes(capacity)), "
                    + "but \(Self.gigabytes(required)) is needed."
            }
        }

        private static func gigabytes(_ bytes: Int64) -> String {
            String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
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

    /// `requiredBytes` is the installer's own size; headroom is added here so
    /// callers cannot forget it.
    public static func evaluate(
        volumes: [Volume],
        bootVolume: BootVolume,
        requiredBytes: Int64,
        protectedPaths: [String]
    ) -> [VolumeDecision] {
        let needed = requiredBytes + headroomBytes

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

    /// Path containment by path component, so `/Volumes/Work` does not match
    /// `/Volumes/Workshop`.
    private static func isPath(_ path: String, under mountPoint: String) -> Bool {
        let normalizedMount = mountPoint.hasSuffix("/") ? String(mountPoint.dropLast()) : mountPoint
        return path == normalizedMount || path.hasPrefix(normalizedMount + "/")
    }
}
