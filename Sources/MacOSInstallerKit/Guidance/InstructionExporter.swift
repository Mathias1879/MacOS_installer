import Foundation

/// An error writing the after-steps to disk.
public enum ExportError: Error, Equatable {
    case cannotWrite(String)
}

/// Writes the after-steps to a file the user can carry to the other Mac.
///
/// The boot instructions are useless in a terminal window someone is about to
/// close before walking across the room, which is exactly what they do next —
/// the Mac showing that terminal is often the one about to be wiped.
public struct InstructionExporter {
    private let directory: URL

    public init(directory: URL = InstructionExporter.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Writes the `.after` stage only — this file is handed to someone who
    /// has already finished the before/during steps and is now standing at
    /// the other Mac. `originalDriveName` is passed as `nil` because `.after`
    /// derives the post-rename volume name itself and never reads it; see
    /// `GuidanceCatalog.sections(for:target:installerName:originalDriveName:)`.
    @discardableResult
    public func export(target: TargetMac, installerName: String) throws -> URL {
        // Sanitised ONCE here, then used everywhere `installerName` would
        // otherwise reach the document — including the volume name
        // `GuidanceCatalog.after` builds from it — so the raw, untrusted
        // string never reaches rendered output by any path.
        let safeInstallerName = Self.sanitised(installerName)
        let sections = GuidanceCatalog.sections(
            for: .after, target: target, installerName: safeInstallerName, originalDriveName: nil
        )
        let text = Self.render(installerName: safeInstallerName, target: target, sections: sections)
        let url = directory.appendingPathComponent(Self.fileName(for: safeInstallerName, target: target))

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw ExportError.cannotWrite(error.localizedDescription)
        }

        return url
    }

    /// Includes `target` so exporting for a second Mac from the same download
    /// cannot silently overwrite the first Mac's file — only re-running for
    /// the SAME installer AND the SAME target should overwrite. `target.rawValue`
    /// is filename-safe on its own (it is a Swift identifier: no slashes, no
    /// control characters), so it needs no sanitising. `safeInstallerName` is
    /// already sanitised by the caller (`export`), once, for every use.
    private static func fileName(for safeInstallerName: String, target: TargetMac) -> String {
        "How to use your \(safeInstallerName) installer (\(target.rawValue)).md"
    }

    /// Builds the Markdown body by mapping each section to its own block of
    /// lines and flattening, rather than mutating a shared accumulator — no
    /// section needs to know about any other section's output. The target is
    /// stated in words right after the title — `target.label` is its one home
    /// (see `TargetMac.label`) — so a reader holding this file cannot mistake
    /// which Mac it was written for before they start following boot steps.
    /// `safeInstallerName` is already sanitised by the caller (`export`).
    private static func render(installerName safeInstallerName: String, target: TargetMac, sections: [GuidanceSection]) -> String {
        let header = [
            "# How to use your `\(safeInstallerName)` installer",
            "",
            "This file is for: \(target.label)",
            "",
        ]
        let body = sections.flatMap(renderedLines)
        return (header + body).joined(separator: "\n")
    }

    private static func renderedLines(for section: GuidanceSection) -> [String] {
        let heading = ["## \(section.heading)", ""]
        let paragraphs = section.body.flatMap { [$0, ""] }
        let steps = section.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        let trailer = steps.isEmpty ? [] : [""]
        return heading + paragraphs + steps + trailer
    }

    /// The single sanitiser shared by the filename AND the document body —
    /// `installerName` is untrusted (it comes from Apple's software update
    /// catalog title), and treating it differently in the two places it is
    /// rendered is how Finding 1 happened. One fact, one home, one sanitiser.
    ///
    /// - Normalises Unicode first (`.precomposedStringWithCanonicalMapping`),
    ///   so two byte-different spellings of the same visible name (NFC vs
    ///   NFD) collapse to the same sanitised string and therefore the same
    ///   file, rather than silently producing two files for one installer.
    /// - Strips every control character, including newlines, so the name can
    ///   never inject a second line — and therefore never a second Markdown
    ///   heading — into either the filename or the document body.
    /// - Also strips the characters that make Markdown syntax "live"
    ///   (`! [ ] ( ) \` # * _ < >`). Stripping newlines alone still leaves an
    ///   image tag or heading marker active on the single remaining line, so
    ///   this is what actually prevents `![x](url)` from reaching the
    ///   document as a working image tag rather than inert text.
    /// - Replaces "/" with "-" and removes ".." so the name can never be
    ///   mistaken for a path component that escapes the target directory.
    /// - Falls back to a fixed, non-empty name — "macOS", not "installer" —
    ///   so a whitespace-only input reads as "your macOS installer" rather
    ///   than the doubled-up "your installer installer".
    private static func sanitised(_ name: String) -> String {
        let normalised = name.precomposedStringWithCanonicalMapping
        let unsafeCharacters = CharacterSet.newlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "![]()`#*_<>"))
        let withoutUnsafeCharacters = String(normalised.unicodeScalars.filter { !unsafeCharacters.contains($0) })
        let stripped = withoutUnsafeCharacters
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? "macOS" : stripped
    }
}
