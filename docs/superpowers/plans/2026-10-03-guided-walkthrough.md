# Guided Walkthrough Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the tool usable by someone who has never opened Terminal — ask which Mac will boot the stick, narrate each stage in plain language, hand them written boot instructions they can carry to the other machine, and make every error say what happened, what it means, and what to do next.

**Architecture:** One structured user-facing error type replaces six independent producers of user text, so every message in the tool has the same three-part shape and a matching log entry. Guidance is structured data keyed by stage and target Mac — not `print()` calls — so it is testable and editable without touching control flow. The executable renders; the library decides what to say.

**Tech Stack:** Swift 6.4, SwiftPM, Swift Testing, `swift-argument-parser` 1.8.2. Foundation only otherwise.

**Spec:** `docs/superpowers/specs/2026-09-26-macos-installer-design.md` — the Guided Walkthrough and Error Handling sections.
**Carry-forward:** `docs/superpowers/plans/carry-forward.md`

## Global Constraints

- Host floor macOS 13 Ventura. `platforms: [.macOS(.v13)]` — never change it.
- Only external dependency is `swift-argument-parser`.
- Run tests with `./scripts/test.sh`, never bare `swift test` (Command Line Tools ship the Swift Testing macro plugin in a subdirectory SwiftPM does not search).
- No `nonisolated(unsafe)` and no `@unchecked Sendable` in `Sources/`.
- No `print()` inside `MacOSInstallerKit`. The library returns strings; the executable prints them.
- Every subprocess goes through `CommandRunner`.
- Tests never touch the live network, a real disk beyond temp directories, or a real subprocess.
- **No command may modify, mount, unmount, format or erase any volume on the development machine.** Both external volumes there (`disk5s1`, `disk6s2`, both named "Untitled") hold live project work.
- Coverage ≥ 80% on `MacOSInstallerKit`, gated by `scripts/ci.sh`. It is currently 95.52%; do not regress it.
- Assert ordering on the FULL array, never on `.first`.
- Every declared error case gets a test asserting that specific case.
- Every safety guard gets a mutation check.
- Conventional commits.

## Copy Rules

This plan writes text a frightened beginner will read. The rules are requirements, not style preferences:

- **Second person, present tense, active voice.** "Hold the power button", not "the power button should be held".
- **No jargon without an inline gloss.** "Terminal (the app where you typed this command)" on first use.
- **Never say "simply", "just", or "obviously".** They tell a confused reader the problem is them.
- **Name the thing on screen.** "Click Erase", not "confirm the operation".
- **One instruction per numbered line.**
- **Numbers as digits.** "32 GB", not "thirty-two gigabytes".
- Target Mac instructions are for the SELECTED target only. No "if Apple silicon… otherwise…" branches for the reader to misparse.

## Ground Truth

From Apple's documentation, already verified and recorded in the spec (`support.apple.com/en-us/101578`, published 2026-09-14):

- **Apple silicon target:** shut down, connect the drive, press and hold the power button until startup options appear, select the installer, click Continue.
- **Intel target:** shut down, connect the drive, turn on and immediately hold Option (Alt), release when the volume picker appears, select the installer, press Return.
- **T2 Macs (2018+ Intel) additionally** require Startup Security Utility to permit booting from external media, or they will refuse.
- The target Mac must be **online during installation** — the installer fetches model-specific firmware.
- An incompatible macOS/Mac pairing shows **a circle with a line through it**.
- Apple recommends a **32 GB** drive.
- The macOS password prompt **shows no characters at all** as you type.
- A TCC dialog — *"Terminal would like to access files on a removable volume"* — appears mid-run and must be accepted or the write fails.
- On success the volume is **renamed** to match the installer, e.g. `Install macOS Tahoe`.

## Current State This Builds On

183→188 tests, `list` and `create` both work. `create` already: refuses internal and boot volumes absolutely, refuses an ambiguous `--volume`, takes a typed-name confirmation, re-resolves the target by UUID immediately before erasing, and renders `MediaWriteError` honestly.

**Six independent producers of user-facing text exist today** and Task 4 retires four of them into one type:
- `VolumeGuard.RefusalReason.userMessage`
- `InstallerPreparationError.userMessage`
- `PreparationErrorFormatter.render`
- `MediaWriteErrorFormatter.render`
- `VolumeTableFormatter.render` (stays — it is a table, not an error)
- `ReleaseTableFormatter.render` (stays — same)

## File Structure

| File | Responsibility |
|---|---|
| `Sources/MacOSInstallerKit/Messages/UserFacingError.swift` | The three-part error type and its renderer |
| `Sources/MacOSInstallerKit/Messages/DiagnosticLog.swift` | Appends technical detail to `~/Library/Logs/macos-installer/` |
| `Sources/MacOSInstallerKit/Messages/Explainable.swift` | Protocol: an error that can describe itself to a human |
| `Sources/MacOSInstallerKit/Guidance/TargetMac.swift` | Which Mac will boot the stick |
| `Sources/MacOSInstallerKit/Guidance/GuidanceCatalog.swift` | Stage content keyed by stage and target |
| `Sources/MacOSInstallerKit/Guidance/InstructionExporter.swift` | Writes the carry-away Markdown file |
| `Sources/macos-installer/TargetMacPicker.swift` | Terminal prompt for the target Mac |
| `Sources/macos-installer/WalkthroughPresenter.swift` | Prints stages; owns no content |
| `docs/manual-verification.md` | Extended with walkthrough rows |

---

### Task 1: The three-part user-facing error

Everything else in this plan renders through this type, so it comes first. The spec requires every user-facing error to state what happened, what it means, and what to do next.

**Files:**
- Create: `Sources/MacOSInstallerKit/Messages/UserFacingError.swift`
- Test: `Tests/MacOSInstallerKitTests/UserFacingErrorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `UserFacingError` with `title: String`, `whatHappened: String`, `whatItMeans: String?`, `whatToDoNext: [String]`, `logReference: String?`; `init(title:whatHappened:whatItMeans:whatToDoNext:logReference:)`; `func rendered() -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MacOSInstallerKit

@Test("renders all three parts with the title, in order")
func rendersThreeParts() {
    let error = UserFacingError(
        title: "Couldn't erase the drive",
        whatHappened: #"macOS refused to erase "SanDisk Ultra"."#,
        whatItMeans: "This usually means the drive is damaged, or formatted in a way macOS can't overwrite.",
        whatToDoNext: [
            "Open Disk Utility (it's in Applications, inside the Utilities folder)",
            "Select SanDisk Ultra in the list on the left",
            "Click Erase",
            #"Set Format to "Mac OS Extended (Journaled)""#,
            "Click Erase, then run this command again",
        ],
        logReference: "~/Library/Logs/macos-installer/2026-10-03.log"
    )

    let out = error.rendered()
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    // The title leads, marked so it is findable in a scrollback.
    #expect(lines[0].contains("Couldn't erase the drive"))
    #expect(lines[0].contains("✗"))

    // All three parts appear, in the spec's order.
    let happenedAt = try! #require(out.range(of: "macOS refused to erase"))
    let meansAt = try! #require(out.range(of: "This usually means"))
    let nextAt = try! #require(out.range(of: "Open Disk Utility"))
    #expect(happenedAt.lowerBound < meansAt.lowerBound)
    #expect(meansAt.lowerBound < nextAt.lowerBound)

    // Steps are numbered, one per line.
    #expect(out.contains("1. Open Disk Utility"))
    #expect(out.contains("5. Click Erase, then run this command again"))

    // The log path is reachable from the message.
    #expect(out.contains("~/Library/Logs/macos-installer/2026-10-03.log"))
}

@Test("omits the meaning section when there is nothing useful to add")
func omitsAbsentMeaning() {
    let error = UserFacingError(
        title: "Couldn't reach Apple",
        whatHappened: "The download couldn't start.",
        whatItMeans: nil,
        whatToDoNext: ["Check your internet connection, then run this command again"],
        logReference: nil
    )

    let out = error.rendered()

    #expect(out.contains("Couldn't reach Apple"))
    #expect(out.contains("The download couldn't start."))
    #expect(out.contains("1. Check your internet connection"))
    // No empty section header, no stray blank run where the meaning would be.
    #expect(out.contains("\n\n\n") == false)
}

@Test("renders without a next-steps section when there is genuinely nothing to try")
func omitsEmptyNextSteps() {
    let error = UserFacingError(
        title: "The drive is in an unknown state",
        whatHappened: "The erase started and did not finish.",
        whatItMeans: "The drive is not safe to boot from.",
        whatToDoNext: [],
        logReference: nil
    )

    let out = error.rendered()

    #expect(out.contains("unknown state"))
    #expect(out.contains("To fix it") == false)
}

@Test("never uses language that blames the reader")
func avoidsBlamingLanguage() {
    // These words tell a confused person the problem is them. The project's
    // copy rules forbid them in any user-facing string.
    let banned = ["simply", "just ", "obviously", "merely"]
    let error = UserFacingError(
        title: "Couldn't erase the drive",
        whatHappened: "macOS refused to erase the drive.",
        whatItMeans: "The drive may be damaged.",
        whatToDoNext: ["Open Disk Utility and erase it, then run this command again"],
        logReference: nil
    )

    let lowered = error.rendered().lowercased()
    for word in banned {
        #expect(lowered.contains(word) == false, "rendered message contains banned word '\(word)'")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter UserFacingErrorTests`
Expected: FAIL — `cannot find 'UserFacingError' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A message for someone who has never opened Terminal.
///
/// The spec requires every user-facing error to state three things: what
/// happened, what it means, and what to do next. This type makes that shape
/// structural rather than a convention each call site has to remember — the
/// previous design had four independent formatters, each phrasing the same
/// guarantees differently.
public struct UserFacingError: Equatable, Sendable {
    /// A short line a user can search for, e.g. "Couldn't erase the drive".
    public let title: String
    /// Plain statement of the observed fact, naming what the user named.
    public let whatHappened: String
    /// Why it probably happened. Nil when there is nothing honest to add —
    /// guessing is worse than silence.
    public let whatItMeans: String?
    /// Concrete actions, one per entry, in the order to try them. Empty when
    /// there is genuinely nothing to try; do not invent filler.
    public let whatToDoNext: [String]
    /// Where the technical detail was written, if it was.
    public let logReference: String?

    public init(
        title: String,
        whatHappened: String,
        whatItMeans: String? = nil,
        whatToDoNext: [String] = [],
        logReference: String? = nil
    ) {
        self.title = title
        self.whatHappened = whatHappened
        self.whatItMeans = whatItMeans
        self.whatToDoNext = whatToDoNext
        self.logReference = logReference
    }

    public func rendered() -> String {
        var blocks: [String] = ["✗ \(title)"]
        blocks.append(indent(whatHappened))

        if let whatItMeans {
            blocks.append(indent(whatItMeans))
        }

        if !whatToDoNext.isEmpty {
            let steps = whatToDoNext.enumerated()
                .map { "     \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            blocks.append("   To fix it:\n" + steps)
        }

        if let logReference {
            blocks.append(indent("Details saved to:\n\(logReference)"))
        }

        return blocks.joined(separator: "\n\n")
    }

    private func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "   \($0)" }
            .joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter UserFacingErrorTests`
Expected: PASS, 4 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Messages Tests/MacOSInstallerKitTests/UserFacingErrorTests.swift
git commit -m "feat: add the three-part user-facing error type"
```

---

### Task 2: Diagnostic log

The terminal shows the human version; the technical detail goes to a file. The spec requires exact argv, exit status and stderr to survive somewhere — right now a possibly-ruined drive leaves its diagnostics only in terminal scrollback.

**Files:**
- Create: `Sources/MacOSInstallerKit/Messages/DiagnosticLog.swift`
- Test: `Tests/MacOSInstallerKitTests/DiagnosticLogTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `DiagnosticLog(directory:clock:)` with `func record(_ detail: String) -> String?` returning the display path written to, `static var defaultDirectory: URL`, `static func displayPath(for: URL) -> String`.

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

@Test("writes a dated file and returns the path to show the user")
func writesDatedFile() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let fixed = Date(timeIntervalSince1970: 1_790_000_000)  // a fixed instant
    let log = DiagnosticLog(directory: dir, clock: { fixed })

    let shown = log.record("createinstallmedia exited 1\nstderr: could not erase")

    let expectedName = DateFormatter.logDateFormatter.string(from: fixed) + ".log"
    let file = dir.appendingPathComponent(expectedName)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(shown?.hasSuffix(expectedName) == true)

    let contents = try String(contentsOf: file, encoding: .utf8)
    #expect(contents.contains("createinstallmedia exited 1"))
    #expect(contents.contains("could not erase"))
}

@Test("appends rather than truncating, so a session's failures accumulate")
func appendsAcrossCalls() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let fixed = Date(timeIntervalSince1970: 1_790_000_000)
    let log = DiagnosticLog(directory: dir, clock: { fixed })

    _ = log.record("first failure")
    _ = log.record("second failure")

    let file = dir.appendingPathComponent(DateFormatter.logDateFormatter.string(from: fixed) + ".log")
    let contents = try String(contentsOf: file, encoding: .utf8)
    #expect(contents.contains("first failure"))
    #expect(contents.contains("second failure"))
}

@Test("timestamps each entry so entries can be correlated with a run")
func timestampsEntries() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let fixed = Date(timeIntervalSince1970: 1_790_000_000)
    let log = DiagnosticLog(directory: dir, clock: { fixed })

    _ = log.record("something")

    let file = dir.appendingPathComponent(DateFormatter.logDateFormatter.string(from: fixed) + ".log")
    let contents = try String(contentsOf: file, encoding: .utf8)
    // An ISO-8601 instant appears on the entry's header line.
    #expect(contents.contains("202"))
    #expect(contents.contains("T"))
}

@Test("returns nil rather than throwing when the log cannot be written")
func survivesUnwritableDirectory() {
    // A path under a file, so directory creation cannot succeed.
    let unwritable = URL(fileURLWithPath: "/dev/null/macos-installer-logs")
    let log = DiagnosticLog(directory: unwritable, clock: { Date() })

    // Logging is a convenience. Failing to log must never mask the real error
    // the caller is in the middle of reporting.
    #expect(log.record("detail") == nil)
}

@Test("abbreviates a home-relative path for display")
func abbreviatesHomePath() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let inside = home.appendingPathComponent("Library/Logs/macos-installer/x.log")

    #expect(DiagnosticLog.displayPath(for: inside) == "~/Library/Logs/macos-installer/x.log")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter DiagnosticLogTests`
Expected: FAIL — `cannot find 'DiagnosticLog' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

extension DateFormatter {
    /// `2026-10-03` — one log file per day.
    static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}

/// Appends technical detail to `~/Library/Logs/macos-installer/<date>.log`.
///
/// The terminal shows the human version of a failure; this is where the exact
/// argv, exit status and stderr go. For a possibly-partially-erased drive that
/// detail is the only record of what was attempted, and terminal scrollback is
/// not a record.
///
/// Logging is best-effort by design: `record` returns nil rather than throwing,
/// because a logging failure must never replace or mask the error the caller is
/// in the middle of reporting.
public struct DiagnosticLog {
    private let directory: URL
    private let clock: () -> Date

    public init(directory: URL, clock: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.clock = clock
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/macos-installer", isDirectory: true)
    }

    /// Abbreviates a path under the user's home directory to `~/…` for display.
    public static func displayPath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard url.path.hasPrefix(home) else { return url.path }
        return "~" + url.path.dropFirst(home.count)
    }

    /// Appends `detail` and returns the display path, or nil if nothing was written.
    @discardableResult
    public func record(_ detail: String) -> String? {
        let now = clock()
        let file = directory.appendingPathComponent(
            DateFormatter.logDateFormatter.string(from: now) + ".log"
        )

        let entry = "=== \(ISO8601DateFormatter().string(from: now)) ===\n\(detail)\n\n"

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
            } else {
                try Data(entry.utf8).write(to: file, options: .atomic)
            }
        } catch {
            return nil
        }

        return Self.displayPath(for: file)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter DiagnosticLogTests`
Expected: PASS, 5 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Messages/DiagnosticLog.swift Tests/MacOSInstallerKitTests/DiagnosticLogTests.swift
git commit -m "feat: record technical failure detail to a dated log file"
```

---

### Task 3: The Explainable protocol

One protocol lets every error in the codebase describe itself in the three-part shape, so the executable never has to know which error type it is holding.

**Files:**
- Create: `Sources/MacOSInstallerKit/Messages/Explainable.swift`
- Test: `Tests/MacOSInstallerKitTests/ExplainableTests.swift`

**Interfaces:**
- Consumes: `UserFacingError` (Task 1), `DiagnosticLog` (Task 2).
- Produces: `protocol Explainable { var explanation: UserFacingError { get }; var technicalDetail: String { get } }`; `func explain(_ error: any Error, log: DiagnosticLog?) -> UserFacingError` as a free function in the library.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

private struct KnownFailure: Error, Explainable {
    var explanation: UserFacingError {
        UserFacingError(
            title: "Couldn't do the thing",
            whatHappened: "The thing did not happen.",
            whatItMeans: "Something was wrong with the thing.",
            whatToDoNext: ["Try the thing again"]
        )
    }
    var technicalDetail: String { "KnownFailure: exit 3, stderr: nope" }
}

private struct UnknownFailure: Error {}

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("uses an Explainable error's own three-part explanation")
func usesExplainableExplanation() {
    let result = explain(KnownFailure(), log: nil)

    #expect(result.title == "Couldn't do the thing")
    #expect(result.whatToDoNext == ["Try the thing again"])
}

@Test("writes the technical detail to the log and references it in the message")
func logsTechnicalDetail() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let log = DiagnosticLog(directory: dir, clock: { Date(timeIntervalSince1970: 1_790_000_000) })

    let result = explain(KnownFailure(), log: log)

    let reference = try #require(result.logReference)
    #expect(reference.hasSuffix(".log"))

    let written = try String(
        contentsOf: dir.appendingPathComponent(
            DateFormatter.logDateFormatter.string(from: Date(timeIntervalSince1970: 1_790_000_000)) + ".log"
        ),
        encoding: .utf8
    )
    #expect(written.contains("exit 3"))
    #expect(written.contains("nope"))
}

@Test("an unexplainable error still produces a three-part message, never raw enum text")
func wrapsUnknownErrors() {
    let result = explain(UnknownFailure(), log: nil)

    // The user must never see `UnknownFailure()`; they get a real message and
    // the raw text goes to the log instead.
    #expect(result.title.isEmpty == false)
    #expect(result.whatHappened.contains("UnknownFailure") == false)
    #expect(result.whatToDoNext.isEmpty == false)
}

@Test("an unexplainable error's raw description is preserved in the log")
func logsUnknownErrorDescription() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let log = DiagnosticLog(directory: dir, clock: { Date(timeIntervalSince1970: 1_790_000_000) })

    _ = explain(UnknownFailure(), log: log)

    let written = try String(
        contentsOf: dir.appendingPathComponent(
            DateFormatter.logDateFormatter.string(from: Date(timeIntervalSince1970: 1_790_000_000)) + ".log"
        ),
        encoding: .utf8
    )
    #expect(written.contains("UnknownFailure"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter ExplainableTests`
Expected: FAIL — `cannot find 'Explainable' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// An error that can describe itself to someone who has never opened Terminal.
///
/// Conforming types own their own wording, so the executable never switches on
/// error type to decide what to say.
public protocol Explainable {
    /// The three-part message a user sees.
    var explanation: UserFacingError { get }
    /// Exact argv, exit status, stderr — whatever a developer would want. Goes
    /// to the log, never to the terminal.
    var technicalDetail: String { get }
}

/// Turns any error into a three-part message, logging its technical detail.
///
/// An error that is not `Explainable` still produces a real message rather than
/// raw enum text: the previous design let `String(describing:)` reach the user,
/// so a digest mismatch printed `mismatch(expected: "0000…", actual: "a1b…")`
/// to someone who had just confirmed erasing a drive.
public func explain(_ error: any Error, log: DiagnosticLog?) -> UserFacingError {
    let detail: String
    let base: UserFacingError

    if let explainable = error as? Explainable {
        detail = explainable.technicalDetail
        base = explainable.explanation
    } else {
        detail = "Unexpected error: \(String(reflecting: error))"
        base = UserFacingError(
            title: "Something went wrong that this tool didn't expect",
            whatHappened: "The operation stopped before it finished.",
            whatItMeans: "This is a gap in the tool rather than something you did.",
            whatToDoNext: [
                "Run the command again — it may have been temporary",
                "If it keeps happening, open an issue and attach the log file below",
            ]
        )
    }

    let reference = log?.record(detail)

    return UserFacingError(
        title: base.title,
        whatHappened: base.whatHappened,
        whatItMeans: base.whatItMeans,
        whatToDoNext: base.whatToDoNext,
        logReference: reference ?? base.logReference
    )
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter ExplainableTests`
Expected: PASS, 5 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Messages/Explainable.swift Tests/MacOSInstallerKitTests/ExplainableTests.swift
git commit -m "feat: add Explainable so every error can describe itself"
```

---

### Task 4: Port the existing errors, retire the two formatters

Four producers of user text collapse into `Explainable` conformances. This is the task that makes the error shape uniform instead of conventional.

**Files:**
- Modify: `Sources/MacOSInstallerKit/Media/InstallMediaWriter.swift` (add an `Explainable` conformance for `MediaWriteError`)
- Modify: `Sources/MacOSInstallerKit/Assembly/InstallerPreparer.swift` (same for `InstallerPreparationError`)
- Modify: `Sources/MacOSInstallerKit/Disks/VolumeGuard.swift` (keep `userMessage`, add an `explanation` for each `RefusalReason`)
- Delete: `Sources/MacOSInstallerKit/Media/MediaWriteErrorFormatter.swift`
- Delete: `Sources/MacOSInstallerKit/Assembly/PreparationErrorFormatter.swift`
- Modify: `Sources/macos-installer/CreateCommand.swift` (render through `explain`)
- Modify/delete the two formatters' test files; add conformance tests.

**Interfaces:**
- Consumes: `Explainable`, `UserFacingError`, `explain(_:log:)`.
- Produces: `MediaWriteError: Explainable`, `InstallerPreparationError: Explainable`, `VolumeGuard.RefusalReason.explanation: UserFacingError`.

**The honesty guarantees must survive the port verbatim.** Five of the six `MediaWriteError` cases happen before anything is written and must say the drive was not touched. `writeFailedDriveStateUnknown` must say the drive may be partially erased, is not safe to boot, and must be rewritten from scratch — never that a retry will fix it. The existing `MediaWriteErrorFormatter` tests pin this; port the assertions, do not drop them.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import MacOSInstallerKit

@Test("every pre-write MediaWriteError states that the drive was not touched")
func preWriteErrorsSayDriveUntouched() {
    let preWrite: [MediaWriteError] = [
        .targetDisappeared(uuid: "UUID-1"),
        .targetMoved(expected: "disk5s1", found: "disk7s1"),
        .targetNotMounted(uuid: "UUID-1"),
        .installerToolMissing(path: "/Applications/X.app/Contents/Resources/createinstallmedia"),
        .authenticationFailed(message: "Sorry, try again."),
    ]

    for error in preWrite {
        let rendered = error.explanation.rendered().lowercased()
        #expect(
            rendered.contains("not") && (rendered.contains("erased") || rendered.contains("written") || rendered.contains("touched")),
            "\(error) must state the drive was not modified"
        )
    }
}

@Test("the unknown-state error refuses to imply a retry will fix it")
func unknownStateErrorIsHonest() {
    let error = MediaWriteError.writeFailedDriveStateUnknown(exitCode: 1, message: "Failed to erase volume")
    let rendered = error.explanation.rendered().lowercased()

    #expect(rendered.contains("unknown"))
    // It must not tell the user the drive is fine, nor that retrying suffices.
    #expect(rendered.contains("nothing was written") == false)
    #expect(rendered.contains("not touched") == false)
    // It must direct them to start over rather than retry in place.
    #expect(rendered.contains("from scratch") || rendered.contains("start over"))
}

@Test("the unknown-state error carries the exit code in its technical detail, not its message")
func technicalDetailCarriesExitCode() {
    let error = MediaWriteError.writeFailedDriveStateUnknown(exitCode: 1, message: "Failed to erase volume")

    #expect(error.technicalDetail.contains("1"))
    #expect(error.technicalDetail.contains("Failed to erase volume"))
    // The user-facing title should not be a raw exit code.
    #expect(error.explanation.title.contains("exited with code") == false)
}

@Test("every refusal reason explains itself with something to do next")
func refusalReasonsOfferNextSteps() {
    let reasons: [VolumeGuard.RefusalReason] = [
        .internalDisk,
        .bootContainer,
        .notMounted,
        .wholeDisk,
        .holdsProtectedPath("/Volumes/Work/caches/x.pkg"),
        .tooSmall(capacityBytes: 8_000_000_000, requiredBytes: 20_000_000_000),
    ]

    for reason in reasons {
        let explanation = reason.explanation
        #expect(explanation.title.isEmpty == false, "\(reason) has no title")
        #expect(explanation.whatToDoNext.isEmpty == false, "\(reason) offers nothing to do next")
    }
}

@Test("the too-small refusal names both sizes in human units")
func tooSmallNamesBothSizes() {
    let reason = VolumeGuard.RefusalReason.tooSmall(
        capacityBytes: 8_000_000_000, requiredBytes: 20_000_000_000
    )

    let rendered = reason.explanation.rendered()
    #expect(rendered.contains("8.0 GB"))
    #expect(rendered.contains("20.0 GB"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter "MediaWriteError|RefusalReason"`
Expected: FAIL — no `explanation` member

- [ ] **Step 3: Conform `MediaWriteError`**

Add to `InstallMediaWriter.swift`, keeping the enum itself unchanged:

```swift
extension MediaWriteError: Explainable {
    public var explanation: UserFacingError {
        switch self {
        case .targetDisappeared:
            return UserFacingError(
                title: "The drive disappeared",
                whatHappened: "The drive you chose is no longer connected, so nothing was erased.",
                whatItMeans: "It was probably unplugged, or it went to sleep.",
                whatToDoNext: [
                    "Plug the drive back in and wait for it to appear on your desktop",
                    "Run this command again",
                ]
            )

        case .targetMoved(let expected, let found):
            return UserFacingError(
                title: "The drive moved",
                whatHappened: "The drive you confirmed was \(expected), but it is now \(found). Nothing was erased.",
                whatItMeans: "macOS renumbers drives when devices are plugged in or unplugged. "
                    + "This tool stopped rather than risk erasing a different drive.",
                whatToDoNext: [
                    "Leave your drives connected as they are",
                    "Run this command again and confirm the drive you want",
                ]
            )

        case .targetNotMounted:
            return UserFacingError(
                title: "The drive isn't ready",
                whatHappened: "The drive you chose is connected but not mounted, so nothing was erased.",
                whatItMeans: "macOS can see the hardware but hasn't made the drive available yet.",
                whatToDoNext: [
                    "Unplug the drive, wait a few seconds, and plug it back in",
                    "Wait until it appears on your desktop",
                    "Run this command again",
                ]
            )

        case .installerToolMissing(let path):
            return UserFacingError(
                title: "The installer app is incomplete",
                whatHappened: "The tool macOS uses to write the drive wasn't found inside the installer app. "
                    + "Nothing was erased.",
                whatItMeans: "The installer app is damaged or only partly downloaded.",
                whatToDoNext: [
                    "Delete the installer app from your Applications folder",
                    "Run this command again so it downloads a fresh copy",
                    "If it keeps failing, the expected location was: \(path)",
                ]
            )

        case .authenticationFailed:
            return UserFacingError(
                title: "The password wasn't accepted",
                whatHappened: "macOS didn't accept the administrator password, so nothing was erased.",
                whatItMeans: "Writing a drive needs administrator permission. "
                    + "The prompt shows no characters at all as you type, which can make it feel broken.",
                whatToDoNext: [
                    "Run this command again",
                    "Type your Mac login password when asked — you will see nothing appear, which is normal",
                    "Press Return",
                ]
            )

        case .writeFailedDriveStateUnknown:
            return UserFacingError(
                title: "The drive is in an unknown state",
                whatHappened: "The erase started and then stopped before it finished.",
                whatItMeans: "The drive is partly written and is NOT safe to boot from. "
                    + "It is not in the state it was before, and it is not finished either.",
                whatToDoNext: [
                    "Do not use this drive to install macOS",
                    "Erase it from scratch in Disk Utility (it's in Applications, inside Utilities)",
                    "Then run this command again",
                ]
            )
        }
    }

    public var technicalDetail: String {
        switch self {
        case .targetDisappeared(let uuid):
            return "MediaWriteError.targetDisappeared uuid=\(uuid)"
        case .targetMoved(let expected, let found):
            return "MediaWriteError.targetMoved expected=\(expected) found=\(found)"
        case .targetNotMounted(let uuid):
            return "MediaWriteError.targetNotMounted uuid=\(uuid)"
        case .installerToolMissing(let path):
            return "MediaWriteError.installerToolMissing path=\(path)"
        case .authenticationFailed(let message):
            return "MediaWriteError.authenticationFailed message=\(message)"
        case .writeFailedDriveStateUnknown(let exitCode, let message):
            return "MediaWriteError.writeFailedDriveStateUnknown exitCode=\(exitCode) message=\(message)"
        }
    }
}
```

- [ ] **Step 4: Conform `InstallerPreparationError` and `RefusalReason`**

Do the same for `InstallerPreparationError` in `InstallerPreparer.swift`, moving the wording from the deleted `PreparationErrorFormatter` into `explanation` and the byte counts and paths into `technicalDetail`. Every prepare-path case must state that the drive was not touched, because the user has already confirmed the erase by then.

For `VolumeGuard.RefusalReason`, add an `explanation` computed property alongside the existing `userMessage`. Keep `userMessage` — `VolumeTableFormatter` uses it for the one-line listing, which is a table cell, not an error report. Each explanation needs real next steps, for example `.tooSmall` should tell the user to use a larger drive and name both sizes, and `.internalDisk` should tell them to connect an external USB drive.

- [ ] **Step 5: Delete the two formatters and port their tests**

```bash
git rm Sources/MacOSInstallerKit/Media/MediaWriteErrorFormatter.swift
git rm Sources/MacOSInstallerKit/Assembly/PreparationErrorFormatter.swift
```

Move every assertion from `MediaWriteErrorFormatterTests` and `PreparationErrorFormatterTests` onto the new conformances. Do NOT delete assertions — in particular the ones pinning that pre-write errors say the drive was untouched and that the unknown-state error does not imply a retry. If an assertion no longer has a home, say so in your report rather than dropping it.

- [ ] **Step 6: Render through `explain` in `CreateCommand`**

Replace the formatter calls with a single catch that renders any error:

```swift
        } catch {
            let log = DiagnosticLog(directory: DiagnosticLog.defaultDirectory)
            print(explain(error, log: log).rendered())
            throw ExitCode.failure
        }
```

- [ ] **Step 7: Run the full suite**

Run: `./scripts/test.sh`
Expected: PASS. Coverage must not drop below 95% — check with `./scripts/ci.sh`.

- [ ] **Step 8: Mutation-check the honesty guarantee**

Change `writeFailedDriveStateUnknown`'s explanation to say "Nothing was written." Confirm `unknownStateErrorIsHonest` FAILS. Restore. This is the assertion that stops the tool lying about a possibly-ruined drive.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: unify user-facing errors behind Explainable"
```

---

### Task 5: TargetMac and its picker

The post-creation instructions depend on the Mac being installed *onto*, not the host. Writing Mojave media on Apple silicon for a 2015 Intel MacBook is the expected case, and the boot procedures are completely different — so the tool has to ask.

**Files:**
- Create: `Sources/MacOSInstallerKit/Guidance/TargetMac.swift`
- Create: `Sources/macos-installer/TargetMacPicker.swift`
- Test: `Tests/MacOSInstallerKitTests/TargetMacTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum TargetMac: String, CaseIterable, Sendable` with cases `appleSilicon`, `intelT2`, `intelPreT2`; `var label: String`; `var bootMethod: String`; `var requiresStartupSecurityUtility: Bool`; `static func identify(answer: String) -> TargetMac?`; `static let helpText: String`. Plus `TargetMacPicker.ask(readLine:print:) -> TargetMac?` in the executable.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MacOSInstallerKit

@Test("every target has a label, a boot method, and no shared boot method")
func targetsHaveDistinctBootMethods() {
    let methods = TargetMac.allCases.map(\.bootMethod)

    for target in TargetMac.allCases {
        #expect(target.label.isEmpty == false)
        #expect(target.bootMethod.isEmpty == false)
    }
    // Apple silicon holds the power button; Intel holds Option. If two targets
    // shared a method the picker would be pointless.
    #expect(Set(methods).count == TargetMac.allCases.count)
}

@Test("Apple silicon boots by holding the power button, not Option")
func appleSiliconUsesPowerButton() {
    let method = TargetMac.appleSilicon.bootMethod.lowercased()

    #expect(method.contains("power button"))
    #expect(method.contains("option") == false)
}

@Test("both Intel targets boot by holding Option")
func intelTargetsUseOption() {
    for target in [TargetMac.intelT2, TargetMac.intelPreT2] {
        #expect(target.bootMethod.lowercased().contains("option"))
    }
}

@Test("only the T2 target needs Startup Security Utility")
func onlyT2NeedsStartupSecurityUtility() {
    #expect(TargetMac.intelT2.requiresStartupSecurityUtility)
    #expect(TargetMac.appleSilicon.requiresStartupSecurityUtility == false)
    #expect(TargetMac.intelPreT2.requiresStartupSecurityUtility == false)
}

@Test("identify accepts the menu numbers")
func identifyAcceptsNumbers() {
    #expect(TargetMac.identify(answer: "1") == .appleSilicon)
    #expect(TargetMac.identify(answer: "2") == .intelT2)
    #expect(TargetMac.identify(answer: "3") == .intelPreT2)
}

@Test("identify accepts plain-language answers a beginner would actually type")
func identifyAcceptsWords() {
    #expect(TargetMac.identify(answer: "apple silicon") == .appleSilicon)
    #expect(TargetMac.identify(answer: "M1") == .appleSilicon)
    #expect(TargetMac.identify(answer: "m2") == .appleSilicon)
    #expect(TargetMac.identify(answer: "  Intel  ") == nil)  // ambiguous: which Intel?
}

@Test("identify rejects an answer it cannot resolve rather than guessing")
func identifyRejectsUnknown() {
    // Guessing here would send the user the wrong boot instructions and they
    // would conclude the stick is broken.
    #expect(TargetMac.identify(answer: "") == nil)
    #expect(TargetMac.identify(answer: "a macbook") == nil)
    #expect(TargetMac.identify(answer: "4") == nil)
}

@Test("help text explains how to find out, without jargon")
func helpTextIsUsable() {
    let help = TargetMac.helpText

    // Names the actual menu item a user clicks.
    #expect(help.contains("About This Mac"))
    #expect(help.lowercased().contains("apple menu"))
    // Copy rules: no blaming language.
    for banned in ["simply", "just ", "obviously"] {
        #expect(help.lowercased().contains(banned) == false)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter TargetMacTests`
Expected: FAIL — `cannot find 'TargetMac' in scope`

- [ ] **Step 3: Write the model**

```swift
import Foundation

/// Which Mac will boot the finished installer.
///
/// This is NOT the Mac running this tool. Writing Mojave media on an Apple
/// silicon Mac for a 2015 Intel MacBook is the expected case, and the two boot
/// in completely different ways — so the after-steps depend on this answer and
/// nothing else.
public enum TargetMac: String, CaseIterable, Sendable {
    case appleSilicon
    case intelT2
    case intelPreT2

    public var label: String {
        switch self {
        case .appleSilicon: return "A Mac with Apple silicon (M1, M2, M3, M4…)"
        case .intelT2: return "An Intel Mac from 2018 or later"
        case .intelPreT2: return "An Intel Mac from 2017 or earlier"
        }
    }

    /// One sentence naming the physical action. Deliberately different per
    /// target: a reader should never have to work out which half applies.
    public var bootMethod: String {
        switch self {
        case .appleSilicon:
            return "Press and hold the power button until you see a screen of startup options."
        case .intelT2, .intelPreT2:
            return "Turn the Mac on and immediately hold the Option key until you see the startup drives."
        }
    }

    /// 2018-and-later Intel Macs refuse to boot from external media until
    /// Startup Security Utility is changed.
    public var requiresStartupSecurityUtility: Bool {
        self == .intelT2
    }

    public static let helpText = """
    How to find out which Mac you have:

      1. On the Mac you want to install macOS onto, click the Apple menu
         in the top-left corner of the screen
      2. Click "About This Mac"
      3. Look for "Chip" or "Processor"

    If it says Apple M1, M2, M3 or M4, choose option 1.
    If it says Intel and the Mac is from 2018 or later, choose option 2.
    If it says Intel and the Mac is from 2017 or earlier, choose option 3.

    If that Mac won't turn on at all, the year is usually printed in the
    About This Mac window of any Mac it was set up from, or on the original
    receipt or box.
    """

    /// Resolves a typed answer, or nil when it cannot be resolved confidently.
    ///
    /// Returning nil for an ambiguous answer is deliberate: a wrong guess sends
    /// the user the wrong boot instructions, and they conclude the stick is
    /// broken rather than that they answered unclearly.
    public static func identify(answer: String) -> TargetMac? {
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }

        switch cleaned {
        case "1": return .appleSilicon
        case "2": return .intelT2
        case "3": return .intelPreT2
        default: break
        }

        if cleaned.contains("apple silicon") || cleaned.range(of: #"^m[1-4]$"#, options: .regularExpression) != nil {
            return .appleSilicon
        }
        // "intel" alone is ambiguous — which era? — so it is not accepted.
        if cleaned.contains("t2") || cleaned.contains("2018") || cleaned.contains("2019") || cleaned.contains("2020") {
            return .intelT2
        }
        if cleaned.contains("2017") || cleaned.contains("2016") || cleaned.contains("2015")
            || cleaned.contains("2014") || cleaned.contains("2013") || cleaned.contains("2012") {
            return .intelPreT2
        }

        return nil
    }
}
```

- [ ] **Step 4: Write the picker**

`Sources/macos-installer/TargetMacPicker.swift` — terminal I/O only, no content of its own:

```swift
import Foundation
import MacOSInstallerKit

/// Asks which Mac will boot the finished installer. Re-asks on an answer it
/// cannot resolve, and offers help rather than guessing.
enum TargetMacPicker {
    static func ask(
        readLine: () -> String? = { Swift.readLine(strippingNewline: true) },
        emit: (String) -> Void = { Swift.print($0) },
        maximumAttempts: Int = 3
    ) -> TargetMac? {
        emit("")
        emit("  Which Mac will you boot this installer on?")
        emit("  (This is the Mac you want to install macOS onto — not necessarily this one.)")
        emit("")
        for (index, target) in TargetMac.allCases.enumerated() {
            emit("    \(index + 1). \(target.label)")
        }
        emit("    ?. I'm not sure — help me find out")
        emit("")

        for _ in 0..<maximumAttempts {
            emit("  Type 1, 2, 3, or ? : ")
            guard let answer = readLine() else { return nil }

            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "?" {
                emit("")
                emit(TargetMac.helpText)
                emit("")
                continue
            }
            if let target = TargetMac.identify(answer: answer) {
                return target
            }
            emit("  That didn't match one of the options. Type 1, 2, 3, or ? for help.")
        }

        return nil
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `./scripts/test.sh --filter TargetMacTests`
Expected: PASS, 8 tests

- [ ] **Step 6: Commit**

```bash
git add Sources/MacOSInstallerKit/Guidance Sources/macos-installer/TargetMacPicker.swift Tests/MacOSInstallerKitTests/TargetMacTests.swift
git commit -m "feat: ask which Mac will boot the installer"
```

---

### Task 6: GuidanceCatalog

Stage content as structured data keyed by stage and target, so it is testable and editable without touching control flow. The spec requires exactly this rather than `print()` calls scattered through the command.

**Files:**
- Create: `Sources/MacOSInstallerKit/Guidance/GuidanceCatalog.swift`
- Test: `Tests/MacOSInstallerKitTests/GuidanceCatalogTests.swift`

**Interfaces:**
- Consumes: `TargetMac` (Task 5).
- Produces: `enum GuidanceStage { case before, during, after }`; `struct GuidanceSection { let heading: String; let body: [String]; let steps: [String] }`; `GuidanceCatalog.sections(for stage: GuidanceStage, target: TargetMac, installerName: String, driveName: String?) -> [GuidanceSection]`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MacOSInstallerKit

@Test("the before stage names the hardware, the erase, and the time")
func beforeStageCoversPreconditions() {
    let sections = GuidanceCatalog.sections(
        for: .before, target: .intelPreT2, installerName: "macOS Tahoe", driveName: nil
    )
    let all = sections.flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n")

    #expect(all.contains("32 GB"))
    #expect(all.lowercased().contains("erase"))
    // An honest duration, so nobody assumes it has frozen after five minutes.
    #expect(all.contains("minutes") || all.contains("hour"))
}

@Test("the before stage warns that the target Mac needs internet during installation")
func beforeStageMentionsTargetInternet() {
    let sections = GuidanceCatalog.sections(
        for: .before, target: .appleSilicon, installerName: "macOS Tahoe", driveName: nil
    )
    let all = sections.flatMap { $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(all.contains("internet") || all.contains("wi-fi"))
}

@Test("the during stage pre-announces the invisible password and the permission dialog")
func duringStagePreAnnouncesSurprises() {
    let sections = GuidanceCatalog.sections(
        for: .during, target: .appleSilicon, installerName: "macOS Tahoe", driveName: "SanDisk Ultra"
    )
    let all = sections.flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

    // Apple documents both. Announcing them afterwards is useless — the point
    // is that the user is not surprised.
    #expect(all.contains("no characters") || all.contains("nothing appear"))
    #expect(all.contains("removable volume") || all.contains("permission"))
}

@Test("the after stage gives only the selected target's boot method")
func afterStageIsSingleTarget() {
    let silicon = GuidanceCatalog.sections(
        for: .after, target: .appleSilicon, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
    ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(silicon.contains("power button"))
    // No branch for the reader to misparse.
    #expect(silicon.contains("option key") == false)

    let intel = GuidanceCatalog.sections(
        for: .after, target: .intelPreT2, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
    ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(intel.contains("option"))
    #expect(intel.contains("power button") == false)
}

@Test("the after stage includes the Startup Security Utility step for a T2 target only")
func afterStageIncludesT2Caveat() {
    func afterText(_ target: TargetMac) -> String {
        GuidanceCatalog.sections(
            for: .after, target: target, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
        ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n")
    }

    #expect(afterText(.intelT2).contains("Startup Security Utility"))
    #expect(afterText(.appleSilicon).contains("Startup Security Utility") == false)
    #expect(afterText(.intelPreT2).contains("Startup Security Utility") == false)
}

@Test("the after stage explains the circle with a line through it")
func afterStageExplainsIncompatibilitySymbol() {
    let all = GuidanceCatalog.sections(
        for: .after, target: .intelPreT2, installerName: "macOS Mojave", driveName: "Install macOS Mojave"
    ).flatMap { $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(all.contains("circle with a line"))
}

@Test("the after stage names the renamed drive, since the user's drive name changed")
func afterStageNamesRenamedDrive() {
    let all = GuidanceCatalog.sections(
        for: .after, target: .appleSilicon, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
    ).flatMap { $0.body + $0.steps }.joined(separator: "\n")

    // Apple renames the volume on success. A user looking for "SanDisk Ultra"
    // in the startup picker will not find it.
    #expect(all.contains("Install macOS Tahoe"))
}

@Test("no stage uses language that blames the reader")
func noStageBlamesTheReader()  {
    for stage in [GuidanceStage.before, .during, .after] {
        for target in TargetMac.allCases {
            let text = GuidanceCatalog.sections(
                for: stage, target: target, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
            ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

            for banned in ["simply", "just ", "obviously", "merely"] {
                #expect(text.contains(banned) == false, "\(stage)/\(target) contains '\(banned)'")
            }
        }
    }
}

@Test("every stage returns at least one section for every target")
func everyStageHasContentForEveryTarget() {
    for stage in [GuidanceStage.before, .during, .after] {
        for target in TargetMac.allCases {
            let sections = GuidanceCatalog.sections(
                for: stage, target: target, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
            )
            #expect(sections.isEmpty == false, "\(stage)/\(target) has no content")
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter GuidanceCatalogTests`
Expected: FAIL — `cannot find 'GuidanceCatalog' in scope`

- [ ] **Step 3: Write the catalog**

Content is data. Write all three stages for all three targets. The `after` stage must branch on target and include the T2 caveat only for `.intelT2`. Structure:

```swift
import Foundation

public enum GuidanceStage: Sendable {
    case before
    case during
    case after
}

/// One titled block of guidance. `body` is prose; `steps` is numbered actions.
public struct GuidanceSection: Equatable, Sendable {
    public let heading: String
    public let body: [String]
    public let steps: [String]

    public init(heading: String, body: [String] = [], steps: [String] = []) {
        self.heading = heading
        self.body = body
        self.steps = steps
    }
}

/// All the words the walkthrough says, as data.
///
/// Keeping this out of control flow is a spec requirement: it makes the copy
/// testable (the tests assert that the password surprise is pre-announced and
/// that the after-stage contains only the selected target's instructions), and
/// editable without reading the command.
public enum GuidanceCatalog {
    public static func sections(
        for stage: GuidanceStage,
        target: TargetMac,
        installerName: String,
        driveName: String?
    ) -> [GuidanceSection] {
        switch stage {
        case .before: return before(installerName: installerName)
        case .during: return during(driveName: driveName)
        case .after: return after(target: target, installerName: installerName, driveName: driveName)
        }
    }

    private static func before(installerName: String) -> [GuidanceSection] {
        [
            GuidanceSection(
                heading: "Before you start",
                body: [
                    "You'll be making a USB drive that can install \(installerName) onto a Mac.",
                ],
                steps: [
                    "Find a USB drive that holds 32 GB or more — any brand is fine",
                    "Copy anything you want to keep off that drive first, onto this Mac's desktop",
                    "Plug the drive into this Mac",
                ]
            ),
            GuidanceSection(
                heading: "Two things to know",
                body: [
                    "Everything on that USB drive will be erased. There is no undo.",
                    "This takes roughly 30 to 60 minutes, most of it downloading. "
                        + "You can leave it running.",
                    "The Mac you install onto will need to be connected to the internet, "
                        + "because the installer downloads a few things specific to that model.",
                ]
            ),
        ]
    }

    private static func during(driveName: String?) -> [GuidanceSection] {
        let drive = driveName ?? "your drive"
        return [
            GuidanceSection(
                heading: "What happens now",
                steps: [
                    "macOS asks for your password — see the note below",
                    "The installer downloads from Apple (this is the slow part)",
                    "The download is checked to make sure it arrived intact",
                    "\(drive) is erased and the installer is written to it",
                ]
            ),
            GuidanceSection(
                heading: "Two things that look like problems but aren't",
                body: [
                    "When macOS asks for your password, no characters appear as you type — "
                        + "not even dots. That is normal. Type it and press Return.",
                    "A box may appear saying \"Terminal would like to access files on a "
                        + "removable volume\". Click OK. If you don't, writing the drive fails.",
                ]
            ),
        ]
    }

    private static func after(
        target: TargetMac,
        installerName: String,
        driveName: String?
    ) -> [GuidanceSection] {
        let volume = driveName ?? "Install \(installerName)"
        var sections: [GuidanceSection] = [
            GuidanceSection(
                heading: "Your installer is ready",
                body: [
                    "The USB drive is now named \"\(volume)\". "
                        + "That is the name you'll look for when starting up.",
                ]
            )
        ]

        var bootSteps = [
            "Shut the other Mac down completely",
            "Plug this USB drive directly into that Mac — not through a hub",
        ]

        switch target {
        case .appleSilicon:
            bootSteps += [
                "Press and hold the power button, and keep holding it",
                "Keep holding until a screen of startup options appears",
                "Click \"\(volume)\", then click Continue",
                "Follow the instructions on screen to install macOS",
            ]
        case .intelT2, .intelPreT2:
            bootSteps += [
                "Turn the Mac on and immediately hold the Option key",
                "Keep holding Option until you see the startup drives",
                "Select \"\(volume)\" and press Return",
                "Choose your language if asked",
                "Select \"Install macOS\" and click Continue",
            ]
        }

        sections.append(
            GuidanceSection(heading: "Starting up from the drive", steps: bootSteps)
        )

        if target.requiresStartupSecurityUtility {
            sections.append(
                GuidanceSection(
                    heading: "One extra step for your Mac",
                    body: [
                        "Intel Macs from 2018 and later refuse to start from a USB drive "
                            + "until you allow it.",
                    ],
                    steps: [
                        "If the drive doesn't appear, hold Command-R at startup instead",
                        "From the menu bar choose Utilities, then Startup Security Utility",
                        "Set \"Allow booting from external or removable media\"",
                        "Restart and hold Option again",
                    ]
                )
            )
        }

        sections.append(
            GuidanceSection(
                heading: "If something goes wrong",
                body: [
                    "If you see a circle with a line through it, that macOS version "
                        + "cannot run on that Mac. You'll need a different version.",
                    "If the drive doesn't appear at all, try a different USB port, "
                        + "and plug it in directly rather than through a hub or dock.",
                ]
            )
        )

        return sections
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter GuidanceCatalogTests`
Expected: PASS, 9 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Guidance/GuidanceCatalog.swift Tests/MacOSInstallerKitTests/GuidanceCatalogTests.swift
git commit -m "feat: add guidance content as structured data"
```

---

### Task 7: InstructionExporter

The after-steps are worthless in a terminal the user is about to close before walking to another machine. On success the tool writes them to a file they can carry.

**Files:**
- Create: `Sources/MacOSInstallerKit/Guidance/InstructionExporter.swift`
- Test: `Tests/MacOSInstallerKitTests/InstructionExporterTests.swift`

**Interfaces:**
- Consumes: `TargetMac`, `GuidanceCatalog`, `GuidanceSection`.
- Produces: `InstructionExporter(directory:)` with `func export(target:installerName:driveName:) throws -> URL`; `static var defaultDirectory: URL` (the Desktop); `ExportError.cannotWrite(String)`.

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

@Test("writes a Markdown file named after the installer")
func writesNamedFile() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(
        target: .intelPreT2, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
    )

    #expect(url.lastPathComponent == "How to use your macOS Tahoe installer.md")
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test("the file contains the selected target's boot steps and not the other target's")
func fileIsSingleTarget() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(
        target: .appleSilicon, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
    )
    let text = try String(contentsOf: url, encoding: .utf8).lowercased()

    #expect(text.contains("power button"))
    #expect(text.contains("option key") == false)
}

@Test("the file includes the T2 extra step for a T2 target")
func fileIncludesT2Step() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(
        target: .intelT2, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
    )

    #expect(try String(contentsOf: url, encoding: .utf8).contains("Startup Security Utility"))
}

@Test("the file includes the troubleshooting section, since nobody reads it until it's needed")
func fileIncludesTroubleshooting() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(
        target: .intelPreT2, installerName: "macOS Mojave", driveName: "Install macOS Mojave"
    )

    #expect(try String(contentsOf: url, encoding: .utf8).contains("circle with a line"))
}

@Test("overwrites a previous export rather than failing or creating a duplicate")
func overwritesPreviousExport() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let exporter = InstructionExporter(directory: dir)

    let first = try exporter.export(
        target: .appleSilicon, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
    )
    let second = try exporter.export(
        target: .intelPreT2, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
    )

    #expect(first == second)
    let text = try String(contentsOf: second, encoding: .utf8).lowercased()
    // The second export's target won, rather than both being concatenated.
    #expect(text.contains("option key"))
    #expect(text.contains("power button") == false)
}

@Test("throws cannotWrite rather than crashing when the directory is unusable")
func throwsOnUnwritableDirectory() {
    let exporter = InstructionExporter(directory: URL(fileURLWithPath: "/dev/null/nope"))

    #expect(throws: ExportError.self) {
        _ = try exporter.export(
            target: .appleSilicon, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
        )
    }
}

@Test("a slash in the installer name cannot escape the target directory")
func sanitisesFileName() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(
        target: .appleSilicon, installerName: "macOS/../../Tahoe", driveName: "X"
    )

    // Whatever the name becomes, it must stay inside `dir`.
    #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter InstructionExporterTests`
Expected: FAIL — `cannot find 'InstructionExporter' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public enum ExportError: Error, Equatable {
    case cannotWrite(String)
}

/// Writes the after-steps to a file the user can carry to the other Mac.
///
/// The boot instructions are useless in a terminal window someone is about to
/// close before walking across the room, which is exactly what they do next.
public struct InstructionExporter {
    private let directory: URL

    public init(directory: URL = InstructionExporter.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    @discardableResult
    public func export(
        target: TargetMac,
        installerName: String,
        driveName: String?
    ) throws -> URL {
        let sections = GuidanceCatalog.sections(
            for: .after, target: target, installerName: installerName, driveName: driveName
        )

        var lines = ["# How to use your \(installerName) installer", ""]
        for section in sections {
            lines.append("## \(section.heading)")
            lines.append("")
            for paragraph in section.body {
                lines.append(paragraph)
                lines.append("")
            }
            for (index, step) in section.steps.enumerated() {
                lines.append("\(index + 1). \(step)")
            }
            if !section.steps.isEmpty { lines.append("") }
        }

        let name = "How to use your \(sanitised(installerName)) installer.md"
        let url = directory.appendingPathComponent(name)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        } catch {
            throw ExportError.cannotWrite(error.localizedDescription)
        }

        return url
    }

    /// Strips path separators so a release name can never escape the directory.
    private func sanitised(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test.sh --filter InstructionExporterTests`
Expected: PASS, 7 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/MacOSInstallerKit/Guidance/InstructionExporter.swift Tests/MacOSInstallerKitTests/InstructionExporterTests.swift
git commit -m "feat: export boot instructions the user can carry away"
```

---

### Task 8: Wire the walkthrough into `create`

**Files:**
- Create: `Sources/macos-installer/WalkthroughPresenter.swift`
- Modify: `Sources/macos-installer/CreateCommand.swift`
- Test: `Tests/MacOSInstallerKitTests/GuidanceRenderingTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `WalkthroughPresenter.render(_ sections: [GuidanceSection]) -> String` — but put the rendering in the LIBRARY as `GuidanceRenderer.render(_:)` so it is covered by tests, and keep `WalkthroughPresenter` as the thin printing wrapper.

**Order of operations in `create`:** the target Mac is asked FIRST, then the Before stage, then version and volume selection, then the typed confirmation, then the During stage, then the work, then the After stage plus the export. `--brief` skips the target question and all three stages.

⚠️ Smoke-test read-only only: `create --help`, and `create` with no `--volume`. Never pass `--volume`.

- [ ] **Step 1: Write the failing test for the renderer**

```swift
import Testing
@testable import MacOSInstallerKit

@Test("renders headings, prose and numbered steps in order")
func rendersSectionsInOrder() {
    let output = GuidanceRenderer.render([
        GuidanceSection(
            heading: "Before you start",
            body: ["You'll be making a USB drive."],
            steps: ["Find a USB drive", "Plug it in"]
        )
    ])

    let headingAt = try! #require(output.range(of: "Before you start"))
    let bodyAt = try! #require(output.range(of: "You'll be making"))
    let stepAt = try! #require(output.range(of: "1. Find a USB drive"))

    #expect(headingAt.lowerBound < bodyAt.lowerBound)
    #expect(bodyAt.lowerBound < stepAt.lowerBound)
    #expect(output.contains("2. Plug it in"))
}

@Test("renders a section with no steps without an empty list")
func rendersBodyOnlySection() {
    let output = GuidanceRenderer.render([
        GuidanceSection(heading: "Two things to know", body: ["Everything will be erased."])
    ])

    #expect(output.contains("Everything will be erased."))
    #expect(output.contains("1.") == false)
}

@Test("renders nothing for an empty section list")
func rendersEmptyForNoSections() {
    #expect(GuidanceRenderer.render([]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter GuidanceRenderingTests`
Expected: FAIL — `cannot find 'GuidanceRenderer' in scope`

- [ ] **Step 3: Write the renderer in the library**

Add `Sources/MacOSInstallerKit/Guidance/GuidanceRenderer.swift`:

```swift
import Foundation

/// Turns guidance sections into terminal text. In the library so the formatting
/// is covered by tests; the executable only prints what this returns.
public enum GuidanceRenderer {
    public static func render(_ sections: [GuidanceSection]) -> String {
        var blocks: [String] = []

        for section in sections {
            var block = ["  \(section.heading)", "  " + String(repeating: "─", count: section.heading.count)]
            for paragraph in section.body {
                block.append("")
                block.append(wrap(paragraph))
            }
            if !section.steps.isEmpty {
                block.append("")
                for (index, step) in section.steps.enumerated() {
                    block.append("    \(index + 1). \(step)")
                }
            }
            blocks.append(block.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n")
    }

    /// Soft-wraps prose at a width that reads comfortably in a default terminal.
    private static func wrap(_ text: String, width: Int = 68) -> String {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " \(word)"
            } else {
                lines.append("  \(current)")
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append("  \(current)") }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Add the presenter and the `--brief` flag**

`Sources/macos-installer/WalkthroughPresenter.swift`:

```swift
import Foundation
import MacOSInstallerKit

/// Prints guidance. Owns no content and makes no decisions.
enum WalkthroughPresenter {
    static func show(
        _ stage: GuidanceStage,
        target: TargetMac,
        installerName: String,
        driveName: String?,
        emit: (String) -> Void = { Swift.print($0) }
    ) {
        let sections = GuidanceCatalog.sections(
            for: stage, target: target, installerName: installerName, driveName: driveName
        )
        emit("")
        emit(GuidanceRenderer.render(sections))
        emit("")
    }
}
```

In `CreateCommand`, add:

```swift
    @Flag(name: .long, help: "Skip the guided walkthrough and print only what's necessary.")
    var brief = false
```

Then wire the order described above. When `brief` is false and the run is interactive, ask for the target Mac before anything else; if the picker returns nil (the user could not answer), say so and continue in brief mode rather than refusing to work. After a successful write, show the After stage and export the file, printing the exported path.

- [ ] **Step 5: Run the suite and smoke-test read-only**

Run: `./scripts/test.sh`
Run: `swift build && swift run macos-installer create --help`
Confirm `--brief` appears in the help output. Paste both into your report.
Do NOT pass `--volume`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: show the guided walkthrough during create"
```

---

### Task 9: Network retry and one automatic re-download

Two spec items under Error Handling that Plan 2 left undone: "downloads are resumable; retry with backoff" and "checksum mismatch — discard, re-download once, then fail".

**Files:**
- Modify: `Sources/MacOSInstallerKit/Download/Downloader.swift`
- Modify: `Sources/MacOSInstallerKit/Assembly/InstallerPreparer.swift`
- Test: `Tests/MacOSInstallerKitTests/DownloaderTests.swift`, `InstallerPreparerTests.swift`

**Interfaces:**
- Consumes: `ResumableTransfer`, `Downloader`, `DigestVerifier`.
- Produces: `Downloader(transfer:fileManager:maximumAttempts:backoff:)` where `backoff: @Sendable (Int) -> Duration`; `InstallerPreparer` retrying once on digest mismatch.

- [ ] **Step 1: Write the failing test**

```swift
@Test("retries a failing transfer up to the attempt limit, then throws")
func retriesThenThrows() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    struct Boom: Error {}
    let transfer = FakeTransfer(payload: Data("0123456789".utf8), error: Boom())

    await #expect(throws: (any Error).self) {
        _ = try await Downloader(
            transfer: transfer, maximumAttempts: 3, backoff: { _ in .zero }
        ).download(from: remote, to: destination, expectedBytes: 10) { _, _ in }
    }

    // Three attempts, not one.
    #expect(transfer.offsets.count == 3)
}

@Test("a retry resumes from the partial file rather than restarting")
func retryResumesFromPartial() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    try Data("012".utf8).write(to: destination)
    struct Boom: Error {}
    let transfer = FakeTransfer(payload: Data("0123456789".utf8), error: Boom())

    _ = try? await Downloader(
        transfer: transfer, maximumAttempts: 2, backoff: { _ in .zero }
    ).download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    // Both attempts start at 3 — restarting an 18 GB download from zero is not
    // a recovery strategy.
    #expect(transfer.offsets == [3, 3])
}

@Test("succeeds without retrying when the first attempt works")
func noRetryOnSuccess() async throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("InstallAssistant.pkg")
    let transfer = FakeTransfer(payload: Data("0123456789".utf8))

    _ = try await Downloader(
        transfer: transfer, maximumAttempts: 3, backoff: { _ in .zero }
    ).download(from: remote, to: destination, expectedBytes: 10) { _, _ in }

    #expect(transfer.offsets.count == 1)
}

@Test("backoff grows with each attempt")
func backoffGrows() {
    let backoff = Downloader.defaultBackoff
    #expect(backoff(1) < backoff(2))
    #expect(backoff(2) < backoff(3))
}
```

Add to `InstallerPreparerTests`:

```swift
@Test("re-downloads once on a digest mismatch before giving up")
func reDownloadsOnceOnDigestMismatch() async throws {
    // A transfer that yields corrupt bytes both times: the preparer must make
    // TWO download attempts before failing, per the spec.
    // ... construct with a fake transfer and a digest that never matches
    #expect(transfer.attemptCount == 2)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test.sh --filter "DownloaderTests|InstallerPreparerTests"`
Expected: FAIL — no `maximumAttempts` parameter.

- [ ] **Step 3: Implement retry in `Downloader`**

Add `maximumAttempts: Int = 3` and `backoff: @Sendable (Int) -> Duration = Downloader.defaultBackoff` to the initializer. Wrap the transfer call in a loop that retries on a thrown error, sleeping `backoff(attempt)` between attempts, and rethrows the last error after the limit. Each attempt must recompute `existingSize` so a partially successful attempt resumes rather than restarting. A `sizeMismatch` after a successful transfer is NOT retried — that is a corrupt or stale file, not a transient network failure, and Plan 2 already deletes it.

```swift
    public static let defaultBackoff: @Sendable (Int) -> Duration = { attempt in
        // 1s, 2s, 4s — short enough not to look hung, long enough to outlast
        // a brief network blip.
        .seconds(1 << (attempt - 1))
    }
```

- [ ] **Step 4: Implement one re-download in `InstallerPreparer`**

On a digest mismatch: delete the package (already implemented), then download and verify once more. If the second attempt also mismatches, fail with the corrupt-download explanation. Do not loop more than twice — a digest that fails twice is not a transient problem.

- [ ] **Step 5: Run to verify it passes**

Run: `./scripts/test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: retry transfers with backoff and re-download once on digest mismatch"
```

---

### Task 10: Carry-forward sweep

Cheap items from `carry-forward.md` that touch files this plan already edits. Each is small; they are batched because they share a review surface.

**Files:**
- Modify: `Tests/MacOSInstallerKitTests/CommandRunnerTests.swift`
- Modify: `Sources/MacOSInstallerKit/Media/InstallMediaWriter.swift`
- Modify: `Sources/MacOSInstallerKit/Disks/VolumeGuard.swift`, `Sources/MacOSInstallerKit/Disks/VolumeTableFormatter.swift`
- Move: `Sources/MacOSInstallerKit/Assembly/InstallerPreparer.swift` → `Sources/MacOSInstallerKit/Pipeline/InstallerPreparer.swift`

- [ ] **Step 1: Bound the deadlock test**

`doesNotDeadlockWhenChildFloodsStderr` currently HANGS rather than failing if the concurrent pipe drain regresses. Add a Swift Testing time limit so a regression fails cleanly:

```swift
@Test("drains both pipes concurrently, so a child that floods stderr cannot deadlock",
      .timeLimit(.minutes(1)))
```

- [ ] **Step 2: Document the residual path-vs-UUID window**

Add to `InstallMediaWriter.write`, above the `createinstallmedia` invocation:

```swift
        // KNOWN, IRREDUCIBLE RACE: every guard above binds a volume UUID, but
        // `createinstallmedia --volume` takes a PATH. Between reading
        // `volume.mountPoint` and createinstallmedia resolving it, an unmount
        // plus a remount of a same-named volume at the same path would erase
        // the wrong drive. It is one exec wide and cannot be closed without an
        // Apple interface that accepts a volume UUID. Real on any machine with
        // two same-named volumes.
```

- [ ] **Step 3: De-duplicate the gigabyte formatter**

`"%.1f GB"` appears in both `VolumeGuard.RefusalReason` and `VolumeTableFormatter`. Extract one internal helper — `ByteSize.gigabytes(_ bytes: Int64) -> String` in `Sources/MacOSInstallerKit/Messages/` — and use it in both. Add a test for the boundary cases: 0, exactly 1 GB, and a 2 TB drive.

- [ ] **Step 4: Move `InstallerPreparer` out of `Assembly/`**

It is an orchestrator, not an `AssemblyStrategy`. `git mv` it to a new `Pipeline/` directory. No behaviour change; the suite must stay green.

- [ ] **Step 5: Run the full suite and CI**

Run: `./scripts/test.sh` then `./scripts/ci.sh`
Expected: green, coverage ≥ 95%.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: bound the deadlock test, document the write race, de-duplicate byte formatting"
```

---

### Task 11: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/manual-verification.md`
- Modify: `docs/superpowers/plans/carry-forward.md`

- [ ] **Step 1: README**

Document the walkthrough and `--brief`. Show what a beginner sees. Keep the "Verified on" section claiming nothing — **the manual-verification checklist still has zero completed rows, so nothing about booting has changed.** Do not soften that section because the tool now explains itself better; explaining and working are different claims.

- [ ] **Step 2: Manual verification rows**

Add to `docs/manual-verification.md`:
- Does the target-Mac question appear before anything else, and does `?` print usable help?
- Does the Before stage appear before the typed confirmation?
- Were the two During-stage surprises actually pre-announced before they happened — the invisible password and the removable-volume dialog?
- Did the After stage show ONLY the selected target's boot method?
- Was `~/Desktop/How to use your <installer> installer.md` written, and are its steps correct for the target you chose?
- Did `--brief` suppress all three stages?
- Did an induced failure produce a three-part message, and did `~/Library/Logs/macos-installer/<date>.log` contain the technical detail?

- [ ] **Step 3: Update carry-forward**

Remove the items this plan completed (the untimed deadlock test, the path-vs-UUID documentation, the duplicated formatter, `InstallerPreparer`'s location, retry with backoff, re-download once, the log directory, the structured error type). Leave the rest: Time Machine via `APFSVolumeRole`, mounted disk images, `CommandRunner` cancellation, `AssemblyStrategy` not used as a strategy, `ConfirmationPrompt` whitespace, `selectRelease` first-match.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs: document the walkthrough and extend manual verification"
```

---

## Self-Review

**Spec coverage.** Guided Walkthrough: target picker (Task 5), three stages as structured data (Task 6), export (Task 7), `--brief` and ordering (Task 8). Error Handling: three-part format (Task 1), `~/Library/Logs/macos-installer/` (Task 2), uniform application (Tasks 3–4), retry with backoff and one re-download (Task 9). Remaining spec items for Plan 4: legacy ESD assembly. **One gap I am leaving deliberately:** the spec's error example shows a "Couldn't erase the drive" message with a Disk Utility recipe for Apple's documented erase failure. `MediaWriteError.writeFailedDriveStateUnknown` covers the post-erase case, but Apple's *pre-erase* "can't erase" failure is not a distinct case in our enum — it arrives inside that one. Splitting it needs a stderr pattern match on `createinstallmedia` output, which is unverified until the manual checklist runs. Recorded in carry-forward rather than guessed at.

**Placeholder scan.** One deliberate soft spot: Task 9's `reDownloadsOnceOnDigestMismatch` test body is a sketch rather than complete code, because the fake needs an attempt counter that does not exist yet and the shape depends on how the implementer threads it. The assertion is specified exactly (`attemptCount == 2`); the construction is not. Flagged here rather than left to look finished.

**Type consistency.** `UserFacingError`'s five fields are identical across Tasks 1, 3, 4. `Explainable` requires `explanation` and `technicalDetail` in Tasks 3, 4. `TargetMac`'s three cases and `requiresStartupSecurityUtility` match across Tasks 5, 6, 7. `GuidanceSection(heading:body:steps:)` matches across Tasks 6, 7, 8. `GuidanceCatalog.sections(for:target:installerName:driveName:)` keeps the same four labels in Tasks 6, 7, 8. `DiagnosticLog.record` returns `String?` in Tasks 2, 3, 4.

**One risk worth naming.** Task 4 deletes two formatters and ports their tests. That is the step where an honesty assertion could be dropped silently — the ones proving a pre-write error says the drive was untouched, and that the unknown-state error does not imply a retry. The task says not to drop them and Step 8 mutation-checks the most important one, but a reviewer should count assertions before and after.

## Plan Sequence

| Plan | Scope | Status |
|---|---|---|
| 1. Version discovery | Sources, merge, `list` | Complete — PR #1 |
| 2. Media creation | Download, guard, write, `create` | Complete — PR #2 |
| **3. Guided walkthrough** | This document — errors, logging, target picker, stages, export | Ready |
| 4. Legacy ESD | Opens with the reassembly spike; completes v1 | Not written |
