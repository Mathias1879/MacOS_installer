import Foundation

/// An error that can describe itself to someone who has never opened Terminal.
///
/// Conforming types own their own wording, so the executable never switches on
/// error type to decide what to say.
public protocol Explainable {
    /// The three-part message a user sees.
    var explanation: UserFacingError { get }
    /// Exact argv, exit status, stderr — whatever a developer would want. Goes
    /// to the log, never to the terminal.
    var technicalDetail: String { get }
}

/// Turns any error into a three-part message, logging its technical detail.
///
/// An error that is not `Explainable` still produces a real message rather than
/// raw enum text: the previous design let `String(describing:)` reach the user,
/// so a digest mismatch printed `mismatch(expected: "0000…", actual: "a1b…")`
/// to someone who had just confirmed erasing a drive.
public func explain(_ error: any Error, log: DiagnosticLog?) -> UserFacingError {
    let detail: String
    let base: UserFacingError

    if let explainable = error as? Explainable {
        detail = explainable.technicalDetail
        base = explainable.explanation
    } else {
        detail = "Unexpected error: \(String(reflecting: error))"
        base = UserFacingError(
            title: "Something went wrong that this tool didn't expect",
            whatHappened: "The operation stopped before it finished.",
            whatItMeans: "This is a gap in the tool rather than something you did.",
            whatToDoNext: [
                "Run the command again — it may have been temporary",
                "If it keeps happening, open an issue and attach the log file below",
            ]
        )
    }

    let reference = log?.record(detail)

    return UserFacingError(
        title: base.title,
        whatHappened: base.whatHappened,
        whatItMeans: base.whatItMeans,
        whatToDoNext: base.whatToDoNext,
        logReference: reference ?? base.logReference
    )
}
