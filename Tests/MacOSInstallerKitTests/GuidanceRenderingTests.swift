import Testing
@testable import MacOSInstallerKit

/// Each case below asserts the exact rendered string, not a prefix, a
/// substring, or an ordering check — `GuidanceRenderer.render` is pure and
/// deterministic, so the exact value is always available, and a substring
/// check would not catch a wrong separator, a misplaced blank line, or
/// mis-ordered blocks the way a full equality check does.
@Test("renders headings, prose and numbered steps in order")
func rendersSectionsInOrder() {
    let section = GuidanceSection(
        heading: "Before you start",
        body: ["You'll be making a USB drive."],
        steps: ["Find a USB drive", "Plug it in"]
    )

    let output = GuidanceRenderer.render([section])

    let expected = [
        "  \(section.heading)",
        "  " + String(repeating: "─", count: section.heading.count),
        "",
        "  You'll be making a USB drive.",
        "",
        "    1. Find a USB drive",
        "    2. Plug it in",
    ].joined(separator: "\n")

    #expect(output == expected)
}

@Test("renders a section with no steps without an empty list")
func rendersBodyOnlySection() {
    let section = GuidanceSection(heading: "Two things to know", body: ["Everything will be erased."])

    let output = GuidanceRenderer.render([section])

    let expected = [
        "  \(section.heading)",
        "  " + String(repeating: "─", count: section.heading.count),
        "",
        "  Everything will be erased.",
    ].joined(separator: "\n")

    #expect(output == expected)
}

@Test("renders nothing for an empty section list")
func rendersEmptyForNoSections() {
    #expect(GuidanceRenderer.render([]) == "")
}

@Test("joins multiple sections with exactly one blank line between them")
func joinsMultipleSectionsWithBlankLine() {
    let first = GuidanceSection(heading: "A", body: ["First."])
    let second = GuidanceSection(heading: "B", body: ["Second."])

    let output = GuidanceRenderer.render([first, second])

    // Each single-section block is already pinned to an exact value by the
    // tests above; a two-section render must be exactly those two blocks
    // joined by one blank line, independent of what either block's own
    // exact text is.
    let firstBlock = GuidanceRenderer.render([first])
    let secondBlock = GuidanceRenderer.render([second])

    #expect(output == firstBlock + "\n\n" + secondBlock)
}
