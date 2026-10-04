import Testing
import MacOSInstallerKit
@testable import macos_installer

@Test("asking for help any number of times never costs an attempt")
func helpDoesNotConsumeAttempts() {
    // Four help requests in a row is already more than `maximumAttempts`
    // (3). If help consumed an attempt the way it used to, the fourth input
    // ("2") would never be reached — the picker would already have given up
    // and returned nil. It must still resolve to the real answer.
    var inputs = ["?", "?", "?", "?", "2"]
    let target = TargetMacPicker.ask(
        readLine: {
            guard !inputs.isEmpty else { return nil }
            return inputs.removeFirst()
        },
        print: { _ in },
        maximumAttempts: 3
    )

    #expect(target == .intelT2)
}

@Test("an unresolved non-help answer still consumes an attempt and eventually gives up")
func unresolvedAnswersStillConsumeAttempts() {
    // Three unresolved answers against a budget of 3 must exhaust it and
    // return nil — this is the budget Finding 3 says help must NOT spend.
    var inputs = ["nope", "huh", "what"]
    let target = TargetMacPicker.ask(
        readLine: {
            guard !inputs.isEmpty else { return nil }
            return inputs.removeFirst()
        },
        print: { _ in },
        maximumAttempts: 3
    )

    #expect(target == nil)
}

@Test("the picker still resolves a correct first answer")
func correctFirstAnswerResolvesImmediately() {
    var inputs = ["1"]
    let target = TargetMacPicker.ask(
        readLine: {
            guard !inputs.isEmpty else { return nil }
            return inputs.removeFirst()
        },
        print: { _ in },
        maximumAttempts: 3
    )

    #expect(target == .appleSilicon)
}
