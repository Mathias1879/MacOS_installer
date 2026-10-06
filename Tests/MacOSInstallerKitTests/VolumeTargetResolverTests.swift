import Foundation
import Testing
@testable import MacOSInstallerKit

private func vol(
    _ id: String,
    _ name: String,
    verdict: VolumeGuard.Verdict = .selectable,
    internalDisk: Bool = false
) -> VolumeGuard.VolumeDecision {
    let volume = Volume(
        deviceIdentifier: id, volumeName: name, volumeUUID: "UUID-\(id)",
        mountPoint: "/Volumes/\(name)", isInternal: internalDisk, isEjectable: !internalDisk,
        busProtocol: internalDisk ? "Apple Fabric" : "USB",
        apfsContainerReference: "c-\(id)", parentWholeDisk: "p-\(id)",
        sizeBytes: 64_000_000_000, isWholeDisk: false
    )
    return VolumeGuard.VolumeDecision(volume: volume, verdict: verdict)
}

// This machine genuinely has two mounted external volumes both named
// "Untitled" (disk5s1 and disk6s2) — this is not a contrived fixture.
private let twoUntitledVolumes: [VolumeGuard.VolumeDecision] = [
    vol("disk5s1", "Untitled"),
    vol("disk6s2", "Untitled"),
]

@Test("an ambiguous name match is refused, not resolved to the first candidate")
func ambiguousNameMatchIsRefused() {
    let resolution = VolumeTargetResolver.resolve(matching: "Untitled", among: twoUntitledVolumes)

    guard case .ambiguous(let candidates) = resolution else {
        Issue.record("expected .ambiguous, got \(resolution)")
        return
    }
    #expect(candidates.count == 2)
    #expect(candidates.map(\.volume.deviceIdentifier).sorted() == ["disk5s1", "disk6s2"])
}

@Test("an exact device-identifier match is unambiguous even when names collide")
func deviceIdentifierMatchIsUnambiguousDespiteNameCollision() {
    let resolution = VolumeTargetResolver.resolve(matching: "disk6s2", among: twoUntitledVolumes)

    guard case .unique(let found) = resolution else {
        Issue.record("expected .unique, got \(resolution)")
        return
    }
    #expect(found.volume.deviceIdentifier == "disk6s2")
}

@Test("a name matching exactly one volume resolves uniquely")
func uniqueNameMatchResolves() {
    let decisions = [vol("disk5s1", "SanDisk Ultra"), vol("disk3s1", "Macintosh HD", internalDisk: true)]

    let resolution = VolumeTargetResolver.resolve(matching: "SanDisk Ultra", among: decisions)

    #expect(resolution == .unique(decisions[0]))
}

@Test("no match returns none")
func noMatchReturnsNone() {
    let decisions = [vol("disk5s1", "SanDisk Ultra")]

    #expect(VolumeTargetResolver.resolve(matching: "Nonexistent", among: decisions) == .none)
}

@Test("a refused volume is never offered as a match, by name or by device identifier")
func refusedVolumeIsNeverOffered() {
    let decisions = [vol("disk3s1", "Macintosh HD", verdict: .refused(.internalDisk), internalDisk: true)]

    #expect(VolumeTargetResolver.resolve(matching: "Macintosh HD", among: decisions) == .none)
    #expect(VolumeTargetResolver.resolve(matching: "disk3s1", among: decisions) == .none)
}

@Test("a volume selectable only with a warning can still be matched")
func warnedVolumeCanBeMatched() {
    let decisions = [vol("disk6s1", "Time Machine Backups", verdict: .selectableWithWarning("warn"))]

    #expect(VolumeTargetResolver.resolve(matching: "Time Machine Backups", among: decisions)
        == .unique(decisions[0]))
}

@Test("resolving by name surfaces the warning verdict, not just the volume")
func uniqueMatchCarriesItsWarningVerdict() {
    let decisions = [vol("disk6s1", "Time Machine Backups", verdict: .selectableWithWarning("looks like a backup"))]

    let resolution = VolumeTargetResolver.resolve(matching: "Time Machine Backups", among: decisions)

    guard case .unique(let found) = resolution else {
        Issue.record("expected .unique, got \(resolution)")
        return
    }
    #expect(found.verdict == .selectableWithWarning("looks like a backup"))
}

// MARK: - I1: a named-but-refused volume's reason is still reachable

/// `resolve` itself must keep returning `.none` for a refused volume — that
/// is the safety property `refusedVolumeIsNeverOffered` above pins — but a
/// caller handling `.none` needs a way to tell "no match exists at all" apart
/// from "that volume was found and refused, and here is why", or a user who
/// typed the EXACT name of a drive this tool rejected sees the same generic
/// listing as someone who mistyped a name that matches nothing.
@Test("refusalReason finds the exact reason for a refused volume matched by name")
func refusalReasonFindsExactNameMatch() {
    let decisions = [vol("disk3s1", "Macintosh HD", verdict: .refused(.internalDisk), internalDisk: true)]

    #expect(VolumeTargetResolver.refusalReason(forExactMatch: "Macintosh HD", among: decisions) == .internalDisk)
}

@Test("refusalReason finds the exact reason for a refused volume matched by device identifier")
func refusalReasonFindsExactDeviceIdentifierMatch() {
    let decisions = [vol("disk3s1", "Macintosh HD", verdict: .refused(.internalDisk), internalDisk: true)]

    #expect(VolumeTargetResolver.refusalReason(forExactMatch: "disk3s1", among: decisions) == .internalDisk)
}

@Test("refusalReason returns nil when no volume, refused or otherwise, matches the query")
func refusalReasonReturnsNilForNoMatch() {
    let decisions = [vol("disk5s1", "SanDisk Ultra")]

    #expect(VolumeTargetResolver.refusalReason(forExactMatch: "Nonexistent", among: decisions) == nil)
}

@Test("refusalReason returns nil for a volume that is selectable, not refused")
func refusalReasonReturnsNilForSelectableVolume() {
    let decisions = [vol("disk5s1", "SanDisk Ultra")]

    #expect(VolumeTargetResolver.refusalReason(forExactMatch: "SanDisk Ultra", among: decisions) == nil)
}
