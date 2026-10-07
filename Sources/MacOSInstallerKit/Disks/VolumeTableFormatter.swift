import Foundation

/// Renders guard decisions. Refused volumes are still shown, with the reason —
/// a user who cannot see their disk assumes the tool is broken.
///
/// The device identifier is printed next to every volume name, selectable or
/// not. Two distinct volumes can share a display name (this machine has two
/// drives both named "Untitled"), so the identifier is the only thing in this
/// output that always disambiguates them.
public enum VolumeTableFormatter {
    public static func render(_ decisions: [VolumeGuard.VolumeDecision]) -> String {
        guard !decisions.isEmpty else { return "No drives found." }

        var lines: [String] = []

        for decision in decisions {
            let name = decision.volume.displayName
            let id = decision.volume.deviceIdentifier
            let size = ByteSize.gigabytes(decision.volume.sizeBytes)
            switch decision.verdict {
            case .selectable:
                lines.append("  \(name)  \(id)  \(size)")
            case .selectableWithWarning(let warning):
                lines.append("  \(name)  \(id)  \(size)   ⚠ \(warning)")
            case .refused(let reason):
                lines.append("  ✕ \(name)  \(id)  \(size)   \(reason.userMessage)")
            }
        }

        let anySelectable = decisions.contains {
            if case .refused = $0.verdict { return false }
            return true
        }
        if !anySelectable {
            lines.append("")
            lines.append("No drive here can be used. Connect an external USB drive of 32 GB or larger.")
        }

        return lines.joined(separator: "\n")
    }
}
