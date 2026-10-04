import Testing
@testable import MacOSInstallerKit

@Test("every target has a label and a boot method")
func targetsHaveLabelsAndBootMethods() {
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)

    for target in TargetMac.allCases {
        #expect(target.label.isEmpty == false)
        #expect(target.bootMethod.isEmpty == false)
    }

    // Apple silicon's procedure (power button) differs from both Intel
    // targets' (Option key).
    #expect(TargetMac.appleSilicon.bootMethod != TargetMac.intelT2.bootMethod)
    #expect(TargetMac.appleSilicon.bootMethod != TargetMac.intelPreT2.bootMethod)

    // Asserted POSITIVELY, not just "not different": an Intel T2 Mac and an
    // Intel pre-T2 Mac boot external media by the identical physical
    // procedure — turn it on, hold Option. If a future edit diverges these
    // strings, this must fail. The T2-only difference (Startup Security
    // Utility must be changed first) belongs solely to
    // `requiresStartupSecurityUtility`, not to this prose.
    #expect(TargetMac.intelT2.bootMethod == TargetMac.intelPreT2.bootMethod)
}

@Test("Apple silicon boots by holding the power button, not the Option key")
func appleSiliconUsesPowerButton() {
    let method = TargetMac.appleSilicon.bootMethod.lowercased()

    #expect(method.contains("power button"))
    #expect(method.contains("option key") == false)
}

@Test("both Intel targets boot by holding Option")
func intelTargetsUseOption() {
    for target in [TargetMac.intelT2, TargetMac.intelPreT2] {
        #expect(target.bootMethod.lowercased().contains("option"))
    }
}

@Test("only the T2 target needs Startup Security Utility")
func onlyT2NeedsStartupSecurityUtility() {
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)

    // Ordered assertion, not a hand-picked true/false per case: if a case is
    // ever reordered or a new one slipped in between, this fails instead of
    // silently passing on coincidental defaults.
    #expect(TargetMac.allCases.map(\.requiresStartupSecurityUtility) == [false, true, false])
}

@Test("identify accepts the menu numbers")
func identifyAcceptsNumbers() {
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)

    #expect(TargetMac.identify(answer: "1") == .appleSilicon)
    #expect(TargetMac.identify(answer: "2") == .intelT2)
    #expect(TargetMac.identify(answer: "3") == .intelPreT2)
}

@Test("identify accepts plain-language answers a beginner would actually type")
func identifyAcceptsWords() {
    #expect(TargetMac.identify(answer: "apple silicon") == .appleSilicon)
    #expect(TargetMac.identify(answer: "M1") == .appleSilicon)
    #expect(TargetMac.identify(answer: "m2") == .appleSilicon)
    #expect(TargetMac.identify(answer: "  Intel  ") == nil)  // ambiguous: which Intel?
}

@Test("identify rejects an answer it cannot resolve rather than guessing")
func identifyRejectsUnknown() {
    // Guessing here would send the user the wrong boot instructions and they
    // would conclude the stick is broken.
    #expect(TargetMac.identify(answer: "") == nil)
    #expect(TargetMac.identify(answer: "a macbook") == nil)
    #expect(TargetMac.identify(answer: "4") == nil)
}

@Test("help text explains how to find out, without jargon")
func helpTextIsUsable() {
    let help = TargetMac.helpText

    // Names the actual menu item a user clicks.
    #expect(help.contains("About This Mac"))
    #expect(help.lowercased().contains("apple menu"))
    // Copy rules: no blaming language.
    for banned in ["simply", "just ", "obviously"] {
        #expect(help.lowercased().contains(banned) == false)
    }
}

// MARK: - Exhaustiveness guard
//
// `TargetMac.allCases` already drives most assertions above, which is
// self-updating against a new case. But two tests make a claim that a
// hand-enumerated subset cannot verify on its own — "only T2" and "the menu
// numbers map to every case" — so this exhaustive `switch` with no `default`
// clause is what fails this file to compile when a case is added without
// updating those tests to match. It is never called for what it does (each
// case just `break`s); it is only called, in the tests above, so the compiler
// checks it and does not flag it as dead code.
private func exhaustivelyCheckTargetMac(_ target: TargetMac) {
    switch target {
    case .appleSilicon: break
    case .intelT2: break
    case .intelPreT2: break
    }
}
