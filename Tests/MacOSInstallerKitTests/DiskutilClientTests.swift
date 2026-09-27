import Foundation
import Testing
@testable import MacOSInstallerKit

private func diskFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "plist"))
    return try Data(contentsOf: url)
}

@Test("parses an external volume including a mount point containing a space")
func parsesExternalVolume() throws {
    let volume = try DiskutilClient.parseInfo(diskFixture("diskutil-info-external"))

    #expect(volume.deviceIdentifier == "disk5s1")
    #expect(volume.volumeName == "Untitled")
    #expect(volume.volumeUUID == "9662C8FB-5D1F-4744-81E0-618FBC801198")
    #expect(volume.mountPoint == "/Volumes/Untitled 1")
    #expect(volume.isInternal == false)
    #expect(volume.isEjectable)
    #expect(volume.busProtocol == "USB")
    #expect(volume.apfsContainerReference == "disk5")
    #expect(volume.sizeBytes == 499_898_081_280)
    #expect(volume.isWholeDisk == false)
    #expect(volume.isMounted)
}

@Test("parses the internal boot volume as internal")
func parsesInternalVolume() throws {
    let volume = try DiskutilClient.parseInfo(diskFixture("diskutil-info-macintosh-hd"))

    #expect(volume.isInternal)
    #expect(volume.apfsContainerReference == "disk3")
    #expect(volume.isMounted == false)
}

@Test("treats an empty mount point as unmounted rather than an empty path")
func emptyMountPointIsNil() throws {
    let volume = try DiskutilClient.parseInfo(diskFixture("diskutil-info-wholedisk"))

    #expect(volume.mountPoint == nil)
    #expect(volume.isMounted == false)
    #expect(volume.isWholeDisk)
    #expect(volume.volumeUUID == nil)
}

@Test("the snapshot at / and the real boot volume differ by UUID but share a container")
func snapshotAndBootVolumeShareContainer() throws {
    let snapshot = try DiskutilClient.parseInfo(diskFixture("diskutil-info-boot"))
    let bootVolume = try DiskutilClient.parseInfo(diskFixture("diskutil-info-macintosh-hd"))

    // This is the trap the guard must survive: matching on UUID would not
    // recognise Macintosh HD as the boot volume.
    #expect(snapshot.volumeUUID != bootVolume.volumeUUID)
    #expect(snapshot.apfsContainerReference == bootVolume.apfsContainerReference)
}

@Test("reports notAPropertyList for data that is not a property list")
func parseInfoThrowsOnInvalidData() {
    #expect(throws: DiskutilParseError.notAPropertyList) {
        try DiskutilClient.parseInfo(Data("nonsense".utf8))
    }
}

@Test("reports missingDeviceIdentifier for a plist without one")
func throwsOnMissingIdentifier() throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: ["VolumeName": "Nameless"], format: .xml, options: 0
    )

    #expect(throws: DiskutilParseError.missingDeviceIdentifier) {
        try DiskutilClient.parseInfo(data)
    }
}
