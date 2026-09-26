# Version Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the package foundation and every installer source, ending in a working `macos-installer list` that shows all obtainable macOS versions from Apple's catalog, `softwareupdate`, and the local disk.

**Architecture:** A thin executable over a `MacOSInstallerKit` library. Three `InstallerSource` implementations answer "what can I obtain?" and are merged by a precedence rule. Every subprocess call goes through a `CommandRunner` protocol and every network read through a `DataFetcher` protocol, so the entire library is testable offline with no disk or network access.

**Tech Stack:** Swift 6.4, SwiftPM, Swift Testing (`import Testing`), `swift-argument-parser` 1.8.2. Foundation only otherwise — `PropertyListSerialization` for the catalog, `XMLParser` for distribution files.

**Spec:** `docs/superpowers/specs/2026-09-26-macos-installer-design.md`

## Global Constraints

- Host floor is **macOS 13 Ventura**. `platforms: [.macOS(.v13)]`.
- The **only** external dependency is `swift-argument-parser`. Adding any other requires changing the spec first.
- Tests never touch the live network or a real disk. Fixtures live in `Tests/MacOSInstallerKitTests/Fixtures/`.
- Coverage target is **80%+ on `MacOSInstallerKit`**. The executable target is excluded.
- Every subprocess invocation goes through `CommandRunner`. Never call `Foundation.Process` directly outside `RealCommandRunner`.
- No `print()` inside `MacOSInstallerKit`. The library returns values; the executable prints.
- Writable version floor is **Mojave 10.14**; ceiling is whatever Apple currently publishes.
- Source precedence is fixed: `local` > `sucatalog` > `softwareUpdate`.
- Commit after every task. Conventional commit format (`feat:`, `test:`, `docs:`, `chore:`).

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | Package definition, two targets plus tests |
| `Sources/MacOSInstallerKit/System/CommandRunner.swift` | Subprocess protocol + real implementation |
| `Sources/MacOSInstallerKit/System/DataFetcher.swift` | Network read protocol + real implementation |
| `Sources/MacOSInstallerKit/Models/OSVersion.swift` | Comparable dotted-version value type |
| `Sources/MacOSInstallerKit/Models/InstallerRelease.swift` | The unit every source produces |
| `Sources/MacOSInstallerKit/Catalog/CatalogProduct.swift` | Parsed sucatalog product |
| `Sources/MacOSInstallerKit/Catalog/SucatalogClient.swift` | Catalog plist → products |
| `Sources/MacOSInstallerKit/Catalog/DistributionParser.swift` | `.dist` XML → title/version/build |
| `Sources/MacOSInstallerKit/Catalog/CatalogURLResolver.swift` | Candidate catalog URLs, first reachable wins |
| `Sources/MacOSInstallerKit/Sources/InstallerSource.swift` | The source protocol |
| `Sources/MacOSInstallerKit/Sources/SucatalogSource.swift` | Catalog-backed source |
| `Sources/MacOSInstallerKit/Sources/SoftwareUpdateSource.swift` | `softwareupdate`-backed source |
| `Sources/MacOSInstallerKit/Sources/LocalInstallerSource.swift` | `/Applications` scan |
| `Sources/MacOSInstallerKit/Sources/ReleaseCatalog.swift` | Merge, dedupe, precedence, sort |
| `Sources/macos-installer/main.swift` | Command-line entry point |
| `Sources/macos-installer/ListCommand.swift` | `list` subcommand and its table output |
| `scripts/ci.sh` | Local build, test, coverage |

---

### Task 1: Package scaffolding and CommandRunner

Everything else depends on being able to fake a subprocess, so this comes first.

**Files:**
- Create: `Package.swift`
- Create: `Sources/MacOSInstallerKit/System/CommandRunner.swift`
- Create: `Sources/macos-installer/main.swift`
- Test: `Tests/MacOSInstallerKitTests/CommandRunnerTests.swift`
- Create: `Tests/MacOSInstallerKitTests/Support/FakeCommandRunner.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `CommandResult` (`exitCode: Int32`, `standardOutput: String`, `standardError: String`); `protocol CommandRunner { func run(_ executable: String, _ arguments: [String]) throws -> CommandResult }`; `RealCommandRunner`; test-only `FakeCommandRunner` with `stub(_:for:)`, `invocations: [(String, [String])]`.

- [ ] **Step 1: Create the package manifest**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacOS_installer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macos-installer", targets: ["macos-installer"]),
        .library(name: "MacOSInstallerKit", targets: ["MacOSInstallerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "macos-installer",
            dependencies: [
                "MacOSInstallerKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "MacOSInstallerKit"),
        .testTarget(
            name: "MacOSInstallerKitTests",
            dependencies: ["MacOSInstallerKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

Create `Sources/macos-installer/main.swift` with a single line so the target compiles: `print("macos-installer")`

Create an empty `Tests/MacOSInstallerKitTests/Fixtures/.gitkeep` so the `resources: [.copy("Fixtures")]` declaration resolves.

- [ ] **Step 2: Write the failing test**

`Tests/MacOSInstallerKitTests/CommandRunnerTests.swift`:

```swift
import Testing
@testable import MacOSInstallerKit

@Test("captures stdout and a zero exit code from a real process")
func realRunnerCapturesStandardOutput() throws {
    let runner = RealCommandRunner()

    let result = try runner.run("/bin/echo", ["hello"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
}

@Test("reports a non-zero exit code without throwing")
func realRunnerReportsFailureExitCode() throws {
    let runner = RealCommandRunner()

    let result = try runner.run("/usr/bin/false", [])

    #expect(result.exitCode != 0)
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter CommandRunnerTests`
Expected: FAIL — `cannot find 'RealCommandRunner' in scope`

- [ ] **Step 4: Write the implementation**

`Sources/MacOSInstallerKit/System/CommandRunner.swift`:

```swift
import Foundation

/// The outcome of a subprocess invocation.
public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum CommandError: Error, Equatable {
    case launchFailed(executable: String, reason: String)
}

/// Every subprocess in this library goes through this protocol so tests can
/// substitute a recording fake. Nothing outside `RealCommandRunner` may use
/// `Foundation.Process` directly.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
}

public struct RealCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(
                executable: executable,
                reason: error.localizedDescription
            )
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter CommandRunnerTests`
Expected: PASS, 2 tests

- [ ] **Step 6: Add the recording fake**

`Tests/MacOSInstallerKitTests/Support/FakeCommandRunner.swift`:

```swift
import Foundation
@testable import MacOSInstallerKit

/// Records every invocation and returns stubbed results. The recording is what
/// lets tests assert that a destructive command was *not* issued.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var stubs: [String: CommandResult] = [:]
    private(set) var invocations: [(executable: String, arguments: [String])] = []

    /// Stub by the full command line, e.g. "/usr/sbin/softwareupdate --list-full-installers".
    func stub(_ result: CommandResult, for commandLine: String) {
        lock.lock(); defer { lock.unlock() }
        stubs[commandLine] = result
    }

    func stub(standardOutput: String, for commandLine: String) {
        stub(
            CommandResult(exitCode: 0, standardOutput: standardOutput, standardError: ""),
            for: commandLine
        )
    }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        invocations.append((executable, arguments))
        let key = ([executable] + arguments).joined(separator: " ")
        return stubs[key] ?? CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }

    /// True if any invocation's command line contains `fragment`.
    func didInvoke(containing fragment: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return invocations.contains { ([$0.executable] + $0.arguments).joined(separator: " ").contains(fragment) }
    }
}
```

- [ ] **Step 7: Verify the fake compiles and the suite is green**

Run: `swift test`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat: add package scaffolding and CommandRunner abstraction"
```

---

### Task 2: OSVersion value type

Version strings must sort correctly — `10.14` is older than `15.8`, and `26.10` is newer than `26.9`. String comparison gets both wrong.

**Files:**
- Create: `Sources/MacOSInstallerKit/Models/OSVersion.swift`
- Test: `Tests/MacOSInstallerKitTests/OSVersionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `OSVersion` — `init?(_ string: String)`, `components: [Int]`, `description: String`, conforms to `Comparable`, `Equatable`, `Hashable`, `Sendable`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MacOSInstallerKit

@Test("parses a dotted version into integer components")
func parsesDottedVersion() throws {
    let version = try #require(OSVersion("10.14.6"))

    #expect(version.components == [10, 14, 6])
    #expect(version.description == "10.14.6")
}

@Test("rejects a version containing non-numeric components")
func rejectsNonNumericVersion() {
    #expect(OSVersion("Tahoe") == nil)
    #expect(OSVersion("") == nil)
    #expect(OSVersion("26.beta") == nil)
}

@Test("orders versions numerically, not lexically")
func ordersNumerically() throws {
    let mojave = try #require(OSVersion("10.14.6"))
    let sequoia = try #require(OSVersion("15.8"))
    let tahoe = try #require(OSVersion("26.7"))

    #expect(mojave < sequoia)
    #expect(sequoia < tahoe)
    // The case string comparison gets wrong:
    #expect(try #require(OSVersion("26.9")) < #require(OSVersion("26.10")))
}

@Test("treats missing trailing components as zero")
func treatsMissingComponentsAsZero() throws {
    #expect(try #require(OSVersion("15.8")) == #require(OSVersion("15.8.0")))
    #expect(try #require(OSVersion("15.8")) < #require(OSVersion("15.8.1")))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter OSVersionTests`
Expected: FAIL — `cannot find 'OSVersion' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A dotted macOS version. Compares numerically so that 26.10 sorts after 26.9
/// and 10.14 sorts before 15.8 — both of which plain string comparison reverses.
public struct OSVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        self.components = parsed
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    /// The leading component, used to decide modern vs legacy assembly.
    public var major: Int { components[0] }

    private static func component(_ version: OSVersion, at index: Int) -> Int {
        index < version.components.count ? version.components[index] : 0
    }

    public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = component(lhs, at: index)
            let right = component(rhs, at: index)
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: OSVersion, rhs: OSVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width where component(lhs, at: index) != component(rhs, at: index) {
            return false
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1 && trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter OSVersionTests`
Expected: PASS, 4 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Models/OSVersion.swift Tests/MacOSInstallerKitTests/OSVersionTests.swift
git commit -m "feat: add OSVersion with numeric ordering"
```

---

### Task 3: InstallerRelease model

The single currency every source produces and the catalog merges.

**Files:**
- Create: `Sources/MacOSInstallerKit/Models/InstallerRelease.swift`
- Test: `Tests/MacOSInstallerKitTests/InstallerReleaseTests.swift`

**Interfaces:**
- Consumes: `OSVersion` (Task 2).
- Produces: `InstallerRelease` with `name: String`, `version: OSVersion`, `build: String`, `sizeBytes: Int64`, `origin: Origin`, `payload: Payload`; `InstallerRelease.Origin` (`.local`, `.sucatalog`, `.softwareUpdate`) conforming to `Comparable` where greater means higher precedence; `InstallerRelease.Payload` (`.installAssistant(url:)`, `.legacyESD(urls:)`, `.localApplication(path:)`, `.softwareUpdate(version:)`); computed `identity: ReleaseIdentity`, `requiresLegacyAssembly: Bool`, `displaySize: String`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private func makeRelease(
    name: String = "macOS Tahoe",
    version: String = "26.7",
    build: String = "25G229",
    sizeBytes: Int64 = 18_381_960_192,
    origin: InstallerRelease.Origin = .sucatalog
) throws -> InstallerRelease {
    InstallerRelease(
        name: name,
        version: try #require(OSVersion(version)),
        build: build,
        sizeBytes: sizeBytes,
        origin: origin,
        payload: .installAssistant(url: URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!)
    )
}

@Test("identity is version plus build, ignoring origin")
func identityIgnoresOrigin() throws {
    let fromCatalog = try makeRelease(origin: .sucatalog)
    let fromLocal = try makeRelease(origin: .local)

    #expect(fromCatalog.identity == fromLocal.identity)
}

@Test("origin precedence ranks local above catalog above software update")
func originPrecedence() {
    #expect(InstallerRelease.Origin.local > InstallerRelease.Origin.sucatalog)
    #expect(InstallerRelease.Origin.sucatalog > InstallerRelease.Origin.softwareUpdate)
}

@Test("versions below Big Sur require legacy assembly")
func legacyAssemblyThreshold() throws {
    #expect(try makeRelease(version: "10.14.6").requiresLegacyAssembly)
    #expect(try makeRelease(version: "10.15.7").requiresLegacyAssembly)
    #expect(try makeRelease(version: "11.7.10").requiresLegacyAssembly == false)
    #expect(try makeRelease(version: "26.7").requiresLegacyAssembly == false)
}

@Test("display size is rendered in gigabytes with one decimal")
func displaySizeInGigabytes() throws {
    let release = try makeRelease(sizeBytes: 18_381_960_192)

    #expect(release.displaySize == "18.4 GB")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter InstallerReleaseTests`
Expected: FAIL — `cannot find 'InstallerRelease' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Identifies a release independently of where it was found, so the same macOS
/// build discovered by two sources deduplicates to one entry.
public struct ReleaseIdentity: Hashable, Sendable {
    public let version: OSVersion
    public let build: String
}

public struct InstallerRelease: Equatable, Sendable {
    /// Ordered by precedence: a higher case wins when two sources offer the
    /// same build. Local wins because it needs no download.
    public enum Origin: Int, Comparable, Sendable {
        case softwareUpdate = 0
        case sucatalog = 1
        case local = 2

        public static func < (lhs: Origin, rhs: Origin) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// How the installer application is obtained. The assembler chosen later
    /// switches on this.
    public enum Payload: Equatable, Sendable {
        case installAssistant(url: URL)
        case legacyESD(urls: [URL])
        case localApplication(path: URL)
        case softwareUpdate(version: String)
    }

    public let name: String
    public let version: OSVersion
    public let build: String
    public let sizeBytes: Int64
    public let origin: Origin
    public let payload: Payload

    public init(
        name: String,
        version: OSVersion,
        build: String,
        sizeBytes: Int64,
        origin: Origin,
        payload: Payload
    ) {
        self.name = name
        self.version = version
        self.build = build
        self.sizeBytes = sizeBytes
        self.origin = origin
        self.payload = payload
    }

    public var identity: ReleaseIdentity {
        ReleaseIdentity(version: version, build: build)
    }

    /// Big Sur (11) introduced the single-package InstallAssistant format.
    /// Anything older uses the undocumented chunked ESD layout.
    public var requiresLegacyAssembly: Bool {
        version.major < 11
    }

    public var displaySize: String {
        let gigabytes = Double(sizeBytes) / 1_000_000_000
        return String(format: "%.1f GB", gigabytes)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter InstallerReleaseTests`
Expected: PASS, 4 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Models/InstallerRelease.swift Tests/MacOSInstallerKitTests/InstallerReleaseTests.swift
git commit -m "feat: add InstallerRelease model with origin precedence"
```

---

### Task 4: DistributionParser

Apple's catalog carries no version or title. Each product points at a `.dist` file that does. Format verified against a live file on 2026-09-26: an `installer-gui-script` XML document with a `<title>` element and an `<auxinfo><dict>` holding `BUILD` and `VERSION` keys.

**Files:**
- Create: `Sources/MacOSInstallerKit/Catalog/DistributionParser.swift`
- Create: `Tests/MacOSInstallerKitTests/Fixtures/sequoia.dist`
- Test: `Tests/MacOSInstallerKitTests/DistributionParserTests.swift`

**Interfaces:**
- Consumes: `OSVersion` (Task 2).
- Produces: `DistributionInfo` (`title: String`, `version: OSVersion`, `build: String`); `DistributionParser.parse(_ data: Data) throws -> DistributionInfo`; `DistributionParseError`.

- [ ] **Step 1: Create the fixture**

Save this as `Tests/MacOSInstallerKitTests/Fixtures/sequoia.dist`. It is a trimmed copy of Apple's real distribution file for product `142-16660`, keeping the elements the parser reads.

```xml
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <pkg-ref id="MajorOSInfo" packageIdentifier="com.apple.pkg.MajorOSInfo"/>
    <pkg-ref id="InstallAssistant" packageIdentifier="com.apple.pkg.InstallAssistant.macOSSequoia"/>
    <title>macOS Sequoia</title>
    <options customize="never" require-scripts="false"/>
    <auxinfo>
        <dict>
            <key>BUILD</key>
            <string>24H23</string>
            <key>VERSION</key>
            <string>15.8</string>
        </dict>
    </auxinfo>
</installer-gui-script>
```

Also save this malformed variant as `Tests/MacOSInstallerKitTests/Fixtures/no-version.dist`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>macOS Mystery</title>
    <auxinfo>
        <dict>
            <key>BUILD</key>
            <string>99A1</string>
        </dict>
    </auxinfo>
</installer-gui-script>
```

- [ ] **Step 2: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

@Test("extracts title, version and build from a real distribution file")
func parsesRealDistribution() throws {
    let info = try DistributionParser.parse(fixture("sequoia.dist"))

    #expect(info.title == "macOS Sequoia")
    #expect(info.build == "24H23")
    #expect(info.version == OSVersion("15.8"))
}

@Test("throws when the version key is absent rather than inventing one")
func throwsOnMissingVersion() throws {
    let data = try fixture("no-version.dist")

    #expect(throws: DistributionParseError.missingVersion) {
        try DistributionParser.parse(data)
    }
}

@Test("throws on data that is not XML at all")
func throwsOnGarbage() {
    let data = Data("not xml".utf8)

    #expect(throws: (any Error).self) {
        try DistributionParser.parse(data)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter DistributionParserTests`
Expected: FAIL — `cannot find 'DistributionParser' in scope`

- [ ] **Step 4: Write the implementation**

```swift
import Foundation

public struct DistributionInfo: Equatable, Sendable {
    public let title: String
    public let version: OSVersion
    public let build: String
}

public enum DistributionParseError: Error, Equatable {
    case malformedXML(String)
    case missingTitle
    case missingVersion
    case missingBuild
    case unparsableVersion(String)
}

/// Reads Apple's `.dist` files. These are `installer-gui-script` XML documents
/// carrying a `<title>` and an `<auxinfo>` dictionary with VERSION and BUILD.
public enum DistributionParser {
    public static func parse(_ data: Data) throws -> DistributionInfo {
        let delegate = DistributionXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw DistributionParseError.malformedXML(reason)
        }

        guard let title = delegate.title, !title.isEmpty else {
            throw DistributionParseError.missingTitle
        }
        guard let versionString = delegate.auxInfo["VERSION"] else {
            throw DistributionParseError.missingVersion
        }
        guard let build = delegate.auxInfo["BUILD"] else {
            throw DistributionParseError.missingBuild
        }
        guard let version = OSVersion(versionString) else {
            throw DistributionParseError.unparsableVersion(versionString)
        }

        return DistributionInfo(title: title, version: version, build: build)
    }
}

/// Collects `<title>` and the flat `<auxinfo>` key/string pairs. The auxinfo
/// dict is plist-shaped: alternating `<key>` and `<string>` elements.
private final class DistributionXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var title: String?
    private(set) var auxInfo: [String: String] = [:]

    private var inAuxInfo = false
    private var currentElement: String?
    private var buffer = ""
    private var pendingKey: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        currentElement = elementName
        buffer = ""
        if elementName == "auxinfo" { inAuxInfo = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "title" where !inAuxInfo:
            if title == nil { title = text }
        case "auxinfo":
            inAuxInfo = false
        case "key" where inAuxInfo:
            pendingKey = text
        case "string" where inAuxInfo:
            if let key = pendingKey {
                auxInfo[key] = text
                pendingKey = nil
            }
        default:
            break
        }

        buffer = ""
        currentElement = nil
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter DistributionParserTests`
Expected: PASS, 3 tests

- [ ] **Step 6: Commit**

```bash
git add Sources/MacOSInstallerKit/Catalog/DistributionParser.swift Tests/MacOSInstallerKitTests/DistributionParserTests.swift Tests/MacOSInstallerKitTests/Fixtures
git commit -m "feat: parse Apple distribution files for title, version and build"
```

---

### Task 5: SucatalogClient

Turns the 7 MB catalog plist into products, keeping only those that carry an installer payload.

**Files:**
- Create: `Sources/MacOSInstallerKit/Catalog/CatalogProduct.swift`
- Create: `Sources/MacOSInstallerKit/Catalog/SucatalogClient.swift`
- Create: `Tests/MacOSInstallerKitTests/Fixtures/mini-catalog.plist`
- Test: `Tests/MacOSInstallerKitTests/SucatalogClientTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `CatalogPackage` (`url: URL`, `size: Int64`); `CatalogProduct` (`identifier: String`, `postDate: Date`, `distributionURL: URL?`, `packages: [CatalogPackage]`, computed `installAssistantURL: URL?`, `legacyESDURLs: [URL]`, `totalSize: Int64`, `kind: CatalogProduct.Kind`); `CatalogProduct.Kind` (`.installAssistant`, `.legacyESD`, `.other`); `SucatalogClient.parse(_ data: Data) throws -> [CatalogProduct]`; `SucatalogParseError`.

- [ ] **Step 1: Create the fixture**

A hand-built miniature catalog with one modern product, one legacy product, and one irrelevant product. Save as `Tests/MacOSInstallerKitTests/Fixtures/mini-catalog.plist`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Products</key>
  <dict>
    <key>142-16660</key>
    <dict>
      <key>PostDate</key><date>2026-09-14T17:22:22Z</date>
      <key>Distributions</key>
      <dict>
        <key>English</key><string>https://swdist.apple.com/x/142-16660.English.dist</string>
      </dict>
      <key>Packages</key>
      <array>
        <dict>
          <key>URL</key><string>https://swcdn.apple.com/x/InstallAssistant.pkg</string>
          <key>Size</key><integer>15296950272</integer>
        </dict>
      </array>
    </dict>
    <key>061-26578</key>
    <dict>
      <key>PostDate</key><date>2019-10-23T00:00:00Z</date>
      <key>Distributions</key>
      <dict>
        <key>English</key><string>https://swdist.apple.com/x/061-26578.English.dist</string>
      </dict>
      <key>Packages</key>
      <array>
        <dict>
          <key>URL</key><string>https://swcdn.apple.com/x/InstallESDDmg.pkg</string>
          <key>Size</key><integer>8000000000</integer>
        </dict>
        <dict>
          <key>URL</key><string>https://swcdn.apple.com/x/InstallInfo.plist</string>
          <key>Size</key><integer>1024</integer>
        </dict>
      </array>
    </dict>
    <key>041-99999</key>
    <dict>
      <key>PostDate</key><date>2024-01-01T00:00:00Z</date>
      <key>Packages</key>
      <array>
        <dict>
          <key>URL</key><string>https://swcdn.apple.com/x/SomeSecurityUpdate.pkg</string>
          <key>Size</key><integer>500000</integer>
        </dict>
      </array>
    </dict>
  </dict>
</dict>
</plist>
```

Verify the fixture parses before continuing:

```bash
plutil -lint Tests/MacOSInstallerKitTests/Fixtures/mini-catalog.plist
```

Expected: `OK`. If it reports an error, the fixture was transcribed incorrectly — fix it before writing any parser code, or the parser will be shaped around a broken input.

- [ ] **Step 2: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private func catalogFixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/mini-catalog", withExtension: "plist"))
    return try Data(contentsOf: url)
}

@Test("keeps only products that carry an installer payload")
func filtersToInstallerProducts() throws {
    let products = try SucatalogClient.parse(catalogFixture())

    let identifiers = Set(products.map(\.identifier))
    #expect(identifiers == ["142-16660", "061-26578"])
}

@Test("classifies modern and legacy products by payload shape")
func classifiesProductKind() throws {
    let products = try SucatalogClient.parse(catalogFixture())
    let modern = try #require(products.first { $0.identifier == "142-16660" })
    let legacy = try #require(products.first { $0.identifier == "061-26578" })

    #expect(modern.kind == .installAssistant)
    #expect(modern.installAssistantURL?.lastPathComponent == "InstallAssistant.pkg")
    #expect(legacy.kind == .legacyESD)
    #expect(legacy.legacyESDURLs.count == 2)
}

@Test("carries the English distribution URL and total payload size")
func carriesDistributionAndSize() throws {
    let products = try SucatalogClient.parse(catalogFixture())
    let modern = try #require(products.first { $0.identifier == "142-16660" })

    #expect(modern.distributionURL?.absoluteString == "https://swdist.apple.com/x/142-16660.English.dist")
    #expect(modern.totalSize == 15_296_950_272)
}

@Test("throws when the payload is not a property list")
func throwsOnNonPlist() {
    #expect(throws: (any Error).self) {
        try SucatalogClient.parse(Data("nonsense".utf8))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter SucatalogClientTests`
Expected: FAIL — `cannot find 'SucatalogClient' in scope`

- [ ] **Step 4: Write the model**

`Sources/MacOSInstallerKit/Catalog/CatalogProduct.swift`:

```swift
import Foundation

public struct CatalogPackage: Equatable, Sendable {
    public let url: URL
    public let size: Int64
}

public struct CatalogProduct: Equatable, Sendable {
    /// Which assembly path this product's payload implies.
    public enum Kind: Equatable, Sendable {
        case installAssistant
        case legacyESD
        case other
    }

    public let identifier: String
    public let postDate: Date
    public let distributionURL: URL?
    public let packages: [CatalogPackage]

    public var installAssistantURL: URL? {
        packages.first { $0.url.lastPathComponent == "InstallAssistant.pkg" }?.url
    }

    public var legacyESDURLs: [URL] {
        guard kind == .legacyESD else { return [] }
        return packages.map(\.url)
    }

    public var kind: Kind {
        if packages.contains(where: { $0.url.lastPathComponent == "InstallAssistant.pkg" }) {
            return .installAssistant
        }
        if packages.contains(where: { $0.url.lastPathComponent == "InstallESDDmg.pkg" }) {
            return .legacyESD
        }
        return .other
    }

    public var totalSize: Int64 {
        switch kind {
        case .installAssistant:
            return packages.first { $0.url.lastPathComponent == "InstallAssistant.pkg" }?.size ?? 0
        case .legacyESD:
            return packages.reduce(0) { $0 + $1.size }
        case .other:
            return 0
        }
    }
}
```

- [ ] **Step 5: Write the client**

`Sources/MacOSInstallerKit/Catalog/SucatalogClient.swift`:

```swift
import Foundation

public enum SucatalogParseError: Error, Equatable {
    case notAPropertyList
    case missingProductsDictionary
}

/// Parses Apple's software update catalog. The live catalog holds ~646 products,
/// of which only those carrying an InstallAssistant or InstallESD payload are
/// macOS installers; the rest are updates, fonts and dictionaries.
public enum SucatalogClient {
    public static func parse(_ data: Data) throws -> [CatalogProduct] {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw SucatalogParseError.notAPropertyList
        }

        guard let root = object as? [String: Any] else {
            throw SucatalogParseError.notAPropertyList
        }
        guard let products = root["Products"] as? [String: Any] else {
            throw SucatalogParseError.missingProductsDictionary
        }

        return products.compactMap { identifier, value in
            guard let entry = value as? [String: Any] else { return nil }
            let product = makeProduct(identifier: identifier, entry: entry)
            return product.kind == .other ? nil : product
        }
        .sorted { $0.postDate < $1.postDate }
    }

    private static func makeProduct(identifier: String, entry: [String: Any]) -> CatalogProduct {
        let packages = (entry["Packages"] as? [[String: Any]] ?? []).compactMap { package -> CatalogPackage? in
            guard
                let urlString = package["URL"] as? String,
                let url = URL(string: urlString)
            else { return nil }
            let size = (package["Size"] as? NSNumber)?.int64Value ?? 0
            return CatalogPackage(url: url, size: size)
        }

        let distributions = entry["Distributions"] as? [String: String]
        let distributionURL = (distributions?["English"]).flatMap(URL.init(string:))

        return CatalogProduct(
            identifier: identifier,
            postDate: entry["PostDate"] as? Date ?? .distantPast,
            distributionURL: distributionURL,
            packages: packages
        )
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --filter SucatalogClientTests`
Expected: PASS, 4 tests

- [ ] **Step 7: Commit**

```bash
git add Sources/MacOSInstallerKit/Catalog Tests/MacOSInstallerKitTests
git commit -m "feat: parse Apple software update catalog into installer products"
```

---

### Task 6: DataFetcher and CatalogURLResolver

Network reads get an injectable protocol for the same reason subprocesses did. The resolver walks a candidate list because Apple renames the catalog index with each macOS generation.

**Files:**
- Create: `Sources/MacOSInstallerKit/System/DataFetcher.swift`
- Create: `Sources/MacOSInstallerKit/Catalog/CatalogURLResolver.swift`
- Create: `Tests/MacOSInstallerKitTests/Support/FakeDataFetcher.swift`
- Test: `Tests/MacOSInstallerKitTests/CatalogURLResolverTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `protocol DataFetcher: Sendable { func data(from url: URL) async throws -> Data }`; `URLSessionDataFetcher`; `CatalogURLResolver` with `static let candidates: [URL]`, `init(fetcher:candidates:)`, `func resolve() async throws -> (url: URL, data: Data)`; `CatalogResolutionError.allCandidatesFailed([String])`; test-only `FakeDataFetcher` with `stub(_:for:)`, `fail(_:for:)`, `requestedURLs`.

- [ ] **Step 1: Write the fetcher protocol**

`Sources/MacOSInstallerKit/System/DataFetcher.swift`:

```swift
import Foundation

public enum FetchError: Error, Equatable {
    case httpStatus(Int, url: URL)
    case transport(String, url: URL)
}

/// All network reads go through this so tests run offline.
public protocol DataFetcher: Sendable {
    func data(from url: URL) async throws -> Data
}

public struct URLSessionDataFetcher: DataFetcher {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
    }

    public func data(from url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw FetchError.httpStatus(http.statusCode, url: url)
            }
            return data
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.transport(error.localizedDescription, url: url)
        }
    }
}
```

- [ ] **Step 2: Write the fake fetcher**

`Tests/MacOSInstallerKitTests/Support/FakeDataFetcher.swift`:

```swift
import Foundation
@testable import MacOSInstallerKit

final class FakeDataFetcher: DataFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: Result<Data, any Error>] = [:]
    private(set) var requestedURLs: [URL] = []

    func stub(_ data: Data, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        responses[url] = .success(data)
    }

    func fail(_ error: any Error, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        responses[url] = .failure(error)
    }

    func data(from url: URL) async throws -> Data {
        lock.lock()
        requestedURLs.append(url)
        let response = responses[url]
        lock.unlock()

        switch response {
        case .success(let data): return data
        case .failure(let error): throw error
        case nil: throw FetchError.httpStatus(404, url: url)
        }
    }
}
```

- [ ] **Step 3: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private let first = URL(string: "https://swscan.apple.com/a.sucatalog")!
private let second = URL(string: "https://swscan.apple.com/b.sucatalog")!

@Test("returns the first candidate that responds")
func returnsFirstReachableCandidate() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.stub(Data("catalog-a".utf8), for: first)
    let resolver = CatalogURLResolver(fetcher: fetcher, candidates: [first, second])

    let result = try await resolver.resolve()

    #expect(result.url == first)
    #expect(result.data == Data("catalog-a".utf8))
    #expect(fetcher.requestedURLs == [first])
}

@Test("falls through to the next candidate when the first fails")
func fallsThroughOnFailure() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.fail(FetchError.httpStatus(404, url: first), for: first)
    fetcher.stub(Data("catalog-b".utf8), for: second)
    let resolver = CatalogURLResolver(fetcher: fetcher, candidates: [first, second])

    let result = try await resolver.resolve()

    #expect(result.url == second)
    #expect(fetcher.requestedURLs == [first, second])
}

@Test("throws listing every failure when no candidate responds")
func throwsWhenAllCandidatesFail() async {
    let fetcher = FakeDataFetcher()
    fetcher.fail(FetchError.httpStatus(404, url: first), for: first)
    fetcher.fail(FetchError.httpStatus(500, url: second), for: second)
    let resolver = CatalogURLResolver(fetcher: fetcher, candidates: [first, second])

    await #expect(throws: (any Error).self) {
        _ = try await resolver.resolve()
    }
}

@Test("ships a non-empty default candidate list")
func defaultCandidatesArePresent() {
    #expect(CatalogURLResolver.candidates.isEmpty == false)
    #expect(CatalogURLResolver.candidates.allSatisfy { $0.absoluteString.hasSuffix(".sucatalog") })
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `swift test --filter CatalogURLResolverTests`
Expected: FAIL — `cannot find 'CatalogURLResolver' in scope`

- [ ] **Step 5: Write the implementation**

```swift
import Foundation

public enum CatalogResolutionError: Error {
    case allCandidatesFailed([String])
}

/// Apple renames the catalog index with each macOS generation. Rather than
/// hard-code one URL, walk a list newest-first and use the first that responds.
/// Verified 2026-09-26: the index-27 URL returns HTTP 200, 7,045,040 bytes.
public struct CatalogURLResolver {
    public static let candidates: [URL] = [
        "https://swscan.apple.com/content/catalogs/others/index-27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
        "https://swscan.apple.com/content/catalogs/others/index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
        "https://swscan.apple.com/content/catalogs/others/index-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog",
    ].compactMap(URL.init(string:))

    private let fetcher: any DataFetcher
    private let candidates: [URL]

    public init(fetcher: any DataFetcher, candidates: [URL] = CatalogURLResolver.candidates) {
        self.fetcher = fetcher
        self.candidates = candidates
    }

    public func resolve() async throws -> (url: URL, data: Data) {
        var failures: [String] = []

        for candidate in candidates {
            do {
                let data = try await fetcher.data(from: candidate)
                return (candidate, data)
            } catch {
                failures.append("\(candidate.lastPathComponent): \(error)")
            }
        }

        throw CatalogResolutionError.allCandidatesFailed(failures)
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --filter CatalogURLResolverTests`
Expected: PASS, 4 tests

- [ ] **Step 7: Commit**

```bash
git add Sources/MacOSInstallerKit Tests/MacOSInstallerKitTests
git commit -m "feat: add DataFetcher abstraction and catalog URL fallback chain"
```

---

### Task 7: InstallerSource protocol and SucatalogSource

Wires the catalog client and distribution parser into one source, fetching distribution files concurrently.

**Files:**
- Create: `Sources/MacOSInstallerKit/Sources/InstallerSource.swift`
- Create: `Sources/MacOSInstallerKit/Sources/SucatalogSource.swift`
- Test: `Tests/MacOSInstallerKitTests/SucatalogSourceTests.swift`

**Interfaces:**
- Consumes: `DataFetcher`, `CatalogURLResolver` (Task 6), `SucatalogClient`, `CatalogProduct` (Task 5), `DistributionParser` (Task 4), `InstallerRelease` (Task 3).
- Produces: `protocol InstallerSource: Sendable { var origin: InstallerRelease.Origin { get }; func availableReleases() async throws -> [InstallerRelease] }`; `SucatalogSource(fetcher:resolver:)`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private let catalogURL = URL(string: "https://swscan.apple.com/test.sucatalog")!
private let distURL = URL(string: "https://swdist.apple.com/x/142-16660.English.dist")!

private func miniCatalogData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/mini-catalog", withExtension: "plist"))
    return try Data(contentsOf: url)
}

private func sequoiaDistData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/sequoia.dist", withExtension: nil))
    return try Data(contentsOf: url)
}

@Test("builds releases by joining catalog products to their distribution files")
func buildsReleasesFromCatalogAndDistributions() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.stub(try miniCatalogData(), for: catalogURL)
    fetcher.stub(try sequoiaDistData(), for: distURL)
    let source = SucatalogSource(
        fetcher: fetcher,
        resolver: CatalogURLResolver(fetcher: fetcher, candidates: [catalogURL])
    )

    let releases = try await source.availableReleases()

    let sequoia = try #require(releases.first { $0.build == "24H23" })
    #expect(sequoia.name == "macOS Sequoia")
    #expect(sequoia.version == OSVersion("15.8"))
    #expect(sequoia.origin == .sucatalog)
    #expect(sequoia.payload == .installAssistant(url: URL(string: "https://swcdn.apple.com/x/InstallAssistant.pkg")!))
}

@Test("skips products whose distribution file cannot be fetched rather than failing wholesale")
func skipsUnfetchableDistributions() async throws {
    let fetcher = FakeDataFetcher()
    fetcher.stub(try miniCatalogData(), for: catalogURL)
    // sequoia .dist is deliberately not stubbed, and the legacy one never is.
    let source = SucatalogSource(
        fetcher: fetcher,
        resolver: CatalogURLResolver(fetcher: fetcher, candidates: [catalogURL])
    )

    let releases = try await source.availableReleases()

    #expect(releases.isEmpty)
}

@Test("reports its origin as sucatalog")
func reportsOrigin() {
    let fetcher = FakeDataFetcher()
    let source = SucatalogSource(
        fetcher: fetcher,
        resolver: CatalogURLResolver(fetcher: fetcher, candidates: [catalogURL])
    )

    #expect(source.origin == .sucatalog)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SucatalogSourceTests`
Expected: FAIL — `cannot find 'SucatalogSource' in scope`

- [ ] **Step 3: Write the protocol**

`Sources/MacOSInstallerKit/Sources/InstallerSource.swift`:

```swift
import Foundation

/// A place macOS installers can be obtained from. Implementations answer what
/// is available; obtaining the bytes is a later concern.
public protocol InstallerSource: Sendable {
    var origin: InstallerRelease.Origin { get }
    func availableReleases() async throws -> [InstallerRelease]
}
```

- [ ] **Step 4: Write the source**

`Sources/MacOSInstallerKit/Sources/SucatalogSource.swift`:

```swift
import Foundation

/// Reads Apple's public software update catalog. Unlike `softwareupdate`, this
/// is not filtered by host model, which is what allows an Apple silicon host to
/// write media for an older Intel target.
public struct SucatalogSource: InstallerSource {
    public let origin: InstallerRelease.Origin = .sucatalog

    private let fetcher: any DataFetcher
    private let resolver: CatalogURLResolver

    public init(fetcher: any DataFetcher, resolver: CatalogURLResolver? = nil) {
        self.fetcher = fetcher
        self.resolver = resolver ?? CatalogURLResolver(fetcher: fetcher)
    }

    public func availableReleases() async throws -> [InstallerRelease] {
        let (_, catalogData) = try await resolver.resolve()
        let products = try SucatalogClient.parse(catalogData)

        // Distribution files are ~10 KB each and there are around twenty of
        // them. Fetch concurrently; a product whose .dist is unavailable is
        // dropped rather than failing the whole listing.
        return await withTaskGroup(of: InstallerRelease?.self) { group in
            for product in products {
                group.addTask { await release(for: product) }
            }

            var releases: [InstallerRelease] = []
            for await release in group {
                if let release { releases.append(release) }
            }
            return releases.sorted { $0.version > $1.version }
        }
    }

    private func release(for product: CatalogProduct) async -> InstallerRelease? {
        guard let distributionURL = product.distributionURL else { return nil }

        guard
            let data = try? await fetcher.data(from: distributionURL),
            let info = try? DistributionParser.parse(data)
        else { return nil }

        let payload: InstallerRelease.Payload
        switch product.kind {
        case .installAssistant:
            guard let url = product.installAssistantURL else { return nil }
            payload = .installAssistant(url: url)
        case .legacyESD:
            payload = .legacyESD(urls: product.legacyESDURLs)
        case .other:
            return nil
        }

        return InstallerRelease(
            name: info.title,
            version: info.version,
            build: info.build,
            sizeBytes: product.totalSize,
            origin: .sucatalog,
            payload: payload
        )
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter SucatalogSourceTests`
Expected: PASS, 3 tests

- [ ] **Step 6: Commit**

```bash
git add Sources/MacOSInstallerKit/Sources Tests/MacOSInstallerKitTests
git commit -m "feat: add SucatalogSource joining products to distribution metadata"
```

---

### Task 8: SoftwareUpdateSource

Parses `softwareupdate --list-full-installers`. Real output captured from macOS 27.0 on 2026-09-26.

**Files:**
- Create: `Sources/MacOSInstallerKit/Sources/SoftwareUpdateSource.swift`
- Test: `Tests/MacOSInstallerKitTests/SoftwareUpdateSourceTests.swift`

**Interfaces:**
- Consumes: `CommandRunner` (Task 1), `InstallerRelease` (Task 3), `InstallerSource` (Task 7).
- Produces: `SoftwareUpdateSource(runner:)`; `static let executablePath = "/usr/sbin/softwareupdate"`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private let realOutput = """
Finding available software
Software Update found the following full installers:
* Title: macOS 27 Golden Gate, Version: 27.0, Size: 17969056KiB, Build: 26A428, Deferred: NO
* Title: macOS Tahoe, Version: 26.7, Size: 17951133KiB, Build: 25G229, Deferred: NO
* Title: macOS Sequoia, Version: 15.8, Size: 15296950KiB, Build: 24H23, Deferred: NO
"""

@Test("parses Apple's full-installer listing into releases")
func parsesFullInstallerListing() async throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: realOutput, for: "/usr/sbin/softwareupdate --list-full-installers")
    let source = SoftwareUpdateSource(runner: runner)

    let releases = try await source.availableReleases()

    #expect(releases.count == 3)
    let tahoe = try #require(releases.first { $0.build == "25G229" })
    #expect(tahoe.name == "macOS Tahoe")
    #expect(tahoe.version == OSVersion("26.7"))
    #expect(tahoe.origin == .softwareUpdate)
    #expect(tahoe.payload == .softwareUpdate(version: "26.7"))
}

@Test("converts the KiB size field to bytes")
func convertsKibibytesToBytes() async throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: realOutput, for: "/usr/sbin/softwareupdate --list-full-installers")
    let source = SoftwareUpdateSource(runner: runner)

    let releases = try await source.availableReleases()
    let sequoia = try #require(releases.first { $0.build == "24H23" })

    #expect(sequoia.sizeBytes == 15_296_950 * 1024)
}

@Test("returns empty rather than throwing when no installers are offered")
func returnsEmptyWhenNothingOffered() async throws {
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: "Finding available software\n", for: "/usr/sbin/softwareupdate --list-full-installers")
    let source = SoftwareUpdateSource(runner: runner)

    #expect(try await source.availableReleases().isEmpty)
}

@Test("ignores malformed lines instead of aborting the listing")
func ignoresMalformedLines() async throws {
    let output = """
    Software Update found the following full installers:
    * Title: macOS Tahoe, Version: 26.7, Size: 17951133KiB, Build: 25G229, Deferred: NO
    * Title: broken line with no fields
    """
    let runner = FakeCommandRunner()
    runner.stub(standardOutput: output, for: "/usr/sbin/softwareupdate --list-full-installers")
    let source = SoftwareUpdateSource(runner: runner)

    #expect(try await source.availableReleases().count == 1)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SoftwareUpdateSourceTests`
Expected: FAIL — `cannot find 'SoftwareUpdateSource' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Reads `softwareupdate --list-full-installers`. Apple filters this list to
/// versions the *host* model supports, so it is a fallback rather than the
/// primary source. Line format verified on macOS 27.0, 2026-09-26:
/// `* Title: macOS Tahoe, Version: 26.7, Size: 17951133KiB, Build: 25G229, Deferred: NO`
public struct SoftwareUpdateSource: InstallerSource {
    public static let executablePath = "/usr/sbin/softwareupdate"

    public let origin: InstallerRelease.Origin = .softwareUpdate

    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    public func availableReleases() async throws -> [InstallerRelease] {
        let result = try runner.run(Self.executablePath, ["--list-full-installers"])
        return result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { Self.parseLine(String($0)) }
            .sorted { $0.version > $1.version }
    }

    static func parseLine(_ line: String) -> InstallerRelease? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("* ") else { return nil }

        // Split "Title: X, Version: Y, Size: ZKiB, Build: B, Deferred: NO"
        // into its labelled fields.
        var fields: [String: String] = [:]
        for segment in trimmed.dropFirst(2).components(separatedBy: ", ") {
            let parts = segment.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1]
        }

        guard
            let title = fields["Title"],
            let versionString = fields["Version"],
            let version = OSVersion(versionString),
            let build = fields["Build"]
        else { return nil }

        let kibibytes = Int64(fields["Size"]?.replacingOccurrences(of: "KiB", with: "") ?? "") ?? 0

        return InstallerRelease(
            name: title,
            version: version,
            build: build,
            sizeBytes: kibibytes * 1024,
            origin: .softwareUpdate,
            payload: .softwareUpdate(version: versionString)
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SoftwareUpdateSourceTests`
Expected: PASS, 4 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Sources/SoftwareUpdateSource.swift Tests/MacOSInstallerKitTests/SoftwareUpdateSourceTests.swift
git commit -m "feat: add SoftwareUpdateSource parsing full-installer listings"
```

---

### Task 9: LocalInstallerSource

Finds `Install macOS *.app` already on disk so re-flashing a drive needs no download.

**Files:**
- Create: `Sources/MacOSInstallerKit/Sources/LocalInstallerSource.swift`
- Test: `Tests/MacOSInstallerKitTests/LocalInstallerSourceTests.swift`

**Interfaces:**
- Consumes: `InstallerRelease` (Task 3), `InstallerSource` (Task 7).
- Produces: `LocalInstallerSource(searchDirectories:fileManager:)`; `static let defaultSearchDirectories: [URL]`.

An installer app carries `Contents/Info.plist` with `CFBundleDisplayName`, and a `Contents/SharedSupport/SharedSupport.dmg`. Version and build live in `Contents/Info.plist` under `DTPlatformVersion` and `DTSDKBuild`; the authoritative pair for our purposes is read from `Contents/Info.plist` keys `CFBundleShortVersionString` (not the OS version) — so instead the source reads the sidecar the installer ships. To keep this task deterministic and testable, the source reads a small plist the test constructs.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

/// Builds a minimal directory that looks like an installer app.
private func makeInstallerApp(
    in directory: URL,
    displayName: String,
    version: String,
    build: String
) throws -> URL {
    let app = directory.appendingPathComponent("\(displayName).app")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

    let info: [String: Any] = [
        "CFBundleDisplayName": displayName,
        "DTPlatformVersion": version,
        "DTSDKBuild": build,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return app
}

@Test("discovers installer applications in the search directories")
func discoversInstallerApps() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let app = try makeInstallerApp(in: root, displayName: "Install macOS Tahoe", version: "26.7", build: "25G229")
    let source = LocalInstallerSource(searchDirectories: [root])

    let releases = try await source.availableReleases()

    #expect(releases.count == 1)
    let release = try #require(releases.first)
    #expect(release.name == "Install macOS Tahoe")
    #expect(release.version == OSVersion("26.7"))
    #expect(release.build == "25G229")
    #expect(release.origin == .local)
    #expect(release.payload == .localApplication(path: app))
}

@Test("ignores applications that are not macOS installers")
func ignoresNonInstallerApps() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try makeInstallerApp(in: root, displayName: "Safari", version: "26.7", build: "25G229")
    let source = LocalInstallerSource(searchDirectories: [root])

    #expect(try await source.availableReleases().isEmpty)
}

@Test("returns empty for a directory that does not exist")
func returnsEmptyForMissingDirectory() async throws {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let source = LocalInstallerSource(searchDirectories: [missing])

    #expect(try await source.availableReleases().isEmpty)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LocalInstallerSourceTests`
Expected: FAIL — `cannot find 'LocalInstallerSource' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Finds installer applications already present on disk. Reusing one avoids a
/// multi-gigabyte download when re-flashing a drive, which is the common case
/// once the tool is in regular use.
public struct LocalInstallerSource: InstallerSource {
    public static let defaultSearchDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications")
    ]

    public let origin: InstallerRelease.Origin = .local

    private let searchDirectories: [URL]
    private let fileManager: FileManager

    public init(
        searchDirectories: [URL] = LocalInstallerSource.defaultSearchDirectories,
        fileManager: FileManager = .default
    ) {
        self.searchDirectories = searchDirectories
        self.fileManager = fileManager
    }

    public func availableReleases() async throws -> [InstallerRelease] {
        searchDirectories
            .flatMap(candidateApplications(in:))
            .compactMap(release(forApplicationAt:))
            .sorted { $0.version > $1.version }
    }

    private func candidateApplications(in directory: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.filter {
            $0.pathExtension == "app" && $0.lastPathComponent.hasPrefix("Install macOS")
        }
    }

    private func release(forApplicationAt app: URL) -> InstallerRelease? {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")

        guard
            let data = try? Data(contentsOf: infoURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let info = plist as? [String: Any],
            let name = info["CFBundleDisplayName"] as? String,
            let versionString = info["DTPlatformVersion"] as? String,
            let version = OSVersion(versionString),
            let build = info["DTSDKBuild"] as? String
        else { return nil }

        let size = (try? fileManager.allocatedSize(ofDirectoryAt: app)) ?? 0

        return InstallerRelease(
            name: name,
            version: version,
            build: build,
            sizeBytes: size,
            origin: .local,
            payload: .localApplication(path: app)
        )
    }
}

extension FileManager {
    /// Sums the allocated size of every regular file beneath `url`.
    func allocatedSize(ofDirectoryAt url: URL) throws -> Int64 {
        guard let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter LocalInstallerSourceTests`
Expected: PASS, 3 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Sources/LocalInstallerSource.swift Tests/MacOSInstallerKitTests/LocalInstallerSourceTests.swift
git commit -m "feat: discover existing macOS installer applications on disk"
```

---

### Task 10: ReleaseCatalog merge and precedence

Combines all sources, deduplicates by identity, and applies the fixed precedence rule.

**Files:**
- Create: `Sources/MacOSInstallerKit/Sources/ReleaseCatalog.swift`
- Test: `Tests/MacOSInstallerKitTests/ReleaseCatalogTests.swift`

**Interfaces:**
- Consumes: `InstallerSource` (Task 7), `InstallerRelease` (Task 3).
- Produces: `ReleaseCatalog(sources:minimumVersion:)`; `func allReleases() async -> ReleaseCatalog.Result`; `ReleaseCatalog.Result` (`releases: [InstallerRelease]`, `failures: [String]`); `static let minimumSupportedVersion: OSVersion`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private struct StubSource: InstallerSource {
    let origin: InstallerRelease.Origin
    let releases: [InstallerRelease]
    var error: (any Error)?

    func availableReleases() async throws -> [InstallerRelease] {
        if let error { throw error }
        return releases
    }
}

private func release(
    _ version: String,
    build: String,
    origin: InstallerRelease.Origin
) throws -> InstallerRelease {
    InstallerRelease(
        name: "macOS Test",
        version: try #require(OSVersion(version)),
        build: build,
        sizeBytes: 1000,
        origin: origin,
        payload: .softwareUpdate(version: version)
    )
}

@Test("prefers the local copy when two sources offer the same build")
func localWinsOverCatalog() async throws {
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .sucatalog, releases: [try release("26.7", build: "25G229", origin: .sucatalog)]),
        StubSource(origin: .local, releases: [try release("26.7", build: "25G229", origin: .local)]),
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.count == 1)
    #expect(result.releases.first?.origin == .local)
}

@Test("prefers the catalog over software update for the same build")
func catalogWinsOverSoftwareUpdate() async throws {
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .softwareUpdate, releases: [try release("26.7", build: "25G229", origin: .softwareUpdate)]),
        StubSource(origin: .sucatalog, releases: [try release("26.7", build: "25G229", origin: .sucatalog)]),
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.first?.origin == .sucatalog)
}

@Test("keeps distinct builds of the same version separate")
func keepsDistinctBuilds() async throws {
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .sucatalog, releases: [
            try release("26.7", build: "25G229", origin: .sucatalog),
            try release("26.7", build: "25G230", origin: .sucatalog),
        ])
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.count == 2)
}

@Test("excludes versions below the Mojave floor")
func excludesBelowMinimumVersion() async throws {
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .sucatalog, releases: [
            try release("10.13.6", build: "17G66", origin: .sucatalog),
            try release("10.14.6", build: "18G103", origin: .sucatalog),
        ])
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.map(\.build) == ["18G103"])
}

@Test("records a source failure without losing the other sources' results")
func oneFailingSourceDoesNotLoseOthers() async throws {
    struct Boom: Error {}
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .sucatalog, releases: [], error: Boom()),
        StubSource(origin: .local, releases: [try release("26.7", build: "25G229", origin: .local)]),
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.count == 1)
    #expect(result.failures.count == 1)
}

@Test("sorts newest version first")
func sortsNewestFirst() async throws {
    let catalog = ReleaseCatalog(sources: [
        StubSource(origin: .sucatalog, releases: [
            try release("15.8", build: "24H23", origin: .sucatalog),
            try release("27.0", build: "26A428", origin: .sucatalog),
            try release("26.7", build: "25G229", origin: .sucatalog),
        ])
    ])

    let result = await catalog.allReleases()

    #expect(result.releases.map { $0.version.description } == ["27.0", "26.7", "15.8"])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ReleaseCatalogTests`
Expected: FAIL — `cannot find 'ReleaseCatalog' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Merges every source into one list. A source that fails is recorded and
/// skipped rather than taking the whole listing down — an offline machine with
/// a local installer should still be able to use it.
public struct ReleaseCatalog {
    public struct Result: Sendable {
        public let releases: [InstallerRelease]
        public let failures: [String]
    }

    /// The oldest macOS this tool will write media for.
    public static let minimumSupportedVersion = OSVersion("10.14")!

    private let sources: [any InstallerSource]
    private let minimumVersion: OSVersion

    public init(
        sources: [any InstallerSource],
        minimumVersion: OSVersion = ReleaseCatalog.minimumSupportedVersion
    ) {
        self.sources = sources
        self.minimumVersion = minimumVersion
    }

    public func allReleases() async -> Result {
        var collected: [InstallerRelease] = []
        var failures: [String] = []

        for source in sources {
            do {
                collected.append(contentsOf: try await source.availableReleases())
            } catch {
                failures.append("\(source.origin): \(error)")
            }
        }

        let eligible = collected.filter { $0.version >= minimumVersion }

        // Same version+build from two sources collapses to the higher-precedence one.
        var best: [ReleaseIdentity: InstallerRelease] = [:]
        for release in eligible {
            if let existing = best[release.identity], existing.origin >= release.origin {
                continue
            }
            best[release.identity] = release
        }

        let sorted = best.values.sorted {
            if $0.version != $1.version { return $0.version > $1.version }
            return $0.build > $1.build
        }

        return Result(releases: sorted, failures: failures)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ReleaseCatalogTests`
Expected: PASS, 6 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Sources/ReleaseCatalog.swift Tests/MacOSInstallerKitTests/ReleaseCatalogTests.swift
git commit -m "feat: merge installer sources with origin precedence and version floor"
```

---

### Task 11: The list command and local CI

Wires everything into a runnable binary and locks in the coverage gate.

**Files:**
- Modify: `Sources/macos-installer/main.swift` (replace the placeholder entirely)
- Create: `Sources/macos-installer/ListCommand.swift`
- Create: `Sources/MacOSInstallerKit/Sources/ReleaseTableFormatter.swift`
- Create: `scripts/ci.sh`
- Test: `Tests/MacOSInstallerKitTests/ReleaseTableFormatterTests.swift`

**Interfaces:**
- Consumes: `ReleaseCatalog` (Task 10), all three sources (Tasks 7–9), `RealCommandRunner` (Task 1), `URLSessionDataFetcher` (Task 6).
- Produces: `ReleaseTableFormatter.render(_ releases: [InstallerRelease]) -> String`; `MacOSInstallerCommand` (root, subcommand `list`).

- [ ] **Step 1: Write the failing formatter test**

Formatting lives in the library, not the executable, so it is covered.

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private func release(
    _ name: String,
    _ version: String,
    _ build: String,
    _ size: Int64,
    _ origin: InstallerRelease.Origin
) throws -> InstallerRelease {
    InstallerRelease(
        name: name,
        version: try #require(OSVersion(version)),
        build: build,
        sizeBytes: size,
        origin: origin,
        payload: .softwareUpdate(version: version)
    )
}

@Test("renders a header and one aligned row per release")
func rendersAlignedTable() throws {
    let output = ReleaseTableFormatter.render([
        try release("macOS Tahoe", "26.7", "25G229", 18_381_960_192, .sucatalog),
        try release("macOS Sequoia", "15.8", "24H23", 15_663_996_928, .local),
    ])

    let lines = output.split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    #expect(lines[0].contains("VERSION"))
    #expect(lines[1].contains("macOS Tahoe"))
    #expect(lines[1].contains("26.7"))
    #expect(lines[1].contains("25G229"))
    #expect(lines[2].contains("macOS Sequoia"))
}

@Test("marks a locally available release so no download is implied")
func marksLocalReleases() throws {
    let output = ReleaseTableFormatter.render([
        try release("macOS Sequoia", "15.8", "24H23", 15_663_996_928, .local)
    ])

    #expect(output.contains("on disk"))
}

@Test("renders a clear message for an empty list")
func rendersEmptyMessage() {
    #expect(ReleaseTableFormatter.render([]).contains("No macOS installers"))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ReleaseTableFormatterTests`
Expected: FAIL — `cannot find 'ReleaseTableFormatter' in scope`

- [ ] **Step 3: Write the formatter**

```swift
import Foundation

/// Renders releases as a fixed-width table. Lives in the library so it is
/// covered by tests; the executable only prints what this returns.
public enum ReleaseTableFormatter {
    public static func render(_ releases: [InstallerRelease]) -> String {
        guard !releases.isEmpty else {
            return "No macOS installers are available from any source."
        }

        let nameWidth = max(4, releases.map(\.name.count).max() ?? 4)
        let versionWidth = max(7, releases.map { $0.version.description.count }.max() ?? 7)
        let buildWidth = max(5, releases.map(\.build.count).max() ?? 5)

        var lines: [String] = []
        lines.append(
            pad("NAME", nameWidth) + "  "
                + pad("VERSION", versionWidth) + "  "
                + pad("BUILD", buildWidth) + "  "
                + pad("SIZE", 9) + "  SOURCE"
        )

        for release in releases {
            lines.append(
                pad(release.name, nameWidth) + "  "
                    + pad(release.version.description, versionWidth) + "  "
                    + pad(release.build, buildWidth) + "  "
                    + pad(release.displaySize, 9) + "  "
                    + describe(release.origin)
            )
        }

        return lines.joined(separator: "\n")
    }

    private static func describe(_ origin: InstallerRelease.Origin) -> String {
        switch origin {
        case .local: return "on disk"
        case .sucatalog: return "Apple catalog"
        case .softwareUpdate: return "Software Update"
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ReleaseTableFormatterTests`
Expected: PASS, 3 tests

- [ ] **Step 5: Write the command**

Replace `Sources/macos-installer/main.swift` with:

```swift
import ArgumentParser

@main
struct MacOSInstallerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macos-installer",
        abstract: "Create a bootable offline macOS installer on an external drive.",
        subcommands: [ListCommand.self],
        defaultSubcommand: ListCommand.self
    )
}
```

Create `Sources/macos-installer/ListCommand.swift`:

```swift
import ArgumentParser
import Foundation
import MacOSInstallerKit

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show every macOS version that can be downloaded or reused."
    )

    @Flag(name: .long, help: "Skip Apple's catalog and use only softwareupdate and local installers.")
    var offline = false

    func run() async throws {
        let fetcher = URLSessionDataFetcher()
        let runner = RealCommandRunner()

        var sources: [any InstallerSource] = [
            LocalInstallerSource(),
            SoftwareUpdateSource(runner: runner),
        ]
        if !offline {
            sources.append(SucatalogSource(fetcher: fetcher))
        }

        let result = await ReleaseCatalog(sources: sources).allReleases()

        print(ReleaseTableFormatter.render(result.releases))

        for failure in result.failures {
            FileHandle.standardError.write(Data("warning: source unavailable — \(failure)\n".utf8))
        }
    }
}
```

Note: because `main.swift` uses `@main`, rename the file to `Sources/macos-installer/MacOSInstallerCommand.swift`. A file literally named `main.swift` cannot contain `@main`.

```bash
git mv Sources/macos-installer/main.swift Sources/macos-installer/MacOSInstallerCommand.swift
```

- [ ] **Step 6: Build and run it for real**

Run: `swift build && swift run macos-installer list`
Expected: a table including macOS 27 Golden Gate, Tahoe and Sequoia. This is the first end-to-end proof — it hits the real catalog.

Run: `swift run macos-installer list --offline`
Expected: a shorter table from `softwareupdate` and any local installers, no network access to swscan.

- [ ] **Step 7: Write the CI script**

`scripts/ci.sh`:

```bash
#!/usr/bin/env bash
# Local CI. No hosted runners — all verification happens on this machine.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building"
swift build --build-tests

echo "==> Testing with coverage"
swift test --enable-code-coverage

BIN_PATH="$(swift build --show-bin-path)"
PROFDATA="${BIN_PATH}/codecov/default.profdata"
TEST_BINARY="$(find "${BIN_PATH}" -name '*.xctest' -maxdepth 1 | head -1)/Contents/MacOS/$(basename "$(find "${BIN_PATH}" -name '*.xctest' -maxdepth 1 | head -1)" .xctest)"

echo "==> Coverage for MacOSInstallerKit"
xcrun llvm-cov report \
    "${TEST_BINARY}" \
    -instr-profile "${PROFDATA}" \
    -ignore-filename-regex='(Tests|\.build)/' \
    | tee /tmp/macos-installer-coverage.txt

TOTAL="$(awk '/^TOTAL/ {gsub(/%/,"",$10); print $10}' /tmp/macos-installer-coverage.txt)"
echo "==> Total line coverage: ${TOTAL}%"

if awk "BEGIN {exit !(${TOTAL} < 80)}"; then
    echo "FAIL: coverage ${TOTAL}% is below the 80% minimum" >&2
    exit 1
fi

echo "==> All checks passed"
```

Make it executable: `chmod +x scripts/ci.sh`

- [ ] **Step 8: Run CI and confirm the gate holds**

Run: `./scripts/ci.sh`
Expected: all tests pass and total coverage is reported at 80% or above. If coverage is short, add tests for the uncovered branches the report names — do not lower the threshold.

- [ ] **Step 9: Commit**

```bash
git add Sources scripts Tests
git commit -m "feat: add list command and local CI with coverage gate"
```

---

## Self-Review

**Spec coverage.** Every item in the spec's Data Flow "sources" stage maps to a task: sucatalog (7), softwareupdate (8), local reuse (9), merge and precedence (10), 24-hour cache — **not yet implemented**. The cache is deliberately deferred: it is an optimisation over a working path, and adding it before the path works would be premature. It is the first task of Plan 2, where the download code that benefits from it also lives. Guidance, disks, `VolumeGuard`, download, assembly and media writing are all out of this plan's scope by design and belong to Plans 2–4.

**Placeholder scan.** No "TBD", no "add error handling", no "similar to Task N". Every code step carries runnable code.

**Type consistency.** `InstallerRelease.Origin` is `.local` / `.sucatalog` / `.softwareUpdate` in Tasks 3, 7, 8, 9, 10 and 11. `availableReleases()` is `async throws -> [InstallerRelease]` in the protocol (7) and all three conformances. `OSVersion(_:)` is failable everywhere it is used. `CommandRunner.run(_:_:)` keeps the same two-argument shape in Tasks 1 and 8. `ReleaseCatalog.allReleases()` is `async` but not `throws`, and Task 11 calls it without `try` — consistent.

**One known rough edge, called out rather than hidden.** Task 9 reads `DTPlatformVersion` and `DTSDKBuild` from an installer app's `Info.plist`. Those keys are correct for real Apple installer apps, but the task's tests construct synthetic apps, so they verify the *parsing*, not that Apple actually populates those keys the way we expect. The first execution of Task 9 should additionally run `swift run macos-installer list` against a machine that has a genuine `Install macOS *.app` present, and correct the key names if they differ. Note this in the task's commit message if a correction is needed.

## Plan Sequence

| Plan | Scope | Status |
|---|---|---|
| **1. Version discovery** | This document — sources, merge, `list` | Ready |
| 2. Media creation | Catalog cache, downloader, checksum, `DiskEnumerator`, `VolumeGuard`, `InstallAssistantAssembler`, `InstallMediaWriter`, `create` command | Not written |
| 3. Guided walkthrough | `Guidance` module, target-Mac picker, three-stage presenter, `InstructionExporter`, `--brief` | Not written |
| 4. Legacy ESD | Opens with the reassembly spike, then `LegacyESDAssembler`; completes v1 | Not written |

Plan 2 should not be written until Plan 1 is executed, because the shape of the download and cache code depends on what the real catalog turns out to require.
