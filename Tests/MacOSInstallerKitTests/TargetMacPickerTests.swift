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
    //
    // A fourth answer ("1") is appended that WOULD resolve to a real target
    // if it were ever read. With the attempts budget working, give-up
    // happens after the third unresolved answer and this fourth answer is
    // never reached, so the result must still be nil. If `attempts += 1`
    // were ever deleted again, the loop would keep going, read this fourth
    // answer, and return `.appleSilicon` instead — failing this test.
    var inputs = ["nope", "huh", "what", "1"]
    var readCount = 0
    let target = TargetMacPicker.ask(
        readLine: {
            guard !inputs.isEmpty else { return nil }
            readCount += 1
            return inputs.removeFirst()
        },
        print: { _ in },
        maximumAttempts: 3
    )

    #expect(target == nil)
    #expect(readCount == 3)
}

@Test("an immediate end of input returns nil without consuming an attempt or looping")
func immediateEndOfInputResolvesToNilImmediately() {
    // Simulates stdin not being a terminal (piped input, CI): `readLine`
    // returns nil on the very first call, before the user has answered
    // anything. `create` relies on this exact nil to fail closed rather than
    // guess a target — see `CreateCommand`'s handling of `TargetMacPicker.ask`.
    var readCount = 0
    let target = TargetMacPicker.ask(
        readLine: {
            readCount += 1
            return nil
        },
        print: { _ in },
        maximumAttempts: 3
    )

    #expect(target == nil)
    #expect(readCount == 1)
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
