import Foundation

/// Renders any failure that can come out of `InstallerPreparer.prepare` —
/// download, digest verification, assembly, or a raw `CommandError` that
/// leaked out of a lower layer — as a plain-language message.
///
/// Every message produced here states explicitly that the drive was not
/// touched. That is always true: `InstallerPreparer.prepare` runs entirely
/// before `InstallMediaWriter` is ever constructed, so nothing on this path
/// can have erased anything. Without this formatter, a bare enum description
/// (or an entirely untyped `CommandError`) would reach the user's terminal
/// immediately after they typed a confirmation to erase a drive, with
/// nothing telling them the drive they just confirmed is still intact — the
/// exact honesty property `MediaWriteErrorFormatter` guarantees on the write
/// path, missing from this longer and likelier-to-fail one.
public enum PreparationErrorFormatter {
    private static let notTouched = "The drive was not touched."

    public static func render(_ error: Error) -> String {
        switch error {
        case let error as InstallerPreparationError:
            return error.userMessage

        case let error as DownloadError:
            return "\(describe(error)) \(notTouched)"

        case let error as DigestError:
            return "\(describe(error)) \(notTouched)"

        case let error as AssemblyError:
            return "\(describe(error)) \(notTouched)"

        case let error as CommandError:
            return "\(describe(error)) \(notTouched)"

        default:
            return "Could not prepare the installer (\(error)). \(notTouched)"
        }
    }

    private static func describe(_ error: DownloadError) -> String {
        switch error {
        case .sizeMismatch(let expected, let actual):
            return "The download did not finish correctly: expected \(expected) bytes but got \(actual)."
        case .transferFailed(let message):
            return "The download failed: \(message)"
        }
    }

    private static func describe(_ error: DigestError) -> String {
        switch error {
        case .mismatch(let expected, let actual):
            return "The downloaded installer package did not match Apple's published digest "
                + "(expected \(expected), got \(actual)) and has been deleted, so it will be "
                + "downloaded again next time rather than reused."
        case .unreadable(let path):
            return "Could not read the downloaded file at \(path) to verify it."
        }
    }

    private static func describe(_ error: AssemblyError) -> String {
        switch error {
        case .installerFailed(let exitCode, let message):
            return "Assembling the installer application failed (exit code \(exitCode)): \(message)"
        case .applicationNotFound(let name):
            return "The installer application \"\(name)\" was not found after assembly completed."
        }
    }

    private static func describe(_ error: CommandError) -> String {
        switch error {
        case .launchFailed(let executable, let reason):
            return "Could not run \(executable): \(reason)"
        }
    }
}
