import Foundation
import Testing
@testable import MacOSInstallerKit

/// A test for this was removed from an earlier task because it tested only
/// `UserFacingError.rendered()`, which merely concatenates fields and cannot
/// introduce a banned word — the test could never fail there. It belongs
/// here, where the actual wording of every explanation this task produces
/// lives, and where a careless rewording really can reintroduce it.
///
/// "simply", "just", "obviously" and "merely" all tell a confused reader the
/// problem is them, which is exactly the failure mode this project's
/// three-part error shape exists to avoid.
@Test("no error explanation uses language that blames the reader")
func explanationsDoNotBlameTheReader() {
    let banned = ["simply", "just ", "obviously", "merely"]

    var rendered: [String] = []
    let writeErrors: [MediaWriteError] = [
        .targetDisappeared(uuid: "U"),
        .targetMoved(expected: "disk5s1", found: "disk7s1"),
        .targetNotMounted(uuid: "U"),
        .installerToolMissing(path: "/x"),
        .authenticationFailed(message: "nope"),
        .writeFailedDriveStateUnknown(exitCode: 1, message: "nope"),
    ]
    rendered += writeErrors.map { $0.explanation.rendered() }

    let reasons: [VolumeGuard.RefusalReason] = [
        .internalDisk, .bootContainer, .notMounted, .wholeDisk,
        .holdsProtectedPath("/x"), .tooSmall(capacityBytes: 1, requiredBytes: 2),
    ]
    rendered += reasons.map { $0.explanation.rendered() }

    let preparationErrors: [InstallerPreparationError] = [
        .legacyAssemblyNotSupported,
        .softwareUpdateOnly(version: "26.7"),
    ]
    rendered += preparationErrors.map { $0.explanation.rendered() }

    let downloadErrors: [DownloadError] = [
        .sizeMismatch(expected: 100, actual: 40, path: "/tmp/x.pkg"),
        .transferFailed("curl exited 7"),
    ]
    rendered += downloadErrors.map { $0.explanation.rendered() }

    let digestErrors: [DigestError] = [
        .mismatch(expected: "aaaa", actual: "bbbb"),
        .unreadable("/tmp/x.pkg"),
    ]
    rendered += digestErrors.map { $0.explanation.rendered() }

    let assemblyErrors: [AssemblyError] = [
        .installerFailed(exitCode: 1, message: "installer: failed"),
        .applicationNotFound("Install macOS Tahoe"),
    ]
    rendered += assemblyErrors.map { $0.explanation.rendered() }

    let commandErrors: [CommandError] = [
        .launchFailed(executable: "/usr/bin/curl", reason: "no such file"),
    ]
    rendered += commandErrors.map { $0.explanation.rendered() }

    for text in rendered {
        let lowered = text.lowercased()
        for word in banned {
            #expect(lowered.contains(word) == false, "explanation contains banned word '\(word)': \(text)")
        }
    }
}
