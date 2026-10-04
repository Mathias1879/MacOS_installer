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
        case .intelT2: return "An Intel Mac from 2018 or later"
        case .intelPreT2: return "An Intel Mac from 2017 or earlier"
        }
    }

    /// One sentence naming the physical action. Deliberately different per
    /// target: a reader should never have to work out which half applies.
    public var bootMethod: String {
        switch self {
        case .appleSilicon:
            // Deliberately avoids the word "option" even as a substring (e.g.
            // "options") — that word is reserved for the Intel boot method
            // below, where it names a physical key, and the two must never
            // read alike.
            return "Press and hold the power button until you see a list of startup disks."
        case .intelT2:
            // Text must stay distinct from the pre-T2 case below: this Mac
            // also needs Startup Security Utility changed before external
            // media is even offered as a choice (see
            // `requiresStartupSecurityUtility`), which is worth saying here
            // even though the key you hold is the same.
            return "Turn the Mac on and immediately hold the Option key until you see the startup drives. " +
                "This Mac also needs Startup Security Utility set to allow booting from external media first."
        case .intelPreT2:
            return "Turn the Mac on and immediately hold the Option key until you see the startup drives."
        }
    }

    /// 2018-and-later Intel Macs refuse to boot from external media until
    /// Startup Security Utility is changed.
    public var requiresStartupSecurityUtility: Bool {
        self == .intelT2
    }

    public static let helpText = """
    How to find out which Mac you have:

      1. On the Mac you want to install macOS onto, click the Apple menu
         in the top-left corner of the screen
      2. Click "About This Mac"
      3. Look for "Chip" or "Processor"

    If it says Apple M1, M2, M3 or M4, choose option 1.
    If it says Intel and the Mac is from 2018 or later, choose option 2.
    If it says Intel and the Mac is from 2017 or earlier, choose option 3.

    If that Mac won't turn on at all, the year is usually printed in the
    About This Mac window of any Mac it was set up from, or on the original
    receipt or box.
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

        if cleaned.contains("apple silicon") || cleaned.range(of: #"^m[1-4]$"#, options: .regularExpression) != nil {
            return .appleSilicon
        }
        // "intel" alone is ambiguous — which era? — so it is not accepted.
        if cleaned.contains("t2") || cleaned.contains("2018") || cleaned.contains("2019") || cleaned.contains("2020") {
            return .intelT2
        }
        if cleaned.contains("2017") || cleaned.contains("2016") || cleaned.contains("2015")
            || cleaned.contains("2014") || cleaned.contains("2013") || cleaned.contains("2012") {
            return .intelPreT2
        }

        return nil
    }
}
