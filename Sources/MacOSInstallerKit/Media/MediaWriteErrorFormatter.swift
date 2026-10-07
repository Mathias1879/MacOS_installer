import Foundation

/// Renders `MediaWriteError` honestly for the user.
///
/// The first five cases are all raised before `createinstallmedia` runs, so
/// they can truthfully say the drive was not touched. The last,
/// `writeFailedDriveStateUnknown`, cannot make that claim: the erase may have
/// started and been interrupted partway through, leaving the drive partially
/// written and non-bootable. Its message must not say or imply that nothing
/// happened, and must not suggest that a simple retry will fix it — the drive
/// has to be rewritten from scratch.
public enum MediaWriteErrorFormatter {
    public static func render(_ error: MediaWriteError) -> String {
        switch error {
        case .targetDisappeared(let uuid):
            return "The drive (\(uuid)) is no longer attached. Nothing was written to it."

        case .targetMoved(let expected, let found):
            return "The drive you confirmed no longer matches what is now at that device node "
                + "(expected \(expected), found \(found)). Nothing was written. Reconnect the "
                + "correct drive and run this again."

        case .targetNotMounted(let uuid):
            return "The drive (\(uuid)) is not mounted, so it cannot be written to. "
                + "Nothing was written to it."

        case .installerToolMissing(let path):
            return "The installer tool was not found at \(path). Nothing was written. "
                + "The installer application may be incomplete — try removing it and running "
                + "this command again so it can be re-assembled."

        case .authenticationFailed(let message):
            return "Authentication failed (\(message)). Nothing was written."

        case .writeFailedDriveStateUnknown(let exitCode, let message):
            return "createinstallmedia exited with code \(exitCode) before finishing (\(message)). "
                + "The drive is now in an UNKNOWN state: the erase may have started and been "
                + "interrupted partway through, so it may be partially written and is not safe "
                + "to boot from. Do not assume it is unchanged, and do not just retry — erase and "
                + "rewrite it from scratch before using it."
        }
    }
}
