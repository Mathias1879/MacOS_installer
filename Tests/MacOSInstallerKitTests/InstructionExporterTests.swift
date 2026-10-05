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

@Test("a slash in the installer name cannot escape the target directory, even though the document body shows the name unstripped")
func sanitisesFileName() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(
        target: .appleSilicon, installerName: "macOS/../../Tahoe"
    )

    // Whatever the FILENAME becomes, it must stay inside `dir`.
    #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)

    // Strengthened per Task 7's resolutions: the assertion above alone would
    // also pass for a sanitiser that strips the name down to nothing, which
    // would either produce a dotfile or fail the write outright. Require a
    // real, non-empty, readable file with the expected content instead.
    #expect(url.lastPathComponent.isEmpty == false)

    // Per fix round 2: the aggressive filename sanitiser is filename-only now.
    // The document body goes through only the layer-agnostic (newline/control
    // character) clean, so "/" and ".." — neither of which is a Markdown
    // metacharacter nor a filesystem escape risk once it's just text in a
    // file body — survive into the heading exactly as given.
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("# How to use your macOS/../../Tahoe installer"))
}

/// True when `target` appears in `text` without an immediately preceding
/// `\`. Fix round 3 narrows the escaped set to six characters and
/// deliberately stops escaping `#`, relying instead on the structural fact
/// that a heading only forms at the START of a line — so the injection
/// tests below check for an unescaped BRACKET (which would mean a real
/// link/image could form) rather than for the literal substring the name
/// contained, which may now survive mid-line as inert text.
private func hasUnescapedCharacter(_ target: Character, in text: String) -> Bool {
    var previousWasBackslash = false
    for character in text {
        if character == target, !previousWasBackslash {
            return true
        }
        previousWasBackslash = character == "\\"
    }
    return false
}

@Test("a newline plus a Markdown image tag in the installer name cannot inject a heading or a live image into the document")
func sanitisesDocumentBodyAgainstMarkdownInjection() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let malicious = "macOS Tahoe\n## Injected heading\n![tracker](https://evil.example.com/pixel.png)"

    let url = try InstructionExporter(directory: dir).export(target: .appleSilicon, installerName: malicious)
    let text = try String(contentsOf: url, encoding: .utf8)

    // No second heading LINE was introduced. The attacker's newline was
    // stripped before rendering, so its "##" marker can only land mid-line —
    // never at the start of a physical line, which is the only place
    // CommonMark treats "#" as heading syntax. Every line starting with "#"
    // is still either this document's own title or a genuine "## " section
    // heading.
    let headingLines = text.split(separator: "\n").filter { $0.hasPrefix("#") }
    #expect(headingLines.allSatisfy { $0.hasPrefix("# How to use your") || $0.hasPrefix("## ") })

    // No live image/link syntax reached the document: every "[" and "]" that
    // came from the attacker's name is backslash-escaped, so CommonMark can
    // never pair them into `[text](url)` or `![alt](url)` — regardless of
    // the unescaped "(" and ")" sitting next to them.
    #expect(hasUnescapedCharacter("[", in: text) == false)
    #expect(hasUnescapedCharacter("]", in: text) == false)
}

@Test("reverting the sanitiser on the document body makes the injection test above fail")
func mutationProofForFinding1() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let malicious = "macOS Tahoe\n## Injected heading\n![tracker](https://evil.example.com/pixel.png)"

    // Reproduce the UNSANITISED header this project's round-1 code used to
    // write — it kept the attacker's newlines, so "##" actually lands at the
    // start of its own line, which is what makes it a real CommonMark
    // heading rather than three inert words of body text.
    let unsanitisedHeader = "# How to use your \(malicious) installer"
    let unsanitisedHeadingLines = unsanitisedHeader.split(separator: "\n").filter { $0.hasPrefix("#") }
    #expect(unsanitisedHeadingLines.contains("## Injected heading"))
    #expect(unsanitisedHeader.contains("![tracker]"))

    // The fixed exporter strips the newlines before this text is ever built,
    // so the same raw ingredients land mid-line instead of at a line start,
    // and the brackets are escaped so no live link/image syntax can form.
    let url = try InstructionExporter(directory: dir).export(target: .appleSilicon, installerName: malicious)
    let text = try String(contentsOf: url, encoding: .utf8)
    let headingLines = text.split(separator: "\n").filter { $0.hasPrefix("#") }
    #expect(headingLines.allSatisfy { $0.hasPrefix("# How to use your") || $0.hasPrefix("## ") })
    #expect(text.contains("![tracker]") == false)
}

@Test("a name containing Markdown grouping and emphasis characters appears in the document with those characters intact, and unescaped")
func documentPreservesMarkdownPunctuationInName() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    // Covers all four characters fix round 2's brief called out by name:
    // "(", ")", "*", "_". Not a value Apple ships; chosen to exercise all
    // four in one fixture. `macOS 15 (Beta)` below is the realistic one.
    let name = "macOS 15 (Beta)_2*"

    let url = try InstructionExporter(directory: dir).export(target: .intelT2, installerName: name)
    let text = try String(contentsOf: url, encoding: .utf8)

    // Round 1 DELETED these characters from the document. Round 2
    // backslash-escaped them. Round 3 narrows the escaped set further still:
    // none of these four is in it, so they now reach the document completely
    // unchanged — no backslash anywhere near them.
    #expect(text.contains("(Beta)_2*"))
    #expect(text.contains("\\(Beta)_2*") == false)
}

@Test("the document's stated volume name matches the real drive name exactly, with NO backslashes at all — what a plain-text reader (e.g. TextEdit) actually sees")
func volumeNameMatchesRealDriveName() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    // The realistic fixture named in fix round 2's (and still round 3's)
    // brief: Apple does ship parenthesised beta titles, so this is
    // reachable, not theoretical.
    let name = "macOS 15 (Beta)"

    let url = try InstructionExporter(directory: dir).export(target: .intelT2, installerName: name)
    let text = try String(contentsOf: url, encoding: .utf8)

    // createinstallmedia renames the real drive to "Install <name>" using
    // the raw name (minus newlines/control characters, which can never
    // survive onto a real volume name either). A `.md` file double-clicked
    // on macOS is at least as likely to open in TextEdit as plain text as it
    // is to open in a Markdown previewer — so the document must contain this
    // EXACT string, with NO backslashes, or a plain-text reader goes hunting
    // the startup picker for a drive name that has backslashes the real
    // drive never had. This is the stronger property round 3 exists for:
    // round 2's escaping would have failed this very assertion.
    let expectedVolumeName = "Install \(name)"
    #expect(text.contains("\"\(expectedVolumeName)\""))
    #expect(text.contains("\\") == false)
}

@Test("a name containing link/image/HTML metacharacters IS escaped, so narrowing the set does not quietly become escaping nothing")
func documentEscapesBracketsAndAngleBrackets() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let name = "macOS [Tahoe] <beta>"

    let url = try InstructionExporter(directory: dir).export(target: .intelT2, installerName: name)
    let text = try String(contentsOf: url, encoding: .utf8)

    #expect(text.contains("\\[Tahoe\\]"))
    #expect(text.contains("\\<beta\\>"))
    // And the unescaped forms are gone from the document.
    #expect(hasUnescapedCharacter("[", in: text) == false)
    #expect(hasUnescapedCharacter("]", in: text) == false)
    #expect(hasUnescapedCharacter("<", in: text) == false)
    #expect(hasUnescapedCharacter(">", in: text) == false)
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
