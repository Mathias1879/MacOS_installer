import Foundation
import Testing
@testable import MacOSInstallerKit

private func volume(
    id: String = "disk5s1",
    name: String = "SanDisk Ultra",
    uuid: String? = "9662C8FB-5D1F-4744-81E0-618FBC801198",
    mount: String? = "/Volumes/SanDisk Ultra",
    isInternal: Bool = false,
    container: String? = "disk5",
    parent: String = "disk5",
    size: Int64 = 64_000_000_000,
    wholeDisk: Bool = false
) -> Volume {
    Volume(
        deviceIdentifier: id, volumeName: name, volumeUUID: uuid, mountPoint: mount,
        isInternal: isInternal, isEjectable: !isInternal, busProtocol: isInternal ? "Apple Fabric" : "USB",
        apfsContainerReference: container, parentWholeDisk: parent,
        sizeBytes: size, isWholeDisk: wholeDisk
    )
}

private let boot = BootVolume(
    deviceIdentifier: "disk3s1s1", containerReference: "disk3", parentWholeDisk: "disk3"
)

private func verdict(
    for v: Volume,
    required: Int64 = 18_000_000_000,
    protectedPaths: [String] = []
) -> VolumeGuard.Verdict {
    VolumeGuard.evaluate(
        volumes: [v], bootVolume: boot, requiredBytes: required, protectedPaths: protectedPaths
    )[0].verdict
}

@Test("a healthy external volume is selectable")
func externalIsSelectable() {
    #expect(verdict(for: volume()) == .selectable)
}

@Test("an internal disk is refused")
func internalIsRefused() {
    #expect(verdict(for: volume(isInternal: true, container: "disk9", parent: "disk9")) == .refused(.internalDisk))
}

@Test("the real boot volume is refused even though its UUID differs from the one reported for /")
func bootVolumeIsRefusedDespiteDifferentUUID() {
    // Macintosh HD: UUID 9E97EE00… while / reports DE969922…, same container disk3.
    let macintoshHD = volume(
        id: "disk3s1", name: "Macintosh HD",
        uuid: "9E97EE00-B7B4-4C33-9220-09F0CAFC59DE",
        mount: nil, isInternal: true, container: "disk3", parent: "disk3"
    )

    // Internal is checked first, so that is the specific reason it is
    // refused. The container rule is isolated independently below by
    // `bootContainerRefusedIndependentOfInternalFlag`.
    #expect(verdict(for: macintoshHD) == .refused(.internalDisk))
}

@Test("a volume in the boot container is refused even when it reports as external")
func bootContainerRefusedIndependentOfInternalFlag() {
    // Contrived but precise: isolates the container rule from the internal rule.
    let sneaky = volume(isInternal: false, container: "disk3", parent: "disk3")

    #expect(verdict(for: sneaky) == .refused(.bootContainer))
}

@Test("the container rule alone refuses a volume whose parent whole disk differs from the boot volume's")
func bootContainerRefusedIndependentOfParentWholeDisk() {
    // Isolates the apfsContainerReference comparison from the parentWholeDisk
    // backstop: container matches the boot container, but parentWholeDisk
    // deliberately does not match boot.parentWholeDisk ("disk3"). Only the
    // container check can catch this candidate.
    let sneaky = volume(isInternal: false, container: "disk3", parent: "disk9")

    #expect(verdict(for: sneaky) == .refused(.bootContainer))
}

@Test("the parent whole disk backstop refuses a volume with no APFS container that shares the boot disk")
func bootContainerBackstopCatchesMissingContainer() {
    // Isolates the parentWholeDisk backstop from the container check: this
    // candidate reports no APFS container at all (e.g. a non-APFS partition),
    // so only matching on parentWholeDisk can recognise it shares the boot
    // disk ("disk3").
    let nonAPFSPartitionOnBootDisk = volume(isInternal: false, container: nil, parent: "disk3")

    #expect(verdict(for: nonAPFSPartitionOnBootDisk) == .refused(.bootContainer))
}

@Test("an unmounted volume is refused")
func unmountedIsRefused() {
    #expect(verdict(for: volume(mount: nil)) == .refused(.notMounted))
}

@Test("a whole disk is refused")
func wholeDiskIsRefused() {
    #expect(verdict(for: volume(wholeDisk: true)) == .refused(.wholeDisk))
}

@Test("a volume holding a protected path is refused so the tool cannot destroy its own input")
func protectedPathIsRefused() {
    let v = volume(mount: "/Volumes/Work")

    #expect(
        verdict(for: v, protectedPaths: ["/Volumes/Work/caches/InstallAssistant.pkg"])
            == .refused(.holdsProtectedPath("/Volumes/Work/caches/InstallAssistant.pkg"))
    )
}

@Test("a volume smaller than the installer plus headroom is refused with both numbers")
func tooSmallIsRefused() {
    let v = volume(size: 8_000_000_000)

    #expect(
        verdict(for: v, required: 18_000_000_000)
            == .refused(.tooSmall(capacityBytes: 8_000_000_000, requiredBytes: 20_000_000_000))
    )
}

@Test("capacity must exceed the installer size plus two gigabytes of headroom")
func headroomIsApplied() {
    // Exactly installer + headroom is acceptable; one byte less is not.
    let exact = volume(size: 20_000_000_000)
    let short = volume(size: 19_999_999_999)

    #expect(verdict(for: exact, required: 18_000_000_000) == .selectable)
    #expect(verdict(for: short, required: 18_000_000_000) != .selectable)
}

@Test("a Time Machine volume is offered but warned about")
func timeMachineIsWarned() {
    let tm = volume(name: "Time Machine Backups")

    #expect(verdict(for: tm) == .selectableWithWarning("This looks like a Time Machine backup."))
}

@Test("evaluates every volume and preserves input order")
func preservesOrder() {
    let decisions = VolumeGuard.evaluate(
        volumes: [volume(id: "disk5s1"), volume(id: "disk6s1", isInternal: true, container: "disk6", parent: "disk6")],
        bootVolume: boot,
        requiredBytes: 1_000,
        protectedPaths: []
    )

    #expect(decisions.map(\.volume.deviceIdentifier) == ["disk5s1", "disk6s1"])
    #expect(decisions.map(\.verdict) == [.selectable, .refused(.internalDisk)])
}

@Test("every refusal reason carries a user-facing message")
func refusalReasonsHaveMessages() {
    let reasons: [VolumeGuard.RefusalReason] = [
        .internalDisk, .bootContainer, .notMounted, .wholeDisk,
        .holdsProtectedPath("/x"), .tooSmall(capacityBytes: 1, requiredBytes: 2),
    ]

    for reason in reasons {
        #expect(reason.userMessage.isEmpty == false)
    }
}

@Test("protected-path matching is case-insensitive, as APFS is")
func protectedPathIsCaseInsensitive() {
    let v = volume(mount: "/Volumes/Work")
    #expect(verdict(for: v, protectedPaths: ["/volumes/work/caches/x.pkg"])
        == .refused(.holdsProtectedPath("/volumes/work/caches/x.pkg")))
}

@Test("protected-path matching survives Unicode normalization differences")
func protectedPathHandlesUnicodeNormalization() {
    // "Café" precomposed in the mount point, decomposed in the path.
    let v = volume(mount: "/Volumes/Caf\u{00E9}")
    #expect(verdict(for: v, protectedPaths: ["/Volumes/Cafe\u{0301}/caches/x.pkg"])
        == .refused(.holdsProtectedPath("/Volumes/Cafe\u{0301}/caches/x.pkg")))
}

@Test("a negative requiredBytes still requires at least the headroom")
func negativeRequiredBytesStillRequiresHeadroom() {
    let tooSmall = volume(size: 1_999_999_999)
    let exact = volume(size: 2_000_000_000)

    #expect(
        verdict(for: tooSmall, required: -5)
            == .refused(.tooSmall(capacityBytes: 1_999_999_999, requiredBytes: 2_000_000_000))
    )
    #expect(verdict(for: exact, required: -5) == .selectable)
}

@Test("--yes does not skip the typed confirmation for a warned (e.g. Time Machine) volume")
func yesDoesNotSkipConfirmationForWarnedVolume() {
    let warned = VolumeGuard.Verdict.selectableWithWarning("This looks like a Time Machine backup.")

    #expect(VolumeGuard.requiresTypedConfirmation(yesFlag: true, verdict: warned) == true)
    #expect(VolumeGuard.requiresTypedConfirmation(yesFlag: false, verdict: warned) == true)
}

@Test("--yes skips the typed confirmation for an ordinary selectable volume")
func yesSkipsConfirmationForOrdinaryVolume() {
    #expect(VolumeGuard.requiresTypedConfirmation(yesFlag: true, verdict: .selectable) == false)
    #expect(VolumeGuard.requiresTypedConfirmation(yesFlag: false, verdict: .selectable) == true)
}
