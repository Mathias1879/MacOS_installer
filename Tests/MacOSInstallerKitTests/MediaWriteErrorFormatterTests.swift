import Foundation
import Testing
@testable import MacOSInstallerKit

private let untouchedCases: [MediaWriteError] = [
    .targetDisappeared(uuid: "UUID-1"),
    .targetMoved(expected: "disk5s1", found: "disk6s2"),
    .targetNotMounted(uuid: "UUID-1"),
    .installerToolMissing(path: "/Applications/Install macOS Tahoe.app/Contents/Resources/createinstallmedia"),
    .authenticationFailed(message: "Sorry, try again."),
]

@Test("every error raised before the erase states plainly that the drive was not touched")
func preEraseErrorsSayNothingWasTouched() {
    for error in untouchedCases {
        let message = MediaWriteErrorFormatter.render(error)
        #expect(message.contains("Nothing was written"))
    }
}

@Test("none of the pre-erase errors imply the drive's state is unknown")
func preEraseErrorsDoNotImplyUnknownState() {
    for error in untouchedCases {
        let message = MediaWriteErrorFormatter.render(error)
        #expect(!message.contains("UNKNOWN"))
    }
}

@Test("a mid-write failure says the drive state is unknown and must be rewritten from scratch")
func midWriteFailureDescribesUnknownState() {
    let message = MediaWriteErrorFormatter.render(
        .writeFailedDriveStateUnknown(exitCode: 1, message: "createinstallmedia: disk I/O error")
    )

    #expect(message.contains("UNKNOWN"))
    #expect(message.contains("rewrite"))
    #expect(message.contains("createinstallmedia: disk I/O error"))
}

@Test("a mid-write failure does not say or imply nothing happened")
func midWriteFailureDoesNotClaimNothingHappened() {
    let message = MediaWriteErrorFormatter.render(
        .writeFailedDriveStateUnknown(exitCode: 1, message: "disk I/O error")
    )

    #expect(!message.contains("Nothing was written"))
}

@Test("a mid-write failure explicitly warns against retrying, rather than implying a retry is safe")
func midWriteFailureWarnsAgainstRetrying() {
    let message = MediaWriteErrorFormatter.render(
        .writeFailedDriveStateUnknown(exitCode: 1, message: "disk I/O error")
    )

    // The message must actively warn against retrying — not merely omit any
    // mention of "retry", which an uninformative message would also satisfy.
    #expect(message.lowercased().contains("do not") && message.lowercased().contains("retry"))
    #expect(message.contains("erase and rewrite"))
}

@Test("includes the device identifiers so the user can tell which drive moved")
func targetMovedIncludesBothIdentifiers() {
    let message = MediaWriteErrorFormatter.render(.targetMoved(expected: "disk5s1", found: "disk6s2"))

    #expect(message.contains("disk5s1"))
    #expect(message.contains("disk6s2"))
}
