import Foundation

/// Guarantees that an announcement completes, the user has a chance to act on
/// it, and only then is whatever depends on that action observed.
///
/// This exists because of a specific, repeat defect: the Before stage tells
/// the user to plug in a drive, and volume enumeration is what later decides
/// which drives are offered. An earlier fix round reordered `announce` ahead
/// of `observe` and that was verified only by checking the SOURCE order
/// changed — never by asking whether a user could act on the instruction in
/// between. They could not: nothing paused between the two, so a user who
/// read "plug the drive in" and did exactly that, right then, still weighed
/// in on a snapshot taken before they moved. `acknowledge` is the fix: it
/// actually waits, via a terminal prompt, before `observe` ever runs.
///
/// Those three are separate statements in `CreateCommand.execute()`, and
/// three adjacent statements can be reordered by any future edit without the
/// compiler objecting — nothing about their types says one must run before
/// another. Collapsing them into a single call makes the order a property of
/// this function's three-line body instead of three call sites a future diff
/// can silently swap, and lets a test pin that order directly.
public enum BeforeStageOrdering {
    /// Runs `announce`, then `acknowledge`, then `observe` — strictly in that
    /// order, never interleaved, never reordered.
    ///
    /// `acknowledge` has no default: this type is pure orchestration with no
    /// I/O of its own (`MacOSInstallerKit` must not print — the executable
    /// target does that), so the real terminal prompt — wait for Return, but
    /// only when stdin is a TTY (`isatty(0)`) — lives in `CreateCommand` and
    /// is passed in like `announce` and `observe` already are. Skipping the
    /// prompt on a non-TTY stdin is deliberate: a non-interactive caller
    /// (piped input, CI) has no one to press Return, and blocking on
    /// `readLine()` there would hang rather than fail closed the way the
    /// non-interactive path already does today (e.g. `TargetMacPicker.ask`
    /// returning `nil` at end-of-input).
    public static func announceThenObserve<Result>(
        announce: () -> Void,
        acknowledge: () -> Void,
        observe: () throws -> Result
    ) rethrows -> Result {
        announce()
        acknowledge()
        return try observe()
    }
}
