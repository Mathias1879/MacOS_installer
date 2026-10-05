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
        let sections = GuidanceCatalog.sections(
            for: .after, target: target, installerName: installerName, originalDriveName: nil
        )
        let text = Self.render(installerName: installerName, sections: sections)
        let url = directory.appendingPathComponent(Self.fileName(for: installerName))

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw ExportError.cannotWrite(error.localizedDescription)
        }

        return url
    }

    private static func fileName(for installerName: String) -> String {
        "How to use your \(sanitised(installerName)) installer.md"
    }

    /// Builds the Markdown body by mapping each section to its own block of
    /// lines and flattening, rather than mutating a shared accumulator — no
    /// section needs to know about any other section's output.
    private static func render(installerName: String, sections: [GuidanceSection]) -> String {
        let header = ["# How to use your \(installerName) installer", ""]
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

    /// Strips path separators so an installer name can never escape the
    /// target directory, and falls back to a fixed name rather than ever
    /// producing an empty string — an empty component would either be
    /// rejected by the filesystem or collapse into the directory itself.
    private static func sanitised(_ name: String) -> String {
        let stripped = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? "installer" : stripped
    }
}
