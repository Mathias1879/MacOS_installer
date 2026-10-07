import Foundation

public enum PrivilegeError: Error, Equatable {
    case runningAsRoot
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
