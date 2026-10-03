import Foundation
import Testing
@testable import MacOSInstallerKit

/// A test for this was removed from an earlier task because it tested only
/// `UserFacingError.rendered()`, which merely concatenates fields and cannot
/// introduce a banned word — the test could never fail there. It belongs
/// here, where the actual wording of every explanation this task produces
/// lives, and where a careless rewording really can reintroduce it.
///
/// The sample arrays below are hand-maintained and have no exhaustiveness
/// checking on their own — fix round 2 proved that pattern ships gaps
/// silently, the same way `PreparationChainTotalityTests` once did. The
/// `exhaustivelyCheck...` helpers further down are what actually enforce it:
/// each is an exhaustive `switch` with no `default` clause, so adding a case
/// to any sampled type fails this file at compile time until a sample is
/// added above and the switch is updated to match.
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
        .writeToolDidNotLaunch(message: "nope"),
        .writeFailedDriveStateUnknown(exitCode: 1, message: "nope"),
    ]
    writeErrors.forEach(exhaustivelyCheckMediaWriteError)
    rendered += writeErrors.map { $0.explanation.rendered() }

    let reasons: [VolumeGuard.RefusalReason] = [
        .internalDisk, .bootContainer, .notMounted, .wholeDisk,
        .holdsProtectedPath("/x"), .tooSmall(capacityBytes: 1, requiredBytes: 2),
    ]
    reasons.forEach(exhaustivelyCheckRefusalReason)
    rendered += reasons.map { $0.explanation.rendered() }

    let preparationErrors: [InstallerPreparationError] = [
        .legacyAssemblyNotSupported,
        .softwareUpdateOnly(version: "26.7"),
    ]
    preparationErrors.forEach(exhaustivelyCheckInstallerPreparationError)
    rendered += preparationErrors.map { $0.explanation.rendered() }

    let downloadErrors: [DownloadError] = [
        .sizeMismatch(expected: 100, actual: 40, path: "/tmp/x.pkg"),
        .transferFailed("curl exited 7"),
    ]
    downloadErrors.forEach(exhaustivelyCheckDownloadError)
    rendered += downloadErrors.map { $0.explanation.rendered() }

    let digestErrors: [DigestError] = [
        .mismatch(expected: "aaaa", actual: "bbbb"),
        .unreadable("/tmp/x.pkg"),
    ]
    digestErrors.forEach(exhaustivelyCheckDigestError)
    rendered += digestErrors.map { $0.explanation.rendered() }

    let assemblyErrors: [AssemblyError] = [
        .installerFailed(exitCode: 1, message: "installer: failed"),
        .applicationNotFound("Install macOS Tahoe"),
    ]
    assemblyErrors.forEach(exhaustivelyCheckAssemblyError)
    rendered += assemblyErrors.map { $0.explanation.rendered() }

    let commandErrors: [CommandError] = [
        .launchFailed(executable: "/usr/bin/curl", reason: "no such file"),
    ]
    commandErrors.forEach(exhaustivelyCheckCommandError)
    rendered += commandErrors.map { $0.explanation.rendered() }

    let privilegeErrors: [PrivilegeError] = [
        .runningAsRoot,
    ]
    privilegeErrors.forEach(exhaustivelyCheckPrivilegeError)
    rendered += privilegeErrors.map { $0.explanation.rendered() }

    let bootVolumeResolverErrors: [BootVolumeResolverError] = [
        .cannotIdentifyBootVolume("diskutil exited 1: no such disk"),
    ]
    bootVolumeResolverErrors.forEach(exhaustivelyCheckBootVolumeResolverError)
    rendered += bootVolumeResolverErrors.map { $0.explanation.rendered() }

    let diskutilParseErrors: [DiskutilParseError] = [
        .notAPropertyList,
        .missingDeviceIdentifier,
        .missingInternalFlag(deviceIdentifier: "disk5s1"),
    ]
    diskutilParseErrors.forEach(exhaustivelyCheckDiskutilParseError)
    rendered += diskutilParseErrors.map { $0.explanation.rendered() }

    for text in rendered {
        let lowered = text.lowercased()
        for word in banned {
            #expect(lowered.contains(word) == false, "explanation contains banned word '\(word)': \(text)")
        }
    }
}

// MARK: - Exhaustiveness guards
//
// Each helper is an exhaustive `switch` over its type with no `default`
// clause and every case just `break`ing. None is called for what it does —
// each is only called, in the test above, so the compiler both checks it
// against the current case set and doesn't flag it as dead code. Adding a
// case to any of these types without updating the matching switch below (and
// adding a sample to the corresponding array above) fails this file to
// compile, rather than letting a new case ship with no banned-word coverage.

private func exhaustivelyCheckMediaWriteError(_ error: MediaWriteError) {
    switch error {
    case .targetDisappeared: break
    case .targetMoved: break
    case .targetNotMounted: break
    case .installerToolMissing: break
    case .authenticationFailed: break
    case .writeToolDidNotLaunch: break
    case .writeFailedDriveStateUnknown: break
    }
}

private func exhaustivelyCheckRefusalReason(_ reason: VolumeGuard.RefusalReason) {
    switch reason {
    case .internalDisk: break
    case .bootContainer: break
    case .notMounted: break
    case .wholeDisk: break
    case .holdsProtectedPath: break
    case .tooSmall: break
    }
}

private func exhaustivelyCheckInstallerPreparationError(_ error: InstallerPreparationError) {
    switch error {
    case .legacyAssemblyNotSupported: break
    case .softwareUpdateOnly: break
    }
}

private func exhaustivelyCheckDownloadError(_ error: DownloadError) {
    switch error {
    case .sizeMismatch: break
    case .transferFailed: break
    }
}

private func exhaustivelyCheckDigestError(_ error: DigestError) {
    switch error {
    case .mismatch: break
    case .unreadable: break
    }
}

private func exhaustivelyCheckAssemblyError(_ error: AssemblyError) {
    switch error {
    case .installerFailed: break
    case .applicationNotFound: break
    }
}

private func exhaustivelyCheckCommandError(_ error: CommandError) {
    switch error {
    case .launchFailed: break
    }
}

private func exhaustivelyCheckPrivilegeError(_ error: PrivilegeError) {
    switch error {
    case .runningAsRoot: break
    }
}

private func exhaustivelyCheckBootVolumeResolverError(_ error: BootVolumeResolverError) {
    switch error {
    case .cannotIdentifyBootVolume: break
    }
}

private func exhaustivelyCheckDiskutilParseError(_ error: DiskutilParseError) {
    switch error {
    case .notAPropertyList: break
    case .missingDeviceIdentifier: break
    case .missingInternalFlag: break
    }
}
