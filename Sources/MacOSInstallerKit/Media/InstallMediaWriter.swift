import Foundation

public enum MediaWriteError: Error, Equatable {
    case targetDisappeared(uuid: String)
    case targetMoved(expected: String, found: String)
    case targetNotMounted(uuid: String)
    case installerToolMissing(path: String)
    case authenticationFailed(message: String)
    /// `createinstallmedia` exited non-zero. The drive's state cannot be known
    /// from this alone: the erase may have started and been interrupted
    /// partway through. Callers MUST treat the target as a non-bootable,
    /// unknown state and rewrite it from scratch — never retry on the
    /// assumption that partial progress can be resumed or trusted.
    case writeFailedDriveStateUnknown(exitCode: Int32, message: String)
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
        let tool = installerApp
            .appendingPathComponent("Contents/Resources/createinstallmedia")
            .path

        // Checked before anything else: a wrong or incomplete installer app
        // would otherwise make the user type their admin password only to
        // have sudo fail with "command not found" — reported as if the drive
        // might have been touched, when nothing ran at all.
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw MediaWriteError.installerToolMissing(path: tool)
        }

        // Take the password BEFORE re-resolving the target. sudo's prompt is
        // an unbounded, user-paced wait; leaving it between the guards and
        // the erase means the device could be unplugged — and a different
        // volume mounted at the same path — while the prompt is up. This
        // machine already has two volumes named "Untitled", so a same-name,
        // same-path remount during that wait is not a hypothetical.
        let auth = try runner.run(Self.sudoPath, ["-v"])
        guard auth.exitCode == 0 else {
            throw MediaWriteError.authenticationFailed(
                message: auth.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let volume = try resolve(uuid: uuid)

        // Also before the guards: a caller-supplied closure can block for
        // arbitrary wall time, and the window between the final guard and the
        // erase below must contain nothing but pure string building.
        progress("Erasing \(volume.displayName) and writing the installer…")

        // Two independent bindings to the volume the user confirmed, not one:
        // the UUID itself, and the device node it resolved to. `diskutil info`
        // accepts device nodes and volume names as well as UUIDs, and names
        // are not unique on this machine, so checking only deviceIdentifier
        // would not catch a lookup that quietly matched the wrong disk.
        guard volume.volumeUUID == uuid else {
            throw MediaWriteError.targetMoved(
                expected: expectedDeviceIdentifier, found: volume.deviceIdentifier
            )
        }
        guard volume.deviceIdentifier == expectedDeviceIdentifier else {
            throw MediaWriteError.targetMoved(
                expected: expectedDeviceIdentifier, found: volume.deviceIdentifier
            )
        }
        guard let mountPoint = volume.mountPoint else {
            throw MediaWriteError.targetNotMounted(uuid: uuid)
        }

        // Pure string building from here to the erase — separate argv
        // elements, since mount points routinely contain spaces.
        //
        // `--nointeraction` suppresses createinstallmedia's own Y/N prompt,
        // which is right because this tool has already taken an explicit
        // typed confirmation. It is specified from Apple's documented
        // behaviour and is UNVERIFIED: no installer app exists on the
        // development machine, and running createinstallmedia for real is out
        // of scope here. This must be confirmed on the Task 13
        // manual-verification checklist before it is trusted.
        let arguments = [tool, "--volume", mountPoint, "--nointeraction"]

        let result: CommandResult
        do {
            result = try runner.run(Self.sudoPath, arguments)
        } catch {
            // A launch failure here is just as unable to prove the drive is
            // untouched as a non-zero exit, so it funnels into the same
            // "unknown state" case rather than leaking CommandError in a
            // foreign error domain.
            throw MediaWriteError.writeFailedDriveStateUnknown(
                exitCode: -1,
                message: "createinstallmedia did not launch: \(error)"
            )
        }

        guard result.exitCode == 0 else {
            let stderrMessage = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            // If --nointeraction were ever rejected, usage text goes to
            // stdout, not stderr — fall back so the failure isn't reported
            // with an empty explanation.
            let message = stderrMessage.isEmpty
                ? result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                : stderrMessage
            throw MediaWriteError.writeFailedDriveStateUnknown(
                exitCode: result.exitCode,
                message: message
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
