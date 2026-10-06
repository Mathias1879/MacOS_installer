import Foundation

/// Requires the user to type the volume's name exactly. A y/N prompt is not
/// sufficient for an irreversible erase — the typing is the point, because it
/// forces the user to read which drive they picked.
///
/// By the time this runs, `CreateCommand` has already resolved `--volume` to
/// exactly one volume (an ambiguous name match is refused earlier, before any
/// confirmation prompt is shown), so a correct typed match here can only ever
/// confirm the single volume that was resolved.
enum ConfirmationPrompt {
    static func requireTypedName(
        _ expected: String,
        readLine: () -> String? = { Swift.readLine(strippingNewline: true) }
    ) -> Bool {
        readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }
}
