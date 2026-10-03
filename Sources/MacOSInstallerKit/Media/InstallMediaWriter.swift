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
        // Wrapped rather than a bare `try`: a launch failure here (e.g. sudo
        // missing from PATH) would otherwise surface as a raw `CommandError`
        // instead of `MediaWriteError`, which is the one type callers catch
        // to render an honest "was the drive touched?" message. A launch
        // failure happens before anything is written, exactly like a
        // non-zero exit from sudo itself, so both map to the same case.
        let auth: CommandResult
        do {
            auth = try runner.run(Self.sudoPath, ["-v"])
        } catch {
            throw MediaWriteError.authenticationFailed(message: "sudo could not be run: \(error)")
        }
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

/// The first five cases are all raised before `createinstallmedia` runs, so
/// they can truthfully say the drive was not touched. The last,
/// `writeFailedDriveStateUnknown`, cannot make that claim: the erase may have
/// started and been interrupted partway through, leaving the drive partially
/// written and non-bootable. Its explanation must not say or imply that
/// nothing happened, and must not suggest that a retry will fix it — the
/// drive has to be erased and rewritten from scratch.
extension MediaWriteError: Explainable {
    public var explanation: UserFacingError {
        switch self {
        case .targetDisappeared(let uuid):
            return UserFacingError(
                title: "The drive disappeared",
                whatHappened: "The drive you chose (\(uuid)) is no longer connected, so nothing was erased.",
                whatItMeans: "It was probably unplugged, or it went to sleep.",
                whatToDoNext: [
                    "Plug the drive back in and wait for it to appear on your desktop",
                    "Run this command again",
                ]
            )

        case .targetMoved(let expected, let found):
            return UserFacingError(
                title: "The drive moved",
                whatHappened: "The drive you confirmed was \(expected), but it is now \(found). "
                    + "Nothing was erased.",
                whatItMeans: "macOS renumbers drives when devices are plugged in or unplugged. "
                    + "This tool stopped rather than risk erasing a different drive.",
                whatToDoNext: [
                    "Leave your drives connected as they are",
                    "Run this command again and confirm the drive you want",
                ]
            )

        case .targetNotMounted(let uuid):
            return UserFacingError(
                title: "The drive isn't ready",
                whatHappened: "The drive you chose (\(uuid)) is connected but not mounted, "
                    + "so nothing was erased.",
                whatItMeans: "macOS can see the hardware but hasn't made the drive available yet.",
                whatToDoNext: [
                    "Unplug the drive, wait a few seconds, and plug it back in",
                    "Wait until it appears on your desktop",
                    "Run this command again",
                ]
            )

        case .installerToolMissing(let path):
            return UserFacingError(
                title: "The installer app is incomplete",
                whatHappened: "The tool macOS uses to write the drive wasn't found inside the installer "
                    + "app. Nothing was erased.",
                whatItMeans: "The installer app is damaged or only partly downloaded.",
                whatToDoNext: [
                    "Delete the installer app from your Applications folder",
                    "Run this command again so it downloads a fresh copy",
                    "If it keeps failing, the expected location was: \(path)",
                ]
            )

        case .authenticationFailed:
            return UserFacingError(
                title: "The password wasn't accepted",
                whatHappened: "macOS didn't accept the administrator password, so nothing was erased.",
                whatItMeans: "Writing a drive needs administrator permission. "
                    + "The prompt shows no characters at all as you type, which can make it feel broken.",
                whatToDoNext: [
                    "Run this command again",
                    "Type your Mac login password when asked — you will see nothing appear, which is normal",
                    "Press Return",
                ]
            )

        case .writeFailedDriveStateUnknown:
            return UserFacingError(
                title: "The drive is in an unknown state",
                whatHappened: "The erase began but did not finish before createinstallmedia stopped.",
                whatItMeans: "The drive may be partially erased. It is not safe to boot from, and it is "
                    + "not in the state it was in before you started — do not assume it is unchanged, "
                    + "and do not retry in place.",
                whatToDoNext: [
                    "Do not use this drive to install macOS",
                    "Do not retry — erase and rewrite it from scratch using Disk Utility "
                        + "(it's in Applications, inside Utilities)",
                    "Then run this command again",
                ]
            )
        }
    }

    public var technicalDetail: String {
        switch self {
        case .targetDisappeared(let uuid):
            return "MediaWriteError.targetDisappeared uuid=\(uuid)"
        case .targetMoved(let expected, let found):
            return "MediaWriteError.targetMoved expected=\(expected) found=\(found)"
        case .targetNotMounted(let uuid):
            return "MediaWriteError.targetNotMounted uuid=\(uuid)"
        case .installerToolMissing(let path):
            return "MediaWriteError.installerToolMissing path=\(path)"
        case .authenticationFailed(let message):
            return "MediaWriteError.authenticationFailed message=\(message)"
        case .writeFailedDriveStateUnknown(let exitCode, let message):
            return "MediaWriteError.writeFailedDriveStateUnknown exitCode=\(exitCode) message=\(message)"
        }
    }
}
