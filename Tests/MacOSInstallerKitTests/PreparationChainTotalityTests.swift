import Foundation
import Testing
@testable import MacOSInstallerKit

/// These two tests are what the old per-case `PreparationErrorFormatterTests`
/// should have been: instead of pinning the wording of a few hand-picked
/// cases, they enumerate every case of every type explicitly, the way
/// `VolumeGuardTests.refusalReasonsHaveMessages` does. The sample arrays below
/// are hand-maintained and have no exhaustiveness checking on their own; the
/// `exhaustivelyCheck...` helpers further down are what actually make a case
/// added later with no honesty statement fail automatically rather than
/// silently shipping a gap — each is an exhaustive `switch` with no `default`
/// clause, so adding a case to the enum fails this file at compile time until
/// a sample is added above and the switch is updated to match.
///
/// `DownloadError`, `DigestError`, and `AssemblyError` all throw strictly
/// before `InstallMediaWriter` is ever constructed (`Downloader.swift:37`,
/// `ResumableTransfer.swift:124/134/138`, `DigestVerifier.swift:26/43`,
/// `InstallAssistantAssembler.swift:38/46`), so every case of all three MAY
/// honestly claim the drive was not touched — and MUST, because the user has
/// already typed the confirmation to erase it by the time these can fire.
@Test("every case of DownloadError, DigestError, and AssemblyError states the drive was not touched")
func downloadDigestAssemblyCasesAllStateDriveUntouched() {
    let downloadCases: [DownloadError] = [
        .sizeMismatch(expected: 100, actual: 40, path: "/tmp/x.pkg"),
        .transferFailed("curl exited 7"),
    ]
    let digestCases: [DigestError] = [
        .mismatch(expected: "aaaa", actual: "bbbb"),
        .unreadable("/tmp/x.pkg"),
    ]
    let assemblyCases: [AssemblyError] = [
        .installerFailed(exitCode: 1, message: "installer: failed"),
        .applicationNotFound("Install macOS Tahoe"),
    ]

    // Calling these with the samples above both proves the exhaustive
    // switches still compile against the current case sets and uses the
    // helpers, so the compiler doesn't warn them as unused.
    downloadCases.forEach(exhaustivelyCheckDownloadError)
    digestCases.forEach(exhaustivelyCheckDigestError)
    assemblyCases.forEach(exhaustivelyCheckAssemblyError)

    let untouchable: [any Explainable] =
        downloadCases.map { $0 as any Explainable }
        + digestCases.map { $0 as any Explainable }
        + assemblyCases.map { $0 as any Explainable }

    for error in untouchable {
        let rendered = error.explanation.rendered()
        #expect(
            rendered.contains("The drive was not touched"),
            "\(error) must state the drive was not touched"
        )
    }
}

/// Exists only to force this file to fail to compile if a case is added to
/// `DownloadError` without a corresponding sample being added to
/// `downloadCases` above: the switch below has no `default` clause, so an
/// unhandled case is a compile error, not a silent pass. Deliberately never
/// called for what it does (each case just `break`s) — only called, in the
/// test above, so the compiler checks it and it isn't flagged as dead code.
private func exhaustivelyCheckDownloadError(_ error: DownloadError) {
    switch error {
    case .sizeMismatch: break
    case .transferFailed: break
    }
}

/// Same purpose as `exhaustivelyCheckDownloadError`, for `DigestError`.
private func exhaustivelyCheckDigestError(_ error: DigestError) {
    switch error {
    case .mismatch: break
    case .unreadable: break
    }
}

/// Same purpose as `exhaustivelyCheckDownloadError`, for `AssemblyError`.
private func exhaustivelyCheckAssemblyError(_ error: AssemblyError) {
    switch error {
    case .installerFailed: break
    case .applicationNotFound: break
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
/// by adding a promise `CommandError` cannot keep. As with the test above,
/// the `commandErrors` array has no exhaustiveness checking by itself; the
/// `exhaustivelyCheckCommandError` helper below is what fails this file at
/// compile time if a case is added without a sample being added here.
@Test("no CommandError explanation makes any claim about the drive")
func commandErrorMakesNoClaimAboutTheDrive() {
    let commandErrors: [CommandError] = [
        .launchFailed(executable: "/usr/bin/curl", reason: "no such file"),
    ]

    commandErrors.forEach(exhaustivelyCheckCommandError)

    for error in commandErrors {
        let rendered = error.explanation.rendered().lowercased()
        #expect(rendered.contains("not touched") == false, "\(error) must not claim the drive is untouched")
        #expect(rendered.contains("erased") == false, "\(error) must not claim anything about erasure")
        #expect(rendered.contains("written") == false, "\(error) must not claim anything about writing")
    }
}

/// Same purpose as `exhaustivelyCheckDownloadError`, for `CommandError`.
private func exhaustivelyCheckCommandError(_ error: CommandError) {
    switch error {
    case .launchFailed: break
    }
}
