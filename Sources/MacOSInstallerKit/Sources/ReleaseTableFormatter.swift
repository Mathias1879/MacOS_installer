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
