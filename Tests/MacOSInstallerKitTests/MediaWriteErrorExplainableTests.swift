import Foundation
import Testing
@testable import MacOSInstallerKit

/// Ported from the deleted `MediaWriteErrorFormatterTests`. These pin the two
/// honesty guarantees `MediaWriteErrorFormatter` used to own and
/// `MediaWriteError.explanation` now owns structurally: every pre-write case
/// states the drive was not touched, and `writeFailedDriveStateUnknown` never
/// claims the drive is fine or that a retry will fix it.
private let untouchedCases: [MediaWriteError] = [
    .targetDisappeared(uuid: "UUID-1"),
    .targetMoved(expected: "disk5s1", found: "disk6s2"),
    .targetNotMounted(uuid: "UUID-1"),
    .installerToolMissing(path: "/Applications/Install macOS Tahoe.app/Contents/Resources/createinstallmedia"),
    .authenticationFailed(message: "Sorry, try again."),
]

// MARK: - Ported from MediaWriteErrorFormatterTests

@Test("every error raised before the erase states plainly that the drive was not touched")
func preEraseErrorsSayNothingWasTouched() {
    for error in untouchedCases {
        let rendered = error.explanation.rendered().lowercased()
        #expect(
            rendered.contains("erased") || rendered.contains("written") || rendered.contains("touched"),
            "\(error) must state the drive was not modified"
        )
    }
}

@Test("none of the pre-erase errors imply the drive's state is unknown")
func preEraseErrorsDoNotImplyUnknownState() {
    for error in untouchedCases {
        let rendered = error.explanation.rendered().lowercased()
        #expect(!rendered.contains("unknown"))
    }
}

@Test("a mid-write failure says the drive state is unknown and must be rewritten from scratch")
func midWriteFailureDescribesUnknownState() {
    let error = MediaWriteError.writeFailedDriveStateUnknown(
        exitCode: 1, message: "createinstallmedia: disk I/O error"
    )
    let rendered = error.explanation.rendered()

    #expect(rendered.lowercased().contains("unknown"))
    #expect(rendered.contains("rewrite"))
    // The raw subprocess message is machine-readable detail, not user-facing
    // wording — it now lives in `technicalDetail`, not the rendered message.
    #expect(error.technicalDetail.contains("createinstallmedia: disk I/O error"))
}

@Test("a mid-write failure does not say or imply nothing happened")
func midWriteFailureDoesNotClaimNothingHappened() {
    let error = MediaWriteError.writeFailedDriveStateUnknown(exitCode: 1, message: "disk I/O error")
    let rendered = error.explanation.rendered()

    #expect(!rendered.contains("Nothing was written"))
}

@Test("a mid-write failure explicitly warns against retrying, rather than implying a retry is safe")
func midWriteFailureWarnsAgainstRetrying() {
    let error = MediaWriteError.writeFailedDriveStateUnknown(exitCode: 1, message: "disk I/O error")
    let rendered = error.explanation.rendered()

    // The message must actively warn against retrying — not merely omit any
    // mention of "retry", which an uninformative message would also satisfy.
    #expect(rendered.lowercased().contains("do not") && rendered.lowercased().contains("retry"))
    #expect(rendered.contains("erase and rewrite"))
}

@Test("includes the device identifiers so the user can tell which drive moved")
func targetMovedIncludesBothIdentifiers() {
    let rendered = MediaWriteError.targetMoved(expected: "disk5s1", found: "disk6s2").explanation.rendered()

    #expect(rendered.contains("disk5s1"))
    #expect(rendered.contains("disk6s2"))
}

// MARK: - New conformance tests (Task 4, Step 1)

@Test("every pre-write MediaWriteError states that the drive was not touched")
func preWriteErrorsSayDriveUntouched() {
    for error in untouchedCases {
        let rendered = error.explanation.rendered().lowercased()
        #expect(
            rendered.contains("not")
                && (rendered.contains("erased") || rendered.contains("written") || rendered.contains("touched")),
            "\(error) must state the drive was not modified"
        )
    }
}

@Test("the unknown-state error refuses to imply a retry will fix it")
func unknownStateErrorIsHonest() {
    let error = MediaWriteError.writeFailedDriveStateUnknown(exitCode: 1, message: "Failed to erase volume")
    let rendered = error.explanation.rendered().lowercased()

    #expect(rendered.contains("unknown"))
    // It must not tell the user the drive is fine, nor that retrying suffices.
    #expect(rendered.contains("nothing was written") == false)
    #expect(rendered.contains("not touched") == false)
    // It must direct them to start over rather than retry in place.
    #expect(rendered.contains("from scratch") || rendered.contains("start over"))
}

@Test("every MediaWriteError's technical detail names its own case and carries its payload")
func technicalDetailNamesEveryCase() {
    #expect(MediaWriteError.targetDisappeared(uuid: "UUID-1").technicalDetail.contains("UUID-1"))
    #expect(
        MediaWriteError.targetMoved(expected: "disk5s1", found: "disk6s2").technicalDetail
            .contains("disk5s1") == true
    )
    #expect(MediaWriteError.targetNotMounted(uuid: "UUID-1").technicalDetail.contains("UUID-1"))
    #expect(MediaWriteError.installerToolMissing(path: "/x").technicalDetail.contains("/x"))
    #expect(MediaWriteError.authenticationFailed(message: "nope").technicalDetail.contains("nope"))
}

@Test("the unknown-state error carries the exit code in its technical detail, not its message")
func technicalDetailCarriesExitCode() {
    let error = MediaWriteError.writeFailedDriveStateUnknown(exitCode: 1, message: "Failed to erase volume")

    #expect(error.technicalDetail.contains("1"))
    #expect(error.technicalDetail.contains("Failed to erase volume"))
    // The user-facing title should not be a raw exit code.
    #expect(error.explanation.title.contains("exited with code") == false)
}
