import Foundation
import Testing
@testable import MacOSInstallerKit

private func bootPlistString() -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>DeviceIdentifier</key><string>disk3s1s1</string>
      <key>VolumeName</key><string>Macintosh HD</string>
      <key>VolumeUUID</key><string>DE969922-CD33-4FA5-8020-DD5AE91CAF5C</string>
      <key>MountPoint</key><string>/</string>
      <key>Internal</key><true/>
      <key>APFSContainerReference</key><string>disk3</string>
      <key>ParentWholeDisk</key><string>disk3</string>
      <key>WholeDisk</key><false/>
      <key>Size</key><integer>245107195904</integer>
    </dict>
    </plist>
    """
}

@Test("resolves the boot container from the root mount point")
func resolvesBootContainer() throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: bootPlistString(), for: "/usr/sbin/diskutil info -plist /")
    let resolver = BootVolumeResolver(runner: runner)

    let boot = try resolver.resolve()

    #expect(boot.containerReference == "disk3")
    #expect(boot.parentWholeDisk == "disk3")
    #expect(boot.deviceIdentifier == "disk3s1s1")
}

@Test("queries the root mount point and nothing else")
func queriesRootOnly() throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: bootPlistString(), for: "/usr/sbin/diskutil info -plist /")
    _ = try BootVolumeResolver(runner: runner).resolve()

    #expect(runner.invocations.count == 1)
    #expect(runner.invocations[0].executable == "/usr/sbin/diskutil")
    #expect(runner.invocations[0].arguments == ["info", "-plist", "/"])
}

@Test("throws when diskutil fails rather than reporting no boot volume")
func throwsWhenDiskutilFails() {
    let runner = FakeCommandRunner()
    runner.stub(
        CommandResult(exitCode: 1, standardOutput: "", standardError: "could not find disk"),
        for: "/usr/sbin/diskutil info -plist /"
    )
    let resolver = BootVolumeResolver(runner: runner)

    #expect(throws: BootVolumeResolverError.self) {
        _ = try resolver.resolve()
    }
}

@Test("throws when APFSContainerReference is missing")
func throwsWhenMissingContainer() throws {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>DeviceIdentifier</key><string>disk3s1s1</string>
      <key>VolumeName</key><string>Macintosh HD</string>
      <key>MountPoint</key><string>/</string>
      <key>Internal</key><true/>
      <key>ParentWholeDisk</key><string>disk3</string>
      <key>WholeDisk</key><false/>
      <key>Size</key><integer>245107195904</integer>
    </dict>
    </plist>
    """
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: plist, for: "/usr/sbin/diskutil info -plist /")

    #expect(throws: BootVolumeResolverError.self) {
        _ = try BootVolumeResolver(runner: runner).resolve()
    }
}

@Test("maps the APFS container and the parent whole disk to distinct fields")
func mapsContainerAndParentSeparately() throws {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>DeviceIdentifier</key><string>disk3s1s1</string>
      <key>VolumeName</key><string>Macintosh HD</string>
      <key>MountPoint</key><string>/</string>
      <key>Internal</key><true/>
      <key>APFSContainerReference</key><string>disk3</string>
      <key>ParentWholeDisk</key><string>disk9</string>
      <key>WholeDisk</key><false/>
      <key>Size</key><integer>245107195904</integer>
    </dict>
    </plist>
    """
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: plist, for: "/usr/sbin/diskutil info -plist /")

    let boot = try BootVolumeResolver(runner: runner).resolve()

    #expect(boot.containerReference == "disk3")
    #expect(boot.parentWholeDisk == "disk9")
}
