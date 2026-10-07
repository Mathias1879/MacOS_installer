import Foundation

/// One volume as reported by `diskutil info -plist`.
///
/// `volumeUUID` is deliberately optional: a whole disk has none. `mountPoint`
/// is nil rather than "" when unmounted, so callers cannot accidentally treat
/// an empty string as a path.
public struct Volume: Equatable, Sendable {
    public let deviceIdentifier: String
    public let volumeName: String
    public let volumeUUID: String?
    public let mountPoint: String?
    public let isInternal: Bool
    public let isEjectable: Bool
    public let busProtocol: String
    public let apfsContainerReference: String?
    public let parentWholeDisk: String
    public let sizeBytes: Int64
    public let isWholeDisk: Bool

    public init(
        deviceIdentifier: String,
        volumeName: String,
        volumeUUID: String?,
        mountPoint: String?,
        isInternal: Bool,
        isEjectable: Bool,
        busProtocol: String,
        apfsContainerReference: String?,
        parentWholeDisk: String,
        sizeBytes: Int64,
        isWholeDisk: Bool
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.mountPoint = mountPoint
        self.isInternal = isInternal
        self.isEjectable = isEjectable
        self.busProtocol = busProtocol
        self.apfsContainerReference = apfsContainerReference
        self.parentWholeDisk = parentWholeDisk
        self.sizeBytes = sizeBytes
        self.isWholeDisk = isWholeDisk
    }

    public var isMounted: Bool { mountPoint != nil }

    /// A human label for pickers and confirmations.
    public var displayName: String {
        volumeName.isEmpty ? deviceIdentifier : volumeName
    }
}
