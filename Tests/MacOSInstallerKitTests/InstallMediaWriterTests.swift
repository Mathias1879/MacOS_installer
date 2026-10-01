import Foundation
import Testing
@testable import MacOSInstallerKit

private let diskutilPath = "/usr/sbin/diskutil"
private let targetUUID = "9662C8FB-5D1F-4744-81E0-618FBC801198"

private func infoPlist(id: String, mount: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>DeviceIdentifier</key><string>\(id)</string>
      <key>VolumeName</key><string>SanDisk Ultra</string>
      <key>VolumeUUID</key><string>\(targetUUID)</string>
      <key>MountPoint</key><string>\(mount)</string>
      <key>Internal</key><false/>
      <key>Ejectable</key><true/>
      <key>BusProtocol</key><string>USB</string>
      <key>APFSContainerReference</key><string>disk5</string>
      <key>ParentWholeDisk</key><string>disk5</string>
      <key>WholeDisk</key><false/>
      <key>Size</key><integer>64000000000</integer>
    </dict>
    </plist>
    """
}

private let app = URL(fileURLWithPath: "/Applications/Install macOS Tahoe.app")
private var createInstallMedia: String {
    "\(app.path)/Contents/Resources/createinstallmedia"
}

@Test("re-resolves the target by UUID and erases the mount point it reports")
func resolvesThenWrites() throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(standardOutput: "Install media now available at /Volumes/Install macOS Tahoe",
                for: "/usr/bin/sudo \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction")

    try InstallMediaWriter(runner: runner).write(
        installerApp: app, toVolumeWithUUID: targetUUID,
        expectedDeviceIdentifier: "disk5s1", progress: { _ in }
    )

    // Resolution must come first, then the erase — never the reverse.
    #expect(runner.invocations.count == 2)
    #expect(runner.invocations[0].arguments == ["info", "-plist", targetUUID])
    #expect(runner.invocations[1].executable == "/usr/bin/sudo")
    #expect(runner.invocations[1].arguments == [createInstallMedia, "--volume", "/Volumes/SanDisk Ultra", "--nointeraction"])
}

@Test("passes a mount point containing spaces as a single argument")
func mountPointWithSpacesStaysOneArgument() throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/Untitled 1"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(standardOutput: "ok",
                for: "/usr/bin/sudo \(createInstallMedia) --volume /Volumes/Untitled 1 --nointeraction")

    try InstallMediaWriter(runner: runner).write(
        installerApp: app, toVolumeWithUUID: targetUUID,
        expectedDeviceIdentifier: "disk5s1", progress: { _ in }
    )

    #expect(runner.invocations[1].arguments[2] == "/Volumes/Untitled 1")
}

@Test("aborts without erasing when the target has moved to a different device node")
func abortsWhenTargetMoved() {
    let runner = FakeCommandRunner()
    // Same UUID, but now enumerated as disk7s1 — a replug reshuffled the nodes.
    runner.stub(standardOutput: infoPlist(id: "disk7s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")

    #expect(throws: MediaWriteError.targetMoved(expected: "disk5s1", found: "disk7s1")) {
        try InstallMediaWriter(runner: runner).write(
            installerApp: app, toVolumeWithUUID: targetUUID,
            expectedDeviceIdentifier: "disk5s1", progress: { _ in }
        )
    }

    // THE ASSERTION THAT MATTERS: nothing destructive was issued.
    #expect(runner.didInvoke(containing: "createinstallmedia") == false)
}

@Test("aborts without erasing when the target has disappeared")
func abortsWhenTargetGone() {
    let runner = FakeCommandRunner()
    runner.stub(CommandResult(exitCode: 1, standardOutput: "", standardError: "Could not find disk"),
                for: "\(diskutilPath) info -plist \(targetUUID)")

    #expect(throws: MediaWriteError.targetDisappeared(uuid: targetUUID)) {
        try InstallMediaWriter(runner: runner).write(
            installerApp: app, toVolumeWithUUID: targetUUID,
            expectedDeviceIdentifier: "disk5s1", progress: { _ in }
        )
    }

    #expect(runner.didInvoke(containing: "createinstallmedia") == false)
}

@Test("aborts without erasing when the target is no longer mounted")
func abortsWhenUnmounted() {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: ""),
                for: "\(diskutilPath) info -plist \(targetUUID)")

    #expect(throws: MediaWriteError.targetNotMounted(uuid: targetUUID)) {
        try InstallMediaWriter(runner: runner).write(
            installerApp: app, toVolumeWithUUID: targetUUID,
            expectedDeviceIdentifier: "disk5s1", progress: { _ in }
        )
    }

    #expect(runner.didInvoke(containing: "createinstallmedia") == false)
}

@Test("reports createinstallmedia failure with exit code and stderr")
func reportsWriteFailure() {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(CommandResult(exitCode: 1, standardOutput: "", standardError: "Failed to erase volume"),
                for: "/usr/bin/sudo \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction")

    #expect(throws: MediaWriteError.createInstallMediaFailed(exitCode: 1, message: "Failed to erase volume")) {
        try InstallMediaWriter(runner: runner).write(
            installerApp: app, toVolumeWithUUID: targetUUID,
            expectedDeviceIdentifier: "disk5s1", progress: { _ in }
        )
    }
}
