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

@Test("identify accepts the chip names exactly as helpText tells the user to read them")
func identifyAcceptsRealisticChipAnswers() {
    // These are the literal strings `helpText` points a user at (the "Chip"
    // line in About This Mac), so the parser must not reject its own advice.
    #expect(TargetMac.identify(answer: "Apple M1 chip") == .appleSilicon)
    #expect(TargetMac.identify(answer: "M2 Max") == .appleSilicon)
    #expect(TargetMac.identify(answer: "M3 Pro") == .appleSilicon)
    #expect(TargetMac.identify(answer: "Apple M4") == .appleSilicon)
}

@Test("unanchoring the chip match does not create a false positive on unrelated text")
func identifyDoesNotFalsePositiveOnEmbeddedLetterM() {
    // Unanchoring `^m[1-4]$` to a substring match risks firing on any word
    // that happens to contain "m" followed by a digit 1-4, such as "item1"
    // or "problem2". A word-boundary match must reject these.
    #expect(TargetMac.identify(answer: "item1") == nil)
    #expect(TargetMac.identify(answer: "problem2") == nil)
    #expect(TargetMac.identify(answer: "room3") == nil)
}

@Test("identify rejects an answer it cannot resolve rather than guessing")
func identifyRejectsUnknown() {
    // Guessing here would send the user the wrong boot instructions and they
    // would conclude the stick is broken.
    #expect(TargetMac.identify(answer: "") == nil)
    #expect(TargetMac.identify(answer: "a macbook") == nil)
    #expect(TargetMac.identify(answer: "4") == nil)
}

@Test("identify never resolves a bare model year — one year can mean either T2 era")
func identifyRejectsBareYears() {
    // The iMac Pro (late 2017) was Apple's first T2 Mac; the 2019 iMac has no
    // T2 chip at all; 2019 IS a T2 year for the Mac Pro, MacBook Pro 16-inch,
    // and MacBook Air. No bare year can be mapped safely, so none is.
    for year in ["2012", "2017", "2018", "2019", "2020"] {
        #expect(TargetMac.identify(answer: year) == nil)
    }
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

@Test("help text resolves the Mac-won't-start-up case and never a bare year")
func helpTextCoversAllThreeCasesWithoutInventingAYearRuleOrURL() {
    let help = TargetMac.helpText

    // Startable-Mac path: names the binary, no-exceptions signal.
    #expect(help.contains("Controller"))
    #expect(help.contains("Apple T2 Security Chip"))
    // Won't-start-up path: refers to Apple's article by title, never a URL —
    // no URL has been verified, and a wrong link in help text is worse than
    // none.
    #expect(help.contains("Mac computers that have the Apple T2 Security Chip"))
    #expect(help.contains("http") == false)
    // Still-unsure path: fails toward the safer guess (T2), with a reason.
    #expect(help.contains("option 2"))
    // No bare year is used as a classification rule anywhere in the prose.
    for year in ["2012", "2013", "2014", "2015", "2016", "2017", "2018", "2019", "2020"] {
        #expect(help.contains(year) == false)
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
