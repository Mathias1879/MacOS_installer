import Foundation
import Testing
@testable import MacOSInstallerKit

private func vol(_ id: String, _ name: String, _ size: Int64, internalDisk: Bool = false) -> Volume {
    Volume(
        deviceIdentifier: id, volumeName: name, volumeUUID: "UUID-\(id)",
        mountPoint: "/Volumes/\(name)", isInternal: internalDisk, isEjectable: !internalDisk,
        busProtocol: internalDisk ? "Apple Fabric" : "USB",
        apfsContainerReference: "c-\(id)", parentWholeDisk: "p-\(id)",
        sizeBytes: size, isWholeDisk: false
    )
}

@Test("lists selectable volumes and shows why refused ones cannot be chosen")
func rendersDecisions() {
    let output = VolumeTableFormatter.render([
        .init(volume: vol("disk5s1", "SanDisk Ultra", 64_000_000_000), verdict: .selectable),
        .init(volume: vol("disk3s1", "Macintosh HD", 245_000_000_000, internalDisk: true),
              verdict: .refused(.internalDisk)),
    ])

    #expect(output.contains("SanDisk Ultra"))
    #expect(output.contains("64.0 GB"))
    #expect(output.contains("Macintosh HD"))
    #expect(output.contains("internal disk"))
}

@Test("marks a warned volume without hiding it")
func rendersWarning() {
    let output = VolumeTableFormatter.render([
        .init(volume: vol("disk6s1", "Time Machine Backups", 2_000_000_000_000),
              verdict: .selectableWithWarning("This looks like a Time Machine backup.")),
    ])

    #expect(output.contains("Time Machine Backups"))
    #expect(output.contains("Time Machine backup"))
}

@Test("says so clearly when nothing is selectable")
func rendersNoneSelectable() {
    let output = VolumeTableFormatter.render([
        .init(volume: vol("disk3s1", "Macintosh HD", 245_000_000_000, internalDisk: true),
              verdict: .refused(.internalDisk)),
    ])

    #expect(output.contains("No drive"))
}

@Test("shows the device identifier next to every volume, so it is always available to disambiguate")
func rendersDeviceIdentifierForEveryVerdict() {
    let output = VolumeTableFormatter.render([
        .init(volume: vol("disk5s1", "Untitled", 64_000_000_000), verdict: .selectable),
        .init(volume: vol("disk6s2", "Untitled", 500_000_000_000),
              verdict: .selectableWithWarning("warn")),
        .init(volume: vol("disk3s1", "Macintosh HD", 245_000_000_000, internalDisk: true),
              verdict: .refused(.internalDisk)),
    ])

    #expect(output.contains("disk5s1"))
    #expect(output.contains("disk6s2"))
    #expect(output.contains("disk3s1"))
}
