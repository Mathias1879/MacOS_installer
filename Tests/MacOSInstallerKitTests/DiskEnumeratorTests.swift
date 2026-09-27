import Foundation
import Testing
@testable import MacOSInstallerKit

private let listPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AllDisks</key>
  <array><string>disk3s1</string><string>disk5s1</string></array>
</dict>
</plist>
"""

private func infoPlist(id: String, name: String, mount: String, isInternal: Bool, container: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>DeviceIdentifier</key><string>\(id)</string>
      <key>VolumeName</key><string>\(name)</string>
      <key>VolumeUUID</key><string>UUID-\(id)</string>
      <key>MountPoint</key><string>\(mount)</string>
      <key>Internal</key><\(isInternal ? "true" : "false")/>
      <key>Ejectable</key><\(isInternal ? "false" : "true")/>
      <key>BusProtocol</key><string>\(isInternal ? "Apple Fabric" : "USB")</string>
      <key>APFSContainerReference</key><string>\(container)</string>
      <key>ParentWholeDisk</key><string>\(container)</string>
      <key>WholeDisk</key><false/>
      <key>Size</key><integer>64000000000</integer>
    </dict>
    </plist>
    """
}

@Test("enumerates each volume reported by diskutil list, in order")
func enumeratesVolumes() throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: listPlist, for: "/usr/sbin/diskutil list -plist")
    runner.stub(
        standardOutput: infoPlist(id: "disk3s1", name: "Macintosh HD", mount: "/", isInternal: true, container: "disk3"),
        for: "/usr/sbin/diskutil info -plist disk3s1"
    )
    runner.stub(
        standardOutput: infoPlist(id: "disk5s1", name: "Untitled", mount: "/Volumes/Untitled 1", isInternal: false, container: "disk5"),
        for: "/usr/sbin/diskutil info -plist disk5s1"
    )

    let volumes = try DiskEnumerator(runner: runner).mountedVolumes()

    #expect(volumes.map(\.deviceIdentifier) == ["disk3s1", "disk5s1"])
    #expect(volumes.map(\.volumeName) == ["Macintosh HD", "Untitled"])
}

@Test("skips a volume whose info cannot be read rather than failing the whole listing")
func skipsUnreadableVolume() throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: listPlist, for: "/usr/sbin/diskutil list -plist")
    runner.stub(
        standardOutput: infoPlist(id: "disk5s1", name: "Untitled", mount: "/Volumes/Untitled 1", isInternal: false, container: "disk5"),
        for: "/usr/sbin/diskutil info -plist disk5s1"
    )
    // disk3s1 intentionally unstubbed — the fake returns a failing result.

    let volumes = try DiskEnumerator(runner: runner).mountedVolumes()

    #expect(volumes.map(\.deviceIdentifier) == ["disk5s1"])
}

@Test("throws when the list command itself fails")
func throwsWhenListFails() {
    let runner = FakeCommandRunner()
    runner.stub(
        CommandResult(exitCode: 1, standardOutput: "", standardError: "diskutil exploded"),
        for: "/usr/sbin/diskutil list -plist"
    )

    #expect(throws: DiskEnumeratorError.self) {
        _ = try DiskEnumerator(runner: runner).mountedVolumes()
    }
}
