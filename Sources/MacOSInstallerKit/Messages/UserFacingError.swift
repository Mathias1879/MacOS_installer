import Foundation

/// A message for someone who has never opened Terminal.
///
/// The spec requires every user-facing error to state three things: what
/// happened, what it means, and what to do next. This type makes that shape
/// structural rather than a convention each call site has to remember — the
/// previous design had four independent formatters, each phrasing the same
/// guarantees differently.
public struct UserFacingError: Equatable, Sendable {
    /// A short line a user can search for, e.g. "Couldn't erase the drive".
    public let title: String
    /// Plain statement of the observed fact, naming what the user named.
    public let whatHappened: String
    /// Why it probably happened. Nil when there is nothing honest to add —
    /// guessing is worse than silence.
    public let whatItMeans: String?
    /// Concrete actions, one per entry, in the order to try them. Empty when
    /// there is genuinely nothing to try; do not invent filler.
    public let whatToDoNext: [String]
    /// Where the technical detail was written, if it was.
    public let logReference: String?

    public init(
        title: String,
        whatHappened: String,
        whatItMeans: String? = nil,
        whatToDoNext: [String] = [],
        logReference: String? = nil
    ) {
        self.title = title
        self.whatHappened = whatHappened
        self.whatItMeans = whatItMeans
        self.whatToDoNext = whatToDoNext
        self.logReference = logReference
    }

    public func rendered() -> String {
        var blocks: [String] = ["✗ \(title)"]
        blocks.append(indent(whatHappened))

        if let whatItMeans {
            blocks.append(indent(whatItMeans))
        }

        if !whatToDoNext.isEmpty {
            let steps = whatToDoNext.enumerated()
                .map { "     \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            blocks.append("   To fix it:\n" + steps)
        }

        if let logReference {
            blocks.append(indent("Details saved to:\n\(logReference)"))
        }

        return blocks.joined(separator: "\n\n")
    }

    private func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "   \($0)" }
            .joined(separator: "\n")
    }
}
