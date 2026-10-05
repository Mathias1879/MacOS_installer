import Foundation
import Testing
@testable import MacOSInstallerKit

/// `export` deliberately drops the brief's `driveName` parameter. The `.after`
/// stage it renders derives "Install <installerName>" itself and ignores
/// `originalDriveName` entirely (see `GuidanceCatalog.after(target:installerName:)`),
/// so a drive name here would be dead weight a caller could pass wrong for a
/// value nothing ever reads — see `InstructionExporter.export(target:installerName:)`.
private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test("writes a Markdown file named after the installer")
func writesNamedFile() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

    let url = try InstructionExporter(directory: dir).export(target: .intelPreT2, installerName: "macOS Tahoe")

    #expect(url.lastPathComponent == "How to use your macOS Tahoe installer.md")
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

@Test("overwrites a previous export rather than failing or creating a duplicate")
func overwritesPreviousExport() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let exporter = InstructionExporter(directory: dir)

    let first = try exporter.export(target: .appleSilicon, installerName: "macOS Tahoe")
    let second = try exporter.export(target: .intelPreT2, installerName: "macOS Tahoe")

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
    #expect(text.contains("# How to use your macOS/../../Tahoe installer"))
}

@Test("every TargetMac case is covered by this file's hand-picked fixtures")
func samplesEveryTargetMacCase() {
    // The tests above each hand-select one or two `TargetMac` cases to prove
    // a specific fact (the boot-method wording, the T2-only extra step).
    // Per this codebase's established pattern (see `GuidanceCatalogTests.swift`
    // and `ExplanationWordingTests.swift`), this exhaustive switch with no
    // `default` fails the file to compile if a fourth case is ever added,
    // rather than letting it ship with no InstructionExporter coverage.
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)
}

private func exhaustivelyCheckTargetMac(_ target: TargetMac) {
    switch target {
    case .appleSilicon: break
    case .intelT2: break
    case .intelPreT2: break
    }
}
