import Foundation
import Testing
@testable import MacOSInstallerKit

/// Ported from the deleted `PreparationErrorFormatterTests`. `DownloadError`
/// is raised entirely before `InstallMediaWriter` is ever constructed
/// (`Downloader.swift:37`, `ResumableTransfer.swift:124/134/138`), so every
/// case can truthfully say the drive was not touched — a download that dies
/// after the user has already confirmed the erase must not leave them
/// wondering whether their drive survived.
@Test("a download failure states plainly that the drive was not touched, without leaking curl's raw message")
func downloadFailureStatesDriveNotTouched() {
    let rendered = DownloadError.transferFailed("curl exited 7").explanation.rendered()

    #expect(rendered.contains("The drive was not touched"))
    // I6 of the final fix round: row 23 of the manual-verification checklist
    // requires the terminal message not contain raw technical detail. This
    // payload now reaches only `technicalDetail` (see
    // `downloadErrorTechnicalDetailNamesEveryCase` below).
    #expect(rendered.contains("curl exited 7") == false)
}

@Test("a size-mismatch download failure states plainly that the drive was not touched")
func sizeMismatchStatesDriveNotTouched() {
    let rendered = DownloadError.sizeMismatch(
        expected: 100, actual: 40, path: "/tmp/InstallAssistant-25G229.pkg"
    ).explanation.rendered()

    #expect(rendered.contains("The drive was not touched"))
}

@Test("a size-mismatch download failure keeps the raw byte counts and cached path out of the user-facing message")
func sizeMismatchExcludesRawDetailFromUserMessage() {
    let error = DownloadError.sizeMismatch(expected: 100, actual: 40, path: "/tmp/InstallAssistant-25G229.pkg")
    let rendered = error.explanation.rendered()

    // I6 of the final fix round: this file is deleted automatically (see
    // `InstallerPreparer.downloadAndVerify`'s caller), so the user never acts
    // on this path directly — it belongs in the log only, matching the
    // standard `MediaWriteError.writeToolDidNotLaunch` already sets.
    #expect(rendered.contains("/tmp/InstallAssistant-25G229.pkg") == false)
    #expect(rendered.contains("100") == false)
    #expect(rendered.contains("40") == false)
    #expect(error.technicalDetail.contains("/tmp/InstallAssistant-25G229.pkg"))
}

@Test("a DownloadError's technical detail names its own case and carries its payload")
func downloadErrorTechnicalDetailNamesEveryCase() {
    #expect(
        DownloadError.sizeMismatch(expected: 100, actual: 40, path: "/x").technicalDetail
            .contains("expected=100") == true
    )
    #expect(DownloadError.transferFailed("curl exited 7").technicalDetail.contains("curl exited 7"))
}
