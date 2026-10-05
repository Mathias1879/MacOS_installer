import Foundation

/// Guarantees that an announcement completes before whatever depends on the
/// user having acted on it is observed.
///
/// This exists because of a specific, repeat defect: the Before stage tells
/// the user to plug in a drive, and volume enumeration is what later decides
/// which drives are offered. Those are two separate statements in
/// `CreateCommand.execute()`, and two adjacent statements can be reordered by
/// any future edit without the compiler objecting — nothing about their
/// types says one must run before the other. Collapsing the pair into a
/// single call makes the order a property of this function's two-line body
/// instead of two call sites a future diff can silently swap, and lets a test
/// pin that order directly.
public enum BeforeStageOrdering {
    /// Runs `announce`, then `observe`. `observe` is evaluated strictly after
    /// `announce` returns — never interleaved, never reordered.
    public static func announceThenObserve<Result>(
        announce: () -> Void,
        observe: () throws -> Result
    ) rethrows -> Result {
        announce()
        return try observe()
    }
}
