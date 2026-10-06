import Testing
@testable import MacOSInstallerKit

/// The finding from round 2 of the final fix: `CreateCommand.reportWriteOutcome`'s
/// three-branch logic was correct but completely untested, because it lived
/// as a private method on the executable target. The decision now lives in
/// `WriteOutcomeMessage`, in the library, specifically so these three cases —
/// the single most load-bearing sentence this tool prints — have a test
/// behind them. Each test asserts the EXACT rendered text, not a substring,
/// per the fix's requirement.
private func volume(id: String = "disk4s1", name: String) -> Volume {
    Volume(
        deviceIdentifier: id, volumeName: name, volumeUUID: "11111111-1111-1111-1111-111111111111",
        mountPoint: "/Volumes/\(name)", isInternal: false, isEjectable: true, busProtocol: "USB",
        apfsContainerReference: nil, parentWholeDisk: "disk4",
        sizeBytes: 64_000_000_000, isWholeDisk: false
    )
}

@Test("observed volume is nil renders the could-not-be-read-back wording")
func observedVolumeNilRendersUnreadableWording() {
    let target = volume(name: "SanDisk Ultra")

    let outcome = WriteOutcomeMessage.decide(
        target: target, expectedName: "Install macOS Tahoe", observedVolume: nil
    )

    #expect(outcome == .unreadable(deviceIdentifier: "disk4s1", expectedName: "Install macOS Tahoe"))
    #expect(
        outcome.rendered
            == "  The write reported success, but disk4s1 could not be read back afterward to "
                + "confirm it. Check it in Disk Utility before relying on it being named "
                + "\"Install macOS Tahoe\"."
    )
}

@Test("observed name differs renders the mismatch wording and names the OBSERVED name to look for")
func observedNameDifferingRendersMismatchWording() {
    let target = volume(name: "SanDisk Ultra")
    let observed = volume(name: "Untitled")

    let outcome = WriteOutcomeMessage.decide(
        target: target, expectedName: "Install macOS Tahoe", observedVolume: observed
    )

    #expect(outcome == .nameMismatch(observedName: "Untitled", expectedName: "Install macOS Tahoe"))
    #expect(
        outcome.rendered
            == "  The write reported success, but the volume is now named "
                + "\"Untitled\", not \"Install macOS Tahoe\" as expected. "
                + "Look for \"Untitled\" at the boot picker instead."
    )
    // The defect this exists to remove: the user must be told the volume's
    // ACTUAL name, not just warned that something doesn't match.
    #expect(outcome.rendered.contains("Untitled"))
}

@Test("observed name matches renders the success wording")
func observedNameMatchingRendersSuccessWording() {
    let target = volume(name: "SanDisk Ultra")
    let observed = volume(name: "Install macOS Tahoe")

    let outcome = WriteOutcomeMessage.decide(
        target: target, expectedName: "Install macOS Tahoe", observedVolume: observed
    )

    #expect(
        outcome
            == .success(displayName: "SanDisk Ultra", deviceIdentifier: "disk4s1", expectedName: "Install macOS Tahoe")
    )
    #expect(outcome.rendered == "  Done. SanDisk Ultra (disk4s1) is now named \"Install macOS Tahoe\".")
}
