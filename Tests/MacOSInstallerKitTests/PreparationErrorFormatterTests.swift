import Foundation
import Testing
@testable import MacOSInstallerKit

@Test("a digest mismatch states plainly that the drive was not touched")
func digestMismatchStatesDriveNotTouched() {
    let message = PreparationErrorFormatter.render(
        DigestError.mismatch(expected: "aaaa", actual: "bbbb")
    )

    #expect(message.contains("The drive was not touched"))
}

@Test("a digest mismatch mentions the corrupted file was deleted")
func digestMismatchMentionsDeletion() {
    let message = PreparationErrorFormatter.render(
        DigestError.mismatch(expected: "aaaa", actual: "bbbb")
    )

    #expect(message.contains("deleted"))
}

@Test("a download failure states plainly that the drive was not touched")
func downloadFailureStatesDriveNotTouched() {
    let message = PreparationErrorFormatter.render(
        DownloadError.transferFailed("curl exited 7")
    )

    #expect(message.contains("The drive was not touched"))
    #expect(message.contains("curl exited 7"))
}

@Test("a size-mismatch download failure states plainly that the drive was not touched")
func sizeMismatchStatesDriveNotTouched() {
    let message = PreparationErrorFormatter.render(
        DownloadError.sizeMismatch(expected: 100, actual: 40)
    )

    #expect(message.contains("The drive was not touched"))
}

@Test("an assembly failure states plainly that the drive was not touched")
func assemblyFailureStatesDriveNotTouched() {
    let message = PreparationErrorFormatter.render(
        AssemblyError.installerFailed(exitCode: 1, message: "installer: failed")
    )

    #expect(message.contains("The drive was not touched"))
    #expect(message.contains("installer: failed"))
}

@Test("a raw CommandError is rendered in plain language and states the drive was not touched")
func commandErrorStatesDriveNotTouched() {
    let message = PreparationErrorFormatter.render(
        CommandError.launchFailed(executable: "/usr/bin/curl", reason: "no such file")
    )

    #expect(message.contains("The drive was not touched"))
    #expect(message.contains("/usr/bin/curl"))
}

@Test("an InstallerPreparationError renders its own user message without an extra not-touched suffix")
func installerPreparationErrorUsesItsOwnMessage() {
    let message = PreparationErrorFormatter.render(InstallerPreparationError.legacyAssemblyNotSupported)

    #expect(message == InstallerPreparationError.legacyAssemblyNotSupported.userMessage)
}

@Test("falls back to a not-touched message for an entirely unrecognised error type")
func unknownErrorFallsBackToNotTouched() {
    enum SomeOtherError: Error { case boom }

    let message = PreparationErrorFormatter.render(SomeOtherError.boom)

    #expect(message.contains("The drive was not touched"))
}
