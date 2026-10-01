import Foundation
import Testing
@testable import MacOSInstallerKit

private let diskutilPath = "/usr/sbin/diskutil"
private let sudoPath = "/usr/bin/sudo"
private let targetUUID = "9662C8FB-5D1F-4744-81E0-618FBC801198"

private func infoPlist(id: String, mount: String, uuid: String = targetUUID) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>DeviceIdentifier</key><string>\(id)</string>
      <key>VolumeName</key><string>SanDisk Ultra</string>
      <key>VolumeUUID</key><string>\(uuid)</string>
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

/// A real (but harmless) temp-directory "app bundle" with an executable file
/// at the expected createinstallmedia path, so the tool-existence guard
/// passes without touching anything under /Applications or any real
/// installer. Created once per test-process run.
private let app: URL = {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InstallMediaWriterTests-\(UUID().uuidString).app")
    let resources = root.appendingPathComponent("Contents/Resources")
    try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let tool = resources.appendingPathComponent("createinstallmedia")
    FileManager.default.createFile(
        atPath: tool.path,
        contents: Data(),
        attributes: [.posixPermissions: 0o755]
    )
    return root
}()

private var createInstallMedia: String {
    "\(app.path)/Contents/Resources/createinstallmedia"
}

/// Stubs a successful `sudo -v` authentication check on `runner`.
private func stubSuccessfulAuthentication(on runner: FakeCommandRunner) {
    runner.stub(standardOutput: "", for: "\(sudoPath) -v")
}

/// Thread-safe collector for progress messages. `progress` is `@Sendable`, so
/// a plain captured `var` cannot be mutated from inside it; this mirrors
/// FakeCommandRunner's own lock-protected, `@unchecked Sendable` style.
private final class MessageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(message)
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

@Test("re-resolves the target by UUID and erases the mount point it reports")
func resolvesThenWrites() throws {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(standardOutput: "Install media now available at /Volumes/Install macOS Tahoe",
                for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction")

    try InstallMediaWriter(runner: runner).write(
        installerApp: app, toVolumeWithUUID: targetUUID,
        expectedDeviceIdentifier: "disk5s1", progress: { _ in }
    )

    // Authentication, then resolution, then the erase — never any other order.
    #expect(runner.invocations.count == 3)
    #expect(runner.invocations[0].executable == sudoPath)
    #expect(runner.invocations[0].arguments == ["-v"])
    #expect(runner.invocations[1].arguments == ["info", "-plist", targetUUID])
    #expect(runner.invocations[2].executable == sudoPath)
    #expect(runner.invocations[2].arguments == [createInstallMedia, "--volume", "/Volumes/SanDisk Ultra", "--nointeraction"])
}

@Test("authenticates with sudo before re-resolving the target")
func authenticatesBeforeResolving() throws {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(standardOutput: "ok",
                for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction")

    try InstallMediaWriter(runner: runner).write(
        installerApp: app, toVolumeWithUUID: targetUUID,
        expectedDeviceIdentifier: "disk5s1", progress: { _ in }
    )

    #expect(runner.invocations[0].executable == sudoPath)
    #expect(runner.invocations[0].arguments == ["-v"])
    #expect(runner.invocations[1].executable == diskutilPath)
}

@Test("aborts without erasing when sudo authentication fails")
func abortsWhenAuthenticationFails() {
    let runner = FakeCommandRunner()
    runner.stub(CommandResult(exitCode: 1, standardOutput: "", standardError: "Sorry, try again."),
                for: "\(sudoPath) -v")

    #expect(throws: MediaWriteError.authenticationFailed(message: "Sorry, try again.")) {
        try InstallMediaWriter(runner: runner).write(
            installerApp: app, toVolumeWithUUID: targetUUID,
            expectedDeviceIdentifier: "disk5s1", progress: { _ in }
        )
    }

    #expect(runner.didInvoke(containing: "diskutil") == false)
    #expect(runner.didInvoke(containing: "createinstallmedia") == false)
}

/// Stands in for a `sudo` that cannot be launched at all (as opposed to one
/// that launches and exits non-zero, already covered by
/// `abortsWhenAuthenticationFails`).
private struct ThrowingAuthRunner: CommandRunner, Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        throw CommandError.launchFailed(executable: executable, reason: "no such file")
    }
}

@Test("wraps a sudo launch failure as authenticationFailed, so CommandError cannot leak past the MediaWriteError catch")
func wrapsSudoLaunchFailureAsAuthenticationFailed() {
    do {
        try InstallMediaWriter(runner: ThrowingAuthRunner()).write(
            installerApp: app, toVolumeWithUUID: targetUUID,
            expectedDeviceIdentifier: "disk5s1", progress: { _ in }
        )
        Issue.record("expected write(installerApp:) to throw")
    } catch let error as MediaWriteError {
        guard case .authenticationFailed(let message) = error else {
            Issue.record("expected .authenticationFailed, got \(error)")
            return
        }
        #expect(message.contains("sudo could not be run"))
    } catch {
        Issue.record("expected a MediaWriteError, but CommandError leaked out instead: \(error)")
    }
}

@Test("passes a mount point containing spaces as a single argument")
func mountPointWithSpacesStaysOneArgument() throws {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/Untitled 1"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(standardOutput: "ok",
                for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/Untitled 1 --nointeraction")

    try InstallMediaWriter(runner: runner).write(
        installerApp: app, toVolumeWithUUID: targetUUID,
        expectedDeviceIdentifier: "disk5s1", progress: { _ in }
    )

    #expect(runner.invocations[2].arguments[2] == "/Volumes/Untitled 1")
}

@Test("calls progress with a human-readable status before erasing")
func callsProgressBeforeErasing() throws {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(standardOutput: "ok",
                for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction")

    let collector = MessageCollector()
    try InstallMediaWriter(runner: runner).write(
        installerApp: app, toVolumeWithUUID: targetUUID,
        expectedDeviceIdentifier: "disk5s1", progress: { collector.record($0) }
    )

    #expect(!collector.messages.isEmpty)
    #expect(collector.messages.allSatisfy { !$0.isEmpty })
}

@Test("aborts without erasing when the target has moved to a different device node")
func abortsWhenTargetMoved() {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
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

@Test("aborts without erasing when the resolved volume's UUID does not match the requested one")
func abortsWhenResolvedVolumeUUIDDiffers() {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    // Device identifier matches, but diskutil resolved a different volume's
    // UUID — e.g. it was handed an ambiguous name instead of a UUID and
    // matched the wrong disk. The device-identifier guard alone would miss
    // this; the UUID must be checked as its own independent binding.
    let differentUUID = "00000000-0000-0000-0000-000000000000"
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra", uuid: differentUUID),
                for: "\(diskutilPath) info -plist \(targetUUID)")

    #expect(throws: MediaWriteError.targetMoved(expected: "disk5s1", found: "disk5s1")) {
        try InstallMediaWriter(runner: runner).write(
            installerApp: app, toVolumeWithUUID: targetUUID,
            expectedDeviceIdentifier: "disk5s1", progress: { _ in }
        )
    }

    #expect(runner.didInvoke(containing: "createinstallmedia") == false)
}

@Test("aborts without erasing when the target has disappeared")
func abortsWhenTargetGone() {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
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
    stubSuccessfulAuthentication(on: runner)
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

@Test("aborts before authenticating when the installer tool is missing")
func abortsWhenInstallerToolMissing() {
    let runner = FakeCommandRunner()
    let missingApp = URL(
        fileURLWithPath: "/private/tmp/InstallMediaWriterTests-missing-\(UUID().uuidString)/Install macOS Tahoe.app"
    )
    let expectedPath = missingApp.appendingPathComponent("Contents/Resources/createinstallmedia").path

    #expect(throws: MediaWriteError.installerToolMissing(path: expectedPath)) {
        try InstallMediaWriter(runner: runner).write(
            installerApp: missingApp, toVolumeWithUUID: targetUUID,
            expectedDeviceIdentifier: "disk5s1", progress: { _ in }
        )
    }

    // Nothing was invoked at all — not even the password prompt.
    #expect(runner.invocations.isEmpty)
}

@Test("reports createinstallmedia failure as a possibly-partial, unknown drive state")
func reportsWriteFailure() {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(CommandResult(exitCode: 1, standardOutput: "", standardError: "Failed to erase volume"),
                for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction")

    #expect(throws: MediaWriteError.writeFailedDriveStateUnknown(exitCode: 1, message: "Failed to erase volume")) {
        try InstallMediaWriter(runner: runner).write(
            installerApp: app, toVolumeWithUUID: targetUUID,
            expectedDeviceIdentifier: "disk5s1", progress: { _ in }
        )
    }
}

@Test("falls back to stdout for the failure message when stderr is empty")
func reportsWriteFailureUsingStdoutWhenStderrEmpty() {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(
        CommandResult(exitCode: 1, standardOutput: "Usage: createinstallmedia --volume <path>", standardError: ""),
        for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction"
    )

    #expect(throws: MediaWriteError.writeFailedDriveStateUnknown(
        exitCode: 1, message: "Usage: createinstallmedia --volume <path>"
    )) {
        try InstallMediaWriter(runner: runner).write(
            installerApp: app, toVolumeWithUUID: targetUUID,
            expectedDeviceIdentifier: "disk5s1", progress: { _ in }
        )
    }
}
