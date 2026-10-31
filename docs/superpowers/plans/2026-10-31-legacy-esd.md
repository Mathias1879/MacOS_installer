# Legacy ESD (Mojave & Catalina) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Mojave 10.14 and Catalina 10.15 writable by assembling the legacy chunked catalog product into a working `Install macOS X.app` without root. Also fix the shipped digest bug that would fail every real download, modern ones included.

**Architecture:** Port macUSB's no-root legacy assembly (`MacOSAssemblyLegacyFlow.swift`, MIT, © 2025-2026 Krystian Pierz) as a second `AssemblyStrategy`. Turn `AssemblyStrategy` into a real strategy: each one declares the files it needs downloaded and then assembles them. `InstallerPreparer` picks a strategy by payload instead of hardcoding one `InstallAssistant-<build>.pkg`. macUSB has no authenticity check, so this plan adds a `pkgutil --check-signature` gate. The legacy path never runs `installer`, which is where the modern path gets its signature check.

**Tech Stack:** Swift 6.0 tools, macOS 13+, Swift Testing, `CommandRunner` seam for `pkgutil` and `diskutil`.

**Spec:** `docs/superpowers/specs/2026-09-26-macos-installer-design.md`. Its "Known Gap" section is replaced by Task 8, using the spike facts below.

**Branch:** `legacy-esd`, stacked on `guided-walkthrough` (PR #3). The PR targets `guided-walkthrough`.

---

## Spike results (run 2026-10-31, replaces the spike the spec required)

Run against Apple's live merged catalog (the URL in `CatalogURLResolver`) and product **001-68446** (Catalina 10.15.7, 19H15). Downloads went only to the gitignored `.superpowers/spike/`. No drive was touched and nothing ran under sudo.

1. **The catalog `Digest` is the SHA-1 of the xar archive's compressed table of contents, not of the file.** Header: 28 bytes, big-endian `magic(4) headerSize(UInt16) version(UInt16) tocCompressedLength(UInt64) tocUncompressedLength(UInt64) checksumAlgorithm(UInt32)`. The digest is `SHA1(bytes[headerSize ..< headerSize + tocCompressedLength])`, which is also the 20 bytes stored at the start of the heap. Confirmed for `InstallAssistantAuto.pkg` (`c6a2cb776cf80f41f078ce84d319ff0010a13f40`), `RecoveryHDMetaDmg.pkg` (`d41292b3…22ed6`), `InstallESDDmg.pkg` (`043fb10e…34df3`), **and the modern `InstallAssistant.pkg`** of 142-50020 (`c7df6521…865d`). The whole-file SHA-1 of `InstallAssistantAuto.pkg` is `78e6321c…bd1`, which does not match. **Today's `DigestVerifier` hashes the whole file, so every real `create` download fails verification twice and aborts.** No test could see it, because the download is faked end to end.
2. All 13 legacy products in the catalog (10.13.5 to 10.15.7) carry all three of `InstallAssistantAuto.pkg`, `RecoveryHDMetaDmg.pkg` and `InstallESDDmg.pkg`, each with a `Digest`. They also carry 7–8 other files (`BaseSystem.dmg`, chunklists, `OSInstall.mpkg`, …) that are **not needed**: `BaseSystem.*` comes from inside RecoveryHDMeta. Today's `legacyESDURLs` takes every package and `totalSize` sums them all.
3. All three are xar pkgs, signed `Status: signed Apple Software` (chain: Software Update → Apple Software Update Certification Authority → Apple Root CA, leaf expires 2029-04-14). `pkgutil --check-signature` on a **truncated** file reports `Status: package is invalid (checksum did not verify)` with exit 1, so it checks the whole file's contents, not just the signature.
4. `pkgutil --expand-full InstallAssistantAuto.pkg <dir>` yields `<dir>/Payload/Install macOS Catalina.app`. Its `Contents/SharedSupport/` already holds `InstallInfo.plist`. `Info.plist` has `CFBundleDisplayName` = `Install macOS Catalina`, `DTPlatformVersion` = `10.15.6`, `DTSDKBuild` = `19H11`. Note this is **not** the catalog's 10.15.7 / 19H15.
5. The package's only postinstall action sets a beta-seed xattr when the Mac is enrolled in a seed program, so skipping `installer` loses nothing.
6. `diskutil image attach --readOnly --mountOptions nobrowse --mountPoint <mp> RecoveryHDMetaDmg.pkg` mounts it, and `diskutil eject <mp>` ejects it. Contents: `AppleDiagnostics.chunklist`, `AppleDiagnostics.dmg`, `BaseSystem.chunklist`, `BaseSystem.dmg`. `hdiutil attach` is deprecated on this OS and failed with "Permission denied" when the mountpoint was on the external volume.
7. `codesign --verify` fails on the **untouched** expanded app ("resource envelope is obsolete (custom omit rules)"), so it cannot be used as a gate. Authenticity comes from finding 3.
8. `Contents/Resources/createinstallmedia` is `Mach-O 64-bit executable x86_64`. On an Apple-silicon host without Rosetta, `/usr/bin/arch -x86_64 /usr/bin/true` exits 1 ("Bad CPU type in executable"). That is the probe.

---

## Global Constraints

- Writable range after this plan: **Mojave 10.14 through macOS 27.** High Sierra 10.13 stays listed and refused (spec: "Writable versions | Mojave 10.14 through macOS 27 Golden Gate").
- Run tests with `./scripts/test.sh`, never bare `swift test`. CI is `./scripts/ci.sh`, which gates `MacOSInstallerKit` at 93% line coverage.
- Never run `createinstallmedia`, `installer`, `sudo`, or write-mode `diskutil` against the development Mac. Never pass `--volume` while testing.
- Refusals are absolute. Add no override flag and no `--force`. Never overwrite or delete anything in `/Applications`.
- Every new `Error` conforms to `Explainable`. Every `whatHappened` on a pre-write error ends with `The drive was not touched.` Each new case is added to the exhaustive checks in `ExplanationWordingTests.swift` and `PreparationChainTotalityTests.swift`.
- Pass arguments as separate argv elements. Never build shell strings (macUSB's `zsh -lc` path is **not** ported).
- Logic lives in `MacOSInstallerKit`. `CreateCommand` only wires.
- Commit format is `<type>: <description>`. Every commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Test expectations use literal values from the spike or the spec, never values computed by the code under test. Correctness-critical guards (Tasks 1, 3, 5, 6) get a mutation check: break the guard, see a named test fail, restore it. Confirm the build exits 0 before trusting a mutation result.

## Review Focus

1. **Apple-silicon target + a 10.x release.** Catalina cannot boot an M-series Mac. Refuse before the Before stage and the erase confirmation (Task 3, `refusesLegacyReleaseForAppleSiliconTarget`).
2. **Apple-silicon host without Rosetta.** `createinstallmedia` is x86_64-only. Refuse before the erase with the install command, never after (Task 3, `refusesLegacyReleaseWithoutRosetta`).
3. **A failure after `InstallESD.dmg` was moved into the app.** The 5–8 GB part must go back to its download path, so a re-run doesn't re-download it (Task 6, `restoresInstallESDWhenAssemblyFails`).
4. **`Install macOS Catalina.app` already in `/Applications`** (an older build the user kept). Refuse before any 8 GB signature check or expansion, and leave it untouched (Task 6, `refusesWhenDestinationAppExists`).
5. **A package that `pkgutil` accepts with exit 0 but that is not Apple Software** (e.g. Developer ID). Refuse on the status line, not just the exit code (Task 5, `refusesDeveloperIDSignedPackage`).

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/MacOSInstallerKit/Download/XarTableOfContents.swift` (new) | Parse a xar header, SHA-1 its compressed TOC |
| `Sources/MacOSInstallerKit/Download/DigestVerifier.swift` (modify) | Compare the catalog digest with the TOC digest |
| `Sources/MacOSInstallerKit/Catalog/CatalogProduct.swift` (modify) | Select exactly the three legacy packages |
| `Sources/MacOSInstallerKit/Models/LegacyESDPackages.swift` (new) | The three-package value carried by the payload |
| `Sources/MacOSInstallerKit/Models/InstallerRelease.swift` (modify) | `.legacyESD(LegacyESDPackages)`, writable floor |
| `Sources/MacOSInstallerKit/Pipeline/ReleaseGates.swift` (new) | Pre-erase checks: target compatibility, Rosetta |
| `Sources/MacOSInstallerKit/Assembly/AssemblyStrategy.swift` (modify) | `PlannedDownload`, the two-method protocol, `AssemblerSet` |
| `Sources/MacOSInstallerKit/Assembly/PackageSignatureVerifier.swift` (new) | The `pkgutil --check-signature` gate |
| `Sources/MacOSInstallerKit/Assembly/LegacyESDAssembler.swift` (new) | The ported assembly |
| `Sources/MacOSInstallerKit/Assembly/LegacyAssemblyError.swift` (new) | Its errors and explanations |
| `Sources/MacOSInstallerKit/Pipeline/InstallerPreparer.swift` (modify) | Strategy selection, per-file download loop |

---

### Task 1: Verify the catalog digest against the xar TOC

**Files:**
- Create: `Sources/MacOSInstallerKit/Download/XarTableOfContents.swift`
- Modify: `Sources/MacOSInstallerKit/Download/DigestVerifier.swift`
- Create fixture: `Tests/MacOSInstallerKitTests/Fixtures/InstallAssistantAuto-001-68446-head.bin`
- Test: `Tests/MacOSInstallerKitTests/XarTableOfContentsTests.swift`, `Tests/MacOSInstallerKitTests/DigestVerifierTests.swift`

**Interfaces:**
- Produces: `enum XarTableOfContents { static func sha1Hex(ofArchiveAt url: URL) throws -> String }` throws `DigestError.unreadable(path)` or the new `DigestError.notAnArchive(path: String)`. `DigestVerifier.verify(fileAt:matches:)` keeps its signature and now compares against `XarTableOfContents.sha1Hex`.

- [ ] **Step 1: Create the fixture.** It is the first 8192 bytes of the real package, enough to hold the 28-byte header and the 4117-byte TOC.

```bash
curl -s -r 0-8191 -o Tests/MacOSInstallerKitTests/Fixtures/InstallAssistantAuto-001-68446-head.bin \
  https://swcdn.apple.com/content/downloads/26/37/001-68446/r1dbqtmf3mtpikjnd04cq31p4jk91dceh8/InstallAssistantAuto.pkg
wc -c Tests/MacOSInstallerKitTests/Fixtures/InstallAssistantAuto-001-68446-head.bin   # expect 8192
```

- [ ] **Step 2: Write the failing tests.** The expected value is Apple's published catalog digest, an independent source.

```swift
@Test("TOC digest of a real Apple package equals the catalog's published Digest")
func tocDigestMatchesAppleCatalog() throws {
    let url = try fixtureURL("InstallAssistantAuto-001-68446-head.bin")
    #expect(try XarTableOfContents.sha1Hex(ofArchiveAt: url) == "c6a2cb776cf80f41f078ce84d319ff0010a13f40")
}

@Test("a file without the xar magic is refused as not an archive")
func nonXarFileIsRefused() throws {
    let url = try temporaryFile(contents: Data(repeating: 0x41, count: 64))
    #expect(throws: DigestError.notAnArchive(path: url.path)) { try XarTableOfContents.sha1Hex(ofArchiveAt: url) }
}

@Test("a xar header whose TOC runs past end of file is refused as not an archive")
func truncatedTOCIsRefused() throws { /* first 100 bytes of the fixture → .notAnArchive */ }

@Test("verify accepts the real package head against the catalog digest")
func verifyAcceptsCatalogDigest() throws {
    try DigestVerifier.verify(fileAt: fixtureURL("InstallAssistantAuto-001-68446-head.bin"),
                              matches: "C6A2CB776CF80F41F078CE84D319FF0010A13F40")   // case-insensitive, as today
}
```

Replace every existing `DigestVerifierTests` case that hashes arbitrary bytes. Their premise, a whole-file SHA-1, is the bug. Keep the mismatch test, but build it from the fixture plus a wrong digest. `actual` must equal `c6a2cb…3f40`.

- [ ] **Step 3: Run them.** `./scripts/test.sh --filter "XarTableOfContents|DigestVerifier"`. Expected: FAIL (no `XarTableOfContents`).

- [ ] **Step 4: Implement.** Read only `headerSize + tocCompressedLength` bytes, never the whole file (packages run to 18 GB). Reject when the magic isn't `xar!`, `headerSize < 28`, or the file is shorter than the TOC end. Add `case notAnArchive(path: String)` to `DigestError`. Explanation title: "The download isn't the kind of file Apple publishes". `whatToDoNext`: "Run this command again to download a fresh copy". Like the other cases, it is deleted and retried once by `InstallerPreparer`, so `DigestError`'s catch there needs no change. Rewrite `DigestVerifier`'s doc comment: the digest covers the TOC, and the TOC carries per-file checksums that `installer` (modern) or `pkgutil` (legacy, Task 5) verify against the payload. Delete `sha1Hex(ofFileAt:)` if nothing else uses it.

- [ ] **Step 5: Run.** `./scripts/test.sh`. Expected: all pass. Mutation: change the hashed range to `0 ..< headerSize`, and `tocDigestMatchesAppleCatalog` must fail.

- [ ] **Step 6: Commit.** `fix: verify Apple's catalog digest against the xar table of contents`

---

### Task 2: Carry exactly the three legacy packages

**Files:**
- Create: `Sources/MacOSInstallerKit/Models/LegacyESDPackages.swift`
- Modify: `Sources/MacOSInstallerKit/Catalog/CatalogProduct.swift`, `Sources/MacOSInstallerKit/Models/InstallerRelease.swift`, `Sources/MacOSInstallerKit/Sources/SucatalogSource.swift:68-69`, `Tests/MacOSInstallerKitTests/Fixtures/mini-catalog.plist`
- Test: `Tests/MacOSInstallerKitTests/SucatalogClientTests.swift`, `SucatalogSourceTests.swift`, `InstallerReleaseTests.swift`

**Interfaces:**
- Produces:
  - `public struct LegacyESDPackages: Equatable, Sendable { public let installAssistantAuto: CatalogPackage; public let recoveryHDMeta: CatalogPackage; public let installESD: CatalogPackage; public var totalSize: Int64 }`
  - `CatalogProduct.installAssistantAutoFilename = "InstallAssistantAuto.pkg"`, `.recoveryHDMetaFilename = "RecoveryHDMetaDmg.pkg"` (alongside the existing `legacyESDFilename`)
  - `CatalogProduct.legacyESDPackages: LegacyESDPackages?`, which is `nil` unless all three are present
  - `kind == .legacyESD` only when `legacyESDPackages != nil`. A product with `InstallESDDmg.pkg` but missing a sibling becomes `.other` and is dropped. `legacyESDURLs` is removed.
  - `InstallerRelease.Payload.legacyESD(LegacyESDPackages)` replaces `.legacyESD(urls:)`
  - `InstallerRelease.oldestWritableLegacyVersion = OSVersion("10.14")!`

- [ ] **Step 1: Update the fixture.** The legacy product in `mini-catalog.plist` gets `InstallAssistantAuto.pkg` (Size 11, Digest `aaaa…`), `RecoveryHDMetaDmg.pkg` (Size 500), `InstallESDDmg.pkg` (Size 7000) and an extra `BaseSystem.dmg` (Size 480), with digests for the three. Add a second legacy product that has `InstallESDDmg.pkg` but no `RecoveryHDMetaDmg.pkg`.

- [ ] **Step 2: Write the failing tests.**

```swift
@Test("legacy product selects exactly the three required packages")
func legacyProductSelectsThreePackages() throws {
    let packages = try #require(legacy.legacyESDPackages)
    #expect(packages.installAssistantAuto.url.lastPathComponent == "InstallAssistantAuto.pkg")
    #expect(packages.recoveryHDMeta.url.lastPathComponent == "RecoveryHDMetaDmg.pkg")
    #expect(packages.installESD.url.lastPathComponent == "InstallESDDmg.pkg")
}
@Test("legacy size counts only the three packages, not BaseSystem.dmg")
func legacySizeExcludesSiblings() { #expect(legacy.totalSize == 7_511) }
@Test("legacy product missing RecoveryHDMetaDmg is not offered")
func incompleteLegacyProductIsOther() { #expect(incomplete.kind == .other) }
@Test("SucatalogSource maps a legacy product to .legacyESD with the three packages")
func sourceMapsLegacyPayload() async throws { /* #expect(release.payload == .legacyESD(expectedPackages)); #expect(release.sizeBytes == 7_511) */ }
```

- [ ] **Step 3: Run.** Expected: FAIL to compile. Then update every `.legacyESD(urls: [])` in tests to a `LegacyESDPackages` sample built by one shared helper, `Support/LegacySample.swift`, with `func legacyPackages(build: String = "19H15") -> LegacyESDPackages`. The same file defines `let catalina = InstallerRelease(name: "macOS Catalina", version: OSVersion("10.15.7")!, build: "19H15", sizeBytes: 8_248_985_973, origin: .sucatalog, payload: .legacyESD(legacyPackages()))` and an equivalent modern `sonoma` (14.x, `.installAssistant`), which Tasks 3, 6 and 7 use.

- [ ] **Step 4: Implement.** Match filenames exactly as `kind` does today. Case-insensitive matching stays deferred (carry-forward).

- [ ] **Step 5: Run.** `./scripts/test.sh`. Expected: all pass.

- [ ] **Step 6: Commit.** `feat: select exactly the three packages a legacy product needs`

---

### Task 3: Pre-erase gates for legacy releases

**Files:**
- Create: `Sources/MacOSInstallerKit/Pipeline/ReleaseGates.swift`
- Modify: `Sources/MacOSInstallerKit/Pipeline/InstallerPreparer.swift` (`assertUsable`, `InstallerPreparationError`)
- Test: `Tests/MacOSInstallerKitTests/ReleaseGatesTests.swift`, `InstallerPreparerTests.swift`

**Interfaces:**
- Produces:
  - `InstallerPreparer.assertUsable(_:)` now throws `.legacyAssemblyNotSupported` only when `.legacyESD` **and** `version < InstallerRelease.oldestWritableLegacyVersion`
  - `public enum ReleaseGates { static func assertBootable(_ release: InstallerRelease, on target: TargetMac?) throws }` throws `InstallerPreparationError.cannotBootAppleSilicon(name: String)` when `target == .appleSilicon && release.requiresLegacyAssembly`. A nil target (under `--brief`) is not gated.
  - `public struct RosettaCheck: Sendable { init(runner: any CommandRunner, hostIsAppleSilicon: Bool = RosettaCheck.hostIsAppleSilicon); func assertCanRunIntelTools(for release: InstallerRelease) throws }` throws `InstallerPreparationError.rosettaRequired(name: String)`. `static let hostIsAppleSilicon: Bool` uses `#if arch(arm64)`. The probe is `/usr/bin/arch -x86_64 /usr/bin/true`, and exit 0 means present. It runs only when `hostIsAppleSilicon && release.requiresLegacyAssembly`.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test("High Sierra legacy release is refused; Catalina legacy release is usable")
func writableFloorIsMojave() throws {
    #expect(throws: InstallerPreparationError.legacyAssemblyNotSupported) {
        try InstallerPreparer.assertUsable(release("macOS High Sierra", "10.13.6", payload: .legacyESD(legacyPackages())))
    }
    try InstallerPreparer.assertUsable(release("macOS Catalina", "10.15.7", payload: .legacyESD(legacyPackages())))
}
@Test("legacy release for an Apple silicon target is refused")
func refusesLegacyReleaseForAppleSiliconTarget() {
    #expect(throws: InstallerPreparationError.cannotBootAppleSilicon(name: "macOS Catalina")) {
        try ReleaseGates.assertBootable(catalina, on: .appleSilicon)
    }
}
@Test("legacy release for Intel targets and modern release for Apple silicon pass")
func compatiblePairsPass() throws { /* catalina on .intelT2, .intelPreT2, nil; sonoma on .appleSilicon */ }
@Test("legacy release on an Apple silicon host without Rosetta is refused")
func refusesLegacyReleaseWithoutRosetta() {
    let runner = FakeCommandRunner()
    runner.stub(CommandResult(exitCode: 1, standardOutput: "",
        standardError: "arch: posix_spawnp: /usr/bin/true: Bad CPU type in executable"),
        for: "/usr/bin/arch -x86_64 /usr/bin/true")
    #expect(throws: InstallerPreparationError.rosettaRequired(name: "macOS Catalina")) {
        try RosettaCheck(runner: runner, hostIsAppleSilicon: true).assertCanRunIntelTools(for: catalina)
    }
}
@Test("Rosetta probe is not run for a modern release or on an Intel host")
func rosettaProbeSkipped() throws { /* #expect(runner.invocations.isEmpty) for both */ }
```

- [ ] **Step 2: Run.** `./scripts/test.sh --filter "ReleaseGates|InstallerPreparer"`. Expected: FAIL.

- [ ] **Step 3: Implement.** The copy is fixed:
  - `.legacyAssemblyNotSupported`: title "This macOS version isn't supported", whatHappened "macOS High Sierra and older can't be written by this tool. The drive was not touched.", next step "Choose macOS Mojave or later". Also update `userMessage`.
  - `.cannotBootAppleSilicon(name)`: title "That Mac can't run this version", whatHappened "\(name) can't start up a Mac with Apple silicon. The drive was not touched.", whatItMeans "Apple silicon Macs need macOS Big Sur 11 or later.", next steps "Choose macOS Big Sur or later for this Mac", "Or run this again and pick an Intel Mac as the target, if that's the Mac you meant".
  - `.rosettaRequired(name)`: title "This Mac needs Rosetta for that version", whatHappened "The tool that writes \(name) to a drive only runs on Intel Macs, and Rosetta isn't installed on this Mac. The drive was not touched.", whatItMeans "Rosetta lets this Mac run Intel-only tools. It's free and from Apple.", next steps "Run: softwareupdate --install-rosetta --agree-to-license", "Run this command again".
  - Add all three to the exhaustive wording checks.

- [ ] **Step 4: Run.** Expected: PASS. Mutations: change `version <` to `<=` in the floor, and drop the `.appleSilicon` condition. Each must fail a named test.

- [ ] **Step 5: Commit.** `feat: refuse legacy releases a target or host cannot use, before the erase`

---

### Task 4: Make `AssemblyStrategy` a real strategy

**Files:**
- Modify: `Sources/MacOSInstallerKit/Assembly/AssemblyStrategy.swift`, `InstallAssistantAssembler.swift`, `Sources/MacOSInstallerKit/Pipeline/InstallerPreparer.swift`
- Test: `Tests/MacOSInstallerKitTests/InstallerPreparerTests.swift`, `InstallAssistantAssemblerTests.swift`

**Interfaces:**
- Produces:

```swift
public struct PlannedDownload: Equatable, Sendable {
    public let url: URL; public let fileName: String; public let sizeBytes: Int64; public let digest: String?
}
public protocol AssemblyStrategy: Sendable {
    func plannedDownloads(for release: InstallerRelease) -> [PlannedDownload]
    /// `downloaded` is in `plannedDownloads` order.
    func assemble(downloaded: [URL], release: InstallerRelease,
                  progress: @Sendable @escaping (String) -> Void) throws -> URL
}
public struct AssemblerSet: Sendable {
    public let installAssistant: any AssemblyStrategy
    public let legacyESD: any AssemblyStrategy
}
InstallerPreparer.init(downloader: Downloader, assemblers: AssemblerSet,
                       cacheDirectory: URL = CatalogCache.defaultDirectory, fileManager: FileManager = .default)
```

- `InstallAssistantAssembler.plannedDownloads` returns `[PlannedDownload(url, "InstallAssistant-\(build).pkg", release.sizeBytes, release.digest)]` for `.installAssistant`, otherwise `[]`. Its `assemble` emits the existing "Installing the macOS installer app (this needs your password)…" itself. That line moves out of the preparer.

- [ ] **Step 1: Write the failing tests.** A `RecordingAssembler` test double returns fixed `PlannedDownload`s and records what it was given.

```swift
@Test("a legacyESD release is assembled by the legacy strategy with its three downloads in order")
func legacyReleaseUsesLegacyStrategy() async throws {
    // legacy RecordingAssembler plans a.pkg, b.pkg, c.pkg; installAssistant one plans nothing
    #expect(legacy.receivedDownloads.map(\.lastPathComponent) == ["a.pkg", "b.pkg", "c.pkg"])
    #expect(modern.assembleCallCount == 0)
}
@Test("each planned download is digest-checked and retried once on mismatch, independently")
func perFileDigestRetry() async throws { /* second file mismatches once → it alone is re-fetched; FakeTransfer call count == 4 */ }
@Test("multi-part downloads report the part number")
func multiPartProgress() async throws { /* progress contains exactly "Downloading part 2 of 3… 50%" */ }
@Test("single-part download keeps the existing progress wording")
func singlePartProgressUnchanged() async throws { /* contains "Downloading… 50%", no "part" */ }
```

- [ ] **Step 2: Run.** Expected: FAIL to compile.

- [ ] **Step 3: Implement.** `prepare` switches on the payload only to choose `assemblers.installAssistant` or `.legacyESD`. `.localApplication` and `.softwareUpdate` keep today's behavior, and `.legacyESD` below the floor throws `.legacyAssemblyNotSupported` (defense in depth, as now). Generalize `downloadAndVerify`, `performDownload` and `verifyDigestIfPresent` to take a `PlannedDownload` plus its destination `cacheDirectory/fileName`. Delete the hardcoded `InstallAssistant-<build>.pkg`. Update the `AssemblyStrategy` doc comment: there are two implementations now, and neither is "unspecified".

- [ ] **Step 4: Run.** `./scripts/test.sh`. Expected: all pass, including every existing `InstallerPreparerTests` case with only its construction changed.

- [ ] **Step 5: Commit.** `refactor: let each assembly strategy declare its downloads; select by payload`

---

### Task 5: Package signature gate

**Files:**
- Create: `Sources/MacOSInstallerKit/Assembly/PackageSignatureVerifier.swift`
- Create fixtures: `Tests/MacOSInstallerKitTests/Fixtures/pkgutil-signature-apple.txt` (the spike's real `pkgutil --check-signature InstallAssistantAuto.pkg` output, verbatim)
- Test: `Tests/MacOSInstallerKitTests/PackageSignatureVerifierTests.swift`

**Interfaces:**
- Produces: `public struct PackageSignatureVerifier: Sendable { init(runner: any CommandRunner); func verify(packageAt url: URL) throws }`. It runs `/usr/sbin/pkgutil --check-signature <path>`. It passes **iff** the exit code is 0 **and** some line, trimmed, equals `Status: signed Apple Software`. Otherwise it throws `public enum PackageSignatureError: Error, Equatable { case notAppleSigned(fileName: String, status: String) }`. `status` is the text after `Status: `, or `no status reported`.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test("real Apple-signed output passes") func acceptsAppleSoftware()            // fixture, exit 0
@Test("truncated package is refused with pkgutil's status")
func refusesInvalidChecksum() { /* stdout "Package \"x.pkg\":\n   Status: package is invalid (checksum did not verify)\n", exit 1
   → .notAppleSigned(fileName: "x.pkg", status: "package is invalid (checksum did not verify)") */ }
@Test("Developer ID signature is refused even though pkgutil exits 0")
func refusesDeveloperIDSignedPackage() { /* "Status: signed by a developer certificate issued by Apple for distribution", exit 0 */ }
@Test("no Status line is refused") func refusesMissingStatus()  // status == "no status reported"
```

- [ ] **Step 2: Run.** Expected: FAIL.

- [ ] **Step 3: Implement.** Explanation: title "A downloaded part isn't signed by Apple", whatHappened "\(fileName) did not pass macOS's signature check (\(status)). The drive was not touched.", whatItMeans "This tool only uses installer parts signed by Apple. The file may be damaged or incomplete.", next steps "Delete the cached download and run this command again: \(cache path)", "If it keeps failing, check your internet connection". Get the cache path from `CatalogCache.defaultDirectory.path`. Add it to the wording and totality checks.

- [ ] **Step 4: Run.** Expected: PASS. Mutation: accept on exit code 0 alone, and `refusesDeveloperIDSignedPackage` must fail.

- [ ] **Step 5: Commit.** `feat: require Apple's package signature on legacy installer parts`

---

### Task 6: `LegacyESDAssembler` (the port)

**Files:**
- Create: `Sources/MacOSInstallerKit/Assembly/LegacyESDAssembler.swift`, `Sources/MacOSInstallerKit/Assembly/LegacyAssemblyError.swift`
- Modify: `Tests/MacOSInstallerKitTests/Support/FakeCommandRunner.swift`
- Test: `Tests/MacOSInstallerKitTests/LegacyESDAssemblerTests.swift`

**Interfaces:**
- Consumes: `PlannedDownload`, `AssemblyStrategy` (Task 4); `LegacyESDPackages` (Task 2); `PackageSignatureVerifier` (Task 5); `AssemblyError.applicationNotFound` (existing).
- Produces:

```swift
public struct LegacyESDAssembler: AssemblyStrategy {
    public static let pkgutilPath = "/usr/sbin/pkgutil"
    public static let diskutilPath = "/usr/sbin/diskutil"
    /// What createinstallmedia needs in SharedSupport; AppleDiagnostics.* is copied when present but not required.
    public static let requiredSharedSupport = ["BaseSystem.chunklist", "BaseSystem.dmg", "InstallESD.dmg", "InstallInfo.plist"]
    public init(runner: any CommandRunner, signatureVerifier: PackageSignatureVerifier,
                workspaceRoot: URL = CatalogCache.defaultDirectory,
                applicationsDirectory: URL = URL(fileURLWithPath: "/Applications"),
                makeMountPoint: @escaping @Sendable () -> URL = { FileManager.default.temporaryDirectory
                    .appendingPathComponent("macos-installer-recovery-\(UUID().uuidString)") },
                fileManager: FileManager = .default)
}
public enum LegacyAssemblyError: Error, Equatable {
    case destinationExists(path: String)
    case expandFailed(exitCode: Int32, message: String)
    case recoveryImageAttachFailed(exitCode: Int32, message: String)
    case installerIncomplete(missing: [String])      // sorted
}
```

- `plannedDownloads(for:)` returns `[auto, recoveryHDMeta, installESD]` with fileNames `"\(build)-InstallAssistantAuto.pkg"`, `"\(build)-RecoveryHDMetaDmg.pkg"`, `"\(build)-InstallESDDmg.pkg"`, and sizes and digests from `LegacyESDPackages`.
- `FakeCommandRunner` gains `func onRun(_ commandLine: String, perform: @escaping @Sendable () throws -> Void)`. The action runs before the stubbed result is returned, which lets a fake `pkgutil --expand-full` create the expanded tree and a fake `diskutil image attach` populate the mount point.

**Algorithm** (the decision this task exists for; order matters):

1. `dest = applicationsDirectory/"Install \(release.name).app"`. If it exists, throw `.destinationExists`. **No command has run yet.**
2. Emit progress "Checking the downloaded parts are signed by Apple…". Verify all three, in plan order.
3. Emit progress "Putting the installer app together…". Set `workspace = workspaceRoot/"legacy-\(build)"`. Remove it if present, then create it.
4. Run `pkgutil --expand-full <auto> <workspace>/expanded`. On non-zero exit, throw `.expandFailed`.
5. `app = <workspace>/expanded/Payload/"Install \(release.name).app"`. If it's missing, throw `AssemblyError.applicationNotFound(release.name)`. Use the exact name, not macUSB's first-`.app` fallback.
6. **Move** (not copy: saves 5–8 GB) `<installESD>` to `app/Contents/SharedSupport/InstallESD.dmg`. From here on, every throw path moves it back to its downloaded path before rethrowing.
7. Create `mp = makeMountPoint()`. Run `diskutil image attach --readOnly --mountOptions nobrowse --mountPoint <mp> <recoveryHDMeta>`. On non-zero exit, throw `.recoveryImageAttachFailed`.
8. Copy every non-hidden item in `mp` into SharedSupport. Always run `diskutil eject <mp>` afterwards, `defer`-style. If eject exits non-zero, emit progress "Note: a temporary read-only disk image couldn't be ejected. It's harmless and goes away when you restart." and continue.
9. Any name in `requiredSharedSupport` missing from SharedSupport → throw `.installerIncomplete(missing:)`.
10. Move `app` to `dest`. Remove the workspace. If that fails, emit progress "Note: couldn't remove temporary files at \(workspace.path)." Return `dest`.

Header doc comment: "Ported from macUSB's `MacOSAssemblyLegacyFlow.swift` (MIT, © 2025-2026 Krystian Pierz, https://github.com/Kruszoneq/macUSB). Changes: signature gate, exact app name, move instead of copy, restore on failure, argv instead of shell, `diskutil image` instead of the deprecated `hdiutil`."

- [ ] **Step 1: Add `onRun` to `FakeCommandRunner`** with a test in `FakeCommandRunnerTests.swift`: `onRunActionExecutesBeforeResultReturns`.

- [ ] **Step 2: Write the failing tests.** Use real temp directories, with fake `pkgutil` and `diskutil` creating trees through `onRun`. The fake expand **fails with exit 1 if its destination already exists**, as the real `pkgutil` does.

```swift
@Test("plans the three parts in order with build-prefixed names")
func plannedDownloadsListsThreePartsInOrder() {
    #expect(assembler.plannedDownloads(for: catalina).map(\.fileName)
        == ["19H15-InstallAssistantAuto.pkg", "19H15-RecoveryHDMetaDmg.pkg", "19H15-InstallESDDmg.pkg"])
}
@Test("assembles a complete installer into Applications")
func assemblesInstallerIntoApplications() throws {
    let app = try assembler.assemble(downloaded: parts, release: catalina) { _ in }
    #expect(app == applications.appendingPathComponent("Install macOS Catalina.app"))
    #expect(try contents(of: app/"Contents/SharedSupport") == ["AppleDiagnostics.chunklist", "AppleDiagnostics.dmg",
        "BaseSystem.chunklist", "BaseSystem.dmg", "InstallESD.dmg", "InstallInfo.plist"])
    #expect(!fileExists(parts[2]))                         // moved, not copied
    #expect(runner.commandLines.map(firstTwoWords) == ["/usr/sbin/pkgutil --check-signature", "/usr/sbin/pkgutil --check-signature",
        "/usr/sbin/pkgutil --check-signature", "/usr/sbin/pkgutil --expand-full", "/usr/sbin/diskutil image", "/usr/sbin/diskutil eject"])
    #expect(!fileExists(workspace))
}
@Test("refuses when the destination app already exists, running nothing")
func refusesWhenDestinationAppExists() { /* .destinationExists(path:); runner.invocations.isEmpty; existing app bytes unchanged */ }
@Test("an unsigned part stops assembly before expansion")
func unsignedPartStopsBeforeExpand() { /* 2nd signature check fails → PackageSignatureError; !runner.didInvoke(containing: "--expand-full") */ }
@Test("restores InstallESD and ejects when required files are missing")
func restoresInstallESDWhenAssemblyFails() {
    // mount provides only AppleDiagnostics.* → .installerIncomplete(missing: ["BaseSystem.chunklist", "BaseSystem.dmg"])
    // fileExists(parts[2]) == true; runner.didInvoke(containing: "/usr/sbin/diskutil eject")
}
@Test("attach failure restores InstallESD and does not eject")
func attachFailureRestores() { /* .recoveryImageAttachFailed(exitCode: 1, message: "…"); parts[2] exists; no eject */ }
@Test("expand failure leaves all three downloaded parts in place")
func expandFailureKeepsParts() { /* .expandFailed(exitCode: 1, ...); all three exist */ }
@Test("a stale workspace from an interrupted run is replaced")
func staleWorkspaceIsReplaced() { /* pre-create workspace/expanded; assemble succeeds */ }
@Test("an eject failure is reported but not fatal")
func ejectFailureIsNotFatal() { /* eject exit 1 → returns app; progress contains the exact Note string */ }
```

- [ ] **Step 3: Run.** `./scripts/test.sh --filter LegacyESDAssembler`. Expected: FAIL.

- [ ] **Step 4: Implement** the algorithm above. `LegacyAssemblyError` explanations all end their `whatHappened` with "The drive was not touched.":
  - `.destinationExists`: "\(path) is already on this Mac, and this tool won't replace it." Next steps: "To use it as-is, run this command again: it is listed as a local installer", "To build a fresh copy, move it out of Applications first".
  - `.expandFailed` / `.recoveryImageAttachFailed`: no raw stderr in the user text (I6 convention). Full detail goes in `technicalDetail`.
  - `.installerIncomplete`: name the missing files. Next step: "Run this command again".
  - Add them to the wording and totality checks.

- [ ] **Step 5: Run.** `./scripts/test.sh`. Expected: all pass. Mutations: remove the step-1 existence check (`refusesWhenDestinationAppExists` fails), remove the restore (`restoresInstallESDWhenAssemblyFails` fails), and change move to copy (`assemblesInstallerIntoApplications` fails).

- [ ] **Step 6: Commit.** `feat: assemble legacy Mojave/Catalina installers without root (ported from macUSB)`

---

### Task 7: Wire it into `create`

**Files:**
- Modify: `Sources/macos-installer/CreateCommand.swift` (`execute`, `prepareInstaller`, `duringPayloadKind`), `Sources/MacOSInstallerKit/Guidance/GuidanceCatalog.swift`, `Sources/MacOSInstallerKit/Sources/ReleaseTableFormatter.swift`
- Test: `GuidanceCatalogTests.swift`, `ReleaseTableFormatterTests.swift`

**Interfaces:**
- Consumes: `ReleaseGates.assertBootable`, `RosettaCheck` (Task 3); `AssemblerSet` (Task 4); `LegacyESDAssembler`, `PackageSignatureVerifier` (Tasks 5–6).
- Produces: `GuidanceCatalog.DuringPayloadKind.needsLegacyAssembly`

- [ ] **Step 1: Write the failing tests.**

```swift
@Test("legacy During steps describe three parts, no password until the write")
func legacyDuringSteps() {
    #expect(steps(.needsLegacyAssembly, drive: "SanDisk") == [
        "The installer downloads from Apple in three parts (this is the slow part)",
        "Each part is checked to make sure it arrived intact and is signed by Apple",
        "The installer app is put together from those parts — no password is needed for this step",
        "SanDisk is erased and the installer is written to it — macOS asks for your password here, see the note below",
    ])
}
@Test("Catalina legacy row has no note; High Sierra row says not supported")
func legacyRowNotes() { /* Catalina row ends with its size; High Sierra row ends with "  (not supported — High Sierra and older)" */ }
```

Delete the old "marks a legacyESD-payload release as not supported yet" test, since its premise is gone.

- [ ] **Step 2: Run.** Expected: FAIL.

- [ ] **Step 3: Implement.**
  - In `execute()`, directly after `InstallerPreparer.assertUsable(release)`: `try ReleaseGates.assertBootable(release, on: targetMac)` then `try RosettaCheck(runner: runner).assertCanRunIntelTools(for: release)`. Both run before `enumerateVolumes`.
  - `prepareInstaller` builds `AssemblerSet(installAssistant: InstallAssistantAssembler(runner: runner), legacyESD: LegacyESDAssembler(runner: runner, signatureVerifier: PackageSignatureVerifier(runner: runner)))`.
  - `duringPayloadKind`: `.legacyESD` maps to `.needsLegacyAssembly`. Update the doc comments in `CreateCommand`, `GuidanceCatalog` and `ReleaseTableFormatter` that say legacy never reaches them.

- [ ] **Step 4: Run** `./scripts/test.sh`, then `./scripts/ci.sh`. Expected: all pass, library coverage ≥ 93%. Then `swift run macos-installer list` with no `--volume` and no `create`. Expected: Mojave and Catalina rows carry no "not supported" note, and High Sierra rows do.

- [ ] **Step 5: Commit.** `feat: offer Mojave and Catalina in create`

---

### Task 8: Docs, attribution, release gate

**Files:**
- Modify: `docs/superpowers/specs/2026-09-26-macos-installer-design.md` ("Known Gap", "Verified Facts", the `LegacyESDAssembler` architecture line), `docs/manual-verification.md`, `docs/superpowers/plans/carry-forward.md`, `README.md`, `docs/HANDOFF.md`

- [ ] **Step 1: Spec.** Replace "Known Gap" with "Legacy assembly (verified 2026-10-31)", condensing spike findings 1–8 and crediting macUSB. While editing the spec, fix the two staleness points HANDOFF.md names: the Data Flow order, and the "target Mac must be online" claim.

- [ ] **Step 2: Manual verification.** Append the rows below.
  - **24:** `create` Catalina on this Apple-silicon host with Rosetta installed, then boot the pre-T2 Intel Mac from it (hold Option).
  - **25:** the same for Mojave.
  - **26:** without Rosetta, `create` Catalina refuses before the Before stage with the install command.
  - **27:** while assembly runs, `Install macOS Catalina.app` never appears half-built in `/Applications`. Afterwards `~/Library/Caches/…/legacy-*` is gone and `diskutil list` shows no leftover recovery image.
  - **28:** `create` a *modern* release end to end and confirm the digest check passes on a real download. This is the Task 1 fix; nothing automated can reach it.
  - Rows 24 and 25 together **are** row 14's cross-version claim for Intel targets.

- [ ] **Step 3: Carry-forward.** Add:
  - `LocalInstallerSource` would list an assembled Catalina 10.15.7/19H15 app as 10.15.6/19H11 (spike finding 4), so its `DTPlatformVersion`/`DTSDKBuild` source is wrong for legacy apps. This resolves the "Unverified assumptions" entry in the wrong direction.
  - High Sierra uses the identical layout and is one constant away. It is refused only because the spec's range stops at Mojave and it is untested.
  - The host free-space check is still missing. Peak need on the legacy path ≈ the three parts (5.2–8.3 GB) plus the 0.5 GB recovery copy.
  - `hdiutil`'s "Permission denied" on an external-volume mountpoint was not root-caused, and is why mount points live in `temporaryDirectory`.
  - Remove the "Legacy ESD assembly is unspecified" and "`AssemblyStrategy` is not actually used as a strategy" entries.

- [ ] **Step 4: README.** Writable versions become Mojave 10.14 through macOS 27. Add an "Acknowledgements" line: "Legacy installer assembly is adapted from [macUSB](https://github.com/Kruszoneq/macUSB) by Krystian Pierz (MIT)." Under "Verified on", say plainly that nothing is boot-tested yet.

- [ ] **Step 5: HANDOFF.** Update the branch table (PR #4 `legacy-esd` → `guided-walkthrough`), "What to do next" (Plan 4 done; rows 24–28 added), and the digest finding as a hard-won fact.

- [ ] **Step 6: Commit and open the PR.** `docs: record legacy assembly mechanics, credit macUSB, add release-gate rows 24-28`. Then run `git push -u origin legacy-esd`, which pushes to GitHub and Gitea; confirm both URLs report success. Then `gh pr create --base guided-walkthrough`.
