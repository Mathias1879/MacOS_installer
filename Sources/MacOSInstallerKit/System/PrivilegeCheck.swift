import Foundation

public enum PrivilegeError: Error, Equatable {
    case runningAsRoot
}

/// This is a deliberate refusal, not a bug: the user ran the command with
/// `sudo` (or as root some other way), which is something they did, and
/// running it again unchanged would refuse the same way. It is also the
/// likeliest first mistake a beginner makes with a tool that erases drives.
/// The explanation must say so plainly and tell them to drop `sudo`, not hand
/// them the generic "run it again, it may have been temporary" fallback.
extension PrivilegeError: Explainable {
    public var explanation: UserFacingError {
        switch self {
        case .runningAsRoot:
            return UserFacingError(
                title: "This was run with sudo",
                whatHappened: "This command was started as root — most likely by running it with sudo.",
                whatItMeans: "This tool escalates to administrator privileges on its own, only for the "
                    + "two steps that actually need it. Running the whole command as root instead would "
                    + "leave the downloaded installer and its cache owned by root, which you could not "
                    + "delete again without sudo.",
                whatToDoNext: [
                    "Run the command again without sudo",
                    "Enter your password only when the tool itself asks for it",
                ]
            )
        }
    }

    public var technicalDetail: String {
        switch self {
        case .runningAsRoot:
            return "PrivilegeError.runningAsRoot"
        }
    }
}

/// The tool runs unprivileged and escalates only for the two operations that
/// require root. Running the whole process as root would leave the download
/// cache and the assembled installer owned by root, which the user then cannot
/// delete without `sudo`.
public enum PrivilegeCheck {
    public static func assertNotRoot(effectiveUserID: uid_t = getuid()) throws {
        guard effectiveUserID != 0 else { throw PrivilegeError.runningAsRoot }
    }
}
