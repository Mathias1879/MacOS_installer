import Foundation

/// Which Mac will boot the finished installer.
///
/// This is NOT the Mac running this tool. Writing Mojave media on an Apple
/// silicon Mac for a 2015 Intel MacBook is the expected case, and the two boot
/// in completely different ways — so the after-steps depend on this answer and
/// nothing else.
public enum TargetMac: String, CaseIterable, Sendable {
    case appleSilicon
    case intelT2
    case intelPreT2

    public var label: String {
        switch self {
        case .appleSilicon: return "A Mac with Apple silicon (M1, M2, M3, M4…)"
        case .intelT2: return "An Intel Mac with a T2 security chip"
        case .intelPreT2: return "An Intel Mac without a T2 security chip"
        }
    }

    /// One sentence naming the physical action. Apple silicon's procedure
    /// differs from Intel's; the two Intel targets share the identical
    /// procedure, because holding Option during startup is physically the
    /// same action on both. The T2 target's extra Startup Security Utility
    /// requirement is a separate fact, not a wording difference — see
    /// `requiresStartupSecurityUtility`, which is its single home.
    public var bootMethod: String {
        switch self {
        case .appleSilicon:
            return "Press and hold the power button until you see a list of startup options."
        case .intelT2, .intelPreT2:
            return "Turn the Mac on and immediately hold the Option key until you see the startup drives."
        }
    }

    /// T2 Macs ship with Secure Boot set to Full Security, which refuses to
    /// boot from external media until Startup Security Utility is changed.
    public var requiresStartupSecurityUtility: Bool {
        self == .intelT2
    }

    public static let helpText = """
    How to find out which Mac you have:

    If the Mac you want to install macOS onto can start up:

      1. Click the Apple menu in the top-left corner of the screen
      2. Click "About This Mac"
      3. If "Chip" shows Apple M1, M2, M3 or M4, choose option 1
      4. If it shows an Intel processor instead, click "System Report"
         (on macOS Ventura or later, click "More Info…" first), then look
         under Hardware for "Controller" — or "iBridge" on some older
         versions of macOS. If either line lists "Apple T2 Security Chip,"
         choose option 2. Only choose option 3 if you checked both labels
         and neither lists it.

    If that Mac cannot start up at all, Apple publishes the full list of T2
    models in a support article titled
    "Mac computers with the Apple T2 Security Chip."
    Look it up from another device and check whether your model is on it.

    If you still cannot tell, choose option 2. The extra step it adds is
    harmless on a Mac that doesn't need it — but skipping that step on a
    Mac that does need it means no startup drive will appear at all when
    you try to boot from this installer.
    """

    /// Resolves a typed answer, or nil when it cannot be resolved confidently.
    ///
    /// Returning nil for an ambiguous answer is deliberate: a wrong guess sends
    /// the user the wrong boot instructions, and they conclude the stick is
    /// broken rather than that they answered unclearly.
    public static func identify(answer: String) -> TargetMac? {
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }

        switch cleaned {
        case "1": return .appleSilicon
        case "2": return .intelT2
        case "3": return .intelPreT2
        default: break
        }

        if cleaned.contains("apple silicon") || cleaned.range(of: #"\bm[1-4]\b"#, options: .regularExpression) != nil {
            return .appleSilicon
        }
        // "intel" alone is ambiguous — which era? — so it is not accepted.
        //
        // No model year ever maps here. A model year cannot tell a T2 Mac
        // from a pre-T2 Mac: the iMac Pro (late 2017) was Apple's first T2
        // Mac, while the 2019 iMac has none at all (the iMac did not gain T2
        // until the 2020 27-inch model) — yet 2019 IS a T2 year for the Mac
        // Pro, the MacBook Pro 16-inch, and the MacBook Air. One year maps to
        // both answers depending on the family, so there is no safe range to
        // match here; `helpText` sends the user to the Controller line in
        // System Report, or to Apple's model list, instead.
        if cleaned.contains("t2") {
            return .intelT2
        }

        return nil
    }
}
