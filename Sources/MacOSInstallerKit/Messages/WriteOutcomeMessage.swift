import Foundation

/// What to tell the user after `InstallMediaWriter.write` reports success,
/// compared against what that write actually observed on disk afterward.
///
/// C4 of the final fix round: an earlier version of `CreateCommand` printed a
/// confident "is now named X" from `createinstallmedia`'s exit code alone,
/// and the After stage and the exported instructions both repeated that
/// unverified name as the one to look for at the boot picker. That is the
/// single most load-bearing sentence this tool prints — it is what a
/// first-time user acts on when deciding whether their installer is ready —
/// so the decision now lives here, in the library, as a pure function over
/// the inputs it actually needs, rather than as a private method on
/// `CreateCommand` in the executable target (which is excluded from
/// coverage and cannot be unit tested directly). `CreateCommand` only calls
/// `decide` and prints `rendered` — it makes no choice of its own.
///
/// Mirrors the split `RetryMessage.swift` and `VolumeGuard.RefusalReason`
/// already use in this codebase: the decision and its exact wording live
/// together in one type, in `MacOSInstallerKit`, so a test can assert on the
/// rendered text directly instead of reaching into a private method.
public enum WriteOutcomeMessage: Equatable, Sendable {
    /// The write reported success, but the volume could not be read back
    /// afterward to confirm anything about it at all.
    case unreadable(deviceIdentifier: String, expectedName: String)
    /// The write reported success and the volume was read back, but its
    /// name does not match what was expected.
    case nameMismatch(observedName: String, expectedName: String)
    /// The write reported success and the volume's observed name matches
    /// what was expected exactly.
    case success(displayName: String, deviceIdentifier: String, expectedName: String)

    /// Decides which case applies.
    ///
    /// - Parameter target: The volume as it was about to be erased, before
    ///   `createinstallmedia` renamed it — used only for `deviceIdentifier`
    ///   and `displayName`, neither of which changes across a write.
    /// - Parameter expectedName: The name `createinstallmedia` is supposed
    ///   to have produced, i.e. `"Install \(release.name)"`.
    /// - Parameter observedVolume: `InstallMediaWriter.write`'s own
    ///   post-write re-resolution of the target volume. `nil` means the
    ///   write reported success but the volume could not be read back
    ///   afterward — that must be said plainly, not assumed away.
    public static func decide(target: Volume, expectedName: String, observedVolume: Volume?) -> WriteOutcomeMessage {
        guard let observedVolume else {
            return .unreadable(deviceIdentifier: target.deviceIdentifier, expectedName: expectedName)
        }

        guard observedVolume.volumeName == expectedName else {
            return .nameMismatch(observedName: observedVolume.volumeName, expectedName: expectedName)
        }

        return .success(
            displayName: target.displayName, deviceIdentifier: target.deviceIdentifier, expectedName: expectedName
        )
    }

    /// The exact line `CreateCommand` prints verbatim.
    public var rendered: String {
        switch self {
        case .unreadable(let deviceIdentifier, let expectedName):
            return "  The write reported success, but \(deviceIdentifier) could not be read back "
                + "afterward to confirm it. Check it in Disk Utility before relying on it being named "
                + "\"\(expectedName)\"."

        case .nameMismatch(let observedName, let expectedName):
            return "  The write reported success, but the volume is now named "
                + "\"\(observedName)\", not \"\(expectedName)\" as expected. "
                + "Look for \"\(observedName)\" at the boot picker instead."

        case .success(let displayName, let deviceIdentifier, let expectedName):
            return "  Done. \(displayName) (\(deviceIdentifier)) is now named \"\(expectedName)\"."
        }
    }
}
