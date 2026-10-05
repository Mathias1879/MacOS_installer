import Foundation
import Testing
@testable import MacOSInstallerKit

/// `export` deliberately drops the brief's `driveName` parameter. The `.after`
/// stage it renders derives "Install <installerName>" itself and ignores
/// `originalDriveName` entirely (see `GuidanceCatalog.after(target:installerName:)`),
/// so a drive name here would be dead weight a caller could pass wrong for a
/// value nothing ever reads — see `InstructionExporter.export(target:installerName:)`.
///
/// `isDirectory: true` matters here: without it, Foundation represents the
/// resulting URL without a trailing slash, and `url.deletingLastPathComponent()`
/// elsewhere then disagrees with `dir.standardizedFileURL` on representation
/// alone — a spurious failure with no path difference behind it.
private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Asserts the export either succeeds with a file written INSIDE `dir`, or
/// throws `ExportError.cannotWrite` — anything else (a crash, a different
/// error type, a file outside `dir`) is a failure of Finding 4's safety
/// property for boundary inputs at this trust boundary.
private func assertSafeOutcome(installerName: String, target: TargetMac, in dir: URL) throws {
    do {
        let url = try InstructionExporter(directory: dir).export(target: target, installerName: installerName)
        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
    } catch let error as ExportError {
        switch error {
        case .cannotWrite: break // acceptable: rejected by the write, not a crash
        }
    }
}

@Test("writes a Markdown file named after the installer and the target")
func writesNamedFile() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(target: .intelPreT2, installerName: "macOS Tahoe")

    #expect(url.lastPathComponent == "How to use your macOS Tahoe installer (intelPreT2).md")
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test("the file contains the selected target's boot steps and not the other target's")
func fileIsSingleTarget() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(target: .appleSilicon, installerName: "macOS Tahoe")
    let text = try String(contentsOf: url, encoding: .utf8).lowercased()

    #expect(text.contains("power button"))
    #expect(text.contains("option key") == false)
}

@Test("the file includes the T2 extra step for a T2 target")
func fileIncludesT2Step() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(target: .intelT2, installerName: "macOS Tahoe")

    #expect(try String(contentsOf: url, encoding: .utf8).contains("Startup Security Utility"))
}

@Test("the file includes the troubleshooting section, since nobody reads it until it's needed")
func fileIncludesTroubleshooting() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(target: .intelPreT2, installerName: "macOS Mojave")

    #expect(try String(contentsOf: url, encoding: .utf8).contains("circle with a line"))
}

@Test("overwrites a previous export for the same installer and the same target")
func overwritesPreviousExport() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let exporter = InstructionExporter(directory: dir)

    let first = try exporter.export(target: .appleSilicon, installerName: "macOS Tahoe")
    let second = try exporter.export(target: .appleSilicon, installerName: "macOS Tahoe")

    #expect(first == second)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
}

@Test("exporting for two different targets from the same installer name produces two distinct files, both still present")
func differentTargetsProduceDistinctFiles() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let exporter = InstructionExporter(directory: dir)

    let first = try exporter.export(target: .appleSilicon, installerName: "macOS Tahoe")
    let second = try exporter.export(target: .intelPreT2, installerName: "macOS Tahoe")

    // Neither export destroyed the other: two distinct paths, both on disk.
    #expect(first != second)
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))

    let firstText = try String(contentsOf: first, encoding: .utf8).lowercased()
    let secondText = try String(contentsOf: second, encoding: .utf8).lowercased()
    #expect(firstText.contains("power button"))
    #expect(secondText.contains("option key"))
}

@Test("throws cannotWrite rather than crashing when the directory is unusable")
func throwsOnUnwritableDirectory() {
    let exporter = InstructionExporter(directory: URL(fileURLWithPath: "/dev/null/nope"))

    #expect(throws: ExportError.self) {
        _ = try exporter.export(target: .appleSilicon, installerName: "macOS Tahoe")
    }
}

@Test("a slash in the installer name cannot escape the target directory")
func sanitisesFileName() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(
        target: .appleSilicon, installerName: "macOS/../../Tahoe"
    )

    // Whatever the name becomes, it must stay inside `dir`.
    #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)

    // Strengthened per Task 7's resolutions: the assertion above alone would
    // also pass for a sanitiser that strips the name down to nothing, which
    // would either produce a dotfile or fail the write outright. Require a
    // real, non-empty, readable file with the expected content instead.
    #expect(url.lastPathComponent.isEmpty == false)
    let text = try String(contentsOf: url, encoding: .utf8)
    // The heading now carries the SAME sanitised name as the filename (fix
    // round 1, Finding 1) — the raw, unsanitised name is never shown.
    #expect(text.contains("# How to use your `macOS---Tahoe` installer"))
}

@Test("a newline plus a Markdown image tag in the installer name cannot inject a heading or a live image into the document")
func sanitisesDocumentBodyAgainstMarkdownInjection() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let malicious = "macOS Tahoe\n## Injected heading\n![tracker](https://evil.example.com/pixel.png)"

    let url = try InstructionExporter(directory: dir).export(target: .appleSilicon, installerName: malicious)
    let text = try String(contentsOf: url, encoding: .utf8)

    // No second heading was introduced: the attack's own "##" marker is gone,
    // so this exact injected heading line can never appear.
    #expect(text.contains("## Injected heading") == false)
    // No live (or inert-but-present) image/link syntax reached the document.
    #expect(text.contains("![") == false)
    #expect(text.contains("](") == false)
    // Only the genuine section headings exist — count stays fixed regardless
    // of what the attacker's name contains.
    let headingLines = text.split(separator: "\n").filter { $0.hasPrefix("#") }
    #expect(headingLines.allSatisfy { $0.hasPrefix("# How to use your") || $0.hasPrefix("## ") })
}

@Test("reverting the sanitiser on the document body makes the injection test above fail")
func mutationProofForFinding1() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let malicious = "macOS Tahoe\n## Injected heading\n![tracker](https://evil.example.com/pixel.png)"

    // Reproduce the UNSANITISED heading this project's round-1 code used to
    // write, to prove `sanitisesDocumentBodyAgainstMarkdownInjection` above
    // is a real guard rather than one that always passes.
    let unsanitisedHeader = "# How to use your \(malicious) installer"
    #expect(unsanitisedHeader.contains("## Injected heading"))
    #expect(unsanitisedHeader.contains("![tracker]"))

    // And the fixed exporter does not reproduce either symptom.
    let url = try InstructionExporter(directory: dir).export(target: .appleSilicon, installerName: malicious)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("## Injected heading") == false)
    #expect(text.contains("![tracker]") == false)
}

@Test("NFC and NFD spellings of the same installer name normalise to one file")
func normalisesUnicodeBeforeNaming() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let nfc = "macOS Sequoia caf\u{00E9}" // é as one precomposed scalar
    let nfd = "macOS Sequoia cafe\u{0301}" // "e" + a combining acute accent

    // Visually identical, byte-different — a real catalog could plausibly
    // round-trip the same display name through either form. Swift's `==`
    // already treats NFC and NFD as canonically equivalent, so that is not a
    // strong enough check here; compare the raw UTF-8 bytes instead, which is
    // what the filesystem actually sees before `sanitised(_:)` normalises it.
    #expect(Array(nfc.utf8) != Array(nfd.utf8))

    let first = try InstructionExporter(directory: dir).export(target: .appleSilicon, installerName: nfc)
    let second = try InstructionExporter(directory: dir).export(target: .appleSilicon, installerName: nfd)

    #expect(first == second)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
}

@Test("control characters in the installer name write safely or throw cannotWrite")
func handlesControlCharacters() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try assertSafeOutcome(installerName: "macOS\u{0001}\u{0007}Tahoe", target: .intelT2, in: dir)
}

@Test("a NUL byte in the installer name writes safely or throws cannotWrite")
func handlesNULByte() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    try assertSafeOutcome(installerName: "macOS\u{0000}Tahoe", target: .intelPreT2, in: dir)
}

@Test("an installer name longer than 255 bytes writes safely or throws cannotWrite")
func handlesNameLongerThan255Bytes() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let longName = String(repeating: "a", count: 300)
    #expect(longName.utf8.count > 255)
    try assertSafeOutcome(installerName: longName, target: .appleSilicon, in: dir)
}

@Test("a whitespace-only installer name falls back to readable wording, not a doubled-up word")
func whitespaceOnlyNameFallsBackSensibly() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(target: .appleSilicon, installerName: "   ")

    #expect(url.lastPathComponent.contains("installer installer") == false)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("installer installer") == false)
}

/// Per Finding 5: this exhaustive switch is an intentional compile-time
/// guard, not a runtime assertion — the house pattern for it (see
/// `ExplanationWordingTests.swift`) is a PRIVATE FUNC called from a real
/// `@Test`, so it keeps forcing a review of new `TargetMac` cases without
/// adding a `@Test` that can never fail on its own.
private func exhaustivelyCheckTargetMac(_ target: TargetMac) {
    switch target {
    case .appleSilicon: break
    case .intelT2: break
    case .intelPreT2: break
    }
}

@Test("the document states which Mac the export is for, in words, for every TargetMac case")
func documentStatesTargetForEveryCase() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    for target in TargetMac.allCases {
        exhaustivelyCheckTargetMac(target)

        let url = try InstructionExporter(directory: dir).export(target: target, installerName: "macOS Sequoia")
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(text.contains("This file is for: \(target.label)"))
    }
}
