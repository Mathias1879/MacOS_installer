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
