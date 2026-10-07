import Foundation
import MacOSInstallerKit

/// Asks which Mac will boot the finished installer. Re-asks on an answer it
/// cannot resolve, and offers help rather than guessing.
enum TargetMacPicker {
    static func ask(
        readLine: () -> String? = { Swift.readLine(strippingNewline: true) },
        print: (String) -> Void = { Swift.print($0) },
        maximumAttempts: Int = 3
    ) -> TargetMac? {
        print("")
        print("  Which Mac will you boot this installer on?")
        print("  (This is the Mac you want to install macOS onto — not necessarily this one.)")
        print("")
        for (index, target) in TargetMac.allCases.enumerated() {
            print("    \(index + 1). \(target.label)")
        }
        print("    ?. I'm not sure — help me find out")
        print("")

        var attempts = 0
        while attempts < maximumAttempts {
            print("  Type 1, 2, 3, or ? : ")
            guard let answer = readLine() else { return nil }

            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "?" {
                print("")
                print(TargetMac.helpText)
                print("")
                continue
            }
            if let target = TargetMac.identify(answer: answer) {
                return target
            }
            attempts += 1
            print("  That didn't match one of the options. Type 1, 2, 3, or ? for help.")
        }

        return nil
    }
}
