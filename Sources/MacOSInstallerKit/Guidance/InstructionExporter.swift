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
    ///
    /// Two DIFFERENT derived names exist from here on, because they answer
    /// two different questions (fix round 2):
    ///
    /// - `cleanedInstallerName` strips ONLY newlines and control characters —
    ///   the minimum every consumer needs, because an embedded newline could
    ///   inject an extra line into either this file or Task 8's terminal
    ///   output. Nothing else is touched, so it is what reaches
    ///   `GuidanceCatalog` and, through it, the document's prose — meaning a
    ///   real Apple title like "macOS 15 (Beta)" keeps its parentheses all
    ///   the way to the sentence that tells the user what to look for at the
    ///   startup picker. That sentence has to match the real, renamed drive,
    ///   or the user hunts for a string that doesn't exist.
    /// - The filename sanitiser (`sanitised(_:)`) is unchanged from fix round
    ///   1 and is used ONLY for the filename, which has real filesystem
    ///   constraints a Markdown document does not.
    @discardableResult
    public func export(target: TargetMac, installerName: String) throws -> URL {
        let cleanedInstallerName = Self.layerAgnosticallyCleaned(installerName)
        let sections = GuidanceCatalog.sections(
            for: .after, target: target, installerName: cleanedInstallerName, originalDriveName: nil
        )
        let rawText = Self.render(installerName: cleanedInstallerName, target: target, sections: sections)
        let text = Self.escapedForMarkdown(rawText, interpolatedContent: cleanedInstallerName)
        let url = directory.appendingPathComponent(
            Self.fileName(for: Self.sanitised(installerName), target: target)
        )

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
    /// control characters), so it needs no sanitising. `fileNameSafeInstallerName`
    /// is already sanitised by the caller (`export`'s `Self.sanitised(installerName)`).
    private static func fileName(for fileNameSafeInstallerName: String, target: TargetMac) -> String {
        "How to use your \(fileNameSafeInstallerName) installer (\(target.rawValue)).md"
    }

    /// Builds the Markdown body by mapping each section to its own block of
    /// lines and flattening, rather than mutating a shared accumulator — no
    /// section needs to know about any other section's output. The target is
    /// stated in words right after the title — `target.label` is its one home
    /// (see `TargetMac.label`) — so a reader holding this file cannot mistake
    /// which Mac it was written for before they start following boot steps.
    ///
    /// Returns the UNESCAPED text — `cleanedInstallerName` appears verbatim
    /// here, exactly as `GuidanceCatalog` embedded it in `sections`. Markdown
    /// escaping happens afterward, in `escapedForMarkdown`, as one pass over
    /// the whole rendered document: every place this function or
    /// `GuidanceCatalog` wrote `cleanedInstallerName` gets caught by that one
    /// pass, with no risk of this function escaping it once and a catalog
    /// sentence leaving another copy unescaped.
    private static func render(installerName cleanedInstallerName: String, target: TargetMac, sections: [GuidanceSection]) -> String {
        let header = [
            "# How to use your \(cleanedInstallerName) installer",
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

    /// Strips ONLY newlines and control characters. This is the ONE cleaning
    /// step that belongs before `GuidanceCatalog`, because `GuidanceCatalog`'s
    /// text has two consumers — this Markdown exporter and Task 8's terminal
    /// walkthrough — and an embedded newline breaks both of them (it can
    /// inject what reads as a second line, or a second Markdown heading, into
    /// either). Nothing else is removed here: Markdown metacharacters like
    /// `(` `)` `*` `_` are ordinary characters in a real Apple catalog title
    /// (e.g. "macOS 15 (Beta)") and a terminal has no Markdown syntax for them
    /// to corrupt, so stripping them at this shared layer would both lose
    /// fidelity for Task 8 and still leave the Markdown-specific problem to
    /// fix separately. That problem is `escapedForMarkdown`'s job instead.
    private static func layerAgnosticallyCleaned(_ name: String) -> String {
        let unsafeCharacters = CharacterSet.newlines.union(.controlCharacters)
        return String(name.unicodeScalars.filter { !unsafeCharacters.contains($0) })
    }

    /// Backslash-escapes Markdown metacharacters wherever `interpolatedContent`
    /// (the newline/control-stripped installer name) literally appears in
    /// `text` — in the heading, and in every catalog sentence that embeds the
    /// derived volume name ("Install \(name)"). A targeted substring replace,
    /// rather than escaping the whole document, is what keeps this scoped to
    /// untrusted content: `GuidanceCatalog`'s own literal prose (e.g. "(this
    /// is the slow part)" in another stage) is never touched by this pass,
    /// because it was never built from `interpolatedContent`.
    ///
    /// Escaping only the narrow six-character set (fix round 3) is strictly
    /// better than fix round 1's deletion AND fix round 2's wider twelve-
    /// character set: a realistic name like "macOS 15 (Beta)" contains none
    /// of the six, so it reaches both a Markdown previewer and a plain-text
    /// reader (e.g. TextEdit) with the EXACT same characters the real,
    /// renamed drive has — no backslashes to misread as part of the name
    /// (see `escapedForMarkdown`'s test, `volumeNameMatchesRealDriveName`).
    private static func escapedForMarkdown(_ text: String, interpolatedContent: String) -> String {
        guard !interpolatedContent.isEmpty else { return text }
        return text.replacingOccurrences(of: interpolatedContent, with: markdownEscaped(interpolatedContent))
    }

    /// Prefixes only the six characters that can actually alter document
    /// structure or inject content — with `\` — rather than the full set of
    /// twelve Markdown metacharacters fix round 2 escaped. Fix round 2's
    /// wider set fixed how the file renders in a Markdown previewer but
    /// broke how it reads as plain text (e.g. a `.md` file double-clicked
    /// and opened in TextEdit, which is at least as likely a destination):
    /// a volume name that exists to be matched character-for-character
    /// against the Mac's startup picker must never gain backslashes the
    /// real drive doesn't have.
    ///
    /// The six kept are exactly the ones that can inject on their own:
    /// - `\` must be escaped so it cannot manufacture escapes out of
    ///   whatever follows it.
    /// - `` ` `` could open a code span and swallow following text.
    /// - `[` and `]` together are what a link or image needs — CommonMark
    ///   cannot form `[text](url)` or `![alt](url)` without both brackets
    ///   present, so escaping either one kills the pair, which is also why
    ///   `!` needs no escaping of its own anymore.
    /// - `<` and `>` are needed for raw HTML such as `<img src=…>`.
    ///
    /// Dropped from fix round 2's set, and why each is safe to drop:
    /// - `(` and `)` are inert literal text once `[` and `]` are gone —
    ///   there is no bracket pair left for them to close a link against.
    /// - `#` only opens a heading at the START of a line. The installer
    ///   name is interpolated mid-line in every template this exporter
    ///   renders (see `GuidanceCatalog`'s `.after`-stage sections and this
    ///   file's own header line) and newlines were already stripped from
    ///   the name before this function ever sees it (`layerAgnosticallyCleaned`),
    ///   so an embedded `#` can never land at the start of a physical line.
    /// - `*` and `_` can at worst italicise — cosmetic, not structural.
    ///
    /// None of these six appears in any real macOS release title (e.g.
    /// "macOS 15 (Beta)"), so a realistic name now passes through this
    /// function completely unchanged — no conditional logic required. Only
    /// an adversarial name picks up backslashes, which is exactly where
    /// that cosmetic cost belongs.
    private static func markdownEscaped(_ text: String) -> String {
        let metacharacters: Set<Character> = ["\\", "`", "[", "]", "<", ">"]
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            if metacharacters.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// The filename sanitiser — UNCHANGED from fix round 1 (per fix round
    /// 2's brief: "Filename sanitising stays exactly as it is"). Used ONLY
    /// for the filename now; the document body no longer goes through this.
    ///
    /// - Normalises Unicode first (`.precomposedStringWithCanonicalMapping`),
    ///   so two byte-different spellings of the same visible name (NFC vs
    ///   NFD) collapse to the same sanitised string and therefore the same
    ///   file, rather than silently producing two files for one installer.
    /// - Strips every control character, including newlines, so the name can
    ///   never inject a second line into the filename.
    /// - Also strips the characters that make Markdown syntax "live"
    ///   (`! [ ] ( ) \` # * _ < >`) — not because a filename renders
    ///   Markdown, but because aggressive stripping of anything unusual is
    ///   the right posture for a filename specifically: nobody matches a
    ///   filename against a boot picker, and filenames have real filesystem
    ///   constraints a Markdown document does not.
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
