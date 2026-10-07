# Media Creation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a chosen macOS release into a bootable USB installer — download it, assemble it, and write it to a volume the user explicitly confirms, while making it impossible to select an internal or boot volume.

**Architecture:** Plan 1's `ReleaseCatalog` answers *what can I get*. This plan adds *get it* and *write it*. Disk facts come from `diskutil -plist` through the existing `CommandRunner` seam rather than the DiskArbitration C API, so the entire safety layer is testable against recorded fixtures with no disk attached. `VolumeGuard` is a pure function over parsed volume records: given a list of volumes and the boot container, it returns which are selectable and why the rest are not.

**Tech Stack:** Swift 6.4, SwiftPM, Swift Testing, `swift-argument-parser` 1.8.2. Foundation only otherwise. External processes: `diskutil`, `installer`, `createinstallmedia`, all via `CommandRunner`.

**Spec:** `docs/superpowers/specs/2026-09-26-macos-installer-design.md`
**Carry-forward from Plan 1:** `docs/superpowers/plans/carry-forward.md`

## Global Constraints

- Host floor macOS 13 Ventura. `platforms: [.macOS(.v13)]` — never change it.
- Only external dependency is `swift-argument-parser`.
- Run tests with `./scripts/test.sh`, never bare `swift test`.
- No `nonisolated(unsafe)` and no `@unchecked Sendable` in `Sources/`.
- No `print()` inside `MacOSInstallerKit`. The library returns values; the executable prints.
- Every subprocess goes through `CommandRunner`. `Foundation.Process` appears only in `RealCommandRunner`.
- Tests never touch the live network, never touch a real disk, and never invoke a real subprocess.
- Coverage ≥ 80% on `MacOSInstallerKit`, gated by `scripts/ci.sh`.
- **Assert ordering on the FULL array, never on `.first`.**
- **Every declared error case gets a test asserting that specific case**, never `#expect(throws: (any Error).self)`.
- **Every safety guard gets a mutation check**: delete or invert the guard, prove its test fails, restore.
- Conventional commits.

## Ground Truth

Captured from the development Mac (macOS 27.0, arm64) on 2026-09-26. Fixtures in this plan are trimmed copies of this real output.

**The boot-volume snapshot trap — the single most important fact in this plan.**

```
diskutil info -plist /            → DeviceIdentifier disk3s1s1   (a SEALED SNAPSHOT)
                                     VolumeUUID DE969922-CD33-4FA5-8020-DD5AE91CAF5C
                                     APFSContainerReference disk3
diskutil info -plist /dev/disk3s1 → DeviceIdentifier disk3s1     ("Macintosh HD", the real boot volume)
                                     VolumeUUID 9E97EE00-B7B4-4C33-9220-09F0CAFC59DE
                                     APFSContainerReference disk3
```

The UUIDs **differ**. A guard that refuses volumes matching `/`'s `VolumeUUID` would happily offer `Macintosh HD` as a target. `APFSContainerReference` is identical for both and is the reliable key.

**Other verified facts:**

- An external USB volume reports `Internal: false`, `Ejectable: true`, `BusProtocol: "USB"`. The internal reports `Internal: true`, `BusProtocol: "Apple Fabric"`.
- A whole disk (`disk4`) has an empty `VolumeName`, no `VolumeUUID`, and an empty `MountPoint`. Only mounted volumes are viable targets — `createinstallmedia` takes a mount path.
- `FreeSpace` reads `0` even on a mounted volume with free space. Capacity decisions must use `Size` / `TotalSize`. This is correct anyway: `createinstallmedia` erases the volume, so its free space is irrelevant — its total capacity is what matters.
- **Mount points contain spaces.** The external volume on this machine mounts at `/Volumes/Untitled 1`. Arguments must be passed as separate `argv` elements, never assembled into a shell string.
- `diskutil list -plist` has top-level keys `AllDisks`, `AllDisksAndPartitions`, `VolumesFromDisks`, `WholeDisks`.
- This machine has a real external target for manual verification: `disk4`, 500 GB USB, currently holding an APFS volume named `Untitled`. **It contains the user's website repositories.** It must never be erased during development. It is, however, an excellent guard test case: the tool should offer it, flagged, requiring a typed name.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/MacOSInstallerKit/Disks/Volume.swift` | Parsed record of one volume |
| `Sources/MacOSInstallerKit/Disks/DiskutilClient.swift` | `diskutil -plist` output → `Volume` / identifier list |
| `Sources/MacOSInstallerKit/Disks/DiskEnumerator.swift` | Lists mounted volumes via `CommandRunner` |
| `Sources/MacOSInstallerKit/Disks/BootVolumeResolver.swift` | Determines the boot APFS container |
| `Sources/MacOSInstallerKit/Disks/VolumeGuard.swift` | Pure selectability decision + refusal reasons |
| `Sources/MacOSInstallerKit/System/PrivilegeCheck.swift` | Refuses to run as root |
| `Sources/MacOSInstallerKit/Catalog/CatalogCache.swift` | 24-hour on-disk cache |
| `Sources/MacOSInstallerKit/Download/Downloader.swift` | Resumable download with progress |
| `Sources/MacOSInstallerKit/Download/ChecksumVerifier.swift` | SHA-256 verification |
| `Sources/MacOSInstallerKit/Assembly/AssemblyStrategy.swift` | Protocol: payload → installer app |
| `Sources/MacOSInstallerKit/Assembly/InstallAssistantAssembler.swift` | `installer -pkg … -target /` |
| `Sources/MacOSInstallerKit/Media/InstallMediaWriter.swift` | `createinstallmedia`, with re-resolution |
| `Sources/macos-installer/CreateCommand.swift` | `create` subcommand |
| `Sources/macos-installer/ConfirmationPrompt.swift` | Typed-name confirmation |
| `docs/manual-verification.md` | Tier 3 boot-test checklist |

---

### Task 1: Harden the test double's default

Carried forward from Plan 1 as its highest-priority item. `FakeCommandRunner` currently returns success with empty output for a command nobody stubbed. This plan introduces commands that erase disks. A test that forgets to stub one must fail loudly, not silently observe a no-op.

**Files:**
- Modify: `Tests/MacOSInstallerKitTests/Support/FakeCommandRunner.swift`
- Modify: any test that relied on the lenient default
- Test: `Tests/MacOSInstallerKitTests/FakeCommandRunnerTests.swift`

**Interfaces:**
- Consumes: existing `CommandRunner`, `CommandResult`.
- Produces: `FakeCommandRunner` whose unstubbed default is a non-zero `CommandResult`; unchanged `stub(_:for:)`, `stub(standardOutput:for:)`, `invocations`, `didInvoke(containing:)`.

- [ ] **Step 1: Write the failing test**

```swift
@Test("an unstubbed command returns a failing result so a forgotten stub cannot pass silently")
func unstubbedCommandFails() throws {
    let runner = FakeCommandRunner()

    let result = try runner.run("/usr/sbin/diskutil", ["info", "-plist", "/dev/disk9"])

    #expect(result.exitCode != 0)
    #expect(result.standardError.contains("unstubbed"))
    #expect(result.standardError.contains("/usr/sbin/diskutil info -plist /dev/disk9"))
}

@Test("a stubbed command still returns its stub unchanged")
func stubbedCommandUnaffected() throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: "hello", for: "/bin/echo hello")

    let result = try runner.run("/bin/echo", ["hello"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "hello")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter FakeCommandRunnerTests`
Expected: FAIL — the unstubbed call currently returns exit code 0.

- [ ] **Step 3: Change the default**

In `FakeCommandRunner.run`, replace the fallback with:

```swift
let key = ([executable] + arguments).joined(separator: " ")
return stubs[key] ?? CommandResult(
    exitCode: 127,
    standardOutput: "",
    standardError: "FakeCommandRunner: unstubbed command '\(key)'. "
        + "Stub it explicitly — a silent success here would let a test "
        + "believe a destructive command succeeded when it never ran."
)
```

- [ ] **Step 4: Run the full suite and repair fallout**

Run: `./scripts/test.sh`
Some existing tests may have relied on the lenient default. For each failure, add the missing explicit stub — do NOT weaken the new default. Report in your fix report which tests needed stubs, because each one was previously asserting against a command that never ran.

- [ ] **Step 5: Commit**

```bash
git add Tests/MacOSInstallerKitTests
git commit -m "test: fail loudly on unstubbed commands in FakeCommandRunner"
```

---

### Task 2: Volume model and diskutil parsing

**Files:**
- Create: `Sources/MacOSInstallerKit/Disks/Volume.swift`
- Create: `Sources/MacOSInstallerKit/Disks/DiskutilClient.swift`
- Create: `Tests/MacOSInstallerKitTests/Fixtures/diskutil-info-boot.plist`
- Create: `Tests/MacOSInstallerKitTests/Fixtures/diskutil-info-macintosh-hd.plist`
- Create: `Tests/MacOSInstallerKitTests/Fixtures/diskutil-info-external.plist`
- Create: `Tests/MacOSInstallerKitTests/Fixtures/diskutil-info-wholedisk.plist`
- Test: `Tests/MacOSInstallerKitTests/DiskutilClientTests.swift`

**Interfaces:**
- Consumes: nothing from this plan.
- Produces: `Volume` with `deviceIdentifier: String`, `volumeName: String`, `volumeUUID: String?`, `mountPoint: String?`, `isInternal: Bool`, `isEjectable: Bool`, `busProtocol: String`, `apfsContainerReference: String?`, `parentWholeDisk: String`, `sizeBytes: Int64`, `isWholeDisk: Bool`, plus computed `isMounted: Bool`. `DiskutilClient.parseInfo(_ Data) throws -> Volume` and `DiskutilClient.parseVolumeIdentifiers(_ Data) throws -> [String]`. `DiskutilParseError` with cases `.notAPropertyList`, `.missingDeviceIdentifier`.

- [ ] **Step 1: Create the fixtures**

These are trimmed copies of real `diskutil info -plist` output captured 2026-09-26. Keep the values exactly — later tasks assert on them.

`diskutil-info-boot.plist` (what `/` reports — note it is a snapshot):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DeviceIdentifier</key><string>disk3s1s1</string>
  <key>VolumeName</key><string>Macintosh HD</string>
  <key>VolumeUUID</key><string>DE969922-CD33-4FA5-8020-DD5AE91CAF5C</string>
  <key>MountPoint</key><string>/</string>
  <key>Internal</key><true/>
  <key>Ejectable</key><false/>
  <key>BusProtocol</key><string>Apple Fabric</string>
  <key>APFSContainerReference</key><string>disk3</string>
  <key>ParentWholeDisk</key><string>disk3</string>
  <key>WholeDisk</key><false/>
  <key>Size</key><integer>245107195904</integer>
</dict>
</plist>
```

`diskutil-info-macintosh-hd.plist` (the real boot volume — DIFFERENT UUID, SAME container):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DeviceIdentifier</key><string>disk3s1</string>
  <key>VolumeName</key><string>Macintosh HD</string>
  <key>VolumeUUID</key><string>9E97EE00-B7B4-4C33-9220-09F0CAFC59DE</string>
  <key>MountPoint</key><string></string>
  <key>Internal</key><true/>
  <key>Ejectable</key><false/>
  <key>BusProtocol</key><string>Apple Fabric</string>
  <key>APFSContainerReference</key><string>disk3</string>
  <key>ParentWholeDisk</key><string>disk3</string>
  <key>WholeDisk</key><false/>
  <key>Size</key><integer>245107195904</integer>
</dict>
</plist>
```

`diskutil-info-external.plist` (real external USB volume; note the SPACE in the mount point):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DeviceIdentifier</key><string>disk5s1</string>
  <key>VolumeName</key><string>Untitled</string>
  <key>VolumeUUID</key><string>9662C8FB-5D1F-4744-81E0-618FBC801198</string>
  <key>MountPoint</key><string>/Volumes/Untitled 1</string>
  <key>Internal</key><false/>
  <key>Ejectable</key><true/>
  <key>BusProtocol</key><string>USB</string>
  <key>APFSContainerReference</key><string>disk5</string>
  <key>ParentWholeDisk</key><string>disk5</string>
  <key>WholeDisk</key><false/>
  <key>Size</key><integer>499898081280</integer>
</dict>
</plist>
```

`diskutil-info-wholedisk.plist` (a whole disk — no UUID, no mount point):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DeviceIdentifier</key><string>disk4</string>
  <key>VolumeName</key><string></string>
  <key>MountPoint</key><string></string>
  <key>Internal</key><false/>
  <key>Ejectable</key><true/>
  <key>BusProtocol</key><string>USB</string>
  <key>ParentWholeDisk</key><string>disk4</string>
  <key>WholeDisk</key><true/>
  <key>Size</key><integer>500107837440</integer>
</dict>
</plist>
```

Validate every fixture before writing parser code:

```bash
for f in Tests/MacOSInstallerKitTests/Fixtures/diskutil-info-*.plist; do plutil -lint "$f"; done
```

Expected: `OK` for each.

- [ ] **Step 2: Write the failing test**

```swift
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
func throwsOnGarbage() {
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
```

- [ ] **Step 3: Run to verify it fails**

Run: `./scripts/test.sh --filter DiskutilClientTests`
Expected: FAIL — `cannot find 'DiskutilClient' in scope`

- [ ] **Step 4: Write the model**

`Sources/MacOSInstallerKit/Disks/Volume.swift`:

```swift
import Foundation

/// One volume as reported by `diskutil info -plist`.
///
/// `volumeUUID` is deliberately optional: a whole disk has none. `mountPoint`
/// is nil rather than "" when unmounted, so callers cannot accidentally treat
/// an empty string as a path.
public struct Volume: Equatable, Sendable {
    public let deviceIdentifier: String
    public let volumeName: String
    public let volumeUUID: String?
    public let mountPoint: String?
    public let isInternal: Bool
    public let isEjectable: Bool
    public let busProtocol: String
    public let apfsContainerReference: String?
    public let parentWholeDisk: String
    public let sizeBytes: Int64
    public let isWholeDisk: Bool

    public init(
        deviceIdentifier: String,
        volumeName: String,
        volumeUUID: String?,
        mountPoint: String?,
        isInternal: Bool,
        isEjectable: Bool,
        busProtocol: String,
        apfsContainerReference: String?,
        parentWholeDisk: String,
        sizeBytes: Int64,
        isWholeDisk: Bool
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.mountPoint = mountPoint
        self.isInternal = isInternal
        self.isEjectable = isEjectable
        self.busProtocol = busProtocol
        self.apfsContainerReference = apfsContainerReference
        self.parentWholeDisk = parentWholeDisk
        self.sizeBytes = sizeBytes
        self.isWholeDisk = isWholeDisk
    }

    public var isMounted: Bool { mountPoint != nil }

    /// A human label for pickers and confirmations.
    public var displayName: String {
        volumeName.isEmpty ? deviceIdentifier : volumeName
    }
}
```

- [ ] **Step 5: Write the parser**

`Sources/MacOSInstallerKit/Disks/DiskutilClient.swift`:

```swift
import Foundation

public enum DiskutilParseError: Error, Equatable {
    case notAPropertyList
    case missingDeviceIdentifier
}

/// Parses `diskutil -plist` output. Using diskutil rather than the
/// DiskArbitration C API keeps every disk fact behind `CommandRunner`, so the
/// safety layer is testable against recorded fixtures with no disk attached.
public enum DiskutilClient {
    public static func parseInfo(_ data: Data) throws -> Volume {
        guard
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let d = object as? [String: Any]
        else { throw DiskutilParseError.notAPropertyList }

        guard let deviceIdentifier = d["DeviceIdentifier"] as? String else {
            throw DiskutilParseError.missingDeviceIdentifier
        }

        return Volume(
            deviceIdentifier: deviceIdentifier,
            volumeName: d["VolumeName"] as? String ?? "",
            volumeUUID: nonEmpty(d["VolumeUUID"] as? String),
            mountPoint: nonEmpty(d["MountPoint"] as? String),
            isInternal: d["Internal"] as? Bool ?? false,
            isEjectable: d["Ejectable"] as? Bool ?? false,
            busProtocol: d["BusProtocol"] as? String ?? "",
            apfsContainerReference: nonEmpty(d["APFSContainerReference"] as? String),
            parentWholeDisk: d["ParentWholeDisk"] as? String ?? deviceIdentifier,
            sizeBytes: (d["Size"] as? NSNumber)?.int64Value ?? 0,
            isWholeDisk: d["WholeDisk"] as? Bool ?? false
        )
    }

    /// Volume identifiers from `diskutil list -plist`, drawn from
    /// `VolumesFromDisks` — the mounted volumes, excluding whole disks.
    public static func parseVolumeIdentifiers(_ data: Data) throws -> [String] {
        guard
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let d = object as? [String: Any]
        else { throw DiskutilParseError.notAPropertyList }

        return d["VolumesFromDisks"] as? [String] ?? []
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `./scripts/test.sh --filter DiskutilClientTests`
Expected: PASS, 6 tests

- [ ] **Step 7: Commit**

```bash
git add Sources/MacOSInstallerKit/Disks Tests/MacOSInstallerKitTests
git commit -m "feat: parse diskutil volume information"
```

---

### Task 3: BootVolumeResolver

Isolated in its own file and task precisely because it is the subtle part. Its whole job is to answer "which APFS container is the system booted from", correctly, given that `/` is a snapshot whose UUID matches nothing else.

**Files:**
- Create: `Sources/MacOSInstallerKit/Disks/BootVolumeResolver.swift`
- Test: `Tests/MacOSInstallerKitTests/BootVolumeResolverTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`, `DiskutilClient`, `Volume`.
- Produces: `BootVolumeResolver(runner:)` with `func resolve() throws -> BootVolume`; `BootVolume` with `containerReference: String?`, `parentWholeDisk: String`, `deviceIdentifier: String`; `BootVolumeResolverError.cannotIdentifyBootVolume(String)`.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter BootVolumeResolverTests`
Expected: FAIL — `cannot find 'BootVolumeResolver' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public struct BootVolume: Equatable, Sendable {
    public let deviceIdentifier: String
    public let containerReference: String?
    public let parentWholeDisk: String
}

public enum BootVolumeResolverError: Error, Equatable {
    case cannotIdentifyBootVolume(String)
}

/// Determines which APFS container the running system booted from.
///
/// This exists as its own type because the obvious implementation is wrong.
/// On a modern macOS, `/` is a sealed SNAPSHOT (e.g. `disk3s1s1`) whose
/// `VolumeUUID` differs from the underlying boot volume `Macintosh HD`
/// (`disk3s1`). Comparing a candidate's UUID against the UUID reported for
/// `/` therefore fails to recognise the real boot volume, and a guard built
/// that way would offer the startup disk as a target for erasure.
///
/// Both the snapshot and the boot volume report the same
/// `APFSContainerReference`, so the container is the reliable key.
public struct BootVolumeResolver {
    public static let diskutilPath = "/usr/sbin/diskutil"

    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    public func resolve() throws -> BootVolume {
        let result = try runner.run(Self.diskutilPath, ["info", "-plist", "/"])

        guard result.exitCode == 0 else {
            throw BootVolumeResolverError.cannotIdentifyBootVolume(
                "diskutil exited \(result.exitCode): "
                    + result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let volume: Volume
        do {
            volume = try DiskutilClient.parseInfo(Data(result.standardOutput.utf8))
        } catch {
            throw BootVolumeResolverError.cannotIdentifyBootVolume("unparsable diskutil output: \(error)")
        }

        return BootVolume(
            deviceIdentifier: volume.deviceIdentifier,
            containerReference: volume.apfsContainerReference,
            parentWholeDisk: volume.parentWholeDisk
        )
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter BootVolumeResolverTests`
Expected: PASS, 3 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Disks/BootVolumeResolver.swift Tests/MacOSInstallerKitTests/BootVolumeResolverTests.swift
git commit -m "feat: resolve the boot APFS container, accounting for the sealed snapshot at /"
```

---

### Task 4: VolumeGuard

The safety core. A pure function: given candidate volumes, the boot volume, a required size, and paths that must not be destroyed, decide what is selectable and give a reason for everything that is not. No I/O, so every rule is directly testable.

**Files:**
- Create: `Sources/MacOSInstallerKit/Disks/VolumeGuard.swift`
- Test: `Tests/MacOSInstallerKitTests/VolumeGuardTests.swift`

**Interfaces:**
- Consumes: `Volume` (Task 2), `BootVolume` (Task 3).
- Produces: `VolumeGuard.evaluate(volumes:bootVolume:requiredBytes:protectedPaths:) -> [VolumeDecision]`; `VolumeDecision` with `volume: Volume`, `verdict: Verdict`; `Verdict` being `.selectable`, `.selectableWithWarning(String)`, or `.refused(RefusalReason)`; `RefusalReason` an enum with `.internalDisk`, `.bootContainer`, `.notMounted`, `.wholeDisk`, `.holdsProtectedPath(String)`, `.tooSmall(capacityBytes: Int64, requiredBytes: Int64)`, each with a `userMessage: String`.
- Also produces `VolumeGuard.headroomBytes: Int64 = 2_000_000_000`.

- [ ] **Step 1: Write the failing test**

```swift
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

    // Internal is checked first; assert it is refused for SOME reason, then
    // prove the container rule independently below.
    #expect(verdict(for: macintoshHD) != .selectable)
}

@Test("a volume in the boot container is refused even when it reports as external")
func bootContainerRefusedIndependentOfInternalFlag() {
    // Contrived but precise: isolates the container rule from the internal rule.
    let sneaky = volume(isInternal: false, container: "disk3", parent: "disk3")

    #expect(verdict(for: sneaky) == .refused(.bootContainer))
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter VolumeGuardTests`
Expected: FAIL — `cannot find 'VolumeGuard' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Decides which volumes may be erased. Pure — no I/O — so every rule is
/// directly testable and no rule can depend on machine state at review time.
///
/// Refusals are absolute. There is deliberately no override flag: the spec
/// requires that internal and boot volumes are never selectable, not that they
/// are selectable with a warning.
public enum VolumeGuard {
    /// Spare capacity required beyond the installer itself.
    public static let headroomBytes: Int64 = 2_000_000_000

    public enum RefusalReason: Equatable, Sendable {
        case internalDisk
        case bootContainer
        case notMounted
        case wholeDisk
        case holdsProtectedPath(String)
        case tooSmall(capacityBytes: Int64, requiredBytes: Int64)

        public var userMessage: String {
            switch self {
            case .internalDisk:
                return "This is an internal disk. Only external drives can be used."
            case .bootContainer:
                return "This volume is part of your startup disk."
            case .notMounted:
                return "This volume isn't mounted, so it can't be written to."
            case .wholeDisk:
                return "This is a whole disk rather than a volume. Pick one of its volumes."
            case .holdsProtectedPath(let path):
                return "This volume holds files this operation needs (\(path))."
            case .tooSmall(let capacity, let required):
                return "This drive holds \(Self.gigabytes(capacity)), "
                    + "but \(Self.gigabytes(required)) is needed."
            }
        }

        private static func gigabytes(_ bytes: Int64) -> String {
            String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
    }

    public enum Verdict: Equatable, Sendable {
        case selectable
        case selectableWithWarning(String)
        case refused(RefusalReason)
    }

    public struct VolumeDecision: Equatable, Sendable {
        public let volume: Volume
        public let verdict: Verdict
    }

    /// `requiredBytes` is the installer's own size; headroom is added here so
    /// callers cannot forget it.
    public static func evaluate(
        volumes: [Volume],
        bootVolume: BootVolume,
        requiredBytes: Int64,
        protectedPaths: [String]
    ) -> [VolumeDecision] {
        let needed = requiredBytes + headroomBytes

        return volumes.map { volume in
            VolumeDecision(volume: volume, verdict: verdict(
                for: volume, bootVolume: bootVolume, needed: needed, protectedPaths: protectedPaths
            ))
        }
    }

    private static func verdict(
        for volume: Volume,
        bootVolume: BootVolume,
        needed: Int64,
        protectedPaths: [String]
    ) -> Verdict {
        if volume.isInternal { return .refused(.internalDisk) }

        // The container check, not a UUID check. `/` is a sealed snapshot whose
        // VolumeUUID differs from the boot volume's, so UUID comparison would
        // fail to recognise the startup disk. See BootVolumeResolver.
        if let container = volume.apfsContainerReference,
           let bootContainer = bootVolume.containerReference,
           container == bootContainer {
            return .refused(.bootContainer)
        }
        if volume.parentWholeDisk == bootVolume.parentWholeDisk {
            return .refused(.bootContainer)
        }

        if volume.isWholeDisk { return .refused(.wholeDisk) }
        guard let mountPoint = volume.mountPoint else { return .refused(.notMounted) }

        if let offending = protectedPaths.first(where: { isPath($0, under: mountPoint) }) {
            return .refused(.holdsProtectedPath(offending))
        }

        if volume.sizeBytes < needed {
            return .refused(.tooSmall(capacityBytes: volume.sizeBytes, requiredBytes: needed))
        }

        if volume.volumeName.localizedCaseInsensitiveContains("time machine") {
            return .selectableWithWarning("This looks like a Time Machine backup.")
        }

        return .selectable
    }

    /// Path containment by path component, so `/Volumes/Work` does not match
    /// `/Volumes/Workshop`.
    private static func isPath(_ path: String, under mountPoint: String) -> Bool {
        let normalizedMount = mountPoint.hasSuffix("/") ? String(mountPoint.dropLast()) : mountPoint
        return path == normalizedMount || path.hasPrefix(normalizedMount + "/")
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter VolumeGuardTests`
Expected: PASS, 11 tests

- [ ] **Step 5: Mutation-check every refusal rule**

This is the safety core; each rule must be provably load-bearing. For each of the six rules, comment it out, run `./scripts/test.sh`, confirm at least one test fails, restore, confirm green. Record all six results in your report.

The container rule matters most: with `if let container = …` removed, `bootContainerRefusedIndependentOfInternalFlag` must fail. If it does not, the test is not pinning the rule and you must strengthen it before continuing.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacOSInstallerKit/Disks/VolumeGuard.swift Tests/MacOSInstallerKitTests/VolumeGuardTests.swift
git commit -m "feat: add VolumeGuard with absolute refusal of internal and boot volumes"
```

---

### Task 5: DiskEnumerator

**Files:**
- Create: `Sources/MacOSInstallerKit/Disks/DiskEnumerator.swift`
- Test: `Tests/MacOSInstallerKitTests/DiskEnumeratorTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`, `DiskutilClient`, `Volume`.
- Produces: `DiskEnumerator(runner:)` with `func mountedVolumes() throws -> [Volume]`; `DiskEnumeratorError.listFailed(String)`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private let listPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>VolumesFromDisks</key>
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter DiskEnumeratorTests`
Expected: FAIL — `cannot find 'DiskEnumerator' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public enum DiskEnumeratorError: Error, Equatable {
    case listFailed(String)
}

/// Lists volumes via `diskutil`. A volume whose details cannot be read is
/// skipped rather than failing the listing — one unreadable disk must not stop
/// the user seeing the others.
public struct DiskEnumerator {
    public static let diskutilPath = "/usr/sbin/diskutil"

    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    public func mountedVolumes() throws -> [Volume] {
        let listed = try runner.run(Self.diskutilPath, ["list", "-plist"])

        guard listed.exitCode == 0 else {
            throw DiskEnumeratorError.listFailed(
                "diskutil exited \(listed.exitCode): "
                    + listed.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let identifiers: [String]
        do {
            identifiers = try DiskutilClient.parseVolumeIdentifiers(Data(listed.standardOutput.utf8))
        } catch {
            throw DiskEnumeratorError.listFailed("unparsable diskutil output: \(error)")
        }

        return identifiers.compactMap { identifier in
            guard
                let info = try? runner.run(Self.diskutilPath, ["info", "-plist", identifier]),
                info.exitCode == 0,
                let volume = try? DiskutilClient.parseInfo(Data(info.standardOutput.utf8))
            else { return nil }
            return volume
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter DiskEnumeratorTests`
Expected: PASS, 3 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Disks/DiskEnumerator.swift Tests/MacOSInstallerKitTests/DiskEnumeratorTests.swift
git commit -m "feat: enumerate mounted volumes via diskutil"
```

---

### Task 6: PrivilegeCheck and the catalog cache

Two small pieces that belong together: the moment the tool starts writing files to disk is the moment running as root starts mattering, because a root-owned cache is a support problem the user cannot fix without `sudo rm`.

**Files:**
- Create: `Sources/MacOSInstallerKit/System/PrivilegeCheck.swift`
- Create: `Sources/MacOSInstallerKit/Catalog/CatalogCache.swift`
- Test: `Tests/MacOSInstallerKitTests/PrivilegeCheckTests.swift`
- Test: `Tests/MacOSInstallerKitTests/CatalogCacheTests.swift`

**Interfaces:**
- Consumes: nothing from this plan.
- Produces: `PrivilegeCheck.assertNotRoot(effectiveUserID:) throws`, defaulting to `getuid()`; `PrivilegeError.runningAsRoot`. `CatalogCache(directory:clock:)` with `func load(key: String) -> Data?`, `func store(_ data: Data, key: String) throws`, `static let ttl: TimeInterval = 86_400`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

@Test("refuses to run as root")
func refusesRoot() {
    #expect(throws: PrivilegeError.runningAsRoot) {
        try PrivilegeCheck.assertNotRoot(effectiveUserID: 0)
    }
}

@Test("permits a normal user")
func permitsNormalUser() throws {
    try PrivilegeCheck.assertNotRoot(effectiveUserID: 501)
}
```

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private func tempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("returns data stored within the TTL")
func returnsFreshData() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let cache = CatalogCache(directory: dir, clock: { now })

    try cache.store(Data("catalog".utf8), key: "sucatalog")
    now = now.addingTimeInterval(3_600)   // one hour later

    #expect(cache.load(key: "sucatalog") == Data("catalog".utf8))
}

@Test("ignores data older than the 24-hour TTL")
func ignoresStaleData() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let cache = CatalogCache(directory: dir, clock: { now })

    try cache.store(Data("catalog".utf8), key: "sucatalog")
    now = now.addingTimeInterval(CatalogCache.ttl + 1)

    #expect(cache.load(key: "sucatalog") == nil)
}

@Test("data exactly at the TTL boundary is still considered fresh")
func boundaryIsFresh() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let cache = CatalogCache(directory: dir, clock: { now })

    try cache.store(Data("catalog".utf8), key: "sucatalog")
    now = now.addingTimeInterval(CatalogCache.ttl)

    #expect(cache.load(key: "sucatalog") == Data("catalog".utf8))
}

@Test("returns nil for a key that was never stored")
func missingKeyReturnsNil() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(CatalogCache(directory: dir, clock: { Date() }).load(key: "absent") == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter "PrivilegeCheckTests|CatalogCacheTests"`
Expected: FAIL — types not in scope.

- [ ] **Step 3: Write PrivilegeCheck**

```swift
import Foundation

public enum PrivilegeError: Error, Equatable {
    case runningAsRoot
}

/// The tool runs unprivileged and escalates only for the two operations that
/// require root. Running the whole process as root would leave the download
/// cache and the assembled installer owned by root, which the user then cannot
/// delete without `sudo`.
public enum PrivilegeCheck {
    public static func assertNotRoot(effectiveUserID: uid_t = getuid()) throws {
        guard effectiveUserID != 0 else { throw PrivilegeError.runningAsRoot }
    }
}
```

- [ ] **Step 4: Write CatalogCache**

```swift
import Foundation

/// A small on-disk cache with a fixed TTL. The clock is injected so expiry is
/// testable without sleeping.
public struct CatalogCache {
    public static let ttl: TimeInterval = 86_400

    private let directory: URL
    private let clock: @Sendable () -> Date

    public init(directory: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.clock = clock
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("macos-installer", isDirectory: true)
    }

    public func load(key: String) -> Data? {
        let entry = directory.appendingPathComponent(key)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path),
            let modified = attributes[.modificationDate] as? Date,
            clock().timeIntervalSince(modified) <= Self.ttl,
            let data = try? Data(contentsOf: entry)
        else { return nil }
        return data
    }

    public func store(_ data: Data, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = directory.appendingPathComponent(key)
        try data.write(to: entry, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: clock()], ofItemAtPath: entry.path)
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `./scripts/test.sh --filter "PrivilegeCheckTests|CatalogCacheTests"`
Expected: PASS, 6 tests

- [ ] **Step 6: Commit**

```bash
git add Sources/MacOSInstallerKit/System/PrivilegeCheck.swift Sources/MacOSInstallerKit/Catalog/CatalogCache.swift Tests/MacOSInstallerKitTests
git commit -m "feat: refuse to run as root and cache the catalog for 24 hours"
```

---

### Task 7: Carry Apple's published digest through the pipeline

Verified 2026-09-26: every installer package in the live catalog carries a `Digest` key — a 40-character hex string, i.e. **SHA-1** — alongside `Size`, `MetadataURL`, `IntegrityDataURL` and `IntegrityDataSize`.

**Be precise about what this buys.** SHA-1 is collision-broken, so this digest is *not* an authenticity control. It is a transport-integrity check against a value Apple publishes: it catches a truncated or corrupted download, which is the realistic failure when pulling 18 GB. Authenticity comes from the package being Apple-signed, which `installer` verifies in Task 10. Do not describe this as a security check anywhere in code comments or user-facing text.

**Files:**
- Modify: `Sources/MacOSInstallerKit/Catalog/CatalogProduct.swift`
- Modify: `Sources/MacOSInstallerKit/Catalog/SucatalogClient.swift`
- Modify: `Sources/MacOSInstallerKit/Models/InstallerRelease.swift`
- Modify: `Sources/MacOSInstallerKit/Sources/SucatalogSource.swift`
- Modify: `Tests/MacOSInstallerKitTests/Fixtures/mini-catalog.plist`
- Test: `Tests/MacOSInstallerKitTests/SucatalogClientTests.swift`, `SucatalogSourceTests.swift`

**Interfaces:**
- Consumes: Plan 1's `CatalogPackage`, `CatalogProduct`, `InstallerRelease`, `SucatalogSource`.
- Produces: `CatalogPackage.digest: String?`; `CatalogProduct.installAssistantDigest: String?`; `InstallerRelease.digest: String?` added as a trailing initializer parameter **defaulting to nil**, so no existing call site breaks.

- [ ] **Step 1: Add the digest to the fixture**

In `Tests/MacOSInstallerKitTests/Fixtures/mini-catalog.plist`, add a `Digest` key to the modern product's `InstallAssistant.pkg` package dict, using the real-format value below. Leave the legacy product's packages without one, so the optional path stays covered.

```xml
        <dict>
          <key>URL</key><string>https://swcdn.apple.com/x/InstallAssistant.pkg</string>
          <key>Size</key><integer>15296950272</integer>
          <key>Digest</key><string>01e1be1b5ea751633fdeb70c3824e56b76d2cf1a</string>
        </dict>
```

Validate: `plutil -lint Tests/MacOSInstallerKitTests/Fixtures/mini-catalog.plist` → `OK`

- [ ] **Step 2: Write the failing tests**

Add to `SucatalogClientTests.swift`:

```swift
@Test("captures Apple's published digest for the installer package")
func capturesDigest() throws {
    let products = try SucatalogClient.parse(catalogFixture())
    let modern = try #require(products.first { $0.identifier == "142-16660" })

    #expect(modern.installAssistantDigest == "01e1be1b5ea751633fdeb70c3824e56b76d2cf1a")
}

@Test("a package with no published digest yields nil rather than an empty string")
func absentDigestIsNil() throws {
    let products = try SucatalogClient.parse(catalogFixture())
    let legacy = try #require(products.first { $0.identifier == "061-26578" })

    #expect(legacy.packages.allSatisfy { $0.digest == nil })
}
```

Add to `SucatalogSourceTests.swift`, inside the existing test that builds releases:

```swift
#expect(sequoia.digest == "01e1be1b5ea751633fdeb70c3824e56b76d2cf1a")
```

- [ ] **Step 3: Run to verify they fail**

Run: `./scripts/test.sh --filter "SucatalogClientTests|SucatalogSourceTests"`
Expected: FAIL — no `digest` member.

- [ ] **Step 4: Thread the digest through**

In `CatalogProduct.swift`, add `public let digest: String?` to `CatalogPackage` (as a trailing initializer parameter), and add:

```swift
    /// Apple's published SHA-1 for the InstallAssistant package, when present.
    /// Transport integrity only — see DigestVerifier.
    public var installAssistantDigest: String? {
        packages.first { $0.url.lastPathComponent == Self.installAssistantFilename }?.digest
    }
```

In `SucatalogClient.makeProduct`, read it alongside URL and Size. Keep the existing fail-closed behaviour for `Size`; the digest is optional and must NOT gate the package:

```swift
return CatalogPackage(url: url, size: size, digest: package["Digest"] as? String)
```

In `InstallerRelease.swift`, add `public let digest: String?` and give the initializer a trailing `digest: String? = nil` parameter.

In `SucatalogSource.release(for:)`, pass `digest: product.installAssistantDigest` when constructing the release.

- [ ] **Step 5: Run the full suite**

Run: `./scripts/test.sh`
Expected: all green. The default `nil` means no Plan 1 call site needed changing; if any did, say so in your report.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "feat: carry Apple's published package digest through to releases"
```

---

### Task 8: Resumable downloader

An 18 GB download over a flaky connection must not start from zero. The transfer itself is behind a protocol so tests never touch the network and never write gigabytes.

**Files:**
- Create: `Sources/MacOSInstallerKit/Download/ResumableTransfer.swift`
- Create: `Sources/MacOSInstallerKit/Download/Downloader.swift`
- Create: `Tests/MacOSInstallerKitTests/Support/FakeTransfer.swift`
- Test: `Tests/MacOSInstallerKitTests/DownloaderTests.swift`

**Interfaces:**
- Consumes: nothing from this plan.
- Produces: `protocol ResumableTransfer: Sendable { func transfer(from: URL, to: URL, startingAt: Int64, progress: @Sendable (Int64) -> Void) async throws }`; `URLSessionResumableTransfer`; `Downloader(transfer:fileManager:)` with `func download(from: URL, to: URL, expectedBytes: Int64, progress: @Sendable (Int64, Int64) -> Void) async throws -> URL`; `DownloadError` with `.sizeMismatch(expected: Int64, actual: Int64)` and `.transferFailed(String)`.

- [ ] **Step 1: Write the fake**

`Tests/MacOSInstallerKitTests/Support/FakeTransfer.swift`:

```swift
import Foundation
@testable import MacOSInstallerKit

final class FakeTransfer: ResumableTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var payload: Data
    private var recordedOffsets: [Int64] = []
    private var error: (any Error)?

    init(payload: Data, error: (any Error)? = nil) {
        self.payload = payload
        self.error = error
    }

    var offsets: [Int64] { lock.withLock { recordedOffsets } }

    func transfer(
        from url: URL,
        to destination: URL,
        startingAt offset: Int64,
        progress: @Sendable (Int64) -> Void
    ) async throws {
        lock.withLock { recordedOffsets.append(offset) }
        if let error { throw error }

        let remainder = payload.dropFirst(Int(offset))
        if FileManager.default.fileExists(atPath: destination.path) {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: remainder)
        } else {
            try remainder.write(to: destination)
        }
        progress(Int64(remainder.count))
    }
}
```

- [ ] **Step 2: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let remote = URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!

@Test("downloads a whole file from offset zero when nothing is present")
func downloadsFromScratch() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    let transfer = FakeTransfer(payload: Data("0123456789".utf8))

    _ = try await Downloader(transfer: transfer)
        .download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    #expect(transfer.offsets == [0])
    #expect(try Data(contentsOf: destination) == Data("0123456789".utf8))
}

@Test("resumes from the size of an existing partial file instead of restarting")
func resumesFromPartial() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("0123".utf8).write(to: destination)
    let transfer = FakeTransfer(payload: Data("0123456789".utf8))

    _ = try await Downloader(transfer: transfer)
        .download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    #expect(transfer.offsets == [4])
    #expect(try Data(contentsOf: destination) == Data("0123456789".utf8))
}

@Test("skips the transfer entirely when the file is already complete")
func skipsWhenComplete() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("0123456789".utf8).write(to: destination)
    let transfer = FakeTransfer(payload: Data("0123456789".utf8))

    _ = try await Downloader(transfer: transfer)
        .download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    #expect(transfer.offsets.isEmpty)
}

@Test("throws sizeMismatch when the finished file is not the expected length")
func throwsOnSizeMismatch() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    let transfer = FakeTransfer(payload: Data("0123".utf8))

    await #expect(throws: DownloadError.sizeMismatch(expected: 10, actual: 4)) {
        _ = try await Downloader(transfer: transfer)
            .download(from: remote, to: destination, expectedBytes: 10) { _, _ in }
    }
}

@Test("reports cumulative progress against the expected total")
func reportsProgress() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("01234".utf8).write(to: destination)
    let transfer = FakeTransfer(payload: Data("0123456789".utf8))

    final class Box: @unchecked Sendable { var seen: [(Int64, Int64)] = [] }
    let box = Box()

    _ = try await Downloader(transfer: transfer)
        .download(from: remote, to: destination, expectedBytes: 10) { done, total in
            box.seen.append((done, total))
        }

    // Progress must account for the 5 bytes already on disk, not just the 5 transferred.
    #expect(box.seen.last?.0 == 10)
    #expect(box.seen.last?.1 == 10)
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `./scripts/test.sh --filter DownloaderTests`
Expected: FAIL — `cannot find 'Downloader' in scope`

- [ ] **Step 4: Write the transfer protocol and real implementation**

`Sources/MacOSInstallerKit/Download/ResumableTransfer.swift`:

```swift
import Foundation

/// Appends bytes to `destination`, starting at `startingAt` in the remote
/// resource. Behind a protocol so tests neither touch the network nor write
/// gigabytes.
public protocol ResumableTransfer: Sendable {
    func transfer(
        from url: URL,
        to destination: URL,
        startingAt offset: Int64,
        progress: @Sendable (Int64) -> Void
    ) async throws
}

public struct URLSessionResumableTransfer: ResumableTransfer {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func transfer(
        from url: URL,
        to destination: URL,
        startingAt offset: Int64,
        progress: @Sendable (Int64) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let (stream, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.transferFailed("HTTP \(http.statusCode)")
        }

        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0

        for try await byte in stream {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                progress(written)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            progress(written)
        }
    }
}
```

- [ ] **Step 5: Write the downloader**

`Sources/MacOSInstallerKit/Download/Downloader.swift`:

```swift
import Foundation

public enum DownloadError: Error, Equatable {
    case sizeMismatch(expected: Int64, actual: Int64)
    case transferFailed(String)
}

/// Resumes an interrupted download rather than restarting it. At 18 GB per
/// installer, restarting is not a realistic recovery.
public struct Downloader {
    private let transfer: any ResumableTransfer
    private let fileManager: FileManager

    public init(transfer: any ResumableTransfer, fileManager: FileManager = .default) {
        self.transfer = transfer
        self.fileManager = fileManager
    }

    @discardableResult
    public func download(
        from url: URL,
        to destination: URL,
        expectedBytes: Int64,
        progress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        let alreadyHave = existingSize(at: destination)

        if alreadyHave < expectedBytes {
            progress(alreadyHave, expectedBytes)
            try await transfer.transfer(from: url, to: destination, startingAt: alreadyHave) { written in
                progress(alreadyHave + written, expectedBytes)
            }
        }

        let finalSize = existingSize(at: destination)
        guard finalSize == expectedBytes else {
            throw DownloadError.sizeMismatch(expected: expectedBytes, actual: finalSize)
        }

        progress(finalSize, expectedBytes)
        return destination
    }

    private func existingSize(at url: URL) -> Int64 {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `./scripts/test.sh --filter DownloaderTests`
Expected: PASS, 5 tests

- [ ] **Step 7: Commit**

```bash
git add Sources/MacOSInstallerKit/Download Tests/MacOSInstallerKitTests
git commit -m "feat: add resumable downloader with progress reporting"
```

---

### Task 9: Digest verification

**Files:**
- Create: `Sources/MacOSInstallerKit/Download/DigestVerifier.swift`
- Test: `Tests/MacOSInstallerKitTests/DigestVerifierTests.swift`

**Interfaces:**
- Consumes: nothing from this plan.
- Produces: `DigestVerifier.sha1Hex(ofFileAt: URL) throws -> String`; `DigestVerifier.verify(fileAt: URL, matches: String) throws`; `DigestError.mismatch(expected: String, actual: String)`, `.unreadable(String)`.

`CryptoKit` is an Apple system framework, not a package dependency, so importing it does not violate the single-dependency rule.

- [ ] **Step 1: Write the failing test**

Known value: SHA-1 of the ASCII string `abc` is `a9993e364706816aba3e25717850c26c9cd0d89d`.

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private func fileContaining(_ text: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try Data(text.utf8).write(to: url)
    return url
}

@Test("computes the SHA-1 of a file")
func computesKnownSHA1() throws {
    let url = try fileContaining("abc")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try DigestVerifier.sha1Hex(ofFileAt: url) == "a9993e364706816aba3e25717850c26c9cd0d89d")
}

@Test("accepts a file whose digest matches, ignoring case")
func acceptsMatchingDigest() throws {
    let url = try fileContaining("abc")
    defer { try? FileManager.default.removeItem(at: url) }

    try DigestVerifier.verify(fileAt: url, matches: "A9993E364706816ABA3E25717850C26C9CD0D89D")
}

@Test("reports mismatch with both digests so a corrupt download is diagnosable")
func reportsMismatch() throws {
    let url = try fileContaining("abc")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: DigestError.mismatch(
        expected: "0000000000000000000000000000000000000000",
        actual: "a9993e364706816aba3e25717850c26c9cd0d89d"
    )) {
        try DigestVerifier.verify(fileAt: url, matches: "0000000000000000000000000000000000000000")
    }
}

@Test("reports unreadable for a file that does not exist")
func reportsUnreadable() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")

    #expect(throws: DigestError.self) {
        _ = try DigestVerifier.sha1Hex(ofFileAt: missing)
    }
}

@Test("hashes a file larger than one read chunk correctly")
func hashesMultiChunkFile() throws {
    // 3 MB of a repeating byte, larger than the 1 MB read buffer.
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x41, count: 3 * 1024 * 1024).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let streamed = try DigestVerifier.sha1Hex(ofFileAt: url)

    // Compare against hashing the whole thing in memory.
    #expect(streamed == DigestVerifier.sha1Hex(of: try Data(contentsOf: url)))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter DigestVerifierTests`
Expected: FAIL — `cannot find 'DigestVerifier' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import CryptoKit
import Foundation

public enum DigestError: Error, Equatable {
    case mismatch(expected: String, actual: String)
    case unreadable(String)
}

/// Verifies a downloaded package against the digest Apple publishes in its
/// software update catalog.
///
/// Apple publishes SHA-1. That is an INTEGRITY check, not an authenticity one:
/// SHA-1 is collision-broken, so a matching digest proves the bytes arrived
/// intact, not that they came from Apple. Authenticity comes from the package
/// being Apple-signed, which `installer` verifies when the package is applied.
/// Do not present this check to users as a security guarantee.
public enum DigestVerifier {
    private static let chunkSize = 1 << 20

    public static func sha1Hex(of data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha1Hex(ofFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw DigestError.unreadable(url.path)
        }
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(fileAt url: URL, matches expected: String) throws {
        let actual = try sha1Hex(ofFileAt: url)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw DigestError.mismatch(expected: expected.lowercased(), actual: actual)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter DigestVerifierTests`
Expected: PASS, 5 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Download/DigestVerifier.swift Tests/MacOSInstallerKitTests/DigestVerifierTests.swift
git commit -m "feat: verify downloads against Apple's published digest"
```

---

### Task 10: InstallAssistantAssembler

Turns a downloaded `InstallAssistant.pkg` into `/Applications/Install macOS X.app` by running `installer`, which also verifies the package's Apple signature.

**Files:**
- Create: `Sources/MacOSInstallerKit/Assembly/AssemblyStrategy.swift`
- Create: `Sources/MacOSInstallerKit/Assembly/InstallAssistantAssembler.swift`
- Test: `Tests/MacOSInstallerKitTests/InstallAssistantAssemblerTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`.
- Produces: `protocol AssemblyStrategy: Sendable { func assemble(payloadAt: URL, expectedAppName: String) throws -> URL }`; `InstallAssistantAssembler(runner:fileManager:)`; `AssemblyError.installerFailed(exitCode: Int32, message: String)`, `.applicationNotFound(String)`.

`installer -pkg … -target /` requires root, so it is invoked through `sudo`. The process itself must not be running as root — see `PrivilegeCheck`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("invokes sudo installer with the package and a root target")
func invokesInstaller() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let pkg = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("pkg".utf8).write(to: pkg)
    let appDir = dir.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(
        at: appDir.appendingPathComponent("Install macOS Tahoe.app"), withIntermediateDirectories: true
    )

    let runner = FakeCommandRunner()
    runner.stub(standardOutput: "installer: The install was successful.",
                for: "/usr/bin/sudo /usr/sbin/installer -pkg \(pkg.path) -target /")

    let app = try InstallAssistantAssembler(runner: runner, applicationsDirectory: appDir)
        .assemble(payloadAt: pkg, expectedAppName: "Install macOS Tahoe")

    #expect(app.lastPathComponent == "Install macOS Tahoe.app")
    #expect(runner.invocations.count == 1)
    #expect(runner.invocations[0].executable == "/usr/bin/sudo")
    #expect(runner.invocations[0].arguments == ["/usr/sbin/installer", "-pkg", pkg.path, "-target", "/"])
}

@Test("passes the package path as one argument even when it contains spaces")
func handlesSpacesInPath() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let spaced = dir.appendingPathComponent("My Downloads")
    try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
    let pkg = spaced.appendingPathComponent("InstallAssistant.pkg")
    try Data("pkg".utf8).write(to: pkg)
    let appDir = dir.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(
        at: appDir.appendingPathComponent("Install macOS Tahoe.app"), withIntermediateDirectories: true
    )

    let runner = FakeCommandRunner()
    runner.stub(standardOutput: "ok", for: "/usr/bin/sudo /usr/sbin/installer -pkg \(pkg.path) -target /")

    _ = try InstallAssistantAssembler(runner: runner, applicationsDirectory: appDir)
        .assemble(payloadAt: pkg, expectedAppName: "Install macOS Tahoe")

    // The path must arrive as a single argv element, unquoted and unsplit.
    #expect(runner.invocations[0].arguments[2] == pkg.path)
    #expect(runner.invocations[0].arguments[2].contains(" "))
}

@Test("throws installerFailed carrying the exit code and stderr")
func throwsWhenInstallerFails() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let pkg = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("pkg".utf8).write(to: pkg)

    let runner = FakeCommandRunner()
    runner.stub(
        CommandResult(exitCode: 1, standardOutput: "", standardError: "package is not signed"),
        for: "/usr/bin/sudo /usr/sbin/installer -pkg \(pkg.path) -target /"
    )

    #expect(throws: AssemblyError.installerFailed(exitCode: 1, message: "package is not signed")) {
        _ = try InstallAssistantAssembler(runner: runner, applicationsDirectory: dir)
            .assemble(payloadAt: pkg, expectedAppName: "Install macOS Tahoe")
    }
}

@Test("throws applicationNotFound when installer succeeds but the app is absent")
func throwsWhenAppMissing() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let pkg = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("pkg".utf8).write(to: pkg)
    let appDir = dir.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

    let runner = FakeCommandRunner()
    runner.stub(standardOutput: "ok", for: "/usr/bin/sudo /usr/sbin/installer -pkg \(pkg.path) -target /")

    #expect(throws: AssemblyError.applicationNotFound("Install macOS Tahoe")) {
        _ = try InstallAssistantAssembler(runner: runner, applicationsDirectory: appDir)
            .assemble(payloadAt: pkg, expectedAppName: "Install macOS Tahoe")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter InstallAssistantAssemblerTests`
Expected: FAIL — types not in scope.

- [ ] **Step 3: Write the protocol and assembler**

`Sources/MacOSInstallerKit/Assembly/AssemblyStrategy.swift`:

```swift
import Foundation

/// Turns a downloaded payload into an `Install macOS X.app` bundle.
/// Two implementations are planned: the modern single-package path, and the
/// legacy chunked-ESD path, whose mechanics are still unspecified.
public protocol AssemblyStrategy: Sendable {
    func assemble(payloadAt payload: URL, expectedAppName: String) throws -> URL
}
```

`Sources/MacOSInstallerKit/Assembly/InstallAssistantAssembler.swift`:

```swift
import Foundation

public enum AssemblyError: Error, Equatable {
    case installerFailed(exitCode: Int32, message: String)
    case applicationNotFound(String)
}

/// Applies `InstallAssistant.pkg` with `installer`, which writes
/// `Install macOS X.app` into /Applications.
///
/// `installer` verifies the package's Apple signature as part of applying it,
/// which is where authenticity is actually established — the catalog's SHA-1
/// digest only proves the bytes arrived intact.
public struct InstallAssistantAssembler: AssemblyStrategy {
    public static let sudoPath = "/usr/bin/sudo"
    public static let installerPath = "/usr/sbin/installer"

    private let runner: any CommandRunner
    private let applicationsDirectory: URL

    public init(
        runner: any CommandRunner,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications")
    ) {
        self.runner = runner
        self.applicationsDirectory = applicationsDirectory
    }

    public func assemble(payloadAt payload: URL, expectedAppName: String) throws -> URL {
        // Arguments are passed as separate argv elements. Paths routinely
        // contain spaces; assembling a shell string here would break them.
        let result = try runner.run(
            Self.sudoPath,
            [Self.installerPath, "-pkg", payload.path, "-target", "/"]
        )

        guard result.exitCode == 0 else {
            throw AssemblyError.installerFailed(
                exitCode: result.exitCode,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let app = applicationsDirectory.appendingPathComponent("\(expectedAppName).app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw AssemblyError.applicationNotFound(expectedAppName)
        }

        return app
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter InstallAssistantAssemblerTests`
Expected: PASS, 4 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Assembly Tests/MacOSInstallerKitTests/InstallAssistantAssemblerTests.swift
git commit -m "feat: assemble the installer application from InstallAssistant.pkg"
```

---

### Task 11: InstallMediaWriter

The destructive step. Its defining behaviour is not running `createinstallmedia` — it is **re-resolving the target immediately beforehand**, because `/dev/diskN` numbering shifts when devices are unplugged, replugged, or enumerated in a different order. The volume the user confirmed must be the volume that gets erased.

**Files:**
- Create: `Sources/MacOSInstallerKit/Media/InstallMediaWriter.swift`
- Test: `Tests/MacOSInstallerKitTests/InstallMediaWriterTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`, `Volume`, `DiskutilClient`.
- Produces: `InstallMediaWriter(runner:)` with `func write(installerApp: URL, toVolumeWithUUID: String, expectedDeviceIdentifier: String, progress: @Sendable (String) -> Void) throws`; `MediaWriteError` with `.targetDisappeared(uuid: String)`, `.targetMoved(expected: String, found: String)`, `.targetNotMounted(uuid: String)`, `.createInstallMediaFailed(exitCode: Int32, message: String)`.

**One thing this plan cannot verify.** `createinstallmedia` is inside an installer app, and no installer app exists on the development machine, so its exact flags cannot be exercised here. The `--nointeraction` flag (which suppresses the interactive `Y` confirmation Apple's documentation describes, since this tool takes its own typed confirmation first) is specified from Apple's documented behaviour and **must be confirmed during manual verification** in Task 13. If it turns out unsupported on some version, the writer needs an interactive-stdin path instead. Record the outcome in `docs/manual-verification.md`.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter InstallMediaWriterTests`
Expected: FAIL — `cannot find 'InstallMediaWriter' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public enum MediaWriteError: Error, Equatable {
    case targetDisappeared(uuid: String)
    case targetMoved(expected: String, found: String)
    case targetNotMounted(uuid: String)
    case createInstallMediaFailed(exitCode: Int32, message: String)
}

/// Writes a bootable installer to a volume.
///
/// The volume is re-resolved by UUID in the instruction immediately preceding
/// the erase. `/dev/diskN` numbering is a lease, not a name: unplugging a hub
/// or attaching another drive renumbers devices. If the UUID now resolves to a
/// different device node than the user confirmed, this aborts rather than
/// erasing whatever is currently at that node.
public struct InstallMediaWriter {
    public static let diskutilPath = "/usr/sbin/diskutil"
    public static let sudoPath = "/usr/bin/sudo"

    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    public func write(
        installerApp: URL,
        toVolumeWithUUID uuid: String,
        expectedDeviceIdentifier: String,
        progress: @Sendable (String) -> Void
    ) throws {
        let volume = try resolve(uuid: uuid)

        guard volume.deviceIdentifier == expectedDeviceIdentifier else {
            throw MediaWriteError.targetMoved(
                expected: expectedDeviceIdentifier, found: volume.deviceIdentifier
            )
        }
        guard let mountPoint = volume.mountPoint else {
            throw MediaWriteError.targetNotMounted(uuid: uuid)
        }

        progress("Erasing \(volume.displayName) and writing the installer…")

        let tool = installerApp
            .appendingPathComponent("Contents/Resources/createinstallmedia")
            .path

        // Separate argv elements: mount points routinely contain spaces.
        // `--nointeraction` suppresses createinstallmedia's own Y/N prompt;
        // this tool has already taken an explicit typed confirmation.
        let result = try runner.run(
            Self.sudoPath, [tool, "--volume", mountPoint, "--nointeraction"]
        )

        guard result.exitCode == 0 else {
            throw MediaWriteError.createInstallMediaFailed(
                exitCode: result.exitCode,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func resolve(uuid: String) throws -> Volume {
        guard
            let info = try? runner.run(Self.diskutilPath, ["info", "-plist", uuid]),
            info.exitCode == 0,
            let volume = try? DiskutilClient.parseInfo(Data(info.standardOutput.utf8))
        else { throw MediaWriteError.targetDisappeared(uuid: uuid) }
        return volume
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter InstallMediaWriterTests`
Expected: PASS, 6 tests

- [ ] **Step 5: Mutation-check the re-resolution guards**

These three guards are what stand between a user and an erased wrong disk. For each, prove its test is load-bearing:

1. Delete `guard volume.deviceIdentifier == expectedDeviceIdentifier`. `abortsWhenTargetMoved` must fail. Restore.
2. Delete `guard let mountPoint = volume.mountPoint` (substitute `""`). `abortsWhenUnmounted` must fail. Restore.
3. Change `resolve` to return a default volume instead of throwing. `abortsWhenTargetGone` must fail. Restore.

Report all three results. If any test still passes, it is not protecting the guard — strengthen it before continuing.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacOSInstallerKit/Media Tests/MacOSInstallerKitTests/InstallMediaWriterTests.swift
git commit -m "feat: write install media, re-resolving the target immediately before erasing"
```

---

### Task 12: The create command

Wires everything into `macos-installer create`, including the typed-name confirmation.

**Files:**
- Create: `Sources/MacOSInstallerKit/Disks/VolumeTableFormatter.swift`
- Create: `Sources/macos-installer/CreateCommand.swift`
- Create: `Sources/macos-installer/ConfirmationPrompt.swift`
- Modify: `Sources/macos-installer/MacOSInstallerCommand.swift`
- Test: `Tests/MacOSInstallerKitTests/VolumeTableFormatterTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `VolumeTableFormatter.render(_ decisions: [VolumeGuard.VolumeDecision]) -> String`; `CreateCommand` with `--version`, `--volume`, `--offline`, `--yes`; `ConfirmationPrompt.requireTypedName(_ expected: String, readLine:) -> Bool`.

Formatting lives in the library so it is covered; the executable only prints.

- [ ] **Step 1: Write the failing formatter test**

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter VolumeTableFormatterTests`
Expected: FAIL — `cannot find 'VolumeTableFormatter' in scope`

- [ ] **Step 3: Write the formatter**

```swift
import Foundation

/// Renders guard decisions. Refused volumes are still shown, with the reason —
/// a user who cannot see their disk assumes the tool is broken.
public enum VolumeTableFormatter {
    public static func render(_ decisions: [VolumeGuard.VolumeDecision]) -> String {
        guard !decisions.isEmpty else { return "No drives found." }

        var lines: [String] = []

        for decision in decisions {
            let name = decision.volume.displayName
            let size = String(format: "%.1f GB", Double(decision.volume.sizeBytes) / 1_000_000_000)
            switch decision.verdict {
            case .selectable:
                lines.append("  \(name)  \(decision.volume.deviceIdentifier)  \(size)")
            case .selectableWithWarning(let warning):
                lines.append("  \(name)  \(decision.volume.deviceIdentifier)  \(size)   ⚠ \(warning)")
            case .refused(let reason):
                lines.append("  ✕ \(name)  \(decision.volume.deviceIdentifier)  \(size)   \(reason.userMessage)")
            }
        }

        let anySelectable = decisions.contains {
            if case .refused = $0.verdict { return false }
            return true
        }
        if !anySelectable {
            lines.append("")
            lines.append("No drive here can be used. Connect an external USB drive of 32 GB or larger.")
        }

        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter VolumeTableFormatterTests`
Expected: PASS, 3 tests

- [ ] **Step 5: Write the confirmation prompt**

`Sources/macos-installer/ConfirmationPrompt.swift`:

```swift
import Foundation

/// Requires the user to type the volume's name exactly. A y/N prompt is not
/// sufficient for an irreversible erase — the typing is the point, because it
/// forces the user to read which drive they picked.
enum ConfirmationPrompt {
    static func requireTypedName(
        _ expected: String,
        readLine: () -> String? = { Swift.readLine(strippingNewline: true) }
    ) -> Bool {
        readLine()?.trimmingCharacters(in: .whitespaces) == expected
    }
}
```

- [ ] **Step 6: Write the create command**

`Sources/macos-installer/CreateCommand.swift`:

```swift
import ArgumentParser
import Foundation
import MacOSInstallerKit

struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Write a bootable macOS installer to an external drive. This erases the drive."
    )

    @Option(name: .long, help: "macOS version to write, e.g. 26.7. Omit to be shown a list.")
    var version: String?

    @Option(name: .long, help: "Target volume's mount point or device identifier.")
    var volume: String?

    @Flag(name: .long, help: "Skip Apple's catalog; use only softwareupdate and local installers.")
    var offline = false

    @Flag(name: .long, help: "Skip the typed confirmation. Use only in scripts you trust.")
    var yes = false

    func run() async throws {
        try PrivilegeCheck.assertNotRoot()

        let runner = RealCommandRunner()
        let bootVolume = try BootVolumeResolver(runner: runner).resolve()
        let volumes = try DiskEnumerator(runner: runner).mountedVolumes()

        var sources: [any InstallerSource] = [
            LocalInstallerSource(),
            SoftwareUpdateSource(runner: runner),
        ]
        if !offline {
            sources.append(SucatalogSource(fetcher: URLSessionDataFetcher()))
        }
        let catalog = await ReleaseCatalog(sources: sources).allReleases()

        guard let release = select(from: catalog.releases) else {
            print(ReleaseTableFormatter.render(catalog.releases))
            print("\nPick one with --version <version>.")
            throw ExitCode.failure
        }

        let decisions = VolumeGuard.evaluate(
            volumes: volumes,
            bootVolume: bootVolume,
            requiredBytes: release.sizeBytes,
            protectedPaths: [CatalogCache.defaultDirectory.path]
        )

        guard let target = chooseTarget(from: decisions) else {
            print(VolumeTableFormatter.render(decisions))
            print("\nPick one with --volume <name or device>.")
            throw ExitCode.failure
        }

        print("")
        print("  This will ERASE \(target.displayName) (\(target.deviceIdentifier)).")
        print("  Everything on it will be destroyed.")
        print("")

        if !yes {
            print("  Type the volume name to confirm: ", terminator: "")
            guard ConfirmationPrompt.requireTypedName(target.displayName) else {
                print("  Names did not match. Nothing was changed.")
                throw ExitCode.failure
            }
        }

        guard let uuid = target.volumeUUID else {
            print("  That volume has no stable identifier, so it cannot be targeted safely.")
            throw ExitCode.failure
        }

        // Download, assemble, write — each step reported as it happens.
        print("  Preparing \(release.name) \(release.version)…")
        // (Wiring of Downloader / DigestVerifier / InstallAssistantAssembler
        //  follows the interfaces defined in Tasks 8-10.)
        let app = try await prepareInstaller(for: release)

        try InstallMediaWriter(runner: runner).write(
            installerApp: app,
            toVolumeWithUUID: uuid,
            expectedDeviceIdentifier: target.deviceIdentifier,
            progress: { print("  \($0)") }
        )

        print("  Done. The drive is now named \"Install \(release.name)\".")
    }

    private func select(from releases: [InstallerRelease]) -> InstallerRelease? {
        guard let version else { return nil }
        return releases.first { $0.version.description == version }
    }

    private func chooseTarget(from decisions: [VolumeGuard.VolumeDecision]) -> Volume? {
        guard let volume else { return nil }
        return decisions.first {
            $0.verdict != .refused(.internalDisk)
                && ($0.volume.displayName == volume || $0.volume.deviceIdentifier == volume)
                && isSelectable($0.verdict)
        }?.volume
    }

    private func isSelectable(_ verdict: VolumeGuard.Verdict) -> Bool {
        if case .refused = verdict { return false }
        return true
    }

    private func prepareInstaller(for release: InstallerRelease) async throws -> URL {
        switch release.payload {
        case .localApplication(let path):
            return path
        case .installAssistant(let url):
            let cacheDir = CatalogCache.defaultDirectory
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let pkg = cacheDir.appendingPathComponent("InstallAssistant-\(release.build).pkg")

            try await Downloader(transfer: URLSessionResumableTransfer())
                .download(from: url, to: pkg, expectedBytes: release.sizeBytes) { done, total in
                    let percent = total > 0 ? Int(done * 100 / total) : 0
                    print("\r  Downloading… \(percent)%", terminator: "")
                }
            print("")

            if let digest = release.digest {
                print("  Checking the download…")
                try DigestVerifier.verify(fileAt: pkg, matches: digest)
            }

            print("  Installing the macOS installer app (this needs your password)…")
            return try InstallAssistantAssembler(runner: RealCommandRunner())
                .assemble(payloadAt: pkg, expectedAppName: "Install \(release.name)")

        case .legacyESD:
            throw ValidationError(
                "Mojave and Catalina media are not supported yet. See the project roadmap."
            )
        case .softwareUpdate:
            throw ValidationError(
                "This release can only be fetched with `softwareupdate --fetch-full-installer`. "
                    + "Run that first, then re-run this command to use the local copy."
            )
        }
    }
}
```

Register it in `MacOSInstallerCommand.swift`:

```swift
        subcommands: [ListCommand.self, CreateCommand.self],
```

- [ ] **Step 7: Build and exercise the safe paths**

Run: `swift build`
Run: `swift run macos-installer create --help`
Run: `swift run macos-installer create` (no arguments)

The last must list releases and exit non-zero without touching a disk. Then:

Run: `swift run macos-installer create --version 26.7`

This must list volumes with `Macintosh HD` shown as refused, and exit without erasing anything. **Confirm `Macintosh HD` appears with a refusal reason and is not offered.** Paste the output into your report.

Do NOT run a command that would erase `disk4` — it holds real user data.

- [ ] **Step 8: Run the full suite and commit**

```bash
./scripts/test.sh
git add Sources Tests
git commit -m "feat: add create command with typed-name confirmation"
```

---

### Task 13: Manual verification checklist and README

The automated suite cannot prove a stick boots. This task writes down what a human must do, and is the release gate for any tag.

**Files:**
- Create: `docs/manual-verification.md`
- Modify: `README.md`

- [ ] **Step 1: Write the checklist**

Create `docs/manual-verification.md` covering, as explicit checkboxes with space to record results:

1. **Preconditions** — a spare USB drive of 32 GB or larger whose contents are expendable, named and noted before starting; confirmation that the drive is NOT the 500 GB external holding user data.
2. **Guard behaviour, non-destructive** — run `macos-installer create --version <v>` and confirm `Macintosh HD` is listed as refused, that no internal volume is offered, and that a deliberately wrong typed name aborts with nothing changed.
3. **Download and assembly** — a full run producing `Install macOS X.app`, recording the wall-clock time and whether the digest check passed.
4. **`--nointeraction` verification** — record whether `createinstallmedia` accepted the flag. This plan specifies it from Apple's documentation and could not test it; if it is rejected, note the actual behaviour and file a fix.
5. **The TCC prompt** — record whether the "Terminal would like to access files on a removable volume" dialog appeared and at which step, so the walkthrough in a later phase can pre-announce it accurately.
6. **Boot test, Apple silicon** — shut down, connect, hold the power button, select the installer, confirm the macOS installer UI loads.
7. **Boot test, pre-T2 Intel (2012–2017)** — shut down, connect, hold Option, select the installer, confirm it loads. This is the test that makes legacy support a true claim.
8. **Result table** — macOS version written, host Mac, target Mac, pass/fail, date.

State at the top that this checklist must be completed before any release tag, and that any row left unchecked must be reflected honestly in the README's support claims.

- [ ] **Step 2: Update the README**

Add a `create` section showing real usage, and state plainly: which macOS versions can currently be written (Big Sur 11 and later; Mojave and Catalina are listed but not yet writable), that the tool never offers internal or boot volumes, that it erases the target, and which hardware the media has actually been boot-tested on — leaving that list empty or marked "not yet verified" until Task 13's checklist is genuinely completed. Do not claim a boot test that has not happened.

- [ ] **Step 3: Commit**

```bash
git add docs/manual-verification.md README.md
git commit -m "docs: add manual verification checklist and document create"
```

---

## Self-Review

**Spec coverage.** Data Flow's download → checksum → assemble → re-resolve → write chain maps to Tasks 8, 9, 10, 11. The Safety Model's five refusal rules map to Task 4, with the protected-path rule wired in Task 12 via `CatalogCache.defaultDirectory`. Privilege Model maps to Tasks 6 and 10. The 24-hour cache maps to Task 6. **Gaps I am carrying deliberately:** the spec's three-part error format and `~/Library/Logs/macos-installer/` are not implemented here — they belong with the guided walkthrough in Plan 3, where all user-facing text is designed together, and implementing them piecemeal now would mean rewriting them there. The spec's Guided Walkthrough section is entirely Plan 3. The legacy ESD path is Plan 4; Task 12 fails it with an explicit message rather than pretending.

**Placeholder scan.** No "TBD" or "handle errors appropriately". One deliberate exception: Task 12's `CreateCommand` carries a comment marking where Tasks 8–10 wire together, and the body immediately below it does that wiring in full. An earlier draft of Task 12's formatter contained two scaffolding lines with an instruction to delete them; that was a trap for an inattentive implementer and has been removed from the plan rather than annotated.

**Type consistency.** `Volume` fields are identical across Tasks 2, 4, 5, 11 and 12. `BootVolume.containerReference` is optional in both Task 3 and Task 4. `VolumeGuard.Verdict` cases match between Tasks 4 and 12. `CommandRunner.run(_:_:)` keeps its two-argument shape throughout. `InstallerRelease.digest` is added with a defaulted parameter in Task 7 and read in Task 12. `AssemblyStrategy.assemble(payloadAt:expectedAppName:)` matches between Tasks 10 and 12.

**One risk I want visible.** Task 12's `create` command is the largest single task here and is the only one whose main path cannot be fully tested automatically — its terminal I/O is deliberately thin, but the wiring it performs is real. If it proves unwieldy during execution, split it: formatter and prompt first, command wiring second.

## Plan Sequence

| Plan | Scope | Status |
|---|---|---|
| 1. Version discovery | Sources, merge, `list` | Complete — PR #1 |
| **2. Media creation** | This document — cache, download, disks, guard, assembly, write, `create` | Ready |
| 3. Guided walkthrough | Target-Mac picker, three-stage beginner flow, exported instructions, error format and logging | Not written |
| 4. Legacy ESD | Opens with the reassembly spike, then `LegacyESDAssembler`; completes v1 | Not written |
