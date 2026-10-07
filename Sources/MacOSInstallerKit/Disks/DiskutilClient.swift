import Foundation

public enum DiskutilParseError: Error, Equatable {
    case notAPropertyList
    case missingDeviceIdentifier
    case missingInternalFlag(deviceIdentifier: String)
}

/// Every case here is a fail-closed refusal, not a bug — `missingInternalFlag`
/// especially: it exists because treating a missing `Internal` flag as
/// optional once let an internal disk be read as external, which would offer
/// the startup disk for erasure. These explanations must say the tool stopped
/// on purpose rather than hand back the generic "this is a gap in the tool"
/// fallback.
extension DiskutilParseError: Explainable {
    public var explanation: UserFacingError {
        switch self {
        case .notAPropertyList:
            return UserFacingError(
                title: "Couldn't read a drive's details",
                whatHappened: "diskutil's output for a drive could not be read as the property list "
                    + "format this tool expects.",
                whatItMeans: "This tool stopped on purpose rather than guess at a drive's details from "
                    + "output it could not parse.",
                whatToDoNext: [
                    "Run this command again",
                    "If it keeps failing, open an issue and attach the log file below",
                ]
            )

        case .missingDeviceIdentifier:
            return UserFacingError(
                title: "A drive is missing an identifier",
                whatHappened: "diskutil reported a drive with no device identifier.",
                whatItMeans: "This tool stopped on purpose rather than track a drive it has no reliable "
                    + "way to refer back to.",
                whatToDoNext: [
                    "Run this command again",
                    "If it keeps failing, open an issue and attach the log file below",
                ]
            )

        case .missingInternalFlag:
            return UserFacingError(
                title: "Couldn't confirm whether a drive is internal",
                whatHappened: "diskutil did not report whether a drive is internal or external.",
                whatItMeans: "This tool stopped on purpose, to protect your internal disks: it refuses "
                    + "to guess here, because guessing wrong could offer an internal disk as a target "
                    + "for erasure.",
                whatToDoNext: [
                    "Run this command again",
                    "If it keeps failing, open an issue and attach the log file below",
                ]
            )
        }
    }

    public var technicalDetail: String {
        switch self {
        case .notAPropertyList:
            return "DiskutilParseError.notAPropertyList"
        case .missingDeviceIdentifier:
            return "DiskutilParseError.missingDeviceIdentifier"
        case .missingInternalFlag(let deviceIdentifier):
            return "DiskutilParseError.missingInternalFlag deviceIdentifier=\(deviceIdentifier)"
        }
    }
}

/// Parses `diskutil -plist` output. Using diskutil rather than the
/// DiskArbitration C API keeps every disk fact behind `CommandRunner`, so the
/// safety layer is testable against recorded fixtures with no disk attached.
public enum DiskutilClient {
    public static func parseInfo(_ data: Data) throws -> Volume {
        guard
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let d = object as? [String: Any]
        else { throw DiskutilParseError.notAPropertyList }

        guard let deviceIdentifier = d["DeviceIdentifier"] as? String else {
            throw DiskutilParseError.missingDeviceIdentifier
        }

        // Required, not defaulted. A missing `Internal` flag must be a loud
        // failure: defaulting it to false would report an internal disk as
        // external, and the volume guard refuses internal disks. Failing open
        // here would mean offering the startup disk for erasure.
        guard let isInternal = d["Internal"] as? Bool else {
            throw DiskutilParseError.missingInternalFlag(deviceIdentifier: deviceIdentifier)
        }

        return Volume(
            deviceIdentifier: deviceIdentifier,
            volumeName: d["VolumeName"] as? String ?? "",
            volumeUUID: nonEmpty(d["VolumeUUID"] as? String),
            mountPoint: nonEmpty(d["MountPoint"] as? String),
            isInternal: isInternal,
            isEjectable: d["Ejectable"] as? Bool ?? false,
            busProtocol: d["BusProtocol"] as? String ?? "",
            apfsContainerReference: nonEmpty(d["APFSContainerReference"] as? String),
            parentWholeDisk: d["ParentWholeDisk"] as? String ?? deviceIdentifier,
            sizeBytes: (d["Size"] as? NSNumber)?.int64Value ?? 0,
            isWholeDisk: d["WholeDisk"] as? Bool ?? false
        )
    }

    /// Device identifiers from `diskutil list -plist`.
    ///
    /// Reads `AllDisks`, NOT `VolumesFromDisks`: the latter holds volume NAMES,
    /// which are not unique — this machine has two volumes named "Untitled",
    /// and `diskutil info` fails on the ambiguous name. `AllDisks` holds real
    /// identifiers. It includes whole disks and non-volume partitions; callers
    /// filter those out.
    public static func parseVolumeIdentifiers(_ data: Data) throws -> [String] {
        guard
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let d = object as? [String: Any]
        else { throw DiskutilParseError.notAPropertyList }

        return d["AllDisks"] as? [String] ?? []
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
