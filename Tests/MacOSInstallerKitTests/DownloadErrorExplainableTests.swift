import Foundation
import Testing
@testable import MacOSInstallerKit

/// Ported from the deleted `PreparationErrorFormatterTests`. `DownloadError`
/// is raised entirely before `InstallMediaWriter` is ever constructed
/// (`Downloader.swift:37`, `ResumableTransfer.swift:124/134/138`), so every
/// case can truthfully say the drive was not touched — a download that dies
/// after the user has already confirmed the erase must not leave them
/// wondering whether their drive survived.
@Test("a download failure states plainly that the drive was not touched")
func downloadFailureStatesDriveNotTouched() {
    let rendered = DownloadError.transferFailed("curl exited 7").explanation.rendered()

    #expect(rendered.contains("The drive was not touched"))
    #expect(rendered.contains("curl exited 7"))
}

@Test("a size-mismatch download failure states plainly that the drive was not touched")
func sizeMismatchStatesDriveNotTouched() {
    let rendered = DownloadError.sizeMismatch(
        expected: 100, actual: 40, path: "/tmp/InstallAssistant-25G229.pkg"
    ).explanation.rendered()

    #expect(rendered.contains("The drive was not touched"))
}

@Test("a size-mismatch download failure includes the cached file's path so the user can find and remove it")
func sizeMismatchIncludesPath() {
    let rendered = DownloadError.sizeMismatch(
        expected: 100, actual: 40, path: "/tmp/InstallAssistant-25G229.pkg"
    ).explanation.rendered()

    #expect(rendered.contains("/tmp/InstallAssistant-25G229.pkg"))
}

@Test("a DownloadError's technical detail names its own case and carries its payload")
func downloadErrorTechnicalDetailNamesEveryCase() {
    #expect(
        DownloadError.sizeMismatch(expected: 100, actual: 40, path: "/x").technicalDetail
            .contains("expected=100") == true
    )
    #expect(DownloadError.transferFailed("curl exited 7").technicalDetail.contains("curl exited 7"))
}
