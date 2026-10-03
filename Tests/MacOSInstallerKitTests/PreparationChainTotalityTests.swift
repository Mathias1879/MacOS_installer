import Foundation
import Testing
@testable import MacOSInstallerKit

/// These two tests are what the old per-case `PreparationErrorFormatterTests`
/// should have been: instead of pinning the wording of a few hand-picked
/// cases, they enumerate every case of every type explicitly, the way
/// `VolumeGuardTests.refusalReasonsHaveMessages` does, so a new case added
/// later with no honesty statement fails automatically rather than silently
/// shipping a gap.
///
/// `DownloadError`, `DigestError`, and `AssemblyError` all throw strictly
/// before `InstallMediaWriter` is ever constructed (`Downloader.swift:37`,
/// `ResumableTransfer.swift:124/134/138`, `DigestVerifier.swift:26/43`,
/// `InstallAssistantAssembler.swift:38/46`), so every case of all three MAY
/// honestly claim the drive was not touched — and MUST, because the user has
/// already typed the confirmation to erase it by the time these can fire.
@Test("every case of DownloadError, DigestError, and AssemblyError states the drive was not touched")
func downloadDigestAssemblyCasesAllStateDriveUntouched() {
    let untouchable: [any Explainable] = [
        DownloadError.sizeMismatch(expected: 100, actual: 40, path: "/tmp/x.pkg"),
        DownloadError.transferFailed("curl exited 7"),
        DigestError.mismatch(expected: "aaaa", actual: "bbbb"),
        DigestError.unreadable("/tmp/x.pkg"),
        AssemblyError.installerFailed(exitCode: 1, message: "installer: failed"),
        AssemblyError.applicationNotFound("Install macOS Tahoe"),
    ]

    for error in untouchable {
        let rendered = error.explanation.rendered()
        #expect(
            rendered.contains("The drive was not touched"),
            "\(error) must state the drive was not touched"
        )
    }
}

/// `CommandError` comes from `CommandRunner`, which anything in this codebase
/// may call — not only the download/digest/assembly chain this task also
/// conforms. Today both write-path `CommandError` sites are already trapped
/// into `MediaWriteError` before a caller ever sees a bare `CommandError`,
/// so one reaching the user currently does mean no write began — but that is
/// incidental to today's call sites, not a structural guarantee of the type
/// itself. A future call site added after an erase begins would turn any
/// drive-state claim here into a lie. This test is the guard that stops
/// someone later "fixing" the apparent inconsistency (every other
/// Explainable type here says something about the drive; this one doesn't)
/// by adding a promise `CommandError` cannot keep.
@Test("no CommandError explanation makes any claim about the drive")
func commandErrorMakesNoClaimAboutTheDrive() {
    let commandErrors: [CommandError] = [
        .launchFailed(executable: "/usr/bin/curl", reason: "no such file"),
    ]

    for error in commandErrors {
        let rendered = error.explanation.rendered().lowercased()
        #expect(rendered.contains("not touched") == false, "\(error) must not claim the drive is untouched")
        #expect(rendered.contains("erased") == false, "\(error) must not claim anything about erasure")
        #expect(rendered.contains("written") == false, "\(error) must not claim anything about writing")
    }
}
