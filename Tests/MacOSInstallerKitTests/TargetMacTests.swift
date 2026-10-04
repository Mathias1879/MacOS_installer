import Testing
@testable import MacOSInstallerKit

@Test("every target has a label, a boot method, and no shared boot method")
func targetsHaveDistinctBootMethods() {
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)

    let methods = TargetMac.allCases.map(\.bootMethod)

    for target in TargetMac.allCases {
        #expect(target.label.isEmpty == false)
        #expect(target.bootMethod.isEmpty == false)
    }
    // Apple silicon holds the power button; Intel holds Option. If two targets
    // shared a method the picker would be pointless.
    #expect(Set(methods).count == TargetMac.allCases.count)
}

@Test("Apple silicon boots by holding the power button, not Option")
func appleSiliconUsesPowerButton() {
    let method = TargetMac.appleSilicon.bootMethod.lowercased()

    #expect(method.contains("power button"))
    #expect(method.contains("option") == false)
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
