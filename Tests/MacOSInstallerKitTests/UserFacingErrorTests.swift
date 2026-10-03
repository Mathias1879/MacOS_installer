import Testing
@testable import MacOSInstallerKit

@Test("renders all three parts with the title, in order")
func rendersThreeParts() {
    let error = UserFacingError(
        title: "Couldn't erase the drive",
        whatHappened: #"macOS refused to erase "SanDisk Ultra"."#,
        whatItMeans: "This usually means the drive is damaged, or formatted in a way macOS can't overwrite.",
        whatToDoNext: [
            "Open Disk Utility (it's in Applications, inside the Utilities folder)",
            "Select SanDisk Ultra in the list on the left",
            "Click Erase",
            #"Set Format to "Mac OS Extended (Journaled)""#,
            "Click Erase, then run this command again",
        ],
        logReference: "~/Library/Logs/macos-installer/2026-10-03.log"
    )

    let out = error.rendered()
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    // The title leads, marked so it is findable in a scrollback.
    #expect(lines[0].contains("Couldn't erase the drive"))
    #expect(lines[0].contains("✗"))

    // All three parts appear, in the spec's order.
    let happenedAt = try! #require(out.range(of: "macOS refused to erase"))
    let meansAt = try! #require(out.range(of: "This usually means"))
    let nextAt = try! #require(out.range(of: "Open Disk Utility"))
    #expect(happenedAt.lowerBound < meansAt.lowerBound)
    #expect(meansAt.lowerBound < nextAt.lowerBound)

    // Steps are numbered, one per line.
    #expect(out.contains("1. Open Disk Utility"))
    #expect(out.contains("5. Click Erase, then run this command again"))

    // The log path is reachable from the message.
    #expect(out.contains("~/Library/Logs/macos-installer/2026-10-03.log"))
}

@Test("omits the meaning section when there is nothing useful to add")
func omitsAbsentMeaning() {
    let error = UserFacingError(
        title: "Couldn't reach Apple",
        whatHappened: "The download couldn't start.",
        whatItMeans: nil,
        whatToDoNext: ["Check your internet connection, then run this command again"],
        logReference: nil
    )

    let out = error.rendered()

    #expect(out.contains("Couldn't reach Apple"))
    #expect(out.contains("The download couldn't start."))
    #expect(out.contains("1. Check your internet connection"))
    // No empty section header, no stray blank run where the meaning would be.
    #expect(out.contains("\n\n\n") == false)
}

@Test("renders without a next-steps section when there is genuinely nothing to try")
func omitsEmptyNextSteps() {
    let error = UserFacingError(
        title: "The drive is in an unknown state",
        whatHappened: "The erase started and did not finish.",
        whatItMeans: "The drive is not safe to boot from.",
        whatToDoNext: [],
        logReference: nil
    )

    let out = error.rendered()

    #expect(out.contains("unknown state"))
    #expect(out.contains("To fix it") == false)
}
