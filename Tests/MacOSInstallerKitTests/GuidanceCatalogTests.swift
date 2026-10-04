import Testing
@testable import MacOSInstallerKit

@Test("the before stage names the hardware, the erase, and the time")
func beforeStageCoversPreconditions() {
    let sections = GuidanceCatalog.sections(
        for: .before, target: .intelPreT2, installerName: "macOS Tahoe", driveName: nil
    )
    let all = sections.flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n")

    #expect(all.contains("32 GB"))
    #expect(all.lowercased().contains("erase"))
    // An honest duration, so nobody assumes it has frozen after five minutes.
    #expect(all.contains("minutes") || all.contains("hour"))
}

@Test("the before stage warns that the target Mac needs internet during installation")
func beforeStageMentionsTargetInternet() {
    let sections = GuidanceCatalog.sections(
        for: .before, target: .appleSilicon, installerName: "macOS Tahoe", driveName: nil
    )
    let all = sections.flatMap { $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(all.contains("internet") || all.contains("wi-fi"))
}

@Test("the during stage pre-announces the invisible password and the permission dialog")
func duringStagePreAnnouncesSurprises() {
    let sections = GuidanceCatalog.sections(
        for: .during, target: .appleSilicon, installerName: "macOS Tahoe", driveName: "SanDisk Ultra"
    )
    let all = sections.flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

    // Apple documents both. Announcing them afterwards is useless — the point
    // is that the user is not surprised.
    #expect(all.contains("no characters") || all.contains("nothing appear"))
    #expect(all.contains("removable volume") || all.contains("permission"))
}

@Test("the after stage gives only the selected target's boot method")
func afterStageIsSingleTarget() {
    let silicon = GuidanceCatalog.sections(
        for: .after, target: .appleSilicon, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
    ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(silicon.contains("power button"))
    // No branch for the reader to misparse.
    #expect(silicon.contains("option key") == false)

    let intel = GuidanceCatalog.sections(
        for: .after, target: .intelPreT2, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
    ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(intel.contains("option"))
    #expect(intel.contains("power button") == false)
}

@Test("the after stage includes the Startup Security Utility step for a T2 target only")
func afterStageIncludesT2Caveat() {
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)

    func afterText(_ target: TargetMac) -> String {
        GuidanceCatalog.sections(
            for: .after, target: target, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
        ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n")
    }

    #expect(afterText(.intelT2).contains("Startup Security Utility"))
    #expect(afterText(.appleSilicon).contains("Startup Security Utility") == false)
    #expect(afterText(.intelPreT2).contains("Startup Security Utility") == false)
}

@Test("the after stage explains the circle with a line through it")
func afterStageExplainsIncompatibilitySymbol() {
    let all = GuidanceCatalog.sections(
        for: .after, target: .intelPreT2, installerName: "macOS Mojave", driveName: "Install macOS Mojave"
    ).flatMap { $0.body + $0.steps }.joined(separator: "\n").lowercased()

    #expect(all.contains("circle with a line"))
}

@Test("the after stage names the renamed drive, since the user's drive name changed")
func afterStageNamesRenamedDrive() {
    let all = GuidanceCatalog.sections(
        for: .after, target: .appleSilicon, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
    ).flatMap { $0.body + $0.steps }.joined(separator: "\n")

    // Apple renames the volume on success. A user looking for "SanDisk Ultra"
    // in the startup picker will not find it.
    #expect(all.contains("Install macOS Tahoe"))
}

@Test("no stage uses language that blames the reader")
func noStageBlamesTheReader() {
    GuidanceStage.allCases.forEach(exhaustivelyCheckGuidanceStage)
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)

    for stage in GuidanceStage.allCases {
        for target in TargetMac.allCases {
            let text = GuidanceCatalog.sections(
                for: stage, target: target, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
            ).flatMap { [$0.heading] + $0.body + $0.steps }.joined(separator: "\n").lowercased()

            for banned in ["simply", "just ", "obviously", "merely"] {
                #expect(text.contains(banned) == false, "\(stage)/\(target) contains '\(banned)'")
            }
        }
    }
}

@Test("every stage returns at least one section for every target")
func everyStageHasContentForEveryTarget() {
    GuidanceStage.allCases.forEach(exhaustivelyCheckGuidanceStage)
    TargetMac.allCases.forEach(exhaustivelyCheckTargetMac)

    for stage in GuidanceStage.allCases {
        for target in TargetMac.allCases {
            let sections = GuidanceCatalog.sections(
                for: stage, target: target, installerName: "macOS Tahoe", driveName: "Install macOS Tahoe"
            )
            #expect(sections.isEmpty == false, "\(stage)/\(target) has no content")
        }
    }
}

// MARK: - Exhaustiveness guards
//
// `afterStageIncludesT2Caveat` hand-enumerates all three `TargetMac` cases
// with a specific true/false expectation per case, and the two loop-based
// tests above hand-iterate `GuidanceStage` and `TargetMac` together. Per this
// codebase's established pattern (see `TargetMacTests.swift` and
// `ExplanationWordingTests.swift`), each is an exhaustive `switch` with no
// `default` clause so that adding a case to either enum fails this file to
// compile until the new case is accounted for here — a hand-maintained list
// alone would let a new case ship with no guidance coverage at all.

private func exhaustivelyCheckGuidanceStage(_ stage: GuidanceStage) {
    switch stage {
    case .before: break
    case .during: break
    case .after: break
    }
}

private func exhaustivelyCheckTargetMac(_ target: TargetMac) {
    switch target {
    case .appleSilicon: break
    case .intelT2: break
    case .intelPreT2: break
    }
}
