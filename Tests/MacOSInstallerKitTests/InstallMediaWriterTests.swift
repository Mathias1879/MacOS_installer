import Foundation
import Testing
@testable import MacOSInstallerKit

private let diskutilPath = "/usr/sbin/diskutil"
private let sudoPath = "/usr/bin/sudo"
private let targetUUID = "9662C8FB-5D1F-4744-81E0-618FBC801198"

private func infoPlist(id: String, mount: String, uuid: String = targetUUID, name: String = "SanDisk Ultra") -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>DeviceIdentifier</key><string>\(id)</string>
      <key>VolumeName</key><string>\(name)</string>
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

/// Stubs the post-write re-resolution `InstallMediaWriter.write` performs
/// (C4) once `createinstallmedia` has exited zero — `diskutil info -plist
/// <expectedDeviceIdentifier>`, keyed by device identifier rather than by
/// `targetUUID`, since that is what the write re-resolves by after the erase.
/// A test that omits this stub still passes `write` itself (the fake's
/// unstubbed response is a non-zero exit, which `try?` turns into `nil`
/// rather than a thrown error) but gets `nil` back instead of a `Volume`.
private func stubPostWriteResolution(on runner: FakeCommandRunner, deviceIdentifier: String, volumeName: String) {
    runner.stub(
        standardOutput: infoPlist(id: deviceIdentifier, mount: "/Volumes/\(volumeName)", name: volumeName),
        for: "\(diskutilPath) info -plist \(deviceIdentifier)"
    )
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

/// A single ordered timeline that both `progress(...)` calls and runner
/// invocations append to, so a test can assert that one entry's INDEX
/// precedes another's — an ordering property, not proximity within either
/// source alone. Lock-protected for the same reason as `MessageCollector`:
/// `progress` is `@Sendable`.
private final class OrderedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
    }

    var entriesSoFar: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

/// Wraps a `FakeCommandRunner`, logging each invocation's command line to a
/// shared `OrderedEventLog` before delegating. This is the seam that lets a
/// test fold runner invocations and `progress(...)` calls into one timeline
/// instead of two separately-ordered lists that can't be compared by index.
private struct LoggingCommandRunner: CommandRunner, Sendable {
    let wrapped: FakeCommandRunner
    let log: OrderedEventLog

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        log.record(([executable] + arguments).joined(separator: " "))
        return try wrapped.run(executable, arguments)
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
    stubPostWriteResolution(on: runner, deviceIdentifier: "disk5s1", volumeName: "Install macOS Tahoe")

    try InstallMediaWriter(runner: runner).write(
        installerApp: app, toVolumeWithUUID: targetUUID,
        expectedDeviceIdentifier: "disk5s1", progress: { _ in }
    )

    // Authentication, pre-erase resolution, the erase, then the post-erase
    // re-resolution (C4) — never any other order.
    #expect(runner.invocations.count == 4)
    #expect(runner.invocations[0].executable == sudoPath)
    #expect(runner.invocations[0].arguments == ["-v"])
    #expect(runner.invocations[1].arguments == ["info", "-plist", targetUUID])
    #expect(runner.invocations[2].executable == sudoPath)
    #expect(runner.invocations[2].arguments == [createInstallMedia, "--volume", "/Volumes/SanDisk Ultra", "--nointeraction"])
    #expect(runner.invocations[3].arguments == ["info", "-plist", "disk5s1"])
}

@Test("authenticates with sudo before re-resolving the target")
func authenticatesBeforeResolving() throws {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(standardOutput: "ok",
                for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction")
    stubPostWriteResolution(on: runner, deviceIdentifier: "disk5s1", volumeName: "Install macOS Tahoe")

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

/// C2 (second half) of the final fix round: `sudo -v` here is a SECOND,
/// independent password prompt — `InstallAssistantAssembler` raises the
/// first, for a downloaded release, but every release reaches this `sudo -v`
/// regardless of how it was obtained. Sudo's default `timestamp_timeout` is
/// 5 minutes and an ~18 GB install routinely exceeds it, so this prompt
/// commonly appears with nothing printed in front of it. This pins that the
/// progress call PRECEDES the `sudo -v` INVOCATION — the actual claim —
/// rather than merely which message came first among messages, which stays
/// green even if `progress(...)` were moved to run after `sudo -v` has
/// already prompted.
///
/// MUTATION PROOF (round-3 Finding A): move the `progress(...)` call in
/// `InstallMediaWriter.write` to just before `let volume = try
/// resolve(uuid: uuid)` — i.e. after `sudo -v` has already run — and this
/// assertion fails: the logged `sudo -v` entry's index comes before the
/// logged progress entry's index instead of after it.
@Test("announces that a password is needed before the sudo -v authentication check runs")
func announcesPasswordNeedBeforeSudoDashV() throws {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(standardOutput: "ok",
                for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction")

    let log = OrderedEventLog()
    let loggingRunner = LoggingCommandRunner(wrapped: runner, log: log)

    try InstallMediaWriter(runner: loggingRunner).write(
        installerApp: app, toVolumeWithUUID: targetUUID,
        expectedDeviceIdentifier: "disk5s1",
        progress: { log.record("progress: \($0)") }
    )

    let events = log.entriesSoFar
    let progressEntry = "progress: Writing the installer needs your password…"
    let sudoDashVEntry = "\(sudoPath) -v"

    guard let progressIndex = events.firstIndex(of: progressEntry) else {
        Issue.record("expected '\(progressEntry)' to appear in the shared log; got \(events)")
        return
    }
    guard let sudoDashVIndex = events.firstIndex(of: sudoDashVEntry) else {
        Issue.record("expected '\(sudoDashVEntry)' to appear in the shared log; got \(events)")
        return
    }

    // The ordering claim itself, by INDEX in one shared timeline — not by
    // which message happened to be recorded first among progress messages.
    #expect(progressIndex < sudoDashVIndex)
}

// MARK: - C4: success is observed, not just asserted from an exit code

/// `write` re-resolves by `expectedDeviceIdentifier`, not by `uuid` — the
/// erase gives the destination a new filesystem, which typically assigns it a
/// new `VolumeUUID`, so the pre-erase UUID is not a safe thing to resolve by
/// afterward. This pins that the device-identifier lookup is what actually
/// happens, and that its result — not an assumption from `exitCode == 0` — is
/// what `write` returns.
@Test("returns the volume actually observed after a successful write, re-resolved by device identifier")
func returnsObservedVolumeAfterSuccessfulWrite() throws {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(standardOutput: "ok",
                for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction")
    stubPostWriteResolution(on: runner, deviceIdentifier: "disk5s1", volumeName: "Install macOS Tahoe")

    let observed = try InstallMediaWriter(runner: runner).write(
        installerApp: app, toVolumeWithUUID: targetUUID,
        expectedDeviceIdentifier: "disk5s1", progress: { _ in }
    )

    #expect(observed?.volumeName == "Install macOS Tahoe")
    #expect(observed?.deviceIdentifier == "disk5s1")
}

/// The exact scenario C4 exists for: `createinstallmedia` can exit zero while
/// naming the result something other than what the catalog's release name
/// would predict (e.g. Apple changes its own naming convention, or a
/// pre-existing differently-named volume at that mount point was reused). The
/// VALUE returned must be the real, differing name — not the expected one —
/// so the caller can say so plainly instead of claiming success under a name
/// that isn't real.
@Test("returns the volume's real name even when it differs from what the release name would predict")
func returnsRealNameEvenWhenItDiffersFromExpectation() throws {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(standardOutput: "ok",
                for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction")
    // Apple's real output, not "Install macOS Tahoe" — the name a caller
    // might otherwise have assumed from the release alone.
    stubPostWriteResolution(on: runner, deviceIdentifier: "disk5s1", volumeName: "Install macOS Tahoe Beta")

    let observed = try InstallMediaWriter(runner: runner).write(
        installerApp: app, toVolumeWithUUID: targetUUID,
        expectedDeviceIdentifier: "disk5s1", progress: { _ in }
    )

    #expect(observed?.volumeName == "Install macOS Tahoe Beta")
}

/// `createinstallmedia` exiting zero is not the same fact as this tool having
/// observed the result — if the post-write lookup itself fails (the fake's
/// unstubbed response here, a non-zero `diskutil info` exit), `write` must
/// return `nil` rather than throw: the write itself genuinely succeeded, so
/// turning an unconfirmable name into a thrown error would misreport a
/// working installer as a failed run.
@Test("returns nil, without throwing, when the volume cannot be re-resolved after a successful write")
func returnsNilWhenPostWriteResolutionFails() throws {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.stub(standardOutput: "ok",
                for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction")
    // Deliberately no stub for "diskutil info -plist disk5s1": the fake's
    // unstubbed response is a non-zero exit, standing in for a drive that
    // disappeared or failed to remount in the instant right after the erase.

    let observed = try InstallMediaWriter(runner: runner).write(
        installerApp: app, toVolumeWithUUID: targetUUID,
        expectedDeviceIdentifier: "disk5s1", progress: { _ in }
    )

    #expect(observed == nil)
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

/// The counterpart to `reportsWriteFailure`: there, createinstallmedia
/// launches and exits non-zero. Here, it never launches at all — the runner
/// itself throws, the way a missing `sudo` or `createinstallmedia` binary
/// would. This must surface as `writeToolDidNotLaunch`, not
/// `writeFailedDriveStateUnknown`, and its explanation must say the drive was
/// not touched, since nothing ever ran.
@Test("reports that the installer tool did not launch, and the drive was not touched, when the runner throws")
func reportsWriteToolDidNotLaunch() {
    let runner = FakeCommandRunner()
    stubSuccessfulAuthentication(on: runner)
    runner.stub(standardOutput: infoPlist(id: "disk5s1", mount: "/Volumes/SanDisk Ultra"),
                for: "\(diskutilPath) info -plist \(targetUUID)")
    runner.throwError(
        CommandError.launchFailed(executable: sudoPath, reason: "no such file"),
        for: "\(sudoPath) \(createInstallMedia) --volume /Volumes/SanDisk Ultra --nointeraction"
    )

    do {
        try InstallMediaWriter(runner: runner).write(
            installerApp: app, toVolumeWithUUID: targetUUID,
            expectedDeviceIdentifier: "disk5s1", progress: { _ in }
        )
        Issue.record("expected write(installerApp:) to throw")
    } catch let error as MediaWriteError {
        guard case .writeToolDidNotLaunch = error else {
            Issue.record("expected .writeToolDidNotLaunch, got \(error)")
            return
        }
        let rendered = error.explanation.rendered().lowercased()
        #expect(
            rendered.contains("not")
                && (rendered.contains("erased") || rendered.contains("written") || rendered.contains("touched")),
            "explanation must state the drive was not touched: \(rendered)"
        )
    } catch {
        Issue.record("expected a MediaWriteError, but \(error) leaked out instead")
    }
}
