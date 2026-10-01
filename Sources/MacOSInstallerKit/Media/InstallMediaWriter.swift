import Foundation

public enum MediaWriteError: Error, Equatable {
    case targetDisappeared(uuid: String)
    case targetMoved(expected: String, found: String)
    case targetNotMounted(uuid: String)
    case createInstallMediaFailed(exitCode: Int32, message: String)
}

/// Writes a bootable installer to a volume.
///
/// The volume is re-resolved by UUID in the instruction immediately preceding
/// the erase. `/dev/diskN` numbering is a lease, not a name: unplugging a hub
/// or attaching another drive renumbers devices. If the UUID now resolves to a
/// different device node than the user confirmed, this aborts rather than
/// erasing whatever is currently at that node.
public struct InstallMediaWriter {
    public static let diskutilPath = "/usr/sbin/diskutil"
    public static let sudoPath = "/usr/bin/sudo"

    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    public func write(
        installerApp: URL,
        toVolumeWithUUID uuid: String,
        expectedDeviceIdentifier: String,
        progress: @Sendable (String) -> Void
    ) throws {
        let volume = try resolve(uuid: uuid)

        guard volume.deviceIdentifier == expectedDeviceIdentifier else {
            throw MediaWriteError.targetMoved(
                expected: expectedDeviceIdentifier, found: volume.deviceIdentifier
            )
        }
        guard let mountPoint = volume.mountPoint else {
            throw MediaWriteError.targetNotMounted(uuid: uuid)
        }

        progress("Erasing \(volume.displayName) and writing the installer…")

        let tool = installerApp
            .appendingPathComponent("Contents/Resources/createinstallmedia")
            .path

        // Separate argv elements: mount points routinely contain spaces.
        // `--nointeraction` suppresses createinstallmedia's own Y/N prompt;
        // this tool has already taken an explicit typed confirmation.
        let result = try runner.run(
            Self.sudoPath, [tool, "--volume", mountPoint, "--nointeraction"]
        )

        guard result.exitCode == 0 else {
            throw MediaWriteError.createInstallMediaFailed(
                exitCode: result.exitCode,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func resolve(uuid: String) throws -> Volume {
        guard
            let info = try? runner.run(Self.diskutilPath, ["info", "-plist", uuid]),
            info.exitCode == 0,
            let volume = try? DiskutilClient.parseInfo(Data(info.standardOutput.utf8))
        else { throw MediaWriteError.targetDisappeared(uuid: uuid) }
        return volume
    }
}
