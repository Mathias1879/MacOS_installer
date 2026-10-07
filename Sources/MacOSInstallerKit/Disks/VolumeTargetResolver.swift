import Foundation

/// Resolves a user-supplied `--volume` string (a display name or a device
/// identifier) to exactly one volume among a set of guard decisions.
///
/// This is pure decision logic with a direct safety consequence, so it lives
/// in the library rather than in `CreateCommand` — the executable target is
/// excluded from coverage, and this is exactly the kind of code that must be
/// tested.
///
/// CORRECTION — an ambiguous match must be REFUSED, not resolved to the first
/// hit. Display names are not unique: this machine has two distinct external
/// volumes both named "Untitled" (`disk5s1` and `disk6s2`). If a chooser
/// silently picked the first one matching `--volume Untitled`, the typed-name
/// confirmation that follows would truthfully ask the user to type "Untitled"
/// — and would get no protection from the fact that it picked the wrong one.
/// So: more than one name match is `.ambiguous`, never `.unique`. An exact
/// device-identifier match is always unambiguous, because device identifiers
/// are unique per volume.
public enum VolumeTargetResolver {
    public enum Resolution: Equatable, Sendable {
        /// Carries the whole decision, not just the `Volume` — callers need
        /// the verdict too. A volume that is `.selectableWithWarning` must
        /// still surface its warning at the one moment it matters (right
        /// before the user confirms an erase), and a bare `Volume` throws
        /// that information away.
        case unique(VolumeGuard.VolumeDecision)
        case ambiguous([VolumeGuard.VolumeDecision])
        case none
    }

    public static func resolve(
        matching query: String,
        among decisions: [VolumeGuard.VolumeDecision]
    ) -> Resolution {
        // An exact device-identifier match is checked first and is always
        // unambiguous, even when two volumes share a display name: the
        // identifier is unique per volume by construction.
        if let byIdentifier = decisions.first(where: {
            $0.volume.deviceIdentifier == query && isSelectable($0.verdict)
        }) {
            return .unique(byIdentifier)
        }

        let nameMatches = decisions.filter {
            $0.volume.displayName == query && isSelectable($0.verdict)
        }

        switch nameMatches.count {
        case 0: return .none
        case 1: return .unique(nameMatches[0])
        default: return .ambiguous(nameMatches)
        }
    }

    private static func isSelectable(_ verdict: VolumeGuard.Verdict) -> Bool {
        if case .refused = verdict { return false }
        return true
    }
}
