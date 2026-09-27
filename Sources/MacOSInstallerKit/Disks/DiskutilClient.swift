import Foundation

public enum DiskutilParseError: Error, Equatable {
    case notAPropertyList
    case missingDeviceIdentifier
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

        return Volume(
            deviceIdentifier: deviceIdentifier,
            volumeName: d["VolumeName"] as? String ?? "",
            volumeUUID: nonEmpty(d["VolumeUUID"] as? String),
            mountPoint: nonEmpty(d["MountPoint"] as? String),
            isInternal: d["Internal"] as? Bool ?? false,
            isEjectable: d["Ejectable"] as? Bool ?? false,
            busProtocol: d["BusProtocol"] as? String ?? "",
            apfsContainerReference: nonEmpty(d["APFSContainerReference"] as? String),
            parentWholeDisk: d["ParentWholeDisk"] as? String ?? deviceIdentifier,
            sizeBytes: (d["Size"] as? NSNumber)?.int64Value ?? 0,
            isWholeDisk: d["WholeDisk"] as? Bool ?? false
        )
    }

    /// Volume identifiers from `diskutil list -plist`, drawn from
    /// `VolumesFromDisks` — the mounted volumes, excluding whole disks.
    public static func parseVolumeIdentifiers(_ data: Data) throws -> [String] {
        guard
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let d = object as? [String: Any]
        else { throw DiskutilParseError.notAPropertyList }

        return d["VolumesFromDisks"] as? [String] ?? []
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
